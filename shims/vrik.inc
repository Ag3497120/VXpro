// vrik.inc: V's arms driven by the player's own hands (included by vxpipe.m) - the native counterpart of Cyberpunk
// Universal Hands VR (RED4ext + CET, Windows only), done where visionOS lets us: the bones the GPU skins with.
//
// What the game's vertex shaders do (read from their AIR, h-VRIK): bone i of a skinned draw is a 3x4 matrix at
// <bone buffer> + isd.x + i * isd.y, isd = the per-instance attribute instance_skinning_data0, the bone buffer the
// address in the top-level table (+48) entry 2. A bone matrix S maps the mesh's bind space (model space, Z up) to the
// object's space; the object is placed by instance_transform0..2 (rotation rows; the 4th column an int, camera-relative
// position = (int - camera int) / 2^17, the camera's ints at the view constants +608), and V_camrel at viewc + 384 maps
// that camera-int-relative space into camera view space (+X right, +Y up, +Z forward, origin at the eye).
// What the game's files say (tools/vrik_table.py -> vrik_table.h): bone i of a mesh is its boneNames[i]; the player rigs
// give each bone's parent and bind position, so its arm segment (upper arm / forearm / hand, per side).

#include "vrik_table.h"

typedef struct { float m[12]; } aff;   // (3x4, rows: p' = R p + t, t at m[3], m[7], m[11])
static aff aff_id(void) { aff a = {{1,0,0,0, 0,1,0,0, 0,0,1,0}}; return a; }
static aff aff_mul(aff a, aff b) {     // (a after b)
    aff r;
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) r.m[i*4+j] = a.m[i*4]*b.m[j] + a.m[i*4+1]*b.m[4+j] + a.m[i*4+2]*b.m[8+j];
        r.m[i*4+3] = a.m[i*4]*b.m[3] + a.m[i*4+1]*b.m[7] + a.m[i*4+2]*b.m[11] + a.m[i*4+3];
    }
    return r;
}
static aff aff_inv(aff a) {            // (rigid: R^T, -R^T t)
    aff r;
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) r.m[i*4+j] = a.m[j*4+i];
    for (int i = 0; i < 3; i++) r.m[i*4+3] = -(r.m[i*4]*a.m[3] + r.m[i*4+1]*a.m[7] + r.m[i*4+2]*a.m[11]);
    return r;
}
static void aff_pt(const float *m, const float p[3], float o[3]) { for (int i = 0; i < 3; i++) o[i] = m[i*4]*p[0] + m[i*4+1]*p[1] + m[i*4+2]*p[2] + m[i*4+3]; }
static void aff_dir(const float *m, const float p[3], float o[3]) { for (int i = 0; i < 3; i++) o[i] = m[i*4]*p[0] + m[i*4+1]*p[1] + m[i*4+2]*p[2]; }
static float v3dot(const float *a, const float *b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
static float v3len(const float *a) { return sqrtf(v3dot(a, a)); }
static void v3cross(const float *a, const float *b, float *o) { float t[3] = { a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0] }; memcpy(o, t, sizeof t); }
static int v3norm(float *a) { float l = v3len(a); if (l < 1e-6f) return 0; a[0] /= l; a[1] /= l; a[2] /= l; return 1; }
// (the rotation taking direction a to direction b, shortest arc, about pivot c: 3x4)
static aff aff_arc(const float a_[3], const float b_[3], const float c[3]) {
    float a[3] = { a_[0], a_[1], a_[2] }, b[3] = { b_[0], b_[1], b_[2] };
    aff r = aff_id();
    if (!v3norm(a) || !v3norm(b)) return r;
    float x[3]; v3cross(a, b, x); float s = v3len(x), co = v3dot(a, b);
    if (s < 1e-6f) { if (co > 0) return r; float t[3] = { 1, 0, 0 }; if (fabsf(a[0]) > 0.9f) { t[0] = 0; t[1] = 1; } v3cross(a, t, x); v3norm(x); s = 0; co = -1; }
    else { x[0] /= s; x[1] /= s; x[2] /= s; }
    float ang = atan2f(s, co), sn = sinf(ang), cs = cosf(ang), C = 1 - cs;
    float R[9] = { cs + x[0]*x[0]*C, x[0]*x[1]*C - x[2]*sn, x[0]*x[2]*C + x[1]*sn,
                   x[1]*x[0]*C + x[2]*sn, cs + x[1]*x[1]*C, x[1]*x[2]*C - x[0]*sn,
                   x[2]*x[0]*C - x[1]*sn, x[2]*x[1]*C + x[0]*sn, cs + x[2]*x[2]*C };
    for (int i = 0; i < 3; i++) { for (int j = 0; j < 3; j++) r.m[i*4+j] = R[i*3+j]; r.m[i*4+3] = c[i] - (R[i*3]*c[0] + R[i*3+1]*c[1] + R[i*3+2]*c[2]); }
    return r;
}
// (rotation by angle ang (rad) around unit axis x, about pivot c: 3x4)
static aff aff_rot(const float x_[3], float ang, const float c[3]) {
    float x[3] = { x_[0], x_[1], x_[2] };
    if (!v3norm(x) || fabsf(ang) < 1e-6f) return aff_id();
    float sn = sinf(ang), cs = cosf(ang), C = 1.0f - cs;
    float R[9] = { cs + x[0]*x[0]*C, x[0]*x[1]*C - x[2]*sn, x[0]*x[2]*C + x[1]*sn,
                   x[1]*x[0]*C + x[2]*sn, cs + x[1]*x[1]*C, x[1]*x[2]*C - x[0]*sn,
                   x[2]*x[0]*C - x[1]*sn, x[2]*x[1]*C + x[0]*sn, cs + x[2]*x[2]*C };
    aff r;
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) r.m[i*4+j] = R[i*3+j];
        r.m[i*4+3] = c[i] - (R[i*3]*c[0] + R[i*3+1]*c[1] + R[i*3+2]*c[2]);
    }
    return r;
}

