// vxmac_test: a small macOS Metal program shaped like the Mac game where it meets the system, built for macOS and run
// unchanged on Vision Pro by VX Mac Host (VXMac/docs/DESIGN.md). It uses the same calls the game does:
//   - AppKit the way the game does it: [NSApplication sharedApplication], a delegate, finishLaunching, its own loop of
//     nextEventMatchingMask:untilDate:inMode:dequeue: + sendEvent:, an NSWindow subclass with an NSView subclass whose
//     layer is a CAMetalLayer (setLayer: + setWantsLayer:), NSScreen, NSCursor, NSWorkspace, notifications;
//   - optionally (-displaylink) a CAMetalDisplayLink driving the frames, as the game's setupCAMetalLink does;
//   - Metal: a scene at render size (colour, depth, motion vectors, a sub-pixel jitter), upscaled by MetalFX's temporal
//     scaler (looked up by name, as the game does) or its spatial scaler, into the drawable, presented by the command
//     buffer;
//   - CoreGraphics display calls, IOKit display calls, libcurl (an offline request), bz2, a memory-pool setup with
//     the game's three large reservations (16, 64, 32 GB as immediates in one function).
// It prints one "vxt" line a second (fps, scaler, sizes, events) and a summary at the end; -seconds N (default 20).
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#include <curl/curl.h>
#include <bzlib.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <objc/runtime.h>
#include <objc/message.h>

static double g_seconds = 20, g_t0;
static int g_quit, g_use_link, g_frames, g_events, g_keys, g_mouse;
static double g_mouse_dx, g_mouse_dy;
static id<MTLDevice> g_dev;
static id<MTLCommandQueue> g_queue;
static CAMetalLayer *g_layer;
static const char *g_scaler = "none";

#define RW 640
#define RH 360
#define OW 1280
#define OH 720

// ---- memory pools: three reservations from immediates in one function, as the game's pool setup ----------------------
typedef struct { uint64_t size; void *base; } pool;
static pool g_pools[3];
__attribute__((noinline)) static void *reserve(uint64_t size) {
    void *p = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}
__attribute__((noinline, used)) void vxt_pools_init(pool *out) {
    // (one constant each, kept in a register by the compiler: the shape of the game's 0x10000fdc0)
    uint64_t a, b, c;
    __asm__ volatile("mov %0, #0x400000000" : "=r"(a));
    out[0].size = a; out[0].base = reserve(a);
    __asm__ volatile("mov %0, #0x1000000000" : "=r"(b));
    out[1].size = b; out[1].base = reserve(b);
    __asm__ volatile("mov %0, #0x800000000" : "=r"(c));
    out[2].size = c; out[2].base = reserve(c);
}

// ---- Metal ----------------------------------------------------------------------------------------------------------
static NSString *kShader = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct V { float4 p [[position]]; float3 c; float2 mv; };\n"
"struct O { float4 c [[color(0)]]; float2 mv [[color(1)]]; };\n"
"struct U { float t, dt, jx, jy; };\n"
"vertex V vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant U &u [[buffer(0)]]) {\n"
"  float2 tri[3] = { float2(0, 0.6), float2(-0.5, -0.4), float2(0.5, -0.4) };\n"
"  float k = float(iid); float z = 0.2 + 0.15 * k;\n"
"  float a = u.t * (0.7 + 0.3 * k), ap = (u.t - u.dt) * (0.7 + 0.3 * k);\n"
"  float2 q = tri[vid] * (0.9 - 0.2 * k);\n"
"  float2 r = float2(q.x * cos(a) - q.y * sin(a), q.x * sin(a) + q.y * cos(a)) + float2(0.3 * k - 0.3, 0);\n"
"  float2 rp = float2(q.x * cos(ap) - q.y * sin(ap), q.x * sin(ap) + q.y * cos(ap)) + float2(0.3 * k - 0.3, 0);\n"
"  V o; o.p = float4(r + float2(u.jx, u.jy), z, 1);\n"
"  o.c = float3(vid == 0, vid == 1, vid == 2) * (1.0 - 0.25 * k) + 0.1;\n"
"  o.mv = (rp - r) * float2(0.5, -0.5);\n"
"  return o; }\n"
"fragment O fs(V i [[stage_in]]) { O o; o.c = float4(i.c, 1); o.mv = i.mv; return o; }\n";

static id<MTLRenderPipelineState> g_pso;
static id<MTLDepthStencilState> g_dss;
static id<MTLTexture> g_color, g_depth, g_motion, g_out;
static id g_temporal, g_spatial;

