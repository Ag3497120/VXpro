// SPDX-License-Identifier: MIT
#import "gpu_npu_offload.h"
#import <Metal/Metal.h>
#import <CoreML/CoreML.h>
#import <CoreVideo/CoreVideo.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <math.h>

static double off_ms(void) {
    static mach_timebase_info_data_t t; if (!t.denom) mach_timebase_info(&t);
    return mach_absolute_time()*(double)t.numer/t.denom/1e6;
}
static double off_memory(void) {
    task_vm_info_data_t v; mach_msg_type_number_t n=TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&v,&n)==KERN_SUCCESS ? v.phys_footprint/1048576.0 : -1;
}
static NSError *off_error(NSString *s) { return [NSError errorWithDomain:@"VXOffloadBench" code:1 userInfo:@{NSLocalizedDescriptionKey:s}]; }
static NSDictionary *off_stats(NSArray<NSNumber *> *numbers) {
    if (!numbers.count) return @{};
    NSArray *sorted=[numbers sortedArrayUsingSelector:@selector(compare:)];
    double total=0; for (NSNumber *n in numbers) total+=n.doubleValue;
    return @{@"count":@(numbers.count),@"mean":@(total/numbers.count),@"median":sorted[sorted.count/2],
             @"p95":sorted[MIN(sorted.count-1,(NSUInteger)(sorted.count*.95))],
             @"p99":sorted[MIN(sorted.count-1,(NSUInteger)(sorted.count*.99))]};
}

@interface VXOffSlot : NSObject {
@public
    CVPixelBufferRef input, output;
    CVMetalTextureRef inputView, outputView;
}
@property id<MTLTexture> scene, up, composed, inputTexture, outputTexture;
@property MLDictionaryFeatureProvider *features;
@property MLPredictionOptions *options;
@property id<MTLBuffer> stamp;
@property dispatch_semaphore_t available;
@end
@implementation VXOffSlot
- (void)dealloc {
    if(inputView) CFRelease(inputView); if(outputView) CFRelease(outputView);
    if(input) CFRelease(input); if(output) CFRelease(output);
}
@end

@interface VXOffBench : NSObject
@property id<MTLDevice> device;
@property id<MTLCommandQueue> queue;
@property NSDictionary<NSString *,id<MTLComputePipelineState>> *pipelines;
@property id<MTLBuffer> weights;
@property MLModel *model;
@property NSArray<VXOffSlot *> *slots;
@property NSUInteger width,height;
@property dispatch_queue_t neural;
@end

