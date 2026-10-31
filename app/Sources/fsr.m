// Foveated super-resolution on the Neural Engine (VX Mac, optional module: a build
// without this file runs strength_hooks.m's stand-ins). docs/DESIGN.md "Foveated SR".
// Per game present (host.m, before the presenter's submit): the frame's centre (VXMAC_FSR_CROP of its width, default the
// model's input size in frame pixels, 1:1) is copied by the GPU, in the game's own command buffer, into an IOSurface
// pixel buffer; when that buffer completes, the Core ML model (tools/fsr_model.py: v1 not learned, x2) runs on a serial
// queue, pinned to the CPU and Neural Engine (no GPU: the game has it 93-98 % busy), writing straight into one of three
// IOSurface output buffers (outputBackings) the warp samples as a texture. At most one prediction at a time: a present
// that comes while one runs is skipped (the hit rate). The presenter asks for the detail of the frame it warps
// (vxmac_fsr_detail, by the present's number): only that frame's own result is used, never an older one (no ghosts);
// the warp blends it over the bilinear frame inside its rectangle with a soft ring (warp_core.m vxw_col).
// VXMAC_FSR=1 on (default off until verified on the device); VXMAC_FSR_MODEL=<name> (default vxfsr_512x288, in the
// app's Resources or Documents, .mlmodelc); VXMAC_FSR_CROP=<0.2..0.8> the crop's share of the frame's width (resampled
// to the model's input when it differs). Stats: fsr_ms_mean/max (the Neural Engine's time per frame), fsr_first_ms
// (the load and the device's compile), fsr_ane (the share of the model's ops on the Neural Engine, MLComputePlan),
// fsr_offered/made/skipped_busy/failed, fsr_hits/asks (eyes drawn with the detail / eyes asked).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreML/CoreML.h>
#import <QuartzCore/QuartzCore.h>
#include <pthread.h>
#include <stdatomic.h>

void vxmac_jlog(const char *event, const char *fields);

enum { kIn = 2, kOut = 3 };
static int g_on = -1, g_state;                     // (state: 0 none, 1 loading, 2 ready, -1 failed)
static MLModel *g_model;
static size_t g_iw, g_ih, g_ow, g_oh;
static CVMetalTextureCacheRef g_cache;
static CVPixelBufferRef g_in[kIn], g_out[kOut];
static id<MTLTexture> g_intex[kIn], g_outtex[kOut];
static id<MTLComputePipelineState> g_crop;
static dispatch_queue_t g_q;
static _Atomic int g_busy;
static pthread_mutex_t g_l = PTHREAD_MUTEX_INITIALIZER;
static int g_pub = -1, g_pub_prev = -1; static uint64_t g_pub_seq; static float g_pub_rect[4];
static unsigned long g_offered, g_made, g_skipped, g_failed, g_asks, g_hits;
static double g_ms_sum, g_ms_max, g_first_ms = -1; static float g_ane = -1;
static float g_crop_frac;

int vxmac_fsr_on(void) {
    // (off by default again since h33: its sharper centre was there on ~42 % of the eye's frames only - a rectangle that
    //  popped in and out at the frame's middle showed the picture as a screen; VXMAC_FSR=1 on)
    if (g_on < 0) { const char *e = getenv("VXMAC_FSR"); g_on = !(e && !strcmp(e, "0")); }   // (on again by default, h37: every frame, soft edge)
    return g_on;
}

static CVPixelBufferRef new_pb(size_t w, size_t h) {
    CVPixelBufferRef p = NULL;
    NSDictionary *a = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES };
    return CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)a, &p) == kCVReturnSuccess ? p : NULL;
}
static id<MTLTexture> tex_of(CVPixelBufferRef pb, MTLPixelFormat f) {
    CVMetalTextureRef mt = NULL;
    if (CVMetalTextureCacheCreateTextureFromImage(NULL, g_cache, pb, NULL, f, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &mt) != kCVReturnSuccess) return nil;
    id<MTLTexture> t = CVMetalTextureGetTexture(mt);
    CFRelease(mt);                                  // (the texture keeps the IOSurface; the cache entry is not needed)
    return t;
}

