// The game's own motion vectors (VX Mac; docs/DESIGN.md). The Mac build writes a two-channel float target in its
// G-buffer pass (RG16Float, colour attachment 3 at the render size, h24: 853x480 with 1280x720 out). Each frame the
// newest one is copied when its pass ends (the game's own command buffer; the target may be an aliased heap resource,
// so it is copied at once) and its mean over the centre measured. Before the presenter uses it, it is verified:
//   - against the image check's measured turn of the same frame (host.m): the regression of the picture's shift (in
//     frame widths / heights) on the target's mean gives its scale and sign on each axis, and the correlation says
//     whether it is motion at all;
//   - on frames where the picture did not move, the target's mean must stay near zero.
// Only with |correlation| >= 0.7 over at least 30 moving frames, and the static mean under 10 % of the moving one, is it
// handed to the presenter as its motion vectors (vxmac_vel_take). VXMAC_VEL=0: off; VXMAC_VEL_INDEX (default 3) and
// VXMAC_VEL_FORMAT (default 65, RG16Float) choose the target.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <pthread.h>

void vxmac_jlog(const char *event, const char *fields);

enum { kVSlots = 3 };
static int g_on = -1, g_index = 3; static unsigned long g_format = 65;
static id<MTLTexture> g_copy[kVSlots]; static id<MTLBuffer> g_mean[kVSlots]; static int g_slot;
static id<MTLComputePipelineState> g_mean_pso;
static pthread_mutex_t g_l = PTHREAD_MUTEX_INITIALIZER;
static id<MTLTexture> g_latest; static id<MTLBuffer> g_latest_mean; static uint64_t g_seq, g_taken;
// (the verification's sums)
static double sxx, sxy, syy_, s_x_uv, s_uu, s_vy, s_y_uv, s_vv_y, s_static, s_moving; static unsigned n_move, n_static;
static int g_ok; static float g_kx, g_ky, g_corr;

static int vel_on(void) {
    if (g_on < 0) {
        const char *e = getenv("VXMAC_VEL"); g_on = !(e && !strcmp(e, "0"));
        e = getenv("VXMAC_VEL_INDEX"); if (e && *e) g_index = atoi(e);
        e = getenv("VXMAC_VEL_FORMAT"); if (e && *e) g_format = strtoul(e, NULL, 10);
    }
    return g_on;
}

// A two-channel float target of a pass with depth ended (the program's thread; cb not committed yet)
void vxmac_vel_target(void *cbp, void *texp, int index) {
    if (!vel_on()) return;
    id<MTLTexture> t = (__bridge id<MTLTexture>)texp;
    if (index != g_index || t.pixelFormat != g_format || t.width < 256) return;
    // (h26: never found on the device with 2D only - the Mac game's targets are one-slice arrays like its depth; the
    //  copy takes slice 0 either way. Anything else is said once)
    if (!(t.textureType == MTLTextureType2D || (t.textureType == MTLTextureType2DArray && t.arrayLength == 1))) {
        static int told;
        if (!told++) { char f[160]; snprintf(f, sizeof f, "\"why\":\"texture type %lu array %lu\",\"w\":%lu,\"h\":%lu", (unsigned long)t.textureType,
                                             (unsigned long)t.arrayLength, (unsigned long)t.width, (unsigned long)t.height); vxmac_jlog("vel_skip", f); }
        return;
    }
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
    id<MTLDevice> dev = cb.device;
    if (!g_mean_pso) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void vm(texture2d<float> v [[texture(0)]], device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
            "  if (i > 0) return; float sx = 0, sy = 0, sa = 0; uint w = v.get_width(), h = v.get_height(), n = 0;\n"
            "  for (uint y = h / 4; y < h * 3 / 4; y += 6) for (uint x = w / 4; x < w * 3 / 4; x += 6) { float2 m = v.read(uint2(x, y)).xy; if (all(isfinite(m))) { sx += m.x; sy += m.y; sa += abs(m.x) + abs(m.y); n++; } }\n"
            "  o[0] = n ? sx / n : 0; o[1] = n ? sy / n : 0; o[2] = n ? sa / n : 0; }\n";
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        g_mean_pso = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"vm"] error:&err] : nil;
        if (!g_mean_pso) { g_on = 0; vxmac_jlog("vel_off", "\"why\":\"pipeline\""); return; }
        char f[160]; snprintf(f, sizeof f, "\"w\":%lu,\"h\":%lu,\"format\":%lu,\"index\":%d", (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, index);
        vxmac_jlog("vel_found", f);
    }
    int s = g_slot; g_slot = (g_slot + 1) % kVSlots;
    if (!g_copy[s] || g_copy[s].width != t.width || g_copy[s].height != t.height) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:t.width height:t.height mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate;
        g_copy[s] = [dev newTextureWithDescriptor:d];
        g_mean[s] = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    }
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1)
             toTexture:g_copy[s] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [b endEncoding];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:g_mean_pso]; [e setTexture:g_copy[s] atIndex:0]; [e setBuffer:g_mean[s] offset:0 atIndex:0];
    [e dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [e endEncoding];
    pthread_mutex_lock(&g_l); g_latest = g_copy[s]; g_latest_mean = g_mean[s]; g_seq++; pthread_mutex_unlock(&g_l);
}