@implementation VXOffBench
- (id<MTLTexture>)texture:(MTLPixelFormat)format width:(NSUInteger)w height:(NSUInteger)h {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;d.storageMode=MTLStorageModePrivate;
    return [self.device newTextureWithDescriptor:d];
}
- (id<MTLTexture>)pixelTexture:(CVPixelBufferRef *)pixel view:(CVMetalTextureRef *)view cache:(CVMetalTextureCacheRef)cache width:(NSUInteger)w height:(NSUInteger)h {
    NSDictionary *attributes=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    if(CVPixelBufferCreate(NULL,w,h,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,pixel)!=kCVReturnSuccess) return nil;
    if(CVMetalTextureCacheCreateTextureFromImage(NULL,cache,*pixel,NULL,MTLPixelFormatBGRA8Unorm,w,h,0,view)!=kCVReturnSuccess) return nil;
    return CVMetalTextureGetTexture(*view);
}
- (void)kernel:(NSString *)name command:(id<MTLCommandBuffer>)command textures:(NSArray<id<MTLTexture>> *)textures job:(const void *)job {
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:self.pipelines[name]];
    for(NSUInteger i=0;i<textures.count;++i) [encoder setTexture:textures[i] atIndex:i];
    if(job) [encoder setBytes:job length:16 atIndex:0];
    if([name isEqual:@"offload_cubic"]) [encoder setBuffer:self.weights offset:0 atIndex:0];
    id<MTLTexture> target=textures.lastObject;
    [encoder dispatchThreads:MTLSizeMake(target.width,target.height,1) threadsPerThreadgroup:MTLSizeMake(16,8,1)];
    [encoder endEncoding];
}
- (id<MTLCommandBuffer>)prepare:(VXOffSlot *)slot frame:(NSUInteger)frame work:(NSUInteger)work pattern:(NSUInteger)pattern {
    id<MTLCommandBuffer> command=[self.queue commandBuffer];
    uint32_t job[4]={(uint32_t)frame,(uint32_t)work,(uint32_t)pattern,0};
    [self kernel:@"offload_scene" command:command textures:@[slot.scene] job:job];
    [self kernel:@"offload_input" command:command textures:@[slot.scene,slot.inputTexture] job:NULL];
    return command;
}
- (id<MTLCommandBuffer>)finish:(VXOffSlot *)slot gpuFilter:(BOOL)gpuFilter {
    id<MTLCommandBuffer> command=[self.queue commandBuffer];
    if(gpuFilter) {
        [self kernel:@"offload_cubic" command:command textures:@[slot.inputTexture,slot.up] job:NULL];
        [self kernel:@"offload_finish" command:command textures:@[slot.up,slot.outputTexture] job:NULL];
    }
    [self kernel:@"offload_compose" command:command textures:@[slot.outputTexture,slot.composed] job:NULL];
    id<MTLComputeCommandEncoder> validation=[command computeCommandEncoder];
    [validation setComputePipelineState:self.pipelines[@"offload_validate"]];
    [validation setTexture:slot.composed atIndex:0];[validation setBuffer:slot.stamp offset:0 atIndex:0];
    [validation dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[validation endEncoding];
    return command;
}
- (BOOL)predict:(VXOffSlot *)slot error:(NSError **)error {
    id<MLFeatureProvider> result=[self.model predictionFromFeatures:slot.features options:slot.options error:error];
    if(!result) return NO;
    CVPixelBufferRef got=[result featureValueForName:@"detail"].imageBufferValue;
    if(got!=slot->output) { if(error)*error=off_error(@"Core ML did not use the requested output backing"); return NO; }
    return YES;
}
- (NSData *)readOutput:(VXOffSlot *)slot {
    CVPixelBufferLockBaseAddress(slot->output,kCVPixelBufferLock_ReadOnly);
    NSMutableData *data=[NSMutableData dataWithLength:self.width*self.height*16];
    size_t row=CVPixelBufferGetBytesPerRow(slot->output), bytes=self.width*8;
    const uint8_t *source=CVPixelBufferGetBaseAddress(slot->output);
    for(NSUInteger y=0;y<self.height*2;++y) memcpy((uint8_t *)data.mutableBytes+y*bytes,source+y*row,bytes);
    CVPixelBufferUnlockBaseAddress(slot->output,kCVPixelBufferLock_ReadOnly);
    return data;
}
- (NSDictionary *)quality:(NSError **)error {
    VXOffSlot *slot=self.slots[0];NSMutableArray *cases=[NSMutableArray array];
    for(NSUInteger pattern=0;pattern<3;++pattern) {
        id<MTLCommandBuffer> a=[self prepare:slot frame:17 work:8 pattern:pattern];[a commit];[a waitUntilCompleted];
        id<MTLCommandBuffer> b=[self finish:slot gpuFilter:YES];[b commit];[b waitUntilCompleted];
        if(a.status!=MTLCommandBufferStatusCompleted||b.status!=MTLCommandBufferStatusCompleted) {if(error)*error=off_error(@"quality GPU command failed");return nil;}
        NSData *reference=[self readOutput:slot];
        if(![self predict:slot error:error]) return nil;
        NSData *actual=[self readOutput:slot];
        const uint8_t *x=reference.bytes,*y=actual.bytes;double sum=0,squares=0;NSUInteger maximum=0,count=0,bad=0;
        for(NSUInteger i=0;i<reference.length;++i) if(i%4!=3) {
            NSUInteger d=abs((int)x[i]-(int)y[i]);maximum=MAX(maximum,d);sum+=d;squares+=d*d;++count;if(d>2)++bad;
        }
        double mse=squares/count;
        [cases addObject:@{@"pattern":@(pattern),@"max_byte_error":@(maximum),@"mean_byte_error":@(sum/count),
                           @"fraction_over_two_levels":@((double)bad/count),@"psnr_db":@(mse>0?10*log10(255*255/mse):120),
                           @"accepted":@(maximum<=3 && mse<2)}];
    }
    return @{@"comparison":@"same fixed filter, native Metal versus Core ML CPU_AND_NE; BGRA8 output",@"cases":cases};
}
- (NSDictionary *)run:(NSString *)mode work:(NSUInteger)work count:(NSUInteger)n error:(NSError **)error {
    BOOL gpu=[mode isEqual:@"gpu_only"]||[mode isEqual:@"gpu_serial"], overlap=[mode isEqual:@"offload_overlap"];
    NSUInteger capacity=([mode isEqual:@"gpu_only"]||overlap)?2:1;
    NSInteger thermalStart=NSProcessInfo.processInfo.thermalState;
    dispatch_group_t group=dispatch_group_create();NSLock *lock=[NSLock new];
    NSMutableArray *ages=[NSMutableArray array],*gpuTimes=[NSMutableArray array],*inference=[NSMutableArray array],*completed=[NSMutableArray array];
    NSMutableArray *preTimes=[NSMutableArray array],*postTimes=[NSMutableArray array],*spans=[NSMutableArray array];
    __block NSError *failure=nil;
    double began=off_ms();
    for(NSUInteger i=0;i<n;++i) {
        // Completion handlers can arrive out of order. A global free-count
        // does not prove that this particular surface is safe to overwrite.
        VXOffSlot *slot=self.slots[i%capacity];
        dispatch_semaphore_wait(slot.available,DISPATCH_TIME_FOREVER);
        [lock lock];BOOL stop=failure!=nil;[lock unlock];if(stop){dispatch_semaphore_signal(slot.available);break;}
        double start=off_ms();
        dispatch_group_enter(group);
        id<MTLCommandBuffer> pre=[self prepare:slot frame:i work:work pattern:0];
        void (^finish)(double)=^(double neuralMS) {
            id<MTLCommandBuffer> post=[self finish:slot gpuFilter:gpu];
            [post addCompletedHandler:^(id<MTLCommandBuffer> end) {
                double now=off_ms();
                [lock lock];
                if(pre.status!=MTLCommandBufferStatusCompleted || end.status!=MTLCommandBufferStatusCompleted) failure=end.error?:pre.error?:off_error(@"GPU command failed");
                uint32_t actual=*(uint32_t *)slot.stamp.contents,expected=(uint32_t)((i*7)&255);
                if(abs((int)actual-(int)expected)>1) failure=off_error([NSString stringWithFormat:@"frame stamp mismatch: %u instead of %u",actual,expected]);
                [ages addObject:@(now-start)];[completed addObject:@(now)];[inference addObject:@(neuralMS)];
                [gpuTimes addObject:@((pre.GPUEndTime-pre.GPUStartTime+end.GPUEndTime-end.GPUStartTime)*1000)];
                [preTimes addObject:@((pre.GPUEndTime-pre.GPUStartTime)*1000)];
                [postTimes addObject:@((end.GPUEndTime-end.GPUStartTime)*1000)];
                [spans addObject:@[@(pre.GPUStartTime),@(pre.GPUEndTime)]];
                [spans addObject:@[@(end.GPUStartTime),@(end.GPUEndTime)]];
                [lock unlock];dispatch_semaphore_signal(slot.available);dispatch_group_leave(group);
            }];[post commit];
        };
        if(gpu) {[pre commit];finish(0);}
        else {
            [pre commit];
            // Submit in producer order, rather than callback-arrival order.
            dispatch_async(self.neural,^{ @autoreleasepool {
                    [pre waitUntilCompleted];
                    NSError *e=nil;double t=off_ms();
                    if(pre.status!=MTLCommandBufferStatusCompleted || ![self predict:slot error:&e]) {
                        [lock lock];failure=e?:pre.error?:off_error(@"input GPU command failed");[lock unlock];
                        dispatch_semaphore_signal(slot.available);dispatch_group_leave(group);return;
                    }
                    finish(off_ms()-t);
                }});
        }
    }
    dispatch_group_wait(group,DISPATCH_TIME_FOREVER);
    if(failure){if(error)*error=failure;return nil;}
    double elapsed=off_ms()-began;
    NSMutableArray *intervals=[NSMutableArray array];NSArray *sorted=[completed sortedArrayUsingSelector:@selector(compare:)];
    for(NSUInteger i=1;i<sorted.count;++i)[intervals addObject:@([sorted[i] doubleValue]-[sorted[i-1] doubleValue])];
    NSArray *ordered=[spans sortedArrayUsingComparator:^NSComparisonResult(NSArray *a,NSArray *b){return [a[0] compare:b[0]];}];
    double covered=0,left=-1,right=-1;
    for(NSArray *span in ordered) {
        double a=[span[0] doubleValue],b=[span[1] doubleValue];
        if(a<=0||b<a)continue;
        if(left<0){left=a;right=b;}
        else if(a<=right)right=MAX(right,b);
        else{covered+=right-left;left=a;right=b;}
    }
    if(left>=0)covered+=right-left;
    return @{@"mode":mode,@"work_iterations":@(work),@"frames":@(ages.count),@"slots":@(capacity),
             @"elapsed_ms":@(elapsed),@"synthetic_completed_per_second":@(1000*ages.count/elapsed),
             @"frame_ready_age_ms":off_stats(ages),@"completion_interval_ms":off_stats(intervals),
             @"gpu_command_duration_sum_ms":off_stats(gpuTimes),@"coreml_predict_ms":off_stats(inference),
             @"scene_and_input_gpu_ms":off_stats(preTimes),@"postprocess_and_compose_gpu_ms":off_stats(postTimes),
             @"gpu_command_span_union_ms":@(covered*1000),@"gpu_command_span_coverage":@(covered*1000/elapsed),
             @"thermal_start":@(thermalStart),@"thermal_end":@(NSProcessInfo.processInfo.thermalState),@"frame_stamps_verified":@YES};
}
@end

NSDictionary *vx_gpu_npu_offload(NSURL *modelURL,NSURL *metalURL,NSURL *weightsURL,NSUInteger iterations,NSArray<NSNumber *> *workloads,NSError **error) {
    VXOffBench *bench=[VXOffBench new];bench.device=MTLCreateSystemDefaultDevice();
    if(!bench.device){if(error)*error=off_error(@"no Metal device");return nil;}
    bench.queue=[bench.device newCommandQueue];bench.neural=dispatch_queue_create("vx.offload.neural",DISPATCH_QUEUE_SERIAL);
    NSString *source=[NSString stringWithContentsOfURL:metalURL encoding:NSUTF8StringEncoding error:error];if(!source)return nil;
    id<MTLLibrary> library=[bench.device newLibraryWithSource:source options:nil error:error];if(!library)return nil;
    NSMutableDictionary *pipelines=[NSMutableDictionary dictionary];
    for(NSString *name in @[@"offload_scene",@"offload_input",@"offload_cubic",@"offload_finish",@"offload_compose",@"offload_validate"]) {
        id<MTLComputePipelineState> pipeline=[bench.device newComputePipelineStateWithFunction:[library newFunctionWithName:name] error:error];
        if(!pipeline)return nil;pipelines[name]=pipeline;
    }
    bench.pipelines=pipelines;
    NSData *weights=[NSData dataWithContentsOfURL:weightsURL options:0 error:error];if(weights.length!=400){if(error)*error=off_error(@"expected 100 fp32 weights");return nil;}
    bench.weights=[bench.device newBufferWithBytes:weights.bytes length:weights.length options:MTLResourceStorageModeShared];
    MLModelConfiguration *configuration=[MLModelConfiguration new];configuration.computeUnits=MLComputeUnitsCPUAndNeuralEngine;
    double before=off_memory(),loadStart=off_ms();
    bench.model=[MLModel modelWithContentsOfURL:modelURL configuration:configuration error:error];if(!bench.model)return nil;
    double loadMS=off_ms()-loadStart;
    MLImageConstraint *input=bench.model.modelDescription.inputDescriptionsByName[@"image"].imageConstraint;
    MLImageConstraint *output=bench.model.modelDescription.outputDescriptionsByName[@"detail"].imageConstraint;
    bench.width=input.pixelsWide;bench.height=input.pixelsHigh;
    if(!bench.width || output.pixelsWide!=(NSInteger)(2*bench.width) || output.pixelsHigh!=(NSInteger)(2*bench.height)){if(error)*error=off_error(@"unexpected image sizes");return nil;}
    CVMetalTextureCacheRef cache=NULL;
    if(CVMetalTextureCacheCreate(NULL,NULL,bench.device,NULL,&cache)!=kCVReturnSuccess){if(error)*error=off_error(@"texture cache failed");return nil;}
    NSMutableArray *slots=[NSMutableArray array];
    for(NSUInteger i=0;i<2;++i) {
        VXOffSlot *slot=[VXOffSlot new];
        slot.available=dispatch_semaphore_create(1);
        slot.scene=[bench texture:MTLPixelFormatRGBA16Float width:1280 height:720];
        slot.up=[bench texture:MTLPixelFormatRGBA16Float width:2*bench.width height:2*bench.height];
        slot.composed=[bench texture:MTLPixelFormatBGRA8Unorm width:2*bench.width height:2*bench.height];
        slot.stamp=[bench.device newBufferWithLength:16 options:MTLResourceStorageModeShared];
        slot.inputTexture=[bench pixelTexture:&slot->input view:&slot->inputView cache:cache width:bench.width height:bench.height];
        slot.outputTexture=[bench pixelTexture:&slot->output view:&slot->outputView cache:cache width:2*bench.width height:2*bench.height];
        if(!slot.scene||!slot.up||!slot.composed||!slot.inputTexture||!slot.outputTexture){CFRelease(cache);if(error)*error=off_error(@"texture allocation failed");return nil;}
        slot.features=[[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"image":[MLFeatureValue featureValueWithPixelBuffer:slot->input]} error:error];
        slot.options=[MLPredictionOptions new];slot.options.outputBackings=@{@"detail":(__bridge id)slot->output};
        [slots addObject:slot];
    }
    CFRelease(cache);bench.slots=slots;
    NSDictionary *quality=[bench quality:error];if(!quality)return nil;
    for(NSDictionary *q in quality[@"cases"]) if(![q[@"accepted"] boolValue]){if(error)*error=off_error([NSString stringWithFormat:@"quality mismatch: %@",quality]);return nil;}
    NSMutableArray *blocks=[NSMutableArray array];
    BOOL focused=[NSProcessInfo.processInfo.arguments containsObject:@"--focused"];
    NSArray *schedule=focused ? @[@"gpu_only",@"offload_overlap",@"offload_overlap",@"gpu_only"] :
        @[@"gpu_only",@"offload_overlap",@"offload_serial",@"gpu_serial",@"gpu_serial",@"offload_serial",@"offload_overlap",@"gpu_only"];
    for(NSNumber *work in workloads) for(NSUInteger repeat=0;repeat<2;++repeat) for(NSString *mode in schedule) {
        if(![bench run:mode work:work.unsignedIntegerValue count:4 error:error])return nil;
        NSDictionary *result=[bench run:mode work:work.unsignedIntegerValue count:iterations error:error];if(!result)return nil;
        [blocks addObject:result];fprintf(stderr,"offload: work=%lu mode=%s completed\n",(unsigned long)work.unsignedIntegerValue,mode.UTF8String);
    }
    return @{@"benchmark_version":@"fixed-sr-offload-v2-slot-ownership",
             @"scope":@"standalone synthetic GPU load and matched fixed filter; not game FPS, headset input latency or an M2/M5 comparison",
             @"gpu":bench.device.name,@"os":[NSProcessInfo processInfo].operatingSystemVersionString,
             @"input_size":@[@(bench.width),@(bench.height)],@"scene_size":@[@1280,@720],
             @"requested_compute_units":@"CPU_AND_NE",@"load_ms":@(loadMS),@"quality":quality,
             @"memory_mb_before_load":@(before),@"memory_mb_after":@(off_memory()),@"blocks":blocks,
             @"backings_verified":@YES,@"inference_concurrency_limit":@1,@"pipeline_slot_limit":@2};
}

#if defined(VX_OFFLOAD_APP)
static NSDictionary *off_device_plan(NSURL *compiled) {
    MLModelConfiguration *configuration=[MLModelConfiguration new];configuration.computeUnits=MLComputeUnitsCPUAndNeuralEngine;
    dispatch_semaphore_t semaphore=dispatch_semaphore_create(0);
    __block NSDictionary *result=nil;
    [MLComputePlan loadContentsOfURL:compiled configuration:configuration completionHandler:^(MLComputePlan *plan,NSError *error){
        if(!plan) result=@{@"unavailable":error.description?:@"no plan"};
        else {
            NSMutableDictionary *counts=[NSMutableDictionary dictionary];double total=0,neural=0;
            for(MLModelStructureProgramOperation *operation in plan.modelStructure.program.functions[@"main"].block.operations) {
                MLComputePlanDeviceUsage *usage=[plan computeDeviceUsageForMLProgramOperation:operation];
                MLComputePlanCost *cost=[plan estimatedCostOfMLProgramOperation:operation];
                NSString *device=!usage?@"unreported":[usage.preferredComputeDevice isKindOfClass:MLNeuralEngineComputeDevice.class]?@"ANE":
                    [usage.preferredComputeDevice isKindOfClass:MLCPUComputeDevice.class]?@"CPU":@"other";
                NSString *key=[NSString stringWithFormat:@"%@ %@",device,operation.operatorName];
                counts[key]=@([counts[key] unsignedIntegerValue]+1);total+=cost.weight;if([device isEqual:@"ANE"])neural+=cost.weight;
            }
            result=@{@"scope":@"preferred devices and estimated costs, not actual per-operation execution trace",@"operations":counts,
                     @"ane_estimated_cost_share":@(total>0?neural/total:0)};
        }
        dispatch_semaphore_signal(semaphore);
    }];
    if(dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC)))return @{@"unavailable":@"plan timed out"};
    return result?:@{};
}
NSString *vx_gpu_npu_offload_app(void) { @autoreleasepool {
    NSURL *resources=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"BenchData"];
    NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *progress=[documents URLByAppendingPathComponent:@"offload-progress.txt"];
    [@"compiling model" writeToURL:progress atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSError *error=nil;double start=off_ms();
    NSURL *compiled=[MLModel compileModelAtURL:[resources URLByAppendingPathComponent:@"FixedSR.mlpackage"] error:&error];
    double compileMS=off_ms()-start;
    BOOL focused=[NSProcessInfo.processInfo.arguments containsObject:@"--focused"];
    BOOL planOnly=[NSProcessInfo.processInfo.arguments containsObject:@"--plan-only"];
    NSDictionary *report=nil;
    if(compiled) {
        [@"running independent benchmark" writeToURL:progress atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if(planOnly) report=off_device_plan(compiled);
        else {
            NSMutableDictionary *measured=[vx_gpu_npu_offload(compiled,[resources URLByAppendingPathComponent:@"gpu_npu_offload.metal"],
                                 [resources URLByAppendingPathComponent:@"weights.bin"],focused?60:12,focused?@[@2048]:@[@0,@64,@512,@2048],&error) mutableCopy];
            if(measured)measured[@"compute_plan"]=off_device_plan(compiled);
            report=measured;
        }
    }
    NSMutableDictionary *result=report ? [report mutableCopy] : [@{@"error":error.description?:@"unknown benchmark failure"} mutableCopy];
    result[@"model_compile_ms"]=@(compileMS);
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
    NSString *filename=planOnly?@"offload-plan.json":focused?@"offload-focused-result-v2.json":@"offload-result-v2.json";
    if(data)[data writeToURL:[documents URLByAppendingPathComponent:filename] options:NSDataWritingAtomic error:&error];
    NSString *status=report ? @"測定が完了しました。結果をMacへ回収できます。" : [NSString stringWithFormat:@"測定を停止しました：%@",error.localizedDescription?:result[@"error"]];
    [status writeToURL:progress atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return status;
}}
#else
int main(int argc,char **argv) { @autoreleasepool {
    if(argc<5){fprintf(stderr,"usage: gpu_npu_offload model.mlmodelc source.metal weights.bin result.json [iterations]\n");return 2;}
    NSError *error=nil;
    NSMutableArray *workloads=[NSMutableArray array];
    for(NSString *part in [(argc>6?@(argv[6]):@"0,64,512,2048") componentsSeparatedByString:@","]) [workloads addObject:@(part.integerValue)];
    NSDictionary *report=vx_gpu_npu_offload([NSURL fileURLWithPath:@(argv[1])],[NSURL fileURLWithPath:@(argv[2])],[NSURL fileURLWithPath:@(argv[3])],argc>5?strtoul(argv[5],NULL,10):20,workloads,&error);
    if(!report){fprintf(stderr,"offload: %s\n",error.description.UTF8String);return 1;}
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
    if(!data||![data writeToURL:[NSURL fileURLWithPath:@(argv[4])] options:NSDataWritingAtomic error:&error]){fprintf(stderr,"write: %s\n",error.description.UTF8String);return 1;}
    return 0;
}}
#endif
