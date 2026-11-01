// vxprof.m - the game's GPU time per pass (VXMAC_PASS_PROFILE=1; off when unset: nothing below is installed or run)
//
// Where do the game's ~60-80 ms of GPU time a frame go? Every few seconds a window of consecutive frames is sampled:
// each encoder the game makes on its command buffers (render, parallel render, compute, blit, acceleration structure)
// gets Metal's timestamp counters at its stage boundaries (Apple GPUs: start / end of the vertex and the fragment stage
// of a render pass, start / end of a compute / blit pass; MTLCounterSamplingPointAtStageBoundary - per draw or per
// dispatch is not supported there). The game's encoder calls are answered as before: a render pass descriptor is
// copied with a sample buffer attachment added (the game's own descriptor is not changed), computeCommandEncoder /
// computeCommandEncoderWithDispatchType: / blitCommandEncoder / accelerationStructureCommandEncoder become their
// ...WithDescriptor: forms with the same dispatch type, plus the attachment. Outside the windows the hooks only pass
// through. Each sampled encoder keeps: its kind, queue, command buffer, attachments (size, format, load / store), the
// pipelines it used (by the FNV-64 hash of their library's bytes - vs_main_/ps_main_/cs_main_ are all alike - the
// same key as VXMAC_PIPE_DUMP's #hash, tools/ui_hashes.py), dispatches and threads (compute).
//
// When all of a frame's command buffers have completed, its timestamps are resolved (ns on Apple GPUs, the same clock
// as GPUStartTime) and each encoder gets: its span, vertex and fragment times (render), and its SHARE: the frame's GPU
// time cut into slices between encoder starts / ends, each slice split evenly among the encoders running in it - on a
// tile GPU consecutive passes overlap (the next pass's vertex stage under the previous one's fragment stage, concurrent
// compute), so spans add up to more than the frame; shares add up to the union of busy time. Written to
// Documents/pass_profile.txt (VXMAC_PASS_PROFILE_FILE: another name; relative = in Documents):
//   PPROF ...                       the run's settings
//   PENC  w<window>.<i> ...         each encoder of a sampled frame, in creation order
//   PFRAME w<window>.<i> ...        that frame: encoders, busy (union of encoder spans), command buffers' busy, by kind
//   PTOP  w<window> ...             the window's encoders grouped by signature (kind + attachments + pipelines),
//                                   by share per frame, the heaviest first
// and a summary line in the host's log per window ("Metal: pass profile ..."), stats pp_*. tools/pass_profile.py reads
// the file. VXMAC_PASS_PROFILE=1 alternates overlap windows (as the game runs) with serial ones (each pass alone,
// see tag()); =overlap / =serial: one kind only. VXMAC_PASS_PROFILE_EVERY (s, default 5; 0 = every frame), _FRAMES (frames per window, default 5: the first is a lead-in, see process_window), _MAX
// (windows, default 240). Our own GPU work is sampled too and marked ours (see alloc_rec).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdatomic.h>
#include <dlfcn.h>
#include "vxmac.h"
#include "vxprof.h"

int vxprof_live;                           // (read by vxmtl.m / vxpipe.m before calling in: 1 while a window samples)
static int g_on = -1;                      // (VXMAC_PASS_PROFILE)
static double g_every = 5; static unsigned g_frames = 5, g_max_windows = 240;
static FILE *g_f; static pthread_mutex_t g_fl = PTHREAD_MUTEX_INITIALIZER;
static id<MTLCounterSet> g_ts; static id<MTLDevice> g_dev; static NSUInteger g_sb_n = 4096;
static dispatch_queue_t g_q;               // (resolution and writing, off the GPU's completion threads)
static const void *kKey = &kKey, *kRec = &kRec, *kCBF = &kCBF;

