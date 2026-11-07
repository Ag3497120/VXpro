// libvxmtl: Metal for a macOS program on visionOS. The real Metal is re-exported; added here:
//   - MTLCopyAllDevicesWithObserver / MTLRemoveDeviceObserver (macOS only: GPU hot-plug): the devices, no
//     notifications (a Vision Pro's GPU never changes);
//   - the present hook (vxmac.h vxmtl_set_present_hook): every -[MTLCommandBuffer presentDrawable:...] of a
//     CAMetalLayer drawable goes to the host first (VX Mac Host copies the frame into its VR presenter's slot in the
//     same command buffer); CAMetalLayer.framebufferOnly is kept off while a hook is set so the drawable can be read;
//   - a CAMetalDisplayLink stand-in (visionOS: a layer in no window gets no display-link callbacks): links run on
//     their run loop at their preferred rate, the update's drawable taken from the layer, as Core Animation's would.
// The swizzles touch only these methods of the system's classes, in this process.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdatomic.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <pthread.h>
#include <TargetConditionals.h>
#include "vxmac.h"
#include "vxprof.h"
#include "vxframe_pace.h"
#include <time.h>

// ---- device observers --------------------------------------------------------------------------------------------
#if TARGET_OS_VISION   // (macOS has its own)
NS_RETURNS_RETAINED NSArray *MTLCopyAllDevicesWithObserver(id __autoreleasing *observer, void (^handler)(id, NSString *)) {
    (void)handler;
    if (observer) *observer = [NSObject new];
    NSArray *all = MTLCopyAllDevices();
    if (!all.count) { id d = MTLCreateSystemDefaultDevice(); all = d ? @[ d ] : @[]; }
    return all;
}
void MTLRemoveDeviceObserver(id observer) { (void)observer; }
#endif

// ---- present hook ------------------------------------------------------------------------------------------------
static vxmtl_present_hook g_hook;
static _Atomic unsigned long g_presents, g_drawable_presents, g_dropped, g_link_calls;
void vxmtl_set_present_hook(vxmtl_present_hook hook) { g_hook = hook; }

