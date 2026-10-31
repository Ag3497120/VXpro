// libvxmtlfx: MetalFX for a macOS program on visionOS. The real MetalFX is re-exported; added here (VXMac/docs/DESIGN.md,
// "MetalFX"):
//   - the interposer: every temporal scaler the program makes (MTLFXTemporalScalerDescriptor
//     -newTemporalScalerWithDevice:, which the game finds by name) comes back wrapped in a proxy that forwards all
//     calls to the real scaler and, at each -encodeToCommandBuffer:, records its inputs (colour, depth, motion vectors,
//     the output, jitter, motion-vector scale, content size, reset) for the host's VR presenter (vxfx_take_frame):
//     depth and motion vectors are what its warp core needs for stereo, reprojection and frame prediction;
//   - a temporal scaler of our own where MetalFX has none (the headers mark MTLFXTemporalScaler unavailable on
//     visionOS; if the device says it is unsupported or making one fails): +supportsDevice: says YES and
//     -newTemporalScalerWithDevice: returns VXFXTemporalScaler, a jitter-compensated bilinear upscale (one compute
//     pass; no history: a stand-in so the program's upscaled path runs) with the same properties and the same capture.
// Knobs: VXMAC_FX_FALLBACK=0 never ours; VXMAC_FX_FORCE_FALLBACK=1 always ours (a Mac test of the stand-in).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <pthread.h>
#include "vxmac.h"

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static vxfx_frame g_last;
static int g_fresh;
static unsigned long g_encodes, g_fallback_encodes, g_proxies, g_fallbacks;
static int g_force_fallback, g_allow_fallback = 1;
static char g_real_state[64] = "not asked";

static void retain_into(void **slot, id o) { *slot = o ? (__bridge_retained void *)o : NULL; }
static void release_slot(void **slot) { if (*slot) CFRelease(*slot); *slot = NULL; }
static void capture(id s, int fallback) {
    vxfx_frame f = { 0 };
    retain_into(&f.color, ((id (*)(id, SEL))objc_msgSend)(s, @selector(colorTexture)));
    retain_into(&f.depth, ((id (*)(id, SEL))objc_msgSend)(s, @selector(depthTexture)));
    retain_into(&f.motion, ((id (*)(id, SEL))objc_msgSend)(s, @selector(motionTexture)));
    retain_into(&f.output, ((id (*)(id, SEL))objc_msgSend)(s, @selector(outputTexture)));
    f.jitter_x = ((float (*)(id, SEL))objc_msgSend)(s, @selector(jitterOffsetX));
    f.jitter_y = ((float (*)(id, SEL))objc_msgSend)(s, @selector(jitterOffsetY));
    f.mv_scale_x = ((float (*)(id, SEL))objc_msgSend)(s, @selector(motionVectorScaleX));
    f.mv_scale_y = ((float (*)(id, SEL))objc_msgSend)(s, @selector(motionVectorScaleY));
    f.input_w = (uint32_t)((NSUInteger (*)(id, SEL))objc_msgSend)(s, @selector(inputContentWidth));
    f.input_h = (uint32_t)((NSUInteger (*)(id, SEL))objc_msgSend)(s, @selector(inputContentHeight));
    f.output_w = (uint32_t)((NSUInteger (*)(id, SEL))objc_msgSend)(s, @selector(outputWidth));
    f.output_h = (uint32_t)((NSUInteger (*)(id, SEL))objc_msgSend)(s, @selector(outputHeight));
    f.reset = ((BOOL (*)(id, SEL))objc_msgSend)(s, @selector(reset));
    f.depth_reversed = ((BOOL (*)(id, SEL))objc_msgSend)(s, @selector(isDepthReversed));
    f.fallback = fallback;
    f.time = CACurrentMediaTime();
    pthread_mutex_lock(&g_lock);
    release_slot(&g_last.color); release_slot(&g_last.depth); release_slot(&g_last.motion); release_slot(&g_last.output);
    g_last = f; g_fresh = 1;
    if (fallback) g_fallback_encodes++; else g_encodes++;
    pthread_mutex_unlock(&g_lock);
}
int vxfx_take_frame(vxfx_frame *out) {
    pthread_mutex_lock(&g_lock);
    int fresh = g_fresh;
    if (fresh) { *out = g_last; memset(&g_last, 0, sizeof g_last); g_fresh = 0; }
    pthread_mutex_unlock(&g_lock);
    return fresh;
}
void vxfx_stats(char *out, unsigned size) {
    snprintf(out, size, "\"fx_encodes\":%lu,\"fx_fallback_encodes\":%lu,\"fx_proxies\":%lu,\"fx_fallbacks\":%lu,\"fx_real\":\"%s\"",
             g_encodes, g_fallback_encodes, g_proxies, g_fallbacks, g_real_state);
}

