// vr/hand_weapon.c driven with made-up hand skeletons at 90 Hz: a reload made by hand gives out, grab, in and done once
// each, and the moves that look like parts of it (a fist at the hip, a grip let go, the old magazine grabbed again, a
// slow give-up) give nothing or a cancel.
//   clang -O2 -Ivr tests/hand_weapon_mac.c vr/hand_weapon.c -o build/hand_weapon_mac && build/hand_weapon_mac
// [record.csv]: also writes every frame as the headset's pose record does (xros_vr.m), for tests/hand_weapon_replay.c.
#include "hand_weapon.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static float head[16], joints[2 * HW_JOINTS];
static double t;
static hand_weapon w;
static unsigned seen[HW_EV_N], arms[HW_ARM_N], ads_frames;
static int use_trigger;
static FILE *rec;
static float yaw_deg;                                     // (the whole body turned left by this, about the eyes)

typedef struct { float palm[3], fwd[3], across[3], grip, trig; int tracked; } hand_in;
static hand_in H[2];
// (the tracking's noise for the noisy runs: each joint off by up to noise_m, the curl by up to grip_jit, a hand
//  lost for a frame drop_pct of the time; a fixed generator, so a seed gives the same run)
static float noise_m, grip_jit, drop_pct; static unsigned rng = 1;
static float rnd(void) { rng = rng * 1664525u + 1013904223u; return ((rng >> 8) & 0xFFFF) / 32767.5f - 1; }   // (-1..1)

static void rot(const float *p, float *o) {              // (the body frame -> the room: turned about the eyes' vertical)
    float a = yaw_deg * (float)M_PI / 180, c = cosf(a), s = sinf(a);
    o[0] = p[0] * c + p[2] * s; o[1] = p[1]; o[2] = -p[0] * s + p[2] * c;
}
static void set_head(void) {
    float a = yaw_deg * (float)M_PI / 180, c = cosf(a), s = sinf(a);
    memset(head, 0, sizeof head);
    head[0] = c; head[2] = -s; head[5] = 1; head[8] = s; head[10] = c; head[15] = 1;
    head[12] = 0; head[13] = 1.6f; head[14] = 0;
}
// (a skeleton from a palm, the hand's forward (wrist -> middle knuckle), across (index knuckle -> little knuckle), curl)
static void put_hand(int h) {
    float *J = joints + h * HW_JOINTS;
    memset(J, 0, HW_JOINTS * sizeof *J);
    if (!H[h].tracked) return;
    if (drop_pct > 0 && (rnd() + 1) * 50 < drop_pct) return;
    float P[3], F[3], A[3]; rot(H[h].palm, P); rot(H[h].fwd, F); rot(H[h].across, A);
    float W[3], MK[3], IK[3], LK[3];
    for (int i = 0; i < 3; i++) {
        W[i] = P[i] - F[i] * 0.045f; MK[i] = P[i] + F[i] * 0.045f;
        IK[i] = MK[i] - A[i] * 0.025f; LK[i] = MK[i] + A[i] * 0.035f - F[i] * 0.01f;
    }
    float ratio = 1.9f - H[h].grip * 1.0f + rnd() * grip_jit;   // (1.9 straight .. 0.9 a fist: the tip's distance over the knuckle's)
    float km = 0.09f, kl = sqrtf(0.08f * 0.08f + 0.035f * 0.035f);
    float MT[3], RT[3], LT[3], IT[3], ki = sqrtf(0.09f * 0.09f + 0.025f * 0.025f), ir = 1.9f - H[h].trig * 0.6f;
    for (int i = 0; i < 3; i++) {
        IT[i] = W[i] + F[i] * ki * ir - A[i] * 0.025f * 0.3f;   // (the index finger: straight 1.9, on a trigger 1.3)
        MT[i] = W[i] + F[i] * km * ratio;
        RT[i] = W[i] + F[i] * km * ratio * 0.97f + A[i] * 0.018f;
        LT[i] = W[i] + F[i] * kl * ratio * 0.93f + A[i] * 0.035f;
    }
    J[0] = 1;
    const float *pts[HW_POINTS] = { W, IK, MK, LK, MT, RT, LT, IT };
    for (int k = 0; k < HW_POINTS; k++) for (int i = 0; i < 3; i++) J[1 + k * 3 + i] = pts[k][i] + (noise_m > 0 ? rnd() * noise_m : 0);
}
static void step(void) {
    set_head(); put_hand(0); put_hand(1);
    int b = hand_weapon_update(&w, head, joints, t);
    int a = hand_weapon_arms(&w, head, joints, t, use_trigger);
    for (int i = 0; i < HW_ARM_N; i++) if (a & (1 << i)) arms[i]++;
    ads_frames += w.ads;
    if (rec) {
        fprintf(rec, "%.4f,1", t);
        for (int i = 0; i < 16; i++) fprintf(rec, ",%.4f", head[i]);
        for (int i = 0; i < 2 * HW_JOINTS; i++) fprintf(rec, ",%.4f", joints[i]);
        fprintf(rec, ",%d\n", b);
    }
    for (int i = 0; i < HW_EV_N; i++) if (b & (1 << i)) seen[i]++;
    t += 1.0 / 90;
}
static void hold(double secs) { for (int i = 0; i < (int)(secs * 90); i++) step(); }
static void move(int h, const float to[3], float grip_to, double secs) {
    float from[3]; memcpy(from, H[h].palm, sizeof from); float g0 = H[h].grip;
    int n = (int)(secs * 90); if (n < 1) n = 1;
    for (int i = 1; i <= n; i++) {
        float k = (float)i / n;
        for (int j = 0; j < 3; j++) H[h].palm[j] = from[j] + (to[j] - from[j]) * k;
        H[h].grip = g0 + (grip_to - g0) * k;
        step();
    }
}
static void grip(int h, float to, double secs) { move(h, H[h].palm, to, secs); }
static void orient(int h, float fx, float fy, float fz, float ax, float ay, float az) {
    H[h].fwd[0] = fx; H[h].fwd[1] = fy; H[h].fwd[2] = fz; H[h].across[0] = ax; H[h].across[1] = ay; H[h].across[2] = az;
}

