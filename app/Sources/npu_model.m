// The frame-prediction model on the Neural Engine (VX Mac, "method 3", docs/DESIGN.md). Optional module (
// strength_hooks.m's stand-ins read as off in a build without them). The model runs once per game frame and its output
// reaches the presenter by present number; the warp uses it (vr/warp_core.m vxw_set_interp, vr/xros_vr.m draw_eye_inner):
// the frame moved by the model's cleaned motion to each eye's time, holes from its fill, its conf as the frame's weight.
// Off by default: VXMAC_INTERP=1 on. Model: VXMAC_INTERP_MODEL (default vxinterp_416x240; .mlmodelc in the app's
// Resources or Documents; tools/interp_model.py). Per game present while vr mode drives the camera (host.m, before the
// presenter's submit): the frame's colour, the scene's depth (the presenter's copy) and the game's velocity (velocity.m)
// packed and encoded at the model's input size by one compute pass in the game's own command buffer, into an IOSurface
// pixel buffer (OneComponent16Half, W x 6H planar: the model's x as an MLMultiArray with no copy); when that buffer
// completes, the model runs on a serial queue (CPU + Neural Engine only, never the GPU: the game keeps it busy, and its
// contention and heat put the app at 45 Hz), at most one at a time (a present that comes while one runs is skipped),
// straight into one of three IOSurface outputs (outputBackings) the GPU reads as an R16Float texture W x 6H: fill rgb,
// motion xy (model pixels / 16 per real-frame interval), conf. The presenter asks for the result of the frame it warps
// (vxmac_interp_result by its present number; only that frame's own, never an older one).
// Velocity scale: vel_check's once verified, else VXMAC_INTERP_VEL_K (default -1.05, today's measurement).
// Stats: interp_* (state, first_ms (load + the device's compile), ane cost share, ms mean/p95/max, offered/made/skipped_busy/
// failed, hits/asks, ready_ms (present to result), late (frames whose result came after the warp first asked: late_ms the
// wait), never (frames shown without one)) and the warp's iw_* (xros_vr.m vx_xros_vr_interp_stats).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreML/CoreML.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include "interp_frame.h"
#include "interp_pack.h"

void vxmac_jlog(const char *event, const char *fields);

enum { kIn = 2, kOut = 3 };
static int g_on = -1, g_state;                     // (0 none, 1 loading, 2 ready, -1 failed)
static MLModel *g_model;
static size_t g_w, g_h;
static CVMetalTextureCacheRef g_cache;
static CVPixelBufferRef g_in[kIn], g_out[kOut];
static MLMultiArray *g_inarr[kIn], *g_outarr[kOut];
static id<MTLTexture> g_intex[kIn], g_outtex[kOut];
static id<MTLComputePipelineState> g_pack;
static id<MTLBuffer> g_dummy_buf; static id<MTLTexture> g_dummy_tex;
static dispatch_queue_t g_q;
static _Atomic int g_busy;
static pthread_mutex_t g_l = PTHREAD_MUTEX_INITIALIZER;
static int g_pub = -1, g_pub_prev = -1; static uint64_t g_pub_seq;
static unsigned long g_offered, g_made, g_skipped, g_failed, g_asks, g_hits;
static double g_ms_sum, g_ms_max, g_first_ms = -1; static float g_ane = -1, g_kdef = -1.05f;
static float g_ms_ring[256]; static unsigned g_ms_n;                 // (the last 256 predictions' ms, for the p95)
static double g_ready_sum; static unsigned long g_ready_n;           // (present -> result published)
static uint64_t g_ask_seq; static double g_ask_t0; static int g_ask_hit, g_ask_missed;
static unsigned long g_late, g_never; static double g_late_ms_sum;
// (what the results hold, every 8th one on a 1/16 subsample: conf (mean, share under 0.25), the fill's departure from the
//  input frame, the motion's from the game's (model pixels); g_conf_last for the warp's VXMAC_INTERP_CONF=auto)
static double g_oc_sum, g_oc_low, g_ofill, g_omot, g_omot_in; static unsigned long g_on_px; static float g_conf_last = -1;

