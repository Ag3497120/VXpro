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

static int bare_menu_target(const float head[16], const float *hand) {
    if (hand[0] < .5f) return -1;
    float ray[3];
    for (int i = 0; i < 3; i++) ray[i] = hand[7 + i] - head[12 + i];
    float depth = -dot3(ray, head + 8);
    if (depth < .12f) return -1;
    float x = dot3(ray, head) / depth;
    float y = dot3(ray, head + 4) / depth - BH_MENU_CENTER_Y;
    if (fabsf(x) >= BH_MENU_X || fabsf(y) >= BH_MENU_Y) return -1;
    int column = (int)((x + BH_MENU_X) * BH_COLUMNS / (2 * BH_MENU_X));
    int row = (int)((BH_MENU_Y - y) * BH_ROWS / (2 * BH_MENU_Y));
    return row * BH_COLUMNS + column;
}

bare_hand_input bare_hands_update(bare_hands *b, const float head[16], const float hands[20],
                                 const float wrists[20], const float middle[2], double now,
                                 int enabled, int gameplay, int owner, int can_eject, int supporting) {
    bare_hand_input result = { .hover = -1, .action = -1 };
    if (!enabled) { memset(b, 0, sizeof *b); return result; }
    int other = 1 - owner;
    unsigned owner_bit = 1u << owner, other_bit = 1u << other;
    unsigned valid = 0, pinched = 0, previously_blocked = b->require_open;
    for (int h = 0; h < 2; h++) {
        unsigned bit = 1u << h;
        const float *hand = hands + h * 10;
        if (hand[0] < .5f || wrists[h * 10] < .5f) { b->require_open |= bit; b->pinch_at[h] = 0; continue; }
        valid |= bit;
        if (dist3(hand + 1, hand + 4) < (b->pinched & bit ? .034f : .019f)) pinched |= bit;
        else b->require_open &= ~bit;
    }
    if (!b->initialized) {
        b->initialized = 1;
        b->armed = 1;
        b->owner = owner;
        b->require_open |= pinched;
    }
    if (b->owner != owner) {
        b->owner = owner;
        b->require_open |= pinched;
        b->shot_until = 0;
        b->moving = b->shake_direction = 0;
        b->sampled_at = 0;
    }
    if ((b->last_at && now - b->last_at > .20) || (gameplay && !b->gameplay)) {
        b->require_open |= pinched;
        previously_blocked |= b->pinched;
        b->shot_until = b->sampled_at = 0;
        b->moving = b->shake_direction = b->menu = b->chord = 0;
        b->walk_needs_open = 1;
    }
    b->gameplay = gameplay;
    b->last_at = now;
    unsigned pressed = pinched & ~b->pinched & ~b->require_open;
    unsigned released = b->pinched & ~pinched & valid & ~previously_blocked;
    b->pinched = pinched;
    for (int h = 0; h < 2; h++) if (pressed & (1u << h)) b->pinch_at[h] = now;

    if (!pinched && valid == 3) b->chord = 0;
    if (b->chord && (pinched != 3 || valid != 3)) b->chord = 2;
    if (!b->menu && !b->chord && pinched == 3 && !(b->require_open & 3) &&
        fabs(b->pinch_at[0] - b->pinch_at[1]) <= .20) {
        b->gap = dist3(hands + 7, hands + 17);
        if (b->gap <= .40f) {
            b->chord = 1;
            b->chord_at = now;
            b->shot_until = 0;
        }
    }
    if (b->chord == 1) {
        if (now - b->chord_at > 1.0) b->chord = 2;
        else if (dist3(hands + 7, hands + 17) >= b->gap + .16f) {
            b->menu = 1;
            b->ready = 0;
            b->chord = 2;
        }
    }
    if (b->menu) {
        if (!pinched && valid == 3) b->ready = 1;
        if (valid == 0) b->menu = b->ready = 0;
        int target[2] = { valid & 1u ? bare_menu_target(head, hands) : -1,
                          valid & 2u ? bare_menu_target(head, hands + 10) : -1 };
        int cursor = pressed & 2u ? 1 : pressed & 1u ? 0 : target[1] >= 0;
        result.hover = target[cursor];
        if (b->ready && !b->chord && (pressed & (1u << cursor)) && result.hover >= 0) {
            result.action = result.hover;
            b->menu = 0;
            b->require_open |= pinched;
            if (result.action == BH_WEAPON) b->armed = 1;
            if (result.action == BH_HOLSTER) b->armed = 0;
        }
        result.menu = b->menu;
    }
    result.blocked = b->menu || b->chord || result.action >= 0 || !gameplay;
    if (result.blocked) {
        b->shot_until = b->sampled_at = 0;
        b->moving = b->shake_direction = 0;
        return result;
    }

    const float *walk = wrists + other * 10, *gun = wrists + owner * 10;
    if (walk[0] < .5f || middle[other] < 0) b->walk_needs_open = 1;
    else if (middle[other] >= .034f) b->walk_needs_open = 0;
    int walk_pinch = !b->walk_needs_open && middle[other] < (b->moving ? .034f : .019f);
    if (!walk_pinch || (pinched & other_bit)) b->moving = 0;
    else if (!b->moving && walk[2] - head[13] < -.28f && walk[2] - head[13] > -.9f) {
        float n = hypotf(head[0], head[2]);
        if (n > .01f) {
            b->moving = 1;
            memcpy(b->walk_origin, walk + 1, sizeof b->walk_origin);
            b->walk_right[0] = head[0] / n;
            b->walk_right[2] = head[2] / n;
            b->walk_forward[0] = b->walk_right[2];
            b->walk_forward[2] = -b->walk_right[0];
        }
    }
    if (b->moving) {
        float delta[3];
        for (int i = 0; i < 3; i++) delta[i] = walk[1 + i] - b->walk_origin[i];
        float x = dot3(delta, b->walk_right), z = dot3(delta, b->walk_forward);
        if (x > .065f) result.movement |= BH_RIGHT;
        if (x < -.065f) result.movement |= BH_LEFT;
        if (z > .065f) result.movement |= BH_FORWARD;
        if (z < -.065f) result.movement |= BH_BACKWARD;
    }

    if (!(valid & owner_bit) || gun[0] < .5f || !b->armed) b->shot_until = 0;
    else if ((released & owner_bit) && b->pinch_at[owner] > 0 && now - b->pinch_at[owner] >= .04 && now - b->pinch_at[owner] < .20)
        b->shot_until = now + .07;
    if (b->armed && gun[0] > .5f && (valid & owner_bit) && !(b->require_open & owner_bit) &&
        (((pinched & owner_bit) && now - b->pinch_at[owner] >= .20) || now < b->shot_until))
        result.pinches |= owner_bit;
    if (!b->moving && walk[0] > .5f) result.pinches |= pinched & other_bit & ~b->require_open;

    // A deliberate lateral sweep and reversal, measured in the room against
    // a fixed axis, so head movement cannot eject a magazine.
    if (!can_eject || !b->armed || supporting || pinched || !(valid & owner_bit) ||
        (b->shake_done && now - b->shake_done < 1.0)) {
        b->sampled_at = 0;
        b->shake_direction = 0;
        return result;
    }
    double dt = now - b->sampled_at;
    if (b->sampled_at && dt > .001 && dt < .09) {
        if (b->shake_direction && now - b->shake_at > .42) b->shake_direction = 0;
        if (!b->shake_direction) {
            float n = hypotf(head[0], head[2]);
            b->shake_axis[0] = n > .01f ? head[0] / n : 1;
            b->shake_axis[2] = n > .01f ? head[2] / n : 0;
        }
        float position = dot3(gun + 1, b->shake_axis);
        float previous = dot3(b->previous, b->shake_axis);
        float speed = (position - previous) / (float)dt;
        if (!b->shake_direction && fabsf(speed) > 1.45f) {
            b->shake_direction = speed > 0 ? 1 : -1;
            b->shake_at = now;
            b->shake_origin = previous;
            b->shake_peak = position;
        } else if (b->shake_direction) {
            int dir = b->shake_direction;
            if ((position - b->shake_peak) * dir > 0) b->shake_peak = position;
            if ((b->shake_peak - b->shake_origin) * dir >= .09f &&
                (b->shake_peak - position) * dir >= .08f && speed * dir < -1.25f) {
                result.eject = 1;
                b->shake_direction = 0;
                b->shake_done = now;
            }
        }
    } else b->shake_direction = 0;
    memcpy(b->previous, gun + 1, sizeof b->previous);
    b->sampled_at = now;
    return result;
}
