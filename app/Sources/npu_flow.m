// NPU motion for the presenter's frame prediction (VX Mac, first stage; docs/DESIGN.md "NPU interpolation").
// The Mac game gives no motion vectors (MetalFX temporal is not called with dynamic resolution), so they are made from
// the frames: each presented frame is scaled down (VXMAC_NPU_W, default 320 wide) into an IOSurface pixel buffer in
// the game's own command buffer; when the GPU is done, Vision's optical flow (VNGenerateOpticalFlowRequest, on the
// Neural Engine) runs between it and the frame before, on a serial queue, never more than one at a time (a frame that
// comes while one runs is skipped). The newest flow goes to the presenter as the frame's motion vectors
// (vxmac_vr_glue.m npu_interp_take_scene), which predicts every compositor frame (90 Hz) from the newest real frame
// moved on by its motion (the warp core on the GPU, avp-port's race design: a real frame when there is one, a
// prediction otherwise). VXMAC_NPU=0: off. VXMAC_NPU_SIGN=-1: the flow's direction the other way.
// The request runs on the Neural Engine only (VNRequest setComputeDevice: MLNeuralEngineComputeDevice for every
// stage that has one; h20: on its default devices the first request never finished while the game kept the GPU 98 %
// busy); a stage without a Neural Engine device runs on the CPU (VXMAC_NPU_DEVICE=any: Vision's own choice); a
// request still running after 400 ms is cancelled. The first request's time (the model's preparation) is logged on
// its own. Thinning: a flow for every VXMAC_NPU_EVERY-th frame at most (default 2).
// Stats (vxmac_npu_stats): flows made / frames offered, skipped while busy, mean and worst Neural Engine time, the
// newest flow's mean motion against the image check's measured turn (to verify the direction).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreML/CoreML.h>
#include <pthread.h>

void vxmac_jlog(const char *event, const char *fields);

enum { kSlots = 4 };
static int g_on = -1, g_w, g_h;
static CVMetalTextureCacheRef g_cache;
static CVPixelBufferRef g_pb[kSlots]; static id<MTLTexture> g_pbtex[kSlots];
static int g_next, g_prev = -1;
static dispatch_queue_t g_q;
static id<MTLComputePipelineState> g_scale;
static _Atomic int g_busy;
static pthread_mutex_t g_l = PTHREAD_MUTEX_INITIALIZER;
static id<MTLTexture> g_flow; static uint64_t g_flow_seq, g_taken_seq; static double g_flow_time;
static _Atomic unsigned long g_offered, g_made, g_skipped, g_failed;
static double g_ms_sum, g_ms_max; static float g_mean_dx;
static double g_first_ms = -1; static char g_device[48] = "?"; static _Atomic unsigned long g_cancelled;
static int g_every = 2;
float vxmac_image_turn_total(void);   // (host.m: the image check's cumulative measured turn, degrees)
static float g_img_at[kSlots]; static unsigned g_cmp_n, g_cmp_same, g_cmp_logged;   // (VXMAC_NPU_EVERY: a flow for every n-th frame at most - thinning)

int vxmac_npu_on(void) {
    // (off by default since h24: Vision's optical flow cannot run on the Neural Engine on visionOS ("unsupported
    //  compute device"), and on the GPU it cost the game frames; VXMAC_NPU=1 runs it on the CPU as a fallback)
    if (g_on < 0) { const char *e = getenv("VXMAC_NPU"); g_on = e && !strcmp(e, "1"); }
    return g_on;
}