static int vrik_weapon(void) { static int on = -1; if (on < 0) { const char *v = getenv("VXMAC_VRIK_WEAPON"); on = !(v && !strcmp(v, "0")); } return on; }
static int vrik_on(void) { static int on = -1; if (on < 0) { const char *v = getenv("VXMAC_VRIK"); on = !(v && !strcmp(v, "0")); if (on) vxmac_log("VRIK: V's arms follow the hands (bone buffer, two-bone IK; VXMAC_VRIK=0 off)"); } return on; }

// ---- which mesh a draw is: cache by (index buffer, offset, count) ---------------------------------------------------
typedef struct { const void *ib; NSUInteger io, count; int list, rigv; } vrik_mesh;
static vrik_mesh g_vk_mesh[256]; static int g_vk_nmesh; static pthread_mutex_t g_vk_l = PTHREAD_MUTEX_INITIALIZER;
static const float *vrik_bindpos(int rigv, int name) { const float *p = &vrik_bind[rigv][name * 3]; return isnan(p[0]) ? NULL : p; }

// Strict unit-scale rotation check (for rigid joint bones and view matrices)
static int vrik_is_rot(const float *M) {
    for (int r = 0; r < 3; r++) {
        float l2 = M[r*4]*M[r*4] + M[r*4+1]*M[r*4+1] + M[r*4+2]*M[r*4+2];
        if (!(l2 >= 0.90f && l2 <= 1.10f && fabsf(M[r*4+3]) < 10.0f)) return 0;
    }
    if (fabsf(v3dot(M, M + 4)) > 0.05f || fabsf(v3dot(M, M + 8)) > 0.05f || fabsf(v3dot(M + 4, M + 8)) > 0.05f) return 0;
    return 1;
}

// General bone matrix check (allows non-uniformly scaled/sheared muscle bones like *_elbow_bend_A_mscl_JNT while rejecting padding/zeros)
static int vrik_is_bone(const float *M) {
    for (int r = 0; r < 3; r++) {
        float l2 = M[r*4]*M[r*4] + M[r*4+1]*M[r*4+1] + M[r*4+2]*M[r*4+2];
        if (!(l2 >= 0.02f && l2 <= 16.0f && isfinite(M[r*4+3]) && fabsf(M[r*4+3]) < 25.0f)) return 0;
    }
    return 1;
}

// (bones of list L at unmodified palette P agree on their rotational arm/hand joints)
static int vrik_try(const uint8_t *P, uint32_t max_bones, int L, int rigv) {
    uint32_t o = vrik_list_off[L], nb = vrik_list_off[L + 1] - o;
    if (nb > max_bones || nb < 16) return -1;
    int good = 0, has_arm_pose = 0;
    for (uint32_t i = 0; i < nb; i++) {
        int nm = vrik_list[o + i], j = vrik_list_par[o + i];
        const float *A = (const float *)(P + (size_t)i * 48);
        if (!vrik_is_bone(A)) return -1;
        if (vrik_seg[nm] > 0) {
            float t2 = A[3]*A[3] + A[7]*A[7] + A[11]*A[11];
            if (t2 > 0.12f) has_arm_pose = 1;   // V's arm/hand bones pivot ~1.45m above V's feet so |t| >= 0.75m (weapons have |t| < 0.2m)
        }
        if (j < 0) continue;
        const float *B = (const float *)(P + (size_t)j * 48);
        if (!vrik_is_rot(A) || !vrik_is_rot(B)) return -1;
        const float *c = vrik_bindpos(rigv, nm); if (!c) continue;
        float a[3], b[3]; aff_pt(A, c, a); aff_pt(B, c, b);
        float d[3] = { a[0]-b[0], a[1]-b[1], a[2]-b[2] };
        if (!isfinite(d[0]) || v3len(d) > 0.015f) return -1;
        float rd = 0;
        for (int k = 0; k < 12; k++) rd += fabsf(A[k] - B[k]);
        if (rd > 0.02f) good++;
    }
    if (!has_arm_pose || good < 4) return -1;
    return good * 100 + (int)nb;
}

static int vrik_identify(const void *ib, NSUInteger io, NSUInteger count, const uint8_t *orig_P, size_t avail, int *rigv, uint32_t *out_rot) {
    uint32_t rot = 0;
    while ((size_t)(rot + 1) * 48 <= avail && rot < 128 && vrik_is_bone((const float *)(orig_P + (size_t)rot * 48))) rot++;
    if (out_rot) *out_rot = rot;
    for (int i = 0; i < g_vk_nmesh; i++) {
        if (g_vk_mesh[i].ib == ib && g_vk_mesh[i].io == io && g_vk_mesh[i].count == count) {
            *rigv = g_vk_mesh[i].rigv;
            return g_vk_mesh[i].list;
        }
    }
    // Quick O(1) check: if no bone in the first 15 has |t| > 0.35m, this is a weapon/item palette (not V's body rig)
    int can_be_body = 0;
    for (uint32_t k = 0; k < rot && k < 15; k++) {
        const float *M = (const float *)(orig_P + (size_t)k * 48);
        if (M[3]*M[3] + M[7]*M[7] + M[11]*M[11] > 0.12f) { can_be_body = 1; break; }
    }
    int best = -1, bestv = 0, bestg = 0;
    if (can_be_body && rot >= 16) {
        for (int L = 0; L < VRIK_NLISTS; L++) for (int v = 0; v < 2; v++) { int g = vrik_try(orig_P, rot, L, v); if (g > bestg) { bestg = g; best = L; bestv = v; } }
    }
    if (g_vk_nmesh < 256) { vrik_mesh m = { ib, io, count, best, bestv }; g_vk_nmesh++; g_vk_mesh[g_vk_nmesh - 1] = m; }
    if (best >= 0) vxmac_log("VRIK: a foreground mesh (%lu indices, rot=%u) is list %d (%u bones, %s rig, score %d)", (unsigned long)count, rot, best, vrik_list_off[best + 1] - vrik_list_off[best], bestv ? "man" : "woman", bestg);
    else vxmac_log("VRIK: a foreground mesh (%lu indices, rot=%u) is none of V's", (unsigned long)count, rot);
    *rigv = bestv;
    return best;
}

