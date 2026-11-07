// SPDX-License-Identifier: MIT
// Actual presenter submission/selection/read ownership, including the first
// motion packet after skipped history and changes of texture size/format.
#define main existing_presenter_cases
#include "presenter_pipeline_mac.m"
#undef main

static id<MTLTexture> fixture_motion;
static int fixture_packet;
static int take_history_scene(void **mv, void **depth, uint32_t *c) {
    memset(c,0,128);*mv=NULL;*depth=NULL;
    if (!fixture_packet) return 0;
    *mv=(void *)CFBridgingRetain(fixture_motion);
    return 1; // A motion packet without projection still conservatively keeps history.
}
static uint32_t pixel(unsigned f,unsigned i) { return 0xff000000u | ((f*131u+i*17u)&0xffffffu); }

@interface HistoryRead : NSObject
@property id<MTLCommandBuffer> command;
@property id<MTLBuffer> color, previous;
@property dispatch_semaphore_t done;
@property unsigned width,height,row,frame,previousFrame;
@end
@implementation HistoryRead
@end
static uint64_t finish_history_read(HistoryRead *r) {
    [r.command commit];wait_signal(r.done);
    assert(r.command.status==MTLCommandBufferStatusCompleted);
    uint64_t hash=1469598103934665603ULL;
    for(unsigned y=0;y<r.height;y++) for(unsigned x=0;x<r.width;x++) {
        unsigned i=y*r.width+x;
        uint32_t got=((const uint32_t *)((const uint8_t *)r.color.contents+y*r.row))[x];
        assert(got==pixel(r.frame,i));hash=(hash^got)*1099511628211ULL;
        if(r.previous) assert(((const uint32_t *)((const uint8_t *)r.previous.contents+y*r.row))[x]==pixel(r.previousFrame,i));
    }
    return hash;
}
int main(int argc,char **argv) { @autoreleasepool {
    assert(argc==4);
    BOOL demand=!strcmp(argv[1],"demand");int model=atoi(argv[2]);assert(model>=0 && model<=2);
    setenv("VXMAC_HISTORY_COPY",demand?"demand":"always",1);
    setenv("VXMAC_INTERP",model==2?"vel":model==1?"1":"0",1);
    setenv("VXMAC_FRAME_PIPELINE","1",1);setenv("VXRT_VR_MODE","head",1);setenv("VXMAC_FLOOR","0",1);
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);
    vx_xros_vr_enable(1);id<MTLCommandQueue> producer=[device newCommandQueue],display=[device newCommandQueue];
    MTLTextureDescriptor *md=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float width:2 height:2 mipmapped:NO];
    md.storageMode=MTLStorageModeShared;fixture_motion=[device newTextureWithDescriptor:md];assert(fixture_motion);
    scene_fixture=take_history_scene;
    unsigned lastW=0,lastH=0,lastFrame=0;MTLPixelFormat lastFormat=MTLPixelFormatInvalid;
    unsigned copies=0,skips=0;uint64_t hash=1469598103934665603ULL;HistoryRead *held=nil;
    for(unsigned f=0;f<48;f++) { @autoreleasepool {
        unsigned group=f/12,w=group==2?64:32,h=group==2?32:16;
        MTLPixelFormat format=(group==1 || group==2)?MTLPixelFormatRGBA8Unorm:MTLPixelFormatBGRA8Unorm;
        unsigned phase=f%12;fixture_packet=phase==3 || phase==5 || phase==8 || phase==11;
        BOOL expectedHistory=!demand || model!=0 || fixture_packet;
        unsigned prevFrame=lastW==w && lastH==h && lastFormat==format?lastFrame:f;
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
        d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> source=[device newTextureWithDescriptor:d];assert(source);
        uint32_t data[64*32];for(unsigned i=0;i<w*h;i++) data[i]=pixel(f,i);
        [source replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:data bytesPerRow:w*4];
        dispatch_semaphore_t copied=dispatch_semaphore_create(0);id<MTLCommandBuffer> cb=[producer commandBuffer];
        vx_xros_vr_submit((__bridge void *)cb,(__bridge void *)source,w,h,released,(__bridge void *)copied);
        [cb commit];wait_signal(copied);assert(cb.status==MTLCommandBufferStatusCompleted);
        assert(vx_xros_vr_begin_frame(head,CACurrentMediaTime()+.01));assert(g_frame_slot>=0);
        vr_slot *slot=&g_slot[g_frame_slot];assert(slot->has_prev_image==expectedHistory);
        if(expectedHistory) { copies++;assert(slot->prev && slot->prev_view && slot->prev_view.pixelFormat==srgb_of(format)); }
        else skips++;
        HistoryRead *r=[HistoryRead new];r.width=w;r.height=h;r.row=256;r.frame=f;r.previousFrame=prevFrame;
        r.command=[display commandBuffer];r.done=dispatch_semaphore_create(0);
        r.color=[device newBufferWithLength:r.row*h options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit=[r.command blitCommandEncoder];
        [blit copyFromTexture:slot->color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1) toBuffer:r.color destinationOffset:0 destinationBytesPerRow:r.row destinationBytesPerImage:r.row*h];
        if(expectedHistory) {
            r.previous=[device newBufferWithLength:r.row*h options:MTLResourceStorageModeShared];
            [blit copyFromTexture:slot->prev sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1) toBuffer:r.previous destinationOffset:0 destinationBytesPerRow:r.row destinationBytesPerImage:r.row*h];
        }
        [blit endEncoding];vx_xros_vr_end_frame((__bridge void *)r.command);
        dispatch_semaphore_t done=r.done;[r.command addCompletedHandler:^(id<MTLCommandBuffer> c){(void)c;dispatch_semaphore_signal(done);}];
        if(f==6) held=r;else hash=(hash^finish_history_read(r))*1099511628211ULL;
        if(f==23) { hash=(hash^finish_history_read(held))*1099511628211ULL;held=nil; }
        lastW=w;lastH=h;lastFormat=format;lastFrame=f;
    } }
    assert(!held && g_history_copies==copies && g_history_skips==skips);
    assert(g_pipeline.admitted==48 && !g_pipeline.failed && !g_pipeline.capacity_drops);
    if(demand && !model) assert(copies==16 && skips==32);else assert(copies==48 && skips==0);
    char fields[2048];vx_xros_vr_stats(fields,sizeof fields);NSError *error=nil;
    NSData *raw=[[NSString stringWithFormat:@"{%s}",fields] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *stats=[NSJSONSerialization JSONObjectWithData:raw options:0 error:&error];assert(stats && !error);
    assert([stats[@"frame_pipeline"][@"history_copies"] unsignedIntValue]==copies);
    NSDictionary *result=@{@"status":@"complete",@"mode":@(argv[1]),@"interpolation_mode":@(model),@"images_verified":@48,@"history_copies":@(copies),@"history_skips":@(skips),@"color_checksum":[NSString stringWithFormat:@"%016llx",(unsigned long long)hash],@"scope":@"actual GPU copy/slot/reader tests; no game-FPS or latency measurement"};
    assert([[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:@(argv[3]) atomically:YES]);
    printf("history %s/interp%d: 48 GPU images, %u copied/%u skipped, checksum %016llx\n",argv[1],model,copies,skips,(unsigned long long)hash);
} }