static int setup(id<MTLDevice> dev, uint32_t w, uint32_t h) {
    const char *e = getenv("VXMAC_NPU_W");
    g_w = e && *e ? atoi(e) : 320; if (g_w < 64) g_w = 64;
    g_h = (int)((double)g_w * h / w + 0.5) & ~1;
    if (CVMetalTextureCacheCreate(NULL, NULL, dev, NULL, &g_cache) != kCVReturnSuccess) return 0;
    NSDictionary *attrs = @{ (id)kCVPixelBufferMetalCompatibilityKey: @YES, (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    NSDictionary *tattrs = @{ (id)kCVMetalTextureUsage: @(MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite) };
    for (int i = 0; i < kSlots; i++) {
        if (CVPixelBufferCreate(NULL, g_w, g_h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &g_pb[i]) != kCVReturnSuccess) return 0;
        CVMetalTextureRef mt = NULL;
        if (CVMetalTextureCacheCreateTextureFromImage(NULL, g_cache, g_pb[i], (__bridge CFDictionaryRef)tattrs, MTLPixelFormatBGRA8Unorm, g_w, g_h, 0, &mt) != kCVReturnSuccess) return 0;
        g_pbtex[i] = CVMetalTextureGetTexture(mt);
        CFRelease(mt);
    }
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void sc(texture2d<float, access::sample> s [[texture(0)]], texture2d<float, access::write> d [[texture(1)]], uint2 g [[thread_position_in_grid]]) {\n"
        "  if (g.x >= d.get_width() || g.y >= d.get_height()) return;\n"
        "  constexpr sampler sm(filter::linear, address::clamp_to_edge);\n"
        "  d.write(float4(s.sample(sm, (float2(g) + 0.5) / float2(d.get_width(), d.get_height())).rgb, 1), g); }\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
    g_scale = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"sc"] error:&err] : nil;
    g_q = dispatch_queue_create("vxmac npu flow", DISPATCH_QUEUE_SERIAL);
    char f[160]; snprintf(f, sizeof f, "\"flow_w\":%d,\"flow_h\":%d,\"ok\":%d", g_w, g_h, g_scale != nil);
    vxmac_jlog("npu_setup", f);
    return g_scale != nil;
}

static void run_flow(int cur, int prev, double t) {
    float img_turn = g_img_at[cur] - g_img_at[prev];
    double t0 = CACurrentMediaTime();
    NSError *err = nil;
    // (the targeted image is the newer frame: the flow is at its pixels, as the presenter's motion vectors are)
    VNGenerateOpticalFlowRequest *req = [[VNGenerateOpticalFlowRequest alloc] initWithTargetedCVPixelBuffer:g_pb[cur] options:@{}];
    req.computationAccuracy = VNGenerateOpticalFlowRequestComputationAccuracyLow;
    req.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half;
    {
        const char *dv = getenv("VXMAC_NPU_DEVICE");
        if (!(dv && !strcmp(dv, "any"))) {
            // (h22: the request's own list of devices per stage came back empty, and Vision ran where it liked. Now from
            //  all the system's compute devices: the Neural Engine for the main and post-processing stages, else the
            //  CPU - never the GPU, which the game keeps 90 % busy)
            static id<MLComputeDeviceProtocol> pick; static const char *kind;
            if (!pick) {
                id<MLComputeDeviceProtocol> cpu = nil;
                for (id<MLComputeDeviceProtocol> d in MLAllComputeDevices()) {
                    (void)0;   // (the Neural Engine is refused for optical flow: h24)
                    if ([(id)d isKindOfClass:[MLCPUComputeDevice class]]) cpu = d;
                }
                kind = pick ? "neural engine" : "cpu";
                if (!pick) pick = cpu;
            }
            if (pick) {
                [req setComputeDevice:pick forComputeStage:VNComputeStageMain];
                [req setComputeDevice:pick forComputeStage:VNComputeStagePostProcessing];
            }
            if (strcmp(kind ? kind : "none", g_device)) { snprintf(g_device, sizeof g_device, "%s", kind ? kind : "none"); char f[96]; snprintf(f, sizeof f, "\"devices\":\"%s\"", g_device); vxmac_jlog("npu_devices", f); }
        } else snprintf(g_device, sizeof g_device, "vision's choice");
    }
    // (a watchdog: a request still running after 400 ms is cancelled)
    __block int done = 0;
    VNGenerateOpticalFlowRequest *watched = req;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!done && g_first_ms >= 0) { [watched cancel]; g_cancelled++; }
    });
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:g_pb[prev] options:@{}];
    BOOL ok = [h performRequests:@[ req ] error:&err];
    done = 1;
    if (g_first_ms < 0) { g_first_ms = (CACurrentMediaTime() - t0) * 1e3; char f[120]; snprintf(f, sizeof f, "\"first_ms\":%.0f,\"ok\":%d,\"devices\":\"%s\"", g_first_ms, ok, g_device); vxmac_jlog("npu_first", f); }
    if (!ok || !req.results.count) {
        g_failed++;
        if (g_failed <= 3) { char f[300]; snprintf(f, sizeof f, "\"error\":\"%s\"", err ? err.localizedDescription.UTF8String : "no result"); vxmac_jlog("npu_flow_error", f); }
        return;
    }
    CVPixelBufferRef fb = ((VNPixelBufferObservation *)req.results.firstObject).pixelBuffer;
    size_t fw = CVPixelBufferGetWidth(fb), fh = CVPixelBufferGetHeight(fb);
    // (h23: the raw flow, 320 px wide, made blocky, flickering patterns in the 90 Hz prediction. Now smoothed (a 5x5
    //  box, twice: about a 9 px blur at flow size) and clamped to 12 flow pixels a frame, in a float copy)
    static float *fa, *fb2; static size_t cap;
    if (cap < fw * fh * 2) { free(fa); free(fb2); cap = fw * fh * 2; fa = malloc(cap * sizeof(float)); fb2 = malloc(cap * sizeof(float)); }
    CVPixelBufferLockBaseAddress(fb, kCVPixelBufferLock_ReadOnly);
    {
        const uint8_t *b0 = CVPixelBufferGetBaseAddress(fb); size_t rw = CVPixelBufferGetBytesPerRow(fb);
        for (size_t y = 0; y < fh; y++) { const __fp16 *r = (const __fp16 *)(b0 + y * rw); for (size_t x = 0; x < fw * 2; x++) fa[y * fw * 2 + x] = r[x]; }
    }
    CVPixelBufferUnlockBaseAddress(fb, kCVPixelBufferLock_ReadOnly);
    for (int pass = 0; pass < 2; pass++) {
        float *src = pass ? fb2 : fa, *dst = pass ? fa : fb2;
        for (size_t y = 0; y < fh; y++) for (size_t x = 0; x < fw; x++) for (int c = 0; c < 2; c++) {
            float sum = 0; int m = 0;
            for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) {
                long yy = (long)y + dy, xx = (long)x + dx;
                if (yy < 0 || xx < 0 || yy >= (long)fh || xx >= (long)fw) continue;
                sum += src[(yy * fw + xx) * 2 + c]; m++;
            }
            float v = sum / m; if (v > 12) v = 12; if (v < -12) v = -12;
            dst[(y * fw + x) * 2 + c] = v;
        }
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float width:fw height:fh mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [g_pbtex[0].device newTextureWithDescriptor:td];
    [tex replaceRegion:MTLRegionMake2D(0, 0, fw, fh) mipmapLevel:0 withBytes:fa bytesPerRow:fw * 2 * sizeof(float)];
    // (the mean horizontal motion, in the flow's pixels: for the log, against the image check)
    double sx = 0; int n = 0;
    for (size_t y = fh / 4; y < fh * 3 / 4; y += 8) for (size_t x = fw / 4; x < fw * 3 / 4; x += 8) { sx += fa[(y * fw + x) * 2]; n++; }
    double ms = (CACurrentMediaTime() - t0) * 1e3;
    {   // (the flow's mean horizontal motion in degrees against the image check's turn between the same two frames:
        //  their signs agree or are opposite consistently - that tells VXMAC_NPU_SIGN)
        const char *te = getenv("VXRT_VR_TAN_Y"); float ty = te ? (float)atof(te) : 0.67f;
        float hfov = 2 * atanf(ty * 16.f / 9.f) * 180 / (float)M_PI, flow_deg = n ? (float)(sx / n) / (float)fw * hfov : 0;
        if (fabsf(img_turn) > 0.5f) {
            g_cmp_n++; if ((flow_deg > 0) == (img_turn > 0)) g_cmp_same++;
            if (g_cmp_logged < 12) { g_cmp_logged++; char f[160]; snprintf(f, sizeof f, "\"flow_deg\":%.2f,\"image_deg\":%.2f", flow_deg, img_turn); vxmac_jlog("npu_vs_image", f); }
        }
    }
    pthread_mutex_lock(&g_l);
    g_flow = tex; g_flow_seq++; g_flow_time = t; g_mean_dx = n ? (float)(sx / n) : 0;
    g_ms_sum += ms; if (ms > g_ms_max) g_ms_max = ms;
    pthread_mutex_unlock(&g_l);
    g_made++;
}

