// SPDX-License-Identifier: MIT
// Test the production permit helper under reordered/concurrent callbacks and real Metal execution.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdatomic.h>
#include "../shims/vxwarp_gate.h"

@interface GateProbe : NSObject { @public atomic_int releases; }
@end
@implementation GateProbe
- (instancetype)init { self=[super init];if(self) atomic_init(&releases,0);return self; }
@end
@interface GateBuffer : NSObject
@property(copy) MTLCommandBufferHandler scheduled;
@property(copy) MTLCommandBufferHandler completed;
@end
@implementation GateBuffer
- (void)addScheduledHandler:(MTLCommandBufferHandler)b { self.scheduled=b; }
- (void)addCompletedHandler:(MTLCommandBufferHandler)b { self.completed=b; }
@end

static void scheduled(GateBuffer *b) { if(b.scheduled) b.scheduled((id)b); }
static void completed(GateBuffer *b) { if(b.completed) b.completed((id)b); }
static void lifecycle_tests(void) {
    GateProbe *nilProbe=[GateProbe new];vxwg_track(NULL,1,^{atomic_fetch_add(&nilProbe->releases,1);});
    assert(atomic_load(&nilProbe->releases)==1);
    for(int mode=0;mode<2;mode++) for(int order=0;order<3;order++) { @autoreleasepool {
        GateBuffer *b=[GateBuffer new];GateProbe *p=[GateProbe new];
        vxwg_track((__bridge void *)b,mode,^{atomic_fetch_add(&p->releases,1);});
        assert(atomic_load(&p->releases)==0 && b.completed && (!!b.scheduled)==mode);
        if(order==0) {
            scheduled(b);assert(atomic_load(&p->releases)==mode);completed(b);
        } else if(order==1) { completed(b);scheduled(b); }
        else { completed(b); } // Failed buffer: no scheduling callback arrives.
        completed(b);scheduled(b);assert(atomic_load(&p->releases)==1);
    } }
    for(int i=0;i<2000;i++) { @autoreleasepool {
        GateBuffer *b=[GateBuffer new];GateProbe *p=[GateProbe new];
        vxwg_track((__bridge void *)b,1,^{atomic_fetch_add(&p->releases,1);});
        dispatch_group_t group=dispatch_group_create();dispatch_queue_t q=dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0);
        dispatch_group_async(group,q,^{scheduled(b);});dispatch_group_async(group,q,^{completed(b);});
        dispatch_group_wait(group,DISPATCH_TIME_FOREVER);assert(atomic_load(&p->releases)==1);
    } }
    __weak GateProbe *weakProbe;
    @autoreleasepool {
        GateBuffer *b=[GateBuffer new];GateProbe *p=[GateProbe new];weakProbe=p;
        vxwg_track((__bridge void *)b,1,^{atomic_fetch_add(&p->releases,1);});scheduled(b);completed(b);
    }
    assert(!weakProbe); // Neither callback nor its ticket forms an ownership cycle.
}

int main(int argc,char **argv) { @autoreleasepool {
    assert(argc==2);lifecycle_tests();
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice();assert(dev);id<MTLCommandQueue> q=[dev newCommandQueue];
    NSString *src=@"#include <metal_stdlib>\nusing namespace metal;kernel void gate_work(device uint *p [[buffer(0)]],uint i [[thread_position_in_grid]]) {p[i]=(i*1664525u+1013904223u)^0x12345678u;}";
    NSError *err=nil;id<MTLLibrary> lib=[dev newLibraryWithSource:src options:nil error:&err];assert(lib);
    id<MTLComputePipelineState> ps=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"gate_work"] error:&err];assert(ps);
    unsigned cases=0;
    for(int mode=0;mode<2;mode++) for(int it=0;it<32;it++) { @autoreleasepool {
        enum { count=65536 };
        id<MTLBuffer> data=[dev newBufferWithLength:count*4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb=[q commandBuffer];GateProbe *p=[GateProbe new];
        vxwg_track((__bridge void *)cb,mode,^{atomic_fetch_add(&p->releases,1);});
        __block int resourceReadComplete=0;
        // Resource ownership is still released only in this completion callback, independent of the gate.
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            assert(done.status==MTLCommandBufferStatusCompleted);
            assert(atomic_load(&p->releases)==1);
            const uint32_t *values=data.contents;
            for(unsigned i=0;i<count;i++) assert(values[i]==((i*1664525u+1013904223u)^0x12345678u));
            resourceReadComplete=1;
        }];
        id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];[e setComputePipelineState:ps];[e setBuffer:data offset:0 atIndex:0];
        [e dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(256,1,1)];[e endEncoding];
        [cb commit];[cb waitUntilCompleted];assert(resourceReadComplete && atomic_load(&p->releases)==1);cases++;
    } }
    NSDictionary *r=@{@"status":@"complete",@"device":dev.name,@"callback_races_passed":@2000,
        @"real_gpu_cases_passed":@(cases),@"completion_resource_checks":@"all 65536 output words verified per case",
        @"default":@"completed",@"scheduled_mode":@"trial only; no game FPS or latency measurement"};
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:NULL];
    assert([bytes writeToFile:@(argv[1]) atomically:YES]);printf("warp gate: callback races and %u real GPU/resource checks passed\n",cases);
    return 0;
} }
