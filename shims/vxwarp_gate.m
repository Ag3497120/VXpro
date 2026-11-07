// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdatomic.h>
#include "vxwarp_gate.h"

@interface VXWarpGateTicket : NSObject {
    atomic_int released;
    void (^onRelease)(void);
}
- (instancetype)initWithRelease:(void (^)(void))release;
- (void)releaseOnce;
@end

@implementation VXWarpGateTicket
- (instancetype)initWithRelease:(void (^)(void))release {
    self = [super init];
    if (self) { atomic_init(&released, 0); onRelease = [release copy]; }
    return self;
}
- (void)releaseOnce {
    if (!atomic_exchange(&released, 1)) onRelease();
}
@end

void vxwg_track(void *command_buffer, int release_when_scheduled, void (^release)(void)) {
    if (!release) return;
    // Even a failed/no-buffer path must not strand the caller's permit.
    if (!command_buffer) { release(); return; }
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)command_buffer;
    VXWarpGateTicket *ticket = [[VXWarpGateTicket alloc] initWithRelease:release];
    if (release_when_scheduled) [cb addScheduledHandler:^(id<MTLCommandBuffer> unused) {
        (void)unused; [ticket releaseOnce];
    }];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> unused) {
        (void)unused; [ticket releaseOnce];
    }];
}
