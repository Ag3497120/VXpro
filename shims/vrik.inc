#include "../vr/hand_weapon.h"
#include "../vr/weapon_contact.h"
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
#include <simd/simd.h>
#include "vrik_assets.inc"

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

typedef struct {
    aff room, recovery_from;
    double live_at, recovery_at, lost_at;
    unsigned frame, epoch;
} vrik_pose_memory;

static aff vrik_lower_held_pose(aff pose, aff room_from_view, double elapsed) {
    // Keep short gaps stationary. On a sustained loss lower the foreground
    // below the view without changing opacity in the game's material passes.
    float t = fminf(1.f, fmaxf(0.f, (float)(elapsed - .25) / .30f));
    float drop = 2.4f * t * t * (3.f - 2.f * t);
    for (int i = 0; i < 3; i++) pose.m[i*4+3] -= room_from_view.m[i*4+1] * drop;
    return pose;
}

static aff vrik_blend_pose(aff from, aff to, aff room_from_view, float t) {
    if (t <= 0.f) return from;
    if (t >= 1.f) return to;
    // Interpolate the same rigid correction for each part of the weapon.
    aff relative = aff_mul(to, aff_inv(from));
    simd_float3x3 rotation;
    for (int i = 0; i < 3; i++)
        rotation.columns[i] = (simd_float3){relative.m[i], relative.m[4+i], relative.m[8+i]};
    simd_quatf turn = simd_slerp(simd_quaternion(0.f, (simd_float3){1,0,0}), simd_quaternion(rotation), t);
    simd_float3x3 blended = simd_matrix3x3(turn);
    aff step = aff_id();
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) step.m[i*4+j] = blended.columns[j][i];
    float eye[3] = { room_from_view.m[3], room_from_view.m[7], room_from_view.m[11] };
    float moved_eye[3]; aff_pt(relative.m, eye, moved_eye);
    for (int i = 0; i < 3; i++)
        step.m[i*4+3] = eye[i] + t * (moved_eye[i] - eye[i]) - v3dot(step.m + i*4, eye);
    return aff_mul(step, from);
}

static int vrik_held_pose(vrik_pose_memory *memory, aff room_from_view, unsigned frame, unsigned epoch,
                          double now, int wrist_tracked, int rigid_grip, const aff *live, aff *out) {
    int known = memory->live_at > 0 && memory->epoch == epoch;
    if (!live) {
        if (!known) return 0;
        if (wrist_tracked) memory->lost_at = 0;
        else if (!memory->lost_at) memory->lost_at = now;
        *out = memory->lost_at > 0 ? vrik_lower_held_pose(memory->room, room_from_view, now - memory->lost_at) : memory->room;
        return 1;
    }
    if (rigid_grip || !known) {
        memory->epoch = epoch;
        memory->recovery_at = 0;
    } else if (frame - memory->frame > 1 || memory->lost_at > 0) {
        memory->recovery_from = memory->lost_at > 0
            ? vrik_lower_held_pose(memory->room, room_from_view, now - memory->lost_at) : memory->room;
        memory->recovery_at = now;
    }
    memory->lost_at = 0;
    float t = memory->recovery_at > 0 ? fminf(1.f, fmaxf(0.f, (float)(now - memory->recovery_at) / .16f)) : 1.f;
    memory->room = vrik_blend_pose(memory->recovery_from, *live, room_from_view, t * t * (3.f - 2.f * t));
    memory->live_at = now;
    memory->frame = frame;
    *out = memory->room;
    return 1;
}

static int vrik_weapon(void) { static int on = -1; if (on < 0) { const char *v = getenv("VXMAC_VRIK_WEAPON"); on = !(v && !strcmp(v, "0")); } return on; }
static int vrik_on(void) {
    static int on=-1;static int (*tracking)(void);static dispatch_once_t once;
    if(on<0) {const char *v=getenv("VXMAC_VRIK");on=!(v && !strcmp(v,"0"));}
    dispatch_once(&once,^{tracking=dlsym(RTLD_DEFAULT,"vx_xros_vr_tracking_enabled");});
    return on && (!tracking || tracking());
}
static int vrik_joy_hold(void) {
    static int on = -1;
    if (on < 0) {
        const char *joy = getenv("VXMAC_JOY_HOLD"), *bare = getenv("VXMAC_FULL_HAND");
        on = (joy && !strcmp(joy, "1")) || (bare && !strcmp(bare, "1"));
    }
    return on;
}

static int vrik_replay_enabled(void) {
    static int enabled;static dispatch_once_t once;
    dispatch_once(&once,^{const char *v=getenv("VXMAC_VRIK_CAPTURE");enabled=v && !strcmp(v,"1");});
    return enabled;
}

// Bone names belong to geometry, not its changing skinning-arena offset.
typedef struct { const void *ib; NSUInteger io, count; unsigned touch; int list, rigv; } vrik_mesh;
static vrik_mesh g_vk_mesh[256]; static int g_vk_nmesh; static pthread_mutex_t g_vk_l = PTHREAD_MUTEX_INITIALIZER;
static unsigned g_vk_mesh_clock;
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

static int vrik_cached_body(const uint8_t *P, unsigned cap, int list, int rig) {
    unsigned start=vrik_list_off[list],count=vrik_list_off[list+1]-start;
    if(count>cap)return 0;
    int body=0;
    for(unsigned k=0;k<count && k<15;k++) {
        const float *m=(const float *)(P+k*48);
        if(m[3]*m[3]+m[7]*m[7]+m[11]*m[11]>.12f)body=1;
    }
    if(!body)return 0;
    // Named wrist/elbow continuity checks survive native muscle-bone scaling.
    // Requiring every volume helper to be a pure rotation would invalidate an
    // otherwise unchanged mesh whenever the game's elbow animation deforms it.
    for(unsigned k=0;k<count;k++) {
        int name=vrik_list[start+k],parent=vrik_list_par[start+k];
        if(parent<0 || (name!=VRIK_LEFTHAND && name!=VRIK_RIGHTHAND &&
                       name!=VRIK_LEFTFOREARM && name!=VRIK_RIGHTFOREARM))continue;
        const float *point=vrik_bindpos(rig,name);if(!point)continue;
        const float *a=(const float *)(P+k*48),*b=(const float *)(P+parent*48);
        if(!vrik_is_bone(a)||!vrik_is_bone(b))return 0;
        float x[3],y[3];aff_pt(a,point,x);aff_pt(b,point,y);
        float d[3]={x[0]-y[0],x[1]-y[1],x[2]-y[2]};
        if(v3len(d)>.02f)return 0;
    }
    return 1;
}

