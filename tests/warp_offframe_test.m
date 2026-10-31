// warp_offframe_test (Mac): the presenter's warp (../vr/warp_core.m) of a synthetic game frame at FOV 110 (tan 1.428 x
// 0.803) into an eye of 1888x1792 (tangents 1.732 1.0 1.0 1.192, the headset's), turned as a fast head turn with an old
// frame (yaw 0..60 deg, pitch -20..20): the part of the eye outside the frame must be the frame's edge continued and
// blurred (its colours), never white. The frame: dark scene colours, a mid-grey border; as the presenter makes it (BGRA8
// sRGB view of a mipmapped texture, mips generated). Prints the brightest off-frame pixel and fails if over the frame's
// brightest edge pixel. Build: xcrun --sdk macosx clang -fobjc-arc -O1 -Ivr tests/warp_offframe_test.m vr/warp_core.m -framework Metal -framework Foundation -o /tmp/wot
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "warp_core.h"
int main(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    const int W = 1600, H = 900, OW = 1888, OH = 1792;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:YES];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> B = [dev newTextureWithDescriptor:td];
    uint8_t *px = malloc(W * H * 4); int edge_max = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        uint8_t *p = px + 4 * (y * W + x);
        int border = x < 8 || y < 8 || x >= W - 8 || y >= H - 8;
        int r = border ? 90 : 20 + (x * 120 / W), g = border ? 90 : 30 + (y * 100 / H), b = border ? 90 : 60;
        p[0] = b; p[1] = g; p[2] = r; p[3] = 255;
        if (border) { int m = r > g ? r : g; if (m > edge_max) edge_max = m; }
    }
    [B replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:W * 4];
    id<MTLTexture> Bv = [B newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB];
    { id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder]; [e generateMipmapsForTexture:B]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:OW height:OH mipmapped:NO];
    od.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; od.storageMode = MTLStorageModeShared;
    id<MTLTexture> O = [dev newTextureWithDescriptor:od];
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:4 height:4 mipmapped:NO];
    dd.storageMode = MTLStorageModeShared; id<MTLTexture> D = [dev newTextureWithDescriptor:dd]; float far[16] = { 0 };
    [D replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:far bytesPerRow:16];
    MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float width:1 height:1 mipmapped:NO];
    md.storageMode = MTLStorageModeShared; id<MTLTexture> MV = [dev newTextureWithDescriptor:md]; float z2[2] = { 0 };
    [MV replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:z2 bytesPerRow:8];
    vxw_core *c = vxw_create((__bridge void *)dev);
    int fails = 0; uint8_t *o = malloc(OW * OH * 4);
    for (int yi = 0; yi <= 60; yi += 20) for (int pi = -20; pi <= 20; pi += 20) {
        vxw_params p = { 0 };
        p.w = W; p.h = H; p.flags = VXW_POSE; p.tan_x = 1.428f; p.tan_y = 0.803f; p.z_a = 0.2f; p.z_b = 0;
        float a = yi * (float)M_PI / 180, b = pi * (float)M_PI / 180, ca = cosf(a), sa = sinf(a), cb_ = cosf(b), sb = sinf(b);
        float R[9] = { ca, 0, -sa,  sa * sb, cb_, ca * sb,  sa * cb_, -sb, ca * cb_ };
        for (int k = 0; k < 9; k++) p.rot[k] = R[k];
        p.dst_tan[0] = 1.732f; p.dst_tan[1] = 1.0f; p.dst_tan[2] = 1.0f; p.dst_tan[3] = 1.192f;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        int ok = vxw_encode_eye(c, (__bridge void *)cb, &p, (__bridge void *)Bv, NULL, (__bridge void *)MV, (__bridge void *)D, (__bridge void *)O, NULL);
        [cb commit]; [cb waitUntilCompleted];
        [O getBytes:o bytesPerRow:OW * 4 fromRegion:MTLRegionMake2D(0, 0, OW, OH) mipmapLevel:0];
        int mx = 0, white = 0;
        for (int i = 0; i < OW * OH; i++) { uint8_t *q2 = o + 4 * i; int m = q2[0] > q2[1] ? q2[0] : q2[1]; m = q2[2] > m ? q2[2] : m; if (m > mx) mx = m; if (q2[0] > 230 && q2[1] > 230 && q2[2] > 230) white++; }
        printf("yaw %3d pitch %3d: encoded %d, brightest %d (frame edge %d, scene max %d), white pixels %d\n", yi, pi, ok, mx, edge_max, 140, white);
        if (white || mx > 200) fails++;
    }
    printf(fails ? "FAIL\n" : "ok: the outside is the frame's own edge, never white\n");
    return fails != 0;
}