static void fout(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void fout(const char *fmt, ...) {
    if (!g_f) return;
    va_list ap; va_start(ap, fmt);
    pthread_mutex_lock(&g_fl); vfprintf(g_f, fmt, ap); fputc('\n', g_f); pthread_mutex_unlock(&g_fl);
    va_end(ap);
}
int vxprof_on(void) {
    if (g_on < 0) { const char *e = getenv("VXMAC_PASS_PROFILE"); g_on = e && *e && strcmp(e, "0") ? 1 : 0; }
    return g_on;
}

// ---- pipelines' keys (vxpipe.m render_note / compute_note): 'f' fragment, 'v' vertex (no fragment), 'k' kernel --------
// (a VXPKey associated with the pipeline: its function's library hash (64 bits) and the kind)
typedef struct { uint64_t h; char kind; } pkey;
@interface VXPKey : NSObject { @public uint64_t h; char kind; }
@end
@implementation VXPKey
@end
void vxprof_pipe_key(id p, NSString *hash, char kind) {
    if (!p || vxprof_on() != 1) return;
    VXPKey *k = [VXPKey new]; k->kind = kind; k->h = hash.length ? strtoull(hash.UTF8String, NULL, 16) : 0;
    objc_setAssociatedObject(p, kKey, k, OBJC_ASSOCIATION_RETAIN);
}

// ---- frames and their encoders -------------------------------------------------------------------------------------
#define MAXP 12
typedef struct {
    char kind;                 // R render, P parallel render, C compute, B blit, A acceleration structure
    int ours;                  // (ours: the compositor's queue ("VX Mac ..."), or encoded by the host inside a hook (vxprof_ours))
    unsigned q, cb;            // (the frame's queue / command buffer numbers)
    unsigned buf, base;        // (sample buffer, first sample index: R/P 4 samples, others 2)
    char att[200];             // (attachments)
    char label[48];
    pkey pipes[MAXP]; unsigned npipes, pipe_sets, more_pipes;
    unsigned dispatches, indirect; double threads;
    uint64_t t[4];             // (resolved)
} prec;
@interface VXPFrame : NSObject {
@public
    pthread_mutex_t l;
    unsigned window, frame, gframe, nrec, cap, nsb, used[8], ncb; prec *recs;
    id<MTLCounterSampleBuffer> sb[8];
    void *qs[16]; unsigned nq;
    double cb_t[512][2]; _Atomic unsigned ncbt;
    _Atomic int pending;       // (1 while open + command buffers not yet completed)
    double t_cpu; int driving, serial;   // (serial: this frame's encoders ran one after another within each command buffer)
}
@end
@implementation VXPFrame
- (instancetype)init { if ((self = [super init])) { pthread_mutex_init(&l, NULL); cap = 512; recs = calloc(cap, sizeof(prec)); atomic_store(&pending, 1); } return self; }
- (void)dealloc { free(recs); pthread_mutex_destroy(&l); }
@end
@interface VXPCb : NSObject { @public void *f; unsigned n; id<MTLFence> fence; int fenced; }   // (on a command buffer: the frame it counts in, its number; serial mode's fence and whether an earlier encoder updated it)
@end
@implementation VXPCb
@end
@interface VXPEncRef : NSObject { @public VXPFrame *f; unsigned i; VXPCb *cb; char kind; }   // (associated with a sampled encoder)
@end
@implementation VXPEncRef
@end

static VXPFrame *g_cur;                    // (the frame being sampled, under g_cl)
static pthread_mutex_t g_cl = PTHREAD_MUTEX_INITIALIZER;
static unsigned g_window, g_win_left, g_frame_n; static double g_next_at; static int g_mode;   // (g_mode 0 alternate, 1 overlap only, 2 serial only)
static _Atomic unsigned long g_st_frames, g_st_encs, g_st_dropped; static double g_st_busy, g_st_span; static pthread_mutex_t g_stl = PTHREAD_MUTEX_INITIALIZER;
static NSMutableArray<id<MTLCounterSampleBuffer>> *g_pool;

static id<MTLCounterSampleBuffer> sb_get(void) {
    @synchronized (g_pool) { if (g_pool.count) { id b = g_pool.lastObject; [g_pool removeLastObject]; return b; } }
    MTLCounterSampleBufferDescriptor *d = [MTLCounterSampleBufferDescriptor new];
    d.counterSet = g_ts; d.sampleCount = g_sb_n; d.storageMode = MTLStorageModeShared; d.label = @"VX Mac pass profile";
    NSError *e = nil; id b = [g_dev newCounterSampleBufferWithDescriptor:d error:&e];
    if (!b) vxmac_log("Metal: pass profile: no sample buffer (%s)", e.localizedDescription.UTF8String);
    return b;
}
static void finish(VXPFrame *f);
static void frame_release(VXPFrame *f) { if (atomic_fetch_sub(&f->pending, 1) == 1) dispatch_async(g_q, ^{ finish(f); }); }

// (our own GPU work is sampled too - the compositor's queue, and what the host encodes into the game's command buffers
//  from the present / pass / target hooks and the UI capture (vxmtl.m brackets those calls with vxprof_ours) - so the
//  sweep shares the GPU's time with it (the warp contends with the game) and the game's own time is told apart)
static __thread int tl_ours;
void vxprof_ours(int d) { tl_ours += d; }
// a sample range in the current frame for an encoder on cb (nil when not sampling or out of room)
static VXPFrame *alloc_rec(id cb, char kind, unsigned ns, unsigned *ri, id<MTLCounterSampleBuffer> *sb, unsigned *base) {
    pthread_mutex_lock(&g_cl); VXPFrame *f = g_cur; if (f) atomic_fetch_add(&f->pending, 1); pthread_mutex_unlock(&g_cl);
    if (!f) return nil;   // (the reference taken above keeps the frame from finishing while this runs)
    id<MTLCommandQueue> q = ((id<MTLCommandBuffer>)cb).commandQueue;
    int ours = tl_ours > 0 || [q.label hasPrefix:@"VX Mac"];
    VXPCb *ct = objc_getAssociatedObject(cb, kCBF);
    int fresh_cb = !ct || ct->f != (__bridge void *)f;
    VXPFrame *ok = nil;
    pthread_mutex_lock(&f->l);
    if (f->nsb == 0 || f->used[f->nsb - 1] + ns > g_sb_n) {
        if (f->nsb < 8) { id b = sb_get(); if (b) { f->sb[f->nsb] = b; f->used[f->nsb] = 0; f->nsb++; } }
    }
    if (f->nsb && f->used[f->nsb - 1] + ns <= g_sb_n) {
        if (f->nrec == f->cap) { f->cap *= 2; f->recs = realloc(f->recs, f->cap * sizeof(prec)); }
        unsigned i = f->nrec++;
        prec *r = &f->recs[i]; memset(r, 0, sizeof *r);
        r->kind = kind; r->ours = ours; r->buf = f->nsb - 1; r->base = f->used[f->nsb - 1]; f->used[f->nsb - 1] += ns;
        unsigned qi = 0; for (; qi < f->nq; qi++) if (f->qs[qi] == (__bridge void *)q) break;
        if (qi == f->nq && f->nq < 16) f->qs[f->nq++] = (__bridge void *)q;
        r->q = qi;
        if (fresh_cb) { ct = [VXPCb new]; ct->f = (__bridge void *)f; ct->n = f->ncb++; }
        r->cb = ct->n;
        *ri = i; *sb = f->sb[r->buf]; *base = r->base; ok = f;
    } else atomic_fetch_add(&g_st_dropped, 1);
    pthread_mutex_unlock(&f->l);
    if (ok && fresh_cb) {   // (the command buffer counted once for this frame; its completion releases it)
        objc_setAssociatedObject(cb, kCBF, ct, OBJC_ASSOCIATION_RETAIN);
        atomic_fetch_add(&f->pending, 1);
        [(id<MTLCommandBuffer>)cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
            unsigned k = atomic_fetch_add(&f->ncbt, 1);
            if (k < 512) { f->cb_t[k][0] = c.GPUStartTime; f->cb_t[k][1] = c.GPUEndTime; }
            frame_release(f);
        }];
    }
    frame_release(f);
    return ok;
}
// (serial mode, VXMAC_PASS_PROFILE=1 every other window / =serial: each sampled render / compute / blit encoder waits for
//  the one before it IN THE SAME command buffer (an MTLFence updated at its end, waited at the next one's start), so
//  each pass's time is its own, not shared with its neighbours. Only within one command buffer: its encoders run in
//  encoding order on one queue, so a wait there can never wait on work submitted later (across command buffers it
//  could: never done). Adds ordering only; the game's own hazard tracking and barriers are untouched.)
static void tag(id enc, id cb, VXPFrame *f, unsigned i, char kind) {
    VXPEncRef *r = [VXPEncRef new]; r->f = f; r->i = i; r->kind = kind;
    pthread_mutex_lock(&f->l); int ours = f->recs[i].ours; pthread_mutex_unlock(&f->l);
    if (f->serial && !ours && kind != 'P' && kind != 'A') {   // (never on our own work: the warp's timing is not changed)
        VXPCb *ct = objc_getAssociatedObject(cb, kCBF);
        if (ct && ct->f == (__bridge void *)f) {
            r->cb = ct;
            if (!ct->fence) ct->fence = [g_dev newFence];
            if (ct->fenced) {
                if (kind == 'R') [(id<MTLRenderCommandEncoder>)enc waitForFence:ct->fence beforeStages:MTLRenderStageVertex];
                else if (kind == 'C') [(id<MTLComputeCommandEncoder>)enc waitForFence:ct->fence];
                else if (kind == 'B') [(id<MTLBlitCommandEncoder>)enc waitForFence:ct->fence];
            }
        }
    }
    objc_setAssociatedObject(enc, kRec, r, OBJC_ASSOCIATION_RETAIN);
}
int vxprof_enabled;   // (1 once the profile is on: vxmtl.m's render endEncoding calls vxprof_end)
void vxprof_end(id enc) {   // (before the encoder's own endEncoding)
    VXPEncRef *r = objc_getAssociatedObject(enc, kRec);
    if (!r || !r->cb || !r->cb->fence) return;
    if (r->kind == 'R') [(id<MTLRenderCommandEncoder>)enc updateFence:r->cb->fence afterStages:MTLRenderStageFragment];
    else if (r->kind == 'C') [(id<MTLComputeCommandEncoder>)enc updateFence:r->cb->fence];
    else if (r->kind == 'B') [(id<MTLBlitCommandEncoder>)enc updateFence:r->cb->fence];
    else return;
    r->cb->fenced = 1; r->cb = nil;
}
static const char *fmt_s(MTLPixelFormat p, char *b) { snprintf(b, 8, "%lu", (unsigned long)p); return b; }
static char la_c(MTLLoadAction a) { return a == MTLLoadActionClear ? 'C' : a == MTLLoadActionLoad ? 'L' : 'D'; }
static char sa_c(MTLStoreAction a) { return a == MTLStoreActionStore ? 'S' : a == MTLStoreActionDontCare ? 'D' : a == MTLStoreActionUnknown ? 'U' : 'R'; }
static void att_str(MTLRenderPassDescriptor *pd, char *o, size_t n) {
    o[0] = 0; char b[8];
    for (int i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *c = pd.colorAttachments[i]; id<MTLTexture> t = c.texture;
        if (!t) continue;
        size_t k = strlen(o);
        snprintf(o + k, n - k, "%sc%d:%lux%lu/%s/%c%c", k ? "," : "", i, (unsigned long)t.width >> c.level, (unsigned long)t.height >> c.level, fmt_s(t.pixelFormat, b), la_c(c.loadAction), sa_c(c.storeAction));
    }
    id<MTLTexture> d = pd.depthAttachment.texture;
    if (d) { size_t k = strlen(o); snprintf(o + k, n - k, "%sd:%lux%lu/%s/%c%c", k ? "," : "", (unsigned long)d.width, (unsigned long)d.height, fmt_s(d.pixelFormat, b), la_c(pd.depthAttachment.loadAction), sa_c(pd.depthAttachment.storeAction)); }
    id<MTLTexture> s = pd.stencilAttachment.texture;
    if (s && s != d) { size_t k = strlen(o); snprintf(o + k, n - k, "%ss:%lux%lu/%s", k ? "," : "", (unsigned long)s.width, (unsigned long)s.height, fmt_s(s.pixelFormat, b)); }
    if (pd.renderTargetArrayLength > 1) { size_t k = strlen(o); snprintf(o + k, n - k, ",layers%lu", (unsigned long)pd.renderTargetArrayLength); }
    if (!o[0]) { snprintf(o, n, "none:%lux%lu", (unsigned long)pd.renderTargetWidth, (unsigned long)pd.renderTargetHeight); }
}
static int free_slot(id arr) {   // (an attachment index the game left free, 0-3)
    for (int i = 0; i < 4; i++) if (![arr[i] sampleBuffer]) return i;
    return -1;
}

