// SPDX-License-Identifier: MIT
// Real production Metal interception: multiple CBs/image, correct pixels and buffer
// contents with/without frame pacing, unchanged completion-owned drawable permits.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>

static unsigned captures;
static int capture(void *cb,void *tex,uint32_t w,uint32_t h) {
    assert(cb && tex && w==64 && h==64);captures++;return 0;
}
int main(int argc,char **argv) { @autoreleasepool {
    assert(argc==2);
    void (*hook)(void *)=dlsym(RTLD_DEFAULT,"vxmtl_set_present_hook");
    void (*stats)(char *,unsigned)=dlsym(RTLD_DEFAULT,"vxmtl_stats");
    assert(hook && stats);hook((void *)capture);
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice();assert(dev);
    id<MTLCommandQueue> q=[dev newCommandQueue];assert(q);
    CAMetalLayer *layer=[CAMetalLayer layer];layer.device=dev;
    layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.drawableSize=CGSizeMake(64,64);
    id<MTLBuffer> data=[dev newBufferWithLength:8*4096 options:MTLResourceStorageModeShared];
    id<MTLBuffer> pixels=[dev newBufferWithLength:64*64*4 options:MTLResourceStorageModeShared];
    uint64_t hash=1469598103934665603ULL;double start=CACurrentMediaTime();
    enum {frames=64};
    for(unsigned f=0;f<frames;f++) { @autoreleasepool {
        id<CAMetalDrawable> d=[layer nextDrawable];assert(d);
        id<MTLCommandBuffer> last=nil;
        for(unsigned k=0;k<8;k++) {
            id<MTLCommandBuffer> cb=[q commandBuffer];
            id<MTLBlitCommandEncoder> b=[cb blitCommandEncoder];
            [b fillBuffer:data range:NSMakeRange(k*4096,4096) value:(uint8_t)(f+k)];[b endEncoding];
            if(k==7) {
                MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor renderPassDescriptor];
                p.colorAttachments[0].texture=d.texture;p.colorAttachments[0].loadAction=MTLLoadActionClear;
                p.colorAttachments[0].storeAction=MTLStoreActionStore;
                p.colorAttachments[0].clearColor=MTLClearColorMake(1,(f&1)?1:0,0,1);
                [[cb renderCommandEncoderWithDescriptor:p] endEncoding];
                b=[cb blitCommandEncoder];
                [b copyFromTexture:d.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                    sourceSize:MTLSizeMake(64,64,1) toBuffer:pixels destinationOffset:0
                    destinationBytesPerRow:256 destinationBytesPerImage:64*256];[b endEncoding];
                [cb presentDrawable:d];
            }
            [cb commit];last=cb;
        }
        [last waitUntilCompleted];assert(last.status==MTLCommandBufferStatusCompleted);
        const uint8_t *values=data.contents,*rgba=pixels.contents;
        for(unsigned k=0;k<8;k++) for(unsigned i=0;i<4096;i++) assert(values[k*4096+i]==(uint8_t)(f+k));
        for(unsigned i=0;i<64*64;i++) {
            assert(rgba[4*i]==0 && rgba[4*i+1]==((f&1)?255:0) && rgba[4*i+2]==255 && rgba[4*i+3]==255);
            for(unsigned c=0;c<4;c++) {hash^=rgba[4*i+c];hash*=1099511628211ULL;}
        }
    } }
    double elapsed=CACurrentMediaTime()-start;assert(captures==frames);
    char fields[1100];stats(fields,sizeof fields);
    NSString *json=[NSString stringWithFormat:@"{%s}",fields];NSError *err=nil;
    NSMutableDictionary *r=[[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:&err] mutableCopy];
    assert(r && !err && [r[@"presents"] unsignedIntValue]==frames);
    assert([r[@"gpu_cap"] doubleValue]==0 && [r[@"pace_cap_ms"] doubleValue]==0);
    assert([r[@"inflight"] intValue]==2 && [r[@"inflight_timeouts"] intValue]==0);
    BOOL paced=[r[@"pacing"] isEqual:@"frame"] && [r[@"frame_max_fps"] doubleValue]>0;
    if(paced) {
        double hz=[r[@"frame_max_fps"] doubleValue];assert(elapsed>=(frames-1)/hz-.002);
        assert([r[@"pace_frame_waits"] unsignedIntValue]>0 && [r[@"pace_frame_waits"] unsignedIntValue]<frames);
    } else assert([r[@"pace_frame_waits"] intValue]==0);
    r[@"status"]=@"complete";r[@"device"]=dev.name;r[@"verified_images"]=@(frames);
    r[@"verified_command_buffers"]=@(frames*8);r[@"elapsed_seconds"]=@(elapsed);
    r[@"pixel_checksum"]=[NSString stringWithFormat:@"%016llx",(unsigned long long)hash];
    r[@"scope"]=@"synthetic production-shim correctness; no game FPS or latency claim";
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:NULL];
    assert([bytes writeToFile:@(argv[1]) atomically:YES]);printf("64 images, 512 command buffers, all pixels and writes verified (%s)\n",[r[@"pacing"] UTF8String]);
} }
