// Hand gestures for the game's actions in vr mode: hand_gestures.h. Plain C, no frameworks, so that
// tests/hand_gestures_mac.c can drive it with recorded or made-up hands on the Mac.
#include "hand_gestures.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static float dot3(const float *a, const float *b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
static float dist3(const float *a, const float *b) { float x = a[0] - b[0], y = a[1] - b[1], z = a[2] - b[2]; return sqrtf(x * x + y * y + z * z); }

// (the thresholds, by name for VXMAC_GESTURE_TUNE and tests/hand_gestures_replay.c; metres, m/s, seconds)
enum { P_PUNCH_SPEED, P_PUNCH_AHEAD, P_CHEST_Y, P_HIP_Y, P_HIP_SIDE, P_RELOAD_S, P_AT_GUN, P_RAISED_Y, P_RAISED_AHEAD,
       P_THROW_SPEED, P_THROW_S, P_MOUTH_R, P_MOUTH_S, P_CD_RELOAD, P_CD_MELEE, P_CD_GRENADE, P_CD_HEAL, P_CD_INTERACT, P_CD_SCAN, P_INTERACT_REACH, P_INTERACT_Y_LO, P_INTERACT_Y_HI, P_INTERACT_OPEN, P_INTERACT_PINCH, P_INTERACT_DWELL, P_TEMPLE_R, P_TEMPLE_S, P_N };
static const char *pname[P_N] = { "punch_speed", "punch_ahead", "chest_y", "hip_y", "hip_side", "reload_s", "at_gun",
    "raised_y", "raised_ahead", "throw_speed", "throw_s", "mouth_r", "mouth_s", "cd_reload", "cd_melee", "cd_grenade", "cd_heal", "cd_interact", "cd_scan", "interact_reach", "interact_y_lo", "interact_y_hi", "interact_open", "interact_pinch", "interact_dwell", "temple_r", "temple_s" };
static float P[P_N] = { 1.4f, 0.10f, -0.35f, -0.42f, 0.45f, 1.5f, 0.25f, -0.05f, 0.25f, 2.0f, 0.8f, 0.13f, 0.4f,
                        1.0f, 0.6f, 1.5f, 2.0f, 0.45f, 1.0f, 0.22f, -0.52f, 0.05f, 0.055f, 0.028f, 0.12f, 0.13f, 0.40f };

int hand_gestures_tune(const char *spec) {
    int n = 0;
    for (const char *s = spec; s && *s; ) {
        const char *eq = strchr(s, '='), *end = strchr(s, ',');
        if (!end) end = s + strlen(s);
        if (eq && eq < end)
            for (int i = 0; i < P_N; i++)
                if ((size_t)(eq - s) == strlen(pname[i]) && !strncmp(s, pname[i], eq - s)) { P[i] = strtof(eq + 1, NULL); n++; }
        s = *end ? end + 1 : end;
    }
    return n;
}
void hand_gestures_params(char *out, unsigned size) {
    unsigned k = 0; out[0] = 0;
    for (int i = 0; i < P_N && k < size; i++) k += snprintf(out + k, size - k, "%s%s=%g", i ? "," : "", pname[i], P[i]);
}

static int fire(hand_gestures *g, int i, double now) {
    if (g->last[i] > 0 && now - g->last[i] < P[P_CD_RELOAD + i]) return 0;
    g->last[i] = now; g->count[i]++;
    return 1 << i;
}

void hand_gestures_arm_pose(float hands[20], int side, const float palm[3], const float across[3]) {
    if (side < 0 || side > 1) return;
    float *v = hands + side * 10; v[0] = 1;
    for (int i = 0; i < 3; i++) {
        v[7+i] = palm[i]; v[1+i] = palm[i] + .04f * across[i]; v[4+i] = palm[i] - .04f * across[i];
    }
}
void hand_gestures_set_controller(hand_gestures *g, int assist, int off_button) { g->assist = assist; g->off_button = off_button; }