// ---- render passes (vxmtl.m h_rce / h_prce, only while vxprof_live) ------------------------------------------------
typedef struct { void *f, *cb; unsigned i; char kind; } vxprof_ctx;   // (f retained until the encoder is tagged)
MTLRenderPassDescriptor *vxprof_render_pd(id cb, MTLRenderPassDescriptor *pd, void **ctx, int parallel) {
    *ctx = NULL;
    if (!pd) return pd;
    int slot = free_slot(pd.sampleBufferAttachments);
    if (slot < 0) return pd;
    unsigned i, base; id<MTLCounterSampleBuffer> sb = nil;
    VXPFrame *f = alloc_rec(cb, parallel ? 'P' : 'R', 4, &i, &sb, &base);
    if (!f) return pd;
    MTLRenderPassDescriptor *c = [pd copy];   // (the game's own descriptor stays as it made it)
    MTLRenderPassSampleBufferAttachmentDescriptor *a = c.sampleBufferAttachments[slot];
    a.sampleBuffer = sb; a.startOfVertexSampleIndex = base; a.endOfVertexSampleIndex = base + 1;
    a.startOfFragmentSampleIndex = base + 2; a.endOfFragmentSampleIndex = base + 3;
    char att[200]; att_str(pd, att, sizeof att);
    pthread_mutex_lock(&f->l); memcpy(f->recs[i].att, att, sizeof att); pthread_mutex_unlock(&f->l);
    vxprof_ctx *x = malloc(sizeof *x); x->f = (__bridge_retained void *)f; x->cb = (__bridge void *)cb; x->i = i; x->kind = parallel ? 'P' : 'R'; *ctx = x;
    return c;
}
void vxprof_render_enc(id enc, void *ctx) {
    if (!ctx) return;
    vxprof_ctx *x = ctx; VXPFrame *f = (__bridge_transfer VXPFrame *)x->f; id cb = (__bridge id)x->cb; unsigned i = x->i; char kind = x->kind; free(x);
    if (enc) tag(enc, cb, f, i, kind);
    else { pthread_mutex_lock(&f->l); f->recs[i].kind = 'x'; pthread_mutex_unlock(&f->l); }
}

// ---- pipelines and dispatches of a sampled encoder -----------------------------------------------------------------
static void note_pipe(id enc, id p) {
    VXPEncRef *r = objc_getAssociatedObject(enc, kRec);
    if (!r) return;
    VXPKey *k = p ? objc_getAssociatedObject(p, kKey) : nil;
    VXPFrame *f = r->f;
    pthread_mutex_lock(&f->l);
    prec *x = &f->recs[r->i];
    if (!x->pipe_sets++ && !x->label[0]) { NSString *lab = [(id<MTLCommandEncoder>)enc label]; if (lab.length) strlcpy(x->label, lab.UTF8String, sizeof x->label); }
    uint64_t h = k ? k->h : 0; char kind = k ? k->kind : '?';
    int seen = 0; for (unsigned j = 0; j < x->npipes; j++) if (x->pipes[j].h == h && x->pipes[j].kind == kind) { seen = 1; break; }
    if (!seen) { if (x->npipes < MAXP) { x->pipes[x->npipes].h = h; x->pipes[x->npipes].kind = kind; x->npipes++; } else x->more_pipes++; }
    pthread_mutex_unlock(&f->l);
}
void vxprof_pipe(id enc, id p) { if (vxprof_live) note_pipe(enc, p); }   // (vxpipe.m h_rps)
static void note_dispatch(id enc, double threads, int indirect) {
    VXPEncRef *r = objc_getAssociatedObject(enc, kRec);
    if (!r) return;
    pthread_mutex_lock(&r->f->l); prec *x = &r->f->recs[r->i]; x->dispatches++; x->threads += threads; if (indirect) x->indirect++; pthread_mutex_unlock(&r->f->l);
}

