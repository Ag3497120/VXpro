// pass_profile_mac (Mac): libvxmtl's per-pass GPU profile (shims/vxprof.m, VXMAC_PASS_PROFILE=1) on a known workload.
// Each frame, on a CAMetalLayer's drawable, the way the game makes its passes: a heavy and a light full-screen render
// pass (2048x2048 RGBA16F; the fragment loop 24x longer in the heavy one), a compute encoder from computeCommandEncoder
// with two kernels, one from computeCommandEncoderWithDispatchType:Concurrent, a blit from blitCommandEncoder, a pass
// into the drawable, present; plus a "VX Mac compositor" queue's pass (never sampled). Shaders come from a metallib
// through newLibraryWithData: (as the game's), so the pipelines carry their library's hash.
// Prints the frames' checksums (the compute output read back): the same with and without the profile and without
// libvxmtl at all = the game's results unchanged.
// Build:
//   xcrun metal -c tests/pass_profile_mac.metal -o /tmp/pp.air && xcrun metallib /tmp/pp.air -o /tmp/pp.metallib
//   xcrun --sdk macosx clang -fobjc-arc -O1 tests/pass_profile_mac.m -framework Metal -framework QuartzCore -framework Foundation -o /tmp/pp
// Run (make -C shims mac first):
//   VXMAC_MAC_TEST=1 VXMAC_PASS_PROFILE=1 VXMAC_PASS_PROFILE_EVERY=0.3 VXMAC_PASS_PROFILE_FILE=/tmp/pp.txt \
//     DYLD_INSERT_LIBRARIES=build/macshim/libvxmtl.dylib /tmp/pp /tmp/pp.metallib 40
//   python3 tools/pass_profile.py /tmp/pp.txt
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: pp <metallib> [frames]\n"); return 2; }
    int frames = argc > 2 ? atoi(argv[2]) : 40;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSData *lib_bytes = [NSData dataWithContentsOfFile:@(argv[1])];
    dispatch_data_t dd = dispatch_data_create(lib_bytes.bytes, lib_bytes.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithData:dd error:&err];
    if (!lib) { fprintf(stderr, "library: %s\n", err.localizedDescription.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"vs_full"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    rd.fragmentFunction = [lib newFunctionWithName:@"ps_heavy"];
    id<MTLRenderPipelineState> heavy = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    rd.fragmentFunction = [lib newFunctionWithName:@"ps_light"];
    id<MTLRenderPipelineState> light = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> todraw = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    id<MTLComputePipelineState> k1 = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"cs_a"] error:&err];
    id<MTLComputePipelineState> k2 = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"cs_b"] error:&err];
    if (!heavy || !light || !todraw || !k1 || !k2) { fprintf(stderr, "pipelines: %s\n", err.localizedDescription.UTF8String); return 1; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:2048 height:2048 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> ta = [dev newTextureWithDescriptor:td], tb = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> out = [dev newBufferWithLength:1024 * 1024 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> scratch = [dev newBufferWithLength:64 << 20 options:MTLResourceStorageModePrivate];
    CAMetalLayer *layer = [CAMetalLayer layer]; layer.device = dev; layer.pixelFormat = MTLPixelFormatBGRA8Unorm; layer.drawableSize = CGSizeMake(640, 360);
    id<MTLCommandQueue> q = [dev newCommandQueue], qc = [dev newCommandQueue]; qc.label = @"VX Mac compositor";
    uint64_t sum_all = 0;
    for (int f = 0; f < frames; f++) @autoreleasepool {
        id<CAMetalDrawable> d = [layer nextDrawable];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLTexture> ts[2] = { ta, tb }; id<MTLRenderPipelineState> ps[2] = { heavy, light };
        for (int i = 0; i < 2; i++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = ts[i]; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re setRenderPipelineState:ps[i]]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
            if (rp.sampleBufferAttachments[0].sampleBuffer) { fprintf(stderr, "FAIL: the program's descriptor was changed\n"); return 1; }
        }
        if (getenv("PP_THREADS")) {   // (the game encodes on several threads: 4 more command buffers encoded at once, in order)
            NSMutableArray *cbs = [NSMutableArray array]; for (int k = 0; k < 4; k++) [cbs addObject:[q commandBuffer]];
            for (id<MTLCommandBuffer> c in cbs) [c enqueue];
            dispatch_apply(4, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t k) {
                id<MTLCommandBuffer> c = cbs[k];
                for (int j = 0; j < 6; j++) {
                    id<MTLComputeCommandEncoder> x = (j & 1) ? [c computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent] : [c computeCommandEncoder];
                    [x setComputePipelineState:k1]; [x setTexture:ta atIndex:0]; [x setBuffer:scratch offset:0 atIndex:0];
                    [x dispatchThreadgroups:MTLSizeMake(16, 16, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)]; [x endEncoding];
                    id<MTLBlitCommandEncoder> y = [c blitCommandEncoder]; [y fillBuffer:scratch range:NSMakeRange(0, 4096) value:1]; [y endEncoding];
                }
                [c commit];
            });
        }
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:k1]; [ce setTexture:ta atIndex:0]; [ce setBuffer:out offset:0 atIndex:0];
        [ce dispatchThreadgroups:MTLSizeMake(1024 / 16, 1024 / 16, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [ce setComputePipelineState:k2]; [ce setTexture:tb atIndex:0];
        [ce dispatchThreads:MTLSizeMake(1024, 1024, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [ce endEncoding];
        id<MTLComputeCommandEncoder> cc = [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent];
        if (cc.dispatchType != MTLDispatchTypeConcurrent) { fprintf(stderr, "FAIL: dispatch type %ld\n", (long)cc.dispatchType); return 1; }
        [cc setComputePipelineState:k1]; [cc setTexture:tb atIndex:0]; [cc setBuffer:out offset:0 atIndex:0];
        [cc dispatchThreadgroups:MTLSizeMake(8, 8, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [cc endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; [be fillBuffer:scratch range:NSMakeRange(0, scratch.length) value:(uint8_t)f]; [be endEncoding];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = d.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:todraw]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
        [cb presentDrawable:d];
        [cb commit];
        id<MTLCommandBuffer> c2 = [qc commandBuffer];
        MTLRenderPassDescriptor *rc = [MTLRenderPassDescriptor renderPassDescriptor];
        rc.colorAttachments[0].texture = tb; rc.colorAttachments[0].loadAction = MTLLoadActionLoad; rc.colorAttachments[0].storeAction = MTLStoreActionStore;
        [[c2 renderCommandEncoderWithDescriptor:rc] endEncoding]; [c2 commit];
        [cb waitUntilCompleted];
        const uint32_t *o = out.contents; uint64_t s = 1469598103934665603ULL;
        for (int i = 0; i < 1024 * 1024; i += 97) { s ^= o[i]; s *= 1099511628211ULL; }
        sum_all = sum_all * 1099511628211ULL + s;
        if (cb.status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "FAIL: command buffer status %ld %s\n", (long)cb.status, cb.error.localizedDescription.UTF8String); return 1; }
    }
    usleep(300000);   // (the profile's last frames resolved and written)
    printf("checksum %016llx frames %d\n", (unsigned long long)sum_all, frames);
} return 0; }