// ---- persistent state: cross-palette arm/hand/finger solver + multi-pass safe palette cache -------------------------
typedef struct { aff orig, mod; int seg; } vrik_known_bone;
typedef struct {
    uint8_t *P;
    uint32_t max_b, nb;
    NSUInteger count;
    int L, applied;
    unsigned stamp;
    aff obj, mod0, modlast;
    aff orig[128];
} vrik_pal;

static struct {
    int have_af[2];   // 1 = true LeftArm/RightArm (SA) + LeftForeArm/RightForeArm (SF) captured
    int have_h[2];    // 1 = true LeftHand/RightHand (SH) captured
    aff SA[2], SF[2], SH[2];
    int rigv;
    aff obj, vcam;
    aff D[7];
    aff D_gun;
    float carry_left, two_hand;
    float curls[2][6];
    float weap[8];
    float slide_pull;
    float r_fwd_obj[3];
    unsigned call_seq;
    vrik_known_bone known[192];
    int nknown;
    vrik_pal pals[128];
    int npals;
} g_vk;

static int vrik_hands(float hf[2][12], int ok[2]) {
    static int (*fn)(float[2][12], int[2]); static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = dlsym(RTLD_DEFAULT, "vx_xros_vr_hand_frames"); });
    return fn ? fn(hf, ok) : 0;
}

static int vrik_hand_curls(float curls[2][6], float weap[8]) {
    static int (*fn)(float[2][6], float[8]); static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = dlsym(RTLD_DEFAULT, "vx_xros_vr_hand_curls"); });
    return fn ? fn(curls, weap) : 0;
}

// (object -> camera-int-relative world, from the instance's transform and the view constants' camera ints)
static int vrik_object(const float itf[12], const uint8_t *viewc, aff *o) {
    int32_t ci[3]; memcpy(ci, viewc + 608, 12);
    for (int r = 0; r < 3; r++) {
        int32_t w; memcpy(&w, &itf[r * 4 + 3], 4);
        for (int c = 0; c < 3; c++) o->m[r*4+c] = itf[r*4+c];
        o->m[r*4+3] = (float)(w - ci[r]) * (1.0f / 131072.0f);
    }
    for (int r = 0; r < 3; r++) { float l = o->m[r*4]*o->m[r*4] + o->m[r*4+1]*o->m[r*4+1] + o->m[r*4+2]*o->m[r*4+2]; if (!(fabsf(l - 1) < 0.05f)) return 0; }
    return 1;
}

