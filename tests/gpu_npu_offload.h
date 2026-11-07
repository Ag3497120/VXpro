// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
// Standalone synthetic benchmark; never starts or modifies the game.
NSDictionary *vx_gpu_npu_offload(NSURL *model, NSURL *metalSource, NSURL *weights,
                               NSUInteger iterations, NSArray<NSNumber *> *workloads, NSError **error);
NSString *vx_gpu_npu_offload_app(void);
