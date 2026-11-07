// SPDX-License-Identifier: MIT
// Exercise the production copy/mean path. The original GPU kernel is the numerical oracle.
#include <assert.h>
#include <stdint.h>
#include <TargetConditionals.h>
#include "../app/Sources/velocity.m"
void vxmac_jlog(const char *event, const char *fields) { (void)event; (void)fields; }

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLComputePipelineState> modes[2];
static void completed(id<MTLCommandBuffer> cb) {
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) fprintf(stderr,"GPU: %s\n",cb.error.description.UTF8String);
    assert(cb.status == MTLCommandBufferStatusCompleted);
}
static void mean(id<MTLTexture> tex, int mode, uint32_t out[3]) {
    setenv("VXMAC_VEL_MEAN_PREFETCH",mode ? "1" : "0",1);
    g_mean_pso=modes[mode]; g_mean_prefetch=mode;
    id<MTLCommandBuffer> cb=[queue commandBuffer];
    vxmac_vel_target((__bridge void *)cb,(__bridge void *)tex,3);
    assert(g_mean_pso && g_latest_mean); modes[mode]=g_mean_pso;
    completed(cb);
    memcpy(out,g_latest_mean.contents,12);
}
static id<MTLTexture> texture(unsigned w, unsigned h, int pattern, int array) {
    uint16_t *pixels=malloc((size_t)w*h*4); assert(pixels);
    for (unsigned y=0;y<h;y++) for (unsigned x=0;x<w;x++) for (unsigned k=0;k<2;k++) {
        unsigned n=(y*w+x)*2+k;
        float v=pattern==0 ? 0 : pattern==1 ? ((int)((x*3+y*7+k*11)%71)-35)/64.f
              : (n%3==0 ? 1024.f : n%3==1 ? -1024.f : (n%7+1)/1024.f);
        __fp16 f=(__fp16)v; memcpy(&pixels[n],&f,2);
        if (pattern==3 && n%11<3) pixels[n]=(uint16_t[]){0x7e00,0x7c00,0xfc00}[n%11];
        if (pattern==4) pixels[n]=(uint16_t[]){0x7e00,0x7c00,0xfc00}[n%3];
    }
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead;
    if (array) { d.textureType=MTLTextureType2DArray; d.arrayLength=1; }
    id<MTLTexture> t=[dev newTextureWithDescriptor:d]; assert(t);
    [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 slice:0 withBytes:pixels bytesPerRow:w*4 bytesPerImage:w*h*4];
    free(pixels); return t;
}
static double bench(id<MTLTexture> t, int mode) {
    enum { repeats=32 };
    id<MTLBuffer> out=[dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[queue commandBuffer];
    for (int i=0;i<repeats;i++) {
        id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
        [e setComputePipelineState:modes[mode]]; [e setTexture:t atIndex:0]; [e setBuffer:out offset:0 atIndex:0];
        if (mode) [e dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(256,1,1)];
        else [e dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
        [e endEncoding];
    }
    completed(cb);
    assert(cb.GPUEndTime>cb.GPUStartTime);
    return (cb.GPUEndTime-cb.GPUStartTime)*1000/repeats;
}
static int run_velocity_test(NSString *output) { @autoreleasepool {
    dev=MTLCreateSystemDefaultDevice(); assert(dev); queue=[dev newCommandQueue];
    setenv("VXMAC_VEL","1",1); g_on=-1;
    const unsigned dims[][2]={{256,256},{853,480},{1280,720},{1291,731},{256,1},{256,2},{1920,1080}};
    unsigned cases=0;
    for (unsigned d=0;d<sizeof dims/sizeof dims[0];d++) for (int p=0;p<5;p++) for (int a=0;a<2;a++) {
        @autoreleasepool {
        id<MTLTexture> t=texture(dims[d][0],dims[d][1],p,a);
        uint32_t original[3],prefetched[3]; mean(t,0,original); mean(t,1,prefetched);
        if (memcmp(original,prefetched,12)) {
            fprintf(stderr,"%ux%u pattern%d array%d: %08x/%08x %08x/%08x %08x/%08x\n",
                dims[d][0],dims[d][1],p,a,original[0],prefetched[0],original[1],prefetched[1],original[2],prefetched[2]);
            NSDictionary *failure=@{@"status":@"mismatch",@"width":@(dims[d][0]),@"height":@(dims[d][1]),
                @"pattern":@(p),@"array":@(a),@"cases_passed":@(cases),
                @"original_bits":@[@(original[0]),@(original[1]),@(original[2])],
                @"prefetched_bits":@[@(prefetched[0]),@(prefetched[1]),@(prefetched[2])]};
            [[NSJSONSerialization dataWithJSONObject:failure options:NSJSONWritingPrettyPrinted error:NULL]
                writeToFile:output atomically:YES];
            return 1;
        }
        cases++;
        }
    }
    id<MTLTexture> t=texture(1280,720,1,0);
    (void)bench(t,0); (void)bench(t,1); // Warm both pipelines before alternating.
    NSMutableArray *times=[NSMutableArray array]; NSMutableArray<NSNumber *> *sorted[2]={[NSMutableArray array],[NSMutableArray array]};
    const int order[]={0,1,1,0,1,0,0,1};
    for (unsigned i=0;i<sizeof order/sizeof order[0];i++) {
        double ms=bench(t,order[i]); [times addObject:@{@"mode":@(order[i]),@"gpu_ms_per_dispatch":@(ms)}]; [sorted[order[i]] addObject:@(ms)];
    }
    for (int m=0;m<2;m++) [sorted[m] sortUsingSelector:@selector(compare:)];
    double median[2];
    for (int m=0;m<2;m++) median[m]=([sorted[m][1] doubleValue]+[sorted[m][2] doubleValue])/2;
    NSDictionary *result=@{@"status":@"complete",@"scope":@"standalone GPU microbenchmark; not game FPS",
        @"device":dev.name,@"production_cases_bitwise_equal":@(cases),@"experimental_default_enabled":@NO,
        @"baseline_median_ms":@(median[0]),@"prefetch_median_ms":@(median[1]),@"alternating_samples":times};
    NSError *error=nil; NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
    assert(data && [data writeToFile:output options:NSDataWritingAtomic error:&error]);
    printf("velocity mean: %u production-path cases match all 3 float outputs bit for bit; baseline %.6f ms, prefetch %.6f ms (%s)\n",
        cases,median[0],median[1],dev.name.UTF8String);
    return 0;
} }
#if TARGET_OS_OSX
int main(int argc,char **argv) { assert(argc==2); return run_velocity_test(@(argv[1])); }
#elif defined(VXMAC_VELOCITY_APP)
NSString *vx_velocity_mean_app(void) {
    NSString *dir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *path=[dir stringByAppendingPathComponent:@"velocity_mean.json"];
    // Replace an earlier result before starting, so a failure cannot be mistaken for the previous run.
    [[NSJSONSerialization dataWithJSONObject:@{@"status":@"started",@"unix_s":@(NSDate.date.timeIntervalSince1970)}
        options:0 error:NULL] writeToFile:path atomically:YES];
    if (run_velocity_test(path)) return @"集計値が一致しません。候補は採用しません。";
    return @"全ケースの集計値が一致し、速度比較を記録しました。ゲーム全体のFPSは測っていません。";
}
#endif
