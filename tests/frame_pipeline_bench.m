// SPDX-License-Identifier: MIT
// Independent Metal correctness probe. Its 90 Hz CPU timer is NOT a display,
// game FPS measurement, or a sensor-to-photon latency measurement.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import "frame_pipeline_bench.h"
#include "../vr/frame_pipeline.h"
#include <pthread.h>
#include <unistd.h>

static NSString *const source = @
"#include <metal_stdlib>\nusing namespace metal;\n"
"float4 stamp(uint n) { return float4(float(n&255u),float((n>>8)&255u),float((n>>16)&255u),float(n>>24))/255.0; }\n"
"uint number(float4 c) { uint4 v=uint4(round(c*255.0)); return v.x|(v.y<<8)|(v.z<<16)|(v.w<<24); }\n"
"kernel void scene(texture2d<float,access::write> out [[texture(0)]], constant uint& seq [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
" float v=float(((p.x+seq*3)/16+p.y/16)%2); float4 c=float4(v,float(p.y)/out.get_height(),.3,1);\n"
" if(all(p==uint2(0))) c=stamp(seq); out.write(c,p); }\n"
// Nearest resizing is deliberately just a placeholder, not a quality model.
"kernel void process(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> out [[texture(1)]], uint2 p [[thread_position_in_grid]]) { out.write(src.read(p/2),p); }\n"
"kernel void display(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> out [[texture(1)]], constant uint& input [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
" float4 c=src.read(p); if(all(p==uint2(1,0))) c=stamp(input); out.write(c,p); }\n"
"kernel void validate(texture2d<float,access::read> src [[texture(0)]], device uint* out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[0]=number(src.read(uint2(0))); out[1]=number(src.read(uint2(1,0))); }\n";

static NSDictionary *distribution(NSArray<NSNumber *> *values) {
    if (!values.count) return @{};
    NSArray *s = [values sortedArrayUsingSelector:@selector(compare:)];
    return @{@"count":@(s.count), @"median":s[s.count/2], @"p95":s[MIN(s.count-1,s.count*95/100)], @"max":s.lastObject};
}

@interface VXFrameSlot : NSObject
@property id<MTLTexture> scene, processed;
@end
@implementation VXFrameSlot
@end
@interface VXFrameOutput : NSObject
@property id<MTLTexture> image;
@property id<MTLBuffer> check;
@property BOOL busy;
@end
@implementation VXFrameOutput
@end

@interface VXFrameBench : NSObject {
@public
    vxfp_pipeline pipeline;
    pthread_mutex_t lock;
    uint64_t checked, errors, sourceTicks, displayTicks, noReady, outputBusy;
    uint64_t reordered, lastCompletion, injectedFailures, maxPending;
}
@property id<MTLDevice> device;
@property id<MTLCommandQueue> renderQueue, processQueue, displayQueue;
@property NSDictionary<NSString *, id<MTLComputePipelineState>> *kernels;
@property NSArray<VXFrameSlot *> *slots;
@property NSArray<VXFrameOutput *> *outputs;
@property dispatch_group_t jobs;
@property dispatch_queue_t worker;
@property NSMutableArray<NSNumber *> *selectionMs, *sourceAgeMs;
@property size_t plannedBytes, allocatedBytes, budget;
@property double delay;
@property BOOL stress;
- (instancetype)initWithDevice:(id<MTLDevice>)device delay:(double)delay stress:(BOOL)stress error:(NSError **)error;
- (NSDictionary *)run:(double)seconds;
@end