// ---- the proxy around a real scaler ------------------------------------------------------------------------------------
@interface VXFXTemporalProxy : NSProxy
- (instancetype)initWithTarget:(id)t;
@end
@implementation VXFXTemporalProxy { id _t; }
- (instancetype)initWithTarget:(id)t { _t = t; return self; }
- (id)forwardingTargetForSelector:(SEL)s { return s == @selector(encodeToCommandBuffer:) ? nil : _t; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [_t methodSignatureForSelector:s]; }
- (void)forwardInvocation:(NSInvocation *)inv { [inv invokeWithTarget:_t]; }
- (BOOL)respondsToSelector:(SEL)s { return [_t respondsToSelector:s]; }
- (BOOL)conformsToProtocol:(Protocol *)p { return [_t conformsToProtocol:p]; }
- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)cb {
    ((void (*)(id, SEL, id))objc_msgSend)(_t, @selector(encodeToCommandBuffer:), cb);
    capture(_t, 0);
}
@end

// ---- our stand-in scaler ------------------------------------------------------------------------------------------------
static NSString *kKernel = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct P { float2 scale; float2 jitter; float2 insize; };\n"
"kernel void up(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],\n"
"               constant P &p [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;\n"
"  constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);\n"
"  float2 q = (float2(g) + 0.5) * p.scale + p.jitter;\n"   // (the jittered input's pixel, the jitter taken back out)
"  q = clamp(q, float2(0.5), p.insize - 0.5);\n"
"  dst.write(src.sample(s, q), g);\n"
"}\n";
@interface VXFXTemporalScaler : NSObject
@property (strong) id<MTLTexture> colorTexture, depthTexture, motionTexture, outputTexture, exposureTexture, reactiveMaskTexture;
@property (strong) id fence;
@property float jitterOffsetX, jitterOffsetY, motionVectorScaleX, motionVectorScaleY, preExposure;
@property NSUInteger inputContentWidth, inputContentHeight;
@property (getter=isDepthReversed) BOOL depthReversed;
@property BOOL reset;
@property (readonly) NSUInteger inputWidth, inputHeight, outputWidth, outputHeight;
@property (readonly) MTLPixelFormat colorTextureFormat, depthTextureFormat, motionTextureFormat, outputTextureFormat;
@property (readonly) float inputContentMinScale, inputContentMaxScale;
@end
@implementation VXFXTemporalScaler {
    id<MTLDevice> _dev; id<MTLComputePipelineState> _pso;
}
- (instancetype)initWithDescriptor:(id)d device:(id<MTLDevice>)dev {
    if (!(self = [super init])) return nil;
    _dev = dev;
#define GETU(k) ((NSUInteger (*)(id, SEL))objc_msgSend)(d, @selector(k))
    _inputWidth = GETU(inputWidth); _inputHeight = GETU(inputHeight); _outputWidth = GETU(outputWidth); _outputHeight = GETU(outputHeight);
    _colorTextureFormat = GETU(colorTextureFormat); _depthTextureFormat = GETU(depthTextureFormat);
    _motionTextureFormat = GETU(motionTextureFormat); _outputTextureFormat = GETU(outputTextureFormat);
    _inputContentWidth = _inputWidth; _inputContentHeight = _inputHeight;
    _inputContentMinScale = 1; _inputContentMaxScale = 3; _preExposure = 1;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kKernel options:nil error:&err];
    _pso = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"up"] error:&err] : nil;
    if (!_pso) { vxmac_log("MetalFX: stand-in scaler: no pipeline (%s)", err.localizedDescription.UTF8String); return nil; }
    vxmac_log("MetalFX: stand-in temporal scaler %lux%lu -> %lux%lu (bilinear, jitter taken out; no history)",
              (unsigned long)_inputWidth, (unsigned long)_inputHeight, (unsigned long)_outputWidth, (unsigned long)_outputHeight);
    return self;
}
- (MTLTextureUsage)colorTextureUsage { return MTLTextureUsageShaderRead; }
- (MTLTextureUsage)depthTextureUsage { return MTLTextureUsageShaderRead; }
- (MTLTextureUsage)motionTextureUsage { return MTLTextureUsageShaderRead; }
- (MTLTextureUsage)reactiveTextureUsage { return MTLTextureUsageShaderRead; }
- (MTLTextureUsage)outputTextureUsage { return MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget; }
- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)cb {
    id<MTLTexture> src = self.colorTexture, dst = self.outputTexture;
    if (src && dst && _pso) {
        struct { float sx, sy, jx, jy, iw, ih; } p = {
            (float)self.inputContentWidth / (float)dst.width, (float)self.inputContentHeight / (float)dst.height,
            -self.jitterOffsetX, -self.jitterOffsetY, (float)self.inputContentWidth, (float)self.inputContentHeight };
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:_pso];
        [e setTexture:src atIndex:0]; [e setTexture:dst atIndex:1];
        [e setBytes:&p length:sizeof p atIndex:0];
        [e dispatchThreads:MTLSizeMake(dst.width, dst.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [e endEncoding];
    }
    capture(self, 1);
}
@end

// ---- the descriptor's methods -----------------------------------------------------------------------------------------
typedef id (*new_imp)(id, SEL, id) __attribute__((ns_returns_retained));   // (new*: +1, as the caller expects)
typedef BOOL (*supports_imp)(id, SEL, id);
static new_imp o_new;
static supports_imp o_supports;
static BOOL h_supports(id self, SEL s, id dev) {
    BOOL real = o_supports ? o_supports(self, s, dev) : NO;
    snprintf(g_real_state, sizeof g_real_state, "%s", real ? "supported" : "unsupported");
    return (real && !g_force_fallback) || g_allow_fallback;
}
__attribute__((ns_returns_retained)) static id h_new(id self, SEL s, id dev) {
    id real = nil;
    if (!g_force_fallback && o_new && (!o_supports || o_supports([self class], @selector(supportsDevice:), dev))) {
        @try { real = o_new(self, s, dev); } @catch (id ex) { vxmac_log("MetalFX: newTemporalScalerWithDevice: threw"); real = nil; }
    }
    if (real) {
        g_proxies++;
        snprintf(g_real_state, sizeof g_real_state, "in use");
        vxmac_log("MetalFX: temporal scaler %s, inputs captured", class_getName(object_getClass(real)));
        return [[VXFXTemporalProxy alloc] initWithTarget:real];
    }
    if (!g_allow_fallback) return nil;
    id ours = [[VXFXTemporalScaler alloc] initWithDescriptor:self device:dev];
    if (ours) g_fallbacks++;
    return ours;
}

__attribute__((constructor)) static void vxfx_init(void) {
    const char *e = getenv("VXMAC_FX_FALLBACK"); g_allow_fallback = !e || strcmp(e, "0");
    e = getenv("VXMAC_FX_FORCE_FALLBACK"); g_force_fallback = e && !strcmp(e, "1");
    Class d = objc_getClass("MTLFXTemporalScalerDescriptor");
    if (!d) { vxmac_log("MetalFX: no MTLFXTemporalScalerDescriptor class: nothing to interpose"); return; }
    Method m = class_getInstanceMethod(d, @selector(newTemporalScalerWithDevice:));
    if (m) o_new = (new_imp)method_setImplementation(m, (IMP)h_new);
    Method cm = class_getClassMethod(d, @selector(supportsDevice:));
    if (cm) o_supports = (supports_imp)method_setImplementation(cm, (IMP)h_supports);
    else class_addMethod(object_getClass(d), @selector(supportsDevice:), (IMP)h_supports, "c@:@");
}