int vxmac_interp_on(void) {
    if (g_on < 0) {
        const char *e = getenv("VXMAC_INTERP"); g_on = e && !strcmp(e, "1");
        if ((e = getenv("VXMAC_INTERP_VEL_K")) && *e) g_kdef = (float)atof(e);
    }
    return g_on > 0 && g_state >= 0;
}

static CVPixelBufferRef new_pb16(size_t w, size_t h) {
    CVPixelBufferRef p = NULL;
    NSDictionary *a = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES };
    return CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_OneComponent16Half, (__bridge CFDictionaryRef)a, &p) == kCVReturnSuccess ? p : NULL;
}
static id<MTLTexture> tex_of(CVPixelBufferRef pb) {
    CVMetalTextureRef mt = NULL;
    if (CVMetalTextureCacheCreateTextureFromImage(NULL, g_cache, pb, NULL, MTLPixelFormatR16Float, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &mt) != kCVReturnSuccess) return nil;
    id<MTLTexture> t = CVMetalTextureGetTexture(mt);
    CFRelease(mt);
    return t;
}
static NSURL *model_url(void) {
    const char *e = getenv("VXMAC_INTERP_MODEL");
    NSString *name = e && *e ? @(e) : @"vxinterp_416x240";
    NSURL *u = [[NSBundle mainBundle] URLForResource:name withExtension:@"mlmodelc"];
    if (u) return u;
    NSURL *docs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    u = [docs URLByAppendingPathComponent:[name stringByAppendingString:@".mlmodelc"]];
    return [[NSFileManager defaultManager] fileExistsAtPath:u.path] ? u : nil;
}
static void fail(const char *why) { char f[400]; snprintf(f, sizeof f, "\"error\":\"%s\"", why); vxmac_jlog("interp", f); g_state = -1; }

