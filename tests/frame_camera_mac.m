// SPDX-License-Identifier: MIT
#import <Metal/Metal.h>
#include "../shims/frame_camera.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
static void camera(float m[16],float degrees) {
    memset(m,0,16*sizeof(float));float a=degrees*.01745329252f;
    m[0]=cosf(a);m[1]=-sinf(a);m[4]=sinf(a);m[5]=cosf(a);m[10]=m[15]=1;
}
int main(void) {@autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);
    id<MTLCommandQueue> queue=[device newCommandQueue];assert(queue);
    id a=[queue commandBuffer],b=[queue commandBuffer],c=[queue commandBuffer];
    float ma[16],mb[16],read[16],tx=0,ty=0;camera(ma,10);camera(mb,35);
    uint64_t qa=vx_frame_camera_store(a,ma,1.4,.8);
    uint64_t qb=vx_frame_camera_store(b,mb,.7,.4);assert(qb>qa);
    // Frame B can be encoded before A is presented. A must retain its own pose
    // and projection; the old global would have selected B's 25-degree turn.
    assert(vx_frame_camera_read(a,read,&tx,&ty)==qa);
    assert(!memcmp(ma,read,sizeof ma) && fabsf(tx-1.4f)<1e-6f && fabsf(ty-.8f)<1e-6f);
    assert(fabsf(atan2f(mb[4],mb[0])-atan2f(read[4],read[0]))>.4f);
    // Rebinding/foreground work and reuse of the game's mutable CPU constants
    // cannot overwrite or alias the source captured from A's world pass.
    assert(vx_frame_camera_store(a,mb,.1,.1)==qa);memset(ma,0,sizeof ma);
    assert(vx_frame_camera_read(a,read,&tx,&ty)==qa && fabsf(read[0]-cosf(.1745329252f))<1e-6);
    dispatch_apply(128,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t n){
        float view[16];camera(view,(float)n);assert(vx_frame_camera_store(c,view,1,.5)>0);
    });
    uint64_t qc=vx_frame_camera_read(c,read,&tx,&ty);assert(qc>qb);
    for(int i=0;i<128;i++)assert(vx_frame_camera_store(c,mb,5,5)==qc);
    assert(vx_frame_camera_read(c,read,&tx,&ty)==qc && tx==1 && ty==.5);
    assert(!vx_frame_camera_read(nil,read,&tx,&ty));
    __weak id lifetime;
    @autoreleasepool {id owner=[NSObject new];assert(!vx_frame_camera_store(owner,mb,0,.5));
        assert(!vx_frame_camera_read(owner,NULL,NULL,NULL));
        assert(vx_frame_camera_store(owner,mb,1,.5));lifetime=objc_getAssociatedObject(owner,kVXFrameCamera);
    }
    assert(lifetime==nil);
    puts("frame camera: interleaved real command buffers retain pose/lens, immutable captures, parallel first writer, unknown ownership and lifetime: ok");
}}