typedef void (*present_imp)(id, SEL, id);
typedef void (*present_t_imp)(id, SEL, id, CFTimeInterval);
// (the originals per hooked class: command buffers of different kinds have their own implementations)
typedef void (*commit_imp)(id, SEL);
typedef struct { Class cls; present_imp p; present_t_imp at, after; commit_imp commit; } orig_t;
static orig_t g_orig[16];
static int g_norig;
static const orig_t *orig_of(id self) {
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c))
        for (int i = 0; i < g_norig; i++) if (g_orig[i].cls == c) return &g_orig[i];
    return NULL;
}
// ---- frames in flight, as a real CAMetalLayer bounds them ---------------------------------------------------------
// A layer on screen hands out at most maximumDrawableCount drawables and takes one back only once it has been shown,
// after the GPU finished the frame: nextDrawable blocks, and that is what keeps a game a few frames ahead at most.
// Ours is in no window and its presents are dropped (the presenter shows the frame), so drawables came back at once
// and the program could run ahead of the GPU (h13: skinned characters garbled - per-frame bone buffers rewritten
// while the GPU still read them; right on the Mac, where the real layer throttled). Here: nextDrawable waits while
// maximumDrawableCount drawables are out; a drawable is back when the command buffer that presents it has completed
// (that buffer also carries the presenter's copy). A drawable never presented is taken back after 250 ms.
// VXMAC_INFLIGHT=0: off; =n: at most n (default 2).
static dispatch_semaphore_t g_inflight; static long g_inflight_n;
static _Atomic unsigned long g_inflight_waits, g_inflight_timeouts;
static void inflight_init(CAMetalLayer *l) {
    if (g_inflight) return;
    const char *e = getenv("VXMAC_INFLIGHT");
    // (2 by default, h25: 3 frames in flight left the shown frame ~140 ms old; 2 still bounds the bone buffers' reuse)
    long n = e && *e ? atol(e) : 2;
    if (n <= 0) { g_inflight_n = -1; return; }
    g_inflight_n = n; g_inflight = dispatch_semaphore_create(n);
    vxmac_log("Metal: frames in flight at most %ld (a drawable back when its command buffer completed)", n);
}
static const void *kOut = &kOut;
static void inflight_acquired(id drawable) {
    if (!g_inflight || !drawable) return;
    objc_setAssociatedObject(drawable, kOut, @1, OBJC_ASSOCIATION_RETAIN);
}
static void inflight_release_after(id cb, id drawable) {
    if (!g_inflight || !drawable || !objc_getAssociatedObject(drawable, kOut)) return;
    objc_setAssociatedObject(drawable, kOut, nil, OBJC_ASSOCIATION_RETAIN);
    dispatch_semaphore_t sem = g_inflight;
    [(id<MTLCommandBuffer>)cb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; dispatch_semaphore_signal(sem); }];
}
// (h26, the HUD question: the passes that draw into the drawable's texture each frame - how many, their load actions,
//  other attachments - logged whenever the frame's pattern changes (40 at most): is the UI its own pass over the
//  composited scene (then the scene can be taken before it and the HUD shown on its own)?)
static __weak id g_cur_tex;
static char g_dsig[256]; static int g_dsig_n, g_dsig_logged; static pthread_mutex_t g_dsig_l = PTHREAD_MUTEX_INITIALIZER;
static void drawable_pass_note(MTLRenderPassDescriptor *pd) {
    id t0 = pd.colorAttachments[0].texture;
    if (!t0 || t0 != g_cur_tex) return;
    int na = 0; for (int i = 1; i < 8; i++) if (pd.colorAttachments[i].texture) na++;
    MTLLoadAction la = pd.colorAttachments[0].loadAction;
    char e[16]; snprintf(e, sizeof e, "%c%s%s%s", la == MTLLoadActionLoad ? 'L' : la == MTLLoadActionClear ? 'C' : 'D', na ? "+" : "", pd.depthAttachment.texture ? "d" : "", " ");
    pthread_mutex_lock(&g_dsig_l);
    if (g_dsig_n < 40) { strlcat(g_dsig, e, sizeof g_dsig); g_dsig_n++; }
    pthread_mutex_unlock(&g_dsig_l);
}
static void drawable_frame_end(void) {
    static char last[256];
    pthread_mutex_lock(&g_dsig_l);
    if (strcmp(g_dsig, last) && g_dsig_logged < 40) { g_dsig_logged++; strlcpy(last, g_dsig, sizeof last);
        vxmac_log("Metal: passes into the drawable this frame (%d): %s(L load, C clear, D dont-care; + more targets, d depth) at present %lu", g_dsig_n, g_dsig, (unsigned long)g_presents); }
    g_dsig[0] = 0; g_dsig_n = 0;
    pthread_mutex_unlock(&g_dsig_l);
}
static void cam_frame_end(void);
static int hooked(id cb, id drawable) {
    g_presents++;
    vxprof_frame();   // (VXMAC_PASS_PROFILE: the sampled frames run present to present)
    cam_frame_end();
    drawable_frame_end();
    inflight_release_after(cb, drawable);
    if (!g_hook || ![drawable conformsToProtocol:@protocol(CAMetalDrawable)]) return 1;
    id<MTLTexture> t = ((id<CAMetalDrawable>)drawable).texture;
    g_drawable_presents++;
    if (vxprof_enabled) vxprof_ours(1);
    int keep = g_hook((__bridge void *)cb, (__bridge void *)t, (uint32_t)t.width, (uint32_t)t.height);
    if (vxprof_enabled) vxprof_ours(-1);
    if (!keep) g_dropped++;
    return keep;
}
// (in the background visionOS refuses GPU work: the game's command buffers fail with "not permitted" and its
// error handler stops the program (h10). Commits wait while the app is in the background: vxmtl_set_foreground)
static pthread_mutex_t g_fg_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_fg_cond = PTHREAD_COND_INITIALIZER;
static volatile int g_fg = 1;
static _Atomic unsigned long g_held_commits;
void vxmtl_set_foreground(int fg) {
    pthread_mutex_lock(&g_fg_lock); g_fg = fg; pthread_cond_broadcast(&g_fg_cond); pthread_mutex_unlock(&g_fg_lock);
    vxmac_log("Metal: %s", fg ? "foreground: commits go through" : "background: the program's commits wait");
    if (!fg) { void vxpipe_archive_flush(const char *); vxpipe_archive_flush("background"); }
}
// (GPU busy time of the program's command buffers - GPU-bound or CPU-bound: the union of their GPU intervals per
//  stats period, against the wall time; the compositor's own queue is left out)
static pthread_mutex_t g_gpu_lock = PTHREAD_MUTEX_INITIALIZER;
static double g_gpu_busy, g_gpu_last_end, g_gpu_since; static unsigned long g_gpu_cbs;
// (h55: the game's GPU time over the last 250 ms, for the pacing below: its command buffers' intervals, merged)
static double g_win_t[1024], g_win_d[1024]; static unsigned g_win_n;
static double win_busy(double now) {   // (with g_gpu_lock held: the share of the last 250 ms the game's work kept the GPU)
    double b = 0; unsigned n = g_win_n < 1024 ? g_win_n : 1024;
    for (unsigned i = 0; i < n; i++) { unsigned k = (g_win_n - 1 - i) % 1024; if (now - g_win_t[k] > 0.25) break; b += g_win_d[k]; }
    return b / 0.25;
}
static void gpu_account(id<MTLCommandBuffer> c) {
    double a = c.GPUStartTime, b = c.GPUEndTime;
    if (!(b > a)) return;
    pthread_mutex_lock(&g_gpu_lock);
    { double a2 = a < g_gpu_last_end ? g_gpu_last_end : a; if (b > a2) { g_win_t[g_win_n % 1024] = b; g_win_d[g_win_n % 1024] = b - a2; g_win_n++; } }
    if (a < g_gpu_last_end) a = g_gpu_last_end;
    if (b > a) g_gpu_busy += b - a;
    if (b > g_gpu_last_end) g_gpu_last_end = b;
    g_gpu_cbs++;
    pthread_mutex_unlock(&g_gpu_lock);
}
// (h55: the presenter keeps the display rate only if the GPU has room for its warp every 11 ms; the game alone kept it
//  96 % busy (2.5.0 native 1600x900) and the compositor fell to 44 Hz. Two paces on the game's commits, off the GPU:
//  - the game's own GPU share held under VXMAC_GPU_CAP (default 0.80 of the last 250 ms; 0 off): a commit waits (1 ms
//    steps, 12 ms at most) while the share is over it, so the GPU idles between the game's command buffers;
//  - while a warp's command buffer is on the GPU (vxmtl_warp_begin / _end, the presenter), the game's commits wait
//    (VXMAC_WARP_HOLD=0 off; 8 ms at most), so its work does not pile up in front of the warp.
//  Waits counted in stats: pace_waits, pace_ms)
static double g_gpu_cap = -1; static int g_warp_hold = -1; static _Atomic int g_warps_in_flight;
static _Atomic unsigned long g_pace_waits, g_pace_us;
static _Atomic unsigned long g_pace_cap_us, g_pace_warp_us;
static _Atomic unsigned long g_pace_frame_us, g_pace_frame_waits;
static int g_frame_pacing;
static double g_frame_max_hz;
static vxfp_clock g_frame_clock;
static pthread_mutex_t g_frame_pace_lock = PTHREAD_MUTEX_INITIALIZER;
static void pace_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *mode = getenv("VXMAC_PACING");
        g_frame_pacing = mode && !strcmp(mode,"frame");
        const char *cap = getenv("VXMAC_GPU_CAP"), *hold = getenv("VXMAC_WARP_HOLD");
        g_gpu_cap = g_frame_pacing ? 0 : cap && *cap ? atof(cap) : 0.70;
        g_frame_max_hz = g_frame_pacing ? vxfp_clock_limit(getenv("VXMAC_GAME_MAX_FPS")) : 0;
        g_warp_hold = !(hold && !strcmp(hold,"0"));
        vxmac_log("Metal: pacing %s, frame maximum %.1f FPS, legacy GPU share %.2f, warp permit %d",
                  g_frame_pacing ? "frame" : "legacy",g_frame_max_hz,g_gpu_cap,g_warp_hold);
    });
}
static void frame_limit_wait(void) {
    pace_init();
    if (!g_frame_pacing || g_frame_max_hz <= 0) return;
    double start = CACurrentMediaTime();
    pthread_mutex_lock(&g_frame_pace_lock);
    double deadline = vxfp_clock_reserve(&g_frame_clock,start,g_frame_max_hz);
    pthread_mutex_unlock(&g_frame_pace_lock);
    double now = start;
    if (deadline <= now) return;
    do {
        double remaining = deadline-now;
        struct timespec wait = { (time_t)remaining, (long)((remaining-floor(remaining))*1e9) };
        nanosleep(&wait,NULL);
        now = CACurrentMediaTime();
    } while (now < deadline);
    unsigned long us = (unsigned long)((now-start)*1e6);
    g_pace_frame_us += us; g_pace_frame_waits++; g_pace_us += us; g_pace_waits++;
}
// (h60f: the cap follows the compositor's misses - VXMacImmersive.swift reports each 5 s window's missed deadlines: over
//  3 -> the cap 0.05 lower (to 0.55 at least), six clean windows in a row -> 0.05 back up to its start; logged)
// (h64: at half rate - VXMAC_GPU_CAP_HALF=<cap> (off when unset; e.g. 0.85): once the compositor has presented every
//  22.2 ms (21-24 ms: visionOS's half rate, which it keeps for the session once it has locked there) for 3 windows in a
//  row (15 s), the warp needs half the GPU time it had at 90 Hz and the cap's start becomes <cap>; back to VXMAC_GPU_CAP
//  as soon as a window presents under 15 ms (90 Hz again). The misses rule above holds in both: over 3 -> 0.05 lower
//  (to 0.55), six clean windows -> 0.05 up to the start of the rate it is at. Logged; stats gpu_cap, gpu_cap_half)
static double g_cap_base = -1, g_cap_half_v = -1; static int g_half_windows, g_half_on; static double g_present_ms;
static void cap_init(void) {
    if (g_cap_half_v >= 0) return;
    const char *e = getenv("VXMAC_GPU_CAP_HALF"); g_cap_half_v = e && *e ? atof(e) : 0;
    if (g_cap_half_v > 0.95) g_cap_half_v = 0.95;
    if (g_cap_half_v > 0) vxmac_log("Metal: at the compositor's half rate the game's GPU share may rise to %.2f (VXMAC_GPU_CAP_HALF)", g_cap_half_v);
}
void vxmtl_compositor_interval(double ms) {   // (VXMacImmersive.swift: each 5 s window's mean present interval, before its misses)
    cap_init(); g_present_ms = ms;
    if (g_gpu_cap <= 0 || g_cap_half_v <= 0) return;
    if (g_cap_base < 0) g_cap_base = g_gpu_cap;
    if (ms > 21 && ms < 24) g_half_windows++; else if (ms > 0) g_half_windows = 0;
    double was = g_gpu_cap;
    if (!g_half_on && g_half_windows >= 3) { g_half_on = 1; if (g_gpu_cap < g_cap_half_v) g_gpu_cap = g_cap_half_v; }
    else if (g_half_on && ms > 0 && ms < 15) { g_half_on = 0; if (g_gpu_cap > g_cap_base) g_gpu_cap = g_cap_base; }
    if (g_gpu_cap != was) vxmac_log("Metal: the compositor at %.1f ms a frame: the game's GPU share cap %.2f -> %.2f (%s)", ms, was, g_gpu_cap, g_half_on ? "half rate" : "full rate again");
}
double vxmtl_gpu_cap(int *half) { if (half) *half = g_half_on; return g_gpu_cap; }
void vxmtl_pacing_report(int missed) {
    static int clean;
    if (g_gpu_cap <= 0) return;
    if (g_cap_base < 0) g_cap_base = g_gpu_cap;
    double top = g_half_on && g_cap_half_v > g_cap_base ? g_cap_half_v : g_cap_base;
    double was = g_gpu_cap;
    if (missed > 3) { clean = 0; if (g_gpu_cap > 0.55) g_gpu_cap -= 0.05; }
    else if (missed == 0 && ++clean >= 6) { clean = 0; if (g_gpu_cap < top - 1e-6) g_gpu_cap += 0.05; }
    if (g_gpu_cap != was) vxmac_log("Metal: the game's GPU share capped at %.2f (%d deadlines missed in 5 s%s)", g_gpu_cap, missed, g_half_on ? ", half rate" : "");
}
void vxmtl_warp_begin(void) { atomic_fetch_add(&g_warps_in_flight, 1); }
void vxmtl_warp_end(void) { if (atomic_fetch_sub(&g_warps_in_flight, 1) <= 0) atomic_store(&g_warps_in_flight, 0); }
#include "vxwarp_gate.h"
static int warp_release_scheduled(void) {
    static int scheduled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *mode = getenv("VXMAC_WARP_RELEASE");
        scheduled = mode && !strcmp(mode, "scheduled");
        vxmac_log("Metal: warp submission permit released when %s", scheduled ? "scheduled (trial)" : "completed");
    });
    return scheduled;
}
void vxmtl_warp_track(void *command_buffer) {
    vxmtl_warp_begin();
    vxwg_track(command_buffer, warp_release_scheduled(), ^{ vxmtl_warp_end(); });
}
static void pace(void) {
    pace_init();
    double t0 = CACurrentMediaTime(), now = t0;
    while (now - t0 < 0.012) {
        int wait = 0, warp_wait = 0;
        if (g_warp_hold && atomic_load(&g_warps_in_flight) > 0 && now - t0 < 0.008) wait = warp_wait = 1;
        if (!wait && g_gpu_cap > 0) { pthread_mutex_lock(&g_gpu_lock); double b = win_busy(now); pthread_mutex_unlock(&g_gpu_lock); wait = b > g_gpu_cap; }
        if (!wait) break;
        double before_sleep = now;
        usleep(1000); now = CACurrentMediaTime();
        // Attribute actual time to the condition that selected this sleep, rather than assuming 1 ms elapsed.
        // These are thread wait totals, not GPU execution time or a directly recoverable FPS budget.
        unsigned long elapsed_us = (unsigned long)((now - before_sleep) * 1e6);
        if (warp_wait) g_pace_warp_us += elapsed_us; else g_pace_cap_us += elapsed_us;
    }
    if (now > t0 + 0.0005) { g_pace_waits++; g_pace_us += (unsigned long)((now - t0) * 1e6); }
}
static void pose_seal(id command);
static void h_commit(id self, SEL s) {
    pose_seal(self);
    if (![((id<MTLCommandBuffer>)self).commandQueue.label hasPrefix:@"VX Mac"]) {
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> c) { gpu_account(c); }];
        if (g_fg) pace();
    }
    if (!g_fg) {
        g_held_commits++;
        pthread_mutex_lock(&g_fg_lock); while (!g_fg) pthread_cond_wait(&g_fg_cond, &g_fg_lock); pthread_mutex_unlock(&g_fg_lock);
    }
    const orig_t *o = orig_of(self);
    if (o && o->commit) o->commit(self, s);
}
static void h_present(id self, SEL s, id d) { const orig_t *o = orig_of(self); if (hooked(self, d) && o && o->p) o->p(self, s, d); }
static void h_present_at(id self, SEL s, id d, CFTimeInterval t) { const orig_t *o = orig_of(self); if (hooked(self, d) && o && o->at) o->at(self, s, d, t); }
static void h_present_after(id self, SEL s, id d, CFTimeInterval t) { const orig_t *o = orig_of(self); if (hooked(self, d) && o && o->after) o->after(self, s, d, t); }

static IMP swap(Class c, SEL s, IMP n) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) return NULL;
    // (on the class itself, so a superclass shared with other kinds keeps its own)
    if (!class_addMethod(c, s, n, method_getTypeEncoding(m))) return method_setImplementation(class_getInstanceMethod(c, s), n);
    return method_getImplementation(m);
}
// ---- render passes (vxmac.h vxmtl_set_pass_hook): each render encoder's depth attachment, given to the host when the
// encoder ends, with the command buffer (the host's presenter copies the scene's depth from the biggest one) --------
static vxmtl_pass_hook g_pass_hook;
void vxmtl_set_pass_hook(vxmtl_pass_hook h) { g_pass_hook = h; }
static vxmtl_target_hook g_target_hook;
void vxmtl_set_target_hook(vxmtl_target_hook h) { g_target_hook = h; }
static const void *kPassTargets = &kPassTargets;
static void targets_end(id enc);
static const void *kPassCB = &kPassCB, *kPassDepth = &kPassDepth, *kPassStore = &kPassStore;
static const void *kPoseResources = &kPoseResources;
static void pose_seal(id command) {
    if (!objc_getAssociatedObject(command, kPoseResources)) return;
    void vxpipe_pose_seal_command_buffer(id);
    vxpipe_pose_seal_command_buffer(command);
}
id vxmtl_command_buffer_for_encoder(id encoder) {
    return objc_getAssociatedObject(encoder, kPassCB);
}