// (on the queue: the model (the device compiles it for the Neural Engine the first time), the buffers, the kernel)
static void load(id<MTLDevice> dev) {
    double t0 = CACurrentMediaTime();
    NSURL *url = model_url();
    if (!url) return fail("no model in the app or Documents");
    MLModelConfiguration *cfg = [MLModelConfiguration new];
    cfg.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
    NSError *err = nil;
    MLModel *m = [MLModel modelWithContentsOfURL:url configuration:cfg error:&err];
    if (!m) return fail(err.localizedDescription.UTF8String ?: "load");
    NSArray<NSNumber *> *ish = m.modelDescription.inputDescriptionsByName[@"x"].multiArrayConstraint.shape;
    NSArray<NSNumber *> *osh = m.modelDescription.outputDescriptionsByName[@"y"].multiArrayConstraint.shape;
    if (ish.count != 4 || osh.count != 4 || ish[1].intValue != 6 || osh[1].intValue != 6 || ![ish[2] isEqual:osh[2]] || ![ish[3] isEqual:osh[3]])
        return fail("the model's x / y are not (1, 6, H, W)");
    g_h = ish[2].unsignedLongValue; g_w = ish[3].unsignedLongValue;
    if (CVMetalTextureCacheCreate(NULL, NULL, dev, NULL, &g_cache) != kCVReturnSuccess) return fail("texture cache");
    NSArray *shape = @[ @1, @6, @(g_h), @(g_w) ];
    for (int i = 0; i < kIn; i++) {
        g_in[i] = new_pb16(g_w, 6 * g_h); g_intex[i] = g_in[i] ? tex_of(g_in[i]) : nil;
        if (!g_intex[i]) return fail("input buffers");
        g_inarr[i] = [[MLMultiArray alloc] initWithPixelBuffer:g_in[i] shape:shape];
    }
    for (int i = 0; i < kOut; i++) {
        g_out[i] = new_pb16(g_w, 6 * g_h); g_outtex[i] = g_out[i] ? tex_of(g_out[i]) : nil;
        if (!g_outtex[i]) return fail("output buffers");
        g_outarr[i] = [[MLMultiArray alloc] initWithPixelBuffer:g_out[i] shape:shape];
    }
    id<MTLLibrary> lib = [dev newLibraryWithSource:@VXI_PACK_MSL options:nil error:&err];
    g_pack = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"nn_pack"] error:&err] : nil;
    if (!g_pack) return fail("pack kernel");
    g_dummy_buf = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead; g_dummy_tex = [dev newTextureWithDescriptor:td];
    g_model = m;
    // (a first prediction: the Neural Engine's own preparation, timed apart from the frames)
    MLDictionaryFeatureProvider *fp = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ @"x": [MLFeatureValue featureValueWithMultiArray:g_inarr[0]] } error:&err];
    MLPredictionOptions *po = [MLPredictionOptions new];
    po.outputBackings = @{ @"y": g_outarr[0] };
    id<MLFeatureProvider> r = fp ? [m predictionFromFeatures:fp options:po error:&err] : nil;
    if (!r) return fail("first prediction");
    g_first_ms = (CACurrentMediaTime() - t0) * 1e3;
    char f[400];
    snprintf(f, sizeof f, "\"ready\":1,\"model\":\"%s\",\"size\":[%zu,%zu],\"first_ms\":%.0f,\"no_copy\":%d", url.lastPathComponent.UTF8String, g_w, g_h, g_first_ms,
             [r featureValueForName:@"y"].multiArrayValue.pixelBuffer == g_out[0]);
    vxmac_jlog("interp", f);
    g_state = 2;
    [MLComputePlan loadContentsOfURL:url configuration:cfg completionHandler:^(MLComputePlan *plan, NSError *e) {
        (void)e;
        MLModelStructureProgramFunction *fn = plan.modelStructure.program.functions[@"main"];
        double all = 0, ane = 0; unsigned n = 0, nane = 0;
        for (MLModelStructureProgramOperation *op in fn.block.operations) {
            MLComputePlanDeviceUsage *u = [plan computeDeviceUsageForMLProgramOperation:op];
            if (!u) continue;
            double w = [plan estimatedCostOfMLProgramOperation:op].weight;
            n++; all += w;
            if ([u.preferredComputeDevice isKindOfClass:[MLNeuralEngineComputeDevice class]]) { nane++; ane += w; }
        }
        g_ane = all > 0 ? (float)(ane / all) : (n ? (float)nane / n : 0);
        char l[160]; snprintf(l, sizeof l, "\"plan\":1,\"ops\":%u,\"ane_ops\":%u,\"ane_cost_share\":%.2f", n, nane, g_ane);
        vxmac_jlog("interp", l);
    }];
}

