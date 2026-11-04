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

// ---- per-pass state: cross-palette arm/hand/finger solver + order-independent palette updater -----------------------
typedef struct { aff orig, mod; int seg; } vrik_known_bone;
typedef struct {
    uint8_t *P;
    uint32_t max_b, nb;
    NSUInteger count;
    int L, applied;
    aff obj, mod0, modlast;
    aff orig[128];
} vrik_pal;

typedef struct {
    uint32_t nb;
    NSUInteger count;
    int valid;
    aff rest_rel;
    aff rest_orig[128];
} vrik_weap_rest;
static vrik_weap_rest g_vk_wrest[32];
static int g_vk_nwrest;

static struct {
    int have_af[2];   // 1 = true LeftArm/RightArm (SA) + LeftForeArm/RightForeArm (SF) captured in this pass
    int have_h[2];    // 1 = true LeftHand/RightHand (SH) captured in this pass
    aff SA[2], SF[2], SH[2];
    int rigv;
    aff obj, vcam;
    aff D[7];
    aff D_gun, D_slide, D_mag;
    float mag_scale;
    float carry_left, two_hand;
    float curls[2][6];
    float weap[8];
    float slide_pull;
    float r_fwd_obj[3];
    vrik_known_bone known[192];
    int nknown;
    vrik_pal pals[64];
    int npals;
    vrik_pal prev_pals[64];
    int nprev_pals;
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
    float T_wrist[2][3] = {{0},{0}}, W_orig[2][3] = {{0},{0}};
    float fv_obj[2][3] = {{0,1,0},{0,1,0}}, av_obj[2][3] = {{1,0,0},{1,0,0}}, nv_obj[2][3] = {{0,0,1},{0,0,1}};
    int solved[2] = { 0, 0 };