static void metal_setup(void) {
    g_dev = MTLCreateSystemDefaultDevice();
    g_queue = [g_dev newCommandQueue];
    NSError *err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:kShader options:nil error:&err];
    if (!lib) { printf("vxt error shader %s\n", err.description.UTF8String); exit(2); }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    pd.colorAttachments[1].pixelFormat = MTLPixelFormatRG16Float;
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    g_pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!g_pso) { printf("vxt error pso %s\n", err.description.UTF8String); exit(2); }
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLess; dd.depthWriteEnabled = YES;
    g_dss = [g_dev newDepthStencilStateWithDescriptor:dd];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:RW height:RH mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
    g_color = [g_dev newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatRG16Float; g_motion = [g_dev newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float; g_depth = [g_dev newTextureWithDescriptor:td];
    td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:OW height:OH mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; td.storageMode = MTLStorageModePrivate;
    g_out = [g_dev newTextureWithDescriptor:td];

    // MetalFX by name, as the game finds it (NSClassFromString + respondsToSelector)
    Class tdc = NSClassFromString(@"MTLFXTemporalScalerDescriptor");
    Class sdc = NSClassFromString(@"MTLFXSpatialScalerDescriptor");
    BOOL tsup = tdc && [tdc respondsToSelector:@selector(supportsDevice:)] && ((BOOL (*)(id, SEL, id))objc_msgSend)(tdc, @selector(supportsDevice:), g_dev);
    printf("vxt metalfx temporal_class=%d temporal_supported=%d spatial_class=%d\n", tdc != nil, tsup, sdc != nil);
    if (tdc && tsup && !getenv("VXT_NO_TEMPORAL")) {
        id d = [tdc new];
        [d setValue:@(MTLPixelFormatRGBA16Float) forKey:@"colorTextureFormat"];
        [d setValue:@(MTLPixelFormatDepth32Float) forKey:@"depthTextureFormat"];
        [d setValue:@(MTLPixelFormatRG16Float) forKey:@"motionTextureFormat"];
        [d setValue:@(MTLPixelFormatRGBA16Float) forKey:@"outputTextureFormat"];
        [d setValue:@(RW) forKey:@"inputWidth"]; [d setValue:@(RH) forKey:@"inputHeight"];
        [d setValue:@(OW) forKey:@"outputWidth"]; [d setValue:@(OH) forKey:@"outputHeight"];
        g_temporal = ((id (*)(id, SEL, id))objc_msgSend)(d, @selector(newTemporalScalerWithDevice:), g_dev);
        if (g_temporal) g_scaler = "temporal";
    }
    if (!g_temporal && sdc) {
        id d = [sdc new];
        [d setValue:@(MTLPixelFormatRGBA16Float) forKey:@"colorTextureFormat"];
        [d setValue:@(MTLPixelFormatRGBA16Float) forKey:@"outputTextureFormat"];
        [d setValue:@(RW) forKey:@"inputWidth"]; [d setValue:@(RH) forKey:@"inputHeight"];
        [d setValue:@(OW) forKey:@"outputWidth"]; [d setValue:@(OH) forKey:@"outputHeight"];
        g_spatial = ((id (*)(id, SEL, id))objc_msgSend)(d, @selector(newSpatialScalerWithDevice:), g_dev);
        if (g_spatial) g_scaler = "spatial";
    }
    printf("vxt scaler %s device \"%s\"\n", g_scaler, g_dev.name.UTF8String);
}

static float halton(int i, int b) { float f = 1, r = 0; while (i > 0) { f /= b; r += f * (i % b); i /= b; } return r; }

static void render(id<CAMetalDrawable> drawable) {
    if (!drawable) return;
    static double last; double now = CACurrentMediaTime();
    float dt = last ? (float)(now - last) : 1.f / 60; last = now;
    float jx = halton(g_frames % 8 + 1, 2) - 0.5f, jy = halton(g_frames % 8 + 1, 3) - 0.5f;
    struct { float t, dt, jx, jy; } u = { (float)(now - g_t0), dt, jx * 2.f / RW, jy * 2.f / RH };
    id<MTLCommandBuffer> cb = [g_queue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = g_color; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.07, 0.12, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[1].texture = g_motion; rp.colorAttachments[1].loadAction = MTLLoadActionClear; rp.colorAttachments[1].storeAction = MTLStoreActionStore;
    rp.depthAttachment.texture = g_depth; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.clearDepth = 1; rp.depthAttachment.storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:g_pso]; [re setDepthStencilState:g_dss];
    [re setVertexBytes:&u length:sizeof u atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:3];
    [re endEncoding];
    if (g_temporal) {
        id s = g_temporal;
        [s setValue:g_color forKey:@"colorTexture"]; [s setValue:g_depth forKey:@"depthTexture"];
        [s setValue:g_motion forKey:@"motionTexture"]; [s setValue:g_out forKey:@"outputTexture"];
        [s setValue:@(jx) forKey:@"jitterOffsetX"]; [s setValue:@(jy) forKey:@"jitterOffsetY"];
        [s setValue:@((float)RW) forKey:@"motionVectorScaleX"]; [s setValue:@((float)RH) forKey:@"motionVectorScaleY"];
        [s setValue:@(RW) forKey:@"inputContentWidth"]; [s setValue:@(RH) forKey:@"inputContentHeight"];
        ((void (*)(id, SEL, id))objc_msgSend)(s, @selector(encodeToCommandBuffer:), cb);
    } else if (g_spatial) {
        id s = g_spatial;
        [s setValue:g_color forKey:@"colorTexture"]; [s setValue:g_out forKey:@"outputTexture"];
        [s setValue:@(RW) forKey:@"inputContentWidth"]; [s setValue:@(RH) forKey:@"inputContentHeight"];
        ((void (*)(id, SEL, id))objc_msgSend)(s, @selector(encodeToCommandBuffer:), cb);
    }
    // (into the drawable: a scaled copy through a render pass is not needed, sizes match: a plain blit when the
    // formats differ is not allowed, so draw it with a tiny pass)
    static id<MTLRenderPipelineState> copy;
    if (!copy) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 p [[position]]; float2 uv; };\n"
            "vertex V cv(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V o; o.p = float4(q * 2 - 1, 0, 1); o.uv = float2(q.x, 1 - q.y); return o; }\n"
            "fragment float4 cf(V i [[stage_in]], texture2d<float> t [[texture(0)]]) { constexpr sampler s(filter::linear); return t.sample(s, i.uv); }\n";
        id<MTLLibrary> l = [g_dev newLibraryWithSource:src options:nil error:nil];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [l newFunctionWithName:@"cv"]; pd.fragmentFunction = [l newFunctionWithName:@"cf"];
        pd.colorAttachments[0].pixelFormat = g_layer.pixelFormat;
        copy = [g_dev newRenderPipelineStateWithDescriptor:pd error:nil];
    }
    MTLRenderPassDescriptor *cp = [MTLRenderPassDescriptor renderPassDescriptor];
    cp.colorAttachments[0].texture = drawable.texture; cp.colorAttachments[0].loadAction = MTLLoadActionDontCare; cp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> ce = [cb renderCommandEncoderWithDescriptor:cp];
    [ce setRenderPipelineState:copy]; [ce setFragmentTexture:(g_temporal || g_spatial) ? g_out : g_color atIndex:0];
    [ce drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [ce endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
    g_frames++;
}

// ---- AppKit, as the game uses it ------------------------------------------------------------------------------------
@interface VXTView : NSView <CAMetalDisplayLinkDelegate>
@end
@implementation VXTView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e { g_keys++; if (e.keyCode == 53) g_quit = 1; }
- (void)keyUp:(NSEvent *)e { (void)e; }
- (void)mouseMoved:(NSEvent *)e { g_mouse++; g_mouse_dx += e.deltaX; g_mouse_dy += e.deltaY; }
- (void)mouseDown:(NSEvent *)e { (void)e; g_mouse++; }
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    (void)link; render(update.drawable);
}
@end