static int vrik_identify(const void *ib, NSUInteger io, NSUInteger count, uint32_t isd0, const uint8_t *orig_P, uint32_t cap_b, uint32_t max_b, uint32_t strict_rot, int *rigv) {
    vrik_mesh *cached=NULL;
    unsigned touch=++g_vk_mesh_clock;
    for (int i = 0; i < g_vk_nmesh; i++) {
        if (g_vk_mesh[i].ib == ib && g_vk_mesh[i].io == io && g_vk_mesh[i].count == count) {
            cached=&g_vk_mesh[i];cached->touch=touch;
            int cL = g_vk_mesh[i].list, cv = g_vk_mesh[i].rigv;
            if (cL >= 0) {
                uint32_t need_nb = vrik_list_off[cL + 1] - vrik_list_off[cL];
                if (need_nb <= cap_b && vrik_cached_body(orig_P,cap_b,cL,cv)) {
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
    if (!cached) {
        if (g_vk_nmesh<256) cached=&g_vk_mesh[g_vk_nmesh++];
        else {
            cached=&g_vk_mesh[0];
            for(int i=1;i<256;i++)if(g_vk_mesh[i].touch<cached->touch)cached=&g_vk_mesh[i];
        }
    }
    *cached=(vrik_mesh){ib,io,count,touch,best,bestv};
    static unsigned logged;
    if (logged++<64) {
        if (best >= 0) vxmac_log("VRIK: a foreground mesh (%lu indices, max_b=%u, strict=%u) is list %d (%u bones, %s rig, score %d)", (unsigned long)count, max_b, strict_rot, best, vrik_list_off[best + 1] - vrik_list_off[best], bestv ? "man" : "woman", bestg);
        else vxmac_log("VRIK: a foreground mesh (%lu indices, max_b=%u, strict=%u) is none of V's", (unsigned long)count, max_b, strict_rot);
    }
    *rigv = bestv;
    return best;
}

// ---- persistent state: cross-palette arm/hand/finger solver + multi-pass safe palette cache -------------------------
#include "../app/Sources/weapon_bridge.h"
typedef struct { aff orig, mod; int seg; } vrik_known_bone;
typedef struct { float at[3], fwd[3], up[3]; } vrik_grip_pose;
enum { VRIK_SATARA_SHELL = 6, VRIK_SARATOGA_MAG, VRIK_CATALOG_AMMO, VRIK_RECEIVER = 32, VRIK_ASSET_BASE = 128 };
typedef struct { unsigned ejection; int mesh; aff pose; } vrik_mag_drop;
typedef struct {
    const void *indices;
    NSUInteger offset, count;
    vrik_grip_pose grip, support, first_native;
    unsigned samples, last_frame;
    int support_valid, bore_sign;
    vrik_pose_memory drawn;
    vrik_mag_drop shell_drop;
    aff slide_rest; unsigned slide_epoch; int slide_valid;
    int slide_pending;
    float slide_shown, slide_release_from;
    double slide_release_at;

} vrik_item_grip;
typedef struct {
    uint8_t *P;
    const uint8_t *source;
    uint64_t source_gpu;
    size_t source_offset;
    size_t source_bytes;
    uint64_t capture_id;
    uint32_t cap_b, max_b, strict_rot, nb;
    const void *indices;
    NSUInteger index_offset, count;
    int L, rig, applied, mod_k1, mod_k2, magazine, receiver, support_connected, needs_held_identity;
    const vrik_asset_profile *asset;
    const vrik_asset_profile *body_profile;
    const vrik_asset_profile *body_identity;
    unsigned stamp, frame;
    aff obj, view, mod1, mod2;
    aff orig[128];
    aff posed[128];
} vrik_pal;
static int vrik_pal_name(const vrik_pal *pal,unsigned k) {
    return pal->body_profile?pal->body_profile->body_names[k]:vrik_list[vrik_list_off[pal->L]+k];
}
static int vrik_named_skin_valid(const vrik_pal *pal) {
    if(!pal->body_profile || pal->body_profile->bones>pal->cap_b)return 0;
    int translated=0;
    for(unsigned k=0;k<pal->body_profile->bones;k++) {
        const float *m=pal->orig[k].m;
        // An exact mesh identity supplies the length. Muscle/volume helper
        // matrices may legitimately shear or collapse; they are not evidence
        // that this palette ended after its first few rotational matrices.
        for(int i=0;i<12;i++)if(!isfinite(m[i]) || fabsf(m[i])>32)return 0;
        translated|=m[3]*m[3]+m[7]*m[7]+m[11]*m[11]>.12f;
    }
    return translated;
}

// Skin matrices include the mesh's own inverse bind transform. A bone name
// alone cannot share a frozen matrix between the hand and its cyberware.
typedef struct {
    const void *indices;
    NSUInteger offset, count;
    int list, rig;
    unsigned touch, generation, bones;
    aff in_hand[128];
    uint8_t valid[128];
} vrik_support_shape;

extern int vxmtl_retain_for_encoder(id encoder, id resource);
extern id vxmtl_command_buffer_for_encoder(id encoder);
@interface VXPoseCopy : NSObject {
@public uint64_t capture_id;
    aff object;
    unsigned frame;
    int sealed, posed, late;
    NSUInteger indices;
    unsigned kind;
    __weak id<MTLCommandBuffer> command;
    id<MTLBuffer> buffer;
}
@end
@implementation VXPoseCopy
@end
static NSMutableDictionary<NSData *, VXPoseCopy *> *g_pose_buffers;
static unsigned g_pose_buffers_frame;
static atomic_ulong g_pose_copy_bytes, g_pose_copy_us, g_pose_copy_max_us;
static atomic_ulong g_pose_bound, g_pose_skipped, g_pose_unposed, g_pose_copy_peak_bytes;
static atomic_ulong g_pose_rebased;
static uint64_t g_pose_capture_id;

void vxpipe_pose_copy_stats(char *out, unsigned size) {
    snprintf(out, size, "\"pose_copy\":{\"bytes\":%lu,\"us\":%lu,\"max_us\":%lu,\"peak_bytes\":%lu,\"bound\":%lu,\"skipped\":%lu,\"unposed\":%lu,\"rebased\":%lu}",
             atomic_load(&g_pose_copy_bytes), atomic_load(&g_pose_copy_us), atomic_load(&g_pose_copy_max_us),
             atomic_load(&g_pose_copy_peak_bytes), atomic_load(&g_pose_bound), atomic_load(&g_pose_skipped), atomic_load(&g_pose_unposed), atomic_load(&g_pose_rebased));
}

// Never publish into the game's source palette. Other meshes, passes and
// frames can read it after this draw. Different palette consumers have their
// own copies, including meshes whose native source ranges happen to overlap.
static void vrik_publish_palette(const vrik_pal *pal) {
    if (!pal->source_gpu || !pal->applied || pal->mod_k1 < 0 || pal->mod_k2 < pal->mod_k1) return;
    if (g_pose_buffers_frame != pal->frame) return;
    for (VXPoseCopy *entry in g_pose_buffers.allValues) {
        id<MTLCommandBuffer> cb = entry->command;
        if (entry->capture_id != pal->capture_id || memcmp(&entry->object, &pal->obj, sizeof(aff)) || entry->frame != pal->frame) continue;
        size_t offset = (size_t)pal->mod_k1 * 48;
        size_t bytes = (size_t)(pal->mod_k2 - pal->mod_k1 + 1) * 48;
        if (offset > entry->buffer.length || bytes > entry->buffer.length - offset) continue;
        if(entry->sealed || !cb || cb.status>=MTLCommandBufferStatusCommitted) {
            static unsigned reports;
            if(vrik_replay_enabled() && reports<24 && !entry->late &&
               memcmp((uint8_t *)entry->buffer.contents+offset,pal->P+offset,bytes)) {
                entry->late=1;reports++;
                vxmac_log("VRIK late pose: frame=%u indices=%lu kind=%u submitted_pose=%d status=%lu",
                          entry->frame,(unsigned long)entry->indices,entry->kind,entry->posed,(unsigned long)cb.status);
            }
            continue;
        }
        memcpy((uint8_t *)entry->buffer.contents + offset, pal->P + (size_t)pal->mod_k1 * 48, bytes);
        entry->posed=1;
    }
}

// Rebase the skinning offset in a private instance record. Consumers with
// overlapping source ranges still need independent outputs. No source vertex
// or instance data is changed.
static id<MTLBuffer> vrik_copy_instance(id encoder, VXEncVM *vm, NSArray *layout,
                                        NSUInteger bi, NSUInteger *binding, int *dynamic, int *rebase) {
    NSUInteger index = [layout[0] unsignedIntegerValue], attr = [layout[1] unsignedIntegerValue];
    NSUInteger stride = [layout[2] unsignedIntegerValue], step = [layout[3] unsignedIntegerValue];
    NSUInteger rate = [layout[4] unsignedIntegerValue];
    NSInteger transform = [layout[6] integerValue];
    if (index >= 31 || index == 2 || transform < 0 ||
        (step != MTLVertexStepFunctionPerInstance && step != MTLVertexStepFunctionConstant)) return nil;
    *dynamic = stride == MTLBufferLayoutStrideDynamic;
    if (*dynamic) stride = vm->vst[index];
    size_t extent = MAX(attr + 16, (NSUInteger)transform + 48);
    if (layout.count > 7) extent = MAX(extent, [layout[7] unsignedIntegerValue]);
    if (step == MTLVertexStepFunctionConstant) { stride = MAX(stride, extent); *rebase = 0; }
    else if (!stride || extent > stride) return nil;
    NSUInteger element = step == MTLVertexStepFunctionConstant ? 0 : bi / (rate ? rate : 1);
    if (element >= NSUIntegerMax / stride) return nil;
    size_t start = *rebase ? element * stride : 0;
    size_t bytes = *rebase ? stride : (element + 1) * stride;
    if (bytes > 256 * 1024) return nil;
    const uint8_t *source = NULL; size_t available = 0;
    NSData *data = vm->vbytes[@(index)];
    if (data) { source = data.bytes; available = data.length; }
    else if (vm->vbuf[index]) {
        id<MTLBuffer> buffer = vm->vbuf[index];
        if (buffer.storageMode == MTLStorageModeShared && vm->voff[index] < buffer.length) {
            source = (const uint8_t *)buffer.contents + vm->voff[index];
            available = buffer.length - vm->voff[index];
        }
    }
    if (!source || start > available || bytes > available - start) return nil;
    id<MTLBuffer> copy = [[encoder device] newBufferWithBytes:source + start length:bytes options:MTLResourceStorageModeShared];
    if (!copy) return nil;
    uint32_t zero = 0;
    size_t target = *rebase ? 0 : element * stride;
    memcpy((uint8_t *)copy.contents + target + attr, &zero, sizeof zero);
    // The velocity pass also reads skin.z. Keep its history in the same posed
    // foreground frame rather than mixing it with the game's untouched arms.
    memcpy((uint8_t *)copy.contents + target + attr + 8, &zero, sizeof zero);
    *binding = index;
    return copy;
}

static int vrik_bind_palette(id encoder, VXEncVM *vm, const uint8_t *top, size_t top_bytes,
                              const uint8_t *table, size_t table_bytes, vrik_pal *pal,
                              NSArray *layout, NSUInteger bi, unsigned span) {
    if (!table || table_bytes < 72 || !pal->P || !pal->cap_b || !top || top_bytes < 56) return 0;
    if (!span || span > 256) return 0;
    id<MTLCommandBuffer> cb = vxmtl_command_buffer_for_encoder(encoder);
    if (!cb || cb.status >= MTLCommandBufferStatusCommitted) return 0;
    unsigned frame = pal->frame;
    if (!g_pose_buffers || g_pose_buffers_frame != frame) {
        g_pose_buffers = [NSMutableDictionary dictionary];
        g_pose_buffers_frame = frame;
    }
    uintptr_t command_identity = (uintptr_t)(__bridge void *)cb;
    uint8_t identity[sizeof command_identity + sizeof pal->capture_id + sizeof pal->obj];
    memcpy(identity, &command_identity, sizeof command_identity);
    memcpy(identity + sizeof command_identity, &pal->capture_id, sizeof pal->capture_id);
    memcpy(identity + sizeof command_identity + sizeof pal->capture_id, &pal->obj, sizeof pal->obj);
    NSData *key = [NSData dataWithBytes:identity length:sizeof identity];
    VXPoseCopy *entry = g_pose_buffers[key];
    if (entry && entry->sealed) return 0;
    double start = CACurrentMediaTime();
    NSUInteger binding; int dynamic, rebase = [objc_getAssociatedObject(vm->pipe, kInstanceRebase) boolValue];
    id<MTLBuffer> instance = vrik_copy_instance(encoder, vm, layout, bi, &binding, &dynamic, &rebase);
    if (!instance) return 0;
    size_t bone_bytes = (size_t)span * 48;
    id<MTLBuffer> copy = entry ? entry->buffer : nil;
    if (!copy) {
        copy = [[encoder device] newBufferWithLength:bone_bytes options:MTLResourceStorageModeShared];
        if (!copy) return 0;
        memset(copy.contents, 0, bone_bytes);
        size_t native_bytes = pal->source ? pal->source_bytes : (size_t)pal->cap_b * 48;
        memcpy(copy.contents, pal->source ?: (const uint8_t *)pal->orig, MIN(native_bytes, bone_bytes));
        copy.label = @"VX Mac immutable-source pose copy";
        entry = [VXPoseCopy new];
        entry->capture_id = pal->capture_id; entry->object = pal->obj;
        entry->frame = frame; entry->command = cb; entry->buffer = copy;
        entry->indices=pal->count;entry->kind=pal->asset?pal->asset->kind:pal->body_identity?128:0;
        g_pose_buffers[key] = entry;
        vrik_publish_palette(pal);
        atomic_fetch_add(&g_pose_copy_bytes, bone_bytes);
        unsigned long peak = atomic_load(&g_pose_copy_peak_bytes);
        while (bone_bytes > peak && !atomic_compare_exchange_weak(&g_pose_copy_peak_bytes, &peak, bone_bytes)) {}
    }
    id<MTLBuffer> arguments = [[encoder device] newBufferWithLength:8192 options:MTLResourceStorageModeShared];
    if (!arguments || !vxmtl_retain_for_encoder(encoder, copy) ||
        !vxmtl_retain_for_encoder(encoder, arguments) || !vxmtl_retain_for_encoder(encoder, instance)) return 0;
    uint8_t *dst = arguments.contents;
    memset(dst, 0, 8192);
    memcpy(dst, top, MIN(top_bytes, (size_t)4096));
    memcpy(dst + 4096, table, MIN(table_bytes, (size_t)4096));
    uint64_t address = arguments.gpuAddress + 4096;
    memcpy(dst + 48, &address, 8);
    address = copy.gpuAddress;
    memcpy(dst + 4096 + 48, &address, 8);
    atomic_fetch_add(&g_pose_copy_bytes, 8192 + instance.length);
    unsigned long us = (unsigned long)((CACurrentMediaTime() - start) * 1e6);
    atomic_fetch_add(&g_pose_copy_us, us);
    unsigned long peak = atomic_load(&g_pose_copy_max_us);
    while (us > peak && !atomic_compare_exchange_weak(&g_pose_copy_max_us, &peak, us)) {}
    [encoder useResource:copy usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
    [encoder useResource:arguments usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
    if (dynamic) o_svbs(encoder, @selector(setVertexBuffer:offset:attributeStride:atIndex:), instance, 0, vm->vst[binding], binding);
    else o_svb2(encoder, @selector(setVertexBuffer:offset:atIndex:), instance, 0, binding);
    o_svb2(encoder, @selector(setVertexBuffer:offset:atIndex:), arguments, 0, 2);
    vm->pose_bound = 1; vm->pose_instance = binding; vm->pose_instance_dynamic = dynamic; vm->pose_rebase = rebase;
    if (rebase) atomic_fetch_add(&g_pose_rebased, 1);
    return 1;
}

// Joy-Con button bitmask passed from host.m -> xros_vr.m -> weap[5]
#define VRIK_BTN_L_GRAB  (1u << 0)   // Left Joy-Con L shoulder or L3 stick click
#define VRIK_BTN_L_TRIG  (1u << 1)   // Left Joy-Con ZL trigger
#define VRIK_BTN_R_GRAB  (1u << 2)   // Right Joy-Con R shoulder or R3 stick click
#define VRIK_BTN_R_TRIG  (1u << 3)   // Right Joy-Con ZR trigger

static struct {
    unsigned solve_frame, capture_frame;
    int capture_started, capture_body, hands_started;
    int have_af[2];   // 1 = true LeftArm/RightArm (SA) + LeftForeArm/RightForeArm (SF) captured in cur_frame
    int have_h[2];    // 1 = true LeftHand/RightHand (SH) captured in cur_frame
    aff SA[2], SF[2], SH[2], hand_ref[2];
    unsigned hand_ref_mask;
    int rigv;
    aff obj, vcam;
    aff D[7];
    aff D_w0[2], D_w1[2], D_w2[2];   // Forearm-to-wrist twist distribution matrices (Wrist_0, Wrist_1, Wrist_2)
    aff D_gun;
    int gun_hand;                    // 1 = right hand holds weapon, 0 = left hand holds weapon
    int native_support, weapon_solved, weapon_origin_valid;
    float weapon_grip_world[3];
    struct {
        aff hand, on_forearm;
        int rig, has_forearm;
        double at;
    } authored_grip[2];
    vrik_item_grip item_grips[96];
    aff right_grip_fingers[29];
    uint32_t right_grip_fingers_valid;
    int right_grip_finger_rig;
    vrik_grip_pose native_item_grip, native_item_support;
    aff posed_left_hand, left_rest_hand, right_rest_hand;
    int right_rest_valid;
    vrik_grip_pose item_target, support_local;
    int support_local_owner, support_contact_owner;
    double support_local_at, support_contact_at;
    struct {
        int locked;
        unsigned epoch;
        unsigned generation, clock;
        vrik_support_shape shapes[32];
    } support_pose;
    float well_room[3], rack_room[6];
    int reload_owner, reload_mesh, rack_valid, rack_auto;
    double reload_at, rack_at;
    unsigned item_target_frame;
    struct {
        int owner, rig;
        unsigned epoch, wrists;
        double at;
        aff room_from_view, wrist_view, grip_from_wrist;
        vrik_pose_memory right_grip;
        unsigned right_grip_frame;
        int right_grip_valid;
        aff right_grip_view, right_wrist_from_palm;
        int right_bind_valid, right_bind_rig;
        unsigned grip_epoch;
        int grip_calibrated;
        float hands[2][12];
        int hands_ok[2];
        struct { vrik_pose_memory pose; aff in_grip; } arm[VRIK_NNAMES];
    } held;
    int item_target_owner, item_target_valid;
    int item_support_valid;
    struct {
        unsigned frame, epoch;
        int valid, support_valid, asset;
        unsigned count;
        aff world_delta, view_from_world;
        vrik_grip_pose native_world, support_world;
    } weapon_frame;
    struct {
        unsigned epoch, seen_frame, revision;
        unsigned count;
        uint16_t asset;
        int valid;
        aff in_root;
    } asset_grip;
    struct { int ready, count; float points[32][3]; } hand_shape[2];
    struct { int valid; aff hand, finger; } trigger_source;
    struct { unsigned epoch, clock; vrik_support_shape shapes[32]; } holding_pose;
    unsigned reload_frame;
    int reload_priority;
    vrik_mag_drop dropped_mag;
    struct { double started; unsigned epoch; int mesh; aff from_palm; } held_mag;
    double item_target_at, contacts_at, support_at;
    int contacts_owner;
    unsigned contacts_frame;
    NSUInteger contact_indices;
    float contact_room[3], support_room[3];
    float bore_room[10];
    double bore_at;
    float two_hand;
    float curls[2][6];
    float weap[8];
    float slide_pull;
    vrik_grip_pose slide_hand;
    int slide_active;
    vrik_grip_pose contact_hand;
    int contact_active, contact_previous_valid;
    float contact_previous[3];
    unsigned contact_epoch;

    unsigned call_seq;
    vrik_known_bone known[192];
    int nknown;
    vrik_pal pals[128];
    int npals;
} g_vk;
static atomic_uint g_vk_supported_at;

static int vrik_equipment_allows(const vrik_asset_profile *asset) {
    static vx_weapon_snapshot (*snapshot)(void);
    static vx_game_context (*context)(void);
    static dispatch_once_t once;
    dispatch_once(&once,^{snapshot=dlsym(RTLD_DEFAULT,"vx_weapon_bridge_snapshot");context=dlsym(RTLD_DEFAULT,"vx_weapon_bridge_context");});
    if(!snapshot || !context)return 0;
    vx_weapon_snapshot item=snapshot();vx_game_context game=context();
    if(!item.known || !item.entity || !game.known || game.mounted || game.menu_open || game.scene_tier>1)return 0;
    return (asset->kind&128) || ((asset->kind&64)?!item.ranged:item.ranged);
}

static int vrik_held_consumer(const vrik_pal *pal) {
    if(!pal->needs_held_identity)return 1;
    if(!g_vk.capture_body || g_vk.solve_frame!=pal->frame || g_vk.held.owner!=1)return 0;
    if(pal->body_identity) {
        float d[3]={pal->obj.m[3]-g_vk.obj.m[3],pal->obj.m[7]-g_vk.obj.m[7],pal->obj.m[11]-g_vk.obj.m[11]};
        return v3len(d)<.04f && v3dot(pal->obj.m,g_vk.obj.m)>.995f && v3dot(pal->obj.m+4,g_vk.obj.m+4)>.995f;
    }
    if(!pal->asset || !g_vk.weapon_origin_valid || !vrik_equipment_allows(pal->asset))return 0;
    const vrik_asset_profile *asset=pal->asset;
    if(asset->root<0 || asset->root>=pal->nb)return 0;
    aff root=aff_mul(pal->obj,pal->orig[asset->root]);
    float point[3],hand[3],d[3];aff_pt(root.m,asset->root_at,point);
    aff_pt(aff_inv(g_vk.vcam).m,g_vk.native_item_grip.at,hand);
    for(int i=0;i<3;i++)d[i]=point[i]-hand[i];
    return v3len(d)<.6f;
}

static unsigned vrik_consumer_span(VXEncVM *vm,const vrik_pal *pal) {
    unsigned span=[objc_getAssociatedObject(vm->pipe,kSkinSpan) unsignedIntValue];
    if(!span && (pal->body_identity || pal->asset))
        span=[objc_getAssociatedObject(vm->pipe,kSkinByteInputs) unsignedIntValue];
    return span;
}

static void vrik_binding_note(VXEncVM *vm,const vrik_pal *pal,NSUInteger bi,int bound) {
    if(!vrik_replay_enabled() || (!pal->body_identity && !pal->asset))return;
    static NSMutableSet *seen;
    if(!seen)seen=[NSMutableSet set];
    NSString *hash=objc_getAssociatedObject(vm->pipe,kHash) ?: @"unknown";
    NSString *key=[NSString stringWithFormat:@"%@:%lu:%d:%d:%d",hash,(unsigned long)pal->count,
                   vm->vp_fg,bound,pal->applied];
    if(seen.count>=96 || [seen containsObject:key])return;
    [seen addObject:key];
    vxmac_log("VRIK consumer: shader=%s indices=%lu foreground=%d kind=%u named=%d span=%u base=%lu posed=%d bound=%d",
              hash.UTF8String,(unsigned long)pal->count,vm->vp_fg,
              pal->asset?pal->asset->kind:128,pal->body_profile!=NULL,
              vrik_consumer_span(vm,pal),(unsigned long)bi,pal->applied,bound);
}

// Triangle identity does not distinguish clothing variants with different
// skin layouts. Compare named source joints against other body consumers in
// this frame. Do not interpret the unused tail of the skinning allocation.
static const vrik_asset_profile *vrik_body_select(const vrik_pal *pal,const vrik_asset_profile *identity) {
    const vrik_asset_profile *best=NULL;
    unsigned first=vrik_asset_first(identity->count),variants=0;
    for(unsigned i=first;i<VRIK_ASSET_COUNT && vrik_assets[i].count==identity->count;i++)
        if(vrik_assets[i].hash==identity->hash && (vrik_assets[i].kind&128)) {variants++;best=&vrik_assets[i];}
    if(variants==1) {
        vrik_pal test=*pal;test.body_profile=best;
        return vrik_named_skin_valid(&test)?best:NULL;
    }
    int best_score=-1,runner=-1,best_anchor=0;best=NULL;
    for(unsigned i=first;i<VRIK_ASSET_COUNT && vrik_assets[i].count==identity->count;i++) {
        const vrik_asset_profile *candidate=&vrik_assets[i];
        if(candidate->hash!=identity->hash || !(candidate->kind&128))continue;
        vrik_pal test=*pal;test.body_profile=candidate;
        if(!vrik_named_skin_valid(&test))continue;
        uint8_t matched[128]={0};int score=0,anchor=0;
        for(int p=0;p<g_vk.npals;p++) {
            const vrik_pal *reference=&g_vk.pals[p];
            if(reference==pal || reference->frame!=pal->frame || reference->L<0 || !reference->nb || reference->body_identity)continue;
            aff relative=aff_mul(aff_inv(reference->obj),pal->obj);
            for(unsigned k=0;k<candidate->bones;k++)if(!matched[k]) {
                aff source=aff_mul(relative,pal->orig[k]);
                for(unsigned j=0;j<reference->nb;j++)if(vrik_pal_name(reference,j)==candidate->body_names[k]) {
                    float error=0;
                    for(int n=0;n<12;n++)error=fmaxf(error,fabsf(source.m[n]-reference->orig[j].m[n]));
                    if(error<.025f) {
                        matched[k]=1;score++;
                        int name=candidate->body_names[k];
                        if(error<.005f && (name==VRIK_LEFTFOREARM || name==VRIK_RIGHTFOREARM))anchor=1;
                    }
                    break;
                }
            }
        }
        if(score>best_score) {runner=best_score;best_score=score;best_anchor=anchor;best=candidate;}
        else runner=MAX(runner,score);
    }
    return (best_score>=2 || best_anchor) && best_score>runner ? best : NULL;
}

static int vrik_body_resolve(vrik_pal *pal) {
    if(!pal->body_identity)return 0;
    const vrik_asset_profile *profile=vrik_body_select(pal,pal->body_identity);
    if(!profile)return 0;
    pal->body_profile=profile;pal->L=profile->body_list;pal->nb=profile->bones;
    pal->rig=g_vk.rigv;pal->applied=0;
    return 1;
}

// The commit hook closes publication under the same lock as the pose writer.
// Checking MTLCommandBuffer.status alone leaves a check-to-commit race.
void vxpipe_pose_seal_command_buffer(id command) {
    pthread_mutex_lock(&g_vk_l);
    for (VXPoseCopy *entry in g_pose_buffers.allValues)
        if (entry->command == command) entry->sealed = 1;
    pthread_mutex_unlock(&g_vk_l);
}

int vxpipe_supported_grip(void) {
    pthread_mutex_lock(&g_vk_l);
    int supported = g_vk.support_at > 0 && CACurrentMediaTime() - g_vk.support_at <= .30;
    pthread_mutex_unlock(&g_vk_l);
    return supported;
}

int vxpipe_drawn_weapon_contacts(int owner, const float free_palm[3], float out[2]) {
    pthread_mutex_lock(&g_vk_l);
    double now = CACurrentMediaTime();
    int valid = owner == g_vk.contacts_owner && now - g_vk.contacts_at <= .18;
    int support_valid = owner == g_vk.support_contact_owner && now - g_vk.support_contact_at <= .18;
    if (valid) out[0] = v3len((float[3]){g_vk.contact_room[0] - free_palm[0], g_vk.contact_room[1] - free_palm[1],
                                        g_vk.contact_room[2] - free_palm[2]});
    if (support_valid) out[1] = v3len((float[3]){g_vk.support_room[0] - free_palm[0], g_vk.support_room[1] - free_palm[1],
                                                g_vk.support_room[2] - free_palm[2]});
    pthread_mutex_unlock(&g_vk_l);
    return valid || support_valid;
}

int vxpipe_weapon_reload_targets(int owner, float well[3], float rack[6], int *has_rack, int *auto_chamber) {
    pthread_mutex_lock(&g_vk_l);
    double now = CACurrentMediaTime();
    int mesh = owner == g_vk.reload_owner && g_vk.reload_at > 0 && now - g_vk.reload_at <= .18
        ? g_vk.reload_mesh : 0;
    *has_rack = owner == g_vk.held.owner && now - g_vk.rack_at <= .18 ? g_vk.rack_valid : 0;
    // Use known receiver / magazine meshes only to choose the visual grab.
    // The game uses its equipped item to decide whether a slide is required.
    *auto_chamber = *has_rack ? g_vk.rack_auto : mesh >= 4;
    if (mesh) memcpy(well, g_vk.well_room, sizeof g_vk.well_room);
    if (*has_rack) memcpy(rack, g_vk.rack_room, sizeof g_vk.rack_room);
    pthread_mutex_unlock(&g_vk_l);
    return mesh;
}

double vxpipe_drawn_weapon_direction(float out[10]) {
    pthread_mutex_lock(&g_vk_l);
    double at = g_vk.bore_at;
    if (at) memcpy(out, g_vk.bore_room, sizeof g_vk.bore_room);
    pthread_mutex_unlock(&g_vk_l);
    return at;
}

static aff vrik_room_from_view(const float head[16]) {
    aff result;
    for (int i = 0; i < 3; i++) {
        result.m[i*4] = head[i];
        result.m[i*4+1] = head[4+i];
        result.m[i*4+2] = -head[8+i];
        result.m[i*4+3] = head[12+i];
    }
    return result;
}

static void vrik_publish_right_grip(void);

static void vrik_held_begin_frame(aff camera) {
    g_vk.held.owner = -1;
    g_vk.slide_active = g_vk.contact_active = 0;
    g_vk.held.right_grip_valid = 0;
    g_vk.held.at = CACurrentMediaTime();
    g_vk.held.wrists = 0;
    memset(g_vk.held.hands_ok, 0, sizeof g_vk.held.hands_ok);
    static int (*query)(float[2][12], int[2], float[16], unsigned *, unsigned *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ query = dlsym(RTLD_DEFAULT, "vx_xros_vr_render_hands"); });
    if (!query) return;
    float head[16]; unsigned epoch, wrists;
    int owner = query(g_vk.held.hands, g_vk.held.hands_ok, head, &epoch, &wrists);
    if (!owner || !vrik_joy_hold()) return;
    int side = owner - 1;
    g_vk.held.owner = side;
    if (g_vk.held.epoch != epoch) {
        g_vk.contacts_at = 0;
        g_vk.support_contact_at = 0;
        g_vk.support_local_at = 0;
        g_vk.support_pose.locked = 0;
        g_vk.support_at = 0;
        g_vk.reload_at = 0;
        g_vk.rack_at = 0;
        g_vk.bore_at = 0;
        memset(g_vk.authored_grip, 0, sizeof g_vk.authored_grip);
        memset(&g_vk.asset_grip, 0, sizeof g_vk.asset_grip);
        memset(g_vk.hand_shape, 0, sizeof g_vk.hand_shape);
        memset(g_vk.holding_pose.shapes, 0, sizeof g_vk.holding_pose.shapes);
        g_vk.holding_pose.epoch = epoch;
        g_vk.trigger_source.valid = 0;
        g_vk.item_target_valid = 0;
    }
    g_vk.held.epoch = epoch;
    g_vk.held.wrists = wrists;
    aff room_from_head = vrik_room_from_view(head);
    g_vk.held.room_from_view = room_from_head;
    static int (*weapon_view)(const float[12], float[16]);
    static dispatch_once_t camera_once;
    dispatch_once(&camera_once, ^{ weapon_view = dlsym(RTLD_DEFAULT, "vx_xros_vr_weapon_view"); });
    if (weapon_view && weapon_view(camera.m, head)) {
        g_vk.held.room_from_view = vrik_room_from_view(head);
        aff from_head = aff_mul(aff_inv(g_vk.held.room_from_view), room_from_head);
        // The game camera steers independently from the headset. Preserve both
        // wrists' room poses by drawing them in the camera's actual view space.
        for (int h = 0; h < 2; h++) if (g_vk.held.hands_ok[h]) for (int k = 0; k < 4; k++) {
            float *sample = g_vk.held.hands[h] + 3 * k;
            float v[3] = {sample[0], sample[1], -sample[2]};
            if (k) aff_dir(from_head.m, v, sample);
            else aff_pt(from_head.m, v, sample);
            sample[2] = -sample[2];
        }
    }
    static int (*slide_contact)(float[6]);
    if (!slide_contact) slide_contact = dlsym(RTLD_DEFAULT, "vx_xros_vr_slide_contact");
    float slide[6];
    g_vk.slide_active = (wrists & 1u) && slide_contact && slide_contact(slide);
    if (g_vk.slide_active) {
        vrik_grip_pose *p = &g_vk.slide_hand;
        aff_pt(aff_inv(g_vk.held.room_from_view).m, slide, p->at);
        for (int i = 0; i < 3; i++) {
            float z = i == 2 ? -1.f : 1.f;
            p->fwd[i] = z * g_vk.held.hands[0][3 + i];
            p->up[i] = -z * g_vk.held.hands[0][6 + i];
            p->at[i] -= .035f * p->fwd[i];
        }
    }
    // Contact affects only the free visual wrist. Raw tracking remains the
    // input to racking, and the accepted two-hand target retains ownership.
    if ((wrists & 1u) && !g_vk.slide_active && g_vk.weap[4]<.5f && g_vk.weap[7]<.5f &&
        g_vk.bore_at>0 && g_vk.held.at-g_vk.bore_at<.16 && g_vk.held.owner==1) {
        aff room=g_vk.held.room_from_view;
        float f[3],u[3],r[3],palm[3],local[3],last[3],clamped[3];
        memcpy(f,g_vk.bore_room,12);memcpy(u,g_vk.bore_room+3,12);
        v3norm(f);v3norm(u);v3cross(f,u,r);v3norm(r);v3cross(r,f,u);
        const float *hand=g_vk.held.hands[0];
        float view_palm[3]={hand[0]+.035f*hand[3],hand[1]+.035f*hand[4],-hand[2]-.035f*hand[5]};
        aff_pt(room.m,view_palm,palm);
        float rel[3],prior[3];for(int i=0;i<3;i++) { rel[i]=palm[i]-g_vk.bore_room[6+i];prior[i]=g_vk.contact_previous[i]-g_vk.bore_room[6+i]; }
        local[0]=v3dot(rel,f);local[1]=v3dot(rel,r);local[2]=v3dot(rel,u);
        last[0]=v3dot(prior,f);last[1]=v3dot(prior,r);last[2]=v3dot(prior,u);
        float lo[3]={-.015f,-.06f,-.005f},hi[3]={fmaxf(.14f,fminf(.45f,g_vk.bore_room[9]+.06f)),.06f,.105f};
        int previous=g_vk.contact_previous_valid && g_vk.contact_epoch==epoch;
        g_vk.contact_active=vx_weapon_box_contact(previous?last:NULL,local,lo,hi,clamped);
        for(int i=0;i<3;i++) palm[i]=g_vk.bore_room[6+i]+clamped[0]*f[i]+clamped[1]*r[i]+clamped[2]*u[i];
        memcpy(g_vk.contact_previous,palm,sizeof palm);g_vk.contact_epoch=epoch;g_vk.contact_previous_valid=1;
        vrik_grip_pose *p=&g_vk.contact_hand;
        aff_pt(aff_inv(room).m,palm,p->at);
        for(int i=0;i<3;i++) { float z=i==2?-1.f:1.f;p->fwd[i]=z*hand[3+i];p->up[i]=-z*hand[6+i];p->at[i]-=.035f*p->fwd[i]; }
    } else g_vk.contact_previous_valid=0;
    if (!(wrists & (1u << side))) {
        if (side == 1) vrik_publish_right_grip();
        return;
    }
    const float *hand = g_vk.held.hands[side];
    float fwd[3], up[3], normal[3];
    for (int i = 0; i < 3; i++) {
        float z = i == 2 ? -1.f : 1.f;
        fwd[i] = z * hand[3+i];
        up[i] = z * hand[6+i] * (side ? 1.f : -1.f);
    }
    v3cross(fwd, up, normal);
    for (int i = 0; i < 3; i++) {
        g_vk.held.wrist_view.m[i*4] = fwd[i];
        g_vk.held.wrist_view.m[i*4+1] = up[i];
        g_vk.held.wrist_view.m[i*4+2] = normal[i];
        g_vk.held.wrist_view.m[i*4+3] = (i == 2 ? -hand[i] : hand[i]) + (side == 0 ? .035f * fwd[i] : 0.f);
    }
    if (side == 1) vrik_publish_right_grip();
}

static int vrik_hand_curls(float curls[2][6], float weap[8]) {
    static int (*fn)(float[2][6], float[8]); static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = dlsym(RTLD_DEFAULT, "vx_xros_vr_hand_curls"); });
    return fn ? fn(curls, weap) : 0;
}

// Use the game's two authored grips as reference frames. The transverse
// basis changes sign between left and right so each hand keeps its chirality.
static int vrik_wrist_frame_from(int side, aff hand, float at[3], float fwd[3], float up[3]) {
    const float *w = vrik_bindpos(g_vk.rigv, side ? VRIK_RIGHTHAND : VRIK_LEFTHAND);
    const float *m = vrik_bindpos(g_vk.rigv, side ? VRIK_RIGHTHANDMIDDLE1 : VRIK_LEFTHANDMIDDLE1);
    const float *i = vrik_bindpos(g_vk.rigv, side ? VRIK_RIGHTHANDINDEX1 : VRIK_LEFTHANDINDEX1);
    const float *p = vrik_bindpos(g_vk.rigv, side ? VRIK_RIGHTHANDPINKY1 : VRIK_LEFTHANDPINKY1);
    if (!w || !m || !i || !p) return 0;
    float f[3], u[3];
    for (int k = 0; k < 3; k++) { f[k] = m[k] - w[k]; u[k] = i[k] - p[k]; }
    aff_pt(hand.m, w, at);
    aff_dir(hand.m, f, fwd);
    aff_dir(hand.m, u, up);
    if (!v3norm(fwd)) return 0;
    float d = v3dot(up, fwd);
    for (int k = 0; k < 3; k++) up[k] -= d * fwd[k];
    return v3norm(up);
}

// Anchor the weapon inside the palm at the same measured point on each rig hand.
static int vrik_trigger_grip(int side, aff hand, vrik_grip_pose *grip) {
    if (!vrik_wrist_frame_from(side, hand, grip->at, grip->fwd, grip->up)) return 0;
    const float *wrist = vrik_bindpos(g_vk.rigv, side ? VRIK_RIGHTHAND : VRIK_LEFTHAND);
    const float *index = vrik_bindpos(g_vk.rigv, side ? VRIK_RIGHTHANDINDEX1 : VRIK_LEFTHANDINDEX1);
    const float *little = vrik_bindpos(g_vk.rigv, side ? VRIK_RIGHTHANDPINKY1 : VRIK_LEFTHANDPINKY1);
    float palm[3];
    for (int i = 0; i < 3; i++) palm[i] = .5f * wrist[i] + .25f * (index[i] + little[i]);
    aff_pt(hand.m, palm, grip->at);
    return 1;
}

// A palm is a capsule from the wrist to the knuckle centre. Its radius comes
// from this rig's metacarpal width, rather than a weapon-specific offset.
static int vrik_palm_capsule(int side, aff hand, float ends[2][3], float *radius) {
    const float *w = vrik_bindpos(g_vk.rigv, side ? VRIK_RIGHTHAND : VRIK_LEFTHAND);
    const float *i = vrik_bindpos(g_vk.rigv, side ? VRIK_RIGHTHANDINDEX1 : VRIK_LEFTHANDINDEX1);
    const float *p = vrik_bindpos(g_vk.rigv, side ? VRIK_RIGHTHANDPINKY1 : VRIK_LEFTHANDPINKY1);
    if (!w || !i || !p) return 0;
    float centre[3], width[3];
    for (int k = 0; k < 3; k++) { centre[k] = .5f * (i[k] + p[k]); width[k] = i[k] - p[k]; }
    aff_pt(hand.m, w, ends[0]); aff_pt(hand.m, centre, ends[1]);
    *radius = .5f * v3len(width);
    return *radius > .01f && *radius < .07f;
}

static float vrik_segment_gap(const float a[2][3], const float b[2][3], float delta[3]) {
    float u[3], v[3], w[3];
    for (int i = 0; i < 3; i++) { u[i] = a[1][i] - a[0][i]; v[i] = b[1][i] - b[0][i]; w[i] = a[0][i] - b[0][i]; }
    float aa = v3dot(u,u), bb = v3dot(u,v), cc = v3dot(v,v), dd = v3dot(u,w), ee = v3dot(v,w);
    float denominator = aa * cc - bb * bb;
    float s = denominator > 1e-10f ? (bb * ee - cc * dd) / denominator : 0;
    s = fmaxf(0, fminf(1, s));
    float t = cc > 1e-10f ? (bb * s + ee) / cc : 0;
    t = fmaxf(0, fminf(1, t));
    if (aa > 1e-10f) s = fmaxf(0, fminf(1, (bb * t - dd) / aa));
    for (int i = 0; i < 3; i++) delta[i] = b[0][i] + t * v[i] - a[0][i] - s * u[i];
    return v3len(delta);
}

static void vrik_separate_support(aff right, aff left, vrik_grip_pose *wrist) {
    float holding[2][3], support[2][3], r, l;
    if (!vrik_palm_capsule(1, right, holding, &r) || !vrik_palm_capsule(0, left, support, &l)) return;
    float away[3];
    for (int i = 0; i < 3; i++) away[i] = support[0][i] - holding[0][i];
    if (!v3norm(away)) {
        const float *shoulder = vrik_bindpos(g_vk.rigv, VRIK_LEFTARM);
        if (!shoulder) return;
        for (int i = 0; i < 3; i++) away[i] = shoulder[i] - holding[0][i];
        if (!v3norm(away)) return;
    }
    for (int step = 0; step < 4; step++) {
        float delta[3], gap = vrik_segment_gap(holding, support, delta);
        float penetration = r + l + .002f - gap;
        if (penetration <= 0) break;
        if (gap < .001f || v3dot(delta, away) <= 0) memcpy(delta, away, sizeof delta);
        else v3norm(delta);
        for (int i = 0; i < 3; i++) {
            float shift = delta[i] * penetration;
            wrist->at[i] += shift; support[0][i] += shift; support[1][i] += shift;
        }
    }
}

static int vrik_authored_hand(int side, double now, aff *hand) {
    __typeof__(g_vk.authored_grip[0]) *grip = &g_vk.authored_grip[side];
    int wrist_ref = (g_vk.hand_ref_mask & (1u << side)) && !g_vk.have_h[side];
    if (wrist_ref || g_vk.have_h[side]) {
        grip->hand = wrist_ref ? g_vk.hand_ref[side] : g_vk.SH[side];
        grip->at = now;
        grip->rig = g_vk.rigv;
        grip->has_forearm = g_vk.have_af[side];
        if (grip->has_forearm) grip->on_forearm = aff_mul(aff_inv(g_vk.SF[side]), grip->hand);
        *hand = grip->hand;
        return 1;
    }
    if (grip->at <= 0 || grip->rig != g_vk.rigv) return 0;
    if (g_vk.have_af[side] && grip->has_forearm) {
        // The relative wrist bind is still usable with a freshly captured
        // forearm, even when the game submits the fingers in another draw.
        *hand = aff_mul(g_vk.SF[side], grip->on_forearm);
        return 1;
    }
    if (now - grip->at > .35) return 0;
    *hand = grip->hand;
    return 1;
}

static aff vrik_retarget_grip(const float from[3], const float from_f[3], const float from_u[3],
                              const float to[3], const float to_f[3], const float to_u[3]) {
    aff turn = aff_arc(from_f, to_f, from);
    float up[3], cross[3]; aff_dir(turn.m, from_u, up); v3cross(up, to_u, cross);
    aff result = aff_mul(aff_rot(to_f, atan2f(v3dot(cross, to_f), v3dot(up, to_u)), from), turn);
    for (int k = 0; k < 3; k++) result.m[k * 4 + 3] += to[k] - from[k];
    return result;
}

static vrik_grip_pose vrik_grip_in(aff frame, const vrik_grip_pose *grip) {
    vrik_grip_pose result;
    aff_pt(frame.m, grip->at, result.at);
    aff_dir(frame.m, grip->fwd, result.fwd);
    aff_dir(frame.m, grip->up, result.up);
    v3norm(result.fwd);
    v3norm(result.up);
    return result;
}

static aff vrik_grip_basis(const vrik_grip_pose *pose) {
    float normal[3];
    v3cross(pose->fwd, pose->up, normal);
    aff basis;
    for (int i = 0; i < 3; i++) {
        basis.m[i * 4] = pose->fwd[i];
        basis.m[i * 4 + 1] = pose->up[i];
        basis.m[i * 4 + 2] = normal[i];
        basis.m[i * 4 + 3] = pose->at[i];
    }
    return basis;
}

// The game's view matrix reverses handedness. Transforming a proper palm
// basis into that view must reverse its normal too; rebuilding cross(f,u) in
// view space instead reflects the gun while leaving its hand unreflected.
static aff vrik_view_palm_basis(const vrik_grip_pose *view_grip) {
    vrik_grip_pose world_grip=vrik_grip_in(aff_inv(g_vk.vcam),view_grip);
    return aff_mul(g_vk.vcam,vrik_grip_basis(&world_grip));
}

static vrik_grip_pose vrik_support_in_body(aff body_from_view,const vrik_grip_pose *target,
                                          const vrik_grip_pose *local) {
    vrik_grip_pose palm=vrik_grip_in(body_from_view,target);
    return vrik_grip_in(vrik_grip_basis(&palm),local);
}

static int vrik_support_requested(void) {
    return g_vk.held.owner == 1 && g_vk.weap[7] > .5f &&
           ((unsigned)g_vk.weap[5] & VRIK_BTN_L_TRIG) && !g_vk.slide_active;
}

static void vrik_set_support_world(const vrik_grip_pose *grip, const vrik_grip_pose *support, int owner) {
    int active = vrik_support_requested();
    if (!active || g_vk.support_pose.epoch != g_vk.held.epoch) g_vk.support_pose.locked = 0;
    if (!support || (active && g_vk.support_pose.locked)) return;
    g_vk.support_local = vrik_grip_in(aff_inv(vrik_grip_basis(grip)), support);
    g_vk.support_local_owner = owner;
    g_vk.support_local_at = g_vk.held.at;
    if (active) {
        g_vk.support_pose.locked = 1;
        g_vk.support_pose.epoch = g_vk.held.epoch;
        g_vk.support_pose.generation++;
    }
}

// One correction in game space, shared by the receiver and every mounted part.
// Object origins, skinning palettes and render-pass view matrices cannot each
// choose a different grip. This is the legacy renderer's consumer boundary;
// it does not replace the pending game-animation adapter.
static int vrik_latch_weapon_frame(void) {
    __typeof__(g_vk.weapon_frame) *frame = &g_vk.weapon_frame;
    if (frame->valid && frame->frame == g_vk.capture_frame && frame->epoch == g_vk.held.epoch) return 1;
    if (g_vk.held.owner != 1 || !g_vk.capture_body || !g_vk.have_h[1] ||
        !g_vk.weapon_origin_valid || !g_vk.held.right_grip_valid ||
        g_vk.held.right_grip_frame != g_vk.capture_frame || !vrik_is_rot(g_vk.vcam.m)) return 0;
    vrik_grip_pose target;
    aff grip = g_vk.held.right_grip_view;
    for (int i = 0; i < 3; i++) {
        target.at[i] = grip.m[i*4+3];
        target.fwd[i] = grip.m[i*4];
        target.up[i] = grip.m[i*4+1];
    }
    aff move = vrik_retarget_grip(g_vk.native_item_grip.at, g_vk.native_item_grip.fwd, g_vk.native_item_grip.up,
                                 target.at, target.fwd, target.up);
    aff world_from_view = aff_inv(g_vk.vcam);
    frame->world_delta = aff_mul(world_from_view, aff_mul(move, g_vk.vcam));
    frame->view_from_world = g_vk.vcam;
    frame->native_world = vrik_grip_in(world_from_view, &g_vk.native_item_grip);
    frame->asset = 0; frame->count = 0;
    frame->support_valid = g_vk.item_support_valid;
    if (frame->support_valid) frame->support_world = vrik_grip_in(world_from_view, &g_vk.native_item_support);
    frame->frame = g_vk.capture_frame;
    frame->epoch = g_vk.held.epoch;
    frame->valid = 1;
    if (frame->support_valid && !g_vk.asset_grip.valid) {
        vrik_set_support_world(&frame->native_world, &frame->support_world, 1);
    }
    return 1;
}

static void vrik_publish_right_grip(void) {
    if (g_vk.held.right_grip_valid || !g_vk.held.right_bind_valid) return;
    int tracked = (g_vk.held.wrists & 2u) != 0;
    aff live = aff_mul(g_vk.held.room_from_view, aff_mul(g_vk.held.wrist_view, g_vk.held.right_wrist_from_palm));
    aff shown;
    unsigned frame = g_vk.capture_frame;
    if (!vrik_held_pose(&g_vk.held.right_grip, g_vk.held.room_from_view, frame, g_vk.held.epoch,
                        g_vk.held.at, tracked, 1, tracked ? &live : NULL, &shown)) return;
    g_vk.held.right_grip_view = aff_mul(aff_inv(g_vk.held.room_from_view), shown);
    g_vk.held.right_grip_valid = 1;
    g_vk.held.right_grip_frame = frame;
}

static int vrik_draw_grip(int owner, int solved, vrik_grip_pose *grip);

// Source contacts must be converted explicitly: the early solver supplies
// camera-view coordinates (a reflection), while a draw supplies item space.
// Only proper game-world coordinates may define the cached local contact.
static void vrik_publish_support(int owner, aff world_from_native, const vrik_grip_pose *native_grip,
                                 const vrik_grip_pose *native_support, const vrik_grip_pose *target) {
    int latched = owner == 1 && g_vk.weapon_frame.valid && g_vk.weapon_frame.frame == g_vk.capture_frame &&
                  g_vk.weapon_frame.epoch == g_vk.held.epoch;
    if (native_support && !latched && !g_vk.asset_grip.valid) {
        vrik_grip_pose world_grip=vrik_grip_in(world_from_native,native_grip);
        vrik_grip_pose world_support=vrik_grip_in(world_from_native,native_support);
        vrik_set_support_world(&world_grip,&world_support,owner);
    }
    if (g_vk.support_local_at <= 0 || g_vk.support_local_owner != owner) return;
    aff room_from_grip = aff_mul(g_vk.held.room_from_view, vrik_view_palm_basis(target));
    vrik_grip_pose palm = vrik_grip_in(room_from_grip, &g_vk.support_local);
    for (int i = 0; i < 3; i++) g_vk.support_room[i] = palm.at[i] + .035f * palm.fwd[i];
    g_vk.support_contact_owner = owner;
    g_vk.support_contact_at = g_vk.held.at;
}

static float vrik_distance(const float a[3], const float b[3]) {
    float delta[3] = {a[0] - b[0], a[1] - b[1], a[2] - b[2]};
    return v3len(delta);
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
    const float (*hf)[12] = g_vk.held.hands;
    const int *ok = g_vk.held.hands_ok;
    memset(g_vk.weap, 0, sizeof g_vk.weap);
    vrik_hand_curls(g_vk.curls, g_vk.weap);
    g_vk.slide_pull = g_vk.weap[0];
    if (!vrik_support_requested()) g_vk.support_pose.locked = 0;
    if (!vrik_is_rot(g_vk.vcam.m)) return;
    aff o2v = aff_mul(g_vk.vcam, g_vk.obj);
    aff v2o = aff_inv(o2v);
    int rigv = g_vk.rigv;

    // 1:1 view-space hand state (+X right, +Y up, +Z forward): position s_hv, forward s_fv, across-knuckle s_av
    static float s_hv[2][3] = { { -0.18f, -0.22f, 0.36f }, { 0.18f, -0.22f, 0.36f } };
    static float s_fv[2][3] = { { 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 1.0f } };
    static float s_av[2][3] = { { 0.0f, -1.0f, 0.0f }, { 0.0f, 1.0f, 0.0f } };
    static float s_roll[2]  = { 0.0f, 0.0f };
    static unsigned s_roll_frame[2] = { UINT32_MAX, UINT32_MAX };
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
    int hand_hold = g_vk.weap[6] >= 1.0f && g_vk.weap[6] <= 2.0f;
    int joy_free_hand = vrik_joy_hold() && hand_hold ? (g_vk.weap[6] > 1.5f ? 0 : 1) : -1;

    unsigned cur_frame = atomic_load(&g_frame);
    int step_filter = (cur_frame != s_last_frame || (!s_init[0] && ok[0]) || (!s_init[1] && ok[1]));
    s_last_frame = cur_frame;

    if (step_filter) {
        for (int side = 0; side < 2; side++) {
            if (ok[side]) {
                float rx = hf[side][0], ry = hf[side][1], rz = -hf[side][2];
                if (side == 0 && (g_vk.slide_active || g_vk.contact_active)) {
                    const vrik_grip_pose *contact=g_vk.slide_active?&g_vk.slide_hand:&g_vk.contact_hand;
                    rx=contact->at[0];ry=contact->at[1];rz=contact->at[2];
                }
                float rf[3] = { hf[side][3], hf[side][4], -hf[side][5] };
                float ra[3] = { hf[side][6], hf[side][7], -hf[side][8] };
                if (!v3norm(rf)) { rf[0] = 0.0f; rf[1] = 0.0f; rf[2] = 1.0f; }
                float da = v3dot(ra, rf); for (int i = 0; i < 3; i++) ra[i] -= da * rf[i];
                if (!v3norm(ra)) { ra[0] = 0.0f; ra[1] = side ? 1.0f : -1.0f; ra[2] = 0.0f; }
                int precision_hand = (g_vk.held.owner == 1 && (g_vk.held.wrists & (1u << side))) ||
                                     (side == joy_free_hand && g_vk.weap[4] > .5f);
                if (!s_init[side] || precision_hand) {
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
                s_hold_frames[side] = side == joy_free_hand ? 2 : 25;
                s_arm_w[side] = fminf(1.0f, s_arm_w[side] + 0.12f);
            } else {
                if (s_hold_frames[side] > 0) s_hold_frames[side]--;
                else if (side == joy_free_hand) {
                    // The native rifle animation keeps this wrist on the gun.
                    // A temporarily untracked free hand should settle away from it.
                    const float rest[3] = { side ? .32f : -.32f, -.62f, .23f };
                    for (int j = 0; j < 3; j++) s_hv[side][j] += (rest[j] - s_hv[side][j]) * .18f;
                    s_arm_w[side] = fminf(1.f, s_arm_w[side] + .12f);
                } else s_arm_w[side] = fmaxf(0.0f, s_arm_w[side] - 0.04f);
            }
        }

        // Joy-Con weapon grab / hand switching:
        // - Press Left Joy-Con L / L3 (VRIK_BTN_L_GRAB) while R is not held -> grab weapon with Left Hand (s_gun_hand = 0)
        // - Press Right Joy-Con R / R3 (VRIK_BTN_R_GRAB) while L is not held -> grab weapon with Right Hand (s_gun_hand = 1)
        unsigned newly_pressed = ctrl_btns & ~s_prev_btns;
        s_prev_btns = ctrl_btns;
        if (!vrik_joy_hold() && (newly_pressed & VRIK_BTN_L_GRAB) && !(ctrl_btns & VRIK_BTN_R_GRAB) && s_arm_w[0] > 0.25f && s_gun_hand != 0) {
            s_gun_hand = 0;
            vxmac_log("VRIK: weapon grabbed by left hand via Joy-Con L button");
        } else if (!vrik_joy_hold() && (newly_pressed & VRIK_BTN_R_GRAB) && !(ctrl_btns & VRIK_BTN_L_GRAB) && s_gun_hand != 1) {
            s_gun_hand = 1;
            vxmac_log("VRIK: weapon grabbed by right hand via Joy-Con R button");
        }
    }
    if (hand_hold) s_gun_hand = g_vk.weap[6] > 1.5f ? 1 : 0;
    else if (s_gun_hand == 0 && s_arm_w[0] < 0.05f && s_arm_w[1] > 0.25f) s_gun_hand = 1;
    g_vk.gun_hand = s_gun_hand;

    static float support_offset[3]; static int support_was, support_owner = -1;
    int support_now = hand_hold && g_vk.weap[7] > .5f && ok[1] && (ok[0] || g_vk.weap[7] > 1.5f);
    if (vrik_joy_hold() && !(ctrl_btns & (s_gun_hand ? VRIK_BTN_L_TRIG : VRIK_BTN_R_TRIG))) support_now = 0;
    if (support_now && (!support_was || support_owner != s_gun_hand)) {
        for (int i = 0; i < 3; i++) support_offset[i] = s_hv[1 - s_gun_hand][i] - s_hv[s_gun_hand][i];
        support_owner = s_gun_hand;
    }
    support_was = support_now;

    float Tc_out[2][3] = {{0},{0}};
    float f_final[2][3] = {{0,1,0},{0,1,0}}, u_final[2][3] = {{0,0,1},{0,0,1}};
    int solved[2] = { 0, 0 };
    g_vk.D[0] = aff_id();
    g_vk.native_support = 0;
    int joy_weapon = vrik_joy_hold() && hand_hold;
    aff joy_gun_delta = aff_id();
    int joy_gun_solved = 0;
    double now = CACurrentMediaTime();
    aff authored_hand[2];
    int have_authored[2] = {0};
    float native_at[2][3], native_fwd[2][3], native_up[2][3];
    int have_native[2] = {0};
    if (joy_weapon) for (int side = 0; side < 2; side++) {
        have_authored[side] = vrik_authored_hand(side, now, &authored_hand[side]);
        if (have_authored[side])
            have_native[side] = vrik_wrist_frame_from(side, authored_hand[side], native_at[side], native_fwd[side], native_up[side]);
    }
    vrik_grip_pose right_grip;
    int have_right_grip = have_native[1] && vrik_trigger_grip(1, authored_hand[1], &right_grip);
    g_vk.right_rest_valid = have_authored[1];
    if (have_authored[1]) g_vk.right_rest_hand = authored_hand[1];
    g_vk.weapon_origin_valid = have_right_grip;
    g_vk.item_support_valid = 0;
    if (have_right_grip) {
        aff_pt(g_vk.obj.m, native_at[1], g_vk.weapon_grip_world);
        g_vk.native_item_grip = vrik_grip_in(o2v, &right_grip);
        vrik_grip_pose local;
        g_vk.item_support_valid = g_vk.have_h[0] && g_vk.have_h[1] && have_native[0] &&
                                 vrik_distance(native_at[0], native_at[1]) < .55f;
        if (g_vk.item_support_valid) {
            memcpy(local.at, native_at[0], sizeof local.at);
            memcpy(local.fwd, native_fwd[0], sizeof local.fwd);
            memcpy(local.up, native_up[0], sizeof local.up);
            vrik_separate_support(authored_hand[1], authored_hand[0], &local);
            g_vk.native_item_support = vrik_grip_in(o2v, &local);
        }
    }
    // The wrist-to-palm offset belongs to V's rig and survives weapon swaps.
    // Render passes submitted before the hands still use the tracked palm.
    if (g_vk.held.right_bind_valid && g_vk.held.right_bind_rig != rigv) {
        g_vk.held.right_bind_valid = 0;
        g_vk.held.right_grip_valid = 0;
    }
    if (g_vk.held.owner == 1 && have_right_grip && (g_vk.hand_ref_mask & 2u) && !g_vk.held.right_grip_valid) {
        vrik_grip_pose wrist;
        memcpy(wrist.at, native_at[1], sizeof wrist.at);
        memcpy(wrist.fwd, native_fwd[1], sizeof wrist.fwd);
        memcpy(wrist.up, native_up[1], sizeof wrist.up);
        g_vk.held.right_wrist_from_palm = aff_mul(aff_inv(vrik_grip_basis(&wrist)), vrik_grip_basis(&right_grip));
        g_vk.held.right_bind_rig = rigv;
        g_vk.held.right_bind_valid = 1;
        vrik_publish_right_grip();
    }
    int paired_right = g_vk.held.owner == 1 && g_vk.held.right_grip_valid;
    vrik_grip_pose target_grip;
    if (paired_right && (g_vk.held.wrists & 2u) && vrik_draw_grip(1, 0, &target_grip)) {
        // Native support can be captured from the arm meshes even when the
        // receiver has a different origin or has not been drawn yet.
        vrik_publish_support(1, aff_inv(g_vk.vcam), &g_vk.native_item_grip,
                             g_vk.item_support_valid ? &g_vk.native_item_support : NULL, &target_grip);
    }
    if (!joy_weapon) {
        g_vk.contacts_at = 0;
        g_vk.reload_at = 0;
        g_vk.support_contact_at = 0;
        g_vk.support_local_at = 0;
        g_vk.item_target_valid = 0;
    }

    for (int i = 0; i < 2; i++) {
        int side = i ? 1 - s_gun_hand : s_gun_hand;
        g_vk.D[side ? 4 : 1] = g_vk.D[side ? 5 : 2] = g_vk.D[side ? 6 : 3] = aff_id();
        g_vk.D_w0[side] = g_vk.D_w1[side] = g_vk.D_w2[side] = aff_id();
        // Wait for the wrist palette as well as the arm palette: partial startup captures can put a hand across the eyes.
        int forced_support = joy_weapon && support_now && side != s_gun_hand && g_vk.weap[7] > 1.5f;
        if ((!forced_support && s_arm_w[side] < 0.01f) || !g_vk.have_af[side] ||
            !(g_vk.have_h[side] || have_authored[side])) continue;
        aff hand = have_authored[side] ? authored_hand[side] : g_vk.SH[side];
        // Fade into the native pose near the eye instead of pinning the tracked hand to a plane.
        // The arm solver below limits the rest of the motion by the arm's actual reach.
        float arm_weight = forced_support ? 1.f : s_arm_w[side];
        if (joy_weapon && side == g_vk.held.owner) {
            if (!(g_vk.held.wrists & (1u << side))) continue;
            if (side == 1) arm_weight = 1.f;
        } else if (joy_weapon && side == s_gun_hand)
            arm_weight *= fmaxf(0.f, fminf(1.f, (v3len(s_hv[side]) - .12f) / .11f));
        else if (side != joy_free_hand)
            arm_weight *= fmaxf(0.f, fminf(1.f, (s_hv[side][2] - .14f) / .16f));
        if (arm_weight < .01f) continue;
        int nA = side ? VRIK_RIGHTARM : VRIK_LEFTARM, nF = side ? VRIK_RIGHTFOREARM : VRIK_LEFTFOREARM, nH = side ? VRIK_RIGHTHAND : VRIK_LEFTHAND;
        const float *cA = vrik_bindpos(rigv, nA), *cF = vrik_bindpos(rigv, nF), *cH = vrik_bindpos(rigv, nH);
        const float *cM = vrik_bindpos(rigv, side ? VRIK_RIGHTHANDMIDDLE1 : VRIK_LEFTHANDMIDDLE1);
        const float *cI = vrik_bindpos(rigv, side ? VRIK_RIGHTHANDINDEX1  : VRIK_LEFTHANDINDEX1);
        const float *cP = vrik_bindpos(rigv, side ? VRIK_RIGHTHANDPINKY1  : VRIK_LEFTHANDPINKY1);
        if (!cA || !cF || !cH || !cM || !cI || !cP) continue;
        const float *SA = g_vk.SA[side].m, *SF = g_vk.SF[side].m;
        float S[3], E[3], eA[3], W[3]; aff_pt(SA, cA, S); aff_pt(SF, cF, E); aff_pt(SA, cF, eA); aff_pt(SF, cH, W);
        float de[3] = { eA[0]-E[0], eA[1]-E[1], eA[2]-E[2] };
        int side_ok = fabsf(S[0]) < .45f;
        if (!side_ok || S[2] < 1.10f || S[2] > 1.70f || v3len(de) > 0.025f) continue;
        float Ev[3], Wv[3]; aff_pt(o2v.m, E, Ev); aff_pt(o2v.m, W, Wv);
        float a = 0, b = 0, d3[3];
        for (int i = 0; i < 3; i++) d3[i] = E[i] - S[i]; a = v3len(d3);
        for (int i = 0; i < 3; i++) d3[i] = W[i] - E[i]; b = v3len(d3);
        if (v3len(Ev) > 0.95f || a < 0.18f || a > 0.38f || b < 0.18f || b > 0.38f) continue;

        // 1:1 Hand Position in camera view space
        float target_v[3] = {
            Wv[0] + (s_hv[side][0] - Wv[0]) * arm_weight,
            Wv[1] + (s_hv[side][1] - Wv[1]) * arm_weight,
            Wv[2] + (s_hv[side][2] - Wv[2]) * arm_weight
        };
        if (side == joy_free_hand) {
            float distance = v3len(target_v);
            if (distance > .001f && distance < .18f)
                for (int j = 0; j < 3; j++) target_v[j] *= .18f / distance;
        }
        int native_support = 0;
        aff support_delta = aff_id();
        if (support_now && side != s_gun_hand && (!joy_weapon || g_vk.support_pose.locked)) {
            vrik_grip_pose weapon_grip;
            int fresh_ik = g_vk.item_target_valid && g_vk.item_target_frame == cur_frame &&
                           g_vk.item_target_owner == s_gun_hand;
            if (joy_weapon && have_native[side] && g_vk.support_local_at > 0 && g_vk.support_local_owner == s_gun_hand &&
                vrik_draw_grip(g_vk.held.owner, fresh_ik, &weapon_grip)) {
                vrik_grip_pose supported_view = vrik_grip_in(vrik_view_palm_basis(&weapon_grip), &g_vk.support_local);
                vrik_grip_pose supported = vrik_grip_in(v2o, &supported_view);
                if (v3len(supported_view.at) >= .20f && vrik_distance(supported.at, S) < .9f) {
                    support_delta = vrik_retarget_grip(native_at[side], native_fwd[side], native_up[side],
                                                       supported.at, supported.fwd, supported.up);
                    memcpy(target_v, supported_view.at, sizeof target_v);
                    native_support = 1;
                }
            } else if (!joy_weapon && side == 0 && solved[1]) {
                const float *right_bind = vrik_bindpos(rigv, VRIK_RIGHTHAND);
                if (right_bind) {
                    float left_wrist[3], right_wrist[3], anchor[3], anchor_view[3];
                    aff_pt(g_vk.SH[0].m, cH, left_wrist);
                    aff_pt(g_vk.SH[1].m, right_bind, right_wrist);
                    aff_pt(g_vk.D[6].m, left_wrist, anchor);
                    aff_pt(o2v.m, anchor, anchor_view);
                    float spacing[3], approach[3], reach[3], left_seam[3];
                    for (int j = 0; j < 3; j++) {
                        spacing[j] = left_wrist[j] - right_wrist[j];
                        approach[j] = anchor_view[j] - s_hv[0][j];
                        reach[j] = anchor[j] - S[j];
                        left_seam[j] = left_wrist[j] - W[j];
                    }
                    float d = v3len(spacing), r = v3len(reach);
                    // Reuse the game's support pose only when both wrists fit the held weapon
                    // and the off hand can reach it without pulling the arm apart.
                    unsigned last_support = atomic_load(&g_vk_supported_at);
                    float contact = last_support && cur_frame - (last_support - 1) <= 3 ? .18f : .12f;
                    if (d > .07f && d < .55f && v3len(approach) < contact &&
                        v3len(left_seam) < .015f && anchor_view[2] >= .28f &&
                        r > fabsf(a - b) + .01f && r < a + b - .002f) {
                        memcpy(target_v, anchor_view, sizeof target_v);
                        support_delta = g_vk.D[6];
                        native_support = 1;
                    }
                }
            } else if (side == 1 && !vrik_joy_hold()) {
                for (int j = 0; j < 3; j++) target_v[j] = s_hv[s_gun_hand][j] + support_offset[j];
                target_v[2] = fmaxf(.30f, target_v[2]);
            }
        }
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
        if (((paired_right && side == 1) || native_support) && fabsf(dc - d) > .0001f) {
            // Extend the sleeve toward the tracked wrist when it is outside
            // the authored arm's reach. Keep the elbow seam fixed.
            float f_exact[3] = {T[0] - E2[0], T[1] - E2[1], T[2] - E2[2]};
            float length = v3len(f_exact);
            if (v3norm(f_exact)) {
                aff stretch = aff_id();
                float scale = length / b - 1.f;
                for (int row = 0; row < 3; row++) {
                    for (int col = 0; col < 3; col++) stretch.m[row*4+col] += scale * f_exact[row] * f_exact[col];
                    stretch.m[row*4+3] = -scale * f_exact[row] * v3dot(f_exact, E2);
                }
                D2 = aff_mul(stretch, aff_mul(aff_arc(u_fore, f_exact, E2), D2));
                memcpy(Tc, T, sizeof Tc);
                memcpy(u_fore, f_exact, sizeof u_fore);
            }
        }

        // Bind-space hand basis: f_bind = Wrist->Middle1, a_bind = (side ? Index1-Pinky1 : Pinky1-Index1) orthogonalized
        float f_bind[3] = { cM[0]-cH[0], cM[1]-cH[1], cM[2]-cH[2] };
        float a_bind[3] = { side ? (cI[0]-cP[0]) : (cP[0]-cI[0]), side ? (cI[1]-cP[1]) : (cP[1]-cI[1]), side ? (cI[2]-cP[2]) : (cP[2]-cI[2]) };
        v3norm(f_bind);
        float d_ba = v3dot(a_bind, f_bind); for (int i = 0; i < 3; i++) a_bind[i] -= d_ba * f_bind[i];
        v3norm(a_bind);

        // Hand basis after two-bone IK D2 (using SH[side] when it matches SF[side] at the wrist joint, else SF[side])
        float wH[3]; aff_pt(hand.m, cH, wH);
        float dw_h[3] = { wH[0] - W[0], wH[1] - W[1], wH[2] - W[2] };
        int use_sh = v3len(dw_h) < .02f;
        aff M_h2 = aff_mul(D2, use_sh ? hand : g_vk.SF[side]);
        float f_h2[3], a_h2[3];
        aff_dir(M_h2.m, f_bind, f_h2); v3norm(f_h2);
        aff_dir(M_h2.m, a_bind, a_h2);
        float d_h2 = v3dot(a_h2, f_h2); for (int i = 0; i < 3; i++) a_h2[i] -= d_h2 * f_h2[i];
        v3norm(a_h2);

        // 1:1 VR hand basis in object space with anatomical wrist flexion/extension cone (max ~60 deg from forearm axis)
        float f_vr[3], a_vr[3];
        aff_dir(v2o.m, s_fv[side], f_vr); v3norm(f_vr);
        aff_dir(v2o.m, s_av[side], a_vr);
        if (native_support) {
            aff grip = aff_mul(support_delta, hand);
            aff_dir(grip.m, f_bind, f_vr);
            aff_dir(grip.m, a_bind, a_vr);
        }
        float df_fore = v3dot(f_vr, u_fore);
        if (!joy_weapon && df_fore < 0.50f) {
            for (int i = 0; i < 3; i++) f_vr[i] += (0.50f - df_fore) * u_fore[i];
            v3norm(f_vr);
        }
        float f_tgt[3] = {
            f_h2[0] + (f_vr[0] - f_h2[0]) * arm_weight,
            f_h2[1] + (f_vr[1] - f_h2[1]) * arm_weight,
            f_h2[2] + (f_vr[2] - f_h2[2]) * arm_weight
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
        if (!joy_weapon) raw_roll = fmaxf(-1.35f, fminf(1.35f, raw_roll));
        if (s_roll_frame[side] != cur_frame) {
            s_roll_frame[side] = cur_frame;
            float change = raw_roll - s_roll[side];
            if (joy_weapon) change = atan2f(sinf(change), cosf(change));
            float limit = joy_weapon ? .48f : .12f;
            change = fmaxf(-limit, fminf(limit, change));
            s_roll[side] += change * .35f;
            if (joy_weapon) s_roll[side] = atan2f(sinf(s_roll[side]), cosf(s_roll[side]));
        }
        // The tracked wrist basis has already been filtered. A second roll filter
        // relative to the animated wrist made the gun inherit native animation jitter.
        float roll_ang = (joy_weapon ? raw_roll : s_roll[side]) * arm_weight;

        // Distribute forearm twist smoothly across Wrist_0 (30%), Wrist_1 (60%), Wrist_2 (85% + half aim), and Hand (100% + full aim)
        g_vk.D_w0[side] = aff_mul(aff_rot(u_fore, 0.30f * roll_ang, Tc), D2);
        g_vk.D_w1[side] = aff_mul(aff_rot(u_fore, 0.60f * roll_ang, Tc), D2);
        g_vk.D_w2[side] = aff_mul(aff_rot(f_half, 0.85f * roll_ang, Tc), aff_mul(R_aim_half, D2));
        aff D3          = aff_mul(aff_rot(f_tgt,  roll_ang,         Tc), aff_mul(R_aim,      D2));
        if (native_support) {
            // The support wrist and gun receive the same rigid transform, preserving contact.
            D3 = support_delta;
            g_vk.native_support = 1;
        }

        memcpy(f_final[side], f_tgt, sizeof f_tgt);
        float a_fin[3]; aff_dir(aff_rot(f_tgt, roll_ang, Tc).m, a_h3, a_fin);
        for (int i = 0; i < 3; i++) u_final[side][i] = side ? a_fin[i] : -a_fin[i];
        v3norm(u_final[side]);
        memcpy(Tc_out[side], Tc, sizeof Tc);
        solved[side] = 1;
        g_vk.D[side ? 4 : 1] = D1; g_vk.D[side ? 5 : 2] = D2; g_vk.D[side ? 6 : 3] = D3;
        if (joy_weapon && side == s_gun_hand) {
            aff posed_hand = aff_mul(D3, hand);
            vrik_grip_pose target;
            int have_target = vrik_trigger_grip(side, posed_hand, &target);
            if (side == 0) {
                g_vk.posed_left_hand = posed_hand;
                g_vk.left_rest_hand = hand;
            }
            if (ok[side] && have_target) {
                g_vk.item_target = vrik_grip_in(o2v, &target);
                g_vk.item_target_owner = side;
                g_vk.item_target_at = now;
                g_vk.item_target_frame = cur_frame;
                g_vk.item_target_valid = 1;
                if (side == 0 && side == g_vk.held.owner && (g_vk.held.wrists & (1u << side))) {
                    aff fit = aff_mul(aff_inv(g_vk.held.wrist_view), vrik_grip_basis(&g_vk.item_target));
                    // Use the rendered grip's local offset only when the IK wrist
                    // is close to the tracked wrist. Large reach clamps are pose-specific.
                    if (v3len((float[3]){fit.m[3], fit.m[7], fit.m[11]}) < .10f && fit.m[0] > .65f) {
                        g_vk.held.grip_from_wrist = fit;
                        g_vk.held.grip_epoch = g_vk.held.epoch;
                        g_vk.held.grip_calibrated = 1;
                    }
                }
                if (side == g_vk.held.owner && g_vk.held.rig != rigv) {
                    memset(g_vk.held.arm, 0, sizeof g_vk.held.arm);
                    g_vk.held.rig = rigv;
                }
            }
            if (side == 1) {
                joy_gun_delta = D3;
                vrik_grip_pose shared;
                if (have_right_grip && g_vk.held.owner == 1 && vrik_draw_grip(1, 0, &shared)) {
                    shared = vrik_grip_in(v2o, &shared);
                    joy_gun_delta = vrik_retarget_grip(right_grip.at, right_grip.fwd, right_grip.up,
                                                       shared.at, shared.fwd, shared.up);
                }
                joy_gun_solved = 1;
            } else if (have_right_grip && have_target) {
                joy_gun_delta = vrik_retarget_grip(right_grip.at, right_grip.fwd, right_grip.up,
                                                   target.at, target.fwd, target.up);
                joy_gun_solved = 1;
            }
        }
        static atomic_uint logged[2]; if (atomic_fetch_add(&logged[side], 1) % 300 == 0)
            vxmac_log("VRIK: %s arm solved (hand=%d gun=%d roll=%.1f deg): S(%.2f %.2f %.2f) E2(%.2f %.2f %.2f) Tc(%.2f %.2f %.2f)",
                      side ? "right" : "left", g_vk.have_h[side], s_gun_hand, roll_ang * 57.2958f, S[0], S[1], S[2], E2[0], E2[1], E2[2], Tc[0], Tc[1], Tc[2]);
    }
    if (g_vk.native_support) {
        atomic_store(&g_vk_supported_at, cur_frame + 1);
        g_vk.support_at = now;
    } else if (!support_now) g_vk.support_at = 0;
    if (joy_weapon) {
        vrik_latch_weapon_frame();
        g_vk.weapon_solved = joy_gun_solved;
        g_vk.D_gun = joy_gun_delta;
        g_vk.two_hand = g_vk.native_support;
        return;
    }

    // 100% Locked Weapon Transform (D_gun) derived directly from g_vk.D[6] (V's Right Hand skinning delta):
    // - When held in Right Hand (gh == 1): D_gun == g_vk.D[6] (zero floating; identical transform to V's right hand!).
    // - When held in Left Hand (gh == 0, switched via Joy-Con L button): composed directly on top of g_vk.D[6],
    //   translating Tc_out[1] -> Tc_out[0] and rotating (f_final[1], u_final[1]) -> (f_gun, u_gun) around Tc_out[0].
    static aff right_reference;
    static float right_at[3], right_fwd[3], right_up[3];
    static int right_reference_ok;
    if ((s_gun_hand == 1 || !right_reference_ok) && solved[1]) {
        right_reference = g_vk.D[6];
        memcpy(right_at, Tc_out[1], sizeof right_at);
        memcpy(right_fwd, f_final[1], sizeof right_fwd);
        memcpy(right_up, u_final[1], sizeof right_up);
        right_reference_ok = 1;
    }
    aff D_gun = g_vk.D[6];
    int gh = s_gun_hand, sh = 1 - gh;
    if (gh == 0 && hand_hold && right_reference_ok) D_gun = right_reference;
    g_vk.weapon_solved = solved[gh] && (gh == 1 || (hand_hold ? right_reference_ok : solved[1]));
    if (g_vk.weapon_solved) {
        float f_gun[3] = { f_final[gh][0], f_final[gh][1], f_final[gh][2] };
        float u_gun[3] = { u_final[gh][0], u_final[gh][1], u_final[gh][2] };
        g_vk.two_hand = 0.0f;

        unsigned sh_grab_mask = (sh == 0) ? (VRIK_BTN_L_GRAB | VRIK_BTN_L_TRIG) : (VRIK_BTN_R_GRAB | VRIK_BTN_R_TRIG);
        if (!g_vk.native_support && solved[sh] && (hand_hold ? support_now : !vrik_joy_hold() && !!(ctrl_btns & sh_grab_mask))) {
            float dv[3] = { s_hv[sh][0] - s_hv[gh][0], s_hv[sh][1] - s_hv[gh][1], s_hv[sh][2] - s_hv[gh][2] };
            float dist_v = v3len(dv);
            if (dist_v > (hand_hold ? 0.12f : 0.14f) && dist_v < 0.65f && (hand_hold || dv[2] > 0.03f)) {
                float dir_2h[3] = { Tc_out[sh][0] - Tc_out[gh][0], Tc_out[sh][1] - Tc_out[gh][1], Tc_out[sh][2] - Tc_out[gh][2] };
                if (v3norm(dir_2h) && v3dot(dir_2h, f_gun) > 0.35f) {
                    for (int i = 0; i < 3; i++) f_gun[i] = f_gun[i] * 0.65f + dir_2h[i] * 0.35f;
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
            const float *ref_at = hand_hold ? right_at : Tc_out[1];
            const float *ref_fwd = hand_hold ? right_fwd : f_final[1];
            const float *ref_up = hand_hold ? right_up : u_final[1];
            aff ref_delta = hand_hold ? right_reference : g_vk.D[6];
            for (int i = 0; i < 3; i++) T_r2l.m[i*4+3] = Tc_out[0][i] - ref_at[i];
            aff R_f = aff_arc(ref_fwd, f_gun, Tc_out[0]);
            float u1[3]; aff_dir(R_f.m, ref_up, u1);
            float d1 = v3dot(u1, f_gun); for (int i = 0; i < 3; i++) u1[i] -= d1 * f_gun[i];
            float d2 = v3dot(u_gun, f_gun); for (int i = 0; i < 3; i++) u_gun[i] -= d2 * f_gun[i];
            float g_roll = 0.0f;
            if (v3norm(u1) && v3norm(u_gun)) {
                float cx[3]; v3cross(u1, u_gun, cx);
                g_roll = atan2f(v3dot(cx, f_gun), v3dot(u1, u_gun));
            }
            aff R_u = aff_rot(f_gun, g_roll, Tc_out[0]);
            D_gun = aff_mul(R_u, aff_mul(R_f, aff_mul(T_r2l, ref_delta)));
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

static const int vrik_finger_bones[2][4][6] = {
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

static const int vrik_thumb_bones[2][5] = {
    { 51, 53, 1659, 1661, 1663 },
    { 143, 145, 2129, 2131, 2133 }
};

static int vrik_grip_digit(int side, int name) {
    for (int finger = 0; finger < 4; finger++)
        for (int joint = 0; joint < 6; joint++)
            if (name == vrik_finger_bones[side][finger][joint]) return finger * 6 + joint;
    for (int joint = 0; joint < 5; joint++)
        if (name == vrik_thumb_bones[side][joint]) return 24 + joint;
    return -1;
}

static void vrik_capture_right_fingers(const vrik_pal *pal, uint32_t list) {
    if (!g_vk.have_h[1] || g_vk.gun_hand != 1 || g_vk.weap[6] != 2.f) return;
    int bH = -1;
    for (uint32_t k = 0; k < pal->nb; k++)
        if (vrik_pal_name(pal,k) == VRIK_RIGHTHAND) { bH = (int)k; break; }
    aff hand = bH >= 0 ? pal->orig[bH] : g_vk.SH[1];
    const float *w = vrik_bindpos(g_vk.rigv, VRIK_RIGHTHAND);
    if (!w) return;
    float captured[3], expected[3];
    aff_pt(hand.m, w, captured);
    aff_pt(g_vk.SH[1].m, w, expected);
    if (vrik_distance(captured, expected) > .02f) return;
    aff inverse = aff_inv(hand);
    if (g_vk.right_grip_finger_rig != g_vk.rigv) g_vk.right_grip_fingers_valid = 0;
    g_vk.right_grip_finger_rig = g_vk.rigv;
    for (uint32_t k = 0; k < pal->nb; k++) {
        int digit = vrik_grip_digit(1, vrik_pal_name(pal,k));
        if (digit < 0) continue;
        g_vk.right_grip_fingers[digit] = aff_mul(inverse, pal->orig[k]);
        g_vk.right_grip_fingers_valid |= 1u << digit;
    }
}

static int vrik_left_grip_bone(int name, aff left_hand, aff *result) {
    int digit = vrik_grip_digit(0, name);
    if (digit < 0 || !(g_vk.right_grip_fingers_valid & (1u << digit))) return 0;
    int right = digit < 24 ? vrik_finger_bones[1][digit / 6][digit % 6] : vrik_thumb_bones[1][digit - 24];
    const float *left_bind = vrik_bindpos(g_vk.rigv, name), *right_bind = vrik_bindpos(g_vk.rigv, right);
    const float *left_wrist = vrik_bindpos(g_vk.rigv, VRIK_LEFTHAND);
    const float *right_wrist = vrik_bindpos(g_vk.rigv, VRIK_RIGHTHAND);
    if (!left_bind || !right_bind || !left_wrist || !right_wrist) return 0;
    aff pose = g_vk.right_grip_fingers[digit];
    float point[3];
    aff_pt(pose.m, right_bind, point);
    for (int r = 0; r < 3; r++) {
        float sign = r == 0 ? -1.f : 1.f;
        for (int c = 0; c < 3; c++) pose.m[r * 4 + c] *= sign * (c == 0 ? -1.f : 1.f);
        float pivot = left_wrist[r] + sign * (point[r] - right_wrist[r]);
        pose.m[r * 4 + 3] = pivot - v3dot(pose.m + r * 4, left_bind);
    }
    *result = aff_mul(left_hand, pose);
    if (digit < 6 && ((unsigned)g_vk.weap[5] & VRIK_BTN_L_TRIG)) {
        const float *index = vrik_bindpos(g_vk.rigv, VRIK_LEFTHANDINDEX1);
        const float *little = vrik_bindpos(g_vk.rigv, VRIK_LEFTHANDPINKY1);
        if (index && little) {
            float pivot[3], axis[3], across[3];
            for (int i = 0; i < 3; i++) across[i] = little[i] - index[i];
            aff_pt(left_hand.m, index, pivot);
            aff_dir(left_hand.m, across, axis);
            *result = aff_mul(aff_rot(axis, .19f, pivot), *result);
        }
    }
    return 1;
}

// Gentle hand-tracking finger flexion/extension for BOTH hands (including knuckle volume/muscle bones so fingers never deform)
static void vrik_finger_deltas(int side, const vrik_pal *pal, uint32_t o, const aff *rest, aff M_out[128]) {
    for (uint32_t k = 0; k < pal->nb; k++) M_out[k] = aff_id();
    int rigv = g_vk.rigv;
    int nH = side ? VRIK_RIGHTHAND : VRIK_LEFTHAND;
    int bH = -1;
    for (uint32_t k = 0; k < pal->nb; k++) if (vrik_pal_name(pal,k) == nH) { bH = (int)k; break; }
    if (bH < 0 && !rest) return;
    const aff *hand = rest ? rest : &pal->orig[bH];

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
    aff_dir(hand->m, fb, f_hand);
    aff_dir(hand->m, ab, ax_curl);
    if (!v3norm(f_hand) || !v3norm(ax_curl)) return;

    // Phalanx bones (b1, b2, b3) + knuckle skin/muscle bones (m1_top, m1_bot attached to b1; m2_top attached to b2)


    // On the native right-hand grip, preserve the weapon's finger placement
    // and drive just the trigger finger.
    int trigger_only = vrik_joy_hold() && side == 1 && g_vk.weap[6] == 2.f;
    for (int f = 0; f < (trigger_only ? 1 : 4); f++) {
        int b1 = -1, b2 = -1, b3 = -1, m1a = -1, m1b = -1, m2a = -1;
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_pal_name(pal,k);
            if      (nm == vrik_finger_bones[side][f][0]) b1  = (int)k;
            else if (nm == vrik_finger_bones[side][f][1]) b2  = (int)k;
            else if (nm == vrik_finger_bones[side][f][2]) b3  = (int)k;
            else if (nm == vrik_finger_bones[side][f][3]) m1a = (int)k;
            else if (nm == vrik_finger_bones[side][f][4]) m1b = (int)k;
            else if (nm == vrik_finger_bones[side][f][5]) m2a = (int)k;
        }
        if (b1 < 0) continue;
        const float *c1 = vrik_bindpos(rigv, vrik_finger_bones[side][f][0]);
        if (!c1) continue;

        // Measure how much phalanx 1 is ALREADY bent in pal->orig relative to the palm so we never double-curl a weapon grip
        float f_p1[3], cx1[3];
        aff_dir((rest ? rest : &pal->orig[b1])->m, fb, f_p1); v3norm(f_p1);
        v3cross(f_hand, f_p1, cx1);
        float cur_ang1 = atan2f(v3dot(cx1, ax_curl), v3dot(f_hand, f_p1));
        float curl = g_vk.curls[side][1 + f];
        float tgt_ang1 = curl * 0.85f;
        float d1 = fmaxf(-0.35f, fminf(0.35f, (tgt_ang1 - cur_ang1) * 0.55f));

        float p1[3]; aff_pt((rest ? rest : &pal->orig[b1])->m, c1, p1);
        aff M1 = aff_rot(ax_curl, d1, p1);
        M_out[b1] = M1;
        if (m1a >= 0) M_out[m1a] = M1;
        if (m1b >= 0) M_out[m1b] = M1;

        if (b2 >= 0) {
            const float *c2 = vrik_bindpos(rigv, vrik_finger_bones[side][f][1]);
            if (c2) {
                float f_p2[3], cx2[3];
                aff_dir((rest ? rest : &pal->orig[b2])->m, fb, f_p2); v3norm(f_p2);
                v3cross(f_p1, f_p2, cx2);
                float cur_ang2 = atan2f(v3dot(cx2, ax_curl), v3dot(f_p1, f_p2));
                float tgt_ang2 = curl * 0.95f;
                float d2 = fmaxf(-0.35f, fminf(0.35f, (tgt_ang2 - cur_ang2) * 0.55f));

                float p2[3], p2m[3]; aff_pt((rest ? rest : &pal->orig[b2])->m, c2, p2); aff_pt(M1.m, p2, p2m);
                aff M2 = aff_mul(aff_rot(ax_curl, d2, p2m), M1);
                M_out[b2] = M2;
                if (m2a >= 0) M_out[m2a] = M2;
                if (b3 >= 0) {
                    const float *c3 = vrik_bindpos(rigv, vrik_finger_bones[side][f][2]);
                    if (c3) {
                        float p3[3], p3m[3]; aff_pt((rest ? rest : &pal->orig[b3])->m, c3, p3); aff_pt(M2.m, p3, p3m);
                        M_out[b3] = aff_mul(aff_rot(ax_curl, d2 * 0.50f, p3m), M2);
                    } else {
                        M_out[b3] = M2;
                    }
                }
            }
        }
    }

    if (trigger_only) return;
    // Thumb flexion (Thumb1, Thumb2 + thumb side/base muscle bones)
    const int *t_jnt = vrik_thumb_bones[side];
    int tb1 = -1, tb2 = -1, tm1 = -1, tm2 = -1, tm3 = -1;
    for (uint32_t k = 0; k < pal->nb; k++) {
        int nm = vrik_pal_name(pal,k);
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
            float pt1[3]; aff_pt((rest ? rest : &pal->orig[tb1])->m, ct1, pt1);
            aff MT1 = aff_rot(f_hand, side ? -dt : dt, pt1);
            M_out[tb1] = MT1;
            if (tm1 >= 0) M_out[tm1] = MT1;
            if (tm2 >= 0) M_out[tm2] = MT1;
            if (tm3 >= 0) M_out[tm3] = MT1;
            if (tb2 >= 0) {
                const float *ct2 = vrik_bindpos(rigv, t_jnt[1]);
                if (ct2) {
                    float pt2[3], pt2m[3]; aff_pt((rest ? rest : &pal->orig[tb2])->m, ct2, pt2); aff_pt(MT1.m, pt2, pt2m);
                    M_out[tb2] = aff_mul(aff_rot(f_hand, side ? -dt : dt, pt2m), MT1);
                } else {
                    M_out[tb2] = MT1;
                }
            }
        }
    }
}

// Bounded diagnostics for identifying the actual weapon palette; bone count alone is not a weapon identifier.
static void vrik_weapon_trace(const vrik_pal *pal, float dist_body) {
    static int enabled = -1;
    if (enabled < 0) { const char *e = getenv("VXMAC_VRIK_WEAPON_DIAG"); enabled = e && !strcmp(e, "1"); }
    if (!enabled || !g_vk.have_h[1]) return;
    static struct { NSUInteger count; uint32_t bones; } seen[64]; static int nseen;
    for (int i = 0; i < nseen; i++) if (seen[i].count == pal->count && seen[i].bones == pal->nb) return;
    if (nseen >= 64) return;
    const float *bind = vrik_bindpos(g_vk.rigv, VRIK_RIGHTHAND);
    if (!bind) return;
    float wrist[3], wrist_view[3]; aff_pt(g_vk.SH[1].m, bind, wrist);
    aff body_view = aff_mul(g_vk.vcam, g_vk.obj); aff_pt(body_view.m, wrist, wrist_view);
    aff item_view = aff_mul(g_vk.vcam, pal->obj);
    float d[3] = { item_view.m[3] - wrist_view[0], item_view.m[7] - wrist_view[1], item_view.m[11] - wrist_view[2] };
    if (v3len(d) > 1.25f) return;
    seen[nseen].count = pal->count; seen[nseen++].bones = pal->nb;
    vxmac_log("VRIK weapon candidate: indices=%lu bones=%u body=%.3f wrist=%.3f item=(%.3f %.3f %.3f) hand=(%.3f %.3f %.3f)",
              (unsigned long)pal->count, pal->nb, dist_body, v3len(d), item_view.m[3], item_view.m[7], item_view.m[11],
              wrist_view[0], wrist_view[1], wrist_view[2]);
}

// Learn the trigger and support anchors in the weapon instance's own frame.
// The model key survives rotating skinning buffers and does not depend on a
// right arm draw being present after ownership has transferred.
static vrik_item_grip *vrik_item_slot(const vrik_pal *pal, int create) {
    vrik_item_grip *oldest = &g_vk.item_grips[0];
    for (unsigned i = 0; i < sizeof g_vk.item_grips / sizeof g_vk.item_grips[0]; i++) {
        vrik_item_grip *key = &g_vk.item_grips[i];
        if (key->indices == pal->indices && key->offset == pal->index_offset && key->count == pal->count) return key;
        unsigned last = key->drawn.frame > key->last_frame ? key->drawn.frame : key->last_frame;
        unsigned oldest_frame = oldest->drawn.frame > oldest->last_frame ? oldest->drawn.frame : oldest->last_frame;
        if (!key->indices || (oldest->indices && last < oldest_frame)) oldest = key;
    }
    if (!create || !pal->indices) return NULL;
    *oldest = (vrik_item_grip){ .indices = pal->indices, .offset = pal->index_offset, .count = pal->count };
    return oldest;
}

static int vrik_item_candidate(const vrik_pal *pal, aff item_view) {
    if (!pal->indices || !g_vk.capture_body || !g_vk.weapon_origin_valid ||
        g_vk.solve_frame != pal->frame) return 0;
    float origin[3] = { item_view.m[3], item_view.m[7], item_view.m[11] };
    float distance = vrik_distance(origin, g_vk.native_item_grip.at);
    if (distance < .18f && v3len(origin) < .95f) return 1;
    return g_vk.held.owner >= 0 && distance < .75f && v3len(origin) < 1.65f ? 2 : 0;
}

static void vrik_learn_item(vrik_item_grip *item, unsigned frame, int candidate, aff inverse) {
    if (item->samples < 3 && (!item->samples || item->last_frame != frame)) {
        vrik_grip_pose sample = vrik_grip_in(inverse, &g_vk.native_item_grip);
        int agrees = item->samples && vrik_distance(sample.at, item->grip.at) < .025f &&
                     v3dot(sample.fwd, item->grip.fwd) > .94f && v3dot(sample.up, item->grip.up) > .94f;
        if (!agrees) {
            item->first_native = g_vk.native_item_grip;
            item->samples = 1;
        } else {
            // A distant root is accepted after its own transform follows the
            // authored right hand across distinct frames, including motion.
            int moved = vrik_distance(item->first_native.at, g_vk.native_item_grip.at) >= .025f ||
                        v3dot(item->first_native.fwd, g_vk.native_item_grip.fwd) < .985f ||
                        v3dot(item->first_native.up, g_vk.native_item_grip.up) < .985f;
            if (candidate == 1) item->samples = 3;
            else if (item->samples < 2 || moved) item->samples++;
        }
        item->grip = sample;
        item->last_frame = frame;
    }
    if (!item->support_valid && g_vk.item_support_valid) {
        item->support = vrik_grip_in(inverse, &g_vk.native_item_support);
        item->support_valid = 1;
    }
}

static void vrik_capture_hand_shape(int side, const vrik_pal *pal, uint32_t list,
                                     const aff finger_delta[128]) {
    int wrist = -1;
    for (unsigned k = 0; k < pal->nb; k++)
        if (vrik_pal_name(pal,k) == (side ? VRIK_RIGHTHAND : VRIK_LEFTHAND)) wrist = (int)k;
    if (wrist < 0 || !g_vk.have_h[side]) return;
    vrik_grip_pose palm;
    if (!vrik_trigger_grip(side, pal->orig[wrist], &palm)) return;
    aff from_palm = aff_inv(vrik_grip_basis(&palm));
    __typeof__(g_vk.hand_shape[0]) *shape = &g_vk.hand_shape[side];
    int frozen = side ? g_vk.trigger_source.valid : g_vk.support_pose.locked;
    if (frozen && shape->ready) return;
    shape->count = 0;
    for (unsigned k = 0; k < pal->nb; k++) {
        int name = vrik_pal_name(pal,k), digit = vrik_grip_digit(side,name);
        if (digit < 0 || (digit < 24 ? digit % 6 >= 3 : digit >= 26)) continue;
        const float *bind = vrik_bindpos(g_vk.rigv,name);
        if (!bind || shape->count >= 32) continue;
        aff posed = aff_mul(finger_delta[k],pal->orig[k]);
        float point[3]; aff_pt(posed.m,bind,point);
        aff_pt(from_palm.m,point,shape->points[shape->count++]);
    }
    shape->ready = shape->count >= 12;
    if (side && shape->ready && !g_vk.trigger_source.valid) {
        for (unsigned k = 0; k < pal->nb; k++) if (vrik_pal_name(pal,k) == vrik_finger_bones[1][0][2]) {
            g_vk.trigger_source.hand = vrik_grip_basis(&palm);
            g_vk.trigger_source.finger = aff_mul(finger_delta[k],pal->orig[k]);
            g_vk.trigger_source.valid = 1;
        }
    }
}

static float vrik_pistol_spacing(void) {
    float right = 0, left = 0;
    for (int k = 0; k < g_vk.hand_shape[1].count; k++) right = fminf(right,g_vk.hand_shape[1].points[k][2]);
    for (int k = 0; k < g_vk.hand_shape[0].count; k++) left = fmaxf(left,g_vk.hand_shape[0].points[k][2]);
    float r[2][3],l[2][3],rr=0,lr=0;
    vrik_palm_capsule(1,aff_id(),r,&rr); vrik_palm_capsule(0,aff_id(),l,&lr);
    // The separation plane includes curled fingers, not just the two wrists.
    return fmaxf(rr+lr+.002f,left-right+(rr+lr)/4.f);
}

static vrik_grip_pose vrik_palm_wrist(int side, const vrik_grip_pose *palm) {
    vrik_grip_pose native, wrist;
    vrik_trigger_grip(side,aff_id(),&native);
    vrik_wrist_frame_from(side,aff_id(),wrist.at,wrist.fwd,wrist.up);
    aff local = aff_mul(aff_inv(vrik_grip_basis(&native)),vrik_grip_basis(&wrist));
    aff target = aff_mul(vrik_grip_basis(palm),local);
    vrik_grip_pose result;
    for (int i=0;i<3;i++) {result.at[i]=target.m[4*i+3];result.fwd[i]=target.m[4*i];result.up[i]=target.m[4*i+1];}
    return result;
}

static void vrik_asset_support(const vrik_asset_profile *asset, aff root, const vrik_grip_pose *source) {
    vrik_grip_pose palm;
    int short_gun = asset->kind & (4|8);
    if (short_gun) {
        if (!g_vk.hand_shape[0].ready || !g_vk.hand_shape[1].ready) return;
        palm = (vrik_grip_pose){{0,0,-vrik_pistol_spacing()},{1,0,0},{0,1,0}};
        palm = vrik_grip_in(vrik_grip_basis(source),&palm);
    } else {
        if (!(asset->kind & 16) && asset->support < 0) return;
        palm = (vrik_grip_pose){{asset->support_at[0],asset->support_at[1],asset->support_at[2]},
                               {0,1,0},{1,0,0}};
        float ends[2][3], radius=0;
        vrik_palm_capsule(0,aff_id(),ends,&radius);
        // A left palm faces opposite cross(fingers, thumb-side). Its surface
        // faces upward with +X transverse, and its centre stays below the gun.
        palm.at[2] -= radius*.5f;
        palm = vrik_grip_in(root,&palm);
    }
    vrik_grip_pose wrist = vrik_palm_wrist(0,&palm);
    int active = vrik_support_requested();
    if (!active || !g_vk.support_pose.locked) {
        g_vk.support_local = vrik_grip_in(aff_inv(vrik_grip_basis(source)),&wrist);
        g_vk.support_local_owner = 1; g_vk.support_local_at = g_vk.held.at;
        if (active) {
            g_vk.support_pose.generation++;
            g_vk.support_pose.locked = 1; g_vk.support_pose.epoch = g_vk.held.epoch;
        }
    }
    g_vk.weapon_frame.support_valid = 1;
    g_vk.weapon_frame.support_world = wrist;
}

// Bind a named receiver once per equipment epoch. Thereafter its actual root,
// rather than a newly animated body wrist, determines the native source grip.
static int vrik_asset_latch(const vrik_pal *pal) {
    const vrik_asset_profile *asset = pal->asset;
    int melee=asset && (asset->kind&64);
    if (!asset || !(asset->kind & (1|64)) || asset->root < 0 || (!melee && asset->trigger < 0) ||
        asset->root >= pal->nb || (!melee && (asset->trigger >= pal->nb || !g_vk.trigger_source.valid)) ||
        g_vk.held.owner != 1 || !g_vk.held.right_grip_valid || !g_vk.capture_body ||
        g_vk.solve_frame != pal->frame) return 0;
    __typeof__(g_vk.weapon_frame) *frame = &g_vk.weapon_frame;
    __typeof__(g_vk.asset_grip) *binding = &g_vk.asset_grip;
    if (frame->valid && frame->asset && frame->frame == pal->frame && frame->count >= pal->count) return 0;
    if (binding->valid && binding->asset != asset->asset && binding->count > pal->count &&
        pal->frame - binding->seen_frame <= 3) return 0;
    aff root = aff_mul(pal->obj,pal->orig[asset->root]);
    // Root coordinates retain the mesh's bind-space axes. The bind pivot only
    // translates this frame; rotating it twice would change the grip profile.
    aff root_basis = root;
    float origin[3];aff_pt(root.m,asset->root_at,origin);
    for (int i=0;i<3;i++)root_basis.m[4*i+3]=origin[i];
    if (!vrik_is_rot(root_basis.m)) return 0;
    if (!binding->valid || binding->epoch != g_vk.held.epoch || binding->asset != asset->asset) {
        vrik_grip_pose authored = vrik_grip_in(aff_inv(g_vk.vcam),&g_vk.native_item_grip);
        if(!melee) {
        const float *tip = vrik_bindpos(g_vk.rigv,vrik_finger_bones[1][0][2]);
        if (!tip) return 0;
        float finger[3], local[3], target_finger[3], trigger[3];
        aff_pt(g_vk.trigger_source.finger.m,tip,finger);
        aff_pt(aff_inv(g_vk.trigger_source.hand).m,finger,local);
        aff_pt(vrik_grip_basis(&authored).m,local,target_finger);
        aff_pt(aff_mul(pal->obj,pal->orig[asset->root]).m,asset->trigger_at,trigger);
        for (int i=0;i<3;i++) authored.at[i] += trigger[i]-target_finger[i];
        }
        binding->in_root = aff_mul(aff_inv(root_basis),vrik_grip_basis(&authored));
        binding->asset = asset->asset; binding->epoch = g_vk.held.epoch;
        binding->count = (unsigned)pal->count; binding->valid = 1;
        g_vk.support_pose.locked = 0;
        vxmac_log("VRIK asset grip: asset=%u indices=%lu bones=%u trigger=%d epoch=%u",
                  asset->asset,(unsigned long)pal->count,asset->bones,asset->trigger,g_vk.held.epoch);
    }
    binding->seen_frame = pal->frame;
    aff native = aff_mul(root_basis,binding->in_root);
    vrik_grip_pose tracked=vrik_grip_in(aff_inv(g_vk.vcam),&(vrik_grip_pose){
        {g_vk.held.right_grip_view.m[3],g_vk.held.right_grip_view.m[7],g_vk.held.right_grip_view.m[11]},
        {g_vk.held.right_grip_view.m[0],g_vk.held.right_grip_view.m[4],g_vk.held.right_grip_view.m[8]},
        {g_vk.held.right_grip_view.m[1],g_vk.held.right_grip_view.m[5],g_vk.held.right_grip_view.m[9]}});
    aff target_world = vrik_grip_basis(&tracked);
    frame->world_delta = aff_mul(target_world,aff_inv(native));
    frame->view_from_world = g_vk.vcam;
    for (int i=0;i<3;i++) {frame->native_world.at[i]=native.m[4*i+3];frame->native_world.fwd[i]=native.m[4*i];frame->native_world.up[i]=native.m[4*i+1];}
    frame->frame = pal->frame;frame->epoch=g_vk.held.epoch;frame->valid=1;frame->asset=1;frame->count=(unsigned)pal->count;
    frame->support_valid=0;
    if(!melee)vrik_asset_support(asset,root,&frame->native_world);
    binding->revision++;
    return 1;
}

static int vrik_draw_grip(int owner, int solved, vrik_grip_pose *grip) {
    aff target;
    if (owner == 1) {
        if (!g_vk.held.right_grip_valid || g_vk.held.right_grip_frame != g_vk.capture_frame) return 0;
        target = g_vk.held.right_grip_view;
    } else {
        if (solved) { *grip = g_vk.item_target; return 1; }
        if (owner < 0 || !(g_vk.held.wrists & (1u << owner))) return 0;
        target = g_vk.held.wrist_view;
        if (g_vk.held.grip_calibrated && g_vk.held.grip_epoch == g_vk.held.epoch)
            target = aff_mul(target, g_vk.held.grip_from_wrist);
    }
    for (int i = 0; i < 3; i++) {
        grip->at[i] = target.m[i*4+3];
        grip->fwd[i] = target.m[i*4];
        grip->up[i] = target.m[i*4+1];
    }
    return 1;
}

static aff vrik_item_delta(const vrik_grip_pose *source, aff item_view, const vrik_grip_pose *target) {
    vrik_grip_pose from = vrik_grip_in(item_view, source);
    aff move = vrik_retarget_grip(from.at, from.fwd, from.up, target->at, target->fwd, target->up);
    return aff_mul(aff_inv(item_view), aff_mul(move, item_view));
}

static void vrik_note_drawn_grip(const vrik_pal *pal, vrik_item_grip *item, aff native_view, aff room_from_item,
                                 const vrik_grip_pose *source, const vrik_grip_pose *support) {
    int owner = g_vk.held.owner;
    if (owner < 0 || pal->magazine || !(g_vk.held.wrists & (1u << owner))) return;
    // The weapon body normally has more indices than its mounted parts.
    // Take one grip for the frame even when the same weapon uses many draws.
    if (g_vk.contacts_frame == pal->frame && pal->count < g_vk.contact_indices) return;
    g_vk.contacts_frame = pal->frame;
    g_vk.contact_indices = pal->count;
    g_vk.contacts_owner = owner;
    g_vk.contacts_at = g_vk.held.at;
    aff_pt(room_from_item.m, source->at, g_vk.contact_room);
    // The ranged viewmodels point along their longitudinal Y axis. Resolve
    // its sign in the native draw pose, before the hand rotates the mesh.
    if (item && pal->asset && (pal->asset->kind&1)) item->bore_sign=1;
    if (item && !item->bore_sign && fabsf(native_view.m[9]) > .65f && native_view.m[6] > .35f)
        item->bore_sign = native_view.m[9] > 0 ? 1 : -1;
    aff item_view = aff_mul(aff_inv(g_vk.held.room_from_view), room_from_item);
    vrik_grip_pose owner_grip = vrik_grip_in(item_view, source);
    vrik_publish_support(owner, pal->obj, source, support, &owner_grip);
    if (item && item->bore_sign) {
        aff bore=pal->asset ? aff_mul(room_from_item,pal->orig[pal->asset->root]) : room_from_item;
        aff_dir(bore.m, (float[3]){0, item->bore_sign, 0}, g_vk.bore_room);
        aff_dir(bore.m, (float[3]){0, 0, 1}, g_vk.bore_room + 3);
        memcpy(g_vk.bore_room + 6, g_vk.contact_room, sizeof g_vk.contact_room);
        g_vk.bore_room[9] = g_vk.support_contact_at == g_vk.held.at ? vrik_distance(g_vk.contact_room, g_vk.support_room) : 0;
        if (v3norm(g_vk.bore_room) && v3norm(g_vk.bore_room + 3)) g_vk.bore_at = g_vk.held.at;
    }
}

static const struct { uint32_t bones, slide; float joint[3]; } vrik_receivers[] = {
    {5, 1, {0, .2767f, .0515f}}, // Saratoga
    {2, 1, {0, .2767f, .0515f}}, // Saratoga lever submesh
    {5, 2, {0, .0859f, .0216f}}, // Unity / Liberty
};

// Local asset metadata and index fingerprints for one-joint ammo meshes.
// Both LODs of one magazine use the same visual identity.
static const struct { NSUInteger count; uint64_t hash; int mesh; } vrik_magazines[] = {
    {108,   UINT64_C(0xaeea4fea3a77df95), 1},
    {738,   UINT64_C(0xce016b542d44cd8d), 2}, // Tsunami Nue
    {4413,  UINT64_C(0x199086271e7790bd), 3}, // Unity / Liberty
    {540,   UINT64_C(0x2761b99add52faa4), 3},
    {23046, UINT64_C(0x4e36e1aceb0707c2), 4}, // D5 Copperhead
    {576,   UINT64_C(0x049977ad06ac6562), 4},
    {9633,  UINT64_C(0xcdf08cb373fd9948), 5}, // Saratoga magazine variant
    {816,   UINT64_C(0xe0d49ca97bba4f76), 5},
    // The Satara's seated left and right shells have identical index data.
    {4032,  UINT64_C(0x8eb437bad74f33bd), VRIK_SATARA_SHELL},
    {228,   UINT64_C(0x6d1f546ff5e07c96), VRIK_SATARA_SHELL},
    {4932,  UINT64_C(0x328106a211000d93), VRIK_SARATOGA_MAG},
    {8172,  UINT64_C(0xf0e66a7b80a26b58), VRIK_SARATOGA_MAG},
    {468,   UINT64_C(0xb842a60e8c705bd2), VRIK_SARATOGA_MAG},
    {8184,  UINT64_C(0x63e76d32f3e45f2a), VRIK_SARATOGA_MAG},
    {1296,  UINT64_C(0x0c5c72fcfaf13553), VRIK_SARATOGA_MAG},
    {75096, UINT64_C(0xf6ee3549d6f57bd8), VRIK_RECEIVER},
    {8514,  UINT64_C(0xb0d0f527d5d36fd2), VRIK_RECEIVER},
    {12795, UINT64_C(0x26a51d68f449df9f), VRIK_RECEIVER + 1},
    {41373, UINT64_C(0x0c137715f8f56073), VRIK_RECEIVER + 2},
    {4890,  UINT64_C(0xf9a60d49e30041d1), VRIK_RECEIVER + 2},
    {4890,  UINT64_C(0x4923071ef80d2cbe), VRIK_RECEIVER + 2},
};

static int vrik_magazine_match(const uint8_t *bytes, NSUInteger count, size_t width) {
    uint64_t hash = UINT64_C(14695981039346656037);
    for (NSUInteger i = 0; i < count; i++) {
        uint32_t index = 0;
        memcpy(&index, bytes + i * width, width);
        if (index > UINT16_MAX) return 0;
        hash = (hash ^ (index & 255)) * UINT64_C(1099511628211);
        hash = (hash ^ (index >> 8)) * UINT64_C(1099511628211);
    }
    const vrik_asset_profile *asset = vrik_asset_match(count, hash);
    if (vrik_replay_enabled()) {
        static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
        static struct { uint64_t hash; NSUInteger count; } seen[96];static unsigned used;
        pthread_mutex_lock(&lock);
        unsigned i=0;while(i<used && (seen[i].hash!=hash || seen[i].count!=count))i++;
        if(i==used && used<96 && (asset || used<16)) {
            seen[used].hash=hash;seen[used++].count=count;
            vxmac_log("VRIK fingerprint: indices=%lu hash=%016llx asset=%u width=%zu",(unsigned long)count,
                      (unsigned long long)hash,asset?asset->asset:0,width);
        }
        pthread_mutex_unlock(&lock);
    }
    if (asset) return VRIK_ASSET_BASE + (int)(asset - vrik_assets);
    for (unsigned i = 0; i < sizeof vrik_magazines / sizeof vrik_magazines[0]; i++) {
        if (vrik_magazines[i].count == count && vrik_magazines[i].hash == hash)
            return vrik_magazines[i].mesh;
    }
    return 0;
}

// Resolve private index buffers with an asynchronous, bounded Metal copy.
// Draw encoding never waits for this lookup and unknown geometry is unchanged.
static int vrik_magazine_mesh(id<MTLBuffer> indices, NSUInteger offset, NSUInteger count, MTLIndexType type,int foreground) {
    unsigned first = vrik_asset_first(count);
    int candidate = first < VRIK_ASSET_COUNT && vrik_assets[first].count == count;
    for (unsigned i = 0; i < sizeof vrik_magazines / sizeof vrik_magazines[0]; i++)
        if (vrik_magazines[i].count == count) { candidate = 1; break; }
    if (!candidate || !indices) return 0;
    size_t width = type == MTLIndexTypeUInt16 ? 2 : 4;
    if (offset > indices.length || count > (indices.length - offset) / width) return 0;
    typedef struct {
        uint64_t address;
        NSUInteger offset, count;
        size_t width;
        unsigned frame, sampled, attempts;
        int mesh, pending;
    } lookup;
    static lookup cache[256];
    static id<MTLCommandQueue> queue;
    static unsigned last_copy_frame[2] = {UINT32_MAX,UINT32_MAX}, pending_copies;
    unsigned frame = atomic_load(&g_frame);
    uint64_t address = indices.gpuAddress;
    lookup *slot = NULL;
    for (unsigned i = 0; i < sizeof cache / sizeof cache[0]; i++) {
        lookup *key = &cache[i];
        if (key->address == address && key->offset == offset && key->count == count && key->width == width) {
            key->frame = frame;
            if (key->mesh || key->pending || key->attempts >= 2 || frame - key->sampled < 15) return key->mesh;
            slot = key;
            break;
        }
        if (!key->pending && (!slot || key->frame < slot->frame)) slot = key;
    }
    if (!slot || !address) return 0;
    if (indices.storageMode == MTLStorageModeShared) {
        int mesh = vrik_magazine_match((const uint8_t *)indices.contents + offset, count, width);
        *slot = (lookup){address, offset, count, width, frame, frame, 2, mesh, 0};
        return mesh;
    }
    // Early scenery must not consume the only readback slot before the
    // visible hands/sleeves reach this encoder. Keep a foreground budget and
    // one pending slot available without increasing the total in-flight cap.
    unsigned priority=!!foreground;
    if (indices.storageMode != MTLStorageModePrivate || last_copy_frame[priority] == frame ||
        pending_copies >= 2 || (!foreground && pending_copies)) return 0;
    NSUInteger copy_start = offset & ~(NSUInteger)3;
    NSUInteger skip = offset - copy_start;
    NSUInteger copy_size = (skip + count * width + 3) & ~(NSUInteger)3;
    if (copy_size > indices.length - copy_start || copy_size > 2 * 1024 * 1024) return 0;
    if (!queue) {
        queue = [indices.device newCommandQueue];
        queue.label = @"VX Mac magazine indices";
    }
    id<MTLBuffer> bytes = [indices.device newBufferWithLength:copy_size options:MTLResourceStorageModeShared];
    if (!bytes) return 0;
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!blit) return 0;
    last_copy_frame[priority] = frame;
    pending_copies++;
    unsigned attempts = slot->address == address && slot->offset == offset && slot->count == count ? slot->attempts : 0;
    *slot = (lookup){address, offset, count, width, frame, frame, attempts + 1, 0, 1};
    [blit copyFromBuffer:indices sourceOffset:copy_start toBuffer:bytes destinationOffset:0 size:copy_size];
    [blit endEncoding];
    [command addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        int mesh = finished.status == MTLCommandBufferStatusCompleted
            ? vrik_magazine_match((const uint8_t *)bytes.contents + skip, count, width) : 0;
        pthread_mutex_lock(&g_vk_l);
        slot->mesh = mesh;
        slot->pending = 0;
        pending_copies--;
        pthread_mutex_unlock(&g_vk_l);
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [command commit]; });
    return 0;
}

static const float vrik_magazine_centers[][3] = {
    {0, -.0213f, -.0599f}, {0, .00015f, 0}, {0, -.0220f, -.0555f},
    {0, -.0528f, -.0955f}, {0, .0397f, -.1224f}, {0, .0400f, 0}, {0, .0397f, -.1224f}
};

static const float *vrik_ammo_center(const vrik_pal *pal) {
    return pal->asset ? pal->asset->ammo_at : vrik_magazine_centers[pal->magazine - 1];
}

static void vrik_note_rack(aff room_from_bone, const float joint[3], int key) {
    aff_pt(room_from_bone.m, joint, g_vk.rack_room);
    aff_dir(room_from_bone.m, (float[3]){0, 1, 0}, g_vk.rack_room + 3);
    if (!v3norm(g_vk.rack_room + 3)) return;
    g_vk.rack_valid = key;
    g_vk.rack_auto = key != 3 && key != VRIK_RECEIVER + 2;
    g_vk.rack_at = g_vk.held.at;
}

static void vrik_note_reload_targets(const vrik_pal *pal, aff item_view, aff delta) {
    int owner = g_vk.held.owner;
    if (owner < 0 || !(g_vk.held.wrists & (1u << owner))) return;
    if (g_vk.reload_frame == pal->frame && g_vk.reload_priority > 1) return;
    g_vk.reload_frame = pal->frame; g_vk.reload_priority = 1;
    aff posed = aff_mul(g_vk.held.room_from_view, aff_mul(item_view, delta));
    aff_pt(aff_mul(posed, pal->orig[pal->asset ? pal->asset->root : 0]).m, vrik_ammo_center(pal), g_vk.well_room);
    g_vk.reload_mesh = pal->magazine ? pal->magazine : VRIK_CATALOG_AMMO;
    g_vk.reload_owner = owner;
    g_vk.reload_at = g_vk.held.at;
    // Bind positions of the Unity slide and the Copperhead charging lever.
    // Their separately identified magazine meshes share the weapon's origin.
    static const float unity[3] = {0, .08594f, .02164f};
    static const float copperhead[3] = {0, .34066f, .04777f};
    const float *joint = pal->magazine == 3 ? unity : pal->magazine == 4 ? copperhead : NULL;
    if (joint && (g_vk.rack_valid < VRIK_RECEIVER || g_vk.held.at - g_vk.rack_at > .18))
        vrik_note_rack(posed, joint, pal->magazine);
}

static int (*vrik_mag_query)(double *, unsigned *);
static int vrik_mag_state(double *started, unsigned *ejection) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ if (!vrik_mag_query) vrik_mag_query=dlsym(RTLD_DEFAULT,"vx_xros_vr_manual_mag_frame"); });
    return vrik_mag_query && g_vk.held.owner >= 0 ? vrik_mag_query(started,ejection) : -1;
}

static aff vrik_manual_slide(const vrik_pal *pal, vrik_item_grip *item, unsigned index) {
    int pistol=(pal->asset && (pal->asset->kind&8) && pal->asset->slide==(int)index) ||
               (pal->receiver==VRIK_RECEIVER+2 && index==vrik_receivers[2].slide);
    aff bone=pal->orig[index];
    if (!pistol || !item) return bone;
    unsigned root=pal->asset ? pal->asset->root : 0;
    if (root>=pal->nb) return bone;
    double started=0;unsigned ejection=0;int state=vrik_mag_state(&started,&ejection);
    if(item->slide_epoch!=g_vk.held.epoch) {
        item->slide_valid=item->slide_pending=0;
        item->slide_shown=item->slide_release_from=0;item->slide_release_at=0;
    }
    int pending=state==HW_EMPTY || state==HW_HOLD_NEW || state==HW_IN_NO_ROUND;
    if(!item->slide_valid && (state==HW_LOADED || pending) && g_vk.slide_pull<=0) {
        item->slide_rest=aff_mul(aff_inv(pal->orig[root]),bone);
        item->slide_epoch=g_vk.held.epoch;item->slide_valid=1;
    }
    if(!item->slide_valid) return bone;
    float pull=fmaxf(0,g_vk.slide_pull);
    if(pending) {
        // Inserting ammunition is not a slide-release operation. The open
        // position remains latched until the physical pull chambers the round.
        pull=.035f+fminf(.045f,pull);
        item->slide_pending=1;item->slide_release_at=0;
    } else if(state==HW_LOADED && item->slide_pending) {
        item->slide_pending=0;item->slide_release_at=g_vk.held.at;
        item->slide_release_from=item->slide_shown;
    }
    if(item->slide_release_at) {
        float t=fminf(1.f,fmaxf(0,(float)(g_vk.held.at-item->slide_release_at)/.10f));
        pull=fmaxf(pull,item->slide_release_from*(1-t));
        if(t>=1) item->slide_release_at=0;
    }
    item->slide_shown=pull;
    if(pending || pull>0 || item->slide_release_at) {
        bone=aff_mul(pal->orig[root],item->slide_rest);
        float shift[3];aff_dir(pal->orig[root].m,(float[3]){0,-pull,0},shift);
        for(int i=0;i<3;i++) bone.m[4*i+3]+=shift[i];
    }
    return bone;
}

static aff vrik_cylinder_pose(const vrik_pal *pal, aff bone, unsigned index) {
    const vrik_asset_profile *asset=pal->asset;
    if (!asset || asset->cylinder != (int)index) return bone;
    double started=0;unsigned ejection=0;
    int state=vrik_mag_state(&started,&ejection);
    if (state!=HW_EMPTY && state!=HW_HOLD_NEW) return bone;
    float t=fminf(1.f,fmaxf(0.f,(float)(g_vk.held.at-started)/.18f));
    const float *pivot=asset->hinge>=0?asset->hinge_at:asset->root_at;
    aff open=aff_rot((float[3]){0,1,0},-1.35f*t,pivot);
    // Skinning matrices already contain the parent pose: conjugate the
    // bind-space hinge through this bone, then move only the cylinder.
    return aff_mul(bone,open);
}

static aff vrik_magazine_pose(const vrik_pal *pal, vrik_item_grip *item, aff bone, unsigned index) {
    double started=0; unsigned ejection=0;
    int state=vrik_mag_state(&started,&ejection);
    if (state != HW_EMPTY && state != HW_HOLD_NEW) return bone;
    aff item_view = aff_mul(pal->view, pal->obj);
    aff room_item = aff_mul(g_vk.held.room_from_view, item_view);
    if (state == HW_HOLD_NEW) {
        int off = 1 - g_vk.held.owner;
        if (!g_vk.held.hands_ok[off]) {
            // A held magazine stays outside the gun after a sustained tracking loss.
            aff hidden = bone;
            aff down = aff_inv(room_item);
            for (int i = 0; i < 3; i++) hidden.m[i * 4 + 3] -= 8.f * down.m[i * 4 + 1];
            return hidden;
        }
        const float *hand = g_vk.held.hands[off];
        vrik_grip_pose palm;
        for (int i = 0; i < 3; i++) {
            float z = i == 2 ? -1.f : 1.f;
            palm.fwd[i] = z * hand[3 + i];
            palm.up[i] = z * hand[6 + i] * (off ? 1.f : -1.f);
            palm.at[i] = z * hand[i] + .035f * palm.fwd[i];
        }
        aff palm_view = vrik_grip_basis(&palm);
        aff mounted_bone = aff_mul(item_view,bone);
        aff relative = aff_id();
        aff mounted = mounted_bone;
        if (pal->asset) {
            aff delta=aff_mul(bone,aff_inv(pal->orig[index]));
            mounted=aff_mul(item_view,aff_mul(delta,pal->orig[pal->asset->root]));
            relative=aff_mul(aff_inv(mounted),mounted_bone);
        }
        const float *center = vrik_ammo_center(pal);
        float mount[3];
        aff_pt(mounted.m, center, mount);
        if (g_vk.held_mag.started != started || g_vk.held_mag.epoch != g_vk.held.epoch ||
            g_vk.held_mag.mesh != pal->magazine) {
            aff pickup = mounted;
            for (int i = 0; i < 3; i++) pickup.m[i * 4 + 3] += palm.at[i] - mount[i];
            g_vk.held_mag.from_palm = aff_mul(aff_inv(palm_view), pickup);
            g_vk.held_mag.started = started;
            g_vk.held_mag.epoch = g_vk.held.epoch;
            g_vk.held_mag.mesh = pal->magazine;
        }
        aff carried = aff_mul(palm_view, g_vk.held_mag.from_palm);
        float approach=fmaxf(0.f,fminf(1.f,(HW_MAG_GUIDE_RADIUS-vrik_distance(mount,palm.at))/(HW_MAG_GUIDE_RADIUS-HW_MAG_CAPTURE_RADIUS)));
        // The same capture radius as the input state machine; guide both the
        // centre and orientation rather than rotating a remote magazine.
        aff guided = vrik_blend_pose(carried, mounted, aff_id(), approach);
        float current[3];
        aff_pt(guided.m, center, current);
        for (int i = 0; i < 3; i++) guided.m[i * 4 + 3] += palm.at[i]+approach*(mount[i]-palm.at[i])-current[i];
        return aff_mul(aff_inv(item_view),aff_mul(guided,relative));
    }
    // Each Satara shell has its own draw and bone even though the index
    // fingerprints match. Capture their departure poses independently.
    vrik_mag_drop *drop = &g_vk.dropped_mag;
    if (pal->magazine == VRIK_SATARA_SHELL || pal->asset) {
        if (!item) return bone;
        drop = &item->shell_drop;
    }
    aff room_bone=aff_mul(room_item,bone), room_root=room_bone;
    if (pal->asset) {
        aff delta=aff_mul(bone,aff_inv(pal->orig[index]));
        room_root=aff_mul(room_item,aff_mul(delta,pal->orig[pal->asset->root]));
    }
    if (drop->ejection != ejection || drop->mesh != pal->magazine) {
        drop->ejection = ejection;
        drop->mesh = pal->magazine;
        drop->pose = room_root;
    }
    aff fallen = drop->pose;
    float seconds = fmaxf(0, (float)(CACurrentMediaTime() - started));
    fallen.m[7] -= seconds < .55f ? .10f * seconds + 4.9f * seconds * seconds : 8.f;
    aff moved=pal->asset ? aff_mul(fallen,aff_mul(aff_inv(room_root),room_bone)) : fallen;
    return aff_mul(aff_inv(room_item), moved);
}

static int vrik_held_bone(int side, int name, int segment) {
    if (side == 0)
        return (segment >= 1 && segment <= 3) || (name >= 1503 && name <= 1505) ||
               name == 1678 || name == 1680 || name == 1682;
    return (segment >= 4 && segment <= 6) || (name >= 1974 && name <= 1976) ||
           name == 2148 || name == 2149 || name == 2150;
}

typedef struct {
    aff upper, forearm;
    float elbow[3], wrist[3], axis[3];
} vrik_arm_solution;

// The final receiver contact moves the whole arm, using this consumer's
// immutable source. It never overwrites the earlier free-hand/right-arm solve.
static int vrik_two_bone(const float S[3],const float upper_end[3],const float E[3],const float W[3],const float T[3],
                         const float pole[3],const float fallback[3],int exact,vrik_arm_solution *out) {
    float a0[3],b0[3],u[3],n[3];
    for(int i=0;i<3;i++) {a0[i]=upper_end[i]-S[i];b0[i]=W[i]-E[i];u[i]=T[i]-S[i];n[i]=pole[i];}
    float a=v3len(a0),b=v3len(b0),d=v3len(u);
    if(a<.001f || b<.001f || d<.001f)return 0;
    v3norm(u);
    float dc=fmaxf(fabsf(a-b)+.01f,fminf(a+b-.002f,d));
    float k=v3dot(n,u);for(int i=0;i<3;i++)n[i]-=k*u[i];
    if(!v3norm(n)) {
        memcpy(n,fallback,sizeof n);k=v3dot(n,u);for(int i=0;i<3;i++)n[i]-=k*u[i];
        if(!v3norm(n))return 0;
    }
    float ca=(a*a+dc*dc-b*b)/(2*a*dc);ca=fmaxf(-1,fminf(1,ca));float sa=sqrtf(1-ca*ca);
    for(int i=0;i<3;i++) {out->elbow[i]=S[i]+a*(ca*u[i]+sa*n[i]);out->wrist[i]=S[i]+dc*u[i];}
    float e1[3],f1[3];
    for(int i=0;i<3;i++)e1[i]=out->elbow[i]-S[i];
    out->upper=aff_arc(a0,e1,S);
    for(int i=0;i<3;i++)f1[i]=out->wrist[i]-out->elbow[i];
    // The native hand/accessory and sleeve can have different elbow poses.
    // Map each source forearm directly to the solved elbow, rather than
    // rotating it about another consumer's source elbow.
    out->forearm=aff_arc(b0,f1,E);
    for(int i=0;i<3;i++)out->forearm.m[i*4+3]+=out->elbow[i]-E[i];
    memcpy(out->axis,f1,sizeof f1);v3norm(out->axis);
    if(exact && fabsf(dc-d)>.0001f) {
        float direction[3];for(int i=0;i<3;i++)direction[i]=T[i]-out->elbow[i];
        float length=v3len(direction);
        if(!v3norm(direction))return 0;
        aff stretch=aff_id();float scale=length/b-1.f;
        for(int row=0;row<3;row++) {
            for(int col=0;col<3;col++)stretch.m[row*4+col]+=scale*direction[row]*direction[col];
            stretch.m[row*4+3]=-scale*direction[row]*v3dot(direction,out->elbow);
        }
        out->forearm=aff_mul(stretch,aff_mul(aff_arc(out->axis,direction,out->elbow),out->forearm));
        memcpy(out->wrist,T,sizeof out->wrist);memcpy(out->axis,direction,sizeof out->axis);
    }
    return 1;
}

static int vrik_support_arm(const vrik_pal *pal, const aff *hand,
                            const vrik_grip_pose *target, aff delta[5]) {
    if (pal->rig != g_vk.rigv || !hand) return 0;
    const float *a=vrik_bindpos(pal->rig,VRIK_LEFTARM), *f=vrik_bindpos(pal->rig,VRIK_LEFTFOREARM),
                *h=vrik_bindpos(pal->rig,VRIK_LEFTHAND);
    if (!a || !f || !h) return 0;
    const aff *upper=g_vk.have_af[0] ? &g_vk.SA[0] : NULL;
    const aff *fore=g_vk.have_af[0] ? &g_vk.SF[0] : NULL;
    int own_upper=0;
    for (unsigned k=0;k<pal->nb;k++) {
        if (vrik_pal_name(pal,k)==VRIK_LEFTARM) {upper=&pal->orig[k];own_upper=2;}
        else if (vrik_pal_name(pal,k)==VRIK_L_SHL_0_JNT && own_upper<2) {upper=&pal->orig[k];own_upper=1;}
        if (vrik_pal_name(pal,k)==VRIK_LEFTFOREARM) fore=&pal->orig[k];
    }
    if (!upper || !fore || !vrik_is_rot(upper->m) || !vrik_is_rot(fore->m) || !vrik_is_rot(hand->m)) return 0;
    float S[3],E[3],W[3],end[3],wrist[3];
    aff_pt(upper->m,a,S);aff_pt(upper->m,f,end);
    aff_pt(fore->m,f,E);aff_pt(fore->m,h,W);aff_pt(hand->m,h,wrist);
    // A hand-only consumer can use a later native forearm pose than the
    // sleeve. Its own wrist/forearm pair is authoritative; the earlier upper
    // arm supplies only the shoulder position when it has no upper-arm bone.
    if ((own_upper && vrik_distance(end,E)>.025f) ||
        vrik_distance(W,wrist)>.025f ||
        vrik_distance(S,target->at)>.9f) return 0;
    aff from_view=aff_inv(aff_mul(pal->view,pal->obj));
    float pole[3],fallback[3];
    aff_dir(from_view.m,(float[3]){-.60f,-1.f,-.35f},pole);
    aff_dir(from_view.m,(float[3]){0,0,-1},fallback);
    vrik_arm_solution solved;
    if (!vrik_two_bone(S,end,E,W,target->at,pole,fallback,1,&solved)) return 0;
    vrik_grip_pose native;
    if (!vrik_wrist_frame_from(0,*hand,native.at,native.fwd,native.up)) return 0;
    float f2[3],up2[3],up[3],cross[3];
    aff_dir(solved.forearm.m,native.fwd,f2);v3norm(f2);
    aff_dir(solved.forearm.m,native.up,up2);memcpy(up,target->up,sizeof up);
    float d1=v3dot(up2,solved.axis),d2=v3dot(up,solved.axis);
    for (int i=0;i<3;i++) {up2[i]-=d1*solved.axis[i];up[i]-=d2*solved.axis[i];}
    float roll=0;
    if (v3norm(up2) && v3norm(up)) {v3cross(up2,up,cross);roll=atan2f(v3dot(cross,solved.axis),v3dot(up2,up));}
    float half[3];for (int i=0;i<3;i++) half[i]=f2[i]+target->fwd[i];
    if (!v3norm(half)) memcpy(half,target->fwd,sizeof half);
    delta[0]=solved.upper;delta[1]=solved.forearm;
    delta[2]=aff_mul(aff_rot(solved.axis,.30f*roll,solved.wrist),solved.forearm);
    delta[3]=aff_mul(aff_rot(solved.axis,.60f*roll,solved.wrist),solved.forearm);
    delta[4]=aff_mul(aff_rot(half,.85f*roll,solved.wrist),
                     aff_mul(aff_arc(f2,half,solved.wrist),solved.forearm));
    return 1;
}

static vrik_support_shape *vrik_consumer_shape(vrik_support_shape shapes[32],unsigned generation,
                                              unsigned clock,const vrik_pal *pal) {
    vrik_support_shape *oldest=&shapes[0];
    for (unsigned i=0;i<32;i++) {
        vrik_support_shape *shape=&shapes[i];
        if (shape->bones && shape->generation==generation &&
            shape->indices==pal->indices && shape->offset==pal->index_offset &&
            shape->count==pal->count && shape->list==pal->L && shape->rig==pal->rig && shape->bones==pal->nb) {
            shape->touch=clock;return shape;
        }
        if (!shape->bones || shape->generation!=generation) oldest=shape;
        else if (oldest->bones && oldest->generation==generation && shape->touch<oldest->touch) oldest=shape;
    }
    oldest->indices=pal->indices;oldest->offset=pal->index_offset;oldest->count=pal->count;
    oldest->list=pal->L;oldest->rig=pal->rig;oldest->bones=0;
    oldest->generation=generation;oldest->touch=clock;
    memset(oldest->valid,0,sizeof oldest->valid);
    return oldest;
}
static vrik_support_shape *vrik_support_shape_for(const vrik_pal *pal) {
    return vrik_consumer_shape(g_vk.support_pose.shapes,g_vk.support_pose.generation,++g_vk.support_pose.clock,pal);
}

static void vrik_apply_pal_pose(vrik_pal *pal) {
    if (pal->nb == 0 || pal->nb > pal->cap_b) return;
    if(!vrik_held_consumer(pal))return;
    pal->support_connected=0;
    if (pal->L >= 0 && g_vk.capture_body && pal->rig == g_vk.rigv &&
        memcmp(&pal->obj, &g_vk.obj, sizeof(aff))) {
        aff body_from_pal = aff_mul(aff_inv(g_vk.obj), pal->obj);
        aff pal_from_body = aff_inv(body_from_pal);
        vrik_pal body = *pal;
        body.obj = g_vk.obj;
        body.applied = 0;
        body.P = (uint8_t *)body.posed;
        for (unsigned k = 0; k < body.nb; k++) body.posed[k] = body.orig[k] = aff_mul(body_from_pal, pal->orig[k]);
        vrik_apply_pal_pose(&body);
        if (body.applied) {
            for (unsigned k = 0; k < body.nb; k++) ((aff *)pal->P)[k] = aff_mul(pal_from_body, body.posed[k]);
            pal->mod_k1 = body.mod_k1; pal->mod_k2 = body.mod_k2;
            pal->mod1 = ((aff *)pal->P)[pal->mod_k1]; pal->mod2 = ((aff *)pal->P)[pal->mod_k2];
            pal->applied = 1;
            pal->support_connected=body.support_connected;
        }
        return;
    }
    int held_owner = g_vk.held.owner;
    int live_arm = g_vk.solve_frame == pal->frame;
    int live_grip = live_arm && g_vk.item_target_valid && g_vk.item_target_frame == pal->frame &&
                    g_vk.item_target_owner == held_owner;
    int wrist_tracked = held_owner >= 0 && (g_vk.held.wrists & (1u << held_owner));
    if (pal->L >= 0) {
        int hold_arm = held_owner >= 0 && pal->rig == g_vk.held.rig;
        if ((!live_arm || (!g_vk.have_af[0] && !g_vk.have_af[1])) && !hold_arm) return;
        aff room_from_arm, arm_from_room, room_grip, grip_delta, placed_hand;
        vrik_grip_pose target;
        int target_valid = hold_arm && vrik_draw_grip(held_owner, live_grip, &target);
        if (hold_arm) {
            room_from_arm = aff_mul(g_vk.held.room_from_view, aff_mul(pal->view, pal->obj));
            arm_from_room = aff_inv(room_from_arm);
            if (target_valid) room_grip = aff_mul(g_vk.held.room_from_view, vrik_grip_basis(&target));
        }
        uint32_t o = pal->L<VRIK_NLISTS?vrik_list_off[pal->L]:0;
        int has_l_fng = 0, has_r_fng = 0, left_wrist = -1, right_wrist = -1, held_wrist = -1;
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_pal_name(pal,k);
            if (nm == VRIK_LEFTHANDINDEX1)  has_l_fng = 1;
            if (nm == VRIK_RIGHTHANDINDEX1) has_r_fng = 1;
            if (nm == VRIK_LEFTHAND) left_wrist = (int)k;
            if (nm == VRIK_RIGHTHAND) right_wrist = (int)k;
            if (held_owner >= 0 && nm == (held_owner ? VRIK_RIGHTHAND : VRIK_LEFTHAND)) held_wrist = (int)k;
        }
        const aff *source_hand = NULL;
        if (target_valid) {
            if (held_wrist >= 0) source_hand = &pal->orig[held_wrist];
            else if (g_vk.capture_body && g_vk.rigv == pal->rig && (g_vk.hand_ref_mask & (1u << held_owner)))
                source_hand = &g_vk.hand_ref[held_owner];
        }
        vrik_grip_pose source_grip;
        int place_hand = source_hand && vrik_trigger_grip(held_owner, *source_hand, &source_grip);
        if (place_hand) {
            aff arm_from_view = aff_mul(arm_from_room, g_vk.held.room_from_view);
            vrik_grip_pose hand_target = vrik_grip_in(arm_from_view, &target);
            grip_delta = vrik_retarget_grip(source_grip.at, source_grip.fwd, source_grip.up,
                                            hand_target.at, hand_target.fwd, hand_target.up);
            placed_hand = aff_mul(grip_delta, *source_hand);
        }
        aff support_delta, support_chain[5];
        vrik_grip_pose support_target;
        const aff *support_source=left_wrist>=0 ? &pal->orig[left_wrist] :
                                  g_vk.have_h[0] ? &g_vk.SH[0] : NULL;
        int place_support = 0;
        if (target_valid && held_owner == 1 && support_source && (g_vk.slide_active || g_vk.contact_active)) {
            vrik_grip_pose native;
            if (vrik_wrist_frame_from(0, *support_source, native.at, native.fwd, native.up)) {
                aff arm_from_view = aff_mul(arm_from_room, g_vk.held.room_from_view);
                vrik_grip_pose snapped = vrik_grip_in(arm_from_view, g_vk.slide_active?&g_vk.slide_hand:&g_vk.contact_hand);
                support_target=snapped;
                support_delta = vrik_retarget_grip(native.at, native.fwd, native.up,
                                                   snapped.at, snapped.fwd, snapped.up);
                place_support = 1;
            }
        } else if (target_valid && held_owner == 1 && support_source && g_vk.support_pose.locked && g_vk.weap[7] > .5f &&
            ((unsigned)g_vk.weap[5] & VRIK_BTN_L_TRIG) && g_vk.support_local_owner == 1 &&
            g_vk.support_local_at > 0) {
            vrik_grip_pose native;
            if (vrik_wrist_frame_from(0, *support_source, native.at, native.fwd, native.up)) {
                aff body_from_view=aff_mul(arm_from_room,g_vk.held.room_from_view);
                vrik_grip_pose supported = vrik_support_in_body(body_from_view,&target,&g_vk.support_local);
                support_target=supported;
                support_delta = vrik_retarget_grip(native.at, native.fwd, native.up,
                                                   supported.at, supported.fwd, supported.up);
                place_support = 1;
                g_vk.support_at = g_vk.held.at;
            }
        }
        int connected_support=place_support && vrik_support_arm(pal,support_source,&support_target,support_chain);
        pal->support_connected=connected_support;
        aff support_from_hand = aff_id(), supported_hand = aff_id();
        int keep_support_pose = place_support && left_wrist>=0 && g_vk.support_pose.locked && !g_vk.slide_active && !g_vk.contact_active;
        if (keep_support_pose) {
            vrik_grip_pose wrist;
            keep_support_pose = vrik_wrist_frame_from(0, pal->orig[left_wrist], wrist.at, wrist.fwd, wrist.up);
            if (keep_support_pose) {
                aff hand = vrik_grip_basis(&wrist);
                support_from_hand = aff_inv(hand);
                supported_hand = aff_mul(support_delta, hand);
            }
        }
        aff M_fng_l[128], M_fng_r[128];
        if (!place_support && g_vk.native_support && g_vk.gun_hand == 1) has_l_fng = 0;
        int left_owner = live_arm && vrik_joy_hold() && g_vk.weap[6] == 1.f;
        int left_grip = left_owner && g_vk.item_target_frame == pal->frame && g_vk.item_target_owner == 0;
        int mirror_grip = left_grip && g_vk.right_grip_fingers_valid && g_vk.right_grip_finger_rig == g_vk.rigv;
        const aff *left_rest = left_grip ? &g_vk.left_rest_hand : NULL;
        const aff *right_rest = NULL;
        if (left_owner) {
            if (right_wrist >= 0) right_rest = &pal->orig[right_wrist];
            else if (g_vk.right_rest_valid) right_rest = &g_vk.right_rest_hand;
        }
        if (live_arm) {
            if (vrik_joy_hold()) vrik_capture_right_fingers(pal, o);
            if (has_r_fng || right_rest) vrik_finger_deltas(1, pal, o, right_rest, M_fng_r);
        }
        if ((live_arm || place_support) && (has_l_fng || left_rest))
            vrik_finger_deltas(0, pal, o, left_rest, M_fng_l);
        if (live_arm) {
            if (has_l_fng) vrik_capture_hand_shape(0,pal,o,M_fng_l);
            if (has_r_fng) vrik_capture_hand_shape(1,pal,o,M_fng_r);
        }
        vrik_support_shape *support_shape=NULL;
        vrik_support_shape *holding_shape=NULL;
        if(place_hand && held_owner==1 && g_vk.hand_shape[1].ready) {
            holding_shape=vrik_consumer_shape(g_vk.holding_pose.shapes,g_vk.held.epoch,++g_vk.holding_pose.clock,pal);
            holding_shape->bones=pal->nb;
        }
        if (keep_support_pose) {
            support_shape=vrik_support_shape_for(pal);
            if (!support_shape->bones) {
                for (unsigned k=0;k<pal->nb;k++) {
                    aff original=has_l_fng ? aff_mul(M_fng_l[k],pal->orig[k]) : pal->orig[k];
                    if(vrik_is_bone(original.m)) {
                        support_shape->in_hand[k]=aff_mul(support_from_hand,original);
                        support_shape->valid[k]=1;
                    }
                }
                support_shape->bones=pal->nb;
            }
        }
        int k1 = -1, k2 = -1;
        for (uint32_t k = 0; k < pal->nb; k++) {
            int nm = vrik_pal_name(pal,k), s = vrik_seg[nm];
            aff *dst = (aff *)(pal->P + (size_t)k * 48);
            int hold_bone = hold_arm && vrik_held_bone(held_owner, nm, s);
            int support_bone=place_support && vrik_held_bone(0,nm,s);
            if (!live_arm && !hold_bone && !support_bone) continue;
            if (connected_support && nm==1503) *dst=aff_mul(support_chain[2],pal->orig[k]);
            else if (connected_support && nm==1504) *dst=aff_mul(support_chain[3],pal->orig[k]);
            else if (connected_support && (nm==1505 || nm==1678 || nm==1680 || nm==1682))
                *dst=aff_mul(support_chain[4],pal->orig[k]);
            else if (connected_support && (s==1 || s==2)) *dst=aff_mul(support_chain[s-1],pal->orig[k]);
            else if (place_support && s == 3) {
                aff original = has_l_fng ? aff_mul(M_fng_l[k], pal->orig[k]) : pal->orig[k];
                if(support_shape && !support_shape->valid[k] && vrik_is_bone(original.m)) {
                    support_shape->in_hand[k]=aff_mul(support_from_hand,original);
                    support_shape->valid[k]=1;
                }
                *dst=support_shape && support_shape->valid[k] ?
                     aff_mul(supported_hand,support_shape->in_hand[k]) : aff_mul(support_delta,original);
            }
            else if (!live_arm) *dst = pal->orig[k];
            else if (nm == 1503) *dst = aff_mul(g_vk.D_w0[0], pal->orig[k]); // l_Wrist_0_JNT (30% forearm roll)
            else if (nm == 1504) *dst = aff_mul(g_vk.D_w1[0], pal->orig[k]); // l_Wrist_1_JNT (60% forearm roll)
            else if (nm == 1505 || nm == 1678 || nm == 1680 || nm == 1682)
                                 *dst = aff_mul(g_vk.D_w2[0], pal->orig[k]); // l_Wrist_2_JNT + wrist_A/B/C_mscl
            else if (nm == 1974) *dst = aff_mul(g_vk.D_w0[1], pal->orig[k]); // r_Wrist_0_JNT (30% forearm roll)
            else if (nm == 1975) *dst = aff_mul(g_vk.D_w1[1], pal->orig[k]); // r_Wrist_1_JNT (60% forearm roll)
            else if (nm == 1976 || nm == 2148 || nm == 2149 || nm == 2150)
                                 *dst = aff_mul(g_vk.D_w2[1], pal->orig[k]); // r_Wrist_2_JNT + wrist_A/B/C_mscl
            else if (s == 3 && mirror_grip && vrik_left_grip_bone(nm, g_vk.posed_left_hand, dst)) {
                // The held hand uses the reflected authored trigger grip.
            }
            else if (s == 3 && left_rest && vrik_grip_digit(0, nm) >= 0)
                *dst = aff_mul(g_vk.D[3], aff_mul(M_fng_l[k], *left_rest));
            else if (s == 6 && right_rest && vrik_grip_digit(1, nm) >= 0)
                *dst = aff_mul(g_vk.D[6], aff_mul(M_fng_r[k], *right_rest));
            else if (s == 3 && has_l_fng) *dst = aff_mul(g_vk.D[3], aff_mul(M_fng_l[k], pal->orig[k]));
            else if (s == 6 && has_r_fng) *dst = aff_mul(g_vk.D[6], aff_mul(M_fng_r[k], pal->orig[k]));
            else *dst = (s > 0) ? aff_mul(g_vk.D[s], pal->orig[k]) : pal->orig[k];

            if (hold_bone) {
                __typeof__(g_vk.held.arm[0]) *bone = &g_vk.held.arm[nm];
                aff world_bone, shown;
                const aff *live = NULL;
                int at_wrist = s != (held_owner ? 4 : 1) && s != (held_owner ? 5 : 2);
                int cached = target_valid && bone->pose.live_at > 0 && bone->pose.epoch == g_vk.held.epoch;
                int rigid_grip = held_owner == 1 && wrist_tracked && at_wrist && (place_hand || cached);
                if (place_hand && at_wrist) {
                    aff posed;
                    int mirrored = held_owner == 0 && g_vk.right_grip_finger_rig == pal->rig &&
                                   vrik_left_grip_bone(nm, placed_hand, &posed);
                    if (!mirrored) {
                        aff original = pal->orig[k];
                        if (live_arm && s == 6 && has_r_fng) original = aff_mul(M_fng_r[k], original);
                        else if (live_arm && s == 3 && has_l_fng) original = aff_mul(M_fng_l[k], original);
                        if (holding_shape) {
                            if (!holding_shape->valid[k]) {
                                holding_shape->in_hand[k] = aff_mul(aff_inv(vrik_grip_basis(&source_grip)),original);
                                holding_shape->valid[k] = 1;
                            }
                            aff target_basis = aff_mul(grip_delta,vrik_grip_basis(&source_grip));
                            posed = aff_mul(target_basis,holding_shape->in_hand[k]);
                            int digit = vrik_grip_digit(1,nm);
                            int index_bone=-1;
                            for(unsigned j=0;j<pal->nb;j++)if(vrik_pal_name(pal,j)==VRIK_RIGHTHANDINDEX1)index_bone=(int)j;
                            if (digit >= 0 && digit < 6 && ((unsigned)g_vk.weap[5] & VRIK_BTN_R_TRIG) &&
                                index_bone>=0 && holding_shape->valid[index_bone]) {
                                float pivot[3],axis[3];
                                aff index = aff_mul(target_basis,holding_shape->in_hand[index_bone]);
                                aff_pt(index.m,vrik_bindpos(g_vk.rigv,VRIK_RIGHTHANDINDEX1),pivot);
                                for (int i=0;i<3;i++) axis[i]=target_basis.m[4*i+1];
                                posed=aff_mul(aff_rot(axis,.12f,pivot),posed);
                            }
                        } else posed = aff_mul(grip_delta, original);
                    }
                    world_bone = aff_mul(room_from_arm, posed);
                    live = &world_bone;
                } else if (rigid_grip) {
                    world_bone = aff_mul(room_grip, bone->in_grip);
                    live = &world_bone;
                } else if (live_grip) {
                    world_bone = aff_mul(room_from_arm, *dst);
                    live = &world_bone;
                } else if (cached && s != (held_owner ? 4 : 1)) {
                    world_bone = aff_mul(room_grip, bone->in_grip);
                    live = &world_bone;
                }
                if (live && target_valid && (live_grip || (place_hand && at_wrist)))
                    bone->in_grip = aff_mul(aff_inv(room_grip), *live);
                if (held_owner == 1 && at_wrist && target_valid && live)
                    *dst = aff_mul(arm_from_room, *live);
                else if (held_owner != 1 && vrik_held_pose(&bone->pose, g_vk.held.room_from_view, pal->frame, g_vk.held.epoch,
                                   g_vk.held.at, wrist_tracked, rigid_grip, live, &shown))
                    *dst = aff_mul(arm_from_room, shown);
            }
            if (s > 0 || hold_bone) {
                if (k1 < 0) k1 = (int)k;
                k2 = (int)k;
                if (s > 0) vrik_record_known(&pal->orig[k], dst, s);
            }
        }
        if (k1 < 0 && !live_arm) return;
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
    vrik_weapon_trace(pal, dist_body);
    vrik_item_grip *item = held_owner >= 0 ? vrik_item_slot(pal, 0) : NULL;
    int known_item = item && (item->samples >= 3 || (item->drawn.live_at > 0 && item->drawn.epoch == g_vk.held.epoch));
    if (!pal->asset && !known_item && dist_body < 0.05f && pal->nb <= 64) {
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
    // The weapon and mounted parts share the same rendered grip target.
    if (!vrik_weapon() || (!pal->asset && !pal->magazine && !pal->receiver && !known_item && dist_body <= .20f) || pal->nb > 128) return;
    vrik_asset_latch(pal);
    aff o2v = aff_mul(pal->view, pal->obj);
    aff delta;
    vrik_grip_pose current_source, current_support;
    const vrik_grip_pose *source = NULL, *support = NULL;
    int live_item = 0;
    if (vrik_joy_hold()) {
        if (!item) item = vrik_item_slot(pal, 0);
        int candidate = vrik_item_candidate(pal, o2v);
        if (pal->asset && g_vk.capture_body) candidate = 1;
        aff item_from_view = aff_inv(o2v);
        if (candidate) {
            if (!item) item = vrik_item_slot(pal, 1);
            if (item) vrik_learn_item(item, pal->frame, pal->receiver ? 1 : candidate, item_from_view);
        }
        int native_grip = held_owner < 0 && g_vk.item_target_valid && g_vk.item_target_owner == g_vk.gun_hand &&
                          CACurrentMediaTime() - g_vk.item_target_at <= .20;
        vrik_grip_pose target;
        if (vrik_draw_grip(held_owner, live_grip || native_grip, &target)) {
            if (held_owner == 1 && vrik_latch_weapon_frame() &&
                (candidate || known_item || pal->asset || pal->receiver || pal->magazine)) {
                aff item_from_world = aff_inv(pal->obj);
                current_source = vrik_grip_in(item_from_world, &g_vk.weapon_frame.native_world);
                source = &current_source;
                if (item) item->grip = current_source;
                if (g_vk.weapon_frame.support_valid) {
                    current_support = vrik_grip_in(item_from_world, &g_vk.weapon_frame.support_world);
                    support = &current_support;
                }
                aff posed_world = aff_mul(g_vk.weapon_frame.world_delta,pal->obj);
                delta = g_vk.weapon_frame.asset
                    ? aff_mul(aff_inv(o2v),aff_mul(g_vk.weapon_frame.view_from_world,posed_world))
                    : aff_mul(item_from_world,posed_world);
                live_item = 1;
            } else if (candidate == 1 || (candidate == 2 && pal->receiver)) {
                // The current authored palm anchors the actual mesh through
                // draw/ready animations. A cached equip pose must not override
                // a palm and receiver captured together in the current frame.
                current_source = vrik_grip_in(item_from_view, &g_vk.native_item_grip);
                source = &current_source;
                if (item) item->grip = current_source;
                if (g_vk.item_support_valid) {
                    current_support = vrik_grip_in(item_from_view, &g_vk.native_item_support);
                    support = &current_support;
                    if (item) { item->support = current_support; item->support_valid = 1; }
                }
            } else if (item && item->samples >= 3) {
                source = &item->grip;
                if (item->support_valid) support = &item->support;
            }
            if (source && !live_item) {
                delta = vrik_item_delta(source, o2v, &target);
                live_item = 1;
            }
        }
    }
    if (!live_item && held_owner != 1 && (held_owner < 0 || live_grip) && g_vk.weapon_solved && live_arm &&
        v3len((float[3]){o2v.m[3], o2v.m[7], o2v.m[11]}) < .95f &&
        (!vrik_joy_hold() || (g_vk.weapon_origin_valid && vrik_distance(
            (float[3]){pal->obj.m[3], pal->obj.m[7], pal->obj.m[11]}, g_vk.weapon_grip_world) <= .18f))) {
        aff dw = aff_mul(g_vk.obj, aff_mul(g_vk.D_gun, aff_inv(g_vk.obj)));
        delta = aff_mul(aff_inv(pal->obj), aff_mul(dw, pal->obj));
        live_item = 1;
    }
    if (held_owner == 1 && item && live_item) {
        // Keep a palette key for recognition. Its pose always comes from the hand.
        item->drawn.epoch = g_vk.held.epoch;
        item->drawn.frame = pal->frame;
        item->drawn.live_at = g_vk.held.at;
    } else if (held_owner >= 0 && held_owner != 1 && item && (live_item || known_item)) {
        aff room_from_item = aff_mul(g_vk.held.room_from_view, o2v);
        aff live = live_item ? aff_mul(room_from_item, delta) : aff_id(), shown;
        if (!vrik_held_pose(&item->drawn, g_vk.held.room_from_view, pal->frame, g_vk.held.epoch,
                            g_vk.held.at, wrist_tracked, 0,
                            live_item ? &live : NULL, &shown)) return;
        delta = aff_mul(aff_inv(room_from_item), shown);
    } else if (!live_item) {
        // An identified first-person magazine still ejects if the receiver
        // used its native pose on this pass.
        if ((!pal->asset && !pal->magazine && !pal->receiver) || held_owner < 0) return;
        delta = aff_id();
        if (!item && (pal->magazine == VRIK_SATARA_SHELL || pal->asset)) item = vrik_item_slot(pal, 1);
    }
    uint32_t bones = pal->nb;
    // Output storage is per consumer. A later overlapping draw must not change
    // how many of this draw's matrices are transformed (or its visible shape).
    if (!bones) return;
    if (held_owner >= 0 && live_item && source)
        vrik_note_drawn_grip(pal, item, o2v, aff_mul(g_vk.held.room_from_view, aff_mul(o2v, delta)), source, support);
    if ((pal->magazine || (pal->asset && pal->asset->ammo)) && live_item) vrik_note_reload_targets(pal, o2v, delta);
    int slide = -1;
    if (pal->receiver && held_owner >= 0) {
        const __typeof__(vrik_receivers[0]) *receiver = &vrik_receivers[pal->receiver - VRIK_RECEIVER];
        if (receiver->slide < bones) {
            slide = (int)receiver->slide;
            int key = pal->receiver == VRIK_RECEIVER + 1 ? VRIK_RECEIVER : pal->receiver;
            aff room_from_item = aff_mul(g_vk.held.room_from_view, aff_mul(o2v, delta));
            vrik_note_rack(aff_mul(room_from_item, vrik_manual_slide(pal,item,slide)), receiver->joint, key);
        }
    }
    if (pal->asset && held_owner >= 0 && live_item) {
        const vrik_asset_profile *asset=pal->asset;
        aff room_item=aff_mul(g_vk.held.room_from_view,aff_mul(o2v,delta));
        if (asset->slide>=0 && asset->slide<bones) {
            vrik_note_rack(aff_mul(room_item,vrik_manual_slide(pal,item,asset->slide)),asset->slide_at,VRIK_ASSET_BASE+asset->asset);
            g_vk.rack_auto=!(asset->kind&8);
        }
        if (asset->cylinder>=0 && asset->cylinder<bones) {
            aff cylinder=vrik_cylinder_pose(pal,pal->orig[asset->cylinder],asset->cylinder);
            aff_pt(aff_mul(room_item,cylinder).m,asset->cylinder_at,g_vk.well_room);
            g_vk.reload_mesh=VRIK_CATALOG_AMMO;g_vk.reload_owner=held_owner;g_vk.reload_at=g_vk.held.at;
            g_vk.reload_frame=pal->frame;g_vk.reload_priority=2;
        }
    }
    for (uint32_t k = 0; k < bones; k++) {
        aff *dst = (aff *)(pal->P + (size_t)k * 48);
        aff native = vrik_cylinder_pose(pal,vrik_manual_slide(pal,item,k),k);
        aff bone = aff_mul(delta, native);
        int ammunition=pal->magazine || (pal->asset && (pal->asset->ammo & (UINT64_C(1)<<k)));
        *dst = ammunition ? vrik_magazine_pose(pal, item, bone,k) : bone;
    }
    pal->mod_k1 = 0;
    pal->mod_k2 = (int)bones - 1;
    pal->mod1 = ((const aff *)pal->P)[0];
    pal->mod2 = ((const aff *)pal->P)[bones - 1];
    pal->applied = 1;
}

static void vrik_apply_pal(vrik_pal *pal) {
    vrik_apply_pal_pose(pal);
    vrik_publish_palette(pal);
}

#include "vrik_capture.inc"

static int vrik_capture_palette(vrik_pal *pal, const uint8_t *source, size_t available,
                                 uint64_t gpu, size_t offset, unsigned frame) {
    uint32_t cap = (uint32_t)MIN(available / 48, (size_t)128);
    if (!cap) return 0;
    int same = pal->source == source && pal->frame == frame && pal->cap_b == cap &&
               !memcmp(pal->orig, source, (size_t)cap * 48);
    if (!same) {
        uint32_t strict = 0, count = 0;
        while (strict < cap && vrik_is_rot((const float *)(source + (size_t)strict * 48))) strict++;
        while (count < cap && vrik_is_pal_bone(source, count, available)) count++;
        count = MAX(count, strict);
        if (!count) return 0;
        pal->cap_b = cap; pal->max_b = count; pal->strict_rot = strict ? strict : count;
        memcpy(pal->orig, source, (size_t)cap * 48);
        memcpy(pal->posed, source, (size_t)cap * 48);
        pal->applied = 0; pal->mod_k1 = pal->mod_k2 = -1;
        pal->capture_id = ++g_pose_capture_id;
    }
    pal->P = (uint8_t *)pal->posed;
    pal->source = source; pal->source_gpu = gpu; pal->source_offset = offset;
    pal->source_bytes = available; pal->frame = frame;
    return 1;
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

static void vrik_route_note(VXEncVM *vm,NSUInteger count,NSUInteger bi) {
    if(!vrik_replay_enabled())return;
    NSArray *skin=objc_getAssociatedObject(vm->pipe,kISD);
    unsigned span=[objc_getAssociatedObject(vm->pipe,kSkinSpan) unsignedIntValue];
    int melee=0;
    for(unsigned i=vrik_asset_first(count);i<VRIK_ASSET_COUNT && vrik_assets[i].count==count;i++)
        if(vrik_assets[i].kind&64) {melee=1;break;}
    if(!melee && !(vm->vp_fg && skin && !span))return;
    NSString *hash=objc_getAssociatedObject(vm->pipe,kHash) ?: @"unknown";
    static NSMutableSet *seen;static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
    NSString *key=[NSString stringWithFormat:@"%@:%lu:%d",hash,count,vm->vp_fg];
    pthread_mutex_lock(&lock);
    if(!seen)seen=[NSMutableSet set];
    int fresh=seen.count<128 && ![seen containsObject:key];
    if(fresh)[seen addObject:key];
    pthread_mutex_unlock(&lock);
    if(!fresh)return;
    uint32_t isd[4]={0};float transform[12]={0};
    int valid=skin && vrik_instance(vm,skin,bi,isd,transform);
    float scales[3]={0};for(int r=0;r<3;r++)for(int c=0;c<3;c++)scales[r]+=transform[r*4+c]*transform[r*4+c];
    vxmac_log("VRIK route: shader=%s indices=%lu foreground=%d melee_count=%d skin=%d stride=%u span=%u instance=%d rigid_layout=%d scales=%.5f/%.5f/%.5f",
              hash.UTF8String,(unsigned long)count,vm->vp_fg,melee,!!skin,isd[1],span,valid,
              objc_getAssociatedObject(vm->pipe,kRigidInstance)!=nil,scales[0],scales[1],scales[2]);
    // Keep only a few private shader contracts for offline inspection. No
    // vertex/index data or complete allocation arenas are exported.
    NSData *library=objc_getAssociatedObject(vm->pipe,kLibData);
    static unsigned saved;static NSUInteger bytes;
    pthread_mutex_lock(&lock);
    int keep=library.length && library.length<=2*1024*1024 && saved<16 && bytes+library.length<=8*1024*1024;
    if(keep){saved++;bytes+=library.length;}
    pthread_mutex_unlock(&lock);
    if(keep)dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
        NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSString *dir=[docs stringByAppendingPathComponent:@"vxvs_routes"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [library writeToFile:[dir stringByAppendingPathComponent:[hash stringByAppendingString:@".metallib"]] atomically:YES];
    }});
}

static int vrik_rigid_transform(id e,VXEncVM *vm,NSUInteger count,NSUInteger bi,id ib,NSUInteger io,MTLIndexType it) {
    NSArray *layout=objc_getAssociatedObject(vm->pipe,kRigidInstance);
    if(!layout || !vm->vp_fg || !vrik_joy_hold())return 0;
    NSUInteger binding=[layout[0] unsignedIntegerValue],offset=[layout[1] unsignedIntegerValue];
    NSUInteger stride=[layout[2] unsignedIntegerValue],step=[layout[3] unsignedIntegerValue],rate=[layout[4] unsignedIntegerValue];
    int dynamic=stride==MTLBufferLayoutStrideDynamic;if(binding>=31 || binding==2)return 0;
    if(dynamic)stride=vm->vst[binding];
    if(step!=MTLVertexStepFunctionPerInstance && step!=MTLVertexStepFunctionConstant)return 0;
    NSUInteger extent=MAX(offset+48,[layout[5] unsignedIntegerValue]);
    if(step==MTLVertexStepFunctionConstant)stride=MAX(stride,extent);
    if(!stride || extent>stride)return 0;
    NSUInteger element=step==MTLVertexStepFunctionConstant?0:bi/(rate?rate:1);
    if(element>=256*1024/stride)return 0;
    size_t bytes=(element+1)*stride;
    NSData *data=vm->vbytes[@(binding)];const uint8_t *source=data.bytes;size_t size=data.length;
    id<MTLBuffer> vertex=vm->vbuf[binding];
    if(!source && vertex && vertex.storageMode==MTLStorageModeShared && vm->voff[binding]<vertex.length) {
        source=(const uint8_t *)vertex.contents+vm->voff[binding];size=vertex.length-vm->voff[binding];
    }
    const uint8_t *top=vm->bytes.bytes;size_t top_size=vm->bytes.length;
    if(!top && vm->original && vm->original.storageMode==MTLStorageModeShared && vm->offset<vm->original.length) {
        top=(const uint8_t *)vm->original.contents+vm->offset;top_size=vm->original.length-vm->offset;
    }
    if(!source || bytes>size || !top || top_size<8)return 0;
    const uint8_t *view=NULL;uint64_t address,available,base;
    pthread_mutex_lock(&g_brl);
    memcpy(&address,top,8);const uint8_t *descriptor=buf_at(address,&available,&base);
    if(descriptor && available>=32) {
        memcpy(&address,descriptor+24,8);const uint8_t *v=buf_at(address,&available,&base);
        if(v && available>=640)view=v;
    }
    pthread_mutex_unlock(&g_brl);
    aff object;if(!view || !vrik_object((const float *)(source+element*stride+offset),view,&object))return 0;
    pthread_mutex_lock(&g_vk_l);
    unsigned frame=atomic_load(&g_frame);
    int attached=0;
    if(g_vk.held.owner==1 && g_vk.capture_frame==frame && vrik_latch_weapon_frame()) {
        int part=vrik_magazine_mesh(ib,io,count,it,vm->vp_fg);
        // A known attachment, or an exact instance shared with an identified
        // receiver, is necessary. Nearby scenery never inherits the gun pose.
        attached=part>=VRIK_ASSET_BASE && !(vrik_assets[part-VRIK_ASSET_BASE].kind&128);
        if(attached && (vrik_assets[part-VRIK_ASSET_BASE].kind&64)) {
            // Rigid melee LODs have no palette; bind their object root using
            // the same authored-hand relation as a one-bone melee model.
            vrik_asset_profile asset=vrik_assets[part-VRIK_ASSET_BASE];asset.root=0;
            vrik_pal item={.asset=&asset,.nb=1,.obj=object,.view=g_vk.vcam,.frame=frame,.count=count};
            item.orig[0]=aff_id();vrik_asset_latch(&item);
        }
        for(int i=0;!attached && i<g_vk.npals;i++) {
            const vrik_pal *pal=&g_vk.pals[i];
            if(pal->frame==frame && (pal->receiver || (pal->asset && (pal->asset->kind&1))) &&
               !memcmp(&object,&pal->obj,sizeof object))attached=1;
        }
    }
    aff posed=attached?aff_mul(g_vk.weapon_frame.world_delta,object):object;
    pthread_mutex_unlock(&g_vk_l);
    if(!attached)return 0;
    float encoded[12];int32_t camera[3];memcpy(camera,view+608,12);
    for(int r=0;r<3;r++) {
        for(int c=0;c<3;c++)encoded[r*4+c]=posed.m[r*4+c];
        double position=round((double)posed.m[r*4+3]*131072.0)+(double)camera[r];
        if(!isfinite(position) || position<INT32_MIN || position>INT32_MAX)return 0;
        int32_t fixed=(int32_t)position;memcpy(encoded+r*4+3,&fixed,4);
    }
    id<MTLBuffer> copy=[[e device] newBufferWithBytes:source length:bytes options:MTLResourceStorageModeShared];
    if(!copy || !vxmtl_retain_for_encoder(e,copy))return 0;
    memcpy((uint8_t *)copy.contents+element*stride+offset,encoded,48);
    if(dynamic)o_svbs(e,@selector(setVertexBuffer:offset:attributeStride:atIndex:),copy,0,vm->vst[binding],binding);
    else o_svb2(e,@selector(setVertexBuffer:offset:atIndex:),copy,0,binding);
    vm->pose_bound=1;vm->pose_instance=binding;vm->pose_instance_dynamic=dynamic;vm->pose_rebase=0;
    return 1;
}

static void vrik_apply(id e, NSUInteger count, NSUInteger instances, NSUInteger bi, id ib, NSUInteger io, MTLIndexType it) {
    VXEncVM *vm = objc_getAssociatedObject(e, kEncVM);
    if (vm && vm->pose_bound) {
        if (vm->original) o_svb2(e, @selector(setVertexBuffer:offset:atIndex:), vm->original, vm->offset, 2);
        else if (vm->bytes) o_svy2(e, @selector(setVertexBytes:length:atIndex:), vm->bytes.bytes, vm->bytes.length, 2);
        NSUInteger binding = vm->pose_instance;
        NSData *data = vm->vbytes[@(binding)];
        if (vm->pose_instance_dynamic) {
            if (data) o_svys(e, @selector(setVertexBytes:length:attributeStride:atIndex:), data.bytes, data.length, vm->vst[binding], binding);
            else o_svbs(e, @selector(setVertexBuffer:offset:attributeStride:atIndex:), vm->vbuf[binding], vm->voff[binding], vm->vst[binding], binding);
        } else if (data) o_svy2(e, @selector(setVertexBytes:length:atIndex:), data.bytes, data.length, binding);
        else o_svb2(e, @selector(setVertexBuffer:offset:atIndex:), vm->vbuf[binding], vm->voff[binding], binding);
        vm->pose_bound = vm->pose_rebase = 0;
    }
    if (!vrik_on() || !vm || !vm->pipe) return;
    vrik_route_note(vm,count,bi);
    if (instances != 1) { atomic_fetch_add(&g_pose_skipped, 1); return; }
    int outside_part=0;
    if(!vm->vp_fg) {
        // The actual crowbar colour/depth draws use the full scene depth
        // range. Viewport compression is not a first-person identity.
        int candidate=0;
        for(unsigned i=vrik_asset_first(count);i<VRIK_ASSET_COUNT && vrik_assets[i].count==count;i++)
            if(vrik_assets[i].kind&(1|32|64|128)){candidate=1;break;}
        if(!candidate)return;
    }
    NSArray *isd_i = objc_getAssociatedObject(vm->pipe, kISD);
    if(isd_i && !objc_getAssociatedObject(vm->pipe,kSkinSpan) && !objc_getAssociatedObject(vm->pipe,kSkinByteInputs) &&
       vrik_rigid_transform(e,vm,count,bi,ib,io,it))return;
    if (!isd_i) {
        if(vrik_rigid_transform(e,vm,count,bi,ib,io,it))return;
        if (vrik_replay_enabled()) {
            pthread_mutex_lock(&g_vk_l);
            int part=vrik_magazine_mesh(ib,io,count,it,vm->vp_fg);
            static NSMutableSet *seen;
            if (!seen) seen=[NSMutableSet set];
            NSString *key=[NSString stringWithFormat:@"%@:%lu",objc_getAssociatedObject(vm->pipe,kHash),(unsigned long)count];
            if (seen.count<96 && ![seen containsObject:key]) {
                [seen addObject:key];
                vxmac_log("VRIK rigid draw: shader=%s indices=%lu recognized=%d",
                          [objc_getAssociatedObject(vm->pipe,kHash) UTF8String] ?: "-",(unsigned long)count,part);
            }
            pthread_mutex_unlock(&g_vk_l);
        }
        return;
    }
    uint32_t isd[4]; float itf[12];
    if (!vrik_instance(vm, isd_i, bi, isd, itf)) return;
    if(isd[1]!=48) {
        // Single-joint/rigid material variants need no palette rebasing. Use
        // the reflected object transform only for an identified held part.
        vrik_rigid_transform(e,vm,count,bi,ib,io,it);
        return;
    }
    const uint8_t *tl = NULL; size_t n = 0;
    if (vm->bytes) { tl = vm->bytes.bytes; n = vm->bytes.length; }
    else if (vm->original && vm->original.storageMode == MTLStorageModeShared && vm->offset < vm->original.length) { tl = (const uint8_t *)vm->original.contents + vm->offset; n = vm->original.length - vm->offset; }
    if (!tl || n < 56) return;
    pthread_mutex_lock(&g_brl);
    uint64_t ta, av, base, ba = 0; memcpy(&ta, tl + 48, 8);
    const uint8_t *t = buf_at(ta, &av, &base);
    size_t table_bytes = t ? MIN(av, (uint64_t)4096) : 0;
    const uint8_t *P = NULL, *bb = NULL, *viewc = NULL; size_t pav = 0;
    if (t && av >= 72) {
        memcpy(&ba, t + 48, 8); bb = buf_at(ba, &av, &base);
        if (bb && isd[0] < av) { P = bb + isd[0]; pav = av - isd[0]; }
    }
    { uint64_t da; memcpy(&da, tl, 8); const uint8_t *d = buf_at(da, &av, &base); if (d && av >= 32) { uint64_t ca; memcpy(&ca, d + 24, 8); const uint8_t *c = buf_at(ca, &av, &base); if (c && av >= 640) viewc = c; } }
    pthread_mutex_unlock(&g_brl);
    if (!P || !viewc || pav < 48) return;
    aff obj; if (!vrik_object(itf, viewc, &obj)) return;
    aff vcam = *(const aff *)(viewc + 384);
    if (!vrik_is_rot(vcam.m)) return;
    if(!vm->vp_fg) {
        aff local=aff_mul(vcam,obj);
        if(v3len((float[3]){local.m[3],local.m[7],local.m[11]})>2.f)return;
    }

    pthread_mutex_lock(&g_vk_l);
    if(!vm->vp_fg) {
        // Only read back an outside-depth identity after the instance has
        // passed the near-player source-space check above.
        outside_part=vrik_magazine_mesh(ib,io,count,it,0);
        if(outside_part<VRIK_ASSET_BASE || !vrik_equipment_allows(&vrik_assets[outside_part-VRIK_ASSET_BASE])) {
            pthread_mutex_unlock(&g_vk_l);return;
        }
    }
    unsigned seq = ++g_vk.call_seq;
    unsigned cur_frame = atomic_load(&g_frame);
    if (!g_vk.capture_started || g_vk.capture_frame != cur_frame) {
        // Never combine a new frame's arm with a wrist from a previous animation or loading screen.
        g_vk.capture_started = 1; g_vk.capture_frame = cur_frame; g_vk.capture_body = 0;g_vk.hands_started=0;
        memset(g_vk.have_af, 0, sizeof g_vk.have_af);
        memset(g_vk.have_h, 0, sizeof g_vk.have_h);
        g_vk.hand_ref_mask = 0;
        g_vk.weapon_frame.valid = 0;
        g_vk.nknown = 0;
        g_vk.held.owner=-1;
    }
    // A world/shadow pass cannot establish the headset's reference camera.
    // Known early consumers wait in private copies for this foreground solve.
    if(vm->vp_fg && !g_vk.hands_started && !g_vk.capture_body) {
        vrik_held_begin_frame(vcam);g_vk.hands_started=1;
    }

    // Geometry identity is part of the key: different meshes can share a
    // native palette address without sharing their cached recognition state.
    vrik_pal *pal = NULL;
    for (int i = 0; i < g_vk.npals; i++) {
        vrik_pal *candidate = &g_vk.pals[i];
        if (candidate->source == P && candidate->indices == (__bridge const void *)ib &&
            candidate->index_offset == io && candidate->count == count &&
            !memcmp(&candidate->obj, &obj, sizeof obj) && !memcmp(&candidate->view, &vcam, sizeof vcam)) {
            pal = candidate; break;
        }
    }
    if (!pal) {
        if (g_vk.npals < 128) pal = &g_vk.pals[g_vk.npals++];
        else {
            int oldest = 0;
            for (int i = 1; i < 128; i++) if (g_vk.pals[i].stamp < g_vk.pals[oldest].stamp) oldest = i;
            pal = &g_vk.pals[oldest];
        }
        memset(pal, 0, sizeof *pal); pal->L = -2;
    }
    if (!vrik_capture_palette(pal, P, pav, ba, isd[0], cur_frame)) {
        pthread_mutex_unlock(&g_vk_l); return;
    }
    pal->stamp = seq;
    pal->frame = cur_frame;
    pal->obj = obj;
    pal->view = vcam;
    pal->indices = (__bridge const void *)ib;
    pal->index_offset = io;
    pal->count = count;
    pal->needs_held_identity=!vm->vp_fg;
    int part = outside_part ? outside_part : vrik_joy_hold() ? vrik_magazine_mesh(ib, io, count, it,vm->vp_fg) : 0;
    const vrik_asset_profile *identified=part>=VRIK_ASSET_BASE?&vrik_assets[part-VRIK_ASSET_BASE]:NULL;
    pal->body_identity=identified && (identified->kind&128)?identified:NULL;
    pal->body_profile=pal->body_identity?vrik_body_select(pal,pal->body_identity):NULL;
    pal->asset = pal->body_identity?NULL:identified;
    pal->magazine = pal->asset ? ((pal->asset->kind & 2) ? VRIK_CATALOG_AMMO : 0) : part < VRIK_RECEIVER ? part : 0;
    pal->receiver = !identified && part >= VRIK_RECEIVER ? part : 0;

    // Identify using the guaranteed-unmodified pal->orig matrices
    const vrik_item_grip *known_weapon = g_vk.held.owner >= 0 ? vrik_item_slot(pal, 0) : NULL;
    int held_weapon = known_weapon && known_weapon->samples >= 3;
    int rigv = 0, L = pal->body_identity ? -2 : pal->asset || pal->magazine || pal->receiver || held_weapon ? -1 :
        vrik_identify((__bridge const void *)ib, io, count, isd[0], (const uint8_t *)pal->orig, pal->cap_b, pal->max_b, pal->strict_rot, &rigv);
    if(pal->body_profile && pal->body_profile->bones<=pal->cap_b) {
        if(vrik_named_skin_valid(pal)) {L=pal->body_profile->body_list;rigv=g_vk.capture_body?g_vk.rigv:g_vk.held.rig;}
        else L=-2;
    }
    if(pal->body_identity && L<0) {
        // Reserve this draw's private binding now. A later body draw can
        // resolve its named layout and publish into the unsubmitted copy.
        pal->L=-2;pal->nb=0;
        int bound=vrik_bind_palette(e,vm,tl,n,t,table_bytes,pal,isd_i,bi,
                                    vrik_consumer_span(vm,pal));
        vrik_binding_note(vm,pal,bi,bound);
        pthread_mutex_unlock(&g_vk_l);return;
    }

    int pose_changed = 0;
    if(L>=0 && !vm->vp_fg) {
        pal->L=L;pal->nb=pal->body_profile->bones;pal->rig=rigv;pal->applied=0;
    } else if (L >= 0) {
        uint32_t o = L<VRIK_NLISTS?vrik_list_off[L]:0;
        uint32_t nb=pal->body_profile?pal->body_profile->bones:vrik_list_off[L+1]-o;
        if (nb > 128) nb = 128;
        if (nb <= pal->cap_b) {
            if (pal->max_b < nb) pal->max_b = nb;
            aff o2v = aff_mul(vcam, obj);
            int near_cam = 0;
            for (uint32_t k = 0; k < nb; k++) {
                int nm = pal->body_profile?pal->body_profile->body_names[k]:vrik_list[o+k]; if (vrik_seg[nm] <= 0) continue;
                const float *c = vrik_bindpos(rigv, nm); if (!c) continue;
                float pt[3], pv[3]; aff_pt(pal->orig[k].m, c, pt); aff_pt(o2v.m, pt, pv);
                if (v3len(pv) < 1.0f) { near_cam = 1; break; }
            }
            float origin_delta[3] = { obj.m[3] - g_vk.obj.m[3], obj.m[7] - g_vk.obj.m[7], obj.m[11] - g_vk.obj.m[11] };
            int same_body = !g_vk.capture_body || (rigv == g_vk.rigv && v3len(origin_delta) < .04f &&
                            v3dot(obj.m, g_vk.obj.m) > .995f && v3dot(obj.m + 4, g_vk.obj.m + 4) > .995f);
            if (near_cam && same_body) {
                if (pal->L != L || pal->nb != nb) {
                    pal->L = L; pal->nb = nb;
                    pal->applied = 0;
                }
                pal->rig = rigv;
                aff canonical[128];
                aff body_from_pal = g_vk.capture_body ? aff_mul(aff_inv(g_vk.obj), obj) : aff_id();
                for (unsigned k = 0; k < nb; k++) canonical[k] = aff_mul(body_from_pal, pal->orig[k]);
                #define BONE(nm) ({ int _b = -1; for (uint32_t _k = 0; _k < nb; _k++) if (vrik_pal_name(pal,_k) == (nm)) { _b = (int)_k; break; } _b; })
                for (int side = 0; side < 2; side++) {
                    int bA = BONE(side ? VRIK_RIGHTARM : VRIK_LEFTARM);
                    if (bA < 0) bA = BONE(side ? VRIK_R_SHL_0_JNT : VRIK_L_SHL_0_JNT);
                    int bF = BONE(side ? VRIK_RIGHTFOREARM : VRIK_LEFTFOREARM);
                    int bH = BONE(side ? VRIK_RIGHTHAND : VRIK_LEFTHAND);
                    const float *cA = vrik_bindpos(rigv, side ? VRIK_RIGHTARM : VRIK_LEFTARM);
                    const float *cF = vrik_bindpos(rigv, side ? VRIK_RIGHTFOREARM : VRIK_LEFTFOREARM);
                    const float *cH = vrik_bindpos(rigv, side ? VRIK_RIGHTHAND : VRIK_LEFTHAND);
                    if (g_vk.held.owner >= 0 && bH >= 0 && cH && !(g_vk.hand_ref_mask & (1u << side)) &&
                        vrik_is_rot(canonical[bH].m)) {
                        float wrist[3], in_view[3];
                        aff_pt(canonical[bH].m, cH, wrist);
                        aff body_view = aff_mul(vcam, g_vk.capture_body ? g_vk.obj : obj);
                        aff_pt(body_view.m, wrist, in_view);
                        if (fabsf(wrist[0]) < .8f && wrist[2] > .7f && wrist[2] < 1.95f && v3len(in_view) < 1.15f) {
                            g_vk.hand_ref[side] = canonical[bH];
                            g_vk.hand_ref_mask |= 1u << side;
                            pose_changed = 1;
                        }
                    }
                    if (!g_vk.have_af[side] && bA >= 0 && bF >= 0 && cA && cF && cH) {
                        float S[3], eA[3], eF[3], W[3];
                        aff_pt(canonical[bA].m, cA, S);
                        aff_pt(canonical[bA].m, cF, eA);
                        aff_pt(canonical[bF].m, cF, eF);
                        aff_pt(canonical[bF].m, cH, W);
                        float de[3] = { eA[0]-eF[0], eA[1]-eF[1], eA[2]-eF[2] };
                        float da[3] = { eF[0]-S[0],  eF[1]-S[1],  eF[2]-S[2] };
                        float df[3] = { W[0]-eF[0],  W[1]-eF[1],  W[2]-eF[2] };
                        float la = v3len(da), lf = v3len(df);
                        int side_ok = fabsf(S[0]) < .45f;
                        if (side_ok && S[2] > 1.10f && S[2] < 1.70f && v3len(de) < 0.02f && la > 0.18f && la < 0.38f && lf > 0.18f && lf < 0.38f) {
                            g_vk.SA[side] = canonical[bA]; g_vk.SF[side] = canonical[bF];
                            g_vk.have_af[side] = 1; pose_changed = 1;
                            if (g_vk.have_h[side]) {
                                float wrist[3]; aff_pt(g_vk.SH[side].m, cH, wrist);
                                float seam[3] = { wrist[0] - W[0], wrist[1] - W[1], wrist[2] - W[2] };
                                if (v3len(seam) >= .02f) g_vk.have_h[side] = 0;
                            }
                        }
                    }
                    if (!g_vk.have_h[side] && bH >= 0 && cH && (g_vk.have_af[side] || bF >= 0)) {
                        float wF[3], wH[3];
                        aff_pt(g_vk.have_af[side] ? g_vk.SF[side].m : canonical[bF].m, cH, wF);
                        aff_pt(canonical[bH].m, cH, wH);
                        float dw[3] = { wF[0]-wH[0], wF[1]-wH[1], wF[2]-wH[2] };
                        if (v3len(dw) >= .02f && g_vk.have_af[side] && bF >= 0 && cF) {
                            // The hand draw can have the matching forearm pose even when the
                            // sleeve uses a different wrist transform. Keep the elbow seam intact.
                            float eA[3], eF[3];
                            aff_pt(g_vk.SA[side].m, cF, eA);
                            aff_pt(canonical[bF].m, cF, eF);
                            aff_pt(canonical[bF].m, cH, wF);
                            float de[3] = { eA[0]-eF[0], eA[1]-eF[1], eA[2]-eF[2] };
                            float seam[3] = { wF[0]-wH[0], wF[1]-wH[1], wF[2]-wH[2] };
                            if (v3len(de) < .02f && v3len(seam) < .02f) {
                                g_vk.SF[side] = canonical[bF];
                                memcpy(dw, seam, sizeof dw);
                            }
                        }
                        if (v3len(dw) < 0.02f) {
                            g_vk.SH[side] = canonical[bH];
                            g_vk.have_h[side] = 1; pose_changed = 1;
                        }
                    }
                }
                #undef BONE
                if (pose_changed && !g_vk.capture_body) {
                    g_vk.rigv = rigv; g_vk.obj = obj; g_vk.vcam = vcam;
                    g_vk.capture_body = 1;
                    if (g_vk.held.owner >= 0 && g_vk.held.rig != rigv) {
                        memset(g_vk.held.arm, 0, sizeof g_vk.held.arm);
                        g_vk.held.rig = rigv;
                    }
                }
            } else if (g_vk.held.owner >= 0 && !same_body && vrik_item_candidate(pal, o2v)) {
                // Distinct foreground items can resemble a short list of arm bones.
                // Let the authored grip association decide when this is a weapon.
                pal->L = -1; pal->nb = pal->strict_rot; pal->applied = 0;
            } else {
                pal->L = -2; pal->nb = 0;
            }
        }
    } else {
        pal->L = -1;
        pal->nb = pal->asset ? pal->asset->bones : pal->magazine ? 1 : pal->receiver ? vrik_receivers[pal->receiver - VRIK_RECEIVER].bones : pal->strict_rot;
    }

    unsigned asset_revision = g_vk.asset_grip.revision;
    if (pose_changed && ((g_vk.have_af[0] && g_vk.have_h[0]) || (g_vk.have_af[1] && g_vk.have_h[1]) ||
                         (vrik_joy_hold() && (g_vk.have_af[0] || g_vk.have_af[1] || g_vk.have_h[1] || g_vk.hand_ref_mask)))) {
        g_vk.solve_frame = cur_frame;
        g_vk.nknown = 0;
        vrik_solve_all();
        // Only revisit palettes observed in this frame. Old shared storage may already be reused.
        for (int i = 0; i < g_vk.npals; i++) {
            vrik_pal *p = &g_vk.pals[i];
            if(p->frame==cur_frame && p->body_identity)vrik_body_resolve(p);
            if (p->L >= 0 && p->frame == cur_frame) vrik_apply_pal(p);
        }
        for (int i = 0; i < g_vk.npals; i++) {
            vrik_pal *p = &g_vk.pals[i];
            if (p->L == -1 && p->frame == cur_frame) vrik_apply_pal(p);
        }
    } else if (!pal->applied && pal->L != -2 &&
               (g_vk.solve_frame == cur_frame || g_vk.held.owner >= 0 || (pal->L == -1 && vrik_joy_hold()))) {
        vrik_apply_pal(pal);
    }
    if (asset_revision != g_vk.asset_grip.revision) {
        for (int i=0;i<g_vk.npals;i++) {
            vrik_pal *seen=&g_vk.pals[i];
            if (seen->frame==cur_frame && seen!=pal && seen->L!=-2) vrik_apply_pal(seen);
        }
        vrik_apply_pal(pal);
    }
    if (pal->L != -2) {
        if (!pal->applied) atomic_fetch_add(&g_pose_unposed, 1);
        int reserve=pal->L>=0 || pal->body_identity || pal->asset;
        if(pal->applied || reserve) {
            int bound=vrik_bind_palette(e,vm,tl,n,t,table_bytes,pal,isd_i,bi,vrik_consumer_span(vm,pal));
            vrik_binding_note(vm,pal,bi,bound);
            if(bound)
                atomic_fetch_add(&g_pose_bound,1);
            else {
                atomic_fetch_add(&g_pose_skipped,1);
                if(pal->asset)vrik_rigid_transform(e,vm,count,bi,ib,io,it);
            }
        }
    }
    vrik_capture_replay();
    pthread_mutex_unlock(&g_vk_l);
}