static void vrik_solve_all(void) {
    float hf[2][12]; int ok[2] = { 0, 0 };
    vrik_hands(hf, ok);
    memset(g_vk.weap, 0, sizeof g_vk.weap);
    vrik_hand_curls(g_vk.curls, g_vk.weap);
    g_vk.slide_pull = g_vk.weap[0];
    if (!vrik_is_rot(g_vk.vcam.m)) return;
    aff o2v = aff_mul(g_vk.vcam, g_vk.obj);
    aff v2o = aff_inv(o2v);
    int rigv = g_vk.rigv;

    // Temporal smoothing + outlier slew-rate limiting in camera view space (+X right, +Y up, +Z forward)
    static float s_hv[2][3] = { { -0.18f, -0.22f, 0.36f }, { 0.18f, -0.22f, 0.36f } };
    static float s_fv[2][3] = { { 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 1.0f } };
    static float s_ref_fv[2][3] = { { 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 1.0f } };
    static float s_arm_w[2] = { 0.0f, 0.0f };
    static int s_hold_frames[2] = { 0, 0 };
    static int s_init[2] = { 0, 0 };

    // Left-hand carry state (evaluated in camera view space so it is 100% immune to the game's left-hand animations)
    static int s_carry_left = 0, s_release_hold = 0;
    static float s_carry_off_v[3] = { 0.12f, -0.02f, -0.12f };
    float left_grip  = (g_vk.curls[0][2] + g_vk.curls[0][3] + g_vk.curls[0][4]) / 3.0f;
    float right_grip = (g_vk.curls[1][2] + g_vk.curls[1][3] + g_vk.curls[1][4]) / 3.0f;

    for (int side = 0; side < 2; side++) {
        if (ok[side]) {
            // Clamp raw wrist target to comfortable view-space bounds so hands/weapons never plunge into the floor or clip the camera
            float rx = fmaxf(-0.42f, fminf(0.42f, hf[side][0]));
            float ry = fmaxf(-0.34f, fminf(0.20f, hf[side][1]));
            float rz = fmaxf( 0.22f, fminf(0.56f, -hf[side][2]));
            float rf[3] = { hf[side][3], hf[side][4], -hf[side][5] };
            if (!v3norm(rf)) { rf[0] = 0.0f; rf[1] = 0.0f; rf[2] = 1.0f; }
            if (!s_init[side]) {
                s_hv[side][0] = rx; s_hv[side][1] = ry; s_hv[side][2] = rz;
                memcpy(s_fv[side], rf, sizeof rf);
                memcpy(s_ref_fv[side], rf, sizeof rf);
                s_init[side] = 1;
            } else {
                // Slew-rate limit per solve step (absorbs 1-frame ARKit occlusion jumps) + low-pass filter
                float dx = rx - s_hv[side][0], dy = ry - s_hv[side][1], dz = rz - s_hv[side][2];
                float dl = sqrtf(dx*dx + dy*dy + dz*dz);
                if (dl > 0.030f) { float s = 0.030f / dl; dx *= s; dy *= s; dz *= s; }
                s_hv[side][0] += dx * 0.28f;
                s_hv[side][1] += dy * 0.28f;
                s_hv[side][2] += dz * 0.28f;
                for (int i = 0; i < 3; i++) {
                    s_fv[side][i] += (rf[i] - s_fv[side][i]) * 0.22f;
                    s_ref_fv[side][i] += (s_fv[side][i] - s_ref_fv[side][i]) * 0.02f;
                }
                v3norm(s_fv[side]);
                v3norm(s_ref_fv[side]);
            }
            s_hold_frames[side] = 25;
            s_arm_w[side] = fminf(1.0f, s_arm_w[side] + 0.08f);
        } else {
            if (s_hold_frames[side] > 0) s_hold_frames[side]--;
            else s_arm_w[side] = fmaxf(0.0f, s_arm_w[side] - 0.04f);
        }
    }

    // Update left-hand carry state machine in camera view space
    if (s_arm_w[0] > 0.6f && s_arm_w[1] > 0.6f) {
        float dv[3] = { s_hv[0][0] - s_hv[1][0], s_hv[0][1] - s_hv[1][1], s_hv[0][2] - s_hv[1][2] };
        float dist_v = v3len(dv);
        if (!s_carry_left) {
            if (dist_v > 0.08f && dist_v < 0.38f && dv[2] > 0.02f && left_grip >= 0.48f && right_grip < 0.24f) {
                if (++s_release_hold >= 12) {
                    s_carry_left = 1;
                    s_carry_off_v[0] = s_hv[1][0] - s_hv[0][0];
                    s_carry_off_v[1] = s_hv[1][1] - s_hv[0][1];
                    s_carry_off_v[2] = s_hv[1][2] - s_hv[0][2];
                    vxmac_log("VRIK: right hand released -> weapon carried smoothly by left hand");
                }
            } else {
                s_release_hold = 0;
            }
        } else {
            float gun_grip_v[3] = { s_hv[0][0] + s_carry_off_v[0], s_hv[0][1] + s_carry_off_v[1], s_hv[0][2] + s_carry_off_v[2] };
            float re_d[3] = { s_hv[1][0] - gun_grip_v[0], s_hv[1][1] - gun_grip_v[1], s_hv[1][2] - gun_grip_v[2] };
            if ((v3len(re_d) < 0.16f && right_grip >= 0.42f) || left_grip < 0.18f) {
                s_carry_left = 0;
                s_release_hold = 0;
                vxmac_log("VRIK: right hand re-acquired weapon grip");
            }
        }
    } else {
        s_carry_left = 0;
        s_release_hold = 0;
    }

    float T_wrist[2][3] = {{0},{0}};
    int solved[2] = { 0, 0 };

    for (int side = 0; side < 2; side++) {
        if (s_arm_w[side] < 0.01f || !g_vk.have_af[side]) continue;
        int nA = side ? VRIK_RIGHTARM : VRIK_LEFTARM, nF = side ? VRIK_RIGHTFOREARM : VRIK_LEFTFOREARM, nH = side ? VRIK_RIGHTHAND : VRIK_LEFTHAND;
        const float *cA = vrik_bindpos(rigv, nA), *cF = vrik_bindpos(rigv, nF), *cH = vrik_bindpos(rigv, nH);
        if (!cA || !cF || !cH) continue;
        const float *SA = g_vk.SA[side].m, *SF = g_vk.SF[side].m;
        float S[3], E[3], W[3]; aff_pt(SA, cA, S); aff_pt(SF, cF, E); aff_pt(SF, cH, W);
        float Ev[3], Wv[3]; aff_pt(o2v.m, E, Ev); aff_pt(o2v.m, W, Wv);
        float a = 0, b = 0, d3[3];
        for (int i = 0; i < 3; i++) d3[i] = E[i] - S[i]; a = v3len(d3);
        for (int i = 0; i < 3; i++) d3[i] = W[i] - E[i]; b = v3len(d3);
        if (v3len(Ev) > 0.95f || a < 0.15f || a > 0.45f || b < 0.15f || b > 0.45f) continue;

        // Blend smoothly in view space between the game's animated wrist Wv and the damped VR wrist s_hv[side]
        // (Use damped relative motion around a gentle anchor so game animations and VR hand tracking never fight)
        float anchor_v[3] = { side ? 0.16f : -0.16f, -0.22f, 0.36f };
        float delta_v[3] = {
            fmaxf(-0.22f, fminf(0.22f, (s_hv[side][0] - anchor_v[0]) * 0.75f)),
            fmaxf(-0.18f, fminf(0.18f, (s_hv[side][1] - anchor_v[1]) * 0.75f)),
            fmaxf(-0.14f, fminf(0.14f, (s_hv[side][2] - anchor_v[2]) * 0.70f))
        };
        float target_v[3] = {
            Wv[0] + delta_v[0] * s_arm_w[side],
            Wv[1] + delta_v[1] * s_arm_w[side],
            fmaxf(0.18f, Wv[2] + delta_v[2] * s_arm_w[side])
        };
        float T[3];
        aff_pt(v2o.m, target_v, T);
        float u[3] = { T[0]-S[0], T[1]-S[1], T[2]-S[2] }; float d = v3len(u);
        if (d < 1e-3f) continue;
        v3norm(u);
        float dc = fmaxf(fabsf(a - b) + 0.01f, fminf(a + b - 0.002f, d));
        // Anatomical elbow pole direction in camera view space: downward (-Y), outward to own side (±X), slightly back (-Z)
        float pv[3] = { side ? 0.60f : -0.60f, -1.0f, -0.35f }, n[3];
        aff_dir(v2o.m, pv, n);
        float k = v3dot(n, u); for (int i = 0; i < 3; i++) n[i] -= k * u[i];
        if (!v3norm(n)) { float fb_v[3] = { 0.0f, 0.0f, -1.0f }; aff_dir(v2o.m, fb_v, n); k = v3dot(n, u); for (int i = 0; i < 3; i++) n[i] -= k * u[i]; v3norm(n); }
        float ca = (a*a + dc*dc - b*b) / (2*a*dc); ca = fmaxf(-1, fminf(1, ca)); float sa = sqrtf(1 - ca*ca);
        float E2[3], Tc[3]; for (int i = 0; i < 3; i++) { E2[i] = S[i] + a * (ca * u[i] + sa * n[i]); Tc[i] = S[i] + dc * u[i]; }
        float e0[3] = { E[0]-S[0], E[1]-S[1], E[2]-S[2] }, e1[3] = { E2[0]-S[0], E2[1]-S[1], E2[2]-S[2] };
        aff D1 = aff_arc(e0, e1, S);
        float W1[3]; aff_pt(D1.m, W, W1);
        float f0[3] = { W1[0]-E2[0], W1[1]-E2[1], W1[2]-E2[2] }, f1[3] = { Tc[0]-E2[0], Tc[1]-E2[1], Tc[2]-E2[2] };
        aff D2 = aff_mul(aff_arc(f0, f1, E2), D1);

        // Preserve the game's seamless forearm-to-hand wrist alignment (D2) and add only a gentle, bounded relative wrist tilt
        // (max ~15 deg) so the wrist crease can NEVER twist/mangle and the weapon always aims naturally forward!
        float ref_obj[3], cur_obj[3], blend_obj[3];
        aff_dir(v2o.m, s_ref_fv[side], ref_obj);
        aff_dir(v2o.m, s_fv[side], cur_obj);
        v3norm(ref_obj); v3norm(cur_obj);
        float tilt_w = 0.35f * s_arm_w[side];
        for (int i = 0; i < 3; i++) blend_obj[i] = ref_obj[i] + (cur_obj[i] - ref_obj[i]) * tilt_w;
        v3norm(blend_obj);
        // Clamp maximum angular deviation from ref_obj so knuckle occlusion can never flip the wrist
        if (v3dot(ref_obj, blend_obj) < 0.96f) {
            for (int i = 0; i < 3; i++) blend_obj[i] = ref_obj[i] * 0.80f + blend_obj[i] * 0.20f;
            v3norm(blend_obj);
        }
        aff D3 = aff_mul(aff_arc(ref_obj, blend_obj, Tc), D2);
        if (side == 1) memcpy(g_vk.r_fwd_obj, cur_obj, sizeof cur_obj);
        memcpy(T_wrist[side], Tc, sizeof Tc);
        solved[side] = 1;
        g_vk.D[side ? 4 : 1] = D1; g_vk.D[side ? 5 : 2] = D2; g_vk.D[side ? 6 : 3] = D3;
        static atomic_uint logged; if (atomic_fetch_add(&logged, 1) % 300 == 0)
            vxmac_log("VRIK: %s arm solved (hand=%d): shoulder (%.2f %.2f %.2f) elbow (%.2f %.2f %.2f)->(%.2f %.2f %.2f) wrist (%.2f %.2f %.2f)->(%.2f %.2f %.2f) reach %.2f/%.2f",
                      side ? "right" : "left", g_vk.have_h[side], S[0], S[1], S[2], E[0], E[1], E[2], E2[0], E2[1], E2[2], W[0], W[1], W[2], T[0], T[1], T[2], d, a + b);
    }

    // Weapon transform (D_gun): normally follows the right hand (D[6]); in left-hand carry mode, translates smoothly with the left hand in view space
    aff D_gun = g_vk.D[6];
    if (s_carry_left && solved[0] && solved[1]) {
        float carry_dv[3] = {
            (s_hv[0][0] + s_carry_off_v[0] - s_hv[1][0]) * 0.75f,
            (s_hv[0][1] + s_carry_off_v[1] - s_hv[1][1]) * 0.75f,
            (s_hv[0][2] + s_carry_off_v[2] - s_hv[1][2]) * 0.70f
        };
        float carry_do[3];
        aff_dir(v2o.m, carry_dv, carry_do);
        D_gun.m[3]  += carry_do[0];
        D_gun.m[7]  += carry_do[1];
        D_gun.m[11] += carry_do[2];
    }
    g_vk.carry_left = s_carry_left ? 1.0f : 0.0f;
    g_vk.two_hand   = (solved[0] && solved[1] && left_grip >= 0.40f) ? 1.0f : 0.0f;
    g_vk.D_gun      = D_gun;
}