// (per class: the originals, for classes the game's encoders and command buffers come from)
typedef void (*cps_imp)(id, SEL, id);
typedef void (*dtg_imp)(id, SEL, MTLSize, MTLSize);
typedef void (*dind_imp)(id, SEL, id, NSUInteger, MTLSize);
typedef struct { Class c; cps_imp cps; dtg_imp dtg, dth; dind_imp dind; } enc_orig;
static enc_orig g_eo[16]; static int g_neo; static pthread_mutex_t g_eol = PTHREAD_MUTEX_INITIALIZER;
static const enc_orig *eo_of(id self) {
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c))
        for (int i = 0; i < g_neo; i++) if (g_eo[i].c == c) return &g_eo[i];
    return NULL;
}
static void h_cps(id self, SEL s, id p) { const enc_orig *o = eo_of(self); if (o && o->cps) o->cps(self, s, p); if (vxprof_live) note_pipe(self, p); }
static void h_dtg(id self, SEL s, MTLSize g, MTLSize t) { const enc_orig *o = eo_of(self); if (o && o->dtg) o->dtg(self, s, g, t); if (vxprof_live) note_dispatch(self, (double)g.width * g.height * g.depth * t.width * t.height * t.depth, 0); }
static void h_dth(id self, SEL s, MTLSize g, MTLSize t) { const enc_orig *o = eo_of(self); if (o && o->dth) o->dth(self, s, g, t); if (vxprof_live) note_dispatch(self, (double)g.width * g.height * g.depth, 0); }
static void h_dind(id self, SEL s, id b, NSUInteger off, MTLSize t) { const enc_orig *o = eo_of(self); if (o && o->dind) o->dind(self, s, b, off, t); if (vxprof_live) note_dispatch(self, 0, 1); }
static IMP swap_on(Class c, SEL s, IMP n) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) return NULL;
    if (method_getImplementation(m) == n) return NULL;   // (inherited from a class already hooked: that one answers)
    if (!class_addMethod(c, s, n, method_getTypeEncoding(m))) return method_setImplementation(class_getInstanceMethod(c, s), n);
    return method_getImplementation(m);
}
typedef void (*end_imp)(id, SEL);
typedef struct { Class c; end_imp end; } end_orig;
static end_orig g_endo[16]; static int g_nendo;
static void h_xend(id self, SEL s) {
    vxprof_end(self);
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c))
        for (int i = 0; i < g_nendo; i++) if (g_endo[i].c == c) { if (g_endo[i].end) g_endo[i].end(self, s); return; }
}
static void hook_end_class(Class c) {   // (compute / blit encoders' endEncoding, for serial mode's fence)
    if (!c) return;
    pthread_mutex_lock(&g_eol);
    int f = 0; for (int i = 0; i < g_nendo; i++) if (g_endo[i].c == c) f = 1;
    if (!f && g_nendo < 16) {
        g_endo[g_nendo].c = c; g_endo[g_nendo].end = (end_imp)swap_on(c, @selector(endEncoding), (IMP)h_xend);
        for (Class sc = class_getSuperclass(c); sc && !g_endo[g_nendo].end; sc = class_getSuperclass(sc))
            for (int i = 0; i < g_nendo; i++) if (g_endo[i].c == sc && g_endo[i].end) { g_endo[g_nendo].end = g_endo[i].end; break; }
        g_nendo++;
    }
    pthread_mutex_unlock(&g_eol);
}
static void hook_compute_class(Class c) {
    if (!c) return;
    pthread_mutex_lock(&g_eol);
    int f = 0; for (int i = 0; i < g_neo; i++) if (g_eo[i].c == c) f = 1;
    if (!f && g_neo < 16) {
        enc_orig *o = &g_eo[g_neo];
        o->c = c;
        o->cps = (cps_imp)swap_on(c, @selector(setComputePipelineState:), (IMP)h_cps);
        o->dtg = (dtg_imp)swap_on(c, @selector(dispatchThreadgroups:threadsPerThreadgroup:), (IMP)h_dtg);
        o->dth = (dtg_imp)swap_on(c, @selector(dispatchThreads:threadsPerThreadgroup:), (IMP)h_dth);
        o->dind = (dind_imp)swap_on(c, @selector(dispatchThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerThreadgroup:), (IMP)h_dind);
        // (a method this class inherits from a class hooked before: that one's original is the one to call)
        for (Class sc = class_getSuperclass(c); sc; sc = class_getSuperclass(sc))
            for (int i = 0; i < g_neo; i++) if (g_eo[i].c == sc) {
                if (!o->cps) o->cps = g_eo[i].cps; if (!o->dtg) o->dtg = g_eo[i].dtg; if (!o->dth) o->dth = g_eo[i].dth; if (!o->dind) o->dind = g_eo[i].dind; }
        g_neo++;
        vxmac_log("Metal: pass profile: compute encoder class %s hooked", class_getName(c));
    }
    pthread_mutex_unlock(&g_eol);
    hook_end_class(c);
}