    for (int side = 0; side < 2; side++) {
        if (!ok[side] || !g_vk.have_af[side]) continue;
        int nA = side ? VRIK_RIGHTARM : VRIK_LEFTARM, nF = side ? VRIK_RIGHTFOREARM : VRIK_LEFTFOREARM, nH = side ? VRIK_RIGHTHAND : VRIK_LEFTHAND;
        const float *cA = vrik_bindpos(rigv, nA), *cF = vrik_bindpos(rigv, nF), *cH = vrik_bindpos(rigv, nH);
        if (!cA || !cF || !cH) continue;
        const float *SA = g_vk.SA[side].m, *SF = g_vk.SF[side].m;
        float S[3], E[3], W[3]; aff_pt(SA, cA, S); aff_pt(SF, cF, E); aff_pt(SF, cH, W);
        float Ev[3]; aff_pt(o2v.m, E, Ev);
        float a = 0, b = 0, d3[3];
        for (int i = 0; i < 3; i++) d3[i] = E[i] - S[i]; a = v3len(d3);
        for (int i = 0; i < 3; i++) d3[i] = W[i] - E[i]; b = v3len(d3);
        if (v3len(Ev) > 0.95f || a < 0.15f || a > 0.45f || b < 0.15f || b > 0.45f) continue;
        // Target wrist in camera view space (+X right, +Y up, +Z forward) -> object space via v2o
        float hv[3] = { hf[side][0], hf[side][1], -hf[side][2] }, T[3];
        aff_pt(v2o.m, hv, T);
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
        aff D3 = D2;
        for (int ax = 0; ax < 3; ax++) {
            const float *h = &hf[side][3 + ax * 3]; float hv2[3] = { h[0], h[1], -h[2] };
            aff_dir(v2o.m, hv2, ax == 0 ? fv_obj[side] : ax == 1 ? av_obj[side] : nv_obj[side]);
        }
        v3norm(fv_obj[side]); v3norm(av_obj[side]); v3norm(nv_obj[side]);
        int nM = side ? VRIK_RIGHTHANDMIDDLE1 : VRIK_LEFTHANDMIDDLE1, nI = side ? VRIK_RIGHTHANDINDEX1 : VRIK_LEFTHANDINDEX1, nP = side ? VRIK_RIGHTHANDPINKY1 : VRIK_LEFTHANDPINKY1;
        const float *cM = vrik_bindpos(rigv, nM), *cI = vrik_bindpos(rigv, nI), *cP = vrik_bindpos(rigv, nP);
        if (g_vk.have_h[side] && cM && cI && cP) {
            float fb[3], ab[3], nbv[3];
            for (int i = 0; i < 3; i++) { fb[i] = cM[i] - cH[i]; ab[i] = side ? cI[i] - cP[i] : cP[i] - cI[i]; }
            v3norm(fb); float t = v3dot(ab, fb); for (int i = 0; i < 3; i++) ab[i] -= t * fb[i]; v3norm(ab); v3cross(fb, ab, nbv);
            float *fv = fv_obj[side], *av = av_obj[side], *nv = nv_obj[side];
            float Rd[9]; for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) Rd[i*3+j] = fv[i]*fb[j] + av[i]*ab[j] + nv[i]*nbv[j];
            aff cur = aff_mul(D2, g_vk.SH[side]);
            float Q[9]; for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) Q[i*3+j] = Rd[i*3]*cur.m[j*4] + Rd[i*3+1]*cur.m[j*4+1] + Rd[i*3+2]*cur.m[j*4+2];
            aff D3r; for (int i = 0; i < 3; i++) { for (int j = 0; j < 3; j++) D3r.m[i*4+j] = Q[i*3+j]; D3r.m[i*4+3] = Tc[i] - (Q[i*3]*Tc[0] + Q[i*3+1]*Tc[1] + Q[i*3+2]*Tc[2]); }
            D3 = aff_mul(D3r, D2);
        }
        if (side == 1) memcpy(g_vk.r_fwd_obj, fv_obj[1], sizeof fv_obj[1]);
        memcpy(T_wrist[side], Tc, sizeof Tc);
        memcpy(W_orig[side], W, sizeof W);
        solved[side] = 1;
        g_vk.D[side ? 4 : 1] = D1; g_vk.D[side ? 5 : 2] = D2; g_vk.D[side ? 6 : 3] = D3;
        static atomic_uint logged; if (atomic_fetch_add(&logged, 1) % 300 == 0)
            vxmac_log("VRIK: %s arm solved (hand=%d): shoulder (%.2f %.2f %.2f) elbow (%.2f %.2f %.2f)->(%.2f %.2f %.2f) wrist (%.2f %.2f %.2f)->(%.2f %.2f %.2f) reach %.2f/%.2f",
                      side ? "right" : "left", g_vk.have_h[side], S[0], S[1], S[2], E[0], E[1], E[2], E2[0], E2[1], E2[2], W[0], W[1], W[2], T[0], T[1], T[2], d, a + b);
    }

    // ---- Weapon Holding State Machine: Right-Hand / Two-Hand Grip / Left-Hand Carry + 3D Magazine & Slide ----
    static int s_carry_left = 0, s_two_hand = 0;
    static float s_two_w = 0.0f, s_two_ref[3] = { 0, 1, 0 }, s_return_w = 0.0f;
    static aff s_carry_rel = {{1,0,0,0, 0,1,0,0, 0,0,1,0}};
    static aff s_last_D_gun = {{1,0,0,0, 0,1,0,0, 0,0,1,0}};
    static aff s_return_from = {{1,0,0,0, 0,1,0,0, 0,0,1,0}};

    aff D_gun = g_vk.D[6];
    float left_grip  = (g_vk.curls[0][2] + g_vk.curls[0][3] + g_vk.curls[0][4]) / 3.0f;
    float right_grip = (g_vk.curls[1][2] + g_vk.curls[1][3] + g_vk.curls[1][4]) / 3.0f;

    if (solved[0] && solved[1]) {
        float d_lr[3] = { T_wrist[0][0] - T_wrist[1][0], T_wrist[0][1] - T_wrist[1][1], T_wrist[0][2] - T_wrist[1][2] };
        float dist_lr = v3len(d_lr);
        float along = v3dot(d_lr, fv_obj[1]);
        float rad = sqrtf(fmaxf(0.0f, dist_lr * dist_lr - along * along));
        int on_weapon = (dist_lr < 0.48f && along > -0.06f && rad < 0.16f && g_vk.weap[1] < 0.5f && g_vk.slide_pull < 0.005f);

        if (!s_carry_left) {
            if ((on_weapon || s_two_hand) && left_grip >= 0.40f && right_grip < 0.34f) {
                s_carry_left = 1;
                s_two_hand = 0;
                s_two_w = 0.0f;
                s_carry_rel = aff_mul(aff_inv(g_vk.D[3]), s_last_D_gun);
                vxmac_log("VRIK: right hand released -> weapon carried by left hand");
            }
        }
        if (s_carry_left) {
            D_gun = aff_mul(g_vk.D[3], s_carry_rel);
            float P_pistol[3]; aff_pt(D_gun.m, W_orig[1], P_pistol);
            float d_re[3] = { T_wrist[1][0] - P_pistol[0], T_wrist[1][1] - P_pistol[1], T_wrist[1][2] - P_pistol[2] };
            float dist_re = v3len(d_re);
            if ((dist_re < 0.20f && right_grip >= 0.44f) || left_grip < 0.20f) {
                s_carry_left = 0;
                s_return_from = D_gun;
                s_return_w = 1.0f;
                vxmac_log("VRIK: right hand re-acquired weapon grip (dist=%.2f)", dist_re);
            }
        }
        if (!s_carry_left) {
            if (on_weapon && left_grip >= 0.40f && right_grip >= 0.34f) {
                if (!s_two_hand && dist_lr > 0.035f) {
                    float u0[3] = { d_lr[0], d_lr[1], d_lr[2] };
                    if (v3norm(u0)) {
                        aff invD6 = aff_inv(g_vk.D[6]);
                        aff_dir(invD6.m, u0, s_two_ref);
                        s_two_hand = 1;
                    }
                }
                if (s_two_hand && dist_lr > 0.035f) {
                    s_two_w = fminf(1.0f, s_two_w + 0.18f);
                    float u_exp[3], u_cur[3] = { d_lr[0], d_lr[1], d_lr[2] };
                    aff_dir(g_vk.D[6].m, s_two_ref, u_exp);
                    if (v3norm(u_exp) && v3norm(u_cur)) {
                        float lev = fminf(1.0f, fmaxf(0.28f, dist_lr / 0.26f)) * s_two_w;
                        float u_aim[3] = { u_exp[0] + (u_cur[0] - u_exp[0]) * lev,
                                           u_exp[1] + (u_cur[1] - u_exp[1]) * lev,
                                           u_exp[2] + (u_cur[2] - u_exp[2]) * lev };
                        if (v3norm(u_aim)) D_gun = aff_mul(aff_arc(u_exp, u_aim, T_wrist[1]), g_vk.D[6]);
                    }
                }
            } else {
                s_two_hand = 0;
                s_two_w = fmaxf(0.0f, s_two_w - 0.20f);
            }
            if (s_return_w > 0.001f) {
                s_return_w = fmaxf(0.0f, s_return_w - 0.14f);
                for (int i = 0; i < 3; i++)
                    D_gun.m[i*4+3] += (s_return_from.m[i*4+3] - D_gun.m[i*4+3]) * s_return_w;
            }
        }
    } else if (!solved[0] && s_carry_left) {
        s_carry_left = 0;
    }

    s_last_D_gun = D_gun;
    g_vk.carry_left = s_carry_left ? 1.0f : 0.0f;
    g_vk.two_hand   = s_two_w;

    // Weapon axes (gun_fwd, gun_up) and grip pivot in g_vk.obj space
    aff D_rel = aff_mul(D_gun, aff_inv(g_vk.D[6]));
    float gun_fwd[3], gun_up[3], neg_av1[3] = { -av_obj[1][0], -av_obj[1][1], -av_obj[1][2] };
    aff_dir(D_rel.m, fv_obj[1], gun_fwd); v3norm(gun_fwd);
    aff_dir(D_rel.m, neg_av1,   gun_up);  v3norm(gun_up);
    float P_grip[3]; aff_pt(D_gun.m, W_orig[1], P_grip);

    g_vk.D_gun = D_gun;
    g_vk.D_slide = D_gun;
    if (g_vk.slide_pull > 0.001f) {
        for (int i = 0; i < 3; i++) {
            g_vk.D_gun.m[i*4+3]   -= gun_fwd[i] * (g_vk.slide_pull * 0.10f);
            g_vk.D_slide.m[i*4+3] -= gun_fwd[i] * (g_vk.slide_pull * 1.05f);
        }
    }

    // 3D Magazine transform (D_mag): seated (0), in left hand / sliding in well (1), dropped (2)
    g_vk.D_mag = g_vk.D_gun;
    g_vk.mag_scale = 1.0f;
    if (g_vk.weap[1] >= 0.5f && g_vk.weap[1] < 1.5f && solved[0]) {
        float P_well[3], P_off[3], delta[3];
        for (int i = 0; i < 3; i++) {
            P_well[i] = P_grip[i] - 0.065f * gun_up[i] + 0.015f * gun_fwd[i];
            P_off[i]  = T_wrist[0][i] + 0.035f * fv_obj[0][i] - 0.020f * av_obj[0][i];
            delta[i]  = P_off[i] - P_well[i];
        }
        float dist = v3len(delta);
        if (dist < 0.095f) {
            float along_well = fminf(0.01f, v3dot(delta, gun_up));
            float rail_w = fmaxf(0.0f, fminf(1.0f, (dist - 0.025f) / 0.070f));
            for (int i = 0; i < 3; i++) {
                float lat = delta[i] - along_well * gun_up[i];
                delta[i] = along_well * gun_up[i] + lat * rail_w;
            }
        }
        float rot_w = fmaxf(0.0f, fminf(1.0f, (dist - 0.045f) / 0.075f));
        float off_up[3] = { -av_obj[0][0], -av_obj[0][1], -av_obj[0][2] };
        float mag_up[3] = { gun_up[0] + (off_up[0] - gun_up[0]) * rot_w,
                            gun_up[1] + (off_up[1] - gun_up[1]) * rot_w,
                            gun_up[2] + (off_up[2] - gun_up[2]) * rot_w };
        aff R_mag = aff_arc(gun_up, mag_up, P_well);
        aff T_mag = aff_id();
        T_mag.m[3] = delta[0]; T_mag.m[7] = delta[1]; T_mag.m[11] = delta[2];
        g_vk.D_mag = aff_mul(T_mag, aff_mul(R_mag, g_vk.D_gun));
    } else if (g_vk.weap[1] >= 1.5f) {
        float drop_d = g_vk.weap[3] * 0.45f;
        for (int i = 0; i < 3; i++) g_vk.D_mag.m[i*4+3] -= gun_up[i] * (0.10f + drop_d);
        if (g_vk.weap[3] >= 0.85f) g_vk.mag_scale = 0.001f;
    }
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

