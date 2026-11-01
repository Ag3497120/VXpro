// interp_warp_mac.m (Mac, method 3 step 4; optional file): the warp's use of the model's layers, proved on
// captured headset frames. For pairs (frame N, frame N + k, k = 1..2, in one burst, N - 1 there too for the camera
// before) of a .vxic capture (app/Sources/interp_capture.m), the very kernels the app runs (vr/warp_core.m, render pass
// into an sRGB colour + Depth32Float target as the headset's drawable) predict N to N + k's time and camera:
//   hold     frame N as it is (no warp)
//   default  ddgame62 as launched: the pose (the real camera of N + k: the head at display time), mode 6's depth and
//            the h60 camera move (velocity from N - 1 -> N, x age, at most 0.3 m) while the dibr gate holds; no motion
//   vel      default + the game's raw velocity as motion vectors (VXMAC_VEL_PREDICT=1's path: camera turn out, t =
//            age / interval at most 2, gated at 150 ms, still blocks held)
//   model    the new path (VXMAC_INTERP=1): the model's cleaned motion (t = age / N's own interval, at most 1.5, held at
//            150 ms), holes from its fill, its conf as N's weight, the camera's turn out, no h60 move
//   velx     the new path's timing and gate with the game's raw velocity instead of the model (no fill, no conf): what
//            the model itself adds is model - velx
// against the real frame N + k: PSNR (8-bit sRGB) over the whole frame and over the part N's frame covers ("in").
// The model runs as the app runs it: Core ML, CPU + Neural Engine, IOSurface input (OneComponent16Half W x 6H, filled
// as tools/interp_model.py encode_input) and output read by Metal as R16Float. PNGs: N | actual N + k | default | vel
// | model | |model - actual| x 4, for VXT_PNG pairs (default 10) spread over the gaps. Then the GPU cost at the headset's
// size (1600x900 frame -> 1888x1792 eye, render pass + depth, as warp_bench_mac.m): an eye without / with the layers.
//   clang -fobjc-arc -O2 -Ivr -framework Foundation -framework Metal -framework CoreML -framework CoreVideo \
//     -framework CoreGraphics -framework ImageIO -lcompression tests/interp_warp_mac.m vr/warp_core.m -o build/interp_warp_mac
//   build/interp_warp_mac <capture.vxic> <model.mlmodelc> <out dir> [max pairs]
// VXT_STRIDE=n: every n-th usable pair (default 1). VXT_SPLIT=heldout | train: only the bursts tools/interp_model.py
// holds out (heldout_burst: chunks of 20 bursts, every 5th) or trains on (default: all). Capture data stays on this Mac (the out dir: build/, not in git).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreML/CoreML.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <compression.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "warp_core.h"
#ifdef VXT_IDENTITY   // (the default paths' bytes against another warp_core.m - e.g. ddgame62's: no vxw_set_interp there)
#define vxw_set_interp(...) 0
#endif

#pragma pack(push, 1)
typedef struct { char magic[4]; uint32_t ver, w, h, planes, res[3]; } file_hdr;
typedef struct {
    char magic[4]; uint32_t hdr_bytes, payload, raw, flags, burst, index;
    uint32_t src_w, src_h, depth_w, depth_h, vel_w, vel_h;
    uint64_t seq, cam_seq; double t, t_prev;
    float vel_k[2], vel_corr, tan[2], nearp, sent[2]; float cam[16]; float cam_vel[3], reserved;
} rec_hdr;
#pragma pack(pop)
enum { F_DEPTH = 1, F_VEL = 2, F_VEL_OK = 4, F_VR = 8, F_CAM = 64, F_ZLIB = 256 };

typedef struct { rec_hdr h; _Float16 *pl; } frame;   // (planes r g b d vx vy, h x w each)

static int W, H;
static id<MTLDevice> dev; static id<MTLCommandQueue> q; static vxw_core *core;

static int read_frame(FILE *f, frame *fr, uint8_t *buf, size_t bufsz) {
    if (fread(&fr->h, sizeof fr->h, 1, f) != 1) return 0;
    if (memcmp(fr->h.magic, "VXFR", 4) || fr->h.hdr_bytes != sizeof(rec_hdr)) { fprintf(stderr, "bad record\n"); return 0; }
    if (fr->h.payload > bufsz || fread(buf, 1, fr->h.payload, f) != fr->h.payload) return 0;
    fr->pl = malloc(fr->h.raw);
    size_t n = fr->h.flags & F_ZLIB ? compression_decode_buffer((uint8_t *)fr->pl, fr->h.raw, buf, fr->h.payload, NULL, COMPRESSION_ZLIB)
                                    : (memcpy(fr->pl, buf, fr->h.payload), fr->h.payload);
    if (n != fr->h.raw) { fprintf(stderr, "bad payload\n"); free(fr->pl); return 0; }
    return 1;
}
static float P(const frame *f, int c, int x, int y) { return (float)f->pl[(size_t)c * W * H + (size_t)y * W + x]; }