// the body frame: the eyes at (0, 1.6, 0) looking down -z; the right (gun) hand holds a pistol in front: fingers
// round the grip forward, knuckles stacked down the grip
static const float GUN[3] = { 0.2f, 1.3f, -0.4f }, REST[3] = { -0.22f, 1.0f, -0.15f };
static float WELL[3];                                     // (where the module puts the grip's bottom for GUN)
static double t_next = 100;
static int gun_h = 1, off_h = 0;
static void reset(int lefty, float yaw) {
    memset(&w, 0, sizeof w); memset(seen, 0, sizeof seen); memset(arms, 0, sizeof arms); ads_frames = 0; use_trigger = 0; w.lefty = lefty; t = t_next; t_next += 60; yaw_deg = yaw;
    gun_h = lefty ? 0 : 1; off_h = 1 - gun_h;
    float g[3] = { lefty ? -GUN[0] : GUN[0], GUN[1], GUN[2] }, r[3] = { lefty ? -REST[0] : REST[0], REST[1], REST[2] };
    memcpy(H[gun_h].palm, g, sizeof g); H[gun_h].grip = 1; H[gun_h].trig = 0; H[gun_h].tracked = 1; orient(gun_h, 0, 0, -1, 0, -1, 0);
    memcpy(H[off_h].palm, r, sizeof r); H[off_h].grip = 0.1f; H[off_h].trig = 0; H[off_h].tracked = 1; orient(off_h, 0, -1, 0, lefty ? -1 : 1, 0, 0);
    // (the grip's bottom: past the little knuckle (palm + fwd 0.045 + across 0.035 - fwd 0.01) by 2 cm along the grip)
    WELL[0] = g[0]; WELL[1] = g[1] - 0.035f - 0.02f; WELL[2] = g[2] - 0.035f;
    hold(1);
}
static float at(float x, float y, float z, float *o) { o[0] = x; o[1] = y; o[2] = z; return 0; }
static int fails;
static void expect(const char *what, unsigned o, unsigned g, unsigned in, unsigned rk, unsigned dn, unsigned cn) {
    unsigned want[HW_EV_N] = { o, g, in, rk, dn, cn };
    int ok = !memcmp(want, seen, sizeof want);
    printf("%-52s %s  (out %u grab %u in %u rack %u done %u cancel %u, %s)\n", what, ok ? "ok" : "FAIL",
           seen[0], seen[1], seen[2], seen[3], seen[4], seen[5], hand_weapon_state_name(w.state));
    fails += !ok;
}
static void expect_arms(const char *what, unsigned hip, unsigned back, unsigned hol, unsigned ads, unsigned shots) {
    int ok = arms[0] == hip && arms[1] == back && arms[2] == hol && w.ads_count == ads && w.shots == shots && !seen[0];
    printf("%-52s %s  (draw hip %u back %u, holster %u, aim %u (%u frames), shots %u)\n", what, ok ? "ok" : "FAIL",
           arms[0], arms[1], arms[2], w.ads_count, ads_frames, w.shots);
    fails += !ok;
}
// the steps of a reload, the off hand's palm in the body frame
static void take_out(void) {
    float p[3]; orient(off_h, gun_h ? 1 : -1, 0, 0, 0, -1, 0);   // (palm towards the grip, knuckles down)
    move(off_h, WELL, 0.1f, 0.4); grip(off_h, 1, 0.15);
    at(WELL[0], WELL[1] - 0.2f, WELL[2] + 0.05f, p); move(off_h, p, 1, 0.3);
    grip(off_h, 0.1f, 0.15);                               // (the old one dropped)
}
static void take_new_at_hip(void) {
    float p[3]; at(gun_h ? -0.15f : 0.15f, 1.0f, -0.05f, p);
    move(off_h, p, 0.1f, 0.4); grip(off_h, 1, 0.15);
}
static void put_in(void) {
    float p[3]; at(WELL[0], WELL[1] - 0.03f, WELL[2], p);
    move(off_h, p, 1, 0.45); hold(0.1);
    at(WELL[0], WELL[1] + 0.03f, WELL[2], p); move(off_h, p, 1, 0.15);
    grip(off_h, 0.1f, 0.15); move(off_h, REST, 0.1f, 0.4);
}

