// SPDX-License-Identifier: MIT
#define main old_warp_suite
#include "warp_black_skip_mac.m"
#undef main
int main(void) { @autoreleasepool {
    setenv("VXMAC_VIGNETTE","0",1);setenv("VXMAC_WARP_BLACK_SKIP","0",1);
    test_dev=MTLCreateSystemDefaultDevice();assert(test_dev);test_queue=[test_dev newCommandQueue];
    vxw_core *core[3];for(int k=0;k<3;k++) {
        if(k==2)unsetenv("VXMAC_EDGE_FILL");else setenv("VXMAC_EDGE_FILL",k?"1":"0",1);
        core[k]=vxw_create((__bridge void *)test_dev);assert(core[k]);
    }
    id<MTLTexture> b=tex(MTLPixelFormatBGRA8Unorm,128,72,MTLTextureUsageShaderRead);
    unsigned char pixels[128*72*4];memset(pixels,180,sizeof pixels);for(int i=0;i<128*72;i++)pixels[i*4+3]=255;
    [b replaceRegion:MTLRegionMake2D(0,0,128,72) mipmapLevel:0 withBytes:pixels bytesPerRow:128*4];
    id<MTLTexture> dp=tex(MTLPixelFormatR32Float,1,1,MTLTextureUsageShaderRead),mv=tex(MTLPixelFormatRG32Float,1,1,MTLTextureUsageShaderRead);
    float d=.02f,zero[2]={0};[dp replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&d bytesPerRow:4];
    [mv replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:zero bytesPerRow:8];
    unsigned cases=0;
    for(int yaw=-30;yaw<=30;yaw+=15) for(int compute=0;compute<2;compute++) for(int srgb=0;srgb<2;srgb++) {
        MTLTextureUsage use=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|(compute?MTLTextureUsageShaderWrite:0);
        id<MTLTexture> out=tex(srgb?MTLPixelFormatBGRA8Unorm_sRGB:MTLPixelFormatBGRA8Unorm,128,128,use);
        id<MTLTexture> od=tex(compute?MTLPixelFormatR32Float:MTLPixelFormatDepth32Float,128,128,use);
        vxw_params p={.w=128,.h=72,.flags=VXW_POSE,.tan_x=1,.tan_y=.56f,.z_a=.2f,.dst_tan={1.3,1.3,1,1},.dst_near=.01f};
        float angle=yaw*.01745329252f;
        p.rot[0]=p.rot[8]=cosf(angle);p.rot[2]=sinf(angle);p.rot[6]=-sinf(angle);p.rot[4]=1;
        NSData *a[2];for(int k=0;k<2;k++) { encode(core[k],&p,b,mv,dp,out,od);a[k]=bytes(out); }
        const unsigned char *off=a[0].bytes,*on=a[1].bytes;unsigned removed=0;
        for(int i=0;i<128*128;i++) {
            if(memcmp(off+i*4,on+i*4,3)) { assert(!off[i*4] && !off[i*4+1] && !off[i*4+2]);removed++; }
            assert(off[i*4+3]==255);
        }
        assert(removed>100);assert(!memcmp(off+(64*128+64)*4,on+(64*128+64)*4,4));
        // Ordinary and vehicle views request the existing extension. Scripted
        // views may omit it; the explicit user opt-out still retains black.
        encode(core[2],&p,b,mv,dp,out,od);assert([bytes(out) isEqualToData:a[0]]);
        p.flags|=VXW_EDGE_FILL;
        encode(core[2],&p,b,mv,dp,out,od);assert([bytes(out) isEqualToData:a[1]]);
        encode(core[0],&p,b,mv,dp,out,od);assert([bytes(out) isEqualToData:a[0]]);
        cases++;
    }
    for(int k=0;k<3;k++)vxw_destroy(core[k]);
    printf("production warp: %u stationary/turning views restore same-frame edge fill; only formerly black pixels change; centre/render/compute/sRGB/linear/depth and opt-out preserved: ok\n",cases);
} }