// (the camera: gm rows right, up, forward (Z up) with the translation in column 3; position -R^T t)
static void cam_R(const frame *f, float R[9]) { for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) R[r * 3 + c] = f->h.cam[r * 4 + c]; }
static void cam_P(const frame *f, float p[3]) { for (int i = 0; i < 3; i++) p[i] = -(f->h.cam[3] * f->h.cam[i] + f->h.cam[7] * f->h.cam[4 + i] + f->h.cam[11] * f->h.cam[8 + i]); }
static void mul_ABt(const float A[9], const float B[9], float o[9]) {   // (A B^T)
    for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) o[r * 3 + c] = A[r * 3] * B[c * 3] + A[r * 3 + 1] * B[c * 3 + 1] + A[r * 3 + 2] * B[c * 3 + 2];
}

static id<MTLTexture> tex2d(MTLPixelFormat f, int w, int h, MTLTextureUsage u, int mips) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:mips];
    td.usage = u; td.storageMode = MTLStorageModeShared;
    if (f == MTLPixelFormatDepth32Float || (u & MTLTextureUsageRenderTarget && !(u & MTLTextureUsageShaderRead))) td.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:td];
}
// (frame N's colour as the slot holds it: 8-bit with mips, sampled through an sRGB view)
static id<MTLTexture> colour_tex(const frame *f, id<MTLTexture> *view) {
    id<MTLTexture> t = tex2d(MTLPixelFormatRGBA8Unorm, W, H, MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView, 1);
    uint8_t *px = malloc((size_t)W * H * 4);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) for (int c = 0; c < 4; c++) {
        float v = c < 3 ? P(f, c, x, y) : 1; v = v < 0 ? 0 : v > 1 ? 1 : v;
        px[((size_t)y * W + x) * 4 + c] = (uint8_t)lrintf(v * 255);
    }
    [t replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:W * 4];
    free(px);
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder]; [b generateMipmapsForTexture:t]; [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    *view = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    return t;
}
static id<MTLTexture> plane_tex(const frame *f, int c0, int n) {   // (R32Float depth, or RG32Float velocity)
    id<MTLTexture> t = tex2d(n == 1 ? MTLPixelFormatR32Float : MTLPixelFormatRG32Float, W, H, MTLTextureUsageShaderRead, 0);
    float *v = malloc((size_t)W * H * 4 * n);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) for (int c = 0; c < n; c++) { float a = P(f, c0 + c, x, y); v[((size_t)y * W + x) * n + c] = isfinite(a) ? a : 0; }
    [t replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:v bytesPerRow:W * 4 * n];
    free(v);
    return t;
}