// Each presented frame (the program's thread, the game's command buffer not yet committed)
void vxmac_npu_frame(void *cbp, void *texp, uint32_t w, uint32_t h) {
    if (!vxmac_npu_on()) return;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
    id<MTLTexture> src = (__bridge id<MTLTexture>)texp;
    if (!g_scale && (g_on == 0 || !setup(cb.device, w, h))) { g_on = 0; vxmac_jlog("npu_off", "\"why\":\"setup\""); return; }
    g_offered++;
    { static int once; if (!once) { once = 1; const char *e = getenv("VXMAC_NPU_EVERY"); if (e && *e) g_every = atoi(e) > 0 ? atoi(e) : 1; } }
    if (g_busy) { g_skipped++; return; }
    if (g_offered % (unsigned long)g_every) return;
    int cur = g_next; g_next = (g_next + 1) % kSlots;
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:g_scale]; [e setTexture:src atIndex:0]; [e setTexture:g_pbtex[cur] atIndex:1];
    [e dispatchThreads:MTLSizeMake(g_w, g_h, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [e endEncoding];
    g_img_at[cur] = vxmac_image_turn_total();
    int prev = g_prev; g_prev = cur;
    if (prev < 0) return;
    g_busy = 1;
    double t = CACurrentMediaTime();
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; dispatch_async(g_q, ^{ @autoreleasepool { run_flow(cur, prev, t); } g_busy = 0; }); }];
}

