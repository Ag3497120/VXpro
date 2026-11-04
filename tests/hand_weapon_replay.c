// A hand pose record from the headset (Documents/hand_pose_record.csv, VXMAC_MAG=1: xros_vr.m) played through
// vr/hand_weapon.c on the Mac, with the thresholds changed by name, to tune them against what the person did.
//   clang -O2 -Ivr tests/hand_weapon_replay.c vr/hand_weapon.c -o build/hand_weapon_replay
//   build/hand_weapon_replay hand_pose_record.csv [fist_on=0.5,well_r=0.1] [--lefty] [--rack] [--hybrid] [--trace] [--json out.json]
// Prints each step with its time from the record's start (and whether the headset saw it too), each change of state,
// the counts, and with --trace a line a second: both hands' grip (lowest..highest), the off hand's nearest approach to
// the grip's bottom, its lowest and highest point against the eyes, the hands' tracked share - the numbers the
// thresholds are set from. --json: every 3rd frame for tools/hand_pose_view.html - the eyes, both hands' joints, the
// grip's bottom and line, the state, the steps made, aim and trigger.
#include "hand_weapon.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { COLS = 2 + 16 + 2 * HW_JOINTS + 1 };

int main(int argc, char **argv) {
    const char *path = NULL, *tune = NULL, *json = NULL; int lefty = 0, rack = 0, trace = 0, hybrid = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--hybrid")) hybrid = 1;
        else if (!strcmp(argv[i], "--lefty")) lefty = 1;
        else if (!strcmp(argv[i], "--rack")) rack = 1;
        else if (!strcmp(argv[i], "--trace")) trace = 1;
        else if (!strcmp(argv[i], "--json") && i + 1 < argc) json = argv[++i];
        else if (strchr(argv[i], '=')) tune = argv[i];
        else path = argv[i];
    }
    if (!path) { fprintf(stderr, "usage: %s hand_pose_record.csv [name=value,...] [--lefty] [--rack] [--hybrid] [--trace]\n", argv[0]); return 2; }
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); return 1; }
    FILE *jf = NULL;
    if (json && !(jf = fopen(json, "w"))) { perror(json); return 1; }
    if (jf) fprintf(jf, "{\"lefty\":%d,\"frames\":[", lefty);
    unsigned jn = 0, arm_counts[HW_ARM_N] = { 0 }, ads_frames = 0; int jacc = 0;
    if (tune && !hand_weapon_tune(tune)) { fprintf(stderr, "no threshold named in %s\n", tune); return 2; }
    char pr[512]; hand_weapon_params(pr, sizeof pr); printf("thresholds %s\n", pr);
    hand_weapon w; memset(&w, 0, sizeof w); w.lefty = lefty; w.rack = rack;
    int gun = lefty ? 0 : 1, off = 1 - gun, last_state = -1;
    static char line[16384]; double t0 = -1, sec = -1; unsigned rows = 0, vr_rows = 0, rec_counts[HW_EV_N] = { 0 }, agree = 0, ours = 0;
    float glo[2] = { 9, 9 }, ghi[2] = { -9, -9 }, near = 9, ylo = 9, yhi = -9; unsigned tr_n[2] = { 0 }, sec_n = 0;
    while (fgets(line, sizeof line, f)) {
        double v[COLS]; int n = 0;
        for (char *s = line, *e; n < COLS; s = e + 1) { v[n++] = strtod(s, &e); if (*e != ',') break; }
        if (n < COLS) continue;
        double now = v[0]; int vr = (int)v[1], rec_b = (int)v[COLS - 1];
        float head[16], joints[2 * HW_JOINTS];
        for (int i = 0; i < 16; i++) head[i] = (float)v[2 + i];
        for (int i = 0; i < 2 * HW_JOINTS; i++) joints[i] = (float)v[18 + i];
        if (t0 < 0) t0 = now;
        rows++;
        for (int i = 0; i < HW_EV_N; i++) if (rec_b & (1 << i)) rec_counts[i]++;
        if (!vr) continue;
        vr_rows++;
        if (hybrid) hand_weapon_set_controller(&w, HW_BTN_ACTIVE, now);
        int b = hand_weapon_update(&w, head, joints, now);
        int ab = hand_weapon_arms(&w, head, joints, now, 1);
        if (w.ads) ads_frames++;
        for (int i = 0; i < HW_ARM_N; i++) if (ab & (1 << i)) arm_counts[i]++;
        jacc |= b;
        if (jf && vr_rows % 3 == 1) {                     // (30 Hz is plenty to look at; the steps of the skipped frames kept)
            fprintf(jf, "%s{\"t\":%.3f,\"eye\":[%.3f,%.3f,%.3f],\"fwd\":[%.3f,%.3f],\"j\":[", jn++ ? "," : "", now - (t0 < 0 ? now : t0),
                    head[12], head[13], head[14], -head[8], -head[10]);
            for (int i = 0; i < 2 * HW_JOINTS; i++) fprintf(jf, "%s%.4f", i ? "," : "", joints[i]);
            fprintf(jf, "],\"well\":%s", w.well_ok ? "[" : "null");
            if (w.well_ok) fprintf(jf, "%.4f,%.4f,%.4f,%.3f,%.3f,%.3f]", w.well[0], w.well[1], w.well[2], w.grip_dir[0], w.grip_dir[1], w.grip_dir[2]);
            fprintf(jf, ",\"s\":%d,\"ev\":%d,\"near\":%d,\"mag\":%d,\"ads\":%d,\"trig\":%d}", w.state, jacc, w.near_well, w.mag_shown, w.ads, w.trigger);
            jacc = 0;
        }
        for (int i = 0; i < HW_EV_N; i++) if (b & (1 << i)) {
            ours++; int same = (rec_b & (1 << i)) != 0; agree += same;
            printf("%8.2f s  %-7s%s\n", now - t0, hand_weapon_event_name(1 << i), same ? "" : "  (not on the headset)");
        }
        for (int i = 0; i < HW_EV_N; i++) if ((rec_b & (1 << i)) && !(b & (1 << i))) printf("%8.2f s  %-7s  (headset only)\n", now - t0, hand_weapon_event_name(1 << i));
        if (w.state != last_state) { if (trace) printf("%8.2f s    -> %s\n", now - t0, hand_weapon_state_name(w.state)); last_state = w.state; }
        if (trace) {
            for (int h = 0; h < 2; h++) {
                hand_pose p; hand_pose_from_joints(joints + h * HW_JOINTS, &p);
                if (!p.ok) continue;
                tr_n[h]++;
                if (p.grip < glo[h]) glo[h] = p.grip;
                if (p.grip > ghi[h]) ghi[h] = p.grip;
                if (h == off) {
                    if (w.well_ok) { float d[3] = { p.palm[0] - w.well[0], p.palm[1] - w.well[1], p.palm[2] - w.well[2] }; float dd = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]); if (dd < near) near = dd; }
                    float y = p.palm[1] - head[13]; if (y < ylo) ylo = y; if (y > yhi) yhi = y;
                }
            }
            sec_n++;
            if (sec < 0) sec = now;
            if (now - sec >= 1) {
                printf("  %6.0f s  grip L %.2f..%.2f R %.2f..%.2f  off hand to grip %.2f m  off y %+.2f..%+.2f m  tracked L %3.0f%% R %3.0f%%\n",
                       sec - t0, glo[0] < 9 ? glo[0] : 0, ghi[0] > -9 ? ghi[0] : 0, glo[1] < 9 ? glo[1] : 0, ghi[1] > -9 ? ghi[1] : 0,
                       near < 9 ? near : 0, ylo < 9 ? ylo : 0, yhi > -9 ? yhi : 0, 100.0 * tr_n[0] / sec_n, 100.0 * tr_n[1] / sec_n);
                sec = now; glo[0] = glo[1] = near = ylo = 9; ghi[0] = ghi[1] = yhi = -9; tr_n[0] = tr_n[1] = 0; sec_n = 0;
            }
        }
    }
    fclose(f);
    if (jf) { fprintf(jf, "]}\n"); fclose(jf); printf("%u frames to %s\n", jn, json); }
    (void)gun;
    printf("%u rows, %u in vr mode (%.0f s)\n", rows, vr_rows, rows ? (double)vr_rows / 90 : 0);
    printf("ads: %u starts, %u frames\n", w.ads_count, ads_frames);
    printf("replay:  out %u  grab %u  in %u  rack %u  done %u  cancel %u\n", w.count[0], w.count[1], w.count[2], w.count[3], w.count[4], w.count[5]);
    printf("arm events:");
    for (int i = 0; i < HW_ARM_N; i++) printf(" bit%d=%u", i, arm_counts[i]);
    printf(" (controller and forearm inputs not recorded)\n");
    printf("headset: out %u  grab %u  in %u  rack %u  done %u  cancel %u   (%u of the replay's %u also on the headset)\n",
           rec_counts[0], rec_counts[1], rec_counts[2], rec_counts[3], rec_counts[4], rec_counts[5], agree, ours);
    return 0;
}