// ---- the model, as npu_model.m runs it ----
static MLModel *g_model; static CVPixelBufferRef g_in, g_out; static MLMultiArray *g_inarr, *g_outarr; static CVMetalTextureCacheRef g_cache;
static id<MTLTexture> g_outtex; static double g_model_ms_sum; static unsigned g_model_n;
static double g_last_conf = 1; static double g_conf_sum, g_conf_low, g_fill_dev, g_mot_dev, g_mot_in, g_out_n;   // (what the model's output holds)
static CVPixelBufferRef pb16(int w, int h) {
    CVPixelBufferRef p = NULL;
    NSDictionary *a = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES };
    CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_OneComponent16Half, (__bridge CFDictionaryRef)a, &p);
    return p;
}
static int model_load(const char *path) {
    MLModelConfiguration *cfg = [MLModelConfiguration new]; cfg.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
    NSError *err = nil;
    g_model = [MLModel modelWithContentsOfURL:[NSURL fileURLWithPath:@(path)] configuration:cfg error:&err];
    if (!g_model) { fprintf(stderr, "model: %s\n", err.localizedDescription.UTF8String); return 0; }
    NSArray *shape = @[ @1, @6, @(H), @(W) ];
    g_in = pb16(W, 6 * H); g_out = pb16(W, 6 * H);
    g_inarr = [[MLMultiArray alloc] initWithPixelBuffer:g_in shape:shape]; g_outarr = [[MLMultiArray alloc] initWithPixelBuffer:g_out shape:shape];
    CVMetalTextureCacheCreate(NULL, NULL, dev, NULL, &g_cache);
    CVMetalTextureRef mt = NULL;
    CVMetalTextureCacheCreateTextureFromImage(NULL, g_cache, g_out, NULL, MTLPixelFormatR16Float, W, 6 * H, 0, &mt);
    g_outtex = CVMetalTextureGetTexture(mt); CFRelease(mt);
    return g_outtex != nil;
}
static int model_run(const frame *f) {   // (tools/interp_model.py encode_input)
    CVPixelBufferLockBaseAddress(g_in, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(g_in); size_t bpr = CVPixelBufferGetBytesPerRow(g_in);
    int kok = (f->h.flags & F_VEL_OK) && fabsf(f->h.vel_k[0]) > 0.1f;
    float kx = kok ? f->h.vel_k[0] : -1.05f, ky = kok ? f->h.vel_k[1] : -1.05f;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        float v[6];
        for (int c = 0; c < 3; c++) { float a = P(f, c, x, y); v[c] = isfinite(a) ? (a < 0 ? 0 : a > 1 ? 1 : a) : 0; }
        float d = P(f, 3, x, y);
        v[3] = f->h.flags & F_DEPTH ? fminf(1, fmaxf(0, log2f(1.0f / fmaxf(d, 1e-6f)) / 12.0f)) : 1;
        float vx = P(f, 4, x, y), vy = P(f, 5, x, y);
        v[4] = f->h.flags & F_VEL ? vx * kx * W / 16.0f : 0; v[5] = f->h.flags & F_VEL ? vy * ky * H / 16.0f : 0;
        for (int c = 0; c < 6; c++) ((_Float16 *)(base + (size_t)(c * H + y) * bpr))[x] = (_Float16)(isfinite(v[c]) ? v[c] : 0);
    }
    CVPixelBufferUnlockBaseAddress(g_in, 0);
    NSError *err = nil;
    MLDictionaryFeatureProvider *fp = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ @"x": [MLFeatureValue featureValueWithMultiArray:g_inarr] } error:&err];
    MLPredictionOptions *po = [MLPredictionOptions new]; po.outputBackings = @{ @"y": g_outarr };
    double t0 = CFAbsoluteTimeGetCurrent();
    id<MLFeatureProvider> r = [g_model predictionFromFeatures:fp options:po error:&err];
    g_model_ms_sum += (CFAbsoluteTimeGetCurrent() - t0) * 1e3; g_model_n++;
    if (!r) { fprintf(stderr, "predict: %s\n", err.localizedDescription.UTF8String); return 0; }
    {   // (its output against its input: conf, the fill's and the motion's departure from the frame and the game's motion)
        double c0 = g_conf_sum, n0 = g_out_n;
        CVPixelBufferLockBaseAddress(g_out, kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(g_in, kCVPixelBufferLock_ReadOnly);
        const uint8_t *ob = CVPixelBufferGetBaseAddress(g_out), *ib = CVPixelBufferGetBaseAddress(g_in);
        size_t obr = CVPixelBufferGetBytesPerRow(g_out), ibr = CVPixelBufferGetBytesPerRow(g_in);
        #define O(c, x, y) ((float)((const _Float16 *)(ob + (size_t)((c) * H + (y)) * obr))[x])
        #define I(c, x, y) ((float)((const _Float16 *)(ib + (size_t)((c) * H + (y)) * ibr))[x])
        for (int y = 0; y < H; y += 2) for (int x = 0; x < W; x += 2) {
            float cf = O(5, x, y); g_conf_sum += cf; g_conf_low += cf < 0.25f;
            g_fill_dev += (fabsf(O(0, x, y) - I(0, x, y)) + fabsf(O(1, x, y) - I(1, x, y)) + fabsf(O(2, x, y) - I(2, x, y))) / 3;
            float md = 16 * hypotf(O(3, x, y) - I(4, x, y), O(4, x, y) - I(5, x, y)), mi = 16 * hypotf(I(4, x, y), I(5, x, y));
            if (isfinite(md) && isfinite(mi)) { g_mot_dev += md; g_mot_in += mi; }
            g_out_n++;
        }
        CVPixelBufferUnlockBaseAddress(g_out, kCVPixelBufferLock_ReadOnly); CVPixelBufferUnlockBaseAddress(g_in, kCVPixelBufferLock_ReadOnly);
        g_last_conf = g_out_n > n0 ? (g_conf_sum - c0) / (g_out_n - n0) : 1;
    }
    return [r featureValueForName:@"y"].multiArrayValue.pixelBuffer == g_out;
}

