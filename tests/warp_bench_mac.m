// warp_bench_mac.m (Mac): the eye warp's GPU time at the headset's size (1600x900 frame into 1888x1792), rotation only and depth + stereo offset; DW=<depth width>. Build as tests/warp_offframe_test.m.
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include "warp_core.h"
int main(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    const int W = 1600, H = 900, OW = 1888, OH = 1792; int DW = atoi(getenv("DW") ?: "1600"), DH = DW * 9 / 16;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:YES];
    td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> B = [dev newTextureWithDescriptor:td];
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:OW height:OH mipmapped:NO];
    od.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; od.storageMode = MTLStorageModePrivate;
    id<MTLTexture> O = [dev newTextureWithDescriptor:od];
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:DW height:DH mipmapped:NO];
    dd.usage = MTLTextureUsageShaderRead; dd.storageMode = MTLStorageModeShared; id<MTLTexture> D = [dev newTextureWithDescriptor:dd];
    float *z = malloc(DW * DH * 4); for (int i = 0; i < DW * DH; i++) z[i] = 0.2f / (2 + (i % DW) * 0.01f);
    [D replaceRegion:MTLRegionMake2D(0, 0, DW, DH) mipmapLevel:0 withBytes:z bytesPerRow:DW * 4];
    MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float width:1 height:1 mipmapped:NO];
    md.storageMode = MTLStorageModeShared; id<MTLTexture> MV = [dev newTextureWithDescriptor:md];
    vxw_core *c = vxw_create((__bridge void *)dev);
    for (int mode = 0; mode < 2; mode++) {
        double tot = 0; int n = 0;
        for (int it = 0; it < 40; it++) {
            vxw_params p = { 0 }; p.w = W; p.h = H; p.flags = VXW_POSE; p.tan_x = 1.428f; p.tan_y = 0.803f; p.z_a = 0.2f;
            float a = 0.05f; p.rot[0] = cosf(a); p.rot[2] = -sinf(a); p.rot[4] = 1; p.rot[6] = sinf(a); p.rot[8] = cosf(a);
            p.pos[0] = mode ? 0.032f : 0; if (!mode) p.z_a = 0;
            p.dst_tan[0] = 1.732f; p.dst_tan[1] = 1; p.dst_tan[2] = 1; p.dst_tan[3] = 1.192f;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            vxw_encode_eye(c, (__bridge void *)cb, &p, (__bridge void *)B, NULL, (__bridge void *)MV, (__bridge void *)D, (__bridge void *)O, NULL);
            [cb commit]; [cb waitUntilCompleted];
            if (it >= 5) { tot += cb.GPUEndTime - cb.GPUStartTime; n++; }
        }
        printf("%s: %.2f ms an eye\n", mode ? "depth + stereo offset (mode 6)" : "rotation only, no depth (mode 2)", tot / n * 1e3);
    }
}