// Indirect argument buffers may be used by a command buffer created with
// unretained references. Own our copies until its GPU work has completed.
int vxmtl_retain_for_encoder(id encoder, id resource) {
    id<MTLCommandBuffer> cb = objc_getAssociatedObject(encoder, kPassCB);
    if (!cb || !resource) return 0;
    @synchronized (cb) {
        NSMutableSet *resources = objc_getAssociatedObject(cb, kPoseResources);
        if (!resources) {
            resources = [NSMutableSet set];
            objc_setAssociatedObject(cb, kPoseResources, resources, OBJC_ASSOCIATION_RETAIN);
            [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                objc_setAssociatedObject(completed, kPoseResources, nil, OBJC_ASSOCIATION_RETAIN);
            }];
        }
        [resources addObject:resource];
    }
    return 1;
}
typedef id (*rce_imp)(id, SEL, MTLRenderPassDescriptor *);
typedef void (*end_imp)(id, SEL);
static rce_imp o_rce, o_prce; static end_imp o_end, o_pend;
static void pass_note(id d) {   // (each distinct depth attachment shape once: the game makes new views every pass)
    static uint64_t seen[32]; static int n; static pthread_mutex_t l = PTHREAD_MUTEX_INITIALIZER;
    id<MTLTexture> t = d;
    uint64_t key = ((uint64_t)t.width << 40) ^ ((uint64_t)t.height << 20) ^ ((uint64_t)t.pixelFormat << 4) ^ (uint64_t)t.textureType;
    pthread_mutex_lock(&l);
    int f = 0; for (int i = 0; i < n; i++) if (seen[i] == key) f = 1;
    if (!f && n < 32) seen[n++] = key;
    pthread_mutex_unlock(&l);
    if (!f) vxmac_log("Metal: depth attachment %lux%lu format %lu type %lu samples %lu array %lu%s", (unsigned long)t.width, (unsigned long)t.height,
                      (unsigned long)t.pixelFormat, (unsigned long)t.textureType, (unsigned long)t.sampleCount, (unsigned long)t.arrayLength,
                      t.parentTexture ? " (a view)" : "");
}
// (h64: what we attach to the game's encoders, dropped when the encoder ends - nothing of ours is read after its
//  endEncoding, and the objects go now rather than with the encoder's dealloc. ddgame63d's malloc grew ~16 blocks per
//  game command buffer, steadily: if the device's encoders were freed without the runtime's association cleanup, each
//  one's records would stay. A sampled probe (1 encoder in 16 we tag; never dropped) tells: "enc_probes_live" in the
//  mem line stays small when the encoders' dealloc frees what is attached to them, and grows with the encoders if not.
//  VXMAC_ENC_CLEAR=0: not dropped (as before))
static const void *kScan, *kUI, *kUIcb, *kUIhit, *kProbe = &kProbe;
static _Atomic long g_probe_made, g_probe_live, g_enc_cleared;
@interface VXEncProbe : NSObject
@end
@implementation VXEncProbe
- (void)dealloc { atomic_fetch_sub(&g_probe_live, 1); }
@end
static void enc_probe(id e) {
    static _Atomic unsigned n;
    if (!e || (atomic_fetch_add(&n, 1) & 15)) return;
    atomic_fetch_add(&g_probe_made, 1); atomic_fetch_add(&g_probe_live, 1);
    objc_setAssociatedObject(e, kProbe, [VXEncProbe new], OBJC_ASSOCIATION_RETAIN);
}
void vxpipe_enc_clear(id e);   // (vxpipe.m: its own key)
static void enc_clear(id e) {
    static int on = -1; if (on < 0) { const char *v = getenv("VXMAC_ENC_CLEAR"); on = !(v && !strcmp(v, "0")); }
    if (!on || !e) return;
    const void *keys[] = { kPassTargets, kPassCB, kPassDepth, kPassStore, kScan, kUI, kUIcb, kUIhit };
    int any = 0;
    for (unsigned i = 0; i < sizeof keys / sizeof *keys; i++) if (objc_getAssociatedObject(e, keys[i])) { objc_setAssociatedObject(e, keys[i], nil, OBJC_ASSOCIATION_ASSIGN); any = 1; }
    vxpipe_enc_clear(e);
    if (any) atomic_fetch_add(&g_enc_cleared, 1);
}
void vxmtl_enc_stats(char *out, unsigned n) {
    snprintf(out, n, "\"enc_probes\":%ld,\"enc_probes_live\":%ld,\"enc_cleared\":%ld", atomic_load(&g_probe_made), atomic_load(&g_probe_live), atomic_load(&g_enc_cleared));
}
static void h_pend(id self, SEL s) {   // (a parallel encoder: its pass ends with it)
    o_pend(self, s);
    targets_end(self);
    if (g_pass_hook) {
        id cb = objc_getAssociatedObject(self, kPassCB), d = objc_getAssociatedObject(self, kPassDepth);
        if (cb && d) { if (vxprof_enabled) vxprof_ours(1); g_pass_hook((__bridge void *)cb, (__bridge void *)d, [objc_getAssociatedObject(self, kPassStore) intValue]); if (vxprof_enabled) vxprof_ours(-1); }
    }
    enc_clear(self);
}
static void targets_end(id enc) {
    if (!g_target_hook) return;
    NSArray *ts = objc_getAssociatedObject(enc, kPassTargets);
    id cb = objc_getAssociatedObject(enc, kPassCB);
    if (vxprof_enabled) vxprof_ours(1);
    for (NSArray *e in ts) g_target_hook((__bridge void *)cb, (__bridge void *)e[0], [e[1] intValue]);
    if (vxprof_enabled) vxprof_ours(-1);
}
static void targets_note(id enc, id cb, MTLRenderPassDescriptor *pd) {
    if (!g_target_hook || !pd.depthAttachment.texture) return;
    NSMutableArray *ts = nil;
    for (int i = 0; i < 8; i++) {
        id<MTLTexture> t = pd.colorAttachments[i].texture;
        if (t && (t.pixelFormat == MTLPixelFormatRG16Float || t.pixelFormat == MTLPixelFormatRG16Snorm) && (pd.colorAttachments[i].storeAction == MTLStoreActionStore || pd.colorAttachments[i].storeAction == MTLStoreActionUnknown ||
                  pd.colorAttachments[i].storeAction == MTLStoreActionStoreAndMultisampleResolve)) {   // (Unknown: set at the pass's end; the velocity check vets it)
            if (!ts) ts = [NSMutableArray array];
            [ts addObject:@[ t, @(i) ]];
        }
    }
    if (ts) { objc_setAssociatedObject(enc, kPassTargets, ts, OBJC_ASSOCIATION_RETAIN); objc_setAssociatedObject(enc, kPassCB, cb, OBJC_ASSOCIATION_ASSIGN); }
}
static void ui_end(id enc, id cbo);   // (h51, below)
void vxpipe_install_device(Class dc); void vxpipe_install_encoders(Class rc, Class cc); int vxpipe_on(void);   // (vxpipe.m)
void vxpipe_frame(void); void vxpipe_render_begin(id e, MTLRenderPassDescriptor *pd,id buffer); void vxpipe_render_end(id e);
static void h_end(id self, SEL s) {
    if (vxprof_enabled) vxprof_end(self);   // (VXMAC_PASS_PROFILE's serial windows: the fence, before the pass ends)
    o_end(self, s);
    vxpipe_render_end(self);
    targets_end(self);
    { id cbu = objc_getAssociatedObject(self, kUI) ? objc_getAssociatedObject(self, kUIcb) : nil; if (cbu) ui_end(self, cbu); }
    if (g_pass_hook) {
        id cb = objc_getAssociatedObject(self, kPassCB), d = objc_getAssociatedObject(self, kPassDepth);
        if (cb && d) { if (vxprof_enabled) vxprof_ours(1); g_pass_hook((__bridge void *)cb, (__bridge void *)d, [objc_getAssociatedObject(self, kPassStore) intValue]); if (vxprof_enabled) vxprof_ours(-1); }
    }
    enc_clear(self);
}
static id h_prce(id self, SEL s, MTLRenderPassDescriptor *pd) {
    void *ppx = NULL; if (vxprof_live) pd = vxprof_render_pd(self, pd, &ppx, 1);
    id e = o_prce(self, s, pd);
    if (ppx) vxprof_render_enc(e, ppx);
    if (e) targets_note(e, self, pd);
    if (e && g_pass_hook) drawable_pass_note(pd);
    if (e && g_pass_hook && pd.depthAttachment.texture) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ o_pend = (end_imp)method_setImplementation(class_getInstanceMethod(object_getClass(e), @selector(endEncoding)), (IMP)h_pend);
                                vxmac_log("Metal: parallel render passes watched on %s", class_getName(object_getClass(e))); });
        pass_note(pd.depthAttachment.texture);
        objc_setAssociatedObject(e, kPassCB, self, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(e, kPassDepth, pd.depthAttachment.texture, OBJC_ASSOCIATION_RETAIN);
        MTLStoreAction sa = pd.depthAttachment.storeAction;
        objc_setAssociatedObject(e, kPassStore, @((sa == MTLStoreActionStore || sa == MTLStoreActionStoreAndMultisampleResolve) && pd.depthAttachment.loadAction != MTLLoadActionClear && pd.colorAttachments[0].texture != nil), OBJC_ASSOCIATION_RETAIN);
        enc_probe(e);
    }
    return e;
}
// (the game's colour targets, each shape and format once: two-channel float targets at the render size are its
//  velocity buffer's candidates, for the presenter's motion vectors in place of the NPU flow)
static void color_note(MTLRenderPassDescriptor *pd) {
    static uint64_t seen[64]; static int n; static pthread_mutex_t l = PTHREAD_MUTEX_INITIALIZER;
    for (int i = 0; i < 8; i++) {
        id<MTLTexture> t = pd.colorAttachments[i].texture;
        if (!t) continue;
        uint64_t key = ((uint64_t)t.width << 40) ^ ((uint64_t)t.height << 20) ^ ((uint64_t)t.pixelFormat << 4) ^ (uint64_t)i;
        pthread_mutex_lock(&l);
        int f = 0; for (int k = 0; k < n; k++) if (seen[k] == key) f = 1;
        if (!f && n < 64) seen[n++] = key;
        pthread_mutex_unlock(&l);
        if (!f && n < 64) vxmac_log("Metal: colour target %d: %lux%lu format %lu type %lu store %lu%s%s", i, (unsigned long)t.width, (unsigned long)t.height,
                                   (unsigned long)t.pixelFormat, (unsigned long)t.textureType, (unsigned long)pd.colorAttachments[i].storeAction, pd.depthAttachment.texture ? " (with depth)" : "",
                                   (t.pixelFormat == MTLPixelFormatRG16Float || t.pixelFormat == MTLPixelFormatRG32Float || t.pixelFormat == MTLPixelFormatRG16Snorm) ? " <- velocity candidate" : "");
    }
}