int hand_gestures_update(hand_gestures *g, const float head[16], const float hands[20], double now) {
    double dt = g->init ? now - g->t_prev : 0;
    g->t_prev = now;
    // (the body's frame from the head's yaw: forward on the floor, right; the eyes' height for "below" and "above")
    float f[3] = { -head[8], 0, -head[10] }, n = sqrtf(f[0] * f[0] + f[2] * f[2]);
    if (n < 1e-3f) { f[0] = 0; f[2] = -1; n = 1; }
    f[0] /= n; f[2] /= n;
    float r[3] = { -f[2], 0, f[0] }, eye[3] = { head[12], head[13], head[14] };
    int gun = g->lefty ? 0 : 1, off = 1 - gun, out = 0;
    float local[2][3];                  // (x right, y up from the eyes, z forward)
    for (int h = 0; h < 2; h++) {
        const float *H = hands + h * 10;
        if (H[0] < 0.5f) { g->fast[h] = 0; g->mouth_since[h] = 0; continue; }
        const float *a = H + 7;
        float rel[3] = { a[0] - eye[0], a[1] - eye[1], a[2] - eye[2] };
        local[h][0] = dot3(rel, r); local[h][1] = rel[1]; local[h][2] = dot3(rel, f);
        // (velocity: half of each frame's step blended in; a hand that was not tracked starts again from rest)
        if (g->init && dt > 1e-4 && dt < 0.1 && hands[h * 10] > 0.5f && (g->p_prev[h][0] || g->p_prev[h][1] || g->p_prev[h][2]))
            for (int i = 0; i < 3; i++) g->vel[h][i] += ((a[i] - g->p_prev[h][i]) / (float)dt - g->vel[h][i]) * 0.5f;
        else memset(g->vel[h], 0, sizeof g->vel[h]);
        memcpy(g->p_prev[h], a, sizeof g->p_prev[h]);
    }
    for (int h = 0; h < 2; h++) if (hands[h * 10] < 0.5f) memset(g->p_prev[h], 0, sizeof g->p_prev[h]);
    g->init = 1;
    int tr[2] = { hands[0] > 0.5f, hands[10] > 0.5f };

    for (int h = 0; h < 2; h++) {
        if (!tr[h] || local[h][2] <= .12f || local[h][1] <= -.35f || local[h][1] >= .35f) continue;
        float pinch = dist3(hands + h * 10 + 1, hands + h * 10 + 4);
        int gripping = pinch < .04f || (g->assist && h == off && g->off_button);
        if (gripping && fabsf(g->vel[h][1]) > .18f &&
            (g->climb_stroke_at == 0 || h != g->climb_last_hand || now - g->climb_stroke_at > .6)) {
            g->climb_dir = g->vel[h][1] < 0 ? 1 : -1;
            g->climb_until = now + .35; g->climb_last_hand = h; g->climb_stroke_at = now;
        }
    }
    g->climbing = now < g->climb_until;
    if (!g->climbing) g->climb_dir = 0;
    int button_edge = g->assist && g->off_button && !g->prev_off_button;
    g->prev_off_button = g->off_button;
    // melee: the gun hand's forward speed over the threshold for two frames, the hand in front of the body
    if (tr[gun]) {
        float fwd = dot3(g->vel[gun], f);
        g->fast[gun] = fwd > P[P_PUNCH_SPEED] && local[gun][2] > P[P_PUNCH_AHEAD] ? g->fast[gun] + 1 : 0;
        if (g->fast[gun] == 2) out |= fire(g, 1, now);
    }
    // reload: the off hand brought down to the hip, then at the gun hand (or back up to the chest without one) within
    // 1.5 s. (Down from the chest within 1.5 s: an arm resting at the side and raised to hold the gun is not a reload.)
    if (tr[off]) {
        if (local[off][1] > P[P_CHEST_Y]) g->up_at = now;
        if (local[off][1] < P[P_HIP_Y] && fabsf(local[off][0]) < P[P_HIP_SIDE]) { if (g->up_at > 0 && now - g->up_at < P[P_RELOAD_S]) g->hip_at = now; }
        else if (g->hip_at > 0 && now - g->hip_at < P[P_RELOAD_S]) {
            int at_gun = tr[gun] ? dist3(hands + off * 10 + 7, hands + gun * 10 + 7) < P[P_AT_GUN] : local[off][1] > P[P_CHEST_Y] + 0.05f;
            if (at_gun) { g->hip_at = 0; out |= fire(g, 0, now); }
        }
    }
    // grenade: the off hand raised to the head, not ahead of it, then thrown forward within 0.8 s
    if (tr[off]) {
        if (local[off][1] > P[P_RAISED_Y] && local[off][2] < P[P_RAISED_AHEAD]) g->raised_at = now;
        else if (g->raised_at > 0 && now - g->raised_at < P[P_THROW_S] && dot3(g->vel[off], f) > P[P_THROW_SPEED]) { g->raised_at = 0; out |= fire(g, 2, now); }
    }
    // heal: an index finger tip at the mouth (8 cm below the eyes, 6 cm ahead) for 0.4 s
    float mouth[3] = { eye[0] + f[0] * 0.06f, eye[1] - 0.08f, eye[2] + f[2] * 0.06f };
    for (int h = 0; h < 2; h++) {
        if (!tr[h]) continue;
        if (dist3(hands + h * 10 + 4, mouth) < P[P_MOUTH_R]) {
            if (!g->mouth_since[h]) g->mouth_since[h] = now;
            else if (now - g->mouth_since[h] >= P[P_MOUTH_S]) { g->mouth_since[h] = 0; out |= fire(g, 3, now); }
        } else g->mouth_since[h] = 0;
    }
    // Deliberately arm only after an open off hand dwells in front of the body. A lost hand cannot close a grab.
    if (tr[off] && !g->suppress_interact && local[off][2] > P[P_INTERACT_REACH] &&
        local[off][1] > P[P_INTERACT_Y_LO] && local[off][1] < P[P_INTERACT_Y_HI] &&
        (!tr[gun] || dist3(hands + off * 10 + 7, hands + gun * 10 + 7) > 0.22f)) {
        if (button_edge) { out |= fire(g, 4, now); g->reach_ready = 0; g->reach_since = 0; }
        float pinch = dist3(hands + off * 10 + 1, hands + off * 10 + 4);
        if (pinch > P[P_INTERACT_OPEN]) {
            if (!g->reach_since) g->reach_since = now;
            if (now - g->reach_since >= P[P_INTERACT_DWELL]) g->reach_ready = 1;
        } else if (pinch < P[P_INTERACT_PINCH] && g->reach_ready) {
            out |= fire(g, 4, now); g->reach_ready = 0; g->reach_since = 0;
        }
    } else { g->reach_ready = 0; g->reach_since = 0; }
    // The off index at the temple holds the game's scanner until the hand leaves.
    float temple[3] = { eye[0] + r[0] * (off ? 0.12f : -0.12f), eye[1], eye[2] + r[2] * (off ? 0.12f : -0.12f) };
    if (tr[off] && dist3(hands + off * 10 + 4, temple) < P[P_TEMPLE_R]) {
        if (button_edge) { g->scan_button_latched = !g->scan_button_latched; if (g->scan_button_latched) out |= fire(g, 5, now); }
        if (!g->scan_since) g->scan_since = now;
        if (!g->assist && !g->scan_latched && now - g->scan_since >= P[P_TEMPLE_S]) {
            out |= fire(g, 5, now); g->scan_latched = 1;
        }
        g->raised_at = 0;
    } else { g->scan_since = 0; g->scan_latched = 0; }
    return out;
}

const char *hand_gesture_name(int bit) {
    switch (bit) { case HG_RELOAD: return "reload"; case HG_MELEE: return "melee"; case HG_GRENADE: return "grenade"; case HG_HEAL: return "heal"; case HG_INTERACT: return "interact"; case HG_SCAN: return "scan"; }
    return "?";
}
