// tests/enc_assoc_mac.m - libvxmtl's per-encoder records (h64): dropped at endEncoding, and the sampled probe that tells
// whether the device frees an encoder's associations with it. Depth passes as the game's, the host's pass hook set.
//   xcrun clang -fobjc-arc -O1 tests/enc_assoc_mac.m -framework Metal -framework QuartzCore -framework Foundation -o build/enc_assoc_mac
//   VXMAC_MAC_TEST=1 DYLD_INSERT_LIBRARIES=build/macshim/libvxmtl.dylib build/enc_assoc_mac 20000 [VXMAC_ENC_CLEAR=0 to compare]
// Expected on the Mac (its encoders' dealloc frees their associations): enc_probes_live ~0 and malloc flat either way.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <malloc/malloc.h>
static void hook(void *cb, void *depth, int stores) { (void)cb; (void)depth; (void)stores; }
static size_t inuse(void) { malloc_statistics_t s; malloc_zone_statistics(NULL, &s); return s.size_in_use; }
int main(int argc, char **argv) { @autoreleasepool {
    int N = argc > 1 ? atoi(argv[1]) : 20000;
    void (*set)(void *) = dlsym(RTLD_DEFAULT, "vxmtl_set_pass_hook"); void (*st)(char *, unsigned) = dlsym(RTLD_DEFAULT, "vxmtl_enc_stats");
    if (set) set((void *)hook);   // (without libvxmtl: the baseline)
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [d newCommandQueue];
    { CAMetalLayer *l = [CAMetalLayer layer]; l.device = d; l.drawableSize = CGSizeMake(64, 64); (void)[l nextDrawable]; }   // (libvxmtl hooks the command buffer class at the first drawable)
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:64 height:64 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth = [d newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatRG16Float; id<MTLTexture> vel = [d newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].texture = vel; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    size_t m0 = 0; id<MTLCommandBuffer> last = nil;
    for (int i = 0; i < N; i++) { @autoreleasepool {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        for (int e = 0; e < 4; e++) { id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp]; [re endEncoding]; }
        [cb commit]; if (i % 32 == 31) [cb waitUntilCompleted]; last = cb;
    } if (i == 1000) m0 = inuse(); }
    [last waitUntilCompleted]; usleep(200000);
    char s[200] = "no libvxmtl"; if (st) st(s, sizeof s);
    printf("%d command buffers x 4 depth passes: malloc in use %+.1f B per command buffer after warm-up; %s\n", N, ((double)inuse() - m0) / (N - 1000), s);
    return 0;
} }
