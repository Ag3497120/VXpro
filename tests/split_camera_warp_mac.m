// SPDX-License-Identifier: MIT
// Reconstruct the observed ~97-degree failure through the production GPU warp.
// Synthetic pixels and poses; this is not a replay of captured game matrices.
#define main old_warp_suite
#include "warp_black_skip_mac.m"
#undef main
#include "../shims/frame_camera.h"
static unsigned dark_pixels(NSData *data) {
    const unsigned char *p=data.bytes;unsigned n=0;
    for(NSUInteger i=0;i<data.length;i+=4)if(p[i]<4 && p[i+1]<4 && p[i+2]<4)n++;
    return n;
}
int main(void) { @autoreleasepool {
    setenv("VXMAC_VIGNETTE","0",1);unsetenv("VXMAC_EDGE_FILL");
    test_dev=MTLCreateSystemDefaultDevice();assert(test_dev);test_queue=[test_dev newCommandQueue];
    vxw_core *core=vxw_create((__bridge void *)test_dev);assert(core);
    id<MTLTexture> b=tex(MTLPixelFormatBGRA8Unorm,128,72,MTLTextureUsageShaderRead);
    unsigned char pixels[128*72*4];memset(pixels,180,sizeof pixels);for(int i=0;i<128*72;i++)pixels[4*i+3]=255;
    [b replaceRegion:MTLRegionMake2D(0,0,128,72) mipmapLevel:0 withBytes:pixels bytesPerRow:128*4];
    id<MTLTexture> dp=tex(MTLPixelFormatR32Float,128,72,MTLTextureUsageShaderRead),mv=tex(MTLPixelFormatRG32Float,1,1,MTLTextureUsageShaderRead);
    float d[128*72],zero[2]={0};for(int i=0;i<128*72;i++)d[i]=.02f;
    [dp replaceRegion:MTLRegionMake2D(0,0,128,72) mipmapLevel:0 withBytes:d bytesPerRow:128*4];
    [mv replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:zero bytesPerRow:8];
    float source[16]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1},later[16];memcpy(later,source,sizeof source);
    float a=97*.01745329252f;later[5]=later[10]=cosf(a);later[6]=sinf(a);later[9]=-sinf(a);
    assert(vx_frame_camera_publish_depth(dp,source,1.444f,.812f));
    float held[16],tx,ty;assert(vx_frame_camera_read(dp,held,&tx,&ty));
    assert(vx_frame_camera_publish_depth(dp,later,1.444f,.812f));
    unsigned cases=0;
    for(int compute=0;compute<2;compute++)for(int srgb=0;srgb<2;srgb++)for(int depth=0;depth<2;depth++) {
        MTLTextureUsage use=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|(compute?MTLTextureUsageShaderWrite:0);
        id<MTLTexture> out=tex(srgb?MTLPixelFormatBGRA8Unorm_sRGB:MTLPixelFormatBGRA8Unorm,128,128,use);
        id<MTLTexture> od=depth?tex(compute?MTLPixelFormatR32Float:MTLPixelFormatDepth32Float,128,128,use):nil;
        vxw_params p={.w=128,.h=72,.flags=VXW_POSE|VXW_EDGE_FILL,.tan_x=tx,.tan_y=ty,.z_a=.2f,.dst_tan={1,1.732f,1,1.192f},.dst_near=.01f};
        // A physical eye sees A, but a late mutable lookup assigns B to A.
        for(int r=0;r<3;r++)for(int c=0;c<3;c++)p.rot[3*r+c]=later[4*c+r];
        encode(core,&p,b,mv,dp,out,od);unsigned before=dark_pixels(bytes(out));
        for(int r=0;r<3;r++)for(int c=0;c<3;c++)p.rot[3*r+c]=held[4*c+r];
        encode(core,&p,b,mv,dp,out,od);unsigned after=dark_pixels(bytes(out));
        assert(before>128*128*.7 && after<128*128*.15);
        const unsigned char *centre=(const unsigned char *)bytes(out).bytes+(64*128+64)*4;
        assert(centre[0]>100 && centre[1]>100 && centre[2]>100);
        cases++;
    }
    vxw_destroy(core);
    printf("split camera production GPU: %u render/compute/sRGB/linear/depth cases reproduce >70%% blackout with wrong 97-degree pose; held source pose restores coverage (<15%% black periphery)\n",cases);
} }