// ---- (h29) the game's own camera: rotation matrices in the constant data of its scene passes ----
// Each frame, the first two render passes with depth at the scene's size (the widest depth seen) are watched: every
// buffer (shared storage) and bytes their draws bind are scanned (2 KB from the binding's offset, 16-byte steps) for
// 4x4 float matrices whose 3x3 is a rotation (unit rows, orthogonal; 4th row or column 0,0,0,1). Up to 16 distinct
// ones a frame (by where they were found: stage, index, offset) go to the host (vxmtl_camera_candidates), which finds
// the one whose turn matches the picture's. VXMAC_CAM_SCAN=0: off.
static int g_cam_scan = -1; static uint32_t g_scene_w;
static _Atomic int g_scan_passes;                     // (scene passes watched this frame)
static pthread_mutex_t g_cam_l = PTHREAD_MUTEX_INITIALIZER;
static vxmtl_cam_cand g_cam_cur[16], g_cam_done[16]; static int g_cam_ncur, g_cam_ndone;
static const void *kScan = &kScan;
static int is_rot(const float *m) {
    if (fabsf(m[15] - 1) > 1e-3f) return 0;                // (cheap first: most data fails here)
    for (int i = 0; i < 16; i++) if (!isfinite(m[i])) return 0;
    // (rows of the 3x3 (m[0..2], m[4..6], m[8..10]): unit and orthogonal; either m[3,7,11] or m[12,13,14] zero with m[15] 1)
    for (int r = 0; r < 3; r++) { float l = m[r*4]*m[r*4] + m[r*4+1]*m[r*4+1] + m[r*4+2]*m[r*4+2]; if (fabsf(l - 1) > 0.01f) return 0; }
    for (int a = 0; a < 3; a++) for (int b = a + 1; b < 3; b++) if (fabsf(m[a*4]*m[b*4] + m[a*4+1]*m[b*4+1] + m[a*4+2]*m[b*4+2]) > 0.01f) return 0;
    if (fabsf(m[15] - 1) > 1e-3f) return 0;
    int c3 = fabsf(m[3]) < 1e-4f && fabsf(m[7]) < 1e-4f && fabsf(m[11]) < 1e-4f, r3 = fabsf(m[12]) < 1e-4f && fabsf(m[13]) < 1e-4f && fabsf(m[14]) < 1e-4f;
    if (!c3 && !r3) return 0;
    // (not the identity: a model matrix with no turn says nothing)
    if (fabsf(m[0] - 1) < 1e-5f && fabsf(m[5] - 1) < 1e-5f && fabsf(m[10] - 1) < 1e-5f) return 0;
    return 1;
}
static _Atomic int g_scan_calls;                      // (bindings scanned this frame: 600 at most - the CPU cost)
static void cam_scan(const void *base, NSUInteger len, uint32_t where) {
    if (!base || len < 64 || atomic_fetch_add(&g_scan_calls, 1) >= 600) return;
    const uint8_t *p = base; NSUInteger n = len < 2048 ? len : 2048;
    for (NSUInteger o = 0; o + 64 <= n; o += 16) {
        const float *m = (const float *)(p + o);
        if (!is_rot(m)) continue;
        uint32_t key = where ^ ((uint32_t)o << 20);
        pthread_mutex_lock(&g_cam_l);
        int dup = 0; for (int i = 0; i < g_cam_ncur; i++) if (g_cam_cur[i].key == key) dup = 1;
        if (!dup && g_cam_ncur < 16) { g_cam_cur[g_cam_ncur].key = key; memcpy(g_cam_cur[g_cam_ncur].m, m, 64); g_cam_ncur++; }
        pthread_mutex_unlock(&g_cam_l);
    }
}
typedef void (*setbuf_imp)(id, SEL, id, NSUInteger, NSUInteger);
typedef void (*setbytes_imp)(id, SEL, const void *, NSUInteger, NSUInteger);
static setbuf_imp o_svb, o_sfb; static setbytes_imp o_svby, o_sfby;
static void scan_buf(id self, id buf, NSUInteger off, NSUInteger idx, uint32_t stage) {
    if (!objc_getAssociatedObject(self, kScan) || !buf) return;
    id<MTLBuffer> b = buf;
    if (b.storageMode != MTLStorageModeShared || off >= b.length) return;
    cam_scan((const uint8_t *)b.contents + off, b.length - off, stage | ((uint32_t)idx << 2) | ((uint32_t)(atomic_load(&g_scan_passes) & 3) << 8));
}
static void h_svb(id self, SEL s, id buf, NSUInteger off, NSUInteger idx) { o_svb(self, s, buf, off, idx); scan_buf(self, buf, off, idx, 0); }
static void h_sfb(id self, SEL s, id buf, NSUInteger off, NSUInteger idx) { o_sfb(self, s, buf, off, idx); scan_buf(self, buf, off, idx, 1); }
static void h_svby(id self, SEL s, const void *b, NSUInteger len, NSUInteger idx) { o_svby(self, s, b, len, idx); if (objc_getAssociatedObject(self, kScan)) cam_scan(b, len, 2 | ((uint32_t)idx << 2)); }
static void h_sfby(id self, SEL s, const void *b, NSUInteger len, NSUInteger idx) { o_sfby(self, s, b, len, idx); if (objc_getAssociatedObject(self, kScan)) cam_scan(b, len, 3 | ((uint32_t)idx << 2)); }
static void cam_watch(id e, MTLRenderPassDescriptor *pd) {
    if (g_cam_scan < 0) { const char *v = getenv("VXMAC_CAM_SCAN"); g_cam_scan = !(v && !strcmp(v, "0")); }
    if (!g_cam_scan || !e) return;
    id<MTLTexture> d = pd.depthAttachment.texture;
    if (!d) return;
    if (d.width > g_scene_w) g_scene_w = (uint32_t)d.width;
    if (d.width != g_scene_w || atomic_fetch_add(&g_scan_passes, 1) >= 2) return;
    static pthread_mutex_t l = PTHREAD_MUTEX_INITIALIZER; static NSMutableSet *hooked;
    pthread_mutex_lock(&l);
    if (!hooked) hooked = [NSMutableSet set];
    Class c = object_getClass(e); NSString *k = NSStringFromClass(c);
    if (![hooked containsObject:k]) {
        [hooked addObject:k];
        setbuf_imp a = (setbuf_imp)method_setImplementation(class_getInstanceMethod(c, @selector(setVertexBuffer:offset:atIndex:)), (IMP)h_svb); if (!o_svb) o_svb = a;
        setbuf_imp b = (setbuf_imp)method_setImplementation(class_getInstanceMethod(c, @selector(setFragmentBuffer:offset:atIndex:)), (IMP)h_sfb); if (!o_sfb) o_sfb = b;
        setbytes_imp cc = (setbytes_imp)method_setImplementation(class_getInstanceMethod(c, @selector(setVertexBytes:length:atIndex:)), (IMP)h_svby); if (!o_svby) o_svby = cc;
        setbytes_imp dd = (setbytes_imp)method_setImplementation(class_getInstanceMethod(c, @selector(setFragmentBytes:length:atIndex:)), (IMP)h_sfby); if (!o_sfby) o_sfby = dd;
        vxmac_log("Metal: the scene passes' constants watched for the camera on %s", class_getName(c));
    }
    pthread_mutex_unlock(&l);
    objc_setAssociatedObject(e, kScan, @1, OBJC_ASSOCIATION_RETAIN);
}
static _Atomic int g_ui_ord; static _Atomic unsigned long g_census_frame; static _Atomic int g_ui_half;
void vxmtl_ui_half(int on) { atomic_store(&g_ui_half, on); }
static void cam_frame_end(void) {
    pthread_mutex_lock(&g_cam_l);
    memcpy(g_cam_done, g_cam_cur, sizeof g_cam_cur); g_cam_ndone = g_cam_ncur; g_cam_ncur = 0;
    pthread_mutex_unlock(&g_cam_l);
    atomic_store(&g_scan_passes, 0); atomic_store(&g_scan_calls, 0); atomic_store(&g_ui_ord, 0); atomic_fetch_add(&g_census_frame, 1);
}
int vxmtl_camera_candidates(vxmtl_cam_cand *out, int max) {
    pthread_mutex_lock(&g_cam_l);
    int n = g_cam_ndone < max ? g_cam_ndone : max; memcpy(out, g_cam_done, n * sizeof *out);
    pthread_mutex_unlock(&g_cam_l);
    return n;
}
// ---- (h33) the HUD on its own: the game composites its scene into the drawable before any render pass (compute or a
// blit) and draws the UI in one render pass that loads it (h26-h32's pass log: one pass a frame, load). That pass is
// sent to a texture of our own instead, cleared to transparent: the drawable keeps the scene, the texture holds the HUD
// with its alpha (as the game designed it: any shape, tilted panels). The host takes it per frame (vxmtl_hud_take).
// VXMAC_HUD_LAYER=0: off (the UI stays in the drawable).
static int g_hud_layer = -1; static __strong id<MTLTexture> g_hud_tex; static _Atomic int g_hud_this_frame;
// (h34: only while the presenter shows the layer - head-look. In menus, loading and the panel the UI stays in the
//  drawable: h33 redirected the main menu's UI too and the panel showed black)
static _Atomic int g_hud_want;
void vxmtl_hud_want(int on) { atomic_store(&g_hud_want, on); }
static pthread_mutex_t g_hud_l = PTHREAD_MUTEX_INITIALIZER;
static MTLRenderPassDescriptor *hud_redirect(MTLRenderPassDescriptor *pd) {
    // (off by default since h34: the Load pass carries the whole frame (a full-screen draw of the scene with the UI) -
    //  the layer showed the full picture as a head-locked square over the world; VXMAC_HUD_LAYER=1 on, for study)
    if (g_hud_layer < 0) { const char *e = getenv("VXMAC_HUD_LAYER"); g_hud_layer = e && !strcmp(e, "1"); }
    if (!g_hud_layer || !g_pass_hook || !atomic_load(&g_hud_want)) return pd;
    id<MTLTexture> t = pd.colorAttachments[0].texture;
    if (!t || t != g_cur_tex || pd.colorAttachments[0].loadAction != MTLLoadActionLoad || pd.depthAttachment.texture) return pd;
    pthread_mutex_lock(&g_hud_l);
    if (!g_hud_tex || g_hud_tex.width != t.width || g_hud_tex.height != t.height || g_hud_tex.pixelFormat != t.pixelFormat) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:t.width height:t.height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView; td.storageMode = MTLStorageModePrivate;
        g_hud_tex = [t.device newTextureWithDescriptor:td];
        vxmac_log("Metal: the UI pass goes to a HUD texture of its own (%lux%lu): the drawable keeps the scene", (unsigned long)t.width, (unsigned long)t.height);
    }
    id<MTLTexture> h = g_hud_tex;
    pthread_mutex_unlock(&g_hud_l);
    if (!h) return pd;
    MTLRenderPassDescriptor *d = [pd copy];
    d.colorAttachments[0].texture = h;
    d.colorAttachments[0].loadAction = MTLLoadActionClear;
    d.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    d.colorAttachments[0].storeAction = MTLStoreActionStore;
    atomic_store(&g_hud_this_frame, 1);
    return d;
}
// ---- (h51) the UI layers by identity, no pixel heuristics. The game draws its UI into frame-sized layers (h50's
// pipeline dump: RGBA8 sRGB (71) and RGBA16F (115), 5 mips each, cleared every frame) with two vertex shaders,
// known by the FNV-64 hash of their library's bytes (vxpipe.m, computed at every library's creation):
// 9659c847a5663c68 and dd2ffa0fee62e619. A render pass is a UI layer pass iff its colour target 0 is frame-sized (the
// drawable's size), it has no depth, and one of those shaders draws in it. In head-look (the presenter shows the HUD)
// and while the game's mouse look is on (its cursor dissociated), every such layer is composited into the HUD texture
// (premultiplied, in pass order) at its pass's end and then cleared, so the game's composite (and the mips it builds
// from the layer afterwards) has the scene only: the dialogue and RELIC popups (the RGBA16F layer) no longer show
// twice. With the cursor associated (menus, the map, inventory: the game's own signal) nothing is taken: the whole
// frame goes to the centred menu panel (vxmtl_ui_menu). VXMAC_UI_CAPTURE=0: off; VXMAC_UI_CLEAR=0: not cleared.
static const void *kUI = &kUI, *kUIcb = &kUIcb, *kUIhit = &kUIhit;
static int g_ui_capture = -1;
int vxpipe_ui_replay(id enc, id cbo, id tex, NSUInteger slice); void vxpipe_ui_rec_begin(id e, int masking, void *tex);
static unsigned long g_hud_filled_frame = (unsigned long)-1;   // (the frame whose first UI layer cleared the HUD texture)
static id<MTLRenderPipelineState> g_ui_blend[2];               // (a layer composited over the HUD texture: 2D, 2D array)
static __thread int g_ui_busy;                                 // (our own passes are not candidates)
static void *g_ui_pipes[128]; static _Atomic int g_ui_npipes;   // (the game's pipelines with a UI vertex shader)
void vxmtl_ui_pipe_add(void *p) {   // (vxpipe.m: a render pipeline whose vertex function's library hash is a UI one)
    int n = atomic_load(&g_ui_npipes);
    if (n >= 128) return;
    g_ui_pipes[n] = p; atomic_store(&g_ui_npipes, n + 1);
    if (n < 40) vxmac_log("Metal: UI pipeline %d registered (vertex shader of the UI set)", n + 1);
}
void vxmtl_ui_pipe_set(id enc, id p) {   // (vxpipe.m: every setRenderPipelineState:)
    void *pp = (__bridge void *)p; int n = atomic_load(&g_ui_npipes);
    for (int i = 0; i < n; i++) if (g_ui_pipes[i] == pp) {
        if (objc_getAssociatedObject(enc, kUI) && !objc_getAssociatedObject(enc, kUIhit)) objc_setAssociatedObject(enc, kUIhit, @1, OBJC_ASSOCIATION_RETAIN);
        return;
    }
}
static void ui_note(id e, MTLRenderPassDescriptor *pd) {
    if (!g_pass_hook || pd.depthAttachment.texture || g_ui_busy || !atomic_load(&g_ui_npipes)) return;
    id<MTLTexture> t = pd.colorAttachments[0].texture, dt = g_cur_tex;
    // (h52: with a mip chain, as both layers have (5): a frame-sized single-level target drawn by a UI shader showed up
    //  in h51 (unknown use; the game's final image is one too) and is never taken)
    if (!t || !dt || t == dt || t.width != dt.width || t.height != dt.height || pd.colorAttachments[0].level != 0 || t.mipmapLevelCount < 2 ||
        !(t.textureType == MTLTextureType2D || (t.textureType == MTLTextureType2DArray && t.arrayLength == 1))) return;
    objc_setAssociatedObject(e, kUI, @[ t, @(pd.colorAttachments[0].slice) ], OBJC_ASSOCIATION_RETAIN);
    if (g_ui_capture < 0) { const char *v = getenv("VXMAC_UI_CAPTURE"); g_ui_capture = !(v && !strcmp(v, "0")); }
    vxpipe_ui_rec_begin(e, g_ui_capture && atomic_load(&g_hud_want) && !vxkit_cursor_associated(), (__bridge void *)t);   // (h58: the world UI's draws recorded, masked while the HUD is captured)
}
static void ui_end_inner(id enc, id cbo);
static void ui_end(id enc, id cbo) {   // (h58: then the world UI drawn again into the layer, after the HUD's capture and clear)
    if (vxprof_enabled) vxprof_ours(1);   // (VXMAC_PASS_PROFILE: the capture's passes are ours)
    NSArray *u = objc_getAssociatedObject(enc, kUI);
    id t = u ? u[0] : nil; NSUInteger slice = u ? [u[1] unsignedIntegerValue] : 0;
    ui_end_inner(enc, cbo);
    if (t && cbo) { g_ui_busy = 1; vxpipe_ui_replay(enc, cbo, t, slice); g_ui_busy = 0; }
    if (vxprof_enabled) vxprof_ours(-1);
}
static void ui_end_inner(id enc, id cbo) {
    NSArray *u = objc_getAssociatedObject(enc, kUI);
    if (!u || !cbo) return;
    int hit = objc_getAssociatedObject(enc, kUIhit) != nil;
    objc_setAssociatedObject(enc, kUI, nil, OBJC_ASSOCIATION_RETAIN);
    if (hit) objc_setAssociatedObject(enc, kUIhit, nil, OBJC_ASSOCIATION_RETAIN);
    if (!hit) return;
    id<MTLTexture> t = u[0]; NSUInteger slice = [u[1] unsignedIntegerValue];
    {   // (each layer texture (format, size) logged once)
        static uint64_t seen[16]; static int ns;
        uint64_t key = ((uint64_t)t.width << 40) ^ ((uint64_t)t.height << 20) ^ ((uint64_t)t.pixelFormat << 4) ^ (uint64_t)t.mipmapLevelCount;
        int known = 0; for (int i = 0; i < ns; i++) if (seen[i] == key) known = 1;
        if (!known && ns < 16) { seen[ns++] = key; vxmac_log("Metal: UI layer %lux%lu format %lu mips %lu (drawn by a UI vertex shader)", (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, (unsigned long)t.mipmapLevelCount); }
    }
    id<MTLCommandBuffer> cb = cbo;
    if (g_ui_capture < 0) { const char *v = getenv("VXMAC_UI_CAPTURE"); g_ui_capture = !(v && !strcmp(v, "0")); }
    if (!g_ui_capture || !atomic_load(&g_hud_want) || vxkit_cursor_associated() || !(t.usage & MTLTextureUsageShaderRead)) return;
    pthread_mutex_lock(&g_hud_l);
    if (!g_hud_tex || g_hud_tex.width != t.width || g_hud_tex.height != t.height) {   // (one fixed format: sRGB 8-bit, premultiplied)
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:t.width height:t.height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView; td.storageMode = MTLStorageModePrivate;
        g_hud_tex = [t.device newTextureWithDescriptor:td];
        vxmac_log("Metal: the UI layers composited into the HUD texture (%lux%lu) and cleared in the game's frame", (unsigned long)t.width, (unsigned long)t.height);
    }
    id<MTLTexture> h = g_hud_tex;
    pthread_mutex_unlock(&g_hud_l);
    if (!h) return;
    unsigned long fcur = atomic_load(&g_census_frame);
    if (g_hud_filled_frame != fcur) {   // (the frame's first layer: the HUD texture cleared)
        g_hud_filled_frame = fcur;
        MTLRenderPassDescriptor *rp0 = [MTLRenderPassDescriptor renderPassDescriptor];
        rp0.colorAttachments[0].texture = h; rp0.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp0.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0); rp0.colorAttachments[0].storeAction = MTLStoreActionStore;
        g_ui_busy = 1; [[cb renderCommandEncoderWithDescriptor:rp0] endEncoding]; g_ui_busy = 0;
    }
    int arr = t.textureType == MTLTextureType2DArray;
    if (!g_ui_blend[arr]) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 p [[position]]; float2 uv; };\n"
            "vertex V bv(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V o; o.p = float4(q * 2 - 1, 0, 1); o.uv = float2(q.x, 1 - q.y); return o; }\n"
            // (h57d: each layer taken as premultiplied and in range - colour at most its alpha, 0..1: the RGBA16F layer (2.5.0's
            //  second) carries HDR / unpremultiplied full-screen effects (a vehicle's mount transition, screen-edge glows)
            //  whose colour above its alpha came out as a white haze / a white frame on the head-locked panel)
            "static float4 pm(float4 c) { c = clamp(c, 0.0f, 1.0f); c.rgb = min(c.rgb, float3(c.a)); return c; }\n"
            "fragment float4 bf(V i [[stage_in]], texture2d<float> t [[texture(0)]]) { constexpr sampler s(filter::nearest); return pm(t.sample(s, i.uv)); }\n"
            "fragment float4 bfa(V i [[stage_in]], texture2d_array<float> t [[texture(0)]]) { constexpr sampler s(filter::nearest); return pm(t.sample(s, i.uv, 0)); }\n";
        NSError *err = nil;
        id<MTLLibrary> lib = [cb.device newLibraryWithSource:src options:nil error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"bv"]; pd.fragmentFunction = [lib newFunctionWithName:arr ? @"bfa" : @"bf"];
        pd.colorAttachments[0].pixelFormat = h.pixelFormat; pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne; pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne; pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        g_ui_blend[arr] = lib ? [cb.device newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
        if (!g_ui_blend[arr]) { vxmac_log("Metal: the UI layer blend: %s", err.localizedDescription.UTF8String); g_ui_capture = 0; return; }
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = h; rp.colorAttachments[0].loadAction = MTLLoadActionLoad; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    g_ui_busy = 1;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:g_ui_blend[arr]]; [re setFragmentTexture:t atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
    g_ui_busy = 0;
    static int clr = -1; if (clr < 0) { const char *v = getenv("VXMAC_UI_CLEAR"); clr = !(v && !strcmp(v, "0")); }
    if (clr && (t.usage & MTLTextureUsageRenderTarget)) {   // (cleared: the composite after this pass gets no UI)
        MTLRenderPassDescriptor *rc = [MTLRenderPassDescriptor renderPassDescriptor];
        rc.colorAttachments[0].texture = t; rc.colorAttachments[0].slice = slice; rc.colorAttachments[0].loadAction = MTLLoadActionClear;
        rc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0); rc.colorAttachments[0].storeAction = MTLStoreActionStore;
        g_ui_busy = 1; [[cb renderCommandEncoderWithDescriptor:rc] endEncoding]; g_ui_busy = 0;
    }
    atomic_store(&g_hud_this_frame, 1);
    {   // (h57f: what the HUD panel shows, for diagnosis - every 15 s the HUD texture (after this layer) saved raw as
        //  Documents/hud_<n>.rgba (8-byte header: width, height; RGBA8 sRGB premultiplied), 6 at most; VXMAC_HUD_SNAP=0 off)
        static double last; static int n, on = -1;
        if (on < 0) { const char *v = getenv("VXMAC_HUD_SNAP"); on = !(v && !strcmp(v, "0")); }
        double tn = CACurrentMediaTime();
        if (on && n < 6 && tn - last > 15) {
            last = tn; int k = n++;
            NSUInteger W = h.width, H = h.height;
            id<MTLBuffer> buf = [cb.device newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromTexture:h sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4];
            [be endEncoding];
            unsigned long fmt = t.pixelFormat;
            [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c;
                NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                NSMutableData *m = [NSMutableData dataWithCapacity:W * H * 4 + 8]; uint32_t hd[2] = { (uint32_t)W, (uint32_t)H };
                [m appendBytes:hd length:8]; [m appendBytes:buf.contents length:W * H * 4];
                [m writeToFile:[d stringByAppendingPathComponent:[NSString stringWithFormat:@"hud_%d.rgba", k]] atomically:YES];
                vxmac_log("Metal: HUD texture saved as hud_%d.rgba (after a format %lu layer)", k, fmt); }];
        }
    }
}
// (h51: a menu / full-screen UI = the game's cursor associated (its mouse look off): the whole frame on the centred
//  panel - the game's own signal, not a coverage share)
int vxmtl_ui_menu(void) { return vxkit_cursor_associated(); }
void *vxmtl_hud_take(void) {   // (the HUD texture when this frame's UI pass went to it, else NULL; once a frame)
    if (!atomic_exchange(&g_hud_this_frame, 0)) return NULL;
    pthread_mutex_lock(&g_hud_l); void *t = (__bridge void *)g_hud_tex; pthread_mutex_unlock(&g_hud_l);
    return t;
}
static void h_end(id self, SEL s);
static void ui_hook_end(id e) {   // (the endEncoding hook installed once on the encoder's class, as the depth passes do)
    static dispatch_once_t once;
    dispatch_once(&once, ^{ if (!o_end) o_end = (end_imp)method_setImplementation(class_getInstanceMethod(object_getClass(e), @selector(endEncoding)), (IMP)h_end); });
}
static id h_rce(id self, SEL s, MTLRenderPassDescriptor *pd) {
    if (g_hud_layer != 0) pd = hud_redirect(pd);
    void *ppx = NULL; if (vxprof_live) pd = vxprof_render_pd(self, pd, &ppx, 0);   // (a sampled frame: a copy with the counters)
    id e = o_rce(self, s, pd);
    if (e) objc_setAssociatedObject(e, kPassCB, self, OBJC_ASSOCIATION_ASSIGN);
    if (ppx) vxprof_render_enc(e, ppx);
    if (e && g_pass_hook) { color_note(pd); drawable_pass_note(pd); cam_watch(e, pd); ui_note(e, pd); if (objc_getAssociatedObject(e, kUI)) { objc_setAssociatedObject(e, kUIcb, self, OBJC_ASSOCIATION_ASSIGN); ui_hook_end(e); } }
    if (e) targets_note(e, self, pd);
    if (e) vxpipe_render_begin(e, pd,self);
    if (e && g_pass_hook && pd.depthAttachment.texture) pass_note(pd.depthAttachment.texture);
    if (e && g_pass_hook && pd.depthAttachment.texture) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ if (!o_end) o_end = (end_imp)method_setImplementation(class_getInstanceMethod(object_getClass(e), @selector(endEncoding)), (IMP)h_end);
                                vxmac_log("Metal: render passes watched on %s", class_getName(object_getClass(e))); });
        objc_setAssociatedObject(e, kPassCB, self, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(e, kPassDepth, pd.depthAttachment.texture, OBJC_ASSOCIATION_RETAIN);
        MTLStoreAction sa = pd.depthAttachment.storeAction;
        objc_setAssociatedObject(e, kPassStore, @((sa == MTLStoreActionStore || sa == MTLStoreActionStoreAndMultisampleResolve) && pd.depthAttachment.loadAction != MTLLoadActionClear && pd.colorAttachments[0].texture != nil), OBJC_ASSOCIATION_RETAIN);
        enc_probe(e);
    }
    return e;
}
static void hook_cb_class(Class c) {
    static NSMutableSet *done; static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&lock);
    if (!done) done = [NSMutableSet set];
    NSString *k = NSStringFromClass(c);
    if (c && ![done containsObject:k] && g_norig < 16) {
        [done addObject:k];
        orig_t *o = &g_orig[g_norig];
        o->cls = c;
        o->p = (present_imp)swap(c, @selector(presentDrawable:), (IMP)h_present);
        o->at = (present_t_imp)swap(c, @selector(presentDrawable:atTime:), (IMP)h_present_at);
        o->after = (present_t_imp)swap(c, @selector(presentDrawable:afterMinimumDuration:), (IMP)h_present_after);
        o->commit = (commit_imp)swap(c, @selector(commit), (IMP)h_commit);
        if (!o_rce) o_rce = (rce_imp)swap(c, @selector(renderCommandEncoderWithDescriptor:), (IMP)h_rce);
        if (!o_prce) o_prce = (rce_imp)swap(c, @selector(parallelRenderCommandEncoderWithDescriptor:), (IMP)h_prce);
        g_norig++;
        vxprof_install_cb_class(c);
        vxmac_log("Metal: present hook on %s", k.UTF8String);
    }
    pthread_mutex_unlock(&lock);
}

