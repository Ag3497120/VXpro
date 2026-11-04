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

// ---- which mesh a draw is: cache by (index buffer, offset, count, skinning offset isd0) ----------------------------
typedef struct { const void *ib; NSUInteger io, count; uint32_t isd0; int list, rigv; } vrik_mesh;
static vrik_mesh g_vk_mesh[256]; static int g_vk_nmesh; static pthread_mutex_t g_vk_l = PTHREAD_MUTEX_INITIALIZER;
static const float *vrik_bindpos(int rigv, int name) { const float *p = &vrik_bind[rigv][name * 3]; return isnan(p[0]) ? NULL : p; }

// Strict unit-scale orthogonal rotation check for skeletal joints and rigid weapon bones
static int vrik_is_rot(const float *M) {
    for (int r = 0; r < 3; r++) {
        float l2 = M[r*4]*M[r*4] + M[r*4+1]*M[r*4+1] + M[r*4+2]*M[r*4+2];
        if (!(l2 >= 0.85f && l2 <= 1.15f && isfinite(M[r*4+3]) && fabsf(M[r*4+3]) < 10.0f)) return 0;
    }
    if (fabsf(v3dot(M, M + 4)) > 0.08f || fabsf(v3dot(M, M + 8)) > 0.08f || fabsf(v3dot(M + 4, M + 8)) > 0.08f) return 0;
    return 1;
}

// Orthogonal bone check allowing muscle/volume helper bone scaling (e.g. *_elbow_bend_A_mscl_JNT when elbow bends)
// Stops cleanly at the 16-byte inter-palette separator where Row 0 has l2 == 0.
static int vrik_is_bone(const float *M) {
    float l[3];
    for (int r = 0; r < 3; r++) {
        float l2 = M[r*4]*M[r*4] + M[r*4+1]*M[r*4+1] + M[r*4+2]*M[r*4+2];
        if (!(l2 >= 0.04f && l2 <= 9.0f && isfinite(M[r*4+3]) && fabsf(M[r*4+3]) < 10.0f)) return 0;
        l[r] = sqrtf(l2);
    }
    if (fabsf(v3dot(M, M + 4)) > 0.35f * l[0] * l[1] ||
        fabsf(v3dot(M, M + 8)) > 0.35f * l[0] * l[2] ||
        fabsf(v3dot(M + 4, M + 8)) > 0.35f * l[1] * l[2]) return 0;
    return 1;
}

static int vrik_is_pal_bone(const uint8_t *P, uint32_t k, size_t pav) {
    if ((size_t)(k + 1) * 48 > pav) return 0;
    return vrik_is_bone((const float *)(P + (size_t)k * 48));
}

// (bones of list L at unmodified palette P agree on their rotational arm/hand joints)
static int vrik_try(const uint8_t *P, uint32_t cap_b, uint32_t max_b, uint32_t strict_rot, int L, int rigv) {
    uint32_t o = vrik_list_off[L], nb = vrik_list_off[L + 1] - o;
    if (nb > cap_b || nb < 16) return -1;
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
    int exact_len = (nb == max_b || nb == strict_rot);
    int min_good = exact_len ? 2 : 6;
    if (!has_arm_pose || good < min_good) return -1;
    return (exact_len ? 100 : 0) + good * 2 + (int)(nb / 4);
}

static int vrik_identify(const void *ib, NSUInteger io, NSUInteger count, uint32_t isd0, const uint8_t *orig_P, uint32_t cap_b, uint32_t max_b, uint32_t strict_rot, int *rigv) {
    for (int i = 0; i < g_vk_nmesh; i++) {
        if (g_vk_mesh[i].ib == ib && g_vk_mesh[i].io == io && g_vk_mesh[i].count == count && g_vk_mesh[i].isd0 == isd0) {
            int cL = g_vk_mesh[i].list, cv = g_vk_mesh[i].rigv;
            if (cL >= 0) {
                uint32_t need_nb = vrik_list_off[cL + 1] - vrik_list_off[cL];
                if (need_nb <= cap_b) {
                    *rigv = cv;
                    return cL;
                }
            } else {
                // Previously weapon/non-body; fast return unless it now has body-scale translations
                int has_body_t = 0;
                for (uint32_t k = 0; k < max_b && k < 15; k++) {
                    const float *M = (const float *)(orig_P + (size_t)k * 48);
                    if (M[3]*M[3] + M[7]*M[7] + M[11]*M[11] > 0.25f) { has_body_t = 1; break; }
                }
                if (!has_body_t) { *rigv = 0; return -1; }
            }
            break;
        }
    }
    // Quick O(1) check: if no bone in the first 15 has |t| > 0.35m, this is a weapon/item palette (not V's body rig)
    int can_be_body = 0;
    for (uint32_t k = 0; k < max_b && k < 15; k++) {
        const float *M = (const float *)(orig_P + (size_t)k * 48);
        if (M[3]*M[3] + M[7]*M[7] + M[11]*M[11] > 0.12f) { can_be_body = 1; break; }
    }
    int best = -1, bestv = 0, bestg = 0;
    if (can_be_body && cap_b >= 16) {
        for (int L = 0; L < VRIK_NLISTS; L++) for (int v = 0; v < 2; v++) { int g = vrik_try(orig_P, cap_b, max_b, strict_rot, L, v); if (g > bestg) { bestg = g; best = L; bestv = v; } }
    }
    int found = 0;
    for (int i = 0; i < g_vk_nmesh; i++) {
        if (g_vk_mesh[i].ib == ib && g_vk_mesh[i].io == io && g_vk_mesh[i].count == count && g_vk_mesh[i].isd0 == isd0) {
            g_vk_mesh[i].list = best; g_vk_mesh[i].rigv = bestv; found = 1; break;
        }
    }
    if (!found && g_vk_nmesh < 256) { vrik_mesh m = { ib, io, count, isd0, best, bestv }; g_vk_nmesh++; g_vk_mesh[g_vk_nmesh - 1] = m; }
    if (best >= 0) vxmac_log("VRIK: a foreground mesh (%lu indices, max_b=%u, strict=%u) is list %d (%u bones, %s rig, score %d)", (unsigned long)count, max_b, strict_rot, best, vrik_list_off[best + 1] - vrik_list_off[best], bestv ? "man" : "woman", bestg);
    else vxmac_log("VRIK: a foreground mesh (%lu indices, max_b=%u, strict=%u) is none of V's", (unsigned long)count, max_b, strict_rot);
    *rigv = bestv;
    return best;
}