// Compute finger phalanx transforms (open/close curl + finger splay) in object space before D[3] (left) or D[6] (right)
static void vrik_finger_deltas(int side, const vrik_pal *pal, uint32_t o, aff M_out[128]) {
    for (uint32_t k = 0; k < pal->nb; k++) M_out[k] = aff_id();
    if (!g_vk.have_h[side]) return;
    int rigv = g_vk.rigv;
    int nH = side ? VRIK_RIGHTHAND : VRIK_LEFTHAND;
    int nM = side ? VRIK_RIGHTHANDMIDDLE1 : VRIK_LEFTHANDMIDDLE1;
    int nI = side ? VRIK_RIGHTHANDINDEX1  : VRIK_LEFTHANDINDEX1;
    int nP = side ? VRIK_RIGHTHANDPINKY1  : VRIK_LEFTHANDPINKY1;
    const float *cH = vrik_bindpos(rigv, nH), *cM = vrik_bindpos(rigv, nM), *cI = vrik_bindpos(rigv, nI), *cP = vrik_bindpos(rigv, nP);
    if (!cH || !cM || !cI || !cP) return;

    float fb[3], ab[3], nbv[3];
    for (int i = 0; i < 3; i++) { fb[i] = cM[i] - cH[i]; ab[i] = side ? cI[i] - cP[i] : cP[i] - cI[i]; }
    if (!v3norm(fb)) return;
    float t = v3dot(ab, fb); for (int i = 0; i < 3; i++) ab[i] -= t * fb[i];
    if (!v3norm(ab)) return;
    v3cross(fb, ab, nbv);

    float ax_curl[3], ax_splay[3], ax_thumb[3];
    aff_dir(g_vk.SH[side].m, ab, ax_curl);   v3norm(ax_curl);
    aff_dir(g_vk.SH[side].m, nbv, ax_splay); v3norm(ax_splay);
    float sgn = side ? -1.0f : 1.0f;
    float tb_bind[3] = { 0.55f*fb[0] + sgn*(0.37f*ab[0] + 0.75f*nbv[0]),
                         0.55f*fb[1] + sgn*(0.37f*ab[1] + 0.75f*nbv[1]),
                         0.55f*fb[2] + sgn*(0.37f*ab[2] + 0.75f*nbv[2]) };
    aff_dir(g_vk.SH[side].m, tb_bind, ax_thumb); v3norm(ax_thumb);

    static const int f_jnt[2][4][3] = {
        { { 15, 17, 19 }, { 24, 26, 28 }, { 42, 44, 46 }, { 33, 35, 37 } },     // LeftHandIndex/Middle/Ring/Pinky 1..3
        { { 107, 109, 111 }, { 116, 118, 120 }, { 134, 136, 138 }, { 125, 127, 129 } } // RightHandIndex/Middle/Ring/Pinky 1..3
    };
    static const int f_mscl_mcp[2][4][2] = {
        { { 1590, 1592 }, { 1614, 1616 }, { 1644, 1646 }, { 1626, 1628 } },
        { { 2060, 2062 }, { 2084, 2086 }, { 2114, 2116 }, { 2096, 2098 } }
    };
    static const int f_mscl_pip[2][4] = {
        { 1588, 1612, 1642, 1624 },
        { 2058, 2082, 2112, 2094 }
    };
    static const int t_jnt[2][3] = { { 51, 53, 55 }, { 143, 145, 147 } };
    static const float splay_dirs[4] = { -0.22f, -0.06f, 0.08f, 0.22f };

    // On right hand: when holding the gun (carry_left == 0), only animate the trigger finger (f == 0); when released (carry_left > 0), animate all 5 fingers!
    int right_holding_gun = (side == 1 && g_vk.carry_left < 0.5f);
    float base_curl = (side == 0) ? 0.25f : 0.78f;
    float splay = right_holding_gun ? 0.0f : g_vk.curls[side][5];

    for (int f = 0; f < 4; f++) {
        if (right_holding_gun && f > 0) continue;
        int b1 = -1, b2 = -1, b3 = -1;
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_list[o + k];
            if (nm == f_jnt[side][f][0]) b1 = (int)k;
            else if (nm == f_jnt[side][f][1]) b2 = (int)k;
            else if (nm == f_jnt[side][f][2]) b3 = (int)k;
        }
        if (b1 < 0) continue;
        const float *c1 = vrik_bindpos(rigv, f_jnt[side][f][0]);
        if (!c1) continue;
        float curl = g_vk.curls[side][1 + f];
        float f_base = right_holding_gun ? 0.45f : base_curl;
        float d = curl - f_base;
        float a1 = d < 0 ? d * 1.25f : d * 1.45f;
        float a2 = d < 0 ? d * 1.65f : d * 1.65f;
        float a3 = d < 0 ? d * 1.65f : d * 1.20f;
        float sp_ang = (side ? -splay_dirs[f] : splay_dirs[f]) * splay;

        float p1[3]; aff_pt(pal->orig[b1].m, c1, p1);
        aff R_sp = aff_rot(ax_splay, sp_ang, p1);
        aff M1 = aff_mul(aff_rot(ax_curl, a1, p1), R_sp);
        aff M1_half = aff_mul(aff_rot(ax_curl, 0.5f * a1, p1), R_sp);
        M_out[b1] = M1;

        aff M2 = M1, M2_half = M1;
        if (b2 >= 0) {
            const float *c2 = vrik_bindpos(rigv, f_jnt[side][f][1]);
            if (c2) {
                float p2[3], p2m[3]; aff_pt(pal->orig[b2].m, c2, p2); aff_pt(M1.m, p2, p2m);
                M2 = aff_mul(aff_rot(ax_curl, a2, p2m), M1);
                M2_half = aff_mul(aff_rot(ax_curl, 0.5f * a2, p2m), M1);
                M_out[b2] = M2;
            }
        }
        if (b3 >= 0) {
            const float *c3 = vrik_bindpos(rigv, f_jnt[side][f][2]);
            if (c3) {
                float p3[3], p3m[3]; aff_pt(pal->orig[b3].m, c3, p3); aff_pt(M2.m, p3, p3m);
                M_out[b3] = aff_mul(aff_rot(ax_curl, a3, p3m), M2);
            }
        }
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_list[o + k];
            if (nm == f_mscl_mcp[side][f][0] || nm == f_mscl_mcp[side][f][1]) M_out[k] = M1_half;
            else if (nm == f_mscl_pip[side][f]) M_out[k] = M2_half;
        }
    }

    if (!right_holding_gun) {
        int bt1 = -1, bt2 = -1, bt3 = -1;
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_list[o + k];
            if (nm == t_jnt[side][0]) bt1 = (int)k;
            else if (nm == t_jnt[side][1]) bt2 = (int)k;
            else if (nm == t_jnt[side][2]) bt3 = (int)k;
        }
        if (bt1 >= 0) {
            const float *ct1 = vrik_bindpos(rigv, t_jnt[side][0]);
            if (ct1) {
                float dt = g_vk.curls[side][0] - (side ? 0.65f : 0.25f);
                float at1 = (dt < 0 ? dt * 1.10f : dt * 0.90f) - 0.18f * splay;
                float at2 = (dt < 0 ? dt * 1.10f : dt * 1.05f);
                float pt1[3]; aff_pt(pal->orig[bt1].m, ct1, pt1);
                aff MT1 = aff_rot(ax_thumb, at1, pt1);
                M_out[bt1] = MT1;
                if (bt2 >= 0) {
                    const float *ct2 = vrik_bindpos(rigv, t_jnt[side][1]);
                    if (ct2) {
                        float pt2[3], pt2m[3]; aff_pt(pal->orig[bt2].m, ct2, pt2); aff_pt(MT1.m, pt2, pt2m);
                        aff MT2 = aff_mul(aff_rot(ax_thumb, at2, pt2m), MT1);
                        M_out[bt2] = MT2;
                        if (bt3 >= 0) M_out[bt3] = MT2;
                    }
                }
            }
        }
    }
}