// ---- compute / blit / acceleration structure encoders: the command buffer's methods -----------------------------------
typedef id (*enc0_imp)(id, SEL);
typedef id (*encdt_imp)(id, SEL, MTLDispatchType);
typedef id (*encd_imp)(id, SEL, id);
typedef struct { Class c; enc0_imp ce, be, ae; encdt_imp cedt; encd_imp ced, bed, aed; } cb_orig;
static cb_orig g_co[16]; static int g_nco; static pthread_mutex_t g_col = PTHREAD_MUTEX_INITIALIZER;
static const cb_orig *co_of(id self) {
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c))
        for (int i = 0; i < g_nco; i++) if (g_co[i].c == c) return &g_co[i];
    return NULL;
}
static id compute_sampled(id self, const cb_orig *o, MTLComputePassDescriptor *d0, MTLDispatchType dt, int has_dt) {
    MTLComputePassDescriptor *d = d0 ? [d0 copy] : [MTLComputePassDescriptor computePassDescriptor];
    if (!d0) d.dispatchType = has_dt ? dt : MTLDispatchTypeSerial;
    int slot = free_slot(d.sampleBufferAttachments);
    unsigned i = 0, base = 0; id<MTLCounterSampleBuffer> sb = nil; VXPFrame *f = nil;
    if (slot >= 0) f = alloc_rec(self, 'C', 2, &i, &sb, &base);
    if (!f) return nil;
    d.sampleBufferAttachments[slot].sampleBuffer = sb;
    d.sampleBufferAttachments[slot].startOfEncoderSampleIndex = base; d.sampleBufferAttachments[slot].endOfEncoderSampleIndex = base + 1;
    id e = o->ced(self, @selector(computeCommandEncoderWithDescriptor:), d);
    if (e) {
        hook_compute_class(object_getClass(e)); tag(e, self, f, i, 'C');
        pthread_mutex_lock(&f->l); snprintf(f->recs[i].att, sizeof f->recs[i].att, "dispatch:%s", d.dispatchType == MTLDispatchTypeConcurrent ? "concurrent" : "serial"); pthread_mutex_unlock(&f->l);
    } else { pthread_mutex_lock(&f->l); f->recs[i].kind = 'x'; pthread_mutex_unlock(&f->l); }
    return e;
}
static id h_ce(id self, SEL s) {
    const cb_orig *o = co_of(self);
    if (vxprof_live && o && o->ced) { id e = compute_sampled(self, o, nil, MTLDispatchTypeSerial, 0); if (e) return e; }
    return o && o->ce ? o->ce(self, s) : nil;
}
static id h_cedt(id self, SEL s, MTLDispatchType dt) {
    const cb_orig *o = co_of(self);
    if (vxprof_live && o && o->ced) { id e = compute_sampled(self, o, nil, dt, 1); if (e) return e; }
    return o && o->cedt ? o->cedt(self, s, dt) : nil;
}
static id h_ced(id self, SEL s, MTLComputePassDescriptor *d) {
    const cb_orig *o = co_of(self);
    if (vxprof_live && o && o->ced && d) { id e = compute_sampled(self, o, d, d.dispatchType, 1); if (e) return e; }
    return o && o->ced ? o->ced(self, s, d) : nil;
}
static id blit_sampled(id self, const cb_orig *o, MTLBlitPassDescriptor *d0) {
    MTLBlitPassDescriptor *d = d0 ? [d0 copy] : [MTLBlitPassDescriptor blitPassDescriptor];
    int slot = free_slot(d.sampleBufferAttachments);
    unsigned i = 0, base = 0; id<MTLCounterSampleBuffer> sb = nil; VXPFrame *f = nil;
    if (slot >= 0) f = alloc_rec(self, 'B', 2, &i, &sb, &base);
    if (!f) return nil;
    d.sampleBufferAttachments[slot].sampleBuffer = sb;
    d.sampleBufferAttachments[slot].startOfEncoderSampleIndex = base; d.sampleBufferAttachments[slot].endOfEncoderSampleIndex = base + 1;
    id e = o->bed(self, @selector(blitCommandEncoderWithDescriptor:), d);
    if (e) { hook_end_class(object_getClass(e)); tag(e, self, f, i, 'B'); } else { pthread_mutex_lock(&f->l); f->recs[i].kind = 'x'; pthread_mutex_unlock(&f->l); }
    return e;
}
static id h_be(id self, SEL s) {
    const cb_orig *o = co_of(self);
    if (vxprof_live && o && o->bed) { id e = blit_sampled(self, o, nil); if (e) return e; }
    return o && o->be ? o->be(self, s) : nil;
}
static id h_bed(id self, SEL s, MTLBlitPassDescriptor *d) {
    const cb_orig *o = co_of(self);
    if (vxprof_live && o && o->bed && d) { id e = blit_sampled(self, o, d); if (e) return e; }
    return o && o->bed ? o->bed(self, s, d) : nil;
}
static id accel_sampled(id self, const cb_orig *o, MTLAccelerationStructurePassDescriptor *d0) {
    MTLAccelerationStructurePassDescriptor *d = d0 ? [d0 copy] : [MTLAccelerationStructurePassDescriptor accelerationStructurePassDescriptor];
    int slot = free_slot(d.sampleBufferAttachments);
    unsigned i = 0, base = 0; id<MTLCounterSampleBuffer> sb = nil; VXPFrame *f = nil;
    if (slot >= 0) f = alloc_rec(self, 'A', 2, &i, &sb, &base);
    if (!f) return nil;
    d.sampleBufferAttachments[slot].sampleBuffer = sb;
    d.sampleBufferAttachments[slot].startOfEncoderSampleIndex = base; d.sampleBufferAttachments[slot].endOfEncoderSampleIndex = base + 1;
    id e = o->aed(self, @selector(accelerationStructureCommandEncoderWithDescriptor:), d);
    if (e) tag(e, self, f, i, 'A'); else { pthread_mutex_lock(&f->l); f->recs[i].kind = 'x'; pthread_mutex_unlock(&f->l); }
    return e;
}
static id h_ae(id self, SEL s) {
    const cb_orig *o = co_of(self);
    if (vxprof_live && o && o->aed) { id e = accel_sampled(self, o, nil); if (e) return e; }
    return o && o->ae ? o->ae(self, s) : nil;
}
static id h_aed(id self, SEL s, MTLAccelerationStructurePassDescriptor *d) {
    const cb_orig *o = co_of(self);
    if (vxprof_live && o && o->aed && d) { id e = accel_sampled(self, o, d); if (e) return e; }
    return o && o->aed ? o->aed(self, s, d) : nil;
}
void vxprof_install_cb_class(Class c) {   // (vxmtl.m hook_cb_class: each command buffer class the game's come from)
    if (vxprof_on() != 1 || !c) return;
    pthread_mutex_lock(&g_col);
    int f = 0; for (int i = 0; i < g_nco; i++) if (g_co[i].c == c) f = 1;
    if (!f && g_nco < 16) {
        cb_orig *o = &g_co[g_nco];
        o->c = c;
        o->ced = (encd_imp)swap_on(c, @selector(computeCommandEncoderWithDescriptor:), (IMP)h_ced);
        o->ce = (enc0_imp)swap_on(c, @selector(computeCommandEncoder), (IMP)h_ce);
        o->cedt = (encdt_imp)swap_on(c, @selector(computeCommandEncoderWithDispatchType:), (IMP)h_cedt);
        o->bed = (encd_imp)swap_on(c, @selector(blitCommandEncoderWithDescriptor:), (IMP)h_bed);
        o->be = (enc0_imp)swap_on(c, @selector(blitCommandEncoder), (IMP)h_be);
        o->aed = (encd_imp)swap_on(c, @selector(accelerationStructureCommandEncoderWithDescriptor:), (IMP)h_aed);
        o->ae = (enc0_imp)swap_on(c, @selector(accelerationStructureCommandEncoder), (IMP)h_ae);
        for (Class sc = class_getSuperclass(c); sc; sc = class_getSuperclass(sc))
            for (int i = 0; i < g_nco; i++) if (g_co[i].c == sc) {
                const cb_orig *p = &g_co[i];
                if (!o->ced) o->ced = p->ced; if (!o->ce) o->ce = p->ce; if (!o->cedt) o->cedt = p->cedt; if (!o->bed) o->bed = p->bed;
                if (!o->be) o->be = p->be; if (!o->aed) o->aed = p->aed; if (!o->ae) o->ae = p->ae; }
        g_nco++;
        vxmac_log("Metal: pass profile: encoders of %s sampled (compute %d/%d/%d, blit %d/%d, accel %d/%d)", class_getName(c),
                  o->ce != NULL, o->cedt != NULL, o->ced != NULL, o->be != NULL, o->bed != NULL, o->ae != NULL, o->aed != NULL);
    }
    pthread_mutex_unlock(&g_col);
}
void vxprof_install_encoders(Class rc, Class cc) {   // (vxmtl.m macos_only_methods: the compute encoder class up front)
    (void)rc;
    if (vxprof_on() != 1) return;
    hook_compute_class(cc);
}