// ---- persistent state: cross-palette arm/hand/finger solver + multi-pass safe palette cache -------------------------
typedef struct { aff orig, mod; int seg; } vrik_known_bone;
typedef struct {
    uint8_t *P;
    uint32_t cap_b, max_b, strict_rot, nb;
    NSUInteger count;
    int L, applied, mod_k1, mod_k2;
    unsigned stamp, frame;
    aff obj, mod1, mod2;
    aff orig[128];
} vrik_pal;

// Joy-Con button bitmask passed from host.m -> xros_vr.m -> weap[5]
#define VRIK_BTN_L_GRAB  (1u << 0)   // Left Joy-Con L shoulder or L3 stick click
#define VRIK_BTN_L_TRIG  (1u << 1)   // Left Joy-Con ZL trigger
#define VRIK_BTN_R_GRAB  (1u << 2)   // Right Joy-Con R shoulder or R3 stick click
#define VRIK_BTN_R_TRIG  (1u << 3)   // Right Joy-Con ZR trigger

static struct {
    unsigned solve_frame;
    int have_af[2];   // 1 = true LeftArm/RightArm (SA) + LeftForeArm/RightForeArm (SF) captured in cur_frame
    int have_h[2];    // 1 = true LeftHand/RightHand (SH) captured in cur_frame
    aff SA[2], SF[2], SH[2];
    int rigv;
    aff obj, vcam;
    aff D[7];
    aff D_w0[2], D_w1[2], D_w2[2];   // Forearm-to-wrist twist distribution matrices (Wrist_0, Wrist_1, Wrist_2)
    aff D_gun;
    int gun_hand;                    // 1 = right hand holds weapon, 0 = left hand holds weapon
    float two_hand;
    float curls[2][6];
    float weap[8];
    float slide_pull;
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

    // 1:1 view-space hand state (+X right, +Y up, +Z forward): position s_hv, forward s_fv, across-knuckle s_av
    static float s_hv[2][3] = { { -0.18f, -0.22f, 0.36f }, { 0.18f, -0.22f, 0.36f } };
    static float s_fv[2][3] = { { 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 1.0f } };
    static float s_av[2][3] = { { 0.0f, -1.0f, 0.0f }, { 0.0f, 1.0f, 0.0f } };
    static float s_roll[2]  = { 0.0f, 0.0f };
    static float s_arm_w[2] = { 0.0f, 0.0f };
    static int s_hold_frames[2] = { 0, 0 };
    static int s_init[2] = { 0, 0 };
    static unsigned s_last_frame = 0;

    // Joy-Con button-driven weapon hand state: s_gun_hand = 1 (Right Hand) or 0 (Left Hand)
    // Hand-tracking finger curls NEVER switch s_gun_hand so holding Joy-Cons never causes interference.
    static int s_gun_hand = 1, s_gun_hand_init = 0;
    static unsigned s_prev_btns = 0;
    if (!s_gun_hand_init) { g_vk.gun_hand = 1; s_gun_hand_init = 1; }
    unsigned ctrl_btns = (unsigned)g_vk.weap[5];

    unsigned cur_frame = atomic_load(&g_frame);
    int step_filter = (cur_frame != s_last_frame || (!s_init[0] && ok[0]) || (!s_init[1] && ok[1]));
    s_last_frame = cur_frame;

    if (step_filter) {
        for (int side = 0; side < 2; side++) {
            if (ok[side]) {
                float rx = fmaxf(-0.48f, fminf(0.48f, hf[side][0]));
                float ry = fmaxf(-0.42f, fminf(0.28f, hf[side][1]));
                float rz = fmaxf( 0.16f, fminf(0.58f, -hf[side][2]));
                float rf[3] = { hf[side][3], hf[side][4], -hf[side][5] };
                float ra[3] = { hf[side][6], hf[side][7], -hf[side][8] };
                if (!v3norm(rf)) { rf[0] = 0.0f; rf[1] = 0.0f; rf[2] = 1.0f; }
                float da = v3dot(ra, rf); for (int i = 0; i < 3; i++) ra[i] -= da * rf[i];
                if (!v3norm(ra)) { ra[0] = 0.0f; ra[1] = side ? 1.0f : -1.0f; ra[2] = 0.0f; }
                if (!s_init[side]) {
                    s_hv[side][0] = rx; s_hv[side][1] = ry; s_hv[side][2] = rz;
                    memcpy(s_fv[side], rf, sizeof rf);
                    memcpy(s_av[side], ra, sizeof ra);
                    s_init[side] = 1;
                } else {
                    float dx = rx - s_hv[side][0], dy = ry - s_hv[side][1], dz = rz - s_hv[side][2];
                    float dl = sqrtf(dx*dx + dy*dy + dz*dz);
                    if (dl > 0.060f) { float s = 0.060f / dl; dx *= s; dy *= s; dz *= s; }
                    s_hv[side][0] += dx * 0.45f;
                    s_hv[side][1] += dy * 0.45f;
                    s_hv[side][2] += dz * 0.45f;
                    for (int i = 0; i < 3; i++) {
                        s_fv[side][i] += (rf[i] - s_fv[side][i]) * 0.35f;
                        s_av[side][i] += (ra[i] - s_av[side][i]) * 0.35f;
                    }
                    v3norm(s_fv[side]);
                    float dt = v3dot(s_av[side], s_fv[side]);
                    for (int i = 0; i < 3; i++) s_av[side][i] -= dt * s_fv[side][i];
                    if (!v3norm(s_av[side])) memcpy(s_av[side], ra, sizeof ra);
                }
                s_hold_frames[side] = 25;
                s_arm_w[side] = fminf(1.0f, s_arm_w[side] + 0.12f);
            } else {
                if (s_hold_frames[side] > 0) s_hold_frames[side]--;
                else s_arm_w[side] = fmaxf(0.0f, s_arm_w[side] - 0.04f);
            }
        }

        // Joy-Con weapon grab / hand switching:
        // - Press Left Joy-Con L / L3 (VRIK_BTN_L_GRAB) while R is not held -> grab weapon with Left Hand (s_gun_hand = 0)
        // - Press Right Joy-Con R / R3 (VRIK_BTN_R_GRAB) while L is not held -> grab weapon with Right Hand (s_gun_hand = 1)
        unsigned newly_pressed = ctrl_btns & ~s_prev_btns;
        s_prev_btns = ctrl_btns;
        if ((newly_pressed & VRIK_BTN_L_GRAB) && !(ctrl_btns & VRIK_BTN_R_GRAB) && s_arm_w[0] > 0.25f && s_gun_hand != 0) {
            s_gun_hand = 0;
            vxmac_log("VRIK: weapon grabbed by left hand via Joy-Con L button");
        } else if ((newly_pressed & VRIK_BTN_R_GRAB) && !(ctrl_btns & VRIK_BTN_L_GRAB) && s_gun_hand != 1) {
            s_gun_hand = 1;
            vxmac_log("VRIK: weapon grabbed by right hand via Joy-Con R button");
        }
    }
    if (s_gun_hand == 0 && s_arm_w[0] < 0.05f && s_arm_w[1] > 0.25f) s_gun_hand = 1;
    g_vk.gun_hand = s_gun_hand;