void vxmac_interp_frame(void *cbp, void *texp, uint32_t w, uint32_t h, const vxmac_frame_info *fi) {
    if (!vxmac_interp_on() || !cbp || !texp || !fi || !(fi->flags & VXI_VR)) return;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
    id<MTLTexture> frame = (__bridge id<MTLTexture>)texp;
    if (!g_state) {
        g_state = 1;
        g_q = dispatch_queue_create("VX Mac interp", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        id<MTLDevice> dev = cb.device;
        dispatch_async(g_q, ^{ @autoreleasepool { load(dev); } });
        return;
    }
    if (g_state != 2) return;
    if (!(frame.usage & MTLTextureUsageShaderRead)) { fail("the frame is not shader-readable"); return; }
    pthread_mutex_lock(&g_l); g_offered++; pthread_mutex_unlock(&g_l);
    int expect = 0;
    if (!atomic_compare_exchange_strong(&g_busy, &expect, 1)) { pthread_mutex_lock(&g_l); g_skipped++; pthread_mutex_unlock(&g_l); return; }
    static int ni; int i = ni; ni = (ni + 1) % kIn;
    id<MTLBuffer> db = (__bridge id<MTLBuffer>)fi->depth_buf; id<MTLTexture> vt = (__bridge id<MTLTexture>)fi->vel_tex;
    int kok = (fi->flags & VXI_VEL_OK) && fabsf(fi->vel_k[0]) > 0.1f;
    vxi_pack_params p = { (uint32_t)g_w, (uint32_t)g_h, fi->depth_w, fi->depth_h, fi->depth_bpp, db && fi->depth_w ? 1u : 0u, vt ? 1u : 0u,
                          kok ? fi->vel_k[0] : g_kdef, kok ? fi->vel_k[1] : g_kdef };
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:g_pack];
    [enc setTexture:frame atIndex:0]; [enc setTexture:vt ?: g_dummy_tex atIndex:1];
    [enc setBuffer:p.has_d ? db : g_dummy_buf offset:0 atIndex:0];
    [enc setBytes:&p length:sizeof p atIndex:1];
    [enc setTexture:g_intex[i] atIndex:2];
    [enc dispatchThreads:MTLSizeMake(g_w, g_h, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [enc endEncoding];
    uint64_t seq = fi->seq; double t_present = fi->t;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status != MTLCommandBufferStatusCompleted) { atomic_store(&g_busy, 0); return; }
        dispatch_async(g_q, ^{ @autoreleasepool {
            pthread_mutex_lock(&g_l);
            int o = 0;
            while (o == g_pub || o == g_pub_prev) o++;   // (neither the published output nor the one before: eyes may read them)
            pthread_mutex_unlock(&g_l);
            double t0 = CACurrentMediaTime();
            NSError *err = nil;
            MLDictionaryFeatureProvider *fp = [[MLDictionaryFeatureProvider alloc]
                initWithDictionary:@{ @"x": [MLFeatureValue featureValueWithMultiArray:g_inarr[i]] } error:&err];
            MLPredictionOptions *po = [MLPredictionOptions new];
            po.outputBackings = @{ @"y": g_outarr[o] };
            id<MLFeatureProvider> res = fp ? [g_model predictionFromFeatures:fp options:po error:&err] : nil;
            double ms = (CACurrentMediaTime() - t0) * 1e3;
            if (res && g_made % 8 == 0) {
                CVPixelBufferLockBaseAddress(g_out[o], kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(g_in[i], kCVPixelBufferLock_ReadOnly);
                const uint8_t *ob = CVPixelBufferGetBaseAddress(g_out[o]), *ib = CVPixelBufferGetBaseAddress(g_in[i]);
                size_t obr = CVPixelBufferGetBytesPerRow(g_out[o]), ibr = CVPixelBufferGetBytesPerRow(g_in[i]), H = g_h;
                double cs = 0, cl = 0, fd = 0, md = 0, mi = 0; unsigned long n = 0;
                for (size_t y = 0; y < H; y += 4) for (size_t x = 0; x < g_w; x += 4) {
                    #define OV(c) ((float)((const __fp16 *)(ob + ((c) * H + y) * obr))[x])
                    #define IV(c) ((float)((const __fp16 *)(ib + ((c) * H + y) * ibr))[x])
                    float cf = OV(5); if (!isfinite(cf)) continue;
                    cs += cf; cl += cf < 0.25f; fd += (fabsf(OV(0) - IV(0)) + fabsf(OV(1) - IV(1)) + fabsf(OV(2) - IV(2))) / 3;
                    float a = 16 * hypotf(OV(3) - IV(4), OV(4) - IV(5)), b = 16 * hypotf(IV(4), IV(5));
                    if (isfinite(a) && isfinite(b)) { md += a; mi += b; }
                    n++;
                    #undef OV
                    #undef IV
                }
                CVPixelBufferUnlockBaseAddress(g_out[o], kCVPixelBufferLock_ReadOnly); CVPixelBufferUnlockBaseAddress(g_in[i], kCVPixelBufferLock_ReadOnly);
                pthread_mutex_lock(&g_l);
                g_oc_sum += cs; g_oc_low += cl; g_ofill += fd; g_omot += md; g_omot_in += mi; g_on_px += n; if (n) g_conf_last = (float)(cs / n);
                pthread_mutex_unlock(&g_l);
            }
            pthread_mutex_lock(&g_l);
            if (res) { g_made++; g_ms_sum += ms; if (ms > g_ms_max) g_ms_max = ms; g_pub_prev = g_pub; g_pub = o; g_pub_seq = seq;
                       g_ms_ring[g_ms_n++ % 256] = (float)ms; g_ready_sum += CACurrentMediaTime() - t_present; g_ready_n++; }
            else g_failed++;
            pthread_mutex_unlock(&g_l);
            atomic_store(&g_busy, 0);
        } });
    }];
}