static int vrik_same_bone(const aff *a, const aff *b) {
    for (int i = 0; i < 12; i++) if (fabsf(a->m[i] - b->m[i]) > 1e-4f) return 0;
    return 1;
}

static void vrik_record_known(const aff *orig, const aff *mod, int seg) {
    for (int m = 0; m < g_vk.nknown; m++) {
        if (vrik_same_bone(&g_vk.known[m].orig, orig)) {
            g_vk.known[m].mod = *mod;
            g_vk.known[m].seg = seg;
            return;
        }
    }
    if (g_vk.nknown < 192) {
        g_vk.known[g_vk.nknown].orig = *orig;
        g_vk.known[g_vk.nknown].mod = *mod;
        g_vk.known[g_vk.nknown].seg = seg;
        g_vk.nknown++;
    }
}

// Gentle finger curl ONLY when the right hand is released from the weapon (s_carry_left > 0);
// when holding weapons, preserve the game's sculpted finger grip poses 100% intact so hands never deform!
static void vrik_finger_deltas(int side, const vrik_pal *pal, uint32_t o, aff M_out[128]) {
    for (uint32_t k = 0; k < pal->nb; k++) M_out[k] = aff_id();
    if (side != 1 || g_vk.carry_left < 0.5f || !g_vk.have_h[1]) return;
    int rigv = g_vk.rigv;
    const float *cH = vrik_bindpos(rigv, VRIK_RIGHTHAND);
    const float *cM = vrik_bindpos(rigv, VRIK_RIGHTHANDMIDDLE1);
    const float *cI = vrik_bindpos(rigv, VRIK_RIGHTHANDINDEX1);
    const float *cP = vrik_bindpos(rigv, VRIK_RIGHTHANDPINKY1);
    if (!cH || !cM || !cI || !cP) return;

    float fb[3], ab[3];
    for (int i = 0; i < 3; i++) { fb[i] = cM[i] - cH[i]; ab[i] = cI[i] - cP[i]; }
    if (!v3norm(fb)) return;
    float t = v3dot(ab, fb); for (int i = 0; i < 3; i++) ab[i] -= t * fb[i];
    if (!v3norm(ab)) return;
    float ax_curl[3];
    aff_dir(g_vk.SH[1].m, ab, ax_curl);
    if (!v3norm(ax_curl)) return;

    static const int f_jnt[4][3] = {
        { 107, 109, 111 }, { 116, 118, 120 }, { 134, 136, 138 }, { 125, 127, 129 }
    };
    for (int f = 0; f < 4; f++) {
        int b1 = -1, b2 = -1, b3 = -1;
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_list[o + k];
            if (nm == f_jnt[f][0]) b1 = (int)k;
            else if (nm == f_jnt[f][1]) b2 = (int)k;
            else if (nm == f_jnt[f][2]) b3 = (int)k;
        }
        if (b1 < 0) continue;
        const float *c1 = vrik_bindpos(rigv, f_jnt[f][0]);
        if (!c1) continue;
        float d = fmaxf(-0.35f, fminf(0.35f, (g_vk.curls[1][1 + f] - 0.55f) * 0.55f));
        float p1[3]; aff_pt(pal->orig[b1].m, c1, p1);
        aff M1 = aff_rot(ax_curl, d, p1);
        M_out[b1] = M1;
        if (b2 >= 0) {
            const float *c2 = vrik_bindpos(rigv, f_jnt[f][1]);
            if (c2) {
                float p2[3], p2m[3]; aff_pt(pal->orig[b2].m, c2, p2); aff_pt(M1.m, p2, p2m);
                aff M2 = aff_mul(aff_rot(ax_curl, d, p2m), M1);
                M_out[b2] = M2;
                if (b3 >= 0) M_out[b3] = M2;
            }
        }
    }
}

