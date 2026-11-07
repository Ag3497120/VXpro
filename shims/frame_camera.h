// SPDX-License-Identifier: MIT
#pragma once
#import <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

// A command buffer owns an immutable camera sample, not a reference to the
// mutable latest-camera globals. The sample never retains its command buffer.
@interface VXFrameCamera : NSObject {
@public uint64_t sequence; float view[16], tan_x, tan_y;
}
@end
@implementation VXFrameCamera
@end
static const void *kVXFrameCamera=&kVXFrameCamera;
static _Atomic uint64_t vx_frame_camera_serial;
static uint64_t vx_frame_camera_next(void) {return atomic_fetch_add(&vx_frame_camera_serial,1)+1;}
static uint64_t vx_frame_camera_read(id buffer,float view[16],float *tx,float *ty) {
    VXFrameCamera *c=buffer ? objc_getAssociatedObject(buffer,kVXFrameCamera) : nil;
    if(!c)return 0;
    if(view)memcpy(view,c->view,sizeof c->view);
    if(tx)*tx=c->tan_x;if(ty)*ty=c->tan_y;
    return c->sequence;
}
static uint64_t vx_frame_camera_store(id buffer,const float view[16],float tx,float ty) {
    if(!buffer || !(tx>0) || !(ty>0))return 0;
    @synchronized(buffer) {
        VXFrameCamera *c=objc_getAssociatedObject(buffer,kVXFrameCamera);
        if(!c) {
            c=[VXFrameCamera new];c->sequence=vx_frame_camera_next();
            memcpy(c->view,view,sizeof c->view);c->tan_x=tx;c->tan_y=ty;
            objc_setAssociatedObject(buffer,kVXFrameCamera,c,OBJC_ASSOCIATION_RETAIN);
        }
        return c->sequence;
    }
}