    float Tc_out[2][3] = {{0},{0}};
    float f_final[2][3] = {{0,1,0},{0,1,0}}, u_final[2][3] = {{0,0,1},{0,0,1}};
    int solved[2] = { 0, 0 };
    g_vk.D[0] = aff_id();

    for (int side = 0; side < 2; side++) {
        g_vk.D[side ? 4 : 1] = g_vk.D[side ? 5 : 2] = g_vk.D[side ? 6 : 3] = aff_id();
        g_vk.D_w0[side] = g_vk.D_w1[side] = g_vk.D_w2[side] = aff_id();
        if (s_arm_w[side] < 0.01f || !g_vk.have_af[side]) continue;
        int nA = side ? VRIK_RIGHTARM : VRIK_LEFTARM, nF = side ? VRIK_RIGHTFOREARM : VRIK_LEFTFOREARM, nH = side ? VRIK_RIGHTHAND : VRIK_LEFTHAND;
        const float *cA = vrik_bindpos(rigv, nA), *cF = vrik_bindpos(rigv, nF), *cH = vrik_bindpos(rigv, nH);
        const float *cM = vrik_bindpos(rigv, side ? VRIK_RIGHTHANDMIDDLE1 : VRIK_LEFTHANDMIDDLE1);
        const float *cI = vrik_bindpos(rigv, side ? VRIK_RIGHTHANDINDEX1  : VRIK_LEFTHANDINDEX1);
        const float *cP = vrik_bindpos(rigv, side ? VRIK_RIGHTHANDPINKY1  : VRIK_LEFTHANDPINKY1);
        if (!cA || !cF || !cH || !cM || !cI || !cP) continue;
        const float *SA = g_vk.SA[side].m, *SF = g_vk.SF[side].m;
        float S[3], E[3], eA[3], W[3]; aff_pt(SA, cA, S); aff_pt(SF, cF, E); aff_pt(SA, cF, eA); aff_pt(SF, cH, W);
        float de[3] = { eA[0]-E[0], eA[1]-E[1], eA[2]-E[2] };
        int side_ok = side ? (S[0] > 0.02f && S[0] < 0.40f) : (S[0] < -0.02f && S[0] > -0.40f);
        if (!side_ok || S[2] < 1.10f || S[2] > 1.70f || v3len(de) > 0.025f) continue;
        float Ev[3], Wv[3]; aff_pt(o2v.m, E, Ev); aff_pt(o2v.m, W, Wv);
        float a = 0, b = 0, d3[3];
        for (int i = 0; i < 3; i++) d3[i] = E[i] - S[i]; a = v3len(d3);
        for (int i = 0; i < 3; i++) d3[i] = W[i] - E[i]; b = v3len(d3);
        if (v3len(Ev) > 0.95f || a < 0.18f || a > 0.38f || b < 0.18f || b > 0.38f) continue;

        // 1:1 Hand Position in camera view space
        float target_v[3] = {
            Wv[0] + (s_hv[side][0] - Wv[0]) * s_arm_w[side],
            Wv[1] + (s_hv[side][1] - Wv[1]) * s_arm_w[side],
            Wv[2] + (s_hv[side][2] - Wv[2]) * s_arm_w[side]
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
        float u_fore[3] = { f1[0], f1[1], f1[2] }; v3norm(u_fore);

        // Bind-space hand basis: f_bind = Wrist->Middle1, a_bind = (side ? Index1-Pinky1 : Pinky1-Index1) orthogonalized
        float f_bind[3] = { cM[0]-cH[0], cM[1]-cH[1], cM[2]-cH[2] };
        float a_bind[3] = { side ? (cI[0]-cP[0]) : (cP[0]-cI[0]), side ? (cI[1]-cP[1]) : (cP[1]-cI[1]), side ? (cI[2]-cP[2]) : (cP[2]-cI[2]) };
        v3norm(f_bind);
        float d_ba = v3dot(a_bind, f_bind); for (int i = 0; i < 3; i++) a_bind[i] -= d_ba * f_bind[i];
        v3norm(a_bind);

        // Hand basis after two-bone IK D2 (using SH[side] when it matches SF[side] at the wrist joint, else SF[side])
        float wH[3]; aff_pt(g_vk.SH[side].m, cH, wH);
        float dw_h[3] = { wH[0] - W[0], wH[1] - W[1], wH[2] - W[2] };
        int use_sh = (g_vk.have_h[side] && v3len(dw_h) < 0.02f);
        aff M_h2 = aff_mul(D2, use_sh ? g_vk.SH[side] : g_vk.SF[side]);
        float f_h2[3], a_h2[3];
        aff_dir(M_h2.m, f_bind, f_h2); v3norm(f_h2);
        aff_dir(M_h2.m, a_bind, a_h2);
        float d_h2 = v3dot(a_h2, f_h2); for (int i = 0; i < 3; i++) a_h2[i] -= d_h2 * f_h2[i];
        v3norm(a_h2);

        // 1:1 VR hand basis in object space with anatomical wrist flexion/extension cone (max ~60 deg from forearm axis)
        float f_vr[3], a_vr[3];
        aff_dir(v2o.m, s_fv[side], f_vr); v3norm(f_vr);
        aff_dir(v2o.m, s_av[side], a_vr);
        float df_fore = v3dot(f_vr, u_fore);
        if (df_fore < 0.50f) {
            for (int i = 0; i < 3; i++) f_vr[i] += (0.50f - df_fore) * u_fore[i];
            v3norm(f_vr);
        }
        float f_tgt[3] = {
            f_h2[0] + (f_vr[0] - f_h2[0]) * s_arm_w[side],
            f_h2[1] + (f_vr[1] - f_h2[1]) * s_arm_w[side],
            f_h2[2] + (f_vr[2] - f_h2[2]) * s_arm_w[side]
        };
        if (!v3norm(f_tgt)) memcpy(f_tgt, f_h2, sizeof f_h2);
        float f_half[3] = { f_h2[0] + f_tgt[0], f_h2[1] + f_tgt[1], f_h2[2] + f_tgt[2] };
        if (!v3norm(f_half)) memcpy(f_half, f_tgt, sizeof f_tgt);

        aff R_aim      = aff_arc(f_h2, f_tgt,  Tc);
        aff R_aim_half = aff_arc(f_h2, f_half, Tc);

        float a_h3[3], a_tgt[3] = { a_vr[0], a_vr[1], a_vr[2] };
        aff_dir(R_aim.m, a_h2, a_h3);
        float dt1 = v3dot(a_h3,  f_tgt); for (int i = 0; i < 3; i++) a_h3[i]  -= dt1 * f_tgt[i];
        float dt2 = v3dot(a_tgt, f_tgt); for (int i = 0; i < 3; i++) a_tgt[i] -= dt2 * f_tgt[i];
        float raw_roll = 0.0f;
        if (v3norm(a_h3) && v3norm(a_tgt)) {
            float cx[3]; v3cross(a_h3, a_tgt, cx);
            raw_roll = atan2f(v3dot(cx, f_tgt), v3dot(a_h3, a_tgt));
        }
        raw_roll = fmaxf(-1.35f, fminf(1.35f, raw_roll));
        if (step_filter) s_roll[side] += (raw_roll - s_roll[side]) * 0.35f;
        float roll_ang = s_roll[side] * s_arm_w[side];

        // Distribute forearm twist smoothly across Wrist_0 (30%), Wrist_1 (60%), Wrist_2 (85% + half aim), and Hand (100% + full aim)
        g_vk.D_w0[side] = aff_mul(aff_rot(u_fore, 0.30f * roll_ang, Tc), D2);
        g_vk.D_w1[side] = aff_mul(aff_rot(u_fore, 0.60f * roll_ang, Tc), D2);
        g_vk.D_w2[side] = aff_mul(aff_rot(f_half, 0.85f * roll_ang, Tc), aff_mul(R_aim_half, D2));
        aff D3          = aff_mul(aff_rot(f_tgt,  roll_ang,         Tc), aff_mul(R_aim,      D2));

        memcpy(f_final[side], f_tgt, sizeof f_tgt);
        aff_dir(D3.m, g_vk.have_h[side] ? g_vk.SH[side].m : g_vk.SF[side].m, u_final[side]); // placeholder overwritten below
        float a_fin[3]; aff_dir(aff_rot(f_tgt, roll_ang, Tc).m, a_h3, a_fin);
        for (int i = 0; i < 3; i++) u_final[side][i] = side ? a_fin[i] : -a_fin[i];
        v3norm(u_final[side]);
        memcpy(Tc_out[side], Tc, sizeof Tc);
        solved[side] = 1;
        g_vk.D[side ? 4 : 1] = D1; g_vk.D[side ? 5 : 2] = D2; g_vk.D[side ? 6 : 3] = D3;
        static atomic_uint logged; if (atomic_fetch_add(&logged, 1) % 300 == 0)
            vxmac_log("VRIK: %s arm solved (hand=%d gun=%d roll=%.1f deg): S(%.2f %.2f %.2f) E2(%.2f %.2f %.2f) Tc(%.2f %.2f %.2f)",
                      side ? "right" : "left", g_vk.have_h[side], s_gun_hand, roll_ang * 57.2958f, S[0], S[1], S[2], E2[0], E2[1], E2[2], Tc[0], Tc[1], Tc[2]);
    }

    // 100% Locked Weapon Transform (D_gun) derived directly from g_vk.D[6] (V's Right Hand skinning delta):
    // - When held in Right Hand (gh == 1): D_gun == g_vk.D[6] (zero floating; identical transform to V's right hand!).
    // - When held in Left Hand (gh == 0, switched via Joy-Con L button): composed directly on top of g_vk.D[6],
    //   translating Tc_out[1] -> Tc_out[0] and rotating (f_final[1], u_final[1]) -> (f_gun, u_gun) around Tc_out[0].
    aff D_gun = g_vk.D[6];
    int gh = s_gun_hand, sh = 1 - gh;
    if (solved[gh] && solved[1]) {
        float f_gun[3] = { f_final[gh][0], f_final[gh][1], f_final[gh][2] };
        float u_gun[3] = { u_final[gh][0], u_final[gh][1], u_final[gh][2] };
        g_vk.two_hand = 0.0f;

        unsigned sh_grab_mask = (sh == 0) ? (VRIK_BTN_L_GRAB | VRIK_BTN_L_TRIG) : (VRIK_BTN_R_GRAB | VRIK_BTN_R_TRIG);
        if (solved[sh] && (ctrl_btns & sh_grab_mask)) {
            float dv[3] = { s_hv[sh][0] - s_hv[gh][0], s_hv[sh][1] - s_hv[gh][1], s_hv[sh][2] - s_hv[gh][2] };
            float dist_v = v3len(dv);
            if (dist_v > 0.14f && dist_v < 0.65f && dv[2] > 0.03f) {
                float dir_2h[3] = { Tc_out[sh][0] - Tc_out[gh][0], Tc_out[sh][1] - Tc_out[gh][1], Tc_out[sh][2] - Tc_out[gh][2] };
                if (v3norm(dir_2h) && v3dot(dir_2h, f_gun) > 0.35f) {
                    for (int i = 0; i < 3; i++) f_gun[i] = f_gun[i] * 0.35f + dir_2h[i] * 0.65f;
                    v3norm(f_gun);
                    float du = v3dot(u_gun, f_gun); for (int i = 0; i < 3; i++) u_gun[i] -= du * f_gun[i];
                    v3norm(u_gun);
                    g_vk.two_hand = 1.0f;
                }
            }
        }

        if (gh == 1) {
            if (g_vk.two_hand < 0.5f) {
                D_gun = g_vk.D[6];
            } else {
                D_gun = aff_mul(aff_arc(f_final[1], f_gun, Tc_out[1]), g_vk.D[6]);
            }
        } else {
            // Start from g_vk.D[6] (which places the weapon grip at Tc_out[1] with basis f_final[1], u_final[1]),
            // translate Tc_out[1] -> Tc_out[0], and align (f_final[1], u_final[1]) -> (f_gun, u_gun) around Tc_out[0]
            aff T_r2l = aff_id();
            for (int i = 0; i < 3; i++) T_r2l.m[i*4+3] = Tc_out[0][i] - Tc_out[1][i];
            aff R_f = aff_arc(f_final[1], f_gun, Tc_out[0]);
            float u1[3]; aff_dir(R_f.m, u_final[1], u1);
            float d1 = v3dot(u1, f_gun); for (int i = 0; i < 3; i++) u1[i] -= d1 * f_gun[i];
            float d2 = v3dot(u_gun, f_gun); for (int i = 0; i < 3; i++) u_gun[i] -= d2 * f_gun[i];
            float g_roll = 0.0f;
            if (v3norm(u1) && v3norm(u_gun)) {
                float cx[3]; v3cross(u1, u_gun, cx);
                g_roll = atan2f(v3dot(cx, f_gun), v3dot(u1, u_gun));
            }
            aff R_u = aff_rot(f_gun, g_roll, Tc_out[0]);
            D_gun = aff_mul(R_u, aff_mul(R_f, aff_mul(T_r2l, g_vk.D[6])));
        }
    }
    g_vk.D_gun = D_gun;
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

// Gentle hand-tracking finger flexion/extension for BOTH hands (including knuckle volume/muscle bones so fingers never deform)
static void vrik_finger_deltas(int side, const vrik_pal *pal, uint32_t o, aff M_out[128]) {
    for (uint32_t k = 0; k < pal->nb; k++) M_out[k] = aff_id();
    int rigv = g_vk.rigv;
    int nH = side ? VRIK_RIGHTHAND : VRIK_LEFTHAND;
    int bH = -1;
    for (uint32_t k = 0; k < pal->nb; k++) if (vrik_list[o + k] == nH) { bH = (int)k; break; }
    if (bH < 0) return;

    const float *cH = vrik_bindpos(rigv, nH);
    const float *cM = vrik_bindpos(rigv, side ? VRIK_RIGHTHANDMIDDLE1 : VRIK_LEFTHANDMIDDLE1);
    const float *cI = vrik_bindpos(rigv, side ? VRIK_RIGHTHANDINDEX1  : VRIK_LEFTHANDINDEX1);
    const float *cP = vrik_bindpos(rigv, side ? VRIK_RIGHTHANDPINKY1  : VRIK_LEFTHANDPINKY1);
    if (!cH || !cM || !cI || !cP) return;

    // Bind-space forward (fb) and inward-curl axis (ab: side ? Index-Pinky : Pinky-Index, so +angle always curls into the palm)
    float fb[3] = { cM[0]-cH[0], cM[1]-cH[1], cM[2]-cH[2] };
    float ab[3] = { side ? (cI[0]-cP[0]) : (cP[0]-cI[0]), side ? (cI[1]-cP[1]) : (cP[1]-cI[1]), side ? (cI[2]-cP[2]) : (cP[2]-cI[2]) };
    if (!v3norm(fb)) return;
    float t = v3dot(ab, fb); for (int i = 0; i < 3; i++) ab[i] -= t * fb[i];
    if (!v3norm(ab)) return;

    float f_hand[3], ax_curl[3];
    aff_dir(pal->orig[bH].m, fb, f_hand);
    aff_dir(pal->orig[bH].m, ab, ax_curl);
    if (!v3norm(f_hand) || !v3norm(ax_curl)) return;

    // Phalanx bones (b1, b2, b3) + knuckle skin/muscle bones (m1_top, m1_bot attached to b1; m2_top attached to b2)
    static const int f_jnt[2][4][6] = {
        {   // Left hand (side = 0)
            {  15,  17,  19, 1592, 1590, 1588 }, // Index
            {  24,  26,  28, 1616, 1614, 1612 }, // Middle
            {  42,  44,  46, 1646, 1644, 1642 }, // Ring
            {  33,  35,  37, 1628, 1626, 1624 }  // Pinky
        },
        {   // Right hand (side = 1)
            { 107, 109, 111, 2062, 2060, 2058 }, // Index
            { 116, 118, 120, 2086, 2084, 2082 }, // Middle
            { 134, 136, 138, 2116, 2114, 2112 }, // Ring
            { 125, 127, 129, 2098, 2096, 2094 }  // Pinky
        }
    };

    for (int f = 0; f < 4; f++) {
        int b1 = -1, b2 = -1, b3 = -1, m1a = -1, m1b = -1, m2a = -1;
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_list[o + k];
            if      (nm == f_jnt[side][f][0]) b1  = (int)k;
            else if (nm == f_jnt[side][f][1]) b2  = (int)k;
            else if (nm == f_jnt[side][f][2]) b3  = (int)k;
            else if (nm == f_jnt[side][f][3]) m1a = (int)k;
            else if (nm == f_jnt[side][f][4]) m1b = (int)k;
            else if (nm == f_jnt[side][f][5]) m2a = (int)k;
        }
        if (b1 < 0) continue;
        const float *c1 = vrik_bindpos(rigv, f_jnt[side][f][0]);
        if (!c1) continue;

        // Measure how much phalanx 1 is ALREADY bent in pal->orig relative to the palm so we never double-curl a weapon grip
        float f_p1[3], cx1[3];
        aff_dir(pal->orig[b1].m, fb, f_p1); v3norm(f_p1);
        v3cross(f_hand, f_p1, cx1);
        float cur_ang1 = atan2f(v3dot(cx1, ax_curl), v3dot(f_hand, f_p1));
        float curl = g_vk.curls[side][1 + f];
        float tgt_ang1 = curl * 0.85f;
        float d1 = fmaxf(-0.35f, fminf(0.35f, (tgt_ang1 - cur_ang1) * 0.55f));

        float p1[3]; aff_pt(pal->orig[b1].m, c1, p1);
        aff M1 = aff_rot(ax_curl, d1, p1);
        M_out[b1] = M1;
        if (m1a >= 0) M_out[m1a] = M1;
        if (m1b >= 0) M_out[m1b] = M1;

        if (b2 >= 0) {
            const float *c2 = vrik_bindpos(rigv, f_jnt[side][f][1]);
            if (c2) {
                float f_p2[3], cx2[3];
                aff_dir(pal->orig[b2].m, fb, f_p2); v3norm(f_p2);
                v3cross(f_p1, f_p2, cx2);
                float cur_ang2 = atan2f(v3dot(cx2, ax_curl), v3dot(f_p1, f_p2));
                float tgt_ang2 = curl * 0.95f;
                float d2 = fmaxf(-0.35f, fminf(0.35f, (tgt_ang2 - cur_ang2) * 0.55f));

                float p2[3], p2m[3]; aff_pt(pal->orig[b2].m, c2, p2); aff_pt(M1.m, p2, p2m);
                aff M2 = aff_mul(aff_rot(ax_curl, d2, p2m), M1);
                M_out[b2] = M2;
                if (m2a >= 0) M_out[m2a] = M2;
                if (b3 >= 0) {
                    const float *c3 = vrik_bindpos(rigv, f_jnt[side][f][2]);
                    if (c3) {
                        float p3[3], p3m[3]; aff_pt(pal->orig[b3].m, c3, p3); aff_pt(M2.m, p3, p3m);
                        M_out[b3] = aff_mul(aff_rot(ax_curl, d2 * 0.50f, p3m), M2);
                    } else {
                        M_out[b3] = M2;
                    }
                }
            }
        }
    }

    // Thumb flexion (Thumb1, Thumb2 + thumb side/base muscle bones)
    int t_jnt[5] = {
        side ? 143 : 51,    // Thumb1
        side ? 145 : 53,    // Thumb2
        side ? 2129 : 1659, // thumb_side_mscl_JNT
        side ? 2131 : 1661, // thumb_thumb_A_bot_mscl_JNT
        side ? 2133 : 1663  // thumb_thumb_A_top_mscl_JNT
    };
    int tb1 = -1, tb2 = -1, tm1 = -1, tm2 = -1, tm3 = -1;
    for (uint32_t k = 0; k < pal->nb; k++) {
        int nm = vrik_list[o + k];
        if      (nm == t_jnt[0]) tb1 = (int)k;
        else if (nm == t_jnt[1]) tb2 = (int)k;
        else if (nm == t_jnt[2]) tm1 = (int)k;
        else if (nm == t_jnt[3]) tm2 = (int)k;
        else if (nm == t_jnt[4]) tm3 = (int)k;
    }
    if (tb1 >= 0) {
        const float *ct1 = vrik_bindpos(rigv, t_jnt[0]);
        if (ct1) {
            float dt = fmaxf(-0.20f, fminf(0.20f, (g_vk.curls[side][0] - 0.45f) * 0.40f));
            float pt1[3]; aff_pt(pal->orig[tb1].m, ct1, pt1);
            aff MT1 = aff_rot(f_hand, side ? -dt : dt, pt1);
            M_out[tb1] = MT1;
            if (tm1 >= 0) M_out[tm1] = MT1;
            if (tm2 >= 0) M_out[tm2] = MT1;
            if (tm3 >= 0) M_out[tm3] = MT1;
            if (tb2 >= 0) {
                const float *ct2 = vrik_bindpos(rigv, t_jnt[1]);
                if (ct2) {
                    float pt2[3], pt2m[3]; aff_pt(pal->orig[tb2].m, ct2, pt2); aff_pt(MT1.m, pt2, pt2m);
                    M_out[tb2] = aff_mul(aff_rot(f_hand, side ? -dt : dt, pt2m), MT1);
                } else {
                    M_out[tb2] = MT1;
                }
            }
        }
    }
}

static int vrik_pal_still_modified(const vrik_pal *p) {
    if (!p || !p->applied || p->nb == 0 || p->mod_k1 < 0 || p->mod_k2 < 0) return 0;
    if (vrik_same_bone(&p->mod1, &p->orig[p->mod_k1]) && vrik_same_bone(&p->mod2, &p->orig[p->mod_k2])) return 0;
    const aff *cur1 = (const aff *)(p->P + (size_t)p->mod_k1 * 48);
    const aff *cur2 = (const aff *)(p->P + (size_t)p->mod_k2 * 48);
    return vrik_same_bone(cur1, &p->mod1) && vrik_same_bone(cur2, &p->mod2);
}

static void vrik_apply_pal(vrik_pal *pal) {
    if ((!g_vk.have_af[0] && !g_vk.have_af[1]) || pal->nb == 0 || pal->nb > pal->cap_b) return;
    if (pal->L >= 0) {
        uint32_t o = vrik_list_off[pal->L];
        int has_l_fng = 0, has_r_fng = 0;
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_list[o + k];
            if (nm == VRIK_LEFTHANDINDEX1)  has_l_fng = 1;
            if (nm == VRIK_RIGHTHANDINDEX1) has_r_fng = 1;
        }
        aff M_fng_l[128], M_fng_r[128];
        if (has_l_fng) vrik_finger_deltas(0, pal, o, M_fng_l);
        if (has_r_fng) vrik_finger_deltas(1, pal, o, M_fng_r);
        int k1 = -1, k2 = -1;
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_list[o + k], s = vrik_seg[nm];
            aff *dst = (aff *)(pal->P + (size_t)k * 48);
            if      (nm == 1503) *dst = aff_mul(g_vk.D_w0[0], pal->orig[k]); // l_Wrist_0_JNT (30% forearm roll)
            else if (nm == 1504) *dst = aff_mul(g_vk.D_w1[0], pal->orig[k]); // l_Wrist_1_JNT (60% forearm roll)
            else if (nm == 1505 || nm == 1678 || nm == 1680 || nm == 1682)
                                 *dst = aff_mul(g_vk.D_w2[0], pal->orig[k]); // l_Wrist_2_JNT + wrist_A/B/C_mscl
            else if (nm == 1974) *dst = aff_mul(g_vk.D_w0[1], pal->orig[k]); // r_Wrist_0_JNT (30% forearm roll)
            else if (nm == 1975) *dst = aff_mul(g_vk.D_w1[1], pal->orig[k]); // r_Wrist_1_JNT (60% forearm roll)
            else if (nm == 1976 || nm == 2148 || nm == 2149 || nm == 2150)
                                 *dst = aff_mul(g_vk.D_w2[1], pal->orig[k]); // r_Wrist_2_JNT + wrist_A/B/C_mscl
            else if (s == 3 && has_l_fng) *dst = aff_mul(g_vk.D[3], aff_mul(M_fng_l[k], pal->orig[k]));
            else if (s == 6 && has_r_fng) *dst = aff_mul(g_vk.D[6], aff_mul(M_fng_r[k], pal->orig[k]));
            else *dst = (s > 0) ? aff_mul(g_vk.D[s], pal->orig[k]) : pal->orig[k];

            if (s > 0) {
                if (k1 < 0) k1 = (int)k;
                k2 = (int)k;
                vrik_record_known(&pal->orig[k], dst, s);
            }
        }
        if (k1 < 0) { k1 = 0; k2 = (int)pal->nb - 1; }
        pal->mod_k1 = k1; pal->mod_k2 = k2;
        pal->mod1 = ((const aff *)pal->P)[k1];
        pal->mod2 = ((const aff *)pal->P)[k2];
        pal->applied = 1;
        return;
    }
    // Check if this is a body-origin sub-palette (e.g. fingernails 5916 or palm cyberware 3918) sharing exact bone matrices with V's hands
    float db[3] = { pal->obj.m[3] - g_vk.obj.m[3], pal->obj.m[7] - g_vk.obj.m[7], pal->obj.m[11] - g_vk.obj.m[11] };
    float dist_body = v3len(db);
    if (dist_body < 0.05f && pal->nb <= 64) {
        int matched_known = 0, k1 = -1, k2 = -1;
        for (uint32_t k = 0; k < pal->nb; k++) {
            for (int m = 0; m < g_vk.nknown; m++) {
                if (vrik_same_bone(&g_vk.known[m].orig, &pal->orig[k])) { matched_known++; break; }
            }
        }
        if (matched_known >= 2) {
            for (uint32_t k = 0; k < pal->nb; k++) {
                int exact = -1;
                for (int m = 0; m < g_vk.nknown; m++) {
                    if (vrik_same_bone(&g_vk.known[m].orig, &pal->orig[k])) { exact = m; break; }
                }
                aff *dst = (aff *)(pal->P + (size_t)k * 48);
                if (exact >= 0) {
                    *dst = g_vk.known[exact].mod;
                    if (k1 < 0) k1 = (int)k;
                    k2 = (int)k;
                } else {
                    *dst = pal->orig[k];
                }
            }
            if (k1 >= 0) {
                pal->mod_k1 = k1; pal->mod_k2 = k2;
                pal->mod1 = ((const aff *)pal->P)[k1];
                pal->mod2 = ((const aff *)pal->P)[k2];
                pal->applied = 1;
            }
        }
        return;
    }
    // Foreground weapon / attachment mesh (pistols, shotguns with 30-54 bones, barrels, sights, scopes):
    // Apply one unified rigid transform D_weap_gun to every bone of every weapon sub-mesh so multi-part weapons never split apart!
    if ((g_vk.have_af[0] || g_vk.have_af[1]) && vrik_weapon() && dist_body > 0.20f && pal->nb >= 1 && pal->nb <= 128) {
        aff o2v = aff_mul(g_vk.vcam, pal->obj);
        float wpos[3] = { o2v.m[3], o2v.m[7], o2v.m[11] };
        if (v3len(wpos) < 0.95f) {
            aff inv_pobj = aff_inv(pal->obj);
            aff Dw_gun = aff_mul(g_vk.obj, aff_mul(g_vk.D_gun, aff_inv(g_vk.obj)));
            aff D_weap_gun = aff_mul(inv_pobj, aff_mul(Dw_gun, pal->obj));
            for (uint32_t k = 0; k < pal->nb; k++) {
                aff *dst = (aff *)(pal->P + (size_t)k * 48);
                *dst = aff_mul(D_weap_gun, pal->orig[k]);
            }
            pal->mod_k1 = 0; pal->mod_k2 = (int)pal->nb - 1;
            pal->mod1 = ((const aff *)pal->P)[0];
            pal->mod2 = ((const aff *)pal->P)[pal->nb - 1];
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
    unsigned cur_frame = atomic_load(&g_frame);

    // Look up P in the persistent multi-pass palette cache
    vrik_pal *pal = NULL;
    for (int i = 0; i < g_vk.npals; i++) {
        if (g_vk.pals[i].P == P) { pal = &g_vk.pals[i]; break; }
    }
    int still_modified = (pal && pal->mod_k1 >= 0 && (size_t)(pal->mod_k1 + 1) * 48 <= pav &&
                          pal->mod_k2 >= 0 && (size_t)(pal->mod_k2 + 1) * 48 <= pav &&
                          vrik_pal_still_modified(pal));
    if (!still_modified && !(pal && pal->frame == cur_frame && !pal->applied)) {
        // P currently holds fresh unmodified matrices from the game CPU:
        uint32_t cap_b = (uint32_t)(pav / 48);
        if (cap_b > 128) cap_b = 128;
        uint32_t strict_rot = 0, max_b = 0;
        while (strict_rot < cap_b && vrik_is_rot((const float *)(P + (size_t)strict_rot * 48))) strict_rot++;
        while (max_b < cap_b && vrik_is_pal_bone(P, max_b, pav)) max_b++;
        if (max_b < strict_rot) max_b = strict_rot;
        if (max_b == 0) { pthread_mutex_unlock(&g_vk_l); return; }
        if (!pal) {
            if (g_vk.npals < 128) {
                pal = &g_vk.pals[g_vk.npals++];
            } else {
                int oldest = 0;
                for (int i = 1; i < 128; i++) if (g_vk.pals[i].stamp < g_vk.pals[oldest].stamp) oldest = i;
                pal = &g_vk.pals[oldest];
            }
            memset(pal, 0, sizeof *pal);
            pal->P = P; pal->L = -2;
        }
        pal->cap_b = cap_b;
        pal->max_b = max_b;
        pal->strict_rot = strict_rot > 0 ? strict_rot : max_b;
        pal->frame = cur_frame;
        pal->applied = 0;
        pal->mod_k1 = pal->mod_k2 = -1;
        memcpy(pal->orig, P, (size_t)cap_b * 48);
    }
    pal->stamp = seq;
    pal->obj = obj;
    pal->count = count;

    // Identify using the guaranteed-unmodified pal->orig matrices
    int rigv = 0, L = vrik_identify((__bridge const void *)ib, io, count, isd[0], (const uint8_t *)pal->orig, pal->cap_b, pal->max_b, pal->strict_rot, &rigv);

    int state_changed = 0;
    if (L >= 0) {
        uint32_t o = vrik_list_off[L], nb = vrik_list_off[L + 1] - o;
        if (nb > 128) nb = 128;
        if (nb <= pal->cap_b) {
            if (pal->max_b < nb) pal->max_b = nb;
            aff o2v = aff_mul(vcam, obj);
            int near_cam = 0;
            for (uint32_t k = 0; k < nb; k++) {
                int nm = vrik_list[o + k]; if (vrik_seg[nm] <= 0) continue;
                const float *c = vrik_bindpos(rigv, nm); if (!c) continue;
                float pt[3], pv[3]; aff_pt(pal->orig[k].m, c, pt); aff_pt(o2v.m, pt, pv);
                if (v3len(pv) < 1.0f) { near_cam = 1; break; }
            }
            if (near_cam) {
                if (pal->L != L || pal->nb != nb) {
                    pal->L = L; pal->nb = nb;
                    state_changed = 1;
                }
                g_vk.rigv = rigv; g_vk.obj = obj; g_vk.vcam = vcam;
                #define BONE(nm) ({ int _b = -1; for (uint32_t _k = 0; _k < nb; _k++) if (vrik_list[o + _k] == (nm)) { _b = (int)_k; break; } _b; })
                for (int side = 0; side < 2; side++) {
                    int bA = BONE(side ? VRIK_RIGHTARM : VRIK_LEFTARM);
                    if (bA < 0) bA = BONE(side ? VRIK_R_SHL_0_JNT : VRIK_L_SHL_0_JNT);
                    int bF = BONE(side ? VRIK_RIGHTFOREARM : VRIK_LEFTFOREARM);
                    int bH = BONE(side ? VRIK_RIGHTHAND : VRIK_LEFTHAND);
                    const float *cA = vrik_bindpos(rigv, side ? VRIK_RIGHTARM : VRIK_LEFTARM);
                    const float *cF = vrik_bindpos(rigv, side ? VRIK_RIGHTFOREARM : VRIK_LEFTFOREARM);
                    const float *cH = vrik_bindpos(rigv, side ? VRIK_RIGHTHAND : VRIK_LEFTHAND);
                    if (bA >= 0 && bF >= 0 && cA && cF && cH) {
                        float S[3], eA[3], eF[3], W[3];
                        aff_pt(pal->orig[bA].m, cA, S);
                        aff_pt(pal->orig[bA].m, cF, eA);
                        aff_pt(pal->orig[bF].m, cF, eF);
                        aff_pt(pal->orig[bF].m, cH, W);
                        float de[3] = { eA[0]-eF[0], eA[1]-eF[1], eA[2]-eF[2] };
                        float da[3] = { eF[0]-S[0],  eF[1]-S[1],  eF[2]-S[2] };
                        float df[3] = { W[0]-eF[0],  W[1]-eF[1],  W[2]-eF[2] };
                        float la = v3len(da), lf = v3len(df);
                        int side_ok = side ? (S[0] > 0.02f && S[0] < 0.40f) : (S[0] < -0.02f && S[0] > -0.40f);
                        if (side_ok && S[2] > 1.10f && S[2] < 1.70f && v3len(de) < 0.02f && la > 0.18f && la < 0.38f && lf > 0.18f && lf < 0.38f) {
                            if (!g_vk.have_af[side] || !vrik_same_bone(&g_vk.SA[side], &pal->orig[bA]) || !vrik_same_bone(&g_vk.SF[side], &pal->orig[bF])) {
                                g_vk.SA[side] = pal->orig[bA]; g_vk.SF[side] = pal->orig[bF];
                                g_vk.have_af[side] = 1; state_changed = 1;
                            }
                        }
                    }
                    if (bH >= 0 && bF >= 0 && cH) {
                        float wF[3], wH[3];
                        aff_pt(pal->orig[bF].m, cH, wF);
                        aff_pt(pal->orig[bH].m, cH, wH);
                        float dw[3] = { wF[0]-wH[0], wF[1]-wH[1], wF[2]-wH[2] };
                        if (v3len(dw) < 0.02f) {
                            if (!g_vk.have_h[side] || !vrik_same_bone(&g_vk.SH[side], &pal->orig[bH])) {
                                g_vk.SH[side] = pal->orig[bH];
                                g_vk.have_h[side] = 1; state_changed = 1;
                            }
                        }
                    }
                }
                #undef BONE
            }
        }
    } else {
        pal->L = -1;
        pal->nb = pal->strict_rot;
    }

    if (state_changed) {
        g_vk.nknown = 0;
        vrik_solve_all();
        // Re-apply to all palettes active in the current render pass so earlier draws stay 100% synchronized
        for (int i = 0; i < g_vk.npals; i++) {
            vrik_pal *p = &g_vk.pals[i];
            if (p->L >= 0 && (p->frame == cur_frame || vrik_pal_still_modified(p))) vrik_apply_pal(p);
        }
        for (int i = 0; i < g_vk.npals; i++) {
            vrik_pal *p = &g_vk.pals[i];
            if (p->L < 0 && (p->frame == cur_frame || vrik_pal_still_modified(p))) vrik_apply_pal(p);
        }
    } else if (!pal->applied) {
        vrik_apply_pal(pal);
    }
    pthread_mutex_unlock(&g_vk_l);
}
