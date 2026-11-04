// A hand record from the headset (Documents/hand_record.csv, VXMAC_GESTURES=1: xros_vr.m) played through
// vr/hand_gestures.c on the Mac, with the thresholds changed by name, to tune them against what the person did.
//   clang -O2 -I../vr tests/hand_gestures_replay.c ../vr/hand_gestures.c -o build/hand_gestures_replay
//   build/hand_gestures_replay hand_record.csv [punch_speed=2.0,mouth_r=0.1] [--lefty] [--trace]
// Prints each gesture with its time from the record's start (and whether the headset saw it too), the counts, and
// with --trace a line a second: the gun hand's peak forward speed, the off hand's lowest and highest point against
// the eyes, the nearest index tip to the mouth, the hands' tracked share - the numbers the thresholds are set from.
#include "hand_gestures.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *path = NULL, *tune = NULL; int lefty = 0, trace = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--lefty")) lefty = 1;
        else if (!strcmp(argv[i], "--trace")) trace = 1;
        else if (strchr(argv[i], '=')) tune = argv[i];
        else path = argv[i];
    }
    if (!path) { fprintf(stderr, "usage: %s hand_record.csv [name=value,...] [--lefty] [--trace]\n", argv[0]); return 2; }
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); return 1; }
    if (tune && !hand_gestures_tune(tune)) { fprintf(stderr, "no threshold named in %s\n", tune); return 2; }
    char pr[512]; hand_gestures_params(pr, sizeof pr); printf("thresholds %s\n", pr);
    hand_gestures g; memset(&g, 0, sizeof g); g.lefty = lefty;
    int gun = lefty ? 0 : 1, off = 1 - gun;
    char line[4096]; double t0 = -1, sec = -1; unsigned rows = 0, vr_rows = 0, rec_counts[HG_N] = { 0 }, agree = 0, ours = 0;
    float peak = 0, lo = 9, hi = -9, mouth_min = 9; unsigned tr_n[2] = { 0 }, sec_n = 0; float prev_gun[3] = { 0 }; double prev_t = 0;
    while (fgets(line, sizeof line, f)) {
        double v[40]; int n = 0;
        for (char *s = line, *e; n < 40; s = e + 1) { v[n++] = strtod(s, &e); if (*e != ',') break; }
        if (n < 39) continue;
        double now = v[0]; int vr = (int)v[1], rec_b = (int)v[38];
        float head[16], hands[20];
        for (int i = 0; i < 16; i++) head[i] = (float)v[2 + i];
        for (int i = 0; i < 20; i++) hands[i] = (float)v[18 + i];
        if (t0 < 0) t0 = now;
        rows++;
        for (int i = 0; i < HG_N; i++) if (rec_b & (1 << i)) rec_counts[i]++;
        if (!vr) continue;
        vr_rows++;
        int b = hand_gestures_update(&g, head, hands, now);
        for (int i = 0; i < HG_N; i++) if (b & (1 << i)) {
            ours++; int same = (rec_b & (1 << i)) != 0; agree += same;
            printf("%8.2f s  %-8s%s\n", now - t0, hand_gesture_name(1 << i), same ? "" : "  (not on the headset)");
        }
        for (int i = 0; i < HG_N; i++) if ((rec_b & (1 << i)) && !(b & (1 << i))) printf("%8.2f s  %-8s  (headset only)\n", now - t0, hand_gesture_name(1 << i));
        if (trace) {
            float fw[3] = { -head[8], 0, -head[10] }, nn = sqrtf(fw[0] * fw[0] + fw[2] * fw[2]); if (nn < 1e-3f) { fw[2] = -1; nn = 1; }
            fw[0] /= nn; fw[2] /= nn;
            float mouth[3] = { head[12] + fw[0] * 0.06f, head[13] - 0.08f, head[14] + fw[2] * 0.06f };
            for (int h = 0; h < 2; h++) if (hands[h * 10] > 0.5f) {
                tr_n[h]++;
                const float *ix = hands + h * 10 + 4;
                float d = sqrtf((ix[0] - mouth[0]) * (ix[0] - mouth[0]) + (ix[1] - mouth[1]) * (ix[1] - mouth[1]) + (ix[2] - mouth[2]) * (ix[2] - mouth[2]));
                if (d < mouth_min) mouth_min = d;
            }
            if (hands[off * 10] > 0.5f) { float y = hands[off * 10 + 8] - head[13]; if (y < lo) lo = y; if (y > hi) hi = y; }
            if (hands[gun * 10] > 0.5f) {
                const float *a = hands + gun * 10 + 7;
                if (prev_t > 0 && now - prev_t < 0.1 && now > prev_t) {
                    float sp = ((a[0] - prev_gun[0]) * fw[0] + (a[2] - prev_gun[2]) * fw[2]) / (float)(now - prev_t);
                    if (sp > peak) peak = sp;
                }
                memcpy(prev_gun, a, sizeof prev_gun); prev_t = now;
            } else prev_t = 0;
            sec_n++;
            if (sec < 0) sec = now;
            if (now - sec >= 1) {
                printf("  %6.0f s  gun fwd peak %4.1f m/s  off hand y %+.2f..%+.2f m  mouth %.2f m  tracked L %3.0f%% R %3.0f%%\n",
                       sec - t0, peak, lo < 9 ? lo : 0, hi > -9 ? hi : 0, mouth_min < 9 ? mouth_min : 0, 100.0 * tr_n[0] / sec_n, 100.0 * tr_n[1] / sec_n);
                sec = now; peak = 0; lo = 9; hi = -9; mouth_min = 9; tr_n[0] = tr_n[1] = 0; sec_n = 0;
            }
        }
    }
    fclose(f);
    printf("%u rows, %u in vr mode (%.0f s)\n", rows, vr_rows, rows ? (double)vr_rows / 90 : 0);
    printf("replay:  reload %u  melee %u  grenade %u  heal %u\n", g.count[0], g.count[1], g.count[2], g.count[3]);
    printf("headset: reload %u  melee %u  grenade %u  heal %u   (%u of the replay's %u also on the headset)\n",
           rec_counts[0], rec_counts[1], rec_counts[2], rec_counts[3], agree, ours);
    return 0;
}