static NSURL *model_url(void) {
    const char *e = getenv("VXMAC_FSR_MODEL");
    NSString *name = e && *e ? @(e) : @"vxfsr_512x288";
    NSURL *u = [[NSBundle mainBundle] URLForResource:name withExtension:@"mlmodelc"];
    if (u) return u;
    NSURL *docs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    u = [docs URLByAppendingPathComponent:[name stringByAppendingString:@".mlmodelc"]];
    return [[NSFileManager defaultManager] fileExistsAtPath:u.path] ? u : nil;
}

// (on the queue: the model loaded (the device compiles it for the Neural Engine the first time), the buffers made)
static void load(id<MTLDevice> dev) {
    double t0 = CACurrentMediaTime();
    NSURL *url = model_url();
    char f[600];
    if (!url) { g_state = -1; vxmac_jlog("fsr", "\"error\":\"no model in the app or Documents\""); return; }
    MLModelConfiguration *cfg = [MLModelConfiguration new];
    cfg.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
    NSError *err = nil;
    MLModel *m = [MLModel modelWithContentsOfURL:url configuration:cfg error:&err];
    if (!m) { g_state = -1; snprintf(f, sizeof f, "\"error\":\"load: %s\"", err.localizedDescription.UTF8String); vxmac_jlog("fsr", f); return; }
    MLImageConstraint *ic = m.modelDescription.inputDescriptionsByName[@"image"].imageConstraint;
    MLImageConstraint *oc = m.modelDescription.outputDescriptionsByName[@"detail"].imageConstraint;
    if (!ic || !oc) { g_state = -1; vxmac_jlog("fsr", "\"error\":\"the model's input/output are not image/detail\""); return; }
    g_iw = ic.pixelsWide; g_ih = ic.pixelsHigh; g_ow = oc.pixelsWide; g_oh = oc.pixelsHigh;
    if (CVMetalTextureCacheCreate(NULL, NULL, dev, NULL, &g_cache) != kCVReturnSuccess) { g_state = -1; return; }
    for (int i = 0; i < kIn; i++) { g_in[i] = new_pb(g_iw, g_ih); g_intex[i] = g_in[i] ? tex_of(g_in[i], MTLPixelFormatBGRA8Unorm) : nil; }
    // (the outputs hold sRGB-encoded values as the game's 8-bit frame does: sampled through sRGB, like the presenter's view)
    for (int i = 0; i < kOut; i++) { g_out[i] = new_pb(g_ow, g_oh); g_outtex[i] = g_out[i] ? tex_of(g_out[i], MTLPixelFormatBGRA8Unorm_sRGB) : nil; }
    for (int i = 0; i < kIn; i++) if (!g_intex[i]) { g_state = -1; vxmac_jlog("fsr", "\"error\":\"input buffers\""); return; }
    for (int i = 0; i < kOut; i++) if (!g_outtex[i]) { g_state = -1; vxmac_jlog("fsr", "\"error\":\"output buffers\""); return; }
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void crop(texture2d<float> f [[texture(0)]], texture2d<float, access::write> o [[texture(1)]],\n"
        "                 constant float4 &r [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
        "    if (g.x >= o.get_width() || g.y >= o.get_height()) return;\n"
        "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
        "    float2 uv = r.xy + (float2(g) + 0.5f) / float2(o.get_width(), o.get_height()) * r.zw;\n"
        "    o.write(float4(f.sample(s, uv, level(0)).rgb, 1), g);\n"
        "}\n";
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
    g_crop = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"crop"] error:&err] : nil;
    if (!g_crop) { g_state = -1; vxmac_jlog("fsr", "\"error\":\"crop kernel\""); return; }
    g_model = m;
    // (a first prediction: the Neural Engine's own preparation, timed apart from the frames)
    MLFeatureValue *fv = [MLFeatureValue featureValueWithPixelBuffer:g_in[0]];
    MLDictionaryFeatureProvider *fp = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ @"image": fv } error:&err];
    MLPredictionOptions *po = [MLPredictionOptions new];
    po.outputBackings = @{ @"detail": (__bridge id)g_out[0] };
    [m predictionFromFeatures:fp options:po error:&err];
    g_first_ms = (CACurrentMediaTime() - t0) * 1e3;
    snprintf(f, sizeof f, "\"ready\":1,\"model\":\"%s\",\"in\":[%zu,%zu],\"out\":[%zu,%zu],\"first_ms\":%.0f,\"crop\":%.3f",
             url.lastPathComponent.UTF8String, g_iw, g_ih, g_ow, g_oh, g_first_ms, g_crop_frac);
    vxmac_jlog("fsr", f);
    g_state = 2;
    // (where its ops run, once: the share of the estimated cost on the Neural Engine)
    [MLComputePlan loadContentsOfURL:url configuration:cfg completionHandler:^(MLComputePlan *plan, NSError *e) {
        (void)e;
        MLModelStructureProgramFunction *fn = plan.modelStructure.program.functions[@"main"];
        double all = 0, ane = 0; unsigned n = 0, nane = 0, ncpu = 0;
        for (MLModelStructureProgramOperation *op in fn.block.operations) {
            MLComputePlanDeviceUsage *u = [plan computeDeviceUsageForMLProgramOperation:op];
            if (!u) continue;
            double w = [plan estimatedCostOfMLProgramOperation:op].weight;
            n++; all += w;
            if ([u.preferredComputeDevice isKindOfClass:[MLNeuralEngineComputeDevice class]]) { nane++; ane += w; }
            else if ([u.preferredComputeDevice isKindOfClass:[MLCPUComputeDevice class]]) ncpu++;
        }
        g_ane = all > 0 ? (float)(ane / all) : (n ? (float)nane / n : 0);
        char l[200];
        snprintf(l, sizeof l, "\"plan\":1,\"ops\":%u,\"ane_ops\":%u,\"cpu_ops\":%u,\"ane_cost_share\":%.2f", n, nane, ncpu, g_ane);
        vxmac_jlog("fsr", l);
    }];
}