// ---- results -------------------------------------------------------------------------------------------------------
static int valid(uint64_t v) { return v != 0 && v != MTLCounterErrorValue; }
static void sig_of(const prec *r, char *o, size_t n) {   // (signature: kind, attachments, pipelines)
    snprintf(o, n, "%c %s |", r->kind, r->att);
    unsigned np = r->npipes + r->more_pipes;
    if (r->kind == 'R' || r->kind == 'P') {
        if (np <= 3) for (unsigned j = 0; j < r->npipes; j++) { size_t k = strlen(o); snprintf(o + k, n - k, " %c%016llx", r->pipes[j].kind, (unsigned long long)r->pipes[j].h); }
        else { unsigned b = 4; while (b < np && b < 4096) b *= 2; size_t k = strlen(o); snprintf(o + k, n - k, " pipes<=%u", b); }
    } else {
        for (unsigned j = 0; j < r->npipes; j++) { size_t k = strlen(o); snprintf(o + k, n - k, " %c%016llx", r->pipes[j].kind, (unsigned long long)r->pipes[j].h); }
        if (r->more_pipes) { size_t k = strlen(o); snprintf(o + k, n - k, " +%u", r->more_pipes); }
    }
}
typedef struct { double share, span, vtx, frag, threads; unsigned n; char kind; } agg;
static NSMutableDictionary<NSString *, NSValue *> *g_win_agg; static unsigned g_win_agg_frames, g_win_agg_id; static int g_win_agg_serial;
static double g_win_busy, g_win_cbbusy, g_win_kind[6];
static void agg_flush(void) {   // (on g_q)
    if (!g_win_agg.count || !g_win_agg_frames) return;
    NSArray *keys = [g_win_agg keysSortedByValueUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        agg x, y; [a getValue:&x size:sizeof x]; [b getValue:&y size:sizeof y]; return x.share > y.share ? NSOrderedAscending : x.share < y.share ? NSOrderedDescending : NSOrderedSame; }];
    double fr = g_win_agg_frames;
    fout("PWIN w%u mode=%s frames=%u busy_ms=%.2f game_ms=%.2f ours_ms=%.2f cb_busy_ms=%.2f render_ms=%.2f compute_ms=%.2f blit_ms=%.2f accel_ms=%.2f groups=%lu", g_win_agg_id, g_win_agg_serial ? "serial" : "overlap", g_win_agg_frames,
         g_win_busy / fr, (g_win_busy - g_win_kind[4]) / fr, g_win_kind[4] / fr, g_win_cbbusy / fr, g_win_kind[0] / fr, g_win_kind[1] / fr, g_win_kind[2] / fr, g_win_kind[3] / fr, (unsigned long)keys.count);
    char line[1000]; int ll = snprintf(line, sizeof line, "Metal: pass profile w%u (%s): %u frames, GPU busy %.1f ms/frame (game %.1f: render %.1f, compute %.1f, blit %.1f; ours %.1f); top:",
                                       g_win_agg_id, g_win_agg_serial ? "serial" : "overlap", g_win_agg_frames, g_win_busy / fr, (g_win_busy - g_win_kind[4]) / fr, g_win_kind[0] / fr, g_win_kind[1] / fr, g_win_kind[2] / fr, g_win_kind[4] / fr);
    unsigned rank = 0;
    for (NSString *k in keys) {
        agg a; [g_win_agg[k] getValue:&a size:sizeof a];
        if (rank < 40) fout("PTOP w%u mode=%s #%u share_ms=%.3f span_ms=%.3f vtx_ms=%.3f frag_ms=%.3f per_frame=%.2f mthreads=%.3f sig=%s", g_win_agg_id, g_win_agg_serial ? "serial" : "overlap", rank + 1,
                            a.share / fr, a.span / fr, a.vtx / fr, a.frag / fr, a.n / fr, a.threads / fr / 1e6, k.UTF8String);
        if (rank < 8 && ll < (int)sizeof line - 120) {
            // (short: kind, first attachment's size, first pipeline's 8 hex digits)
            const char *s = k.UTF8String; int o5 = !strncmp(s, "ours ", 5); if (o5) s += 5;
            char att[40] = ""; sscanf(s + 2, "%39[^,| ]", att);
            const char *p = strchr(s, '|'); char p8[24] = "";
            if (p && p[1] == ' ' && p[2]) snprintf(p8, sizeof p8, "%.9s", p + 2);
            ll += snprintf(line + ll, sizeof line - ll, " %s%c %s %s %.1f ms (x%.1f);", o5 ? "ours " : "", s[0], att, p8, a.share / fr, a.n / fr);
        }
        rank++;
    }
    fflush(g_f);
    vxmac_log("%s", line);
    [g_win_agg removeAllObjects]; g_win_agg_frames = 0; g_win_busy = g_win_cbbusy = 0; memset(g_win_kind, 0, sizeof g_win_kind);
}
static int cmp_ev(const void *a, const void *b) { const double *x = a, *y = b; return x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : (x[1] < y[1] ? -1 : x[1] > y[1]); }
// (a window's frames are swept together: the GPU runs a frame's first passes while the one before is finishing, and a
//  stage that waits on the frame before (Mac test: a first pass's vertex stage of 15 ms for 3 vertices) must share that
//  time with the work it waits on. The window's first frame can still overlap the unsampled frame before it: it is
//  written (lead=1) but left out of the window's groups (PTOP) and totals (PWIN) when the window has more frames.)
static NSMutableArray<VXPFrame *> *g_wf;   // (the frames of the window being completed, on g_q)
static void process_window(void) {
    NSArray<VXPFrame *> *fs = [g_wf copy]; [g_wf removeAllObjects];
    if (!fs.count) return;
    unsigned nf = (unsigned)fs.count, tot = 0;
    for (VXPFrame *f in fs) tot += f->nrec;
    // events: time, start(1)/end(0), frame, record
    double *ev = malloc(sizeof(double) * 4 * 4 * (tot ? tot : 1)); unsigned ne = 0;
    double **share = calloc(nf, sizeof *share), *busy = calloc(nf, sizeof *busy);
    for (unsigned fi = 0; fi < nf; fi++) {
        VXPFrame *f = fs[fi]; share[fi] = calloc(f->nrec ? f->nrec : 1, sizeof(double));
        for (unsigned i = 0; i < f->nrec; i++) {
            prec *r = &f->recs[i];
            if (r->kind == 'x') continue;
            unsigned np = (r->kind == 'R' || r->kind == 'P') ? 2 : 1;
            for (unsigned k = 0; k < np; k++) {
                uint64_t x = r->t[2 * k], z = r->t[2 * k + 1];
                if (!valid(x) || !valid(z) || z <= x) continue;
                ev[4 * ne] = (double)x; ev[4 * ne + 1] = 1; ev[4 * ne + 2] = fi; ev[4 * ne + 3] = i; ne++;
                ev[4 * ne] = (double)z; ev[4 * ne + 1] = 0; ev[4 * ne + 2] = fi; ev[4 * ne + 3] = i; ne++;
            }
        }
    }
    qsort(ev, ne, 4 * sizeof(double), cmp_ev);   // (ends before starts at the same instant)
    unsigned (*act)[2] = malloc(sizeof(unsigned[2]) * (ne ? ne : 1)); unsigned na = 0; double last = 0;
    for (unsigned k = 0; k < ne; k++) {
        double t = ev[4 * k]; unsigned fi = (unsigned)ev[4 * k + 2], i = (unsigned)ev[4 * k + 3];
        if (na && t > last) { double dt = (t - last) / na; for (unsigned j = 0; j < na; j++) { share[act[j][0]][act[j][1]] += dt; busy[act[j][0]] += dt; } }
        last = t;
        if (ev[4 * k + 1] > 0.5) { act[na][0] = fi; act[na][1] = i; na++; }
        else for (unsigned j = 0; j < na; j++) if (act[j][0] == fi && act[j][1] == i) { act[j][0] = act[na - 1][0]; act[j][1] = act[na - 1][1]; na--; break; }
    }
    if (!g_win_agg) g_win_agg = [NSMutableDictionary dictionary];
    for (unsigned fi = 0; fi < nf; fi++) {
        VXPFrame *f = fs[fi];
        int lead = f->frame == 0 && g_frames > 1, use = !lead;
        unsigned n = f->nrec;
        double t0 = 1e300, t1 = 0;
        for (unsigned i = 0; i < n; i++) { prec *r = &f->recs[i]; if (r->kind == 'x') continue; for (unsigned k = 0; k < 4; k++) if (valid(r->t[k])) { double t = (double)r->t[k]; if (t < t0) t0 = t; if (t > t1) t1 = t; } }
        // (the command buffers' own busy time, merged, for comparison: the gaps are work outside any sampled encoder)
        unsigned nc = atomic_load(&f->ncbt); if (nc > 512) nc = 512;
        double cbb = 0; { double cs[512][2]; memcpy(cs, f->cb_t, nc * sizeof cs[0]); qsort(cs, nc, sizeof cs[0], cmp_ev);
            double end = 0; for (unsigned k = 0; k < nc; k++) { double x = cs[k][0], z = cs[k][1]; if (!(z > x)) continue; if (x < end) x = end; if (z > x) cbb += z - x; if (z > end) end = z; } }
        cbb *= 1e3;   // (s -> ms)
        double kind_ms[6] = {0}, ours_ms = 0;
        if (use) { g_win_agg_id = f->window; g_win_agg_serial = f->serial; g_win_agg_frames++; g_win_busy += busy[fi] / 1e6; g_win_cbbusy += cbb; }
        for (unsigned i = 0; i < n; i++) {
            prec *r = &f->recs[i];
            if (r->kind == 'x') continue;
            int ren = r->kind == 'R' || r->kind == 'P';
            double vt = ren && valid(r->t[0]) && valid(r->t[1]) && r->t[1] > r->t[0] ? (r->t[1] - r->t[0]) / 1e6 : 0;
            double ft = ren && valid(r->t[2]) && valid(r->t[3]) && r->t[3] > r->t[2] ? (r->t[3] - r->t[2]) / 1e6 : 0;
            double a = 1e300, z = 0; unsigned ns = ren ? 4 : 2;
            for (unsigned k = 0; k < ns; k++) if (valid(r->t[k])) { double t = (double)r->t[k]; if (!(k & 1) && t < a) a = t; if ((k & 1) && t > z) z = t; }
            double sp = a < 1e300 && z > a ? (z - a) / 1e6 : 0, sh = share[fi][i] / 1e6;
            char pl[MAXP * 19 + 16] = "";
            for (unsigned j = 0; j < r->npipes; j++) { size_t k = strlen(pl); snprintf(pl + k, sizeof pl - k, "%s%c%016llx", j ? "," : "", r->pipes[j].kind, (unsigned long long)r->pipes[j].h); }
            fout("PENC w%u.%u i%u k=%c%s q%u cb%u start_ms=%.3f span_ms=%.3f vtx_ms=%.3f frag_ms=%.3f share_ms=%.3f sets=%u disp=%u ind=%u mthreads=%.3f label=%s att=%s pipes=%u:%s%s",
                 f->window, f->frame, i, r->kind, r->ours ? " ours=1" : "", r->q, r->cb, a < 1e300 && t0 < 1e300 ? (a - t0) / 1e6 : -1, sp, vt, ft, sh, r->pipe_sets, r->dispatches, r->indirect, r->threads / 1e6,
                 r->label[0] ? r->label : "-", r->att[0] ? r->att : "-", r->npipes + r->more_pipes, pl[0] ? pl : "-", r->more_pipes ? ",..." : "");
            int ki = r->ours ? 4 : ren ? 0 : r->kind == 'C' ? 1 : r->kind == 'B' ? 2 : 3;
            kind_ms[ki] += sh; if (r->ours) ours_ms += sh;
            if (!use) continue;
            g_win_kind[ki] += sh;
            char sg[400]; sig_of(r, sg + (r->ours ? 5 : 0), sizeof sg - 5); if (r->ours) memcpy(sg, "ours ", 5);
            NSString *key = @(sg); agg g = {0};
            NSValue *old = g_win_agg[key]; if (old) [old getValue:&g size:sizeof g];
            g.share += sh; g.span += sp; g.vtx += vt; g.frag += ft; g.threads += r->threads; g.n++; g.kind = r->kind;
            g_win_agg[key] = [NSValue valueWithBytes:&g objCType:@encode(agg)];
        }
        fout("PFRAME w%u.%u mode=%s lead=%d present=%u t=%.2f driving=%d encoders=%u busy_ms=%.3f game_ms=%.3f ours_ms=%.3f span_ms=%.3f cb_busy_ms=%.3f cbs=%u queues=%u render_ms=%.3f compute_ms=%.3f blit_ms=%.3f accel_ms=%.3f",
             f->window, f->frame, f->serial ? "serial" : "overlap", lead, f->gframe, f->t_cpu, f->driving, n, busy[fi] / 1e6, busy[fi] / 1e6 - ours_ms, ours_ms, t1 > t0 ? (t1 - t0) / 1e6 : 0, cbb, nc, f->nq,
             kind_ms[0], kind_ms[1], kind_ms[2], kind_ms[3]);
        pthread_mutex_lock(&g_stl); if (use) { g_st_busy += busy[fi] / 1e6; g_st_span += t1 > t0 ? (t1 - t0) / 1e6 : 0; } pthread_mutex_unlock(&g_stl);
        if (use) { atomic_fetch_add(&g_st_frames, 1); atomic_fetch_add(&g_st_encs, n); }
        free(share[fi]);
    }
    free(share); free(busy); free(ev); free(act);
    agg_flush();
}
static void finish(VXPFrame *f) {   // (on g_q: every command buffer of the frame completed)
    @autoreleasepool {
    for (unsigned b = 0; b < f->nsb; b++) {
        NSData *d = f->used[b] ? [f->sb[b] resolveCounterRange:NSMakeRange(0, f->used[b])] : nil;
        const MTLCounterResultTimestamp *v = d.bytes;
        for (unsigned i = 0; i < f->nrec; i++) {
            prec *r = &f->recs[i];
            if (r->buf != b) continue;
            unsigned ns = (r->kind == 'R' || r->kind == 'P') ? 4 : 2;
            for (unsigned k = 0; k < ns; k++) r->t[k] = (v && r->base + k < d.length / sizeof *v) ? v[r->base + k].timestamp : 0;
        }
        @synchronized (g_pool) { [g_pool addObject:f->sb[b]]; }
        f->sb[b] = nil;
    }
    if (!g_wf) g_wf = [NSMutableArray array];
    if (g_wf.count && g_wf.lastObject->window != f->window) process_window();   // (an earlier window left incomplete)
    [g_wf addObject:f];
    if (f->frame + 1 >= g_frames) process_window();
    }
}