static void vrik_apply_pal(vrik_pal *pal) {
    if ((!g_vk.have_af[0] && !g_vk.have_af[1]) || pal->nb == 0) return;
    if (pal->L >= 0) {
        uint32_t o = vrik_list_off[pal->L];
        int has_r_fng = 0;
        if (g_vk.carry_left >= 0.5f) {
            for (uint32_t k = 0; k < pal->nb; k++) if (vrik_list[o + k] == VRIK_RIGHTHANDINDEX1) { has_r_fng = 1; break; }
        }
        aff M_fng[128];
        if (has_r_fng) vrik_finger_deltas(1, pal, o, M_fng);
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_list[o + k], s = vrik_seg[nm];
            aff *dst = (aff *)(pal->P + (size_t)k * 48);
            if (s == 6 && has_r_fng) {
                *dst = aff_mul(g_vk.D[6], aff_mul(M_fng[k], pal->orig[k]));
            } else {
                *dst = (s > 0) ? aff_mul(g_vk.D[s], pal->orig[k]) : pal->orig[k];
            }
            if (s > 0) vrik_record_known(&pal->orig[k], dst, s);
        }
        pal->mod0 = ((const aff *)pal->P)[0];
        pal->modlast = ((const aff *)pal->P)[pal->nb - 1];
        pal->applied = 1;
        return;
    }
    // Check if this palette shares exact bone matrices with V's arm/hand/finger palettes (e.g. fingernails 5916, palm cyberware 3918)
    int matched_known = 0, fallback_seg = 0;
    for (uint32_t k = 0; k < pal->nb; k++) {
        for (int m = 0; m < g_vk.nknown; m++) {
            if (vrik_same_bone(&g_vk.known[m].orig, &pal->orig[k])) {
                if (!fallback_seg) fallback_seg = g_vk.known[m].seg;
                matched_known++;
                break;
            }
        }
    }
    if (matched_known >= 2) {
        int cur_seg = fallback_seg;
        for (uint32_t k = 0; k < pal->nb; k++) {
            int exact = -1;
            for (int m = 0; m < g_vk.nknown; m++) {
                if (vrik_same_bone(&g_vk.known[m].orig, &pal->orig[k])) { exact = m; cur_seg = g_vk.known[m].seg; break; }
            }
            aff *dst = (aff *)(pal->P + (size_t)k * 48);
            if (exact >= 0) *dst = g_vk.known[exact].mod;
            else *dst = (cur_seg > 0) ? aff_mul(g_vk.D[cur_seg], pal->orig[k]) : pal->orig[k];
        }
        pal->mod0 = ((const aff *)pal->P)[0];
        pal->modlast = ((const aff *)pal->P)[pal->nb - 1];
        pal->applied = 1;
        return;
    }
    // Foreground weapon / attachment mesh: must have its instance origin near the camera (< 0.85m) and distinct from V's body origin at the feet (> 0.50m)
    if (g_vk.have_af[1] && vrik_weapon()) {
        float db[3] = { pal->obj.m[3] - g_vk.obj.m[3], pal->obj.m[7] - g_vk.obj.m[7], pal->obj.m[11] - g_vk.obj.m[11] };
        if (v3len(db) < 0.50f) return;
        aff o2v = aff_mul(g_vk.vcam, pal->obj);
        float wpos[3] = { o2v.m[3], o2v.m[7], o2v.m[11] };
        if (v3len(wpos) < 0.85f) {
            // Apply one unified rigid transform D_weap_gun to every bone of every weapon sub-mesh so multi-part weapons never split apart
            aff inv_pobj = aff_inv(pal->obj);
            aff Dw_gun = aff_mul(g_vk.obj, aff_mul(g_vk.D_gun, aff_inv(g_vk.obj)));
            aff D_weap_gun = aff_mul(inv_pobj, aff_mul(Dw_gun, pal->obj));
            for (uint32_t k = 0; k < pal->nb; k++) {
                aff *dst = (aff *)(pal->P + (size_t)k * 48);
                *dst = aff_mul(D_weap_gun, pal->orig[k]);
            }
            pal->mod0 = ((const aff *)pal->P)[0];
            pal->modlast = ((const aff *)pal->P)[pal->nb - 1];
            pal->applied = 1;
        }
    }
}