// The newest flow, once (retained for the caller), its size and age
float vxmac_npu_sign(void) {
    const char *se = getenv("VXMAC_NPU_SIGN");
    if (se && *se) return atof(se) < 0 ? -1.f : 1.f;
    if (g_cmp_n < 10) return 0;
    float same = (float)g_cmp_same / g_cmp_n;   // (flow moving with the scene: the vectors must be negated)
    float sign = same >= 0.7f ? -1.f : same <= 0.3f ? 1.f : 0.f;
    static float said = 2; if (sign != said) { said = sign; char f[96]; snprintf(f, sizeof f, "\"sign\":%.0f,\"same\":%.2f,\"n\":%u", sign, same, g_cmp_n); vxmac_jlog("npu_sign", f); }
    return sign;
}
int vxmac_npu_take(void **mv, uint32_t *w, uint32_t *h) {
    // (the flow's direction set from the image check: the presenter's motion vectors point from a pixel to where it was
    //  in the frame before, against the scene's motion; after 10 comparisons the sign that makes the flow agree with
    //  that in 70 % of them is used (vxmac_npu_sign), and with neither, no flow: the rotation-only warp. Until then the
    //  flow waits. VXMAC_NPU_SIGN=1/-1 fixes it)
    if (vxmac_npu_sign() == 0) return 0;
    pthread_mutex_lock(&g_l);
    int fresh = g_flow && g_flow_seq != g_taken_seq;
    if (fresh) { *mv = (__bridge_retained void *)g_flow; *w = (uint32_t)g_flow.width; *h = (uint32_t)g_flow.height; g_taken_seq = g_flow_seq; }
    pthread_mutex_unlock(&g_l);
    return fresh;
}

void vxmac_npu_stats(char *out, unsigned size) {
    pthread_mutex_lock(&g_l);
    unsigned long made = g_made;
    snprintf(out, size, "\"npu_sign_same\":%u,\"npu_sign_n\":%u,\"npu_device\":\"%s\",\"npu_first_ms\":%.0f,\"npu_cancelled\":%lu,\"npu\":%d,\"npu_offered\":%lu,\"npu_flows\":%lu,\"npu_skipped_busy\":%lu,\"npu_failed\":%lu,\"npu_ms_mean\":%.1f,\"npu_ms_max\":%.1f,\"npu_mean_dx\":%.2f",
             g_cmp_same, g_cmp_n, g_device, g_first_ms, (unsigned long)g_cancelled, g_on > 0, (unsigned long)g_offered, made, (unsigned long)g_skipped, (unsigned long)g_failed, made ? g_ms_sum / made : 0.0, g_ms_max, g_mean_dx);
    g_ms_max = 0;
    pthread_mutex_unlock(&g_l);
}
