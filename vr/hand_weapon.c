// A gun's magazine handled by hand in vr mode: hand_weapon.h. Plain C, no frameworks, so that tests/hand_weapon_mac.c
// can drive it with recorded or made-up hands on the Mac.
#include "hand_weapon.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static float dot3(const float *a, const float *b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
static float dist3(const float *a, const float *b) { float x = a[0] - b[0], y = a[1] - b[1], z = a[2] - b[2]; return sqrtf(x * x + y * y + z * z); }
static void sub3(const float *a, const float *b, float *o) { o[0] = a[0] - b[0]; o[1] = a[1] - b[1]; o[2] = a[2] - b[2]; }
static int unit3(float *v) { float n = sqrtf(dot3(v, v)); if (n < 1e-5f) return 0; v[0] /= n; v[1] /= n; v[2] /= n; return 1; }
static float clamp01(float x) { return x < 0 ? 0 : x > 1 ? 1 : x; }

// (the thresholds, by name for VXMAC_MAG_TUNE and tests/hand_weapon_replay.c; metres, m/s, seconds, curl ratios)
enum { P_CURL_OPEN, P_CURL_FIST, P_FIST_ON, P_FIST_OFF, P_GUN_FIST, P_WELL_R, P_PULL, P_PUSH, P_HIP_Y, P_HIP_SIDE,
       P_CHEST_LO, P_CHEST_HI, P_CHEST_SIDE, P_CHEST_AHEAD, P_SLIDE_R, P_RACK_PULL, P_NO_FIST_DOWN, P_STEP_S, P_EMPTY_S,
       P_HOLSTER_Y, P_BACK_Y, P_RAISED_Y, P_RAISED_AHEAD, P_DRAW_S, P_ADS_R, P_ADS_OFF, P_ADS_S, P_TRIG_ON, P_TRIG_OFF,
       P_ARM_CD, P_N };
static const char *pname[P_N] = { "curl_open", "curl_fist", "fist_on", "fist_off", "gun_fist", "well_r", "pull", "push",
    "hip_y", "hip_side", "chest_lo", "chest_hi", "chest_side", "chest_ahead", "slide_r", "rack_pull", "no_fist_down",
    "step_s", "empty_s", "holster_y", "back_y", "raised_y", "raised_ahead", "draw_s", "ads_r", "ads_off", "ads_s",
    "trig_on", "trig_off", "arm_cd" };
static float P[P_N] = { 1.70f, 1.10f, 0.60f, 0.40f, 0.50f, 0.14f, 0.09f, 0.02f, -0.42f, 0.45f,
                        -0.55f, -0.22f, 0.25f, 0.30f, 0.14f, 0.045f, 0.10f, 2.5f, 20.0f,
                        -0.44f, -0.25f, -0.40f, 0.08f, 1.5f, 0.11f, 0.17f, 0.2f, 1.55f, 1.68f, 1.0f };