int main(int argc, char **argv) {
    if (argc > 1 && !(rec = fopen(argv[1], "w"))) { perror(argv[1]); return 2; }
    {   // the curl measure itself
        hand_pose p; reset(0, 0);
        H[0].grip = 0; put_hand(0); hand_pose_from_joints(joints, &p); float open = p.grip;
        H[0].grip = 1; put_hand(0); hand_pose_from_joints(joints, &p); float fist = p.grip;
        int ok = open < 0.15f && fist > 0.85f;
        printf("%-52s %s  (open %.2f, fist %.2f)\n", "grip: an open hand ~0, a fist ~1", ok ? "ok" : "FAIL", open, fist); fails += !ok;
    }
    reset(0, 0); hold(3); expect("idle 3 s: nothing", 0, 0, 0, 0, 0, 0);

    reset(0, 0); take_out(); take_new_at_hip(); put_in();
    expect("reload: out, a new one from the hip, in: done", 1, 1, 1, 0, 1, 0);

    reset(0, 0); take_out();
    { float p[3]; at(-0.05f, 1.2f, -0.2f, p); move(off_h, p, 0.1f, 0.3); grip(off_h, 1, 0.15); }   // (the chest pouch)
    put_in();
    expect("reload with a magazine from the chest", 1, 1, 1, 0, 1, 0);

    reset(0, 0); { float p[3]; at(-0.15f, 1.0f, -0.05f, p); move(off_h, p, 0.1f, 0.4); grip(off_h, 1, 0.15); hold(0.5); grip(off_h, 0.1f, 0.2); }
    expect("a fist at the hip with the gun loaded: nothing", 0, 0, 0, 0, 0, 0);

    reset(0, 0); orient(off_h, 1, 0, 0, 0, -1, 0); move(off_h, WELL, 0.1f, 0.4); grip(off_h, 1, 0.15); hold(0.3); grip(off_h, 0.1f, 0.15);
    { float p[3]; at(WELL[0], WELL[1] - 0.2f, WELL[2], p); move(off_h, p, 0.1f, 0.3); }
    expect("the grip held, let go, then the hand away: nothing", 0, 0, 0, 0, 0, 0);

    reset(0, 0);                                          // (a two-handed grip: the off hand's fist under the grip, aiming)
    { orient(off_h, 1, 0, 0, 0, -1, 0); move(off_h, WELL, 0.1f, 0.4); grip(off_h, 1, 0.15);
      for (int i = 0; i < 90; i++) { yaw_deg += 0.6f; step(); }   // (both hands turned together with the body, 1 s)
      hold(3); float p[3]; at(WELL[0] - 0.1f, WELL[1] - 0.25f, WELL[2] + 0.1f, p); move(off_h, p, 1, 0.3); grip(off_h, 0.1f, 0.2); }
    expect("a two-handed grip held 4 s, turned, then let go: nothing", 0, 0, 0, 0, 0, 0);

    reset(0, 0); { orient(off_h, 1, 0, 0, 0, -1, 0); move(off_h, WELL, 0.1f, 0.4); grip(off_h, 1, 0.15);
      float p[3]; at(WELL[0] - 0.2f, WELL[1], WELL[2], p); move(off_h, p, 1, 0.3); hold(0.5); }
    expect("the fist pulled sideways off the grip: nothing", 0, 0, 0, 0, 0, 0);

    reset(0, 0); take_out(); orient(off_h, 1, 0, 0, 0, -1, 0); move(off_h, WELL, 0.1f, 0.3); grip(off_h, 1, 0.15); hold(0.3);
    expect("after out, a fist at the grip again: no new magazine", 1, 0, 0, 0, 0, 0);

    reset(0, 0); take_out(); take_new_at_hip(); grip(off_h, 0.1f, 0.15); hold(0.3); take_new_at_hip(); put_in();
    expect("the new one dropped, another taken, in: done", 1, 2, 1, 0, 1, 0);

    reset(0, 0); take_out(); hold(21);
    expect("out, then nothing for 21 s: cancelled", 1, 0, 0, 0, 0, 1);

    reset(0, 0); take_out(); take_new_at_hip();
    { float p[3]; at(WELL[0], WELL[1] - 0.03f, WELL[2], p); move(off_h, p, 1, 0.45);
      H[off_h].tracked = 0; hold(0.3); H[off_h].tracked = 1;
      at(WELL[0], WELL[1] + 0.03f, WELL[2], p); move(off_h, p, 1, 0.15); }
    expect("the off hand lost for 0.3 s at the grip: still in", 1, 1, 1, 0, 1, 0);

    reset(0, 0); w.rack = 1; take_out(); take_new_at_hip(); put_in();
    { float s[3] = { GUN[0], GUN[1] + 0.04f + 0.025f, GUN[2] - 0.04f }, p[3];   // (above the index knuckle: the slide)
      orient(off_h, 0, -1, 0, 1, 0, 0); move(off_h, s, 0.1f, 0.4); grip(off_h, 1, 0.15);
      at(s[0], s[1], s[2] + 0.1f, p); move(off_h, p, 1, 0.2); grip(off_h, 0.1f, 0.15); }
    expect("VXMAC_MAG_RACK=1: in, then the slide racked: done", 1, 1, 1, 1, 1, 0);

    reset(0, 0); w.rack = 1; take_out(); take_new_at_hip(); put_in(); hold(1);
    expect("VXMAC_MAG_RACK=1: in, slide not racked yet: not done", 1, 1, 1, 0, 0, 0);

    reset(0, 0); H[gun_h].grip = 0.1f; WELL[1] = GUN[1] - 0.10f; WELL[0] = GUN[0]; WELL[2] = GUN[2];
    take_out(); take_new_at_hip(); put_in();
    expect("the gun hand open: the grip's bottom 10 cm below it", 1, 1, 1, 0, 1, 0);

    reset(0, 90); take_out(); take_new_at_hip(); put_in();
    expect("the body turned 90 degrees: the same reload", 1, 1, 1, 0, 1, 0);

    reset(1, 0); take_out(); take_new_at_hip(); put_in();
    expect("left-handed (VXMAC_GESTURE_LEFTY=1): the same reload", 1, 1, 1, 0, 1, 0);


    // the gun hand's other moves (hand_weapon_arms)
    float HIP_R[3] = { 0.25f, 0.98f, -0.05f }, BACK_R[3] = { 0.15f, 1.62f, 0.08f };
    reset(0, 0); H[gun_h].grip = 0.1f; move(gun_h, HIP_R, 0.1f, 0.5); grip(gun_h, 1, 0.15); move(gun_h, GUN, 1, 0.4); hold(0.5);
    expect_arms("draw from the hip: weapon 1", 1, 0, 0, 0, 0);
    reset(0, 0); H[gun_h].grip = 0.1f; move(gun_h, BACK_R, 0.1f, 0.5); grip(gun_h, 1, 0.15); move(gun_h, GUN, 1, 0.5); hold(0.5);
    expect_arms("draw over the shoulder: weapon 2", 0, 1, 0, 0, 0);
    reset(0, 0); move(gun_h, HIP_R, 1, 0.5); grip(gun_h, 0.1f, 0.2); hold(0.5);
    expect_arms("holster: down to the hip, opened", 0, 0, 1, 0, 0);
    reset(0, 0); H[gun_h].grip = 0.1f; move(gun_h, HIP_R, 0.1f, 0.5);
    for (int i = 0; i < 5; i++) { float p[3] = { HIP_R[0], HIP_R[1] + 0.03f * (i & 1), HIP_R[2] + 0.1f * (i & 1) }; move(gun_h, p, 1, 0.3); move(gun_h, HIP_R, 0.1f, 0.3); }
    expect_arms("walking: the hand at the hip, fist and open, x5", 0, 0, 0, 0, 0);
    reset(0, 0); H[gun_h].grip = 0.1f; move(gun_h, HIP_R, 0.1f, 0.5); grip(gun_h, 1, 0.15); hold(2); move(gun_h, GUN, 1, 0.4);
    expect_arms("a fist at the hip held 2 s, then up: no draw", 0, 0, 0, 0, 0);
    reset(0, 0); { float p[3] = { GUN[0] - 0.06f, GUN[1] + 0.01f, GUN[2] + 0.02f }; orient(off_h, 1, 0, 0, 0, -1, 0);
      move(off_h, p, 0.6f, 0.4); hold(1); move(off_h, REST, 0.1f, 0.4); }
    expect_arms("aim: the off hand round the gun hand 1 s", 0, 0, 0, 1, 0);
    reset(0, 0); { float p[3] = { GUN[0] - 0.02f, GUN[1] - 0.03f, GUN[2] - 0.3f }; move(off_h, p, 0.6f, 0.4); hold(1); move(off_h, REST, 0.1f, 0.4); }
    expect_arms("aim: the off hand ahead under a rifle's barrel", 0, 0, 0, 1, 0);
    reset(0, 0); take_out(); take_new_at_hip(); put_in();
    { int ok = w.ads_count == 0; printf("%-52s %s  (aim %u)\n", "a whole reload: no aim", ok ? "ok" : "FAIL", w.ads_count); fails += !ok; }
    reset(0, 0); use_trigger = 1; for (int i = 0; i < 3; i++) { H[gun_h].trig = 1; hold(0.15); H[gun_h].trig = 0; hold(0.25); }
    expect_arms("trigger (VXMAC_TRIGGER=1): pulled 3 times", 0, 0, 0, 0, 3);
    reset(0, 0); for (int i = 0; i < 3; i++) { H[gun_h].trig = 1; hold(0.15); H[gun_h].trig = 0; hold(0.25); }
    expect_arms("trigger off: nothing", 0, 0, 0, 0, 0);
    reset(0, 0); use_trigger = 1; move(gun_h, HIP_R, 1, 0.5); H[gun_h].trig = 1; hold(0.3); H[gun_h].trig = 0; hold(0.3);
    { int ok = w.shots == 0; printf("%-52s %s  (shots %u)\n", "trigger with the gun lowered: no shot", ok ? "ok" : "FAIL", w.shots); fails += !ok; }

    {   // the same moves with the tracking's noise - 5 mm on each joint, the curl +-0.08, 2 % of frames lost - 20 seeds each
        noise_m = 0.005f; grip_jit = 0.08f; drop_pct = 2;
        if (getenv("HW_NOISE")) sscanf(getenv("HW_NOISE"), "%f,%f,%f", &noise_m, &grip_jit, &drop_pct);   // (metres, curl, percent)
        int bad[6] = { 0 };
        for (int seed = getenv("HW_SEED") ? atoi(getenv("HW_SEED")) : 1; seed <= (getenv("HW_SEED") ? atoi(getenv("HW_SEED")) : 20); seed++) {
            rng = seed * 7919u;
            reset(0, 0); take_out(); take_new_at_hip(); put_in();
            bad[0] += !(seen[4] == 1 && seen[5] == 0 && w.ads_count == 0);
            if (getenv("HW_DEBUG") && !(seen[4] == 1 && seen[5] == 0 && w.ads_count == 0))
                printf("  seed %d: out %u grab %u in %u done %u cancel %u aim %u, %s\n", seed, seen[0], seen[1], seen[2], seen[4], seen[5], w.ads_count, hand_weapon_state_name(w.state));
            reset(0, 0); hold(5);
            bad[1] += seen[0] || seen[4] || w.ads_count || arms[0] || arms[1] || arms[2];
            reset(0, 0); { float p[3] = { GUN[0] - 0.06f, GUN[1] + 0.01f, GUN[2] + 0.02f }; orient(off_h, 1, 0, 0, 0, -1, 0); move(off_h, p, 0.6f, 0.4); hold(2); move(off_h, REST, 0.1f, 0.4); }
            bad[2] += w.ads_count != 1;
            reset(0, 0); use_trigger = 1; for (int i = 0; i < 3; i++) { H[gun_h].trig = 1; hold(0.2); H[gun_h].trig = 0; hold(0.3); }
            bad[3] += w.shots != 3;
            reset(0, 0); use_trigger = 1; hold(4);
            bad[4] += w.shots != 0;
            float HIP_N[3] = { 0.25f, 0.98f, -0.05f };
            reset(0, 0); H[gun_h].grip = 0.1f; move(gun_h, HIP_N, 0.1f, 0.5);
            for (int i = 0; i < 5; i++) { float p[3] = { HIP_N[0], HIP_N[1] + 0.03f * (i & 1), HIP_N[2] + 0.1f * (i & 1) }; move(gun_h, p, 1, 0.3); move(gun_h, HIP_N, 0.1f, 0.3); }
            bad[5] += arms[0] || arms[1] || arms[2];
        }
        static const char *what[6] = { "a reload: done once, no aim", "idle 5 s: nothing", "aim held 2 s: one aim (no flicker)",
                                       "3 trigger pulls: 3 shots", "a still trigger finger 4 s: no shot", "walking with a fist at the hip: nothing" };
        for (int i = 0; i < 6; i++) {
            char l[96]; snprintf(l, sizeof l, "noisy x20: %s", what[i]);
            printf("%-52s %s  (%d of 20 wrong)\n", l, bad[i] ? "FAIL" : "ok", bad[i]); fails += bad[i] != 0;
        }
        noise_m = grip_jit = drop_pct = 0;
    }

    reset(0, 0);
    move(off_h, (float[3]){ -0.30f, 1.30f, -0.42f }, 0.1f, 0.4); hold(0.2); grip(off_h, 1, 0.15); hold(0.2);
    printf("off-hand open reach and grab: %s\n", arms[3] == 1 ? "ok" : "FAIL"); fails += arms[3] != 1;
    reset(0, 0);
    H[off_h].tracked = 0; H[gun_h].grip = 0.1f; w.weapon_drawn = 0; w.gun_fist = 0;
    move(gun_h, (float[3]){ 0.30f, 1.30f, -0.42f }, 0.1f, 0.4); hold(0.2); grip(gun_h, 1, 0.15);
    printf("free gun hand open reach and grab: %s\n", arms[3] == 1 ? "ok" : "FAIL"); fails += arms[3] != 1;
    reset(0, 0);
    move(off_h, (float[3]){ -0.30f, 1.30f, -0.42f }, 0.1f, 0.4); hold(0.2); w.state = HW_EMPTY; grip(off_h, 1, 0.15);
    printf("magazine sequence suppresses grab: %s\n", arms[3] == 0 ? "ok" : "FAIL"); fails += arms[3] != 0;
    reset(0, 0);
    H[off_h].tracked = 0; grip(gun_h, 0.1f, 0.2); hold(0.2); grip(gun_h, 1, 0.15);
    printf("drawn gun hand cannot interact: %s\n", arms[3] == 0 ? "ok" : "FAIL"); fails += arms[3] != 0;
    reset(0, 0);
    move(off_h, (float[3]){ -0.30f, 1.30f, -0.42f }, 0.1f, 0.4); hold(0.2); H[off_h].tracked = 0; step(); H[off_h].tracked = 1; grip(off_h, 1, 0.01); hold(0.2);
    printf("tracking loss disarms full-joint grab: %s\n", arms[3] == 0 ? "ok" : "FAIL"); fails += arms[3] != 0;

    // h72: a forearm supplies a pose when the finger skeleton is unavailable.
    reset(0, 0); H[off_h].tracked = 0;
    { float a[14] = { 1, -.3f, 1.35f, -.2f, -.3f, 1.30f, -.4f }; hand_weapon_set_arms(&w, a); step();
      hand_pose p = w.pose[off_h];
      int ok = p.ok && p.from_arm == 1 && fabsf(p.palm[2] - (-.4f - .07f * .2f / sqrtf(.0425f))) < .001f &&
          fabsf(p.fwd[1]*p.across[1]+p.fwd[2]*p.across[2]) < .001f;
      printf("forearm reconstructs pose: %s\n", ok ? "ok" : "FAIL"); fails += !ok; }
    reset(0, 0); w.mode = HW_MODE_HYBRID; use_trigger = 1; H[gun_h].trig = 1; H[off_h].grip = 1; hold(.15);
    { int ok = !w.trigger; hand_weapon_set_controller(&w, HW_BTN_R_TRIG, t); hold(.1); ok &= w.trigger;
      hand_weapon_set_controller(&w, 0, t); hold(.1); ok &= !w.trigger;
      printf("hybrid trigger uses button: %s\n", ok ? "ok" : "FAIL"); fails += !ok; }
    reset(0, 0); hand_weapon_set_auto_mag(&w, 1); w.ammo_used = 1;
    move(off_h, (float[3]){ -.6f, 1.2f, -.2f }, 0, .4); hold(.1);
    move(gun_h, (float[3]){ .6f, 1.3f, -.4f }, 1, .08); hold(.1);
    expect("fast gun hand with off hand away: no reload", 0, 0, 0, 0, 0, 0);
    reset(0, 0); w.mode = HW_MODE_HYBRID; hand_weapon_set_auto_mag(&w, 1); w.rack = 1;
    move(off_h, WELL, 1, .4); hold(3);
    expect("assisted support hand held still: no reload", 0, 0, 0, 0, 0, 0);
    hand_weapon_set_controller(&w, HW_BTN_L_GRAB, t); step();
    hand_weapon_set_controller(&w, 0, t); hold(.2);
    { float p[3] = { WELL[0], WELL[1] - .12f, WELL[2] }; move(off_h, p, 1, .2); }
    move(off_h, WELL, 1, .2); hold(2.5);
    expect("assisted reload locks out repeated reloads", 1, 1, 1, 1, 1, 0);
    { int ok = w.reload_block && w.well_block; w.shots++; step(); ok &= !w.reload_block;
      printf("firing rearms reload: %s\n", ok ? "ok" : "FAIL"); fails += !ok; }
    reset(0, 0); w.mode = HW_MODE_HYBRID; H[off_h].grip = 1;
    orient(off_h, 1, 0, 0, 0, -1, 0); move(off_h, WELL, 1, .4); hold(.1);
    { float p[3] = { WELL[0], WELL[1] - .20f, WELL[2] + .05f }; move(off_h, p, 1, .3); }
    { float p[3] = { -.15f, 1.0f, -.05f }; move(off_h, p, 1, .4); }
    put_in(); expect("hybrid curled hands: dwell reload", 1, 1, 1, 0, 1, 0);
    reset(0, 0); w.mode = HW_MODE_HYBRID; H[off_h].grip = 1;
    orient(off_h, 1, 0, 0, 0, -1, 0); move(off_h, WELL, 1, .4);
    hand_weapon_set_controller(&w, HW_BTN_L_GRAB, t); step();
    { float p[3] = { WELL[0], WELL[1] - .20f, WELL[2] + .05f }; move(off_h, p, 1, .3); }
    { float p[3] = { -.15f, 1.0f, -.05f }; move(off_h, p, 1, .4); }
    put_in(); expect("hybrid curled hands: button reload", 1, 1, 1, 0, 1, 0);
    reset(0, 0); w.mode = HW_MODE_HYBRID; H[gun_h].grip = 1;
    move(gun_h, HIP_R, 1, .4); hold(.12); move(gun_h, GUN, 1, .4);
    { int ok = arms[0] == 1; printf("hybrid hip dwell draw: %s\n", ok ? "ok" : "FAIL"); fails += !ok; }
    reset(0, 0); w.mode = HW_MODE_HYBRID; H[gun_h].grip = 1;
    move(gun_h, (float[3]){ .2f, 1.5f, .1f }, 1, .4); hold(.12); move(gun_h, GUN, 1, .4);
    { int ok = arms[1] == 1; printf("hybrid shoulder dwell draw: %s\n", ok ? "ok" : "FAIL"); fails += !ok; }
    reset(0, 0); w.mode = HW_MODE_HYBRID; H[off_h].grip = 1;
    move(off_h, (float[3]){ -.3f, 1.3f, -.5f }, 1, .4);
    hand_weapon_set_controller(&w, HW_BTN_L_GRAB, t); step();
    { int ok = arms[3] == 1; printf("hybrid button reach: %s\n", ok ? "ok" : "FAIL"); fails += !ok; }
    reset(0, 0); hand_weapon_set_controller(&w, HW_BTN_R_GRAB, t);
    { int ok = hand_weapon_is_hybrid(&w, t + 1); hand_weapon_set_controller(&w, 0, t + 1);
      ok &= !hand_weapon_is_hybrid(&w, t + 5.1); printf("auto mode expires: %s\n", ok ? "ok" : "FAIL"); fails += !ok; }
    reset(0, 0); w.mode = HW_MODE_HYBRID; w.state = HW_EMPTY; w.state_at = t;
    move(off_h, (float[3]){ -.15f, 1.32f, -.1f }, 1, .2);
    move(off_h, (float[3]){ -.15f, 1.25f, -.1f }, 1, .06);
    H[off_h].tracked = 0; hold(.2);
    { int ok = w.pose[off_h].from_arm == 2 && w.pose[off_h].palm[1] < 1.25f && seen[1] == 1;
      H[off_h].tracked = 1; put_in(); ok &= seen[4] == 1;
      printf("occlusion carries hand to pouch and completes reload: %s\n", ok ? "ok" : "FAIL"); fails += !ok; }
    if (rec) fclose(rec);
    printf(fails ? "%d FAILED\n" : "all passed\n", fails);
    return fails != 0;
}