void vxmac_fsr_frame(void *cbp, void *texp, uint32_t w, uint32_t h, uint64_t seq) {
    if (!vxmac_fsr_on() || !cbp || !texp || !w || !h) return;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
    id<MTLTexture> frame = (__bridge id<MTLTexture>)texp;
    if (!g_state) {
        g_state = 1;
        g_q = dispatch_queue_create("VX Mac FSR", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        id<MTLDevice> dev = cb.device;
        dispatch_async(g_q, ^{ @autoreleasepool { load(dev); } });
        return;
    }
    if (g_state != 2) return;
    pthread_mutex_lock(&g_l); g_offered++; pthread_mutex_unlock(&g_l);
    int expect = 0;
    if (!atomic_compare_exchange_strong(&g_busy, &expect, 1)) { pthread_mutex_lock(&g_l); g_skipped++; pthread_mutex_unlock(&g_l); return; }
    // the crop: the model's input in frame pixels (1:1), centred; VXMAC_FSR_CROP: that share of the frame's width instead
    if (g_crop_frac == 0) { const char *e = getenv("VXMAC_FSR_CROP"); float c = e && *e ? (float)atof(e) : 0; g_crop_frac = c >= 0.1f && c <= 0.9f ? c : -1; }
    float cw = g_crop_frac > 0 ? g_crop_frac * w : (float)g_iw, ch = cw * (float)g_ih / (float)g_iw;
    if (cw > w) { cw = (float)w; ch = cw * (float)g_ih / (float)g_iw; }
    if (ch > h) { ch = (float)h; cw = ch * (float)g_iw / (float)g_ih; }
    float x0 = floorf((w - cw) * 0.5f), y0 = floorf((h - ch) * 0.5f);
    float r[4] = { x0 / w, y0 / h, cw / w, ch / h };
    static int ni;
    int i = ni; ni = (ni + 1) % kIn;
    if (g_crop_frac < 0 && frame.pixelFormat == MTLPixelFormatBGRA8Unorm && (uint32_t)cw == g_iw && (uint32_t)ch == g_ih) {
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];     // (1:1: a copy, as the presenter's own)
        [b copyFromTexture:frame sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake((NSUInteger)x0, (NSUInteger)y0, 0)
                sourceSize:MTLSizeMake(g_iw, g_ih, 1) toTexture:g_intex[i] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [b endEncoding];
    } else if (frame.usage & MTLTextureUsageShaderRead) {          // (resampled: VXMAC_FSR_CROP, or another format)
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:g_crop];
        [enc setTexture:frame atIndex:0];
        [enc setTexture:g_intex[i] atIndex:1];
        [enc setBytes:r length:sizeof r atIndex:0];
        [enc dispatchThreads:MTLSizeMake(g_iw, g_ih, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [enc endEncoding];
    } else {
        static int told;
        if (!told++) vxmac_jlog("fsr", "\"error\":\"the frame cannot be sampled (not shader-readable) and is not a 1:1 BGRA8 crop\"");
        atomic_store(&g_busy, 0);
        return;
    }
    CVPixelBufferRef in = g_in[i];
    float r0 = r[0], r1 = r[1], r2 = r[2], r3 = r[3];   // (the block takes scalars, not the array)
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status != MTLCommandBufferStatusCompleted) { atomic_store(&g_busy, 0); return; }
        dispatch_async(g_q, ^{ @autoreleasepool {
            // (the output: neither the published one nor the one before it, which compositor frames may still read)
            pthread_mutex_lock(&g_l);
            int o = 0;
            while (o == g_pub || o == g_pub_prev) o++;
            pthread_mutex_unlock(&g_l);
            double t0 = CACurrentMediaTime();
            NSError *err = nil;
            MLDictionaryFeatureProvider *fp = [[MLDictionaryFeatureProvider alloc]
                initWithDictionary:@{ @"image": [MLFeatureValue featureValueWithPixelBuffer:in] } error:&err];
            MLPredictionOptions *po = [MLPredictionOptions new];
            po.outputBackings = @{ @"detail": (__bridge id)g_out[o] };
            id<MLFeatureProvider> res = fp ? [g_model predictionFromFeatures:fp options:po error:&err] : nil;
            double ms = (CACurrentMediaTime() - t0) * 1e3;
            pthread_mutex_lock(&g_l);
            if (res) {
                g_made++; g_ms_sum += ms; if (ms > g_ms_max) g_ms_max = ms;
                g_pub_prev = g_pub; g_pub = o; g_pub_seq = seq; g_pub_rect[0] = r0; g_pub_rect[1] = r1; g_pub_rect[2] = r2; g_pub_rect[3] = r3;
            } else g_failed++;
            pthread_mutex_unlock(&g_l);
            atomic_store(&g_busy, 0);
        } });
    }];
}