// (a draw's per-instance data: the skinning attribute and the instance's transform)
static int vrik_instance(VXEncVM *vm, NSArray *isd_i, NSUInteger bi, uint32_t isd[4], float itf[12]) {
    NSUInteger bidx = [isd_i[0] unsignedIntegerValue], aoff = [isd_i[1] unsignedIntegerValue], lst = [isd_i[2] unsignedIntegerValue], step = [isd_i[3] unsignedIntegerValue], rate = [isd_i[4] unsignedIntegerValue]; NSInteger it0 = [isd_i[6] integerValue];
    if (bidx >= 31 || it0 < 0) return 0;
    if (lst == MTLBufferLayoutStrideDynamic) lst = vm->vst[bidx];
    NSUInteger el = step == MTLVertexStepFunctionPerInstance ? bi / (rate ? rate : 1) : 0;
    const uint8_t *ip = NULL; size_t ia = 0;
    NSData *bd = vm->vbytes[@(bidx)];
    if (bd) { ip = bd.bytes; ia = bd.length; } else if (vm->vbuf[bidx]) { id<MTLBuffer> b = vm->vbuf[bidx]; if (b.storageMode == MTLStorageModeShared && vm->voff[bidx] < b.length) { ip = (const uint8_t *)b.contents + vm->voff[bidx]; ia = b.length - vm->voff[bidx]; } }
    if (!ip || el * lst + aoff + 16 > ia || el * lst + (size_t)it0 + 48 > ia) return 0;
    memcpy(isd, ip + el * lst + aoff, 16); memcpy(itf, ip + el * lst + it0, 48);
    return 1;
}