// CAMetalLayer: framebufferOnly kept off (the frame is read by the host), the command buffer class hooked at the
// first drawable
typedef id (*next_imp)(id, SEL);
typedef void (*setbool_imp)(id, SEL, BOOL);
static next_imp o_next;
static setbool_imp o_set_fbo;
static void h_set_fbo(id self, SEL s, BOOL v) { o_set_fbo(self, s, g_hook ? NO : v); }
static id h_next(id self, SEL s) {
    CAMetalLayer *l = self;
    inflight_init(l);
    int permit = 0;
    if (g_inflight) {
        permit = dispatch_semaphore_wait(g_inflight, DISPATCH_TIME_NOW) == 0;
        if (!permit) {
            g_inflight_waits++;
            permit = dispatch_semaphore_wait(g_inflight, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)) == 0;
            if (!permit) g_inflight_timeouts++;   // (a drawable never presented: go on without a permit)
        }
    }
    // One wait before the next drawable, never repeated across the command
    // buffers building that image. Completion permits still protect live buffers.
    if (g_hook) frame_limit_wait();
    if (g_hook && l.framebufferOnly) o_set_fbo(self, @selector(setFramebufferOnly:), NO);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> dev = l.device ?: MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        hook_cb_class([[q commandBuffer] class]);
        hook_cb_class([[q commandBufferWithUnretainedReferences] class]);
        vxmac_log("Metal: first drawable: %.0fx%.0f format %lu", l.drawableSize.width, l.drawableSize.height, (unsigned long)l.pixelFormat);
    });
    vxpipe_frame();
    id d = o_next(self, s);
    if (d) g_cur_tex = ((id<CAMetalDrawable>)d).texture;
    if (permit) { if (d) inflight_acquired(d); else dispatch_semaphore_signal(g_inflight); }
    return d;
}

