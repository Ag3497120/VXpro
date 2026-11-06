// SPDX-License-Identifier: MIT
// Run with the Mac libvxmtl injected and VXMAC_MAC_TEST=1. This exercises the
// actual encoder/command hooks, including unretained-reference command buffers.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    assert(device);
    CAMetalLayer *layer = [CAMetalLayer layer]; layer.device = device;
    layer.drawableSize = CGSizeMake(4, 4); (void)[layer nextDrawable];
    int (*retain_resource)(id,id) = dlsym(RTLD_DEFAULT, "vxmtl_retain_for_encoder");
    id (*command_for_encoder)(id) = dlsym(RTLD_DEFAULT, "vxmtl_command_buffer_for_encoder");
    assert(retain_resource && command_for_encoder);
    id<MTLCommandQueue> queue = [device newCommandQueue]; queue.label = @"VX Mac resource test";
    id<MTLCommandBuffer> command = [queue commandBufferWithUnretainedReferences];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> texture = [device newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    assert(command_for_encoder(encoder) == command);
    __weak id witness;
    @autoreleasepool {
        id resource = [NSObject new]; witness = resource;
        assert(retain_resource(encoder, resource));
    }
    assert(witness);
    [encoder endEncoding];
    assert(!command_for_encoder(encoder) && witness);
    [command commit]; [command waitUntilCompleted];
    assert(command.status == MTLCommandBufferStatusCompleted && !command.error);
    assert(!witness);
    puts("pose resources: actual hooks retain through encoder end and release after command completion: ok");
    return 0;
} }