// ---- frame boundary (vxmtl.m: at each present of the game's drawable) ----------------------------------------------
static void setup(void) {
    const char *e;
    if ((e = getenv("VXMAC_PASS_PROFILE_EVERY")) && *e) g_every = atof(e);
    if ((e = getenv("VXMAC_PASS_PROFILE_FRAMES")) && *e && atoi(e) > 0) g_frames = (unsigned)atoi(e);
    if ((e = getenv("VXMAC_PASS_PROFILE_MAX")) && *e && atoi(e) > 0) g_max_windows = (unsigned)atoi(e);
    if ((e = getenv("VXMAC_PASS_PROFILE")) && !strcmp(e, "overlap")) g_mode = 1;
    else if (e && !strcmp(e, "serial")) g_mode = 2;
    g_dev = MTLCreateSystemDefaultDevice();
    if (![g_dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) { vxmac_log("Metal: pass profile: stage-boundary counters not supported: off"); g_on = 0; return; }
    for (id<MTLCounterSet> s in g_dev.counterSets) if ([s.name isEqualToString:MTLCommonCounterSetTimestamp]) g_ts = s;
    if (!g_ts) { vxmac_log("Metal: pass profile: no timestamp counter set: off"); g_on = 0; return; }
    g_pool = [NSMutableArray array];
    { id b = sb_get(); if (!b) { g_sb_n = 2048; b = sb_get(); } if (!b) { g_on = 0; return; } [g_pool addObject:b]; }
    g_q = dispatch_queue_create("VX Mac pass profile", DISPATCH_QUEUE_SERIAL);
    const char *path = getenv("VXMAC_PASS_PROFILE_FILE"); if (!path || !*path) path = "pass_profile.txt";
    NSString *ps = @(path);
    if (![ps isAbsolutePath]) ps = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:ps];
    g_f = fopen(ps.fileSystemRepresentation, "w");
    MTLTimestamp c, gt; [g_dev sampleTimestamps:&c gpuTimestamp:&gt];
    fout("PPROF v1 mode=%s device=%s every_s=%.2f frames=%u max_windows=%u sample_buffer=%lu cpu_ts=%llu gpu_ts=%llu (timestamps ns, GPUStartTime's clock)", g_mode == 0 ? "alternate" : g_mode == 1 ? "overlap" : "serial", g_dev.name.UTF8String,
         g_every, g_frames, g_max_windows, (unsigned long)g_sb_n, (unsigned long long)c, (unsigned long long)gt);
    if (g_f) fflush(g_f);
    vxprof_enabled = 1;
    g_win_left = g_max_windows; g_next_at = CACurrentMediaTime() + (g_every > 0 ? g_every : 0);
    vxmac_log("Metal: pass profile on: %u frames every %.1f s (%u windows at most) to %s", g_frames, g_every, g_max_windows, g_f ? ps.fileSystemRepresentation : "(no file)");
}
void vxprof_frame(void) {
    if (vxprof_on() != 1) return;
    static dispatch_once_t once; dispatch_once(&once, ^{ setup(); });
    if (g_on != 1) return;
    static unsigned left_in_window, wnum; static int (*drv)(void); static int drv_once;
    if (!drv_once++) drv = dlsym(RTLD_DEFAULT, "vx_xros_vr_driving");
    pthread_mutex_lock(&g_cl);
    VXPFrame *old = g_cur; g_cur = nil;
    double now = CACurrentMediaTime();
    g_frame_n++;
    if (!left_in_window && g_win_left && now >= g_next_at) { left_in_window = g_frames; wnum++; g_win_left--; g_next_at = now + g_every; }
    if (left_in_window) {
        VXPFrame *f = [VXPFrame new];
        f->window = wnum; f->frame = g_frames - left_in_window; f->gframe = g_frame_n; f->t_cpu = now; f->serial = g_mode == 2 || (g_mode == 0 && !(wnum & 1)); f->driving = drv ? drv() : -1;
        g_cur = f; left_in_window--;
    }
    g_window = wnum;
    vxprof_live = g_cur != nil;
    pthread_mutex_unlock(&g_cl);
    if (old) frame_release(old);   // (closed: finished when its command buffers have completed)
}
void vxprof_stats(char *out, unsigned n) {
    if (vxprof_on() != 1) { if (n) out[0] = 0; return; }
    unsigned long fr = atomic_exchange(&g_st_frames, 0), en = atomic_exchange(&g_st_encs, 0);
    pthread_mutex_lock(&g_stl); double b = g_st_busy, s = g_st_span; g_st_busy = g_st_span = 0; pthread_mutex_unlock(&g_stl);
    snprintf(out, n, "\"pp_frames\":%lu,\"pp_encoders\":%.0f,\"pp_busy_ms\":%.1f,\"pp_span_ms\":%.1f,\"pp_dropped\":%lu",
             fr, fr ? (double)en / fr : 0, fr ? b / fr : 0, fr ? s / fr : 0, (unsigned long)atomic_exchange(&g_st_dropped, 0));
}