// ---- CAMetalDisplayLink stand-in -----------------------------------------------------------------------------------
@interface VXDisplayLinkUpdate : NSObject
@property (strong) id<CAMetalDrawable> drawable;
@property CFTimeInterval targetTimestamp, targetPresentationTimestamp;
@end
@implementation VXDisplayLinkUpdate
@end
// (CAMetalDisplayLink's alloc gives one of these: the real link, made on a layer, takes the layer's drawables over
// and would never call back for a layer in no window)
@interface VXMetalDisplayLink : NSObject
@property (weak) id delegate;
@property CAFrameRateRange preferredFrameRateRange;
@property NSInteger preferredFrameLatency;
@property (getter=isPaused) BOOL paused;
@property (readonly) CAMetalLayer *layer;
@end
static double g_host_present_time;
static int g_fake_link;
void vxmtl_displaylink_tick(double t) { g_host_present_time = t; }
@implementation VXMetalDisplayLink { NSTimer *_timer; float _fps; }
- (instancetype)initWithMetalLayer:(CAMetalLayer *)layer {
    if ((self = [super init])) { _layer = layer; _preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60); _preferredFrameLatency = 1; }
    return self;
}
- (void)fire {
    id del = self.delegate;
    if (!del || self.paused) return;
    VXDisplayLinkUpdate *u = [VXDisplayLinkUpdate new];
    u.drawable = [_layer nextDrawable];
    if (!u.drawable) return;
    CFTimeInterval now = CACurrentMediaTime();
    u.targetTimestamp = now + 1.0 / _fps;
    u.targetPresentationTimestamp = g_host_present_time > now ? g_host_present_time : now + 1.0 / _fps;
    g_link_calls++;
    ((void (*)(id, SEL, id, id))objc_msgSend)(del, @selector(metalDisplayLink:needsUpdate:), self, u);
}
- (void)addToRunLoop:(NSRunLoop *)rl forMode:(NSRunLoopMode)mode {
    CAFrameRateRange r = _preferredFrameRateRange;
    _fps = r.preferred > 0 ? r.preferred : r.maximum > 0 ? r.maximum : 60;
    if (_fps > 90) _fps = 90;
    [_timer invalidate];
    __weak VXMetalDisplayLink *w = self;
    _timer = [NSTimer timerWithTimeInterval:1.0 / _fps repeats:YES block:^(NSTimer *t) { (void)t; [w fire]; }];
    [rl addTimer:_timer forMode:mode];
    vxmac_log("QuartzCore: CAMetalDisplayLink stand-in at %.0f Hz (mode %s)", _fps, mode.UTF8String);
}
- (void)removeFromRunLoop:(NSRunLoop *)rl forMode:(NSRunLoopMode)mode { (void)rl; (void)mode; [_timer invalidate]; _timer = nil; }
- (void)invalidate { [_timer invalidate]; _timer = nil; }
@end
typedef id (*alloc_imp)(id, SEL, void *);
__attribute__((ns_returns_retained)) static id h_link_alloc(id self, SEL s, void *zone) {   // (alloc: +1)
 (void)self; (void)s; (void)zone; return [VXMetalDisplayLink alloc]; }