static void vrik_apply_pal(vrik_pal *pal) {
    if ((!g_vk.have_af[0] && !g_vk.have_af[1]) || pal->nb == 0) return;
    if (pal->L >= 0) {
        uint32_t o = vrik_list_off[pal->L];
        int has_fng[2] = { 0, 0 };
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_list[o + k];
            if (nm == VRIK_LEFTHANDINDEX1)  has_fng[0] = 1;
            if (nm == VRIK_RIGHTHANDINDEX1) has_fng[1] = 1;
        }
        aff M_fng[2][128];
        if (has_fng[0]) vrik_finger_deltas(0, pal, o, M_fng[0]);
        if (has_fng[1]) vrik_finger_deltas(1, pal, o, M_fng[1]);
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_list[o + k], s = vrik_seg[nm];
            aff *dst = (aff *)(pal->P + (size_t)k * 48);
            if (s == 3 && has_fng[0]) {
                *dst = aff_mul(g_vk.D[3], aff_mul(M_fng[0][k], pal->orig[k]));
            } else if (s == 6 && has_fng[1]) {
                *dst = aff_mul(g_vk.D[6], aff_mul(M_fng[1][k], pal->orig[k]));
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
    // Otherwise it's a foreground weapon / magazine / attachment mesh
    if ((g_vk.have_af[1] || g_vk.have_af[0]) && vrik_weapon()) {
        // Reject body sub-meshes whose bone 0 is in character model space (|t| > 0.35m)
        float t0_2 = pal->orig[0].m[3]*pal->orig[0].m[3] + pal->orig[0].m[7]*pal->orig[0].m[7] + pal->orig[0].m[11]*pal->orig[0].m[11];
        if (t0_2 > 0.15f) return;
        aff o2v = aff_mul(g_vk.vcam, pal->obj);
        float wpos[3] = { o2v.m[3], o2v.m[7], o2v.m[11] };
        if (v3len(wpos) < 1.5f) {
            aff eff_obj = pal->obj;
            const aff *src_orig = pal->orig;
            if (g_vk.have_h[1]) {
                vrik_weap_rest *wr = NULL;
                for (int w = 0; w < g_vk_nwrest; w++) {
                    if (g_vk_wrest[w].nb == pal->nb && g_vk_wrest[w].count == pal->count) { wr = &g_vk_wrest[w]; break; }
                }
                if (!wr && g_vk_nwrest < 32) {
                    wr = &g_vk_wrest[g_vk_nwrest++];
                    wr->nb = pal->nb; wr->count = pal->count; wr->valid = 0;
                }
                aff h1_world = aff_mul(g_vk.obj, g_vk.SH[1]);
                if (wr && g_vk.weap[4] < 0.5f && t0_2 < 0.04f) {
                    wr->rest_rel = aff_mul(aff_inv(h1_world), pal->obj);
                    memcpy(wr->rest_orig, pal->orig, (size_t)pal->nb * sizeof(aff));
                    wr->valid = 1;
                } else if (wr && wr->valid && g_vk.weap[4] >= 0.5f) {
                    eff_obj = aff_mul(h1_world, wr->rest_rel);
                    src_orig = wr->rest_orig;
                }
            }
            int is_mag = (pal->nb >= 4 && pal->nb <= 7 && pal->count != 5916 && pal->count != 3918);
            int is_frame = (pal->nb >= 8);
            aff inv_pobj = aff_inv(pal->obj);
            if (is_mag) {
                aff Dw_mag = aff_mul(g_vk.obj, aff_mul(g_vk.D_mag, aff_inv(g_vk.obj)));
                aff D_weap_mag = aff_mul(inv_pobj, aff_mul(Dw_mag, eff_obj));
                for (uint32_t k = 0; k < pal->nb; k++) {
                    aff *dst = (aff *)(pal->P + (size_t)k * 48);
                    aff M = aff_mul(D_weap_mag, src_orig[k]);
                    if (g_vk.mag_scale < 0.99f) {
                        for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) M.m[r*4+c] *= g_vk.mag_scale;
                    }
                    *dst = M;
                }
            } else {
                aff Dw_gun   = aff_mul(g_vk.obj, aff_mul(g_vk.D_gun,   aff_inv(g_vk.obj)));
                aff Dw_slide = aff_mul(g_vk.obj, aff_mul(g_vk.D_slide, aff_inv(g_vk.obj)));
                aff D_weap_gun   = aff_mul(inv_pobj, aff_mul(Dw_gun,   eff_obj));
                aff D_weap_slide = aff_mul(inv_pobj, aff_mul(Dw_slide, eff_obj));
                for (uint32_t k = 0; k < pal->nb; k++) {
                    aff *dst = (aff *)(pal->P + (size_t)k * 48);
                    int slide_bone = is_frame && (k == 5 || k == 6 || (pal->nb >= 14 && (k == 8 || k == 9 || k == 11)));
                    *dst = aff_mul(slide_bone ? D_weap_slide : D_weap_gun, src_orig[k]);
                }
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
    // Reset per-pass state ONLY at the start of a foreground viewport pass (vm->draw_idx == 0), NEVER mid-pass from compositor g_frame
    if (vm->draw_idx++ == 0) {
        g_vk.nprev_pals = g_vk.npals;
        for (int i = 0; i < g_vk.npals; i++) g_vk.prev_pals[i] = g_vk.pals[i];
        g_vk.have_af[0] = g_vk.have_af[1] = 0;
        g_vk.have_h[0] = g_vk.have_h[1] = 0;
        for (int s = 0; s < 7; s++) g_vk.D[s] = aff_id();
        g_vk.D_gun = g_vk.D_slide = g_vk.D_mag = aff_id();
        g_vk.mag_scale = 1.0f;
        g_vk.carry_left = 0;
        g_vk.nknown = 0;
        g_vk.npals = 0;
    }

    vrik_pal *pal = NULL;
    for (int i = 0; i < g_vk.npals; i++) {
        if (g_vk.pals[i].P == P) { pal = &g_vk.pals[i]; break; }
    }
    if (!pal) {
        if (g_vk.npals >= 64) { pthread_mutex_unlock(&g_vk_l); return; }
        uint32_t max_b = (uint32_t)(pav / 48);
        if (max_b > 128) max_b = 128;
        pal = &g_vk.pals[g_vk.npals++];
        pal->P = P; pal->max_b = max_b; pal->nb = 0; pal->L = -2; pal->applied = 0; pal->obj = obj; pal->count = (uint32_t)count;
        // If a previous pass in the same game frame already modified P in-place, restore its unmodified orig matrices
        int from_prev = 0;
        for (int j = 0; j < g_vk.nprev_pals; j++) {
            vrik_pal *pr = &g_vk.prev_pals[j];
            if (pr->P == P && pr->applied && pr->nb > 0 && pr->nb <= max_b &&
                vrik_same_bone((const aff *)P, &pr->mod0) &&
                vrik_same_bone((const aff *)(P + (size_t)(pr->nb - 1) * 48), &pr->modlast)) {
                uint32_t copy_b = max_b <= pr->max_b ? max_b : pr->max_b;
                memcpy(pal->orig, pr->orig, (size_t)copy_b * 48);
                if (max_b > copy_b) memcpy(pal->orig + copy_b, P + (size_t)copy_b * 48, (size_t)(max_b - copy_b) * 48);
                from_prev = 1;
                break;
            }
        }
        if (!from_prev) memcpy(pal->orig, P, (size_t)max_b * 48);
    }

    // Always identify using the unmodified pal->orig matrices, never modified P
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
                if (pal->L < 0 || nb > pal->nb) {
                    pal->L = L; pal->nb = nb; pal->obj = obj; pal->applied = 0;
                    state_changed = 1;
                }
                g_vk.rigv = rigv; g_vk.obj = obj; g_vk.vcam = vcam;
                #define BONE(nm) ({ int _b = -1; for (uint32_t _k = 0; _k < nb; _k++) if (vrik_list[o + _k] == (nm)) { _b = (int)_k; break; } _b; })
                for (int side = 0; side < 2; side++) {
                    int bA = BONE(side ? VRIK_RIGHTARM : VRIK_LEFTARM);
                    int bF = BONE(side ? VRIK_RIGHTFOREARM : VRIK_LEFTFOREARM);
                    int bH = BONE(side ? VRIK_RIGHTHAND : VRIK_LEFTHAND);
                    if (!g_vk.have_af[side] && bA >= 0 && bF >= 0) {
                        g_vk.SA[side] = pal->orig[bA]; g_vk.SF[side] = pal->orig[bF];
                        g_vk.have_af[side] = 1; state_changed = 1;
                    }
                    if (!g_vk.have_h[side] && bH >= 0) {
                        g_vk.SH[side] = pal->orig[bH];
                        g_vk.have_h[side] = 1; state_changed = 1;
                    }
                }
                #undef BONE
            }
        }
    } else if (pal->L == -2) {
        pal->L = -1;
        pal->nb = rot > pal->max_b ? pal->max_b : rot;
        pal->obj = obj;
    }

    if (state_changed) {
        vrik_solve_all();
        for (int i = 0; i < g_vk.npals; i++) vrik_apply_pal(&g_vk.pals[i]);
    } else if (!pal->applied) {
        vrik_apply_pal(pal);
    }
    pthread_mutex_unlock(&g_vk_l);
}