static void vrik_apply(id e, NSUInteger count, NSUInteger bi, id ib, NSUInteger io) {
    if (!vrik_on()) return;
    VXEncVM *vm = objc_getAssociatedObject(e, kEncVM);
    if (!vm || !vm->vp_fg || !vm->pipe) return;
    NSArray *isd_i = objc_getAssociatedObject(vm->pipe, kISD); if (!isd_i) return;
    uint32_t isd[4]; float itf[12];
    if (!vrik_instance(vm, isd_i, bi, isd, itf) || isd[1] != 48) return;
    const uint8_t *tl = NULL; size_t n = 0;
    if (vm->bytes) { tl = vm->bytes.bytes; n = vm->bytes.length; }
    else if (vm->original && vm->original.storageMode == MTLStorageModeShared && vm->offset < vm->original.length) { tl = (const uint8_t *)vm->original.contents + vm->offset; n = vm->original.length - vm->offset; }
    if (!tl || n < 56) return;
    pthread_mutex_lock(&g_brl);
    uint64_t ta, av, base; memcpy(&ta, tl + 48, 8); const uint8_t *t = buf_at(ta, &av, &base); uint8_t *P = NULL; size_t pav = 0; const uint8_t *viewc = NULL;
    if (t && av >= 72) { uint64_t ba; memcpy(&ba, t + 48, 8); const uint8_t *bb = buf_at(ba, &av, &base); if (bb && isd[0] < av) { P = (uint8_t *)bb + isd[0]; pav = av - isd[0]; } }
    { uint64_t da; memcpy(&da, tl, 8); const uint8_t *d = buf_at(da, &av, &base); if (d && av >= 32) { uint64_t ca; memcpy(&ca, d + 24, 8); const uint8_t *c = buf_at(ca, &av, &base); if (c && av >= 640) viewc = c; } }
    pthread_mutex_unlock(&g_brl);
    if (!P || !viewc || pav < 48) return;
    aff obj; if (!vrik_object(itf, viewc, &obj)) return;
    aff vcam = *(const aff *)(viewc + 384);
    if (!vrik_is_rot(vcam.m)) return;

    pthread_mutex_lock(&g_vk_l);
    unsigned seq = ++g_vk.call_seq;
    uint32_t max_b = (uint32_t)(pav / 48);
    if (max_b > 128) max_b = 128;

    // Look up P in the persistent multi-pass palette cache (never wiped on setViewport toggles or secondary encoders)
    vrik_pal *pal = NULL;
    for (int i = 0; i < g_vk.npals; i++) {
        if (g_vk.pals[i].P == P) { pal = &g_vk.pals[i]; break; }
    }
    if (!pal) {
        if (g_vk.npals < 128) {
            pal = &g_vk.pals[g_vk.npals++];
        } else {
            int oldest = 0;
            for (int i = 1; i < 128; i++) if (g_vk.pals[i].stamp < g_vk.pals[oldest].stamp) oldest = i;
            pal = &g_vk.pals[oldest];
        }
        memset(pal, 0, sizeof *pal);
        pal->P = P; pal->max_b = max_b; pal->L = -2;
        memcpy(pal->orig, P, (size_t)max_b * 48);
    } else {
        // Check if P still holds VRIK's modified output from an earlier pass/batch of the SAME frame.
        // Only snapshot P into pal->orig when the game CPU has written fresh unmodified matrices into P!
        int still_modified = (pal->applied && pal->nb > 0 && pal->nb <= max_b &&
                              vrik_same_bone((const aff *)P, &pal->mod0) &&
                              vrik_same_bone((const aff *)(P + (size_t)(pal->nb - 1) * 48), &pal->modlast));
        if (!still_modified) {
            pal->max_b = max_b;
            memcpy(pal->orig, P, (size_t)max_b * 48);
            pal->applied = 0;
        } else if (max_b > pal->max_b) {
            memcpy(pal->orig + pal->max_b, P + (size_t)pal->max_b * 48, (size_t)(max_b - pal->max_b) * 48);
            pal->max_b = max_b;
        }
    }
    pal->stamp = seq;
    pal->obj = obj;
    pal->count = count;

    // Always identify using the guaranteed-unmodified pal->orig matrices, never modified P
    uint32_t rot = 0;
    int rigv = 0, L = vrik_identify((__bridge const void *)ib, io, count, (const uint8_t *)pal->orig, (size_t)pal->max_b * 48, &rigv, &rot);

    int state_changed = 0;
    if (L >= 0) {
        uint32_t o = vrik_list_off[L], nb = vrik_list_off[L + 1] - o;
        if (nb > 128) nb = 128;
        if (nb <= pal->max_b) {
            aff o2v = aff_mul(vcam, obj);
            int near_cam = 0;
            for (uint32_t k = 0; k < nb; k++) {
                int nm = vrik_list[o + k]; if (vrik_seg[nm] <= 0) continue;
                const float *c = vrik_bindpos(rigv, nm); if (!c) continue;
                float pt[3], pv[3]; aff_pt(pal->orig[k].m, c, pt); aff_pt(o2v.m, pt, pv);
                if (v3len(pv) < 1.0f) { near_cam = 1; break; }
            }
            if (near_cam) {
                if (pal->L < 0 || nb > pal->nb || !pal->applied) {
                    pal->L = L; pal->nb = nb;
                    state_changed = 1;
                }
                g_vk.rigv = rigv; g_vk.obj = obj; g_vk.vcam = vcam;
                #define BONE(nm) ({ int _b = -1; for (uint32_t _k = 0; _k < nb; _k++) if (vrik_list[o + _k] == (nm)) { _b = (int)_k; break; } _b; })
                for (int side = 0; side < 2; side++) {
                    int bA = BONE(side ? VRIK_RIGHTARM : VRIK_LEFTARM);
                    int bF = BONE(side ? VRIK_RIGHTFOREARM : VRIK_LEFTFOREARM);
                    int bH = BONE(side ? VRIK_RIGHTHAND : VRIK_LEFTHAND);
                    if (bA >= 0 && bF >= 0) {
                        if (!g_vk.have_af[side] || !vrik_same_bone(&g_vk.SA[side], &pal->orig[bA]) || !vrik_same_bone(&g_vk.SF[side], &pal->orig[bF])) {
                            g_vk.SA[side] = pal->orig[bA]; g_vk.SF[side] = pal->orig[bF];
                            g_vk.have_af[side] = 1; state_changed = 1;
                        }
                    }
                    if (bH >= 0) {
                        if (!g_vk.have_h[side] || !vrik_same_bone(&g_vk.SH[side], &pal->orig[bH])) {
                            g_vk.SH[side] = pal->orig[bH];
                            g_vk.have_h[side] = 1; state_changed = 1;
                        }
                    }
                }
                #undef BONE
            }
        }
    } else {
        pal->L = -1;
        pal->nb = rot > pal->max_b ? pal->max_b : rot;
    }

    if (state_changed) {
        g_vk.nknown = 0;
        vrik_solve_all();
        // Re-apply cleanly from unmodified pal->orig to all active palettes seen recently
        for (int i = 0; i < g_vk.npals; i++) {
            if (seq - g_vk.pals[i].stamp < 64 && g_vk.pals[i].L >= 0) vrik_apply_pal(&g_vk.pals[i]);
        }
        for (int i = 0; i < g_vk.npals; i++) {
            if (seq - g_vk.pals[i].stamp < 64 && g_vk.pals[i].L < 0) vrik_apply_pal(&g_vk.pals[i]);
        }
    } else if (!pal->applied) {
        vrik_apply_pal(pal);
    }
    pthread_mutex_unlock(&g_vk_l);
}