// ---- macOS-only Metal methods (visionOS: the selector is missing, the program's call would throw) -----------------
// Known ones get their macOS meaning for an Apple GPU (no Depth24Stencil8, built in, not low power...); any other
// unrecognised selector on Metal's own classes (device, queue, command buffer, encoders, resources) resolves to a
// method returning 0, logged once ("Metal: not implemented").
static BOOL ret_no(id s, SEL c) { (void)s; (void)c; return NO; }
static NSUInteger ret_zero(id s, SEL c) { (void)s; (void)c; return 0; }
static void mtl_unknown(Class cls, SEL sel) {
    static NSMutableSet *seen; static pthread_mutex_t l = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&l);
    if (!seen) seen = [NSMutableSet set];
    NSString *k = [NSString stringWithFormat:@"%s -%s", class_getName(cls), sel_getName(sel)];
    BOOL fresh = ![seen containsObject:k];
    [seen addObject:k];
    pthread_mutex_unlock(&l);
    if (fresh) vxmac_log("Metal: not implemented: %s (returns 0)", k.UTF8String);
}
// (through forwarding, not +resolveInstanceMethod:, so -respondsToSelector: still answers truthfully)
typedef NSMethodSignature *(*sig_imp)(id, SEL, SEL);
static NSMutableDictionary *g_sig_orig;
static NSMethodSignature *h_sig(id self, SEL s, SEL sel) {
    NSValue *v;
    @synchronized (g_sig_orig) { v = g_sig_orig[NSStringFromClass(object_getClass(self))]; }
    NSMethodSignature *m = v ? ((sig_imp)v.pointerValue)(self, s, sel) : nil;
    if (m) return m;
    mtl_unknown(object_getClass(self), sel);
    return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
static void h_forward(id self, SEL s, NSInvocation *inv) { (void)self; (void)s; id z = nil; [inv setReturnValue:&z]; }
static void catch_all(Class c) {
    if (!c) return;
    if (!g_sig_orig) g_sig_orig = [NSMutableDictionary dictionary];
    NSString *k = NSStringFromClass(c);
    @synchronized (g_sig_orig) {
        if (g_sig_orig[k]) return;
        g_sig_orig[k] = [NSValue valueWithPointer:(void *)class_getMethodImplementation(c, @selector(methodSignatureForSelector:))];
    }
    class_replaceMethod(c, @selector(methodSignatureForSelector:), (IMP)h_sig, "@@::");
    class_replaceMethod(c, @selector(forwardInvocation:), (IMP)h_forward, "v@:@");
}
// The GPU working set the device reports (the game sizes its GPU memory budget from it): VXMAC_GPU_WORKING_SET_MB
// (0, the default: the device's own figure; the device's figure is logged). 4096 in c572f91 garbled the skinned
// characters (vertex explosions in character creation and on every NPC indoors, h10; fine with the device's figure
// in h9): not a default.
typedef uint64_t (*u64_imp)(id, SEL);
static u64_imp o_working_set;
static uint64_t g_working_set;
static uint64_t h_working_set(id self, SEL s) {
    static int once;
    if (!once) {   // (read at the program's first query: the host has set the variable from its arguments by then)
        once = 1;
        const char *e = getenv("VXMAC_GPU_WORKING_SET_MB");
        g_working_set = e && *e ? strtoull(e, NULL, 10) << 20 : 0;
        vxmac_log("Metal: the program asks recommendedMaxWorkingSetSize: %llu MB (device %llu MB)",
                  (unsigned long long)((g_working_set ? g_working_set : o_working_set(self, s)) >> 20), (unsigned long long)(o_working_set(self, s) >> 20));
    }
    return g_working_set ? g_working_set : o_working_set(self, s);
}

// ---- what the program asks the device, and allocations that fail (VXMAC_MTL_WATCH=0: off) ----------------------------
// Each capability query is logged once with the device's answer (supportsFamily: per family, argumentBuffersSupport,
// maxBufferLength, ...); every buffer / heap / texture creation that returns nil is logged with its size and options,
// and the first buffers and heaps of 64 MB or more: what the Mac build relies on that the headset answers differently.
typedef BOOL (*fam_imp)(id, SEL, NSInteger);
typedef NSUInteger (*uint_imp)(id, SEL);
typedef id (*buf_len_imp)(id, SEL, NSUInteger, NSUInteger) __attribute__((ns_returns_retained));
typedef id (*buf_bytes_imp)(id, SEL, const void *, NSUInteger, NSUInteger) __attribute__((ns_returns_retained));
typedef id (*buf_nocopy_imp)(id, SEL, void *, NSUInteger, NSUInteger, id) __attribute__((ns_returns_retained));
typedef id (*obj_imp)(id, SEL, id) __attribute__((ns_returns_retained));
static fam_imp o_fam; static uint_imp o_abs, o_maxbuf;
static buf_len_imp o_buf_len; static buf_bytes_imp o_buf_bytes; static buf_nocopy_imp o_buf_nocopy; static obj_imp o_heap, o_tex;
static _Atomic int g_big_logged;
// (VXMAC_GPU_FAMILY_MAX=1007: Apple families above it answered NO - the M1 Max (Apple7) path the Mac test took, where
//  the characters were right; VXMAC_GPU_FAMILY_MAC=1: Mac1/Mac2 (2001/2002) answered YES as on a Mac)
static BOOL h_fam(id self, SEL s, NSInteger f) {
    BOOL r = o_fam(self, s, f);
    // (read at every call: the first query comes before the host has set the variables - h13's run had none applied)
    const char *e1 = getenv("VXMAC_GPU_FAMILY_MAX"), *e2 = getenv("VXMAC_GPU_FAMILY_MAC");
    long fmax = e1 && *e1 ? atol(e1) : 0; int fmac = e2 && !strcmp(e2, "1");
    if (fmax && f > fmax && f >= 1001 && f < 2000) r = NO;
    if (fmac && (f == 2001 || f == 2002)) r = YES;
    static uint64_t seen[64]; static int n;
    int found = 0; for (int i = 0; i < n; i++) if (seen[i] == (uint64_t)f) found = 1;
    if (!found && n < 64) { seen[n++] = (uint64_t)f; vxmac_log("Metal: query supportsFamily:%ld -> %d", (long)f, r); }
    return r;
}
static NSUInteger h_abs(id self, SEL s) { NSUInteger r = o_abs(self, s); static int once; if (!once++) vxmac_log("Metal: query argumentBuffersSupport -> tier %lu", (unsigned long)r + 1); return r; }
static NSUInteger h_maxbuf(id self, SEL s) { NSUInteger r = o_maxbuf(self, s); static int once; if (!once++) vxmac_log("Metal: query maxBufferLength -> %lu MB", (unsigned long)(r >> 20)); return r; }
static void buf_note(const char *what, id r, NSUInteger len, NSUInteger opts) {
    {   // (each distinct options value once: storage mode (bits 4-7: 0 shared, 1 managed (macOS only), 2 private), cache,
        // hazard tracking: a managed buffer here would need its didModifyRange:, which visionOS does not have)
        static NSUInteger seen[32]; static int n; static pthread_mutex_t l = PTHREAD_MUTEX_INITIALIZER;
        pthread_mutex_lock(&l);
        int f = 0; for (int i = 0; i < n; i++) if (seen[i] == opts) f = 1;
        if (!f && n < 32) seen[n++] = opts;
        pthread_mutex_unlock(&l);
        if (!f) vxmac_log("Metal: %s options %#lx (storage %lu, cache %lu, hazard %lu) first seen, %lu bytes, %s", what, (unsigned long)opts,
                          (unsigned long)((opts >> 4) & 0xf), (unsigned long)(opts & 0xf), (unsigned long)((opts >> 8) & 0x3), (unsigned long)len,
                          r ? [NSStringFromClass([r class]) UTF8String] : "nil");
    }
    { void vxpipe_buf_add(id); if (r) vxpipe_buf_add(r); }   // (h51: the dump's buffers by GPU address)
    if (!r) vxmac_log("Metal: %s %lu bytes options %#lx -> nil", what, (unsigned long)len, (unsigned long)opts);
    else if (len >= (64u << 20) && g_big_logged++ < 40) vxmac_log("Metal: %s %lu MB options %#lx", what, (unsigned long)(len >> 20), (unsigned long)opts);
}
__attribute__((ns_returns_retained)) static id h_buf_len(id self, SEL s, NSUInteger len, NSUInteger o) { id r = o_buf_len(self, s, len, o); buf_note("newBufferWithLength", r, len, o); return r; }
__attribute__((ns_returns_retained)) static id h_buf_bytes(id self, SEL s, const void *b, NSUInteger len, NSUInteger o) { id r = o_buf_bytes(self, s, b, len, o); buf_note("newBufferWithBytes", r, len, o); return r; }
__attribute__((ns_returns_retained)) static id h_buf_nocopy(id self, SEL s, void *b, NSUInteger len, NSUInteger o, id d) {
    id r = o_buf_nocopy(self, s, b, len, o, d);
    buf_note("newBufferWithBytesNoCopy", r, len, o);
    if (r && g_big_logged < 60 && len >= (16u << 20)) { g_big_logged++; vxmac_log("Metal: no-copy buffer at %p, %lu MB", b, (unsigned long)(len >> 20)); }
    return r;
}
__attribute__((ns_returns_retained)) static id h_heap(id self, SEL s, MTLHeapDescriptor *d) {
    id r = o_heap(self, s, d);
    if (!r || (d.size >= (64u << 20) && g_big_logged++ < 40))
        vxmac_log("Metal: newHeap %lu MB storage %lu type %ld hazard %lu -> %s", (unsigned long)(d.size >> 20), (unsigned long)d.storageMode, (long)d.type, (unsigned long)d.hazardTrackingMode, r ? "ok" : "nil");
    return r;
}
__attribute__((ns_returns_retained)) static id h_tex(id self, SEL s, MTLTextureDescriptor *d) {
    id r = o_tex(self, s, d);
    if (!r) vxmac_log("Metal: newTexture %lux%lu format %lu storage %lu usage %#lx -> nil", (unsigned long)d.width, (unsigned long)d.height,
                      (unsigned long)d.pixelFormat, (unsigned long)d.storageMode, (unsigned long)d.usage);
    return r;
}
// (the game's Metal binary archives: its Mac build ships native GPU binaries (staticshadermetalnative*.cache); each
//  archive it opens is logged, and VXMAC_BINARY_ARCHIVES=0 hands it an empty archive instead, so every pipeline is
//  compiled on the headset from the shipped AIR (an A/B for the garbled skinned characters))
typedef id (*arch_imp)(id, SEL, MTLBinaryArchiveDescriptor *, NSError **) __attribute__((ns_returns_retained));
static arch_imp o_arch;
__attribute__((ns_returns_retained)) static id h_arch(id self, SEL s, MTLBinaryArchiveDescriptor *d, NSError **err) {
    const char *e = getenv("VXMAC_BINARY_ARCHIVES");
    int off = e && !strcmp(e, "0");
    NSURL *u = d.url;
    if (off && u) { MTLBinaryArchiveDescriptor *empty = [MTLBinaryArchiveDescriptor new]; d = empty; }
    id r = o_arch(self, s, d, err);
    { void vxpipe_arch_note(id); vxpipe_arch_note(r); }   // (h64: its adds and writes counted)
    vxmac_log("Metal: binary archive %s%s -> %s%s", u ? u.path.UTF8String : "(new)", off && u ? " replaced by an empty one" : "",
              r ? "ok" : "nil", (!r && err && *err) ? [(*err).localizedDescription UTF8String] : "");
    return r;
}
static void watch_device(Class dc) {
    const char *e = getenv("VXMAC_MTL_WATCH");
    if (e && !strcmp(e, "0")) return;
#define SW(sel, h, o) do { Method m = class_getInstanceMethod(dc, @selector(sel)); if (m) o = (__typeof__(o))method_setImplementation(m, (IMP)h); } while (0)
    SW(supportsFamily:, h_fam, o_fam);
    SW(argumentBuffersSupport, h_abs, o_abs);
    SW(maxBufferLength, h_maxbuf, o_maxbuf);
    SW(newBufferWithLength:options:, h_buf_len, o_buf_len);
    SW(newBufferWithBytes:length:options:, h_buf_bytes, o_buf_bytes);
    SW(newBufferWithBytesNoCopy:length:options:deallocator:, h_buf_nocopy, o_buf_nocopy);
    SW(newHeapWithDescriptor:, h_heap, o_heap);
    SW(newTextureWithDescriptor:, h_tex, o_tex);
    SW(newBinaryArchiveWithDescriptor:error:, h_arch, o_arch);
}

static void macos_only_methods(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return;
    Class dc = object_getClass(dev);
    class_addMethod(dc, @selector(isDepth24Stencil8PixelFormatSupported), (IMP)ret_no, "c@:");
    class_addMethod(dc, sel_registerName("isLowPower"), (IMP)ret_no, "c@:");
    class_addMethod(dc, sel_registerName("isHeadless"), (IMP)ret_no, "c@:");
    class_addMethod(dc, sel_registerName("isRemovable"), (IMP)ret_no, "c@:");
    class_addMethod(dc, sel_registerName("location"), (IMP)ret_zero, "Q@:");
    class_addMethod(dc, sel_registerName("locationNumber"), (IMP)ret_zero, "Q@:");
    class_addMethod(dc, sel_registerName("maxTransferRate"), (IMP)ret_zero, "Q@:");
    class_addMethod(dc, sel_registerName("peerGroupID"), (IMP)ret_zero, "Q@:");
    class_addMethod(dc, sel_registerName("peerIndex"), (IMP)ret_zero, "I@:");
    class_addMethod(dc, sel_registerName("peerCount"), (IMP)ret_zero, "I@:");
    catch_all(dc);
    watch_device(dc);
    vxpipe_install_device(dc);   // (h51: always - the libraries' hashes tell the UI pipelines)
    {
        uint64_t real = dev.recommendedMaxWorkingSetSize;
        Method m = class_getInstanceMethod(dc, @selector(recommendedMaxWorkingSetSize));
        if (m) o_working_set = (u64_imp)method_setImplementation(m, (IMP)h_working_set);
        vxmac_log("Metal: device %s, recommendedMaxWorkingSetSize %llu MB", dev.name.UTF8String, (unsigned long long)(real >> 20));
    }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    catch_all(object_getClass(q)); catch_all(object_getClass(cb));
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> b = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    catch_all(object_getClass(t)); catch_all(object_getClass(b));
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.size = 1 << 16; hd.storageMode = MTLStorageModePrivate;
    { id hp = [dev newHeapWithDescriptor:hd]; catch_all(object_getClass(hp)); void vxpipe_install_heap(Class); vxpipe_install_heap(object_getClass(hp)); }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp]; catch_all(object_getClass(re)); [re endEncoding];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; catch_all(object_getClass(ce)); [ce endEncoding];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; catch_all(object_getClass(be)); [be endEncoding];
    {   // (h51: always - setRenderPipelineState tells the UI layers' passes; the dump's other encoder hooks only with it;
        //  the render encoder's endEncoding through h_end)
        vxpipe_install_encoders(object_getClass(re), object_getClass(ce));
        if (!o_end) o_end = (end_imp)method_setImplementation(class_getInstanceMethod(object_getClass(re), @selector(endEncoding)), (IMP)h_end);
        vxprof_install_encoders(object_getClass(re), object_getClass(ce));
    }
    vxmac_log("Metal: macOS-only methods added to %s; catch-all on its device, queue, command buffer, encoders, resources", class_getName(dc));
}