@implementation VXFrameBench
- (MTLTextureDescriptor *)descriptor:(NSUInteger)w height:(NSUInteger)h {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModePrivate;
    return d;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device delay:(double)delay stress:(BOOL)stress error:(NSError **)error {
    self = [super init]; if (!self) return nil;
    pthread_mutex_init(&lock, NULL);
    _device = device; _delay = delay; _stress = stress;
    if (!vxfp_init(&pipeline, delay, .080)) return nil;
    _jobs = dispatch_group_create(); _worker = dispatch_queue_create("VX frame preparation", DISPATCH_QUEUE_SERIAL);
    _selectionMs = [NSMutableArray array]; _sourceAgeMs = [NSMutableArray array];
    _renderQueue = [device newCommandQueue]; _renderQueue.label = @"VX frame source";
    _processQueue = [device newCommandQueue]; _processQueue.label = @"VX frame processing";
    _displayQueue = [device newCommandQueue]; _displayQueue.label = @"VX frame presentation probe";
    if (!_renderQueue || !_processQueue || !_displayQueue) return nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:error];
    if (!library) return nil;
    NSMutableDictionary *kernels = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"scene", @"process", @"display", @"validate"]) {
        id<MTLComputePipelineState> state = [device newComputePipelineStateWithFunction:[library newFunctionWithName:name] error:error];
        if (!state) return nil; kernels[name] = state;
    }
    _kernels = kernels;
    MTLTextureDescriptor *small = [self descriptor:320 height:180], *large = [self descriptor:640 height:360];
    size_t a = [device heapTextureSizeAndAlignWithDescriptor:small].size;
    size_t b = [device heapTextureSizeAndAlignWithDescriptor:large].size;
    size_t checkSize = [device heapBufferSizeAndAlignWithLength:16 options:MTLResourceStorageModeShared].size;
    _budget = 16 * 1024 * 1024;
    if (a > SIZE_MAX - b || b > SIZE_MAX - checkSize || !vxfp_memory_plan(a+b, b+checkSize, 2, _budget, &_plannedBytes)) return nil;
    NSMutableArray *slots = [NSMutableArray array], *outputs = [NSMutableArray array];
    for (int i = 0; i < VXFP_SLOTS; i++) {
        VXFrameSlot *s = [VXFrameSlot new];
        s.scene = [device newTextureWithDescriptor:small]; s.processed = [device newTextureWithDescriptor:large];
        if (!s.scene || !s.processed) return nil;
        _allocatedBytes += s.scene.allocatedSize + s.processed.allocatedSize;
        [slots addObject:s];
    }
    for (int i = 0; i < 2; i++) {
        VXFrameOutput *o = [VXFrameOutput new];
        o.image = [device newTextureWithDescriptor:large];
        o.check = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
        if (!o.image || !o.check) return nil;
        _allocatedBytes += o.image.allocatedSize + o.check.allocatedSize;
        [outputs addObject:o];
    }
    if (_allocatedBytes > _budget) return nil;
    _slots = slots; _outputs = outputs;
    return self;
}
- (void)dealloc { pthread_mutex_destroy(&lock); }
- (BOOL)encode:(NSString *)name command:(id<MTLCommandBuffer>)command textures:(NSArray<id<MTLTexture>> *)textures number:(uint32_t)number output:(id<MTLBuffer>)output {
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!encoder) return NO;
    [encoder setComputePipelineState:self.kernels[name]];
    for (NSUInteger i = 0; i < textures.count; i++) [encoder setTexture:textures[i] atIndex:i];
    if (output) [encoder setBuffer:output offset:0 atIndex:0];
    else if ([name isEqual:@"scene"] || [name isEqual:@"display"]) [encoder setBytes:&number length:sizeof number atIndex:0];
    MTLSize size = output ? MTLSizeMake(1,1,1) : MTLSizeMake(textures.lastObject.width,textures.lastObject.height,1);
    [encoder dispatchThreads:size threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [encoder endEncoding];
    return YES;
}
- (void)finish:(vxfp_ticket)ticket success:(BOOL)success {
    pthread_mutex_lock(&lock);
    if (ticket.sequence < lastCompletion) reordered++;
    lastCompletion = MAX(lastCompletion, ticket.sequence);
    if (!vxfp_complete(&pipeline, ticket, CACurrentMediaTime(), success)) errors++;
    pthread_mutex_unlock(&lock);
    dispatch_group_leave(self.jobs);
}
- (void)fail:(vxfp_ticket)ticket {
    pthread_mutex_lock(&lock); errors++; pthread_mutex_unlock(&lock);
    [self finish:ticket success:NO];
}
- (void)produce:(uint64_t)sequence now:(double)now {
    vxfp_ticket ticket;
    pthread_mutex_lock(&lock); sourceTicks++;
    BOOL accepted = vxfp_acquire(&pipeline, sequence, now, &ticket);
    unsigned pending = 0;
    for (int i = 0; i < VXFP_SLOTS; i++) if (pipeline.slots[i].state == VXFP_RENDERING || pipeline.slots[i].state == VXFP_PROCESSING) pending++;
    maxPending = MAX(maxPending, pending);
    pthread_mutex_unlock(&lock);
    if (!accepted) return;
    dispatch_group_enter(self.jobs);
    VXFrameSlot *slot = self.slots[ticket.slot];
    id<MTLCommandBuffer> render = [self.renderQueue commandBuffer];
    if (!render || ![self encode:@"scene" command:render textures:@[slot.scene] number:(uint32_t)sequence output:nil]) {
        [self fail:ticket]; return;
    }
    [render addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status != MTLCommandBufferStatusCompleted) { [self fail:ticket]; return; }
        dispatch_async(self.worker, ^{ @autoreleasepool {
            pthread_mutex_lock(&self->lock); BOOL valid = vxfp_process(&self->pipeline, ticket); pthread_mutex_unlock(&self->lock);
            if (!valid) { [self fail:ticket]; return; }
            id<MTLCommandBuffer> process = [self.processQueue commandBuffer];
            if (!process || ![self encode:@"process" command:process textures:@[slot.scene,slot.processed] number:0 output:nil]) {
                [self fail:ticket]; return;
            }
            [process addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                BOOL inject = self.stress && sequence % 11 == 0;
                BOOL success = completed.status == MTLCommandBufferStatusCompleted && !inject;
                if (completed.status != MTLCommandBufferStatusCompleted) { pthread_mutex_lock(&self->lock); self->errors++; pthread_mutex_unlock(&self->lock); }
                if (inject) { pthread_mutex_lock(&self->lock); self->injectedFailures++; pthread_mutex_unlock(&self->lock); }
                // Tests delayed/out-of-order publication without pretending that
                // a CPU timer represents Neural Engine or R1 execution time.
                double lag = self.stress && sequence % 3 == 1 ? .150 : 0;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(lag*NSEC_PER_SEC)), self.worker, ^{ [self finish:ticket success:success]; });
            }];
            [process commit];
        }});
    }];
    [render commit];
}
- (void)display:(uint32_t)tick now:(double)now {
    VXFrameOutput *output = nil; vxfp_ticket ticket; vxfp_reason why;
    double begin = CACurrentMediaTime();
    pthread_mutex_lock(&lock); displayTicks++;
    for (VXFrameOutput *o in self.outputs) if (!o.busy) { output = o; break; }
    if (!output) { outputBusy++; pthread_mutex_unlock(&lock); return; }
    // A synthetic input event bypasses intentional buffering. It is not a
    // measurement of Joy-Con latency or a change to real game input handling.
    BOOL active = tick % 90 >= 30 && tick % 90 < 36;
    if (!vxfp_select(&pipeline, now, active, &ticket, &why)) { noReady++; pthread_mutex_unlock(&lock); return; }
    output.busy = YES;
    [self.sourceAgeMs addObject:@((now - pipeline.slots[ticket.slot].content_time)*1000)];
    pthread_mutex_unlock(&lock);
    dispatch_group_enter(self.jobs);
    id<MTLCommandBuffer> command = [self.displayQueue commandBuffer];
    BOOL ok = command && [self encode:@"display" command:command textures:@[self.slots[ticket.slot].processed,output.image] number:tick output:nil] &&
        [self encode:@"validate" command:command textures:@[output.image] number:0 output:output.check];
    if (!ok) {
        pthread_mutex_lock(&lock); errors++; vxfp_release(&pipeline, ticket); output.busy = NO; pthread_mutex_unlock(&lock);
        dispatch_group_leave(self.jobs); return;
    }
    [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
        const uint32_t *stamp = output.check.contents;
        pthread_mutex_lock(&self->lock);
        if (done.status != MTLCommandBufferStatusCompleted || stamp[0] != ticket.sequence || stamp[1] != tick) self->errors++;
        else self->checked++;
        if (!vxfp_release(&self->pipeline, ticket)) self->errors++;
        output.busy = NO;
        pthread_mutex_unlock(&self->lock);
        dispatch_group_leave(self.jobs);
    }];
    [command commit];
    pthread_mutex_lock(&lock); [self.selectionMs addObject:@((CACurrentMediaTime()-begin)*1000)]; pthread_mutex_unlock(&lock);
}
- (NSDictionary *)run:(double)seconds {
    double start = CACurrentMediaTime(), nextSource = start, nextDisplay = start;
    uint64_t sourceSequence = 0; uint32_t tick = 0;
    while (CACurrentMediaTime() - start < seconds) { @autoreleasepool {
        double now = CACurrentMediaTime();
        if (now >= nextSource) {
            nextSource += 1.0/30;
            if (nextSource < now) nextSource = now + 1.0/30;
            // Also test a stalled producer while the display path keeps running.
            if (!(self.stress && now-start > .70 && now-start < .95)) [self produce:++sourceSequence now:now];
        }
        if (now >= nextDisplay) {
            nextDisplay += 1.0/90;
            if (nextDisplay < now) nextDisplay = now + 1.0/90;
            [self display:++tick now:now];
        }
        usleep(250);
    }}
    BOOL drained = dispatch_group_wait(self.jobs, dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC)) == 0;
    pthread_mutex_lock(&lock);
    BOOL idle = YES;
    for (int i = 0; i < VXFP_SLOTS; i++) if (pipeline.slots[i].readers || pipeline.slots[i].state == VXFP_RENDERING || pipeline.slots[i].state == VXFP_PROCESSING) idle = NO;
    BOOL covered = !self.stress || (reordered && injectedFailures && pipeline.late_bypasses && pipeline.capacity_drops);
    BOOL pass = drained && idle && covered && checked > 30 && !errors && !pipeline.rejected_callbacks && self.allocatedBytes <= self.budget && pipeline.repeats;
    NSDictionary *result = @{@"passed":@(pass), @"delay_ms":@(self.delay*1000), @"stress":@(self.stress),
        @"seconds":@(seconds), @"drained":@(drained), @"idle":@(idle), @"stress_coverage":@(covered),
        @"source_ticks":@(sourceTicks), @"admitted":@(pipeline.admitted), @"capacity_drops":@(pipeline.capacity_drops),
        @"display_cpu_ticks":@(displayTicks), @"validated_gpu_outputs":@(checked), @"errors":@(errors),
        @"no_ready_skips":@(noReady), @"output_busy_skips":@(outputBusy), @"repeats":@(pipeline.repeats),
        @"input_bypasses":@(pipeline.input_bypasses), @"late_bypasses":@(pipeline.late_bypasses),
        @"reordered_completions":@(reordered), @"injected_failures":@(injectedFailures),
        @"rejected_callbacks":@(pipeline.rejected_callbacks), @"max_pending_frames":@(maxPending),
        @"pool_planned_bytes":@(self.plannedBytes), @"pool_allocated_bytes":@(self.allocatedBytes), @"pool_budget_bytes":@(self.budget),
        @"pool_texture_count":@8, @"pool_readback_buffer_count":@2,
        @"source_age_at_cpu_selection_ms":distribution(self.sourceAgeMs), @"cpu_encode_submit_ms":distribution(self.selectionMs)};
    pthread_mutex_unlock(&lock);
    return result;
}
@end