// ---- one warp, as xros_vr.m draw_eye_inner sets it up ----
enum { V_HOLD, V_DEF, V_VEL, V_MODEL, V_VELX, NV };
static const char *vname[NV] = { "hold", "default", "vel", "model", "velx" };
static id<MTLTexture> g_o, g_od, g_read;
static uint8_t *warp(int v, const frame *a, const frame *b, const frame *c, id<MTLTexture> bview, id<MTLTexture> aview, id<MTLTexture> depth,
                     id<MTLTexture> vel, id<MTLTexture> zero_mv, id<MTLTexture> far_depth, double *t_used) {
    double age = c->h.t - b->h.t, gap = b->h.t - b->h.t_prev;
    float Rb[9], Rc[9], Ra[9], rot[9]; cam_R(b, Rb); cam_R(c, Rc); cam_R(a, Ra);
    mul_ABt(Rc, Rb, rot);                              // (c's camera from b's)
    vxw_params p = { 0 };
    p.w = W; p.h = H; p.flags = VXW_POSE; p.tan_x = b->h.tan[0]; p.tan_y = b->h.tan[1]; p.z_a = b->h.nearp; p.z_b = 0;
    memcpy(p.rot, rot, sizeof rot);
    p.dst_tan[0] = p.dst_tan[1] = p.tan_x; p.dst_tan[2] = p.dst_tan[3] = p.tan_y;
    p.dst_near = 0.2f;
    int use_dibr = gap <= 0.11 && age < 0.25;
    int interp = (v == V_MODEL || v == V_VELX) && gap > 0.005 && gap < 0.4;
    if (v != V_HOLD && use_dibr && !interp) {   // (h60's move: the camera's velocity from a to b, x age, in b's axes, at most 0.3 m)
        float pa[3], pb[3]; cam_P(a, pa); cam_P(b, pb);
        double dtv = b->h.t - a->h.t; float d[3] = { 0 }, dw[3];
        if (dtv > 0.01 && dtv < 0.3) for (int i = 0; i < 3; i++) dw[i] = (pb[i] - pa[i]) / (float)dtv * (float)fmin(age, 0.2); else dw[0] = dw[1] = dw[2] = 0;
        for (int r = 0; r < 3; r++) d[r] = Rb[r * 3] * dw[0] + Rb[r * 3 + 1] * dw[1] + Rb[r * 3 + 2] * dw[2];
        float n = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]); if (n > 0.3f) for (int i = 0; i < 3; i++) d[i] *= 0.3f / n;
        // (as xros_vr.m: M's translation less d, then x VXRT_VR_STEREO (0.4) while the depth is used)
        for (int r = 0; r < 3; r++) p.pos[r] = -d[r] * 0.4f;
    }
    if (interp) use_dibr = 1;   // (xros_vr.m: the model's motion takes the depth's z-order at any rate, without a baseline outside the gate)
    id<MTLTexture> mv = zero_mv, A = nil;
    float cam[9]; mul_ABt(Ra, Rb, cam);                // (a's camera from b's)
    *t_used = 0;
    if (v == V_VEL && gap < 0.15 && age < 0.15) {
        int kok = (b->h.flags & F_VEL_OK) && fabsf(b->h.vel_k[0]) > 0.1f;
        float kx = kok ? b->h.vel_k[0] : -1.05f, ky = kok ? b->h.vel_k[1] : -1.05f;
        mv = vel; p.mv_sx = -kx * W; p.mv_sy = -ky * H;
        double t = age / gap; p.t = (float)(t > 2 ? 2 : t);
        memcpy(p.cam, cam, sizeof cam); p.flags |= VXW_CAM_MV | VXW_STILL; p.thr = 0.03f; A = aview;
        *t_used = p.t;
    }
    float ct = 0, cf = 0;
    if (interp) {   // (xros_vr.m's defaults; VXT_TMAX / VXT_MAX_MS / VXT_FADE_MS / VXT_CONF (x conf_t) to try others)
        static double tmax = -1, maxs, fades, confk;
        if (tmax < 0) { tmax = getenv("VXT_TMAX") ? atof(getenv("VXT_TMAX")) : 1.5; maxs = (getenv("VXT_MAX_MS") ? atof(getenv("VXT_MAX_MS")) : 150) / 1e3;
                        fades = (getenv("VXT_FADE_MS") ? atof(getenv("VXT_FADE_MS")) : 100) / 1e3; confk = getenv("VXT_CONF") ? atof(getenv("VXT_CONF")) : 1; }
        double ag = age > maxs ? maxs : age, t = ag / gap; p.t = (float)(t > tmax ? tmax : t);
        memcpy(p.cam, cam, sizeof cam); p.flags |= VXW_CAM_MV | VXW_STILL; p.thr = 0.03f; A = aview;
        ct = (p.t < 1 ? p.t : 1) * (float)confk;
        cf = maxs > fades ? (float)((age - fades) / (maxs - fades)) : 0; cf = cf < 0 ? 0 : cf > 1 ? 1 : cf * cf * (3 - 2 * cf);
        if (!getenv("VXT_CONF") && g_last_conf < 0.05) ct = cf = 0;   // (xros_vr.m VXMAC_INTERP_CONF=auto: a collapsed conf is not used)
        if (v == V_VELX) {
            int kok = (b->h.flags & F_VEL_OK) && fabsf(b->h.vel_k[0]) > 0.1f;
            mv = vel; p.mv_sx = -(kok ? b->h.vel_k[0] : -1.05f) * W; p.mv_sy = -(kok ? b->h.vel_k[1] : -1.05f) * H;
        }
        *t_used = p.t;
    }
    if (v == V_HOLD) {   // (frame N's own bytes)
        uint8_t *px = malloc((size_t)W * H * 4);
        [bview.parentTexture getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
        return px;
    }
    id<MTLCommandBuffer> cb = [q commandBuffer];
    {
        if (v == V_MODEL && getenv("VXT_LAYERS")) {   // (layers made offline for this very pair, e.g. an oracle flow: <dir>/<seq N>_<seq N+k>.f16)
            char path[1024]; snprintf(path, sizeof path, "%s/%llu_%llu.f16", getenv("VXT_LAYERS"), (unsigned long long)b->h.seq, (unsigned long long)c->h.seq);
            FILE *lf = fopen(path, "rb");
            if (!lf) { static int told; if (!told++) fprintf(stderr, "no layers %s\n", path); }
            else {
                CVPixelBufferLockBaseAddress(g_out, 0);
                uint8_t *ob = CVPixelBufferGetBaseAddress(g_out); size_t obr = CVPixelBufferGetBytesPerRow(g_out);
                for (int r = 0; r < 6 * H; r++) if (fread(ob + (size_t)r * obr, 2, W, lf) != (size_t)W) break;
                CVPixelBufferUnlockBaseAddress(g_out, 0); fclose(lf);
                g_last_conf = 1;
            }
        }
        int ok = vxw_set_interp(core, (__bridge void *)cb, interp && v == V_MODEL ? (__bridge void *)g_outtex : NULL, W, H,
                                b->h.seq * 4 + (c->h.index - b->h.index), 1, ct, cf);
        if (v == V_VELX) ok = 1;
        if (interp && !ok) { fprintf(stderr, "vxw_set_interp failed\n"); exit(1); }
        if (!vxw_encode_eye(core, (__bridge void *)cb, &p, (__bridge void *)bview, (__bridge void *)A, (__bridge void *)mv,
                            (__bridge void *)(use_dibr ? depth : far_depth), (__bridge void *)g_o, (__bridge void *)g_od)) { fprintf(stderr, "encode failed\n"); exit(1); }
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromTexture:g_o sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                  toTexture:g_read destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [bl endEncoding];
    }
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "GPU error\n"); exit(1); }
    uint8_t *px = malloc((size_t)W * H * 4);
    [g_read getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    return px;
}