int vxmac_interp_result(uint64_t seq, void **tex, uint32_t *w, uint32_t *h) {
    if (g_on != 1 || g_state != 2) return 0;
    pthread_mutex_lock(&g_l);
    g_asks++;
    int ok = g_pub >= 0 && g_pub_seq == seq;
    if (ok) { *tex = (__bridge void *)g_outtex[g_pub]; *w = (uint32_t)g_w; *h = (uint32_t)g_h; g_hits++; }
    double now = CACurrentMediaTime();
    if (seq != g_ask_seq) { if (g_ask_seq && !g_ask_hit) g_never++; g_ask_seq = seq; g_ask_t0 = now; g_ask_hit = 0; g_ask_missed = 0; }
    if (ok && !g_ask_hit) { g_ask_hit = 1; if (g_ask_missed) { g_late++; g_late_ms_sum += (now - g_ask_t0) * 1e3; } }
    if (!ok) g_ask_missed = 1;
    pthread_mutex_unlock(&g_l);
    return ok;
}

static int fcmp(const void *a, const void *b) { float x = *(const float *)a, y = *(const float *)b; return x < y ? -1 : x > y; }

// (the newest checked result's mean conf, -1 before one: the warp's VXMAC_INTERP_CONF=auto)
float vxmac_interp_conf_mean(void) { pthread_mutex_lock(&g_l); float c = g_conf_last; pthread_mutex_unlock(&g_l); return c; }

void vxmac_interp_stats(char *out, unsigned size) {
    pthread_mutex_lock(&g_l);
    unsigned n = g_ms_n < 256 ? g_ms_n : 256; float r[256]; memcpy(r, g_ms_ring, n * sizeof *r);
    qsort(r, n, sizeof *r, fcmp);
    int l = snprintf(out, size, "\"interp\":%d,\"interp_state\":%d,\"interp_first_ms\":%.0f,\"interp_ane\":%.2f,\"interp_offered\":%lu,\"interp_made\":%lu,"
             "\"interp_skipped_busy\":%lu,\"interp_failed\":%lu,\"interp_ms_mean\":%.1f,\"interp_ms_p95\":%.1f,\"interp_ms_max\":%.1f,\"interp_hits\":%lu,\"interp_asks\":%lu,"
             "\"interp_ready_ms\":%.1f,\"interp_late\":%lu,\"interp_late_ms\":%.1f,\"interp_never\":%lu,"
             "\"interp_conf_mean\":%.3f,\"interp_conf_low\":%.2f,\"interp_fill_dev\":%.4f,\"interp_motion_dev_px\":%.2f,\"interp_motion_in_px\":%.2f",
             g_on > 0, g_state, g_first_ms, g_ane, g_offered, g_made, g_skipped, g_failed, g_made ? g_ms_sum / g_made : 0.0, n ? r[(n * 95) / 100 < n ? (n * 95) / 100 : n - 1] : 0.0,
             g_ms_max, g_hits, g_asks, g_ready_n ? g_ready_sum / g_ready_n * 1e3 : 0.0, g_late, g_late ? g_late_ms_sum / g_late : 0.0, g_never,
             g_on_px ? g_oc_sum / g_on_px : -1.0, g_on_px ? g_oc_low / g_on_px : 0.0, g_on_px ? g_ofill / g_on_px : 0.0, g_on_px ? g_omot / g_on_px : 0.0, g_on_px ? g_omot_in / g_on_px : 0.0);
    g_oc_sum = g_oc_low = g_ofill = g_omot = g_omot_in = 0; g_on_px = 0;
    g_ms_max = 0; g_ms_n = 0; g_ready_sum = 0; g_ready_n = 0; g_late = 0; g_late_ms_sum = 0; g_never = 0;
    pthread_mutex_unlock(&g_l);
    void vx_xros_vr_interp_stats(char *, unsigned);
    if (g_on > 0 && l > 0 && (unsigned)l + 2 < size) { out[l] = ','; vx_xros_vr_interp_stats(out + l + 1, size - (unsigned)l - 1); }
}
