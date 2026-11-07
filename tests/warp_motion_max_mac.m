// SPDX-License-Identifier: MIT
// Reuse the existing full production-warp test's textures, parameters and readback.
#define main unused_black_skip_main
#include "warp_black_skip_mac.m"
#undef main

static void motion_input(id<MTLTexture> t, int mode) {
    NSUInteger w=t.width,h=t.height;
    float *v=calloc(w*h*2,sizeof(float)); assert(v);
    for (NSUInteger y=0;y<h;y++) for (NSUInteger x=0;x<w;x++) {
        NSUInteger q=(y*w+x)*2;
        if (mode==1) { v[q]=.01f; v[q+1]=-.02f; } // quantizes to zero
        if (mode==2 && (x+y)%7) { v[q]=(int)(x%9)-4; v[q+1]=(int)(y%7)-3; }
        if (mode==3) { v[q]=x%2 ? NAN : INFINITY; v[q+1]=0; }
    }
    [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:v bytesPerRow:w*8];free(v);
}

static int run_motion_max(NSString *path) { @autoreleasepool {
    test_dev=MTLCreateSystemDefaultDevice(); assert(test_dev); test_queue=[test_dev newCommandQueue];
    unsetenv("VXMAC_WARP_BLACK_SKIP");
    vxw_core *core[2];
    for (int k=0;k<2;k++) { setenv("VXMAC_WARP_MOTION_MAX",k ? "skip_zero" : "legacy",1);core[k]=vxw_create((__bridge void *)test_dev); assert(core[k]); }
    enum {w=1280,h=720};
    id<MTLTexture> b=tex(MTLPixelFormatBGRA8Unorm,w,h,MTLTextureUsageShaderRead);
    id<MTLTexture> dp=tex(MTLPixelFormatR32Float,w,h,MTLTextureUsageShaderRead);
    id<MTLTexture> mv=tex(MTLPixelFormatRG32Float,65,37,MTLTextureUsageShaderRead);
    uint32_t *c=malloc(w*h*4);float *z=malloc(w*h*4);assert(c && z);
    for (unsigned y=0;y<h;y++) for (unsigned x=0;x<w;x++) { unsigned n=y*w+x;
        c[n]=0xff000000u|((x*7+y*3)&255)|(((x^y)&255)<<8)|(((x+y*11)&255)<<16);
        z[n]=x>w/3 && x<w/2 && y>h/3 ? .95f : .2f/(2+(x%317)*.01f);
    }
    [b replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:c bytesPerRow:w*4];
    [dp replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:z bytesPerRow:w*4];free(c);free(z);
    id<MTLTexture> layers=tex(MTLPixelFormatR16Float,4,24,MTLTextureUsageShaderRead);
    __fp16 ls[96]; for (int i=0;i<96;i++) ls[i]=i/16==5 ? .25f : i/16<3 ? .4f : 0;
    [layers replaceRegion:MTLRegionMake2D(0,0,4,24) mipmapLevel:0 withBytes:ls bytesPerRow:8];
    unsigned cases=0;
    for (int srgb=0;srgb<2;srgb++) for (int interp=0;interp<2;interp++)
    for (int compute=0;compute<2;compute++) for (int depth=0;depth<2;depth++) for (int i=0;i<8;i++) { @autoreleasepool {
        motion_input(mv,i%4);
        MTLTextureUsage usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|(compute ? MTLTextureUsageShaderWrite : 0);
        id<MTLTexture> out=tex(srgb ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm,320+i%2,304+i%2,usage);
        id<MTLTexture> od=depth ? tex(compute ? MTLPixelFormatR32Float : MTLPixelFormatDepth32Float,320+i%2,304+i%2,usage) : nil;
        vxw_params p=params(w,h,i);p.mv_sx=p.mv_sy=1;p.t=.5f;
        if (i==7) { float r[9]={-1,0,0,0,1,0,0,0,-1};memcpy(p.rot,r,sizeof r); }
        float rect[4]={.2f,.2f,.5f,.5f},hr[4]={.05f,.5f,.2f,.7f};
        NSData *colour=nil,*depth_bytes=nil;uint32_t motion=0;
        for (int k=0;k<2;k++) {
            id<MTLCommandBuffer> prep=[test_queue commandBuffer];
            assert(vxw_set_interp(core[k],(__bridge void *)prep,interp ? (__bridge void *)layers : NULL,4,4,i+1,0,.5f,0)==interp);
            [prep commit];[prep waitUntilCompleted];assert(prep.status==MTLCommandBufferStatusCompleted);
            vxw_set_detail(core[k],i%2 ? (__bridge void *)b : NULL,rect);vxw_set_hud_rects(core[k],hr,i%2);
            float delta[3]={.04f,0,0},rot[3]={0,.03f,0};vxw_set_viewmodel(core[k],i%3==0 ? delta : NULL,rot);
            encode(core[k],&p,b,mv,dp,out,od);
            uint32_t mm=*(uint32_t *)core[k]->mx.contents;
            if (!k) { colour=bytes(out);depth_bytes=od ? bytes(od) : nil;motion=mm; }
            else if (![colour isEqual:bytes(out)] || (od && ![depth_bytes isEqual:bytes(od)]) || mm!=motion) {
                fprintf(stderr,"motion max mismatch srgb%d interp%d compute%d depth%d case%d\n",srgb,interp,compute,depth,i);return 1;
            }
        }
        cases++;
    } }
    id<MTLTexture> out=tex(MTLPixelFormatBGRA8Unorm_sRGB,1888,1792,MTLTextureUsageRenderTarget);
    id<MTLTexture> od=tex(MTLPixelFormatDepth32Float,1888,1792,MTLTextureUsageRenderTarget);
    NSMutableArray *samples=[NSMutableArray array];const int order[]={0,1,1,0,1,0,0,1};
    for (int mode=0;mode<2;mode++) {
        motion_input(mv,mode ? 2 : 0);vxw_params p=params(w,h,1);p.mv_sx=p.mv_sy=1;p.t=.5f;
        for (int k=0;k<2;k++) { vxw_set_interp(core[k],NULL,NULL,0,0,0,0,0,0);vxw_set_detail(core[k],NULL,NULL);vxw_set_hud_rects(core[k],NULL,0);vxw_set_viewmodel(core[k],NULL,NULL); }
        for (int i=0;i<8;i++) for (int k=0;k<2;k++) encode(core[k],&p,b,mv,dp,out,od);
        for (int i=0;i<32;i++) { int k=order[i%8];double ms=encode(core[k],&p,b,mv,dp,out,od);
            [samples addObject:@{@"skip_zero":@(k),@"motion_input":mode ? @"mixed" : @"zero",@"gpu_ms_per_eye":@(ms)}]; }
    }
    NSDictionary *result=@{@"status":@"complete",@"device":test_dev.name,@"byte_identical_colour_depth_motion_cases":@(cases),
        @"default_enabled":@NO,@"scope":@"standalone synthetic full production warp, not game FPS",@"alternating_samples":samples};
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];assert([data writeToFile:path atomically:YES]);
    for (int k=0;k<2;k++) vxw_destroy(core[k]);printf("motion max: %u colour/depth/motion cases byte-identical\n",cases);return 0;
} }

#if TARGET_OS_OSX
int main(int argc,char **argv) { assert(argc==2);return run_motion_max(@(argv[1])); }
#elif defined(VXMAC_MOTION_MAX_APP)
NSString *vx_motion_max_app(void) {
    NSString *path=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"motion_max.json"];
    [@"{\"status\":\"started\"}" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return run_motion_max(path) ? @"一致検査が失敗しました。候補はゲームに採用しません。" : @"一致検査と速度比較の記録が完了しました。";
}
#endif