int hand_weapon_tune(const char *spec) {
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
void hand_weapon_params(char *out, unsigned size) {
    unsigned k = 0; out[0] = 0;
    for (int i = 0; i < P_N && k < size; i++) k += snprintf(out + k, size - k, "%s%s=%g", i ? "," : "", pname[i], P[i]);
}

void hand_pose_from_joints(const float j[HW_JOINTS], hand_pose *p) {
    memset(p, 0, sizeof *p);
    if (j[0] < 0.5f) return;
    const float *pt = j + 1;
    const float *W = pt + HW_WRIST * 3, *IK = pt + HW_INDEX_K * 3, *MK = pt + HW_MIDDLE_K * 3, *LK = pt + HW_LITTLE_K * 3;
    const float *MT = pt + HW_MIDDLE_T * 3, *RT = pt + HW_RING_T * 3, *LT = pt + HW_LITTLE_T * 3;
    for (int i = 0; i < 3; i++) p->palm[i] = (W[i] + MK[i]) * 0.5f;
    sub3(MK, W, p->fwd); sub3(LK, IK, p->across);
    if (dist3(LK, IK) < 0.015f || !unit3(p->fwd) || !unit3(p->across)) return;
    // (a finger's curl: its tip's distance from the wrist over its knuckle's - about 1.9 straight, 0.9 in a fist)
    float km = dist3(MK, W), kl = dist3(LK, W);
    if (km < 0.02f || kl < 0.02f) return;
    float r[3] = { dist3(MT, W) / km, dist3(RT, W) / km, dist3(LT, W) / kl }, g = 0;
    for (int i = 0; i < 3; i++) g += clamp01((P[P_CURL_OPEN] - r[i]) / (P[P_CURL_OPEN] - P[P_CURL_FIST]));
    p->grip = g / 3;
    float ki = dist3(IK, W); p->index = ki > 0.02f ? dist3(pt + HW_INDEX_T * 3, W) / ki : 0;
    p->ok = 1;
}

void hand_weapon_set_auto_mag(hand_weapon *w, int enabled) { w->auto_mag = !!enabled; }
void hand_weapon_set_arms(hand_weapon *w, const float arms[14]) {
    for (int h = 0; h < 2; h++) {
        const float *a = arms + h * 7;
        w->arm_tracked[h] = a[0] > 0.5f;
        memcpy(w->forearm_elbow[h], a + 1, 3 * sizeof(float));
        memcpy(w->forearm_wrist[h], a + 4, 3 * sizeof(float));
    }
}
void hand_weapon_set_controller(hand_weapon *w, unsigned btns, double now) {
    w->ctrl_btns = btns;
    if (btns & ~HW_BTN_ACTIVE) w->ctrl_last_t = now;
}
int hand_weapon_is_hybrid(const hand_weapon *w, double now) {
    return w->mode == HW_MODE_HYBRID || (w->mode == HW_MODE_AUTO &&
        ((w->ctrl_btns & HW_BTN_ACTIVE) || (w->ctrl_last_t > 0 && now >= w->ctrl_last_t && now - w->ctrl_last_t < 5)));
}
static void cross3(const float *a, const float *b, float *o) {
    o[0] = a[1]*b[2]-a[2]*b[1]; o[1] = a[2]*b[0]-a[0]*b[2]; o[2] = a[0]*b[1]-a[1]*b[0];
}
static void prepare_poses(hand_weapon *w, const float head[16], const float *j, double now) {
    if (w->pose_at == now && w->pose_at != 0) return;
    w->pose_at = now;
    float f[3] = { -head[8], 0, -head[10] }; if (!unit3(f)) { f[0]=0; f[2]=-1; }
    float right[3] = { -f[2], 0, f[0] };
    for (int h = 0; h < 2; h++) {
        hand_pose *p = &w->pose[h];
        const float *hj = j + h * HW_JOINTS;
        hand_pose_from_joints(hj, p);
        if (w->arm_tracked[h] && p->ok &&
            dist3(hj + 1 + HW_MIDDLE_T * 3, hj + 1 + HW_RING_T * 3) < .005f &&
            dist3(hj + 1 + HW_MIDDLE_T * 3, hj + 1 + HW_LITTLE_T * 3) < .005f) p->ok = 0;
        float shoulder[3] = { head[12] + right[0] * (h ? .18f : -.18f), head[13] - .18f, head[14] + right[2] * (h ? .18f : -.18f) };
        if (!p->ok && w->arm_tracked[h]) {
            sub3(w->forearm_wrist[h], w->forearm_elbow[h], p->fwd);
            if (unit3(p->fwd)) {
                float up[3] = { 0, 1, 0 };
                cross3(p->fwd, up, p->across);
                if (!unit3(p->across)) { memcpy(p->across, right, sizeof right); float d = dot3(p->across, p->fwd); for (int i=0;i<3;i++) p->across[i] -= d*p->fwd[i]; unit3(p->across); }
                for (int i=0;i<3;i++) p->palm[i] = w->forearm_wrist[h][i] + .07f*p->fwd[i];
                p->grip = w->last_valid_grip[h]; p->index = 1.9f; p->ok = 1; p->from_arm = 1;
            }
        }
        if (p->ok) {
            double dt = now - w->last_valid_t[h];
            if (w->last_valid_t[h] > 0 && dt > 1e-4 && dt < .2) {
                for (int i=0;i<3;i++) w->last_valid_vel[h][i] += .5f*((p->palm[i]-w->last_valid_pos[h][i])/(float)dt-w->last_valid_vel[h][i]);
                float speed = sqrtf(dot3(w->last_valid_vel[h], w->last_valid_vel[h]));
                if (speed > 3.5f) for (int i=0;i<3;i++) w->last_valid_vel[h][i] *= 3.5f/speed;
            } else memset(w->last_valid_vel[h], 0, sizeof w->last_valid_vel[h]);
            memcpy(w->last_valid_pos[h], p->palm, sizeof p->palm); memcpy(w->last_valid_fwd[h], p->fwd, sizeof p->fwd);
            memcpy(w->last_valid_across[h], p->across, sizeof p->across); w->last_valid_grip[h] = p->grip; w->last_valid_t[h] = now;
        } else if (w->last_valid_t[h] > 0 && now >= w->last_valid_t[h] && now - w->last_valid_t[h] <= .35) {
            float dt = (float)(now - w->last_valid_t[h]), d[3];
            for (int i=0;i<3;i++) p->palm[i] = w->last_valid_pos[h][i] + w->last_valid_vel[h][i]*dt*(1-.8f*dt);
            sub3(p->palm, shoulder, d); float len = sqrtf(dot3(d,d));
            if (len > .72f) for (int i=0;i<3;i++) p->palm[i] = shoulder[i] + d[i]*(.72f/len);
            sub3(p->palm, shoulder, p->fwd); if (!unit3(p->fwd)) memcpy(p->fwd, w->last_valid_fwd[h], sizeof p->fwd);
            memcpy(p->across, w->last_valid_across[h], sizeof p->across); p->grip = w->last_valid_grip[h]; p->index = 1.9f; p->ok = 1; p->from_arm = 2;
        }
        w->arm_extrapolated[h] = p->from_arm == 2;
    }
    int gun = w->lefty ? 0 : 1;
    unsigned gb = gun ? HW_BTN_R_GRAB : HW_BTN_L_GRAB;
    unsigned ob = gun ? HW_BTN_L_GRAB : HW_BTN_R_GRAB;
    int g = !!(w->ctrl_btns & gb), o = !!(w->ctrl_btns & ob);
    w->gun_pressed = g && !w->prev_gun_btn; w->gun_released = !g && w->prev_gun_btn;
    w->off_pressed = o && !w->prev_off_btn; w->off_released = !o && w->prev_off_btn;
    w->prev_gun_btn = g; w->prev_off_btn = o;
}

static int set_state(hand_weapon *w, int s, double now) { w->state = s; w->state_at = now; w->near_at = 0; return 0; }
static int ev(hand_weapon *w, int bit) { for (int i = 0; i < HW_EV_N; i++) if (bit & (1 << i)) w->count[i]++; return bit; }

int hand_weapon_update(hand_weapon *w, const float head[16], const float joints[2 * HW_JOINTS], double now) {
    double dt = w->init ? now - w->t_prev : 0;
    w->t_prev = now;
    if (!w->init) { w->init = 1; set_state(w, HW_LOADED, now); }
    // (the body's frame from the head's yaw: forward on the floor, right; the eyes' height for "below")
    float f[3] = { -head[8], 0, -head[10] }; if (!unit3(f)) { f[0] = 0; f[1] = 0; f[2] = -1; }
    float r[3] = { -f[2], 0, f[0] }, eye[3] = { head[12], head[13], head[14] };
    int gun = w->lefty ? 0 : 1, off = 1 - gun, out = 0;
    hand_pose pg, po;
    prepare_poses(w, head, joints, now);
    pg = w->pose[gun]; po = w->pose[off];
    int hybrid = hand_weapon_is_hybrid(w, now);
    // the grip's bottom: past the gun hand's little-finger knuckle along the grip's line when it holds a fist;
    // otherwise below the hand
    // (the gun hand lost for a moment keeps its last grip's bottom for 0.3 s: a magazine half in is not started again)
    w->well_ok = pg.ok || (w->well_at > 0 && now - w->well_at < 0.3);
    if (pg.ok) {
        w->well_at = now;
        const float *LK = joints + gun * HW_JOINTS + 1 + HW_LITTLE_K * 3;
        if (!pg.from_arm && !hybrid && pg.grip >= P[P_GUN_FIST]) {
            for (int i = 0; i < 3; i++) { w->grip_dir[i] = -pg.across[i]; w->well[i] = LK[i] + pg.across[i] * 0.02f; }
        } else if (!pg.from_arm && !hybrid) {
            w->grip_dir[0] = 0; w->grip_dir[1] = 1; w->grip_dir[2] = 0;
            for (int i = 0; i < 3; i++) w->well[i] = pg.palm[i]; w->well[1] -= P[P_NO_FIST_DOWN];
        } else {
            w->grip_dir[0] = 0; w->grip_dir[1] = 1; w->grip_dir[2] = 0;
            float side = gun ? 1.0f : -1.0f;
            for (int i = 0; i < 3; i++) w->well[i] = pg.palm[i] - .05f*r[i]*side + .04f*f[i] - (i == 1 ? .04f : 0);
        }
    }
    if (pg.ok && w->weapon_type != HW_WPN_PISTOL) {
        float forward = w->weapon_type == HW_WPN_RIFLE ? .09f : .12f;
        for (int i = 0; i < 3; i++) w->well[i] = pg.palm[i] + forward * pg.fwd[i] - (i == 1 ? .04f : 0);
        w->grip_dir[0] = 0; w->grip_dir[1] = 1; w->grip_dir[2] = 0;
    }
    // the off hand: its fist (with hysteresis), its palm's velocity
    int was_fist = w->off_fist;
    if (po.ok) w->off_fist = was_fist ? po.grip > P[P_FIST_OFF] : po.grip > P[P_FIST_ON];
    int closed = po.ok && w->off_fist && !was_fist;
    if (po.ok && dt > 1e-4 && dt < 0.1 && (w->off_prev[0] || w->off_prev[1] || w->off_prev[2]))
        for (int i = 0; i < 3; i++) w->off_vel[i] += ((po.palm[i] - w->off_prev[i]) / (float)dt - w->off_vel[i]) * 0.5f;
    else memset(w->off_vel, 0, sizeof w->off_vel);
    if (po.ok) memcpy(w->off_prev, po.palm, sizeof w->off_prev); else memset(w->off_prev, 0, sizeof w->off_prev);
    float dwell = po.ok && w->well_ok ? dist3(po.palm, w->well) : 9;
    w->near_well = dwell < P[P_WELL_R];
    if (w->well_block && !w->reload_block && ((w->auto_mag && po.ok && dist3(po.palm, w->grab_at) >= .05f) ||
        (w->auto_mag && now - w->state_at >= .10) || (!w->auto_mag && dwell >= .26f))) w->well_block = 0;
    if (w->reload_block && ((po.ok && w->well_ok && dwell >= .24f) || w->off_pressed || w->shots != w->reload_shots)) {
        w->reload_block = 0; w->well_block = 0;
    }
    if (dwell >= .32f) w->auto_approach_ready = 1;
    float rel[3] = { 0 }, ly = 0, lx = 0, lz = 0;
    if (po.ok) { sub3(po.palm, eye, rel); lx = dot3(rel, r); ly = rel[1]; lz = dot3(rel, f); }

    // A brief loss of finger tracking alone must not turn a bare-hand reload into an assisted one.
    int assisted = hybrid || po.from_arm == 1 || (po.from_arm == 2 && w->arm_tracked[off]);
    int off_held = w->prev_off_btn;
    float slide[3] = { 0 };
    if (pg.ok) {
        const float *IK = joints + gun * HW_JOINTS + 1 + HW_INDEX_K * 3;
        for (int i = 0; i < 3; i++)
            slide[i] = w->weapon_type == HW_WPN_PISTOL ? (IK[i] + w->grip_dir[i] * .04f) : (pg.palm[i] + (w->weapon_type == HW_WPN_SHOTGUN ? .18f : -.05f) * pg.fwd[i] + (i == 1 ? .045f : 0));
    }
    float d_slide = (pg.ok && po.ok) ? dist3(po.palm, slide) : 9.0f;

    switch (w->state) {
    case HW_LOADED: {
        // 1. Direct left-hand slide cocking / racking (at top of gun, above the magazine well)
        if (pg.ok && po.ok) {
            int at_slide = d_slide < fmaxf(P[P_SLIDE_R], .16f) && po.palm[1] >= pg.palm[1] - .03f;
            if (!w->slide_hold) {
                if (!w->reload_block && at_slide && (w->off_fist || po.grip > .32f || w->off_pressed)) {
                    w->slide_hold = 1; memcpy(w->grab_at, po.palm, sizeof w->grab_at);
                }
            } else {
                float pull_vec[3]; sub3(w->grab_at, po.palm, pull_vec);
                float back = fmaxf(dot3(pull_vec, pg.fwd), dot3(pull_vec, f));
                if (!w->reload_block && back >= .038f && pull_vec[1] > -.06f) {
                    out |= ev(w, HW_EV_RACK | HW_EV_DONE);
                    w->reload_block = w->well_block = 1; w->reload_shots = w->shots;
                    w->state_at = now;
                }
                if (d_slide > .28f || (!assisted && !w->off_fist && po.grip < .22f && !off_held)) {
                    w->slide_hold = 0;
                }
            }
        } else {
            w->slide_hold = 0;
        }
        // 2. Grabbing a fresh magazine directly from hip or chest pouch with left hand
        int hip_pouch = ly < -.30f && fabsf(lx) < P[P_HIP_SIDE];
        int chest_pouch = ly > P[P_CHEST_LO] && ly < P[P_CHEST_HI] && fabsf(lx) < P[P_CHEST_SIDE] && lz > -.05f && lz < P[P_CHEST_AHEAD];
        if (po.ok && (hip_pouch || chest_pouch) && dwell > .24f && (closed || w->off_pressed || (w->off_fist && w->auto_approach_ready))) {
            out |= ev(w, HW_EV_GRAB); set_state(w, HW_HOLD_NEW, now);
            memcpy(w->grab_at, po.palm, sizeof w->grab_at); w->well_block = 0; w->auto_approach_ready = 0; break;
        }
        // 3. Direct magazine approach from below into the magazine well
        if (!w->reload_block && w->auto_mag && w->auto_approach_ready && po.ok && w->well_ok &&
            dwell < .15f && po.palm[1] <= w->well[1] + .03f && w->off_vel[1] > .04f) {
            out |= ev(w, HW_EV_OUT | HW_EV_GRAB); set_state(w, HW_HOLD_NEW, now);
            memcpy(w->grab_at, po.palm, sizeof w->grab_at); w->well_block = 0; w->auto_approach_ready = 0; break;
        }
        float radius = assisted ? fmaxf(P[P_WELL_R], .18f) : P[P_WELL_R];
        if (w->auto_mag && po.ok && w->well_ok && !w->well_block && !w->reload_block &&
            (assisted && w->off_pressed && dwell < radius)) {
            out |= ev(w, HW_EV_OUT | HW_EV_GRAB); set_state(w, HW_HOLD_NEW, now);
            memcpy(w->grab_at, po.palm, sizeof w->grab_at); w->well_block = 1; break;
        }
        // 4. Pulling the old magazine downward out of the grip
        if (po.ok && w->well_ok && !w->well_block && !w->reload_block) {
            float relative[3]; sub3(po.palm, w->well, relative);
            if (!w->pull_ready && dwell < .15f && po.palm[1] <= pg.palm[1] + .01f) {
                memcpy(w->pull_at, relative, sizeof w->pull_at); w->pull_ready = 1;
            }
            if (w->pull_ready && dist3(relative, w->pull_at) >= .07f && relative[1] <= w->pull_at[1] - .045f) {
                set_state(w, HW_HOLD_OLD, now); memcpy(w->grab_at, w->pull_at, sizeof w->grab_at);
                w->pull_ready = 0;
            } else if ((closed || w->off_pressed) && dwell < radius && dot3(relative, w->grip_dir) < .03f) {
                set_state(w, HW_HOLD_OLD, now); memcpy(w->grab_at, relative, sizeof w->grab_at); w->pull_ready = 0;
            } else if (dwell >= .26f) w->pull_ready = 0;
        } else w->pull_ready = 0;
        break;
    }
    case HW_HOLD_OLD: {
        if (!assisted && w->ads) { w->well_block = 1; set_state(w, HW_LOADED, now); break; }
        float relative[3] = { 0 }; if (po.ok && w->well_ok) sub3(po.palm, w->well, relative);
        if (po.ok && w->well_ok && (w->off_pressed || w->off_released || dist3(relative, w->grab_at) >= .06f ||
            (dwell > P[P_PULL] && -dot3(relative, w->grip_dir) > P[P_PULL] * .5f))) {
            out |= ev(w, HW_EV_OUT);
            if (w->auto_mag) { out |= ev(w, HW_EV_GRAB); set_state(w, HW_HOLD_NEW, now);
                memcpy(w->grab_at, po.palm, sizeof w->grab_at); w->well_block = 1; }
            else set_state(w, HW_EMPTY, now);
        } else if (now - w->state_at > P[P_STEP_S] || (po.ok && !w->off_fist && !assisted && !off_held)) set_state(w, HW_LOADED, now);
        break;
    }
    case HW_EMPTY: {
        int hip = ly < -.28f && fabsf(lx) < P[P_HIP_SIDE];
        int chest = ly > P[P_CHEST_LO] && ly < P[P_CHEST_HI] && fabsf(lx) < P[P_CHEST_SIDE] && lz > -.05f && lz < P[P_CHEST_AHEAD];
        if (po.ok && (closed || w->off_pressed || ((w->off_fist || off_held || assisted) && (hip || chest) && dwell > .20f))) {
            out |= ev(w, HW_EV_GRAB); set_state(w, HW_HOLD_NEW, now);
            memcpy(w->grab_at, po.palm, sizeof w->grab_at); w->well_block = 0; break;
        } else if (now - w->state_at > P[P_EMPTY_S]) { out |= ev(w, HW_EV_CANCEL); set_state(w, HW_LOADED, now); }
        break;
    }
    case HW_HOLD_NEW:
        if (po.ok && !w->off_fist && po.grip < .25f && !assisted && !off_held && dwell > .20f && now - w->state_at > .25) {
            set_state(w, HW_EMPTY, now); break;
        }
        if (po.ok && w->well_ok && !w->well_block && dwell < fmaxf(P[P_WELL_R], .20f)) {
            float d[3]; sub3(po.palm, w->well, d);
            float along = dot3(d, w->grip_dir);
            if (!w->near_at) { w->near_at = now; w->in_start = dwell; }
            if (w->in_start - dwell >= .015f || along > .01f || now - w->near_at >= .06 || w->off_pressed || w->off_released) {
                out |= ev(w, HW_EV_IN | HW_EV_DONE);
                w->well_block = w->reload_block = 1; w->ammo_used = 0; w->reload_shots = w->shots;
                memcpy(w->grab_at, po.palm, sizeof w->grab_at);
                if (w->rack) set_state(w, HW_IN_NO_ROUND, now);
                else set_state(w, HW_LOADED, now);
                w->slide_hold = 0; break;
            }
        } else if (po.ok) w->near_at = 0;
        if (now - w->state_at > P[P_EMPTY_S]) { out |= ev(w, HW_EV_CANCEL); set_state(w, HW_LOADED, now); }
        break;
    case HW_IN_NO_ROUND:
        if (pg.ok && po.ok && w->well_ok) {
            if (!w->slide_hold && (d_slide < fmaxf(P[P_SLIDE_R], .20f) || dwell < .22f)) {
                w->slide_hold = 1; memcpy(w->grab_at, po.palm, sizeof w->grab_at);
            }
            if (w->slide_hold) {
                float pull_vec[3]; sub3(w->grab_at, po.palm, pull_vec);
                float back = fmaxf(dot3(pull_vec, pg.fwd), dot3(pull_vec, f));
                if (w->off_pressed || back >= .038f || dist3(po.palm, w->grab_at) >= P[P_RACK_PULL]) {
                    out |= ev(w, HW_EV_RACK | HW_EV_DONE); w->reload_block = w->well_block = 1; w->reload_shots = w->shots; set_state(w, HW_LOADED, now);
                }
            }
            if (now - w->state_at > 3.0) { w->slide_hold = 0; set_state(w, HW_LOADED, now); }
        }
        break;
    }
    // a magazine in the off hand while one is held: along the fist's knuckles, its top at the index finger's side
    w->mag_shown = po.ok && (w->state == HW_HOLD_OLD || w->state == HW_HOLD_NEW);
    if (w->mag_shown) for (int i = 0; i < 3; i++) { w->mag_up[i] = -po.across[i]; w->mag_at[i] = po.palm[i]; }
    return out;
}

static int interact_grab(hand_weapon *w, const float eye[3], const float f[3], const hand_pose *pg, const hand_pose *po, double now) {
    const hand_pose *p[2] = { po, pg };
    int out = 0;
    for (int i = 0; i < 2; i++) {
        float rel[3] = { 0, 0, 0 };
        if (p[i]->ok) sub3(p[i]->palm, eye, rel);
        int safe = p[i]->ok && p[i]->from_arm != 2 && dot3(rel, f) > 0.22f && rel[1] > -0.52f && rel[1] < 0.05f &&
            w->state == HW_LOADED && !w->ads && !w->ads_since && !w->draw_from && !w->in_hip &&
            !(pg->ok && po->ok && dist3(pg->palm, po->palm) < 0.22f) &&
            (i == 0 || !w->weapon_drawn);
        if (!safe) { w->interact_since[i] = 0; w->interact_ready[i] = 0; continue; }
        if (p[i]->grip < P[P_FIST_OFF]) {
            if (!w->interact_since[i]) w->interact_since[i] = now;
            if (now - w->interact_since[i] >= 0.12) w->interact_ready[i] = 1;
        } else if (p[i]->grip > P[P_FIST_ON] && w->interact_ready[i]) {
            if (!w->interact_last || now - w->interact_last >= .45) { out = HW_ARM_INTERACT; w->interact_last = now; }
            w->interact_ready[i] = 0; w->interact_since[i] = 0;
        }
    }
    return out;
}

int hand_weapon_arms(hand_weapon *w, const float head[16], const float joints[2 * HW_JOINTS], double now, int use_trigger) {
    float f[3] = { -head[8], 0, -head[10] }; if (!unit3(f)) { f[0] = 0; f[1] = 0; f[2] = -1; }
    float r[3] = { -f[2], 0, f[0] }, eye[3] = { head[12], head[13], head[14] };
    int gun = w->lefty ? 0 : 1, off = 1 - gun, out = 0;
    float side = gun ? 1 : -1;                            // (the gun's side: +x right for a right hand)
    hand_pose pg, po;
    prepare_poses(w, head, joints, now);
    pg = w->pose[gun]; po = w->pose[off];
    int hybrid = hand_weapon_is_hybrid(w, now);
    // (a hand lost for a moment - a frame or two of tracking - holds the aim and the trigger as they were: no button
    //  let go and pressed again, no extra shot; lost 0.3 s: let go)
    if (pg.ok) w->gun_seen = now;
    if (po.ok) w->off_seen = now;
    if (!pg.ok) {
        if (hybrid && !(w->ctrl_btns & (gun ? HW_BTN_R_TRIG : HW_BTN_L_TRIG))) { w->trigger = 0; w->trig_frames = 0; }
        if (now - w->gun_seen > 0.3) { w->draw_from = 0; w->in_hip = 0; w->ads = 0; w->trigger = 0; w->ads_since = 0; }
        return interact_grab(w, eye, f, &pg, &po, now);
    }
    float rel[3]; sub3(pg.palm, eye, rel);
    float lx = dot3(rel, r) * side, ly = rel[1], lz = dot3(rel, f);
    int was_fist = w->gun_fist;
    w->gun_fist = was_fist ? pg.grip > P[P_FIST_OFF] : pg.grip > P[P_FIST_ON];
    int closed = w->gun_fist && !was_fist, opened = !w->gun_fist && was_fist;
    int raised = lz > P[P_RAISED_AHEAD] && ly > P[P_RAISED_Y];
    if (raised) { w->raised_at = now; if (was_fist) w->weapon_drawn = 1; }
    int hip = lx > 0.03f && lx < P[P_HIP_SIDE] && ly < P[P_HOLSTER_Y] && lz > -0.25f && lz < 0.25f;
    int back = ly > P[P_BACK_Y] && lz < 0.15f && lx > -0.05f && lx < 0.40f;
    #define ARM(bit, i) do { if (!(w->arm_last[i] > 0 && now - w->arm_last[i] < P[P_ARM_CD])) { w->arm_last[i] = now; w->arm_count[i]++; out |= (bit); } } while (0)
    // draw: a fist closed at the hip or the back, then up in front in time
    if ((closed || w->gun_pressed) && (hip || back)) { w->draw_from = hip ? 1 : 2; w->draw_at = now; }
    int zone = hip ? 1 : back ? 2 : 0;
    if ((hybrid || pg.from_arm) && zone) {
        if (zone != w->draw_zone) { w->draw_zone = zone; w->draw_dwell = now; }
        else if (now - w->draw_dwell >= .08 && !w->draw_from) { w->draw_from = zone; w->draw_at = now; }
    } else { w->draw_zone = 0; w->draw_dwell = 0; }
    if (w->draw_from) {
        if ((!w->gun_fist && !hybrid && !pg.from_arm && !w->prev_gun_btn) || now - w->draw_at > ((hybrid || pg.from_arm) ? 1.0f : P[P_DRAW_S])) w->draw_from = 0;
        else if (raised) { if (w->draw_from == 1) ARM(HW_ARM_DRAW_HIP, 0); else ARM(HW_ARM_DRAW_BACK, 1); w->draw_from = 0; }
    }
    // holster: down from in front to the hip with the fist, opened there
    if (hip && !w->in_hip) w->hip_entered_fist = w->gun_fist && w->raised_at > 0 && now - w->raised_at < P[P_DRAW_S];
    w->in_hip = hip;
    if (hip && (opened || w->gun_released) && w->hip_entered_fist) { ARM(HW_ARM_HOLSTER, 2); w->hip_entered_fist = 0; }
    #undef ARM
    if (out & HW_ARM_DRAW_HIP) w->weapon_type = HW_WPN_PISTOL;
    if (out & HW_ARM_DRAW_BACK) w->weapon_type = w->weapon_type == HW_WPN_RIFLE ? HW_WPN_SHOTGUN : HW_WPN_RIFLE;
    if (out & (HW_ARM_DRAW_HIP | HW_ARM_DRAW_BACK)) w->weapon_drawn = 1;
    if (out & HW_ARM_HOLSTER) w->weapon_drawn = 0;
    // aim: the off hand at the gun hand, the gun raised, held; not while a magazine is out
    // (a pistol: the off hand wrapped round the gun hand - at it, and above the grip's bottom, not at the bottom where
    //  a magazine is taken; a rifle: the off hand ahead under the barrel, 12-50 cm ahead of the gun hand, in line)
    //  (above the grip's bottom is asked only to start: held, the hands' distance alone - the grip's line jitters)
    //  (a fist only closed on the grip's bottom - the magazine not yet out - still aims: a support hand's fist there is
    //   common, and its curl jitters)
    int loaded = w->state == HW_LOADED || w->state == HW_HOLD_OLD;
    float dh = 9, dh_hold = 9;
    if (po.ok) {
        float d[3]; sub3(po.palm, pg.palm, d);
        float ahead = dot3(d, f), lat = sqrtf(fmaxf(dot3(d, d) - ahead * ahead, 0));
        float dw[3]; sub3(po.palm, w->well, dw);
        int above = !w->well_ok || dot3(dw, w->grip_dir) > 0.025f;
        dh_hold = dist3(po.palm, pg.palm);
        if (above || hybrid) dh = dh_hold;
        if (ahead > (hybrid ? -0.05f : 0.12f) && ahead < 0.50f && lat < (hybrid ? 0.28f : 0.12f)) { dh = fminf(dh, lat * 0.5f); dh_hold = fminf(dh_hold, lat * 0.5f); }   // (in line ahead: as near)
    }
    if (!w->ads) {
        if (loaded && raised && (dh < (hybrid ? .22f : P[P_ADS_R]) || (hybrid && (w->ctrl_btns & HW_BTN_L_TRIG)))) {
            if (!w->ads_since) w->ads_since = now;
            else if (now - w->ads_since >= P[P_ADS_S]) { w->ads = 1; w->ads_count++; }
        } else w->ads_since = 0;
    } else if (!loaded || !raised || (!(hybrid && (w->ctrl_btns & HW_BTN_L_TRIG)) &&
               (po.ok ? dh_hold > (hybrid ? .28f : P[P_ADS_OFF]) : now - w->off_seen > 0.3))) { w->ads = 0; w->ads_since = 0; }
    // trigger: the index finger curled on a fist, the gun raised
    //  (the finger's measure smoothed - half of each frame blended in - and a change taken after two frames: tracking
    //   jitter of a few millimetres is no shot)
    w->idx_s = w->idx_s > 0 ? w->idx_s + (pg.index - w->idx_s) * 0.5f : pg.index;
    int ctrl_trig = !!(w->ctrl_btns & (gun ? HW_BTN_R_TRIG : HW_BTN_L_TRIG));
    if (!use_trigger) {
        if (ctrl_trig && !w->trigger) { w->shots++; w->ammo_used++; }
        w->trigger = ctrl_trig; w->trig_frames = 0;
    } else {
        int want = use_trigger && w->gun_fist && raised && w->idx_s > 0 && (w->trigger ? w->idx_s < P[P_TRIG_OFF] : w->idx_s < P[P_TRIG_ON]);
        if (hybrid) want = use_trigger && raised && !!(w->ctrl_btns & (gun ? HW_BTN_R_TRIG : HW_BTN_L_TRIG));
        w->trig_frames = want != w->trigger ? w->trig_frames + 1 : 0;
        if (w->trig_frames >= 2 || (!want && !(use_trigger && w->gun_fist && raised))) {
            if (want && !w->trigger) { w->shots++; w->ammo_used++; }
            w->trigger = want; w->trig_frames = 0;
        }
    }
    out |= interact_grab(w, eye, f, &pg, &po, now);
    if (po.ok && (hybrid || po.from_arm) && w->off_pressed) {
        float d[3]; sub3(po.palm, eye, d);
        int reach = dot3(d, f) > .22f && d[1] > -.52f && d[1] < .05f && w->state == HW_LOADED && !w->ads;
        if (reach && (!w->interact_last || now - w->interact_last >= .45)) {
            out |= HW_ARM_INTERACT; w->interact_last = now;
        }
    }
    return out;
}

const char *hand_weapon_event_name(int bit) {
    switch (bit) { case HW_EV_OUT: return "out"; case HW_EV_GRAB: return "grab"; case HW_EV_IN: return "in";
                   case HW_EV_RACK: return "rack"; case HW_EV_DONE: return "done"; case HW_EV_CANCEL: return "cancel"; }
    return "?";
}
const char *hand_weapon_state_name(int s) {
    static const char *n[] = { "loaded", "holding the old magazine", "empty", "holding a new magazine", "in, no round" };
    return s >= 0 && s <= HW_IN_NO_ROUND ? n[s] : "?";
}