void vxmtl_stats(char *out, unsigned size) {
    pace_init();
    double now = CACurrentMediaTime(), busy_pct = 0; unsigned long cbs;
    pthread_mutex_lock(&g_gpu_lock);
    if (g_gpu_since > 0 && now > g_gpu_since) busy_pct = 100.0 * g_gpu_busy / (now - g_gpu_since);
    cbs = g_gpu_cbs; g_gpu_busy = 0; g_gpu_cbs = 0; g_gpu_since = now;
    pthread_mutex_unlock(&g_gpu_lock);
    char head[512]; snprintf(head, sizeof head, "\"game_gpu_busy_pct\":%.0f,\"game_cbs\":%lu,\"pace_waits\":%lu,\"pace_ms\":%.0f,\"pace_cap_ms\":%.0f,\"pace_warp_ms\":%.0f,\"gpu_cap\":%.2f,\"gpu_cap_half\":%d,\"warp_release\":\"%s\",\"pacing\":\"%s\",\"frame_max_fps\":%.1f,\"pace_frame_ms\":%.0f,\"pace_frame_waits\":%lu,", busy_pct, cbs,
                             atomic_exchange(&g_pace_waits, 0), atomic_exchange(&g_pace_us, 0) / 1e3,
                             atomic_exchange(&g_pace_cap_us, 0) / 1e3, atomic_exchange(&g_pace_warp_us, 0) / 1e3, g_gpu_cap, g_half_on,
                             warp_release_scheduled() ? "scheduled" : "completed",g_frame_pacing ? "frame" : "legacy",g_frame_max_hz,
                             atomic_exchange(&g_pace_frame_us,0)/1e3,atomic_exchange(&g_pace_frame_waits,0));
    size_t hl = strlen(head); if (hl < size) { memcpy(out, head, hl + 1); out += hl; size -= (unsigned)hl; }
    { void vxpipe_ui_stats(char *, unsigned); char w[200]; vxpipe_ui_stats(w, sizeof w); size_t wl = strlen(w); if (wl + 1 < size) { memcpy(out, w, wl); out[wl] = ','; out += wl + 1; size -= (unsigned)(wl + 1); } }
    { char pp[200]; vxprof_stats(pp, sizeof pp); size_t pl = strlen(pp); if (pl && pl + 1 < size) { memcpy(out, pp, pl); out[pl] = ','; out += pl + 1; size -= (unsigned)(pl + 1); } }
    snprintf(out, size, "\"inflight\":%ld,\"inflight_waits\":%lu,\"inflight_timeouts\":%lu,\"held_commits\":%lu,\"presents\":%lu,\"drawable_presents\":%lu,\"dropped\":%lu,\"displaylink_calls\":%lu,\"displaylink\":\"%s\"",
             g_inflight_n, (unsigned long)g_inflight_waits, (unsigned long)g_inflight_timeouts, (unsigned long)g_held_commits, (unsigned long)g_presents, (unsigned long)g_drawable_presents, (unsigned long)g_dropped, (unsigned long)g_link_calls,
             g_fake_link ? "stand-in" : "system");
}

__attribute__((constructor)) static void vxmtl_init(void) {
#if TARGET_OS_VISION
    macos_only_methods();
#else
    if (getenv("VXMAC_MAC_TEST")) macos_only_methods();   // (a Mac A/B of the headset's Metal additions: the same swizzles)
#endif
    Class layer = objc_getClass("CAMetalLayer");
    o_next = (next_imp)swap(layer, @selector(nextDrawable), (IMP)h_next);
    o_set_fbo = (setbool_imp)swap(layer, @selector(setFramebufferOnly:), (IMP)h_set_fbo);
    const char *e = getenv("VXMAC_DISPLAYLINK");
#if TARGET_OS_VISION
    g_fake_link = !e || strcmp(e, "system");
#else
    g_fake_link = e && !strcmp(e, "standin");
#endif
    Class link = objc_getClass("CAMetalDisplayLink");
    if (g_fake_link && link)
        class_replaceMethod(object_getClass(link), @selector(allocWithZone:), (IMP)h_link_alloc, "@@:^v");
}
