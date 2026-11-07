// SPDX-License-Identifier: MIT
// Full production warp A/B: compare every colour/depth byte, then time alternating encodes.
#include <assert.h>
#include <TargetConditionals.h>
#define VXW_BLACK_SKIP_BENCH 1
#include "../vr/warp_core.m"
#import <QuartzCore/QuartzCore.h>

static id<MTLDevice> test_dev;
static id<MTLCommandQueue> test_queue;
static id<MTLTexture> tex(MTLPixelFormat fmt,unsigned w,unsigned h,MTLTextureUsage usage) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=usage;
    id<MTLTexture> t=[test_dev newTextureWithDescriptor:d]; assert(t); return t;
}
static double encode(vxw_core *core,const vxw_params *p,id<MTLTexture> b,id<MTLTexture> mv,id<MTLTexture> dp,id<MTLTexture> out,id<MTLTexture> depth) {
    id<MTLCommandBuffer> cb=[test_queue commandBuffer];
    assert(vxw_encode_eye(core,(__bridge void *)cb,p,(__bridge void *)b,NULL,(__bridge void *)mv,(__bridge void *)dp,(__bridge void *)out,(__bridge void *)depth));
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status!=MTLCommandBufferStatusCompleted) fprintf(stderr,"GPU failure: %s\n",cb.error.description.UTF8String);
    assert(cb.status==MTLCommandBufferStatusCompleted);
    return (cb.GPUEndTime-cb.GPUStartTime)*1e3;
}
static NSData *bytes(id<MTLTexture> t) {
    NSMutableData *data=[NSMutableData dataWithLength:t.width*t.height*4];
    [t getBytes:data.mutableBytes bytesPerRow:t.width*4 fromRegion:MTLRegionMake2D(0,0,t.width,t.height) mipmapLevel:0];
    return data;
}
static vxw_params params(unsigned w,unsigned h,int i) {
    vxw_params p={0}; p.w=w;p.h=h;p.flags=VXW_POSE;p.tan_x=1.428f;p.tan_y=.803f;p.z_a=.2f;
    p.dst_tan[0]=1.732f;p.dst_tan[1]=1;p.dst_tan[2]=1;p.dst_tan[3]=1.192f;p.dst_near=.01f;
    float a=(i%4)*.15f,b=((i/4)%3-1)*.12f,ca=cosf(a),sa=sinf(a),cb=cosf(b),sb=sinf(b);
    float r[9]={ca,0,-sa,sa*sb,cb,ca*sb,sa*cb,-sb,ca*cb};memcpy(p.rot,r,sizeof r);
    p.pos[0]=(i%2 ? -.032f : .032f);p.pos[2]=(i%3)*.01f;
    return p;
}
static int run_black_skip(NSString *path) { @autoreleasepool {
    test_dev=MTLCreateSystemDefaultDevice();assert(test_dev);test_queue=[test_dev newCommandQueue];
    vxw_core *core[2];
    for (int k=0;k<2;k++) { setenv("VXMAC_WARP_BLACK_SKIP",k ? "1" : "0",1);core[k]=vxw_create((__bridge void *)test_dev);assert(core[k]); }
    enum { w=1280,h=720,ow=1888,oh=1792 };
    id<MTLTexture> b=tex(MTLPixelFormatBGRA8Unorm,w,h,MTLTextureUsageShaderRead);
    id<MTLTexture> dp=tex(MTLPixelFormatR32Float,w,h,MTLTextureUsageShaderRead);
    id<MTLTexture> mv=tex(MTLPixelFormatRG32Float,1,1,MTLTextureUsageShaderRead);
    unsigned char *pixels=malloc(w*h*4);float *z=malloc(w*h*4);assert(pixels&&z);
    for (unsigned y=0;y<h;y++) for (unsigned x=0;x<w;x++) {
        unsigned n=y*w+x;pixels[n*4]=(x*7+y*3)%256;pixels[n*4+1]=(x^y)%256;pixels[n*4+2]=(x+y*11)%256;pixels[n*4+3]=255;
        z[n]=x>w/3 && x<w/2 && y>h/3 ? .95f : .2f/(2+(x%317)*.01f);
    }
    [b replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:pixels bytesPerRow:w*4];
    [dp replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:z bytesPerRow:w*4];
    float zero[2]={0};[mv replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:zero bytesPerRow:8];free(pixels);free(z);
    id<MTLTexture> layers=tex(MTLPixelFormatR16Float,4,24,MTLTextureUsageShaderRead);
    __fp16 l[96];for (int i=0;i<96;i++) l[i]=i/16==5 ? .25f : i/16<3 ? .4f : 0;
    [layers replaceRegion:MTLRegionMake2D(0,0,4,24) mipmapLevel:0 withBytes:l bytesPerRow:8];
    unsigned cases=0;
    // Both the render-only compositor target and the compute output path, including depth/no-depth and HUD/detail.
    for (int srgb=0;srgb<2;srgb++) for (int interp=0;interp<2;interp++)
    for (int compute=0;compute<2;compute++) for (int depth=0;depth<2;depth++) for (int i=0;i<12;i++) { @autoreleasepool {
        MTLPixelFormat df=compute ? MTLPixelFormatR32Float : MTLPixelFormatDepth32Float;
        MTLTextureUsage usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|(compute ? MTLTextureUsageShaderWrite : 0);
        unsigned tw=320+i%2,th=304+i%2;
        id<MTLTexture> out=tex(srgb ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm,tw,th,usage);
        id<MTLTexture> od=depth ? tex(df,tw,th,usage) : nil;
        vxw_params p=params(w,h,i);
        float rect[4]={.2f,.2f,.5f,.5f},hr[4]={.05f,.5f,.2f,.7f};
        for (int k=0;k<2;k++) {
            id<MTLCommandBuffer> prep=[test_queue commandBuffer];
            int active=vxw_set_interp(core[k],(__bridge void *)prep,interp ? (__bridge void *)layers : NULL,4,4,i+1,0,.5f,0);
            assert(active==interp);
            [prep commit];[prep waitUntilCompleted];assert(prep.status==MTLCommandBufferStatusCompleted);
            vxw_set_detail(core[k],i%2 ? (__bridge void *)b : NULL,rect);
            vxw_set_hud_rects(core[k],hr,i%2);
            float delta[3]={.04f,0,0},rot[3]={0,.03f,0};
            vxw_set_viewmodel(core[k],i%3==0 ? delta : NULL,rot);
        }
        (void)encode(core[0],&p,b,mv,dp,out,od);NSData *colour=bytes(out),*d=od ? bytes(od) : nil;
        (void)encode(core[1],&p,b,mv,dp,out,od);
        if (![colour isEqual:bytes(out)] || (od && ![d isEqual:bytes(od)])) {
            fprintf(stderr,"warp mismatch: srgb%d interp%d compute%d depth%d case%d\n",srgb,interp,compute,depth,i);return 1;
        }
        cases++;
    } }
    id<MTLTexture> out=tex(MTLPixelFormatBGRA8Unorm_sRGB,ow,oh,MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead);
    id<MTLTexture> od=tex(MTLPixelFormatDepth32Float,ow,oh,MTLTextureUsageRenderTarget);
    vxw_params p=params(w,h,1);
    for (int k=0;k<2;k++) { vxw_set_interp(core[k],NULL,NULL,0,0,0,0,0,0);vxw_set_detail(core[k],NULL,NULL);vxw_set_hud_rects(core[k],NULL,0);vxw_set_viewmodel(core[k],NULL,NULL);(void)encode(core[k],&p,b,mv,dp,out,od); }
    // Warm the full compositor-size outputs, not just the small correctness targets.
    for (int i=0;i<12;i++) for (int k=0;k<2;k++) (void)encode(core[k],&p,b,mv,dp,out,od);
    NSMutableArray *samples=[NSMutableArray array];const int order[]={0,1,1,0,1,0,0,1};
    for (unsigned i=0;i<32;i++) {
        int mode=order[i%8];double ms=encode(core[mode],&p,b,mv,dp,out,od);
        [samples addObject:@{@"skip":@(mode),@"gpu_ms_per_eye":@(ms)}];
    }
    NSDictionary *result=@{@"status":@"complete",@"device":test_dev.name,@"byte_identical_colour_depth_cases":@(cases),
        @"scope":@"standalone full-warp synthetic comparison; not game FPS or full game image quality",
        @"default_enabled":@NO,@"alternating_samples":samples};
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
    assert([data writeToFile:path atomically:YES]);
    for (int k=0;k<2;k++) vxw_destroy(core[k]);
    printf("warp black skip: %u colour/depth cases byte-identical\n",cases);return 0;
} }
#if TARGET_OS_OSX
int main(int argc,char **argv) { assert(argc==2);return run_black_skip(@(argv[1])); }
#elif defined(VXMAC_FPS_BUDGET_APP)
NSString *vx_warp_black_skip_app(void) {
    NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *path=[docs stringByAppendingPathComponent:@"warp_black_skip.json"];
    [@"{\"status\":\"started\"}" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (run_black_skip(path)) {
        [@"{\"status\":\"mismatch\"}" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return @"表示補正の一致検査が失敗しました。候補をゲームには採用しません。";
    }
    return @"表示補正の一致検査と速度比較を記録しました。";
}
#endif