static void png(const char *path, const uint8_t *rgba, int w, int h) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate((void *)rgba, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL(u, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(d, img, NULL); CGImageDestinationFinalize(d);
    CFRelease(d); CFRelease(u); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
}

typedef struct { double se_all, se_in; unsigned long n_all, n_in; } acc;
typedef struct { acc a[NV]; unsigned n; double t_sum[NV]; double ssim[NV]; unsigned long ssim_n; double dse[NV]; unsigned long dn; } bucket;
// (perceptual checks: SSIM of luma over 8x8 windows (stride 4) inside the part N covers; "dyn": PSNR only where the
//  default warp (the camera's turn alone) misses the real frame by over 20/255 in luma - moving objects, parallax,
//  disocclusions: where prediction and ghosting show)
static float luma(const uint8_t *p) { return 0.299f * p[0] + 0.587f * p[1] + 0.114f * p[2]; }
static double psnr(double se, unsigned long n) { return n && se > 0 ? 10 * log10(255.0 * 255.0 / (se / n)) : 99; }

int main(int argc, char **argv) {
    @autoreleasepool {
    if (argc < 4) { fprintf(stderr, "usage: interp_warp_mac capture.vxic model.mlmodelc outdir [max pairs]\n"); return 2; }
    setenv("VXMAC_VIGNETTE", "0", 0);   // (the head-locked vignette darkens the eye's edge: not part of the prediction)
    int maxp = argc > 4 ? atoi(argv[4]) : 100000, stride = getenv("VXT_STRIDE") ? atoi(getenv("VXT_STRIDE")) : 1, npng = getenv("VXT_PNG") ? atoi(getenv("VXT_PNG")) : 10;
    if (stride < 1) stride = 1;
    FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
    file_hdr fh; if (fread(&fh, sizeof fh, 1, f) != 1 || memcmp(fh.magic, "VXIC", 4) || fh.ver != 1 || fh.planes != 6) { fprintf(stderr, "not a v1 capture\n"); return 1; }
    W = (int)fh.w; H = (int)fh.h;
    dev = MTLCreateSystemDefaultDevice(); q = [dev newCommandQueue];
    core = vxw_create((__bridge void *)dev);
    if (!core) { fprintf(stderr, "warp core did not compile\n"); return 1; }
    if (!model_load(argv[2])) return 1;
    [[NSFileManager defaultManager] createDirectoryAtPath:@(argv[3]) withIntermediateDirectories:YES attributes:nil error:nil];
    g_o = tex2d(MTLPixelFormatRGBA8Unorm_sRGB, W, H, MTLTextureUsageRenderTarget, 0);   // (as the drawable: render target only)
    g_od = tex2d(MTLPixelFormatDepth32Float, W, H, MTLTextureUsageRenderTarget, 0);
    // (the render target is sRGB: its bytes are the sRGB encoding, read through a plain copy texture of the same bytes)
    MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:W height:H mipmapped:NO];
    rd.usage = MTLTextureUsageShaderRead; rd.storageMode = MTLStorageModeShared; g_read = [dev newTextureWithDescriptor:rd];
    id<MTLTexture> zero_mv = tex2d(MTLPixelFormatRG32Float, 1, 1, MTLTextureUsageShaderRead, 0), far_depth = tex2d(MTLPixelFormatR32Float, 1, 1, MTLTextureUsageShaderRead, 0);
    { float z[2] = { 0, 0 }; [zero_mv replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:z bytesPerRow:8];
      float fz = 0.2f / 100.0f; [far_depth replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&fz bytesPerRow:4]; }   // (C.farp's plane)
    size_t bufsz = (size_t)W * H * 12 + 4096; uint8_t *buf = malloc(bufsz);
    // (a burst's frames, kept until the burst ends)
    frame win[64]; int nw = 0;
    static const double edges[] = { 0, 0.055, 0.100, 0.150, 0.201 };
    bucket bk[4] = { 0 }, all = { 0 };
    int pairs = 0, seen = 0, pngs = 0, png_due[4] = { 0 };
    double model_ms_max = 0; (void)model_ms_max;
    unsigned long hole_px = 0, px_total = 0; (void)hole_px; (void)px_total;
    int done = 0;
    while (!done) {
        frame fr; int got = read_frame(f, &fr, buf, bufsz);
        int flush = !got || (nw && (fr.h.burst != win[0].h.burst || fr.h.index != win[nw - 1].h.index + 1)) || nw == 64;
        if (flush) {
            for (int i = 1; i < nw && !done; i++) {   // (N = i, N - 1 = i - 1)
                frame *a = &win[i - 1], *b = &win[i];
                unsigned need = F_DEPTH | F_VEL | F_CAM;
                {   static int split = -1;
                    if (split < 0) { const char *e = getenv("VXT_SPLIT"); split = e && !strcmp(e, "heldout") ? 1 : e && !strcmp(e, "train") ? 2 : 0; }
                    int held = ((b->h.burst - 1) / 20) % 5 == 4;
                    if ((split == 1 && !held) || (split == 2 && held)) continue; }
                if ((a->h.flags & F_CAM) == 0 || (b->h.flags & need) != need) continue;
                double gap = b->h.t - b->h.t_prev;
                if (!(gap > 0.005 && gap < 0.4)) continue;
                int ran = 0; id<MTLTexture> bview = nil, aview = nil, depth = nil, vel = nil; __unused id<MTLTexture> bt = nil, at = nil;
                for (int k = 1; k <= 2 && i + k < nw && !done; k++) {
                    frame *c = &win[i + k];
                    double age = c->h.t - b->h.t;
                    if (age > 0.2 || !(c->h.flags & F_CAM)) break;
                    if (seen++ % stride) continue;
                    if (!ran) {
                        bt = colour_tex(b, &bview); at = colour_tex(a, &aview); depth = plane_tex(b, 3, 1); vel = plane_tex(b, 4, 2);
                        if (!model_run(b)) { fprintf(stderr, "model output not in its backing\n"); return 1; }
                        ran = 1;
                    }
                    int bi = 0; while (bi < 3 && age >= edges[bi + 1]) bi++;
                    uint8_t *out[NV]; double tu[NV];
#ifdef VXT_IDENTITY
                    { static uint64_t hsh = 1469598103934665603ull; static unsigned nh;
                      for (int v = V_DEF; v <= V_VEL; v++) { uint8_t *o = warp(v, a, b, c, bview, aview, depth, vel, zero_mv, far_depth, &tu[v]);
                          for (size_t i2 = 0; i2 < (size_t)W * H * 4; i2++) hsh = (hsh ^ o[i2]) * 1099511628211ull; free(o); }
                      if (++nh % 50 == 0 || pairs + 1 >= maxp) printf("identity: %u pairs, hash %016llx\n", nh, (unsigned long long)hsh); }
                    pairs++; if (pairs >= maxp) done = 1;
                    continue;
#endif
                    for (int v = 0; v < NV; v++) out[v] = warp(v, a, b, c, bview, aview, depth, vel, zero_mv, far_depth, &tu[v]);
                    // (the part of c's view that b's frame covers: c's rays back through the rotation, inside b)
                    float Rb[9], Rc[9], rot[9]; cam_R(b, Rb); cam_R(c, Rc); mul_ABt(Rc, Rb, rot);
                    float tx = b->h.tan[0], ty = b->h.tan[1];
                    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
                        float Y[3] = { ((x + 0.5f) / W * 2 - 1) * tx, (1 - (y + 0.5f) / H * 2) * ty, 1 }, X[3];
                        for (int r = 0; r < 3; r++) X[r] = rot[0 * 3 + r] * Y[0] + rot[1 * 3 + r] * Y[1] + rot[2 * 3 + r] * Y[2];
                        int in = X[2] > 1e-4f && fabsf(X[0] / X[2]) < tx * 0.98f && fabsf(X[1] / X[2]) < ty * 0.98f;
                        for (int v = 0; v < NV; v++) {
                            double se = 0;
                            for (int ch = 0; ch < 3; ch++) {
                                float tv = P(c, ch, x, y); tv = tv < 0 ? 0 : tv > 1 ? 1 : tv;
                                double d = out[v][((size_t)y * W + x) * 4 + ch] - tv * 255.0; se += d * d;
                            }
                            bk[bi].a[v].se_all += se; bk[bi].a[v].n_all += 3; all.a[v].se_all += se; all.a[v].n_all += 3;
                            if (in) { bk[bi].a[v].se_in += se; bk[bi].a[v].n_in += 3; all.a[v].se_in += se; all.a[v].n_in += 3; }
                        }
                    }
                    for (int v = 0; v < NV; v++) { bk[bi].t_sum[v] += tu[v]; all.t_sum[v] += tu[v]; }
                    {   float *L[NV], *T = malloc(sizeof(float) * W * H); uint8_t *inm = malloc((size_t)W * H);
                        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
                            uint8_t tp[3]; for (int ch = 0; ch < 3; ch++) { float tv = P(c, ch, x, y); tv = tv < 0 ? 0 : tv > 1 ? 1 : tv; tp[ch] = (uint8_t)lrintf(tv * 255); }
                            T[y * W + x] = luma(tp);
                            float Y[3] = { ((x + 0.5f) / W * 2 - 1) * tx, (1 - (y + 0.5f) / H * 2) * ty, 1 }, X[3];
                            for (int r = 0; r < 3; r++) X[r] = rot[0 * 3 + r] * Y[0] + rot[1 * 3 + r] * Y[1] + rot[2 * 3 + r] * Y[2];
                            inm[y * W + x] = X[2] > 1e-4f && fabsf(X[0] / X[2]) < tx * 0.98f && fabsf(X[1] / X[2]) < ty * 0.98f;
                        }
                        for (int v = 0; v < NV; v++) { L[v] = malloc(sizeof(float) * W * H); for (int i2 = 0; i2 < W * H; i2++) L[v][i2] = luma(out[v] + (size_t)i2 * 4); }
                        for (int i2 = 0; i2 < W * H; i2++) if (inm[i2] && fabsf(L[V_DEF][i2] - T[i2]) > 20) {
                            for (int v = 0; v < NV; v++) { double d = L[v][i2] - T[i2]; bk[bi].dse[v] += d * d; all.dse[v] += d * d; }
                            bk[bi].dn++; all.dn++;
                        }
                        const double C1 = 6.5025, C2 = 58.5225;
                        for (int y0 = 0; y0 + 8 <= H; y0 += 4) for (int x0 = 0; x0 + 8 <= W; x0 += 4) {
                            int ok2 = inm[y0 * W + x0] && inm[(y0 + 7) * W + x0 + 7] && inm[y0 * W + x0 + 7] && inm[(y0 + 7) * W + x0];
                            if (!ok2) continue;
                            double mt = 0, vt = 0; for (int y = y0; y < y0 + 8; y++) for (int x = x0; x < x0 + 8; x++) { double q2 = T[y * W + x]; mt += q2; vt += q2 * q2; }
                            mt /= 64; vt = vt / 64 - mt * mt;
                            for (int v = 0; v < NV; v++) {
                                double mo = 0, vo = 0, co = 0;
                                for (int y = y0; y < y0 + 8; y++) for (int x = x0; x < x0 + 8; x++) { double o2 = L[v][y * W + x]; mo += o2; vo += o2 * o2; co += o2 * T[y * W + x]; }
                                mo /= 64; vo = vo / 64 - mo * mo; co = co / 64 - mo * mt;
                                double ss = ((2 * mo * mt + C1) * (2 * co + C2)) / ((mo * mo + mt * mt + C1) * (vo + vt + C2));
                                bk[bi].ssim[v] += ss; all.ssim[v] += ss;
                            }
                            bk[bi].ssim_n++; all.ssim_n++;
                        }
                        for (int v = 0; v < NV; v++) free(L[v]);
                        free(T); free(inm);
                    }
                    bk[bi].n++; all.n++; pairs++;
                    // (PNGs: spread over the gap buckets, a pair every so often)
                    if (pngs < npng && png_due[bi] <= pngs / 4 && (pairs % 37) == 0) {
                        png_due[bi]++;
                        int cw = W * 3, chh = H * 2; uint8_t *g = calloc((size_t)cw * chh * 4, 1);
                        const uint8_t *tiles[6]; uint8_t *tgt = malloc((size_t)W * H * 4), *diff = malloc((size_t)W * H * 4);
                        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) for (int ch = 0; ch < 4; ch++) {
                            float tv = ch < 3 ? P(c, ch, x, y) : 1; tv = tv < 0 ? 0 : tv > 1 ? 1 : tv;
                            size_t o = ((size_t)y * W + x) * 4 + ch;
                            tgt[o] = (uint8_t)lrintf(tv * 255);
                            diff[o] = ch < 3 ? (uint8_t)fmin(255, abs((int)out[V_MODEL][o] - (int)tgt[o]) * 4) : 255;
                        }
                        tiles[0] = out[V_HOLD]; tiles[1] = tgt; tiles[2] = out[V_DEF]; tiles[3] = out[V_VEL]; tiles[4] = out[V_MODEL]; tiles[5] = diff;
                        for (int k2 = 0; k2 < 6; k2++) for (int y = 0; y < H; y++)
                            memcpy(g + (((size_t)(k2 / 3) * H + y) * cw + (size_t)(k2 % 3) * W) * 4, tiles[k2] + (size_t)y * W * 4, (size_t)W * 4);
                        for (int y = 0; y < chh; y++) for (int x = 0; x < cw; x++) g[((size_t)y * cw + x) * 4 + 3] = 255;
                        char path[1024];
                        snprintf(path, sizeof path, "%s/pair_%02d_gap%03.0fms_age%03.0fms.png", argv[3], pngs, gap * 1e3, age * 1e3);
                        png(path, g, cw, chh);
                        // (each pair's PSNR next to its PNG)
                        printf("png %s  t=%.2f\n", path, tu[V_MODEL]);
                        free(g); free(tgt); free(diff); pngs++;
                    }
                    for (int v = 0; v < NV; v++) free(out[v]);
                    if (pairs >= maxp) done = 1;
                }
            }
            for (int i = 0; i < nw; i++) free(win[i].pl);
            nw = 0;
            if (pairs && pairs % 500 < 2) { fprintf(stderr, "%d pairs\n", pairs); }
        }
        if (!got) break;
        win[nw++] = fr;
    }
    for (int i = 0; i < nw; i++) free(win[i].pl);
    printf("\npairs %d (frames N with N-1 and N+k, k=1..2, age <= 200 ms, in bursts), model on this Mac: %.2f ms mean over %u predictions\n",
           pairs, g_model_n ? g_model_ms_sum / g_model_n : 0, g_model_n);
    if (g_out_n) printf("the model's output (Core ML on this Mac): conf mean %.4f (under 0.25: %.1f %%), |fill - frame| %.4f, |motion - game's| %.2f model px (game's %.2f)\n",
                        g_conf_sum / g_out_n, 100 * g_conf_low / g_out_n, g_fill_dev / g_out_n, g_mot_dev / g_out_n, g_mot_in / g_out_n);
    printf("PSNR dB (8-bit sRGB) against the real frame N+k: whole frame / the part frame N covers   [mean t]\n");
    for (int bi = -1; bi < 4; bi++) {
        bucket *B = bi < 0 ? &all : &bk[bi];
        if (!B->n) continue;
        if (bi < 0) printf("  all          n=%5u", B->n); else printf("  %3.0f-%3.0f ms   n=%5u", edges[bi] * 1e3, edges[bi + 1] * 1e3, B->n);
        for (int v = 0; v < NV; v++) printf("  %s %.2f/%.2f [%.2f]", vname[v], psnr(B->a[v].se_all, B->a[v].n_all), psnr(B->a[v].se_in, B->a[v].n_in), B->t_sum[v] / B->n);
        printf("\n               SSIM");
        for (int v = 0; v < NV; v++) printf("  %s %.4f", vname[v], B->ssim_n ? B->ssim[v] / B->ssim_n : 0);
        printf("   dyn PSNR (%.1f %% of pixels)", 100.0 * B->dn / ((double)B->n * W * H));
        for (int v = 0; v < NV; v++) printf("  %s %.2f", vname[v], psnr(B->dse[v], B->dn));
        printf("\n");
    }
    // ---- the GPU cost at the headset's size ----
    {
        const int BW = 1600, BH = 900, OW = 1888, OH = 1792;
        id<MTLTexture> B = tex2d(MTLPixelFormatRGBA8Unorm, BW, BH, MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView, 1);
        uint8_t *px = malloc((size_t)BW * BH * 4); for (size_t i = 0; i < (size_t)BW * BH * 4; i++) px[i] = (uint8_t)(rand() & 255);
        [B replaceRegion:MTLRegionMake2D(0, 0, BW, BH) mipmapLevel:0 withBytes:px bytesPerRow:BW * 4]; free(px);
        id<MTLTexture> Bv = [B newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
        id<MTLTexture> D = tex2d(MTLPixelFormatR32Float, BW, BH, MTLTextureUsageShaderRead, 0);
        float *z = malloc((size_t)BW * BH * 4); for (int i = 0; i < BW * BH; i++) z[i] = 0.2f / (2 + (i % BW) * 0.01f);
        [D replaceRegion:MTLRegionMake2D(0, 0, BW, BH) mipmapLevel:0 withBytes:z bytesPerRow:BW * 4]; free(z);
        id<MTLTexture> O = tex2d(MTLPixelFormatBGRA8Unorm_sRGB, OW, OH, MTLTextureUsageRenderTarget, 0), OD = tex2d(MTLPixelFormatDepth32Float, OW, OH, MTLTextureUsageRenderTarget, 0);
        double tot[3] = { 0 }; int n[3] = { 0 };
        for (int it = 0; it < 300; it++) {
            int mode = it % 3;   // (0 without the layers, 1 with (repacked once before), 2 with + the repack in the same buffer)
            vxw_params p = { 0 }; p.w = BW; p.h = BH; p.flags = VXW_POSE; p.tan_x = 1.444f; p.tan_y = 0.812f; p.z_a = 0.2f;
            float a = 0.05f; p.rot[0] = cosf(a); p.rot[2] = -sinf(a); p.rot[4] = 1; p.rot[6] = sinf(a); p.rot[8] = cosf(a);
            p.pos[0] = 0.032f; p.dst_tan[0] = 1.732f; p.dst_tan[1] = 1; p.dst_tan[2] = 1; p.dst_tan[3] = 1.192f; p.dst_near = 0.2f;
            if (mode) { p.t = 1.5f; p.flags |= VXW_CAM_MV; p.cam[0] = p.cam[4] = p.cam[8] = 1; }
            id<MTLCommandBuffer> cb = [q commandBuffer];
            vxw_set_interp(core, (__bridge void *)cb, mode ? (__bridge void *)g_outtex : NULL, W, H, mode == 2 ? 1000000 + (uint64_t)it : 7, 1, 1, 0.5f);
            vxw_encode_eye(core, (__bridge void *)cb, &p, (__bridge void *)Bv, NULL, (__bridge void *)zero_mv, (__bridge void *)D, (__bridge void *)O, (__bridge void *)OD);
            [cb commit]; [cb waitUntilCompleted];
            if (it >= 30) { tot[mode] += cb.GPUEndTime - cb.GPUStartTime; n[mode]++; }
        }
        printf("\nGPU, an eye (1600x900 -> 1888x1792, render pass + depth, this Mac): without the layers %.3f ms, with %.3f ms (+%.3f), with + a repack %.3f ms\n",
               tot[0] / n[0] * 1e3, tot[1] / n[1] * 1e3, (tot[1] / n[1] - tot[0] / n[0]) * 1e3, tot[2] / n[2] * 1e3);
    }
    }
    return 0;
}
