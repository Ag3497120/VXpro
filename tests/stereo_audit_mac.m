// SPDX-License-Identifier: MIT
// Run with VXMAC_MAC_TEST=1 and the Mac libvxmtl injected. The audit must
// classify foreground draws without changing their output or counting world draws.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = device;
    layer.drawableSize = CGSizeMake(64, 64);
    (void)[layer nextDrawable];
    id<MTLCommandQueue> queue = [device newCommandQueue];
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 vs(uint i [[vertex_id]]) { float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0.5,1); }\n"
        "fragment float4 color() { return float4(1,0,0,1); }\n"
        "struct G { float4 a [[color(0)]]; float4 b [[color(1)]]; };\n"
        "fragment G material() { G g; g.a=float4(1,0,0,1); g.b=float4(0,1,0,1); return g; }\n";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    assert(library && !error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:1024 height:64 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color = [device newTextureWithDescriptor:td];
    id<MTLTexture> material = [device newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth = [device newTextureWithDescriptor:td];
    MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
    ds.depthCompareFunction = MTLCompareFunctionAlways;
    ds.depthWriteEnabled = YES;
    id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:ds];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    for (int pass = 0; pass < 4; pass++) {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [library newFunctionWithName:@"vs"];
        pd.fragmentFunction = pass == 2 ? nil : [library newFunctionWithName:pass == 1 ? @"material" : @"color"];
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        if (pass != 2) pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        if (pass == 1) pd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
        assert(pipeline && !error);
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture = depth;
        rp.depthAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        for (int i = 0; i < (pass == 2 ? 0 : pass == 1 ? 2 : 1); i++) {
            rp.colorAttachments[i].texture = i ? material : color;
            rp.colorAttachments[i].loadAction = MTLLoadActionClear;
            rp.colorAttachments[i].storeAction = MTLStoreActionStore;
        }
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:rp];
        [encoder setRenderPipelineState:pipeline];
        [encoder setDepthStencilState:depthState];
        [encoder setViewport:(MTLViewport){0,0,1024,64,pass == 3 ? 0 : .9,1}];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
    }
    [command commit];
    [command waitUntilCompleted];
    assert(command.status == MTLCommandBufferStatusCompleted);
    unsigned char pixel[4];
    [color getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(512,32,1,1) mipmapLevel:0];
    assert(pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 255);
    void (*stats)(char *, unsigned) = dlsym(RTLD_DEFAULT, "vxpipe_stereo_stats");
    assert(stats);
    char output[320];
    stats(output, sizeof output);
    printf("%s\n", output);
    fflush(stdout);
    if (getenv("VXMAC_STEREO_AUDIT")) {
        assert(strstr(output, "\"stereo_fg_draws\":3,"));
        assert(strstr(output, "\"stereo_fg_indices\":9,"));
        assert(strstr(output, "\"stereo_fg_multi_target\":1,"));
        assert(strstr(output, "\"stereo_fg_single_target\":1,"));
        assert(strstr(output, "\"stereo_fg_depth_only\":1"));
    } else assert(output[0] == 0);
    puts("stereo audit: foreground stages classified, world excluded, original colour retained: ok");
    return 0;
} }