int vxmac_fsr_detail(uint64_t seq, void **tex, float rect[4]) {
    if (g_on != 1 || g_state != 2) return 0;
    pthread_mutex_lock(&g_l);
    g_asks++;
    // (h37: every frame - the newest result also for the next 2 presents (the warp moves it with the frame's own sampling;
    //  between consecutive frames the centre changes little), so it no longer pops in and out)
    int ok = g_pub >= 0 && g_pub_seq <= seq && seq - g_pub_seq <= 2;
    if (ok) { *tex = (__bridge void *)g_outtex[g_pub]; memcpy(rect, g_pub_rect, sizeof g_pub_rect); g_hits++; }
    pthread_mutex_unlock(&g_l);
    return ok;
}

uint64_t vxmac_fsr_result_seq(void) { pthread_mutex_lock(&g_l); uint64_t s = g_pub_seq; pthread_mutex_unlock(&g_l); return s; }
void vxmac_fsr_stats(char *out, unsigned size) {
    pthread_mutex_lock(&g_l);
    snprintf(out, size, "\"fsr\":%d,\"fsr_state\":%d,\"fsr_first_ms\":%.0f,\"fsr_ane\":%.2f,\"fsr_offered\":%lu,\"fsr_made\":%lu,\"fsr_skipped_busy\":%lu,"
             "\"fsr_failed\":%lu,\"fsr_ms_mean\":%.1f,\"fsr_ms_max\":%.1f,\"fsr_hits\":%lu,\"fsr_asks\":%lu",
             g_on > 0, g_state, g_first_ms, g_ane, g_offered, g_made, g_skipped, g_failed, g_made ? g_ms_sum / g_made : 0.0, g_ms_max, g_hits, g_asks);
    g_ms_max = 0;
    pthread_mutex_unlock(&g_l);
}
