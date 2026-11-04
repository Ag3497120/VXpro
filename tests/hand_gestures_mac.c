// vr/hand_gestures.c driven with made-up hands at 90 Hz: each gesture made once is seen once, and the moves that
// look like them (an arm resting at the side and raised, a slow push, a quick body turn, a short touch at the mouth,
// tracking lost and found elsewhere) are seen as none.
//   clang -O2 -I../vr tests/hand_gestures_mac.c ../vr/hand_gestures.c -o build/hand_gestures_mac && build/hand_gestures_mac
// [record.csv]: also writes every frame as the headset's hand record does (xros_vr.m), for tests/hand_gestures_replay.c.
#include "hand_gestures.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static float head[16];
static float hands[20];
static double t;
static hand_gestures g;
static unsigned seen[HG_N];
static FILE *rec;

static void set_head(float yaw_deg) {                     // (at 1.6 m, turned left by yaw from facing -z)
    float a = yaw_deg * (float)M_PI / 180, c = cosf(a), s = sinf(a);
    memset(head, 0, sizeof head);
    head[0] = c; head[2] = -s; head[5] = 1; head[8] = s; head[10] = c; head[15] = 1;
    head[12] = 0; head[13] = 1.6f; head[14] = 0;
}
static void set_hand(int h, const float p[3]) {           // (the anchor at p, the index tip 8 cm ahead of it, the thumb beside)
    float *H = hands + h * 10;
    H[0] = 1;
    H[1] = p[0] + (h ? -0.03f : 0.03f); H[2] = p[1]; H[3] = p[2] - 0.04f;
    H[4] = p[0]; H[5] = p[1]; H[6] = p[2] - 0.08f;
    H[7] = p[0]; H[8] = p[1]; H[9] = p[2];
}
static float lp[2][3];
static void step(void) {
    int b = hand_gestures_update(&g, head, hands, t);
    if (rec) {
        fprintf(rec, "%.4f,1", t);
        for (int i = 0; i < 16; i++) fprintf(rec, ",%.4f", head[i]);
        for (int i = 0; i < 20; i++) fprintf(rec, ",%.4f", hands[i]);
        fprintf(rec, ",%d\n", b);
    }
    for (int i = 0; i < HG_N; i++) if (b & (1 << i)) seen[i]++;
    t += 1.0 / 90;
}
static void hold(double secs) { for (int i = 0; i < (int)(secs * 90); i++) { set_hand(0, lp[0]); set_hand(1, lp[1]); step(); } }
static void move(int h, const float to[3], double secs) {
    float from[3]; memcpy(from, lp[h], sizeof from);
    int n = (int)(secs * 90);
    for (int i = 1; i <= n; i++) {
        float k = (float)i / n;
        for (int j = 0; j < 3; j++) lp[h][j] = from[j] + (to[j] - from[j]) * k;
        set_hand(0, lp[0]); set_hand(1, lp[1]); step();
    }
}
static const float L_REST[3] = { -0.2f, 1.3f, -0.35f }, R_GUN[3] = { 0.2f, 1.3f, -0.4f };
static double t_next = 100;
static void reset(void) {
    memset(&g, 0, sizeof g); memset(seen, 0, sizeof seen); t = t_next; t_next += 30; set_head(0);
    memcpy(lp[0], L_REST, sizeof lp[0]); memcpy(lp[1], R_GUN, sizeof lp[1]);
    hold(1);
}
static int fails;
static void expect(const char *what, int i, unsigned want) {
    unsigned other = 0; for (int j = 0; j < HG_N; j++) if (j != i) other += seen[j];
    int ok = (i < 0 ? 0 : seen[i]) == want && other == 0;
    if (i < 0) ok = other == 0 && want == 0;
    printf("%-44s %s  (reload %u melee %u grenade %u heal %u)\n", what, ok ? "ok" : "FAIL", seen[0], seen[1], seen[2], seen[3]);
    fails += !ok;
}