@interface VXTWindow : NSWindow
@end
@implementation VXTWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface VXTDelegate : NSObject <NSApplicationDelegate>
@end
@implementation VXTDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)n { (void)n; printf("vxt delegate applicationDidFinishLaunching\n"); }
- (void)applicationDidBecomeActive:(NSNotification *)n { (void)n; printf("vxt delegate applicationDidBecomeActive\n"); }
@end

static void probe_system(void) {
    CGDirectDisplayID d = CGMainDisplayID();
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);
    printf("vxt cg main=%u %zux%zu px %.0f Hz builtin=%d\n", d, CGDisplayPixelsWide(d), CGDisplayPixelsHigh(d),
           m ? CGDisplayModeGetRefreshRate(m) : 0.0, CGDisplayIsBuiltin(d));
    if (m) CGDisplayModeRelease(m);
    uint32_t n = 0; CGGetActiveDisplayList(0, NULL, &n);
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
    CFTypeRef model = s ? IORegistryEntryCreateCFProperty(s, CFSTR("model"), kCFAllocatorDefault, 0) : NULL;
    printf("vxt iokit platform=%d model=%s displays=%u\n", s != 0, model ? "yes" : "no", n);
    if (model) CFRelease(model);
    if (s) IOObjectRelease(s);
    NSScreen *sc = NSScreen.mainScreen;
    printf("vxt screen %.0fx%.0f scale %.1f max_fps %ld screens %lu\n", sc.frame.size.width, sc.frame.size.height, sc.backingScaleFactor,
           (long)sc.maximumFramesPerSecond, (unsigned long)NSScreen.screens.count);
    curl_global_init(CURL_GLOBAL_DEFAULT);
    CURL *c = curl_easy_init();
    curl_easy_setopt(c, CURLOPT_URL, "https://localhost.invalid/vxt");
    curl_easy_setopt(c, CURLOPT_TIMEOUT, 2L);
    CURLcode r = curl_easy_perform(c);
    long code = 0; curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
    printf("vxt curl perform=%d (%s) http=%ld\n", r, curl_easy_strerror(r), code);
    curl_easy_cleanup(c);
    char in[64] = "vxt bz2 roundtrip", z[256], out[64]; unsigned zl = sizeof z, ol = sizeof out;
    int b1 = BZ2_bzBuffToBuffCompress(z, &zl, in, (unsigned)strlen(in) + 1, 9, 0, 0);
    int b2 = BZ2_bzBuffToBuffDecompress(out, &ol, z, zl, 0, 0);
    printf("vxt bz2 %d %d %s\n", b1, b2, b2 == BZ_OK && !strcmp(in, out) ? "ok" : "bad");
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    printf("vxt bundle %s\nvxt resources %s\nvxt documents %s\n", NSBundle.mainBundle.bundlePath.UTF8String,
           NSBundle.mainBundle.resourcePath.UTF8String, docs.path.UTF8String);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "-seconds") && i + 1 < argc) g_seconds = atof(argv[++i]);
            else if (!strcmp(argv[i], "-displaylink")) g_use_link = 1;
        }
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("vxt start pid %d\n", getpid());
        vxt_pools_init(g_pools);
        uint64_t total = 0;
        for (int i = 0; i < 3; i++) { printf("vxt pool %d size %llu MB base %p\n", i, g_pools[i].size >> 20, g_pools[i].base); total += g_pools[i].base ? g_pools[i].size : 0; }
        printf("vxt pools reserved %llu GB\n", total >> 30);

        [NSApplication sharedApplication];
        VXTDelegate *del = [VXTDelegate new];
        NSApp.delegate = del;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        probe_system();
        metal_setup();

        VXTWindow *w = [[VXTWindow alloc] initWithContentRect:NSMakeRect(0, 0, OW / 2, OH / 2)
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                      backing:NSBackingStoreBuffered defer:NO];
        VXTView *v = [[VXTView alloc] initWithFrame:NSMakeRect(0, 0, OW / 2, OH / 2)];
        g_layer = [CAMetalLayer layer];
        g_layer.device = g_dev; g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm; g_layer.framebufferOnly = YES;
        g_layer.drawableSize = CGSizeMake(OW, OH);
        v.layer = g_layer; v.wantsLayer = YES;
        w.contentView = v; w.acceptsMouseMovedEvents = YES; w.title = @"vxmac_test";
        [w makeKeyAndOrderFront:nil];
        [w makeFirstResponder:v];
        printf("vxt window %.0fx%.0f backing %.1f\n", w.frame.size.width, w.frame.size.height, w.backingScaleFactor);

        CAMetalDisplayLink *link = nil;
        if (g_use_link) {
            link = [[CAMetalDisplayLink alloc] initWithMetalLayer:g_layer];
            link.delegate = v;
            link.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 60);
            [link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
            printf("vxt displaylink on\n");
        }
        g_t0 = CACurrentMediaTime();
        double next = g_t0 + 1; int last_frames = 0;
        while (!g_quit) {
            @autoreleasepool {
                NSEvent *e;
                while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:(g_use_link ? [NSDate dateWithTimeIntervalSinceNow:0.002] : NSDate.distantPast)
                                                   inMode:NSDefaultRunLoopMode dequeue:YES])) {
                    g_events++;
                    [NSApp sendEvent:e];
                }
                if (!g_use_link) render([g_layer nextDrawable]);
                double now = CACurrentMediaTime();
                if (now >= next) {
                    printf("vxt t=%.0f fps=%d frames=%d events=%d keys=%d mouse=%d (%.0f,%.0f) scaler=%s\n", now - g_t0, g_frames - last_frames,
                           g_frames, g_events, g_keys, g_mouse, g_mouse_dx, g_mouse_dy, g_scaler);
                    last_frames = g_frames; next += 1;
                }
                if (now - g_t0 >= g_seconds) break;
            }
        }
        [link invalidate];
        printf("vxt done frames=%d in %.1f s scaler=%s pools=%lluGB -> %s\n", g_frames, CACurrentMediaTime() - g_t0, g_scaler, total >> 30,
               g_frames > 0 ? "ok" : "no frames");
    }
    return 0;
}