// The newest target's mean buffer (for the verification at the frame's present)
void *vxmac_vel_latest_mean(void) {
    pthread_mutex_lock(&g_l); void *m = (__bridge void *)g_latest_mean; pthread_mutex_unlock(&g_l);
    return m;
}

// One frame of the verification: the picture's measured shift (fractions of the frame's width / height, + right / down)
// and the target's means (read after the frame completed)
void vxmac_vel_verify(float ux, float uy, const float *mean) {
    if (!mean || g_on <= 0) return;
    float vx = mean[0], vy = mean[1], va = mean[2];
    if (fabsf(ux) > 0.004f) {   // (moving: over 0.4 % of the width a frame)
        sxx += (double)vx * vx; sxy += (double)vx * ux; syy_ += (double)ux * ux;
        s_vv_y += (double)vy * vy; s_y_uv += (double)vy * uy; s_vy += (double)uy * uy;
        s_moving += va; n_move++;
    } else if (fabsf(ux) < 0.0005f && fabsf(uy) < 0.0005f) { s_static += va; n_static++; }
    static double last; double now = CACurrentMediaTime();
    if (now - last < 2.0 || n_move < 10) return;
    last = now;
    double corr = sxx > 0 && syy_ > 0 ? sxy / sqrt(sxx * syy_) : 0;
    double kx = sxx > 0 ? sxy / sxx : 0, ky = s_vv_y > 0 ? s_y_uv / s_vv_y : 0;
    double mov = n_move ? s_moving / n_move : 0, stat = n_static ? s_static / n_static : -1;
    // (h27: still frames keep 13-24 % of the moving frames' mean - people and the camera's own sway - with corr -0.97;
    //  the bar was 10 % and the target never passed. 35 % now, with the correlation the real test)
    int ok = n_move >= 30 && fabs(corr) >= 0.8 && stat >= 0 && stat < 0.35 * mov;
    char f[300]; snprintf(f, sizeof f, "\"moving_frames\":%u,\"static_frames\":%u,\"corr_x\":%.2f,\"k_x\":%.4f,\"k_y\":%.4f,\"moving_mean_abs\":%.5f,\"static_mean_abs\":%.5f,\"verified\":%d",
                          n_move, n_static, corr, kx, ky, mov, stat, ok);
    vxmac_jlog("vel_check", f);
    pthread_mutex_lock(&g_l); g_ok = ok; g_kx = (float)kx; g_ky = (float)ky; g_corr = (float)corr; pthread_mutex_unlock(&g_l);
}

// The newest copy for the presenter, once verified: its scale (frame UV a unit of the target, the sign included, for
// the presenter's convention "where the pixel was": the negative of the scene's motion)
int vxmac_vel_take(void **mv, float *mvs_x, float *mvs_y) {
    pthread_mutex_lock(&g_l);
    // (h27: off by default - the picture shook with head turns once it was used (every eye predicted in ddgame23); the
    //  check still runs and logs. VXMAC_VEL_PREDICT=1: used)
    static int use = -1;
    if (use < 0) { const char *e = getenv("VXMAC_VEL_PREDICT"); use = e && !strcmp(e, "1"); }
    int fresh = use && g_ok && g_latest && g_seq != g_taken;
    if (fresh) { *mv = (__bridge_retained void *)g_latest; *mvs_x = -g_kx; *mvs_y = -g_ky; g_taken = g_seq; }
    pthread_mutex_unlock(&g_l);
    return fresh;
}
