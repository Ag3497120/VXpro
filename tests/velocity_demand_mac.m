// SPDX-License-Identifier: MIT
// Exercise consumer selection and the production capture path, without starting a game.
#include <assert.h>
#include <TargetConditionals.h>
#include "../app/Sources/velocity.m"

void vxmac_jlog(const char *event, const char *fields) { (void)event; (void)fields; }
static const char *envs[] = {"VXMAC_VEL", "VXMAC_CAPTURE", "VXMAC_INTERP", "VXMAC_VEL_PREDICT"};
static void configure(const char *vel, const char *cap, const char *interp, const char *predict) {
    const char *values[] = {vel, cap, interp, predict};
    for (int i=0;i<4;i++) { if (values[i]) setenv(envs[i],values[i],1); else unsetenv(envs[i]); }
    g_on=-1;
}
static void wait_for(id<MTLCommandBuffer> cb) {
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) fprintf(stderr,"GPU failure: %s\n",cb.error.description.UTF8String);
    assert(cb.status == MTLCommandBufferStatusCompleted);
}
static id<MTLTexture> input(id<MTLDevice> dev) {
    unsigned w=1280,h=720;
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> t=[dev newTextureWithDescriptor:d]; assert(t);
    __fp16 *p=malloc(w*h*4); assert(p);
    for (unsigned i=0;i<w*h;i++) { p[i*2]=.25f; p[i*2+1]=-.5f; }
    [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:p bytesPerRow:w*4];
    free(p); return t;
}
static unsigned check_policy(id<MTLCommandQueue> q, id<MTLTexture> t) {
    const struct { const char *v,*c,*i,*p; int enabled; } cases[] = {
        {NULL,NULL,NULL,NULL,0},{"auto",NULL,NULL,NULL,0},
        {"1",NULL,NULL,NULL,1},{"2",NULL,NULL,NULL,1},
        {"0","2","vel","1",0},{"auto","1",NULL,NULL,1},
        {NULL,"2",NULL,NULL,1},{NULL,"0",NULL,NULL,0},
        {NULL,"-1",NULL,NULL,0},{NULL,"3",NULL,NULL,0},
        {NULL,"true",NULL,NULL,0},{NULL,NULL,"1",NULL,1},
        {NULL,NULL,"vel",NULL,1},{NULL,NULL,"0",NULL,0},
        {NULL,NULL,"invalid",NULL,0},{NULL,NULL,NULL,"1",1},
        {NULL,NULL,NULL,"0",0}
    };
    unsigned n=sizeof cases/sizeof cases[0];
    for (unsigned i=0;i<n;i++) {
        configure(cases[i].v,cases[i].c,cases[i].i,cases[i].p);
        g_latest=nil; g_latest_mean=nil; g_mean_pso=nil;
        for (int k=0;k<kVSlots;k++) { g_copy[k]=nil; g_mean[k]=nil; }
        uint64_t seq=g_seq;
        if (!cases[i].enabled) {
            // A disabled hook must return before touching Metal, including no compilation or image allocation.
            vxmac_vel_target(NULL,NULL,3);
            assert(!g_on && !g_mean_pso && !g_latest && !g_latest_mean && g_seq==seq);
            for (int k=0;k<kVSlots;k++) assert(!g_copy[k] && !g_mean[k]);
        } else {
            id<MTLCommandBuffer> cb=[q commandBuffer];
            vxmac_vel_target((__bridge void *)cb,(__bridge void *)t,3);
            wait_for(cb);
            assert(g_on && g_seq==seq+1 && g_latest && g_latest_mean && g_mean_pso);
            const float *m=g_latest_mean.contents;
            assert(fabsf(m[0]-.25f)<1e-6f && fabsf(m[1]+.5f)<1e-6f && fabsf(m[2]-.75f)<1e-6f);
        }
    }
    // Other NPU features do not read this target: enabling only SR/optical flow must not request this copy.
    configure(NULL,NULL,NULL,NULL); setenv("VXMAC_NPU","1",1); setenv("VXMAC_FSR","1",1);
    assert(!vel_on()); unsetenv("VXMAC_NPU"); unsetenv("VXMAC_FSR");
    return n+1;
}
static NSDictionary *sample(id<MTLCommandQueue> q, id<MTLTexture> t, int force) {
    enum { frames=8, passes=4 };
    configure(force ? "1" : "auto",NULL,NULL,NULL);
    uint64_t seq=g_seq;
    double start=CACurrentMediaTime();
    id<MTLCommandBuffer> cb=[q commandBuffer];
    for (int f=0;f<frames;f++) for (int p=0;p<passes;p++)
        vxmac_vel_target((__bridge void *)cb,(__bridge void *)t,3);
    wait_for(cb);
    double wall=(CACurrentMediaTime()-start)*1e3/frames;
    assert(g_seq-seq==(force ? frames*passes : 0));
    double gpu=cb.GPUEndTime>cb.GPUStartTime ? (cb.GPUEndTime-cb.GPUStartTime)*1e3/frames : 0;
    return @{@"mode":force ? @"forced-diagnostic" : @"automatic-no-consumer",
             @"encoded_captures":@(g_seq-seq),@"synthetic_frames":@(frames),
             @"gpu_ms_per_synthetic_frame":@(gpu),@"wall_ms_per_synthetic_frame":@(wall)};
}
static int run_demand_test(NSString *path) { @autoreleasepool {
    setenv("VXMAC_VEL_MEAN_PREFETCH","1",1);
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice(); assert(dev);
    id<MTLCommandQueue> q=[dev newCommandQueue]; assert(q);
    id<MTLTexture> t=input(dev);
    unsigned cases=check_policy(q,t);
    (void)sample(q,t,1); (void)sample(q,t,0);
    const int order[]={1,0,0,1,0,1,1,0};
    NSMutableArray *samples=[NSMutableArray array];
    for (unsigned i=0;i<sizeof order/sizeof order[0];i++) [samples addObject:sample(q,t,order[i])];
    NSDictionary *result=@{@"status":@"complete",@"scope":@"standalone production-path test; not game FPS",
        @"device":dev.name,@"policy_cases_passed":@(cases),@"outputs_for_enabled_cases":@"all 3 expected means within 1e-6",
        @"disabled_cases":@"no Metal access, pipeline, texture, buffer, or sequence advance",
        @"alternating_samples":samples};
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
    assert(data && [data writeToFile:path atomically:YES]);
    printf("velocity demand: %u policy cases passed; benchmark saved\n",cases);
    return 0;
} }
#if TARGET_OS_OSX
int main(int argc,char **argv) { assert(argc==2); return run_demand_test(@(argv[1])); }
#elif defined(VXMAC_VELOCITY_DEMAND_APP)
NSString *vx_velocity_demand_app(void) {
    NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *path=[docs stringByAppendingPathComponent:@"velocity_demand.json"];
    [@"{\"status\":\"started\"}" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    run_demand_test(path);
    return @"利用先ごとの検査と、補助処理の速度比較を記録しました。ゲーム全体のFPSは未測定です。";
}
#endif