static NSDictionary *run_all(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return @{@"passed":@NO, @"error":@"Metal device not available"};
    NSMutableArray *cases = [NSMutableArray array]; BOOL passed = YES;
    for (int i = 0; i < 3; i++) { @autoreleasepool {
        NSError *error = nil;
        VXFrameBench *bench = [[VXFrameBench alloc] initWithDevice:device delay:i == 0 ? 0 : 1.0/30 stress:i == 2 error:&error];
        if (!bench) { passed = NO; [cases addObject:@{@"passed":@NO, @"error":error.localizedDescription ?: @"pool allocation or configuration failed"}]; break; }
        NSDictionary *result = [bench run:2]; [cases addObject:result];
        if (![result[@"passed"] boolValue]) { passed = NO; break; }
    }}
    return @{@"version":@"bounded-frame-pipeline-v1", @"passed":@(passed), @"device":device.name,
        @"os":NSProcessInfo.processInfo.operatingSystemVersionString,
        @"real_display_measurement":@NO, @"game_fps_measurement":@NO, @"controller_latency_measurement":@NO,
        @"npu_model_used":@NO, @"r1_access":@NO, @"latest_input_test":@"synthetic per-display tick encoded and read back on GPU",
        @"processing":@"nearest resize placeholder; no super-resolution quality claim", @"cases":cases};
}
NSString *vx_frame_pipeline_app(void) { @autoreleasepool {
    NSDictionary *result = run_all();
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSError *error = nil;
    if (![data writeToURL:[directory URLByAppendingPathComponent:@"frame-pipeline-result-v1.json"] options:NSDataWritingAtomic error:&error]) return error.localizedDescription;
    return [result[@"passed"] boolValue] ? @"画像の所有権・再利用・加工遅延時の分岐の検査が完了しました。ゲームのFPS・表示遅延は未測定です。" : @"検査で問題を検出しました。記録を確認します。";
}}
#ifndef VX_FRAME_PIPELINE_APP
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) { fprintf(stderr, "usage: frame_pipeline_bench OUTPUT.json\n"); return 2; }
    NSDictionary *result = run_all();
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    NSError *error = nil;
    if (![data writeToFile:[NSString stringWithUTF8String:argv[1]] options:NSDataWritingAtomic error:&error]) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    printf("frame pipeline Metal: %s (%s)\n", [result[@"passed"] boolValue] ? "ok" : "FAILED", [result[@"device"] UTF8String]);
    return [result[@"passed"] boolValue] ? 0 : 1;
}}
#endif