int main(int argc, char **argv) {
    if (argc > 1 && !(rec = fopen(argv[1], "w"))) { perror(argv[1]); return 2; }
    reset(); hold(3); expect("idle 3 s: none", -1, 0);

    reset();
    move(0, (float[3]){ -0.2f, 1.0f, -0.1f }, 0.4); move(0, (float[3]){ 0.15f, 1.3f, -0.4f }, 0.5);
    expect("reload: chest -> hip -> gun hand: 1 reload", 0, 1);

    reset();
    move(0, (float[3]){ -0.25f, 0.95f, 0 }, 0.5); hold(3); move(0, (float[3]){ 0.15f, 1.3f, -0.4f }, 0.6);
    expect("arm resting at the side, then raised: none", -1, 0);

    reset();
    move(1, (float[3]){ 0.2f, 1.3f, -0.3f }, 0.3); move(1, (float[3]){ 0.2f, 1.35f, -0.75f }, 0.15);
    expect("punch 3 m/s: 1 melee", 1, 1);

    reset();
    move(1, (float[3]){ 0.2f, 1.3f, -0.3f }, 0.3); move(1, (float[3]){ 0.2f, 1.35f, -0.75f }, 0.6);
    expect("slow push 0.75 m/s: none", -1, 0);

    reset();
    move(0, (float[3]){ -0.2f, 1.65f, -0.05f }, 0.4); hold(0.1); move(0, (float[3]){ -0.2f, 1.6f, -0.6f }, 0.2);
    expect("raise and throw 2.75 m/s: 1 grenade", 2, 1);

    reset();
    move(1, (float[3]){ 0, 1.52f, 0.02f }, 0.4); hold(0.6); move(1, R_GUN, 0.4);
    expect("index finger at the mouth 0.6 s: 1 heal", 3, 1);

    reset();
    move(1, (float[3]){ 0, 1.52f, 0.02f }, 0.4); hold(0.2); move(1, R_GUN, 0.4);
    expect("short touch at the mouth 0.2 s: none", -1, 0);

    reset();                                              // (the body turns 90 degrees in 0.3 s, the hands with it)
    for (int i = 1; i <= 27; i++) {
        float yaw = 90.0f * i / 27, a = yaw * (float)M_PI / 180, c = cosf(a), s = sinf(a);
        set_head(yaw);
        for (int h = 0; h < 2; h++) {
            const float *p0 = h ? R_GUN : L_REST;
            lp[h][0] = p0[0] * c + p0[2] * s; lp[h][1] = p0[1]; lp[h][2] = -p0[0] * s + p0[2] * c;
        }
        set_hand(0, lp[0]); set_hand(1, lp[1]); step();
    }
    hold(0.5);
    expect("body turn 90 deg in 0.3 s: none", -1, 0);

    reset();                                              // (the gun hand lost for 0.5 s, found 60 cm ahead)
    for (int i = 0; i < 45; i++) { set_hand(0, lp[0]); hands[10] = 0; step(); }
    lp[1][2] -= 0.6f; hold(0.5);
    expect("tracking lost, found 60 cm ahead: none", -1, 0);

    reset();                                              // (two punches 0.3 s apart: the cooldown keeps one)
    move(1, (float[3]){ 0.2f, 1.3f, -0.3f }, 0.2); move(1, (float[3]){ 0.2f, 1.35f, -0.75f }, 0.15);
    move(1, (float[3]){ 0.2f, 1.3f, -0.3f }, 0.15); move(1, (float[3]){ 0.2f, 1.35f, -0.75f }, 0.15);
    expect("two punches 0.3 s apart: 1 melee (cooldown)", 1, 1);

    reset(); g.lefty = 1;                                 // (left-handed: the left hand punches)
    move(0, (float[3]){ -0.2f, 1.3f, -0.3f }, 0.2); move(0, (float[3]){ -0.2f, 1.35f, -0.75f }, 0.15);
    expect("lefty: left punch: 1 melee", 1, 1);

    reset();
    move(0, (float[3]){ -0.25f, 1.30f, -0.55f }, 0.4);
    for (int i = 0; i < 20; i++) { set_hand(0, lp[0]); set_hand(1, lp[1]); hands[1] -= 0.08f; step(); }
    for (int i = 0; i < 20; i++) { set_hand(0, lp[0]); set_hand(1, lp[1]); memcpy(hands + 1, hands + 4, 3 * sizeof(float)); step(); }
    expect("open reach then pinch: one interaction", 4, 1);

    reset();
    move(0, (float[3]){ -0.25f, 1.30f, -0.55f }, 0.4);
    for (int i = 0; i < 40; i++) { set_hand(0, lp[0]); set_hand(1, lp[1]); memcpy(hands + 1, hands + 4, 3 * sizeof(float)); step(); }
    expect("closed hand entering reach: none", -1, 0);

    reset(); g.suppress_interact = 1;
    move(0, (float[3]){ -0.25f, 1.30f, -0.55f }, 0.4);
    for (int i = 0; i < 20; i++) { set_hand(0, lp[0]); set_hand(1, lp[1]); hands[1] -= 0.08f; step(); }
    for (int i = 0; i < 20; i++) { set_hand(0, lp[0]); set_hand(1, lp[1]); memcpy(hands + 1, hands + 4, 3 * sizeof(float)); step(); }
    expect("reach suppressed while aiming or reloading", -1, 0);

    reset();
    move(0, (float[3]){ -0.25f, 1.30f, -0.55f }, 0.4);
    for (int i = 0; i < 20; i++) { set_hand(0, lp[0]); set_hand(1, lp[1]); hands[1] -= 0.08f; step(); }
    hands[0] = 0; step();
    for (int i = 0; i < 20; i++) { set_hand(0, lp[0]); set_hand(1, lp[1]); memcpy(hands + 1, hands + 4, 3 * sizeof(float)); step(); }
    expect("tracking loss disarms reach", -1, 0);

    reset();
    move(0, (float[3]){ -0.12f, 1.6f, 0.08f }, 0.5); hold(0.8);
    expect("off index at temple: one scan", 5, 1);

    hand_gestures_tune("interact_reach=0.60");
    reset(); move(0, (float[3]){ -0.25f, 1.30f, -0.50f }, 0.4);
    for (int i = 0; i < 20; i++) { set_hand(0, lp[0]); set_hand(1, lp[1]); hands[1] -= 0.08f; step(); }
    for (int i = 0; i < 20; i++) { set_hand(0, lp[0]); set_hand(1, lp[1]); memcpy(hands + 1, hands + 4, 3 * sizeof(float)); step(); }
    expect("tuned reach excludes closer pinch", -1, 0);
    {
        char params[1024];
        int n = hand_gestures_tune("interact_reach=0.39,interact_y_lo=-0.47,interact_y_hi=-0.07,interact_open=0.056,interact_pinch=0.027,interact_dwell=0.13,temple_r=0.086,temple_s=0.41");
        hand_gestures_params(params, sizeof params);
        int ok = n == 8 && strstr(params, "interact_reach=0.39") && strstr(params, "temple_s=0.41");
        printf("gesture thresholds tune and print: %s\n", ok ? "ok" : "FAIL"); fails += !ok;
        hand_gestures_tune("interact_reach=0.38,interact_y_lo=-0.48,interact_y_hi=-0.08,interact_open=0.055,interact_pinch=0.028,interact_dwell=0.12,temple_r=0.085,temple_s=0.40");
    }

    reset();
    { float palm[3] = { -.25f, 1.3f, -.55f }, across[3] = { 1, 0, 0 };
      hands[0] = 0; hand_gestures_arm_pose(hands, 0, palm, across);
      int ok = hands[0] == 1 && fabsf(hands[7] - palm[0]) < .001f && fabsf(hands[1] - hands[4]) > .07f;
      printf("arm pose supplies gesture anchor: %s\n", ok ? "ok" : "FAIL"); fails += !ok; }
    reset();
    move(0, (float[3]){ -.25f, 1.30f, -.55f }, .4);
    hand_gestures_set_controller(&g, 1, 1); step();
    expect("controller reach assists interaction", 4, 1);
    reset();
    move(0, (float[3]){ -.12f, 1.6f, .08f }, .5);
    hand_gestures_set_controller(&g, 1, 1); step();
    { int ok = g.scan_button_latched; hand_gestures_set_controller(&g, 1, 0); step();
      hand_gestures_set_controller(&g, 1, 1); step(); ok &= !g.scan_button_latched;
      printf("controller temple scan toggles: %s\n", ok ? "ok" : "FAIL"); fails += !ok; }
    if (rec) fclose(rec);
    printf(fails ? "%d FAILED\n" : "all passed\n", fails);
    return fails != 0;
}
