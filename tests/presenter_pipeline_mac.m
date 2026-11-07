// SPDX-License-Identifier: MIT
// Includes the actual presenter. Only its surrounding platform/game inputs are
// stubbed; no copied implementation of slot submission, selection or release.
#import <Metal/Metal.h>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdarg.h>
#include "../vr/xros_vr.m"

void (*vx_host_jlog)(const char *, const char *);
int vx_xros_display_w = 16, vx_xros_display_h = 16;
void vx_log(const char *fmt, ...) { (void)fmt; }
void vx_xros_pace_tick(void) {}
void vx_input_chords_poll(void) {}
int vx_game_mouse_look(void) { return 0; }
unsigned long vx_head_consumed(void) { return 0; }
int vxmtl_game_tan(float *x, float *y) { (void)x; (void)y; return 0; }
int vxmac_combat_input(void) { return 0; }
int vxmac_stick_active(void) { return 0; }
void vx_raw_mouse(int dx, int dy, uint16_t buttons, int16_t wheel) { (void)dx; (void)dy; (void)buttons; (void)wheel; }
void *vxmac_vel_latest_tex(uint32_t *w, uint32_t *h, float k[2], float *corr, int *verified) {
    *w=*h=0; k[0]=k[1]=0; *corr=0; *verified=0; return NULL;
}
uint64_t vxmtl_game_camera(float m[16]) { memset(m,0,64); return 0; }
void vxmtl_ui_half(int half) { (void)half; }
void vxmtl_warp_begin(void) {}
void vxmtl_warp_end(void) {}
void vxmtl_warp_track(void *cb) { (void)cb; }
static int (*scene_fixture)(void **, void **, uint32_t *);
int npu_interp_take_scene(void **mv, void **depth, uint32_t c[32]) {
    if (scene_fixture) return scene_fixture(mv,depth,c);
    (void)mv; (void)depth; memset(c,0,128); return 0;
}
int npu_fsr2_parse(const uint32_t *c, float *ty, float z[4], float mv[2], uint32_t size[2]) {
    (void)c; (void)ty; (void)z; (void)mv; (void)size; return 0;
}

// A real GPU completion is delivered with a failed status to exercise the
// presenter's error path without submitting invalid commands to the GPU.
@interface VXFailedStatus : NSObject
@end
@implementation VXFailedStatus
- (MTLCommandBufferStatus)status { return MTLCommandBufferStatusError; }
@end
@interface VXFailedCommand : NSProxy
@property id<MTLCommandBuffer> real;
@end
@implementation VXFailedCommand
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [(id)self.real methodSignatureForSelector:s]; }
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:self.real]; }
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler {
    [self.real addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)done; handler((id)[VXFailedStatus new]); }];
}
@end

static unsigned release_count, readbacks;
static void released(void *arg) {
    release_count++;
    dispatch_semaphore_signal((__bridge dispatch_semaphore_t)arg);
}
static void wait_signal(dispatch_semaphore_t signal) {
    assert(dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0);
}
static float head[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, .1f,0,0,1};
static void fill(id<MTLTexture> texture, uint32_t seq) {
    uint32_t pixels[256];
    for (int i=0;i<256;i++) pixels[i]=0xff000000u|seq;
    [texture replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:pixels bytesPerRow:64];
}
static void submit(id<MTLCommandQueue> queue, id<MTLTexture> source, uint32_t seq, BOOL fail) {
    fill(source, seq);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLCommandBuffer> submitCommand = command;
    if (fail) { VXFailedCommand *proxy = [VXFailedCommand alloc]; proxy.real = command; submitCommand=(id)proxy; }
    vx_xros_vr_submit((__bridge void *)submitCommand, (__bridge void *)source, 16, 16, released, (__bridge void *)done);
    [command commit]; wait_signal(done);
    assert(command.status == MTLCommandBufferStatusCompleted);
}

@interface VXReader : NSObject
@property id<MTLCommandBuffer> command;
@property id<MTLBuffer> data;
@property dispatch_semaphore_t done;
@property uint32_t expected;
@end
@implementation VXReader
@end
static VXReader *reader(id<MTLCommandQueue> queue, uint32_t expected) {
    assert(vx_xros_vr_begin_frame(head, CACurrentMediaTime()+.01));
    assert(g_frame_slot >= 0 && g_slot[g_frame_slot].pseq == expected);
    VXReader *r=[VXReader new]; r.expected=expected; r.done=dispatch_semaphore_create(0);
    r.command=[queue commandBuffer]; r.data=[queue.device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit=[r.command blitCommandEncoder];
    [blit copyFromTexture:g_slot[g_frame_slot].color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
              sourceSize:MTLSizeMake(16,16,1) toBuffer:r.data destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:4096];
    [blit endEncoding];
    vx_xros_vr_end_frame((__bridge void *)r.command);
    dispatch_semaphore_t signal=r.done;
    [r.command addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; dispatch_semaphore_signal(signal); }];
    return r;
}
static void finish_reader(VXReader *r) {
    [r.command commit]; wait_signal(r.done);
    assert(r.command.status == MTLCommandBufferStatusCompleted);
    const uint8_t *bytes=r.data.contents;
    for (int y=0;y<16;y++) for (int x=0;x<16;x++) assert(((const uint32_t *)(bytes+y*256))[x] == (0xff000000u|r.expected));
    readbacks++;
}
static NSDictionary *probe(BOOL enabled) { @autoreleasepool {
    setenv("VXMAC_FRAME_PIPELINE",enabled?"1":"0",1);
    setenv("VXRT_VR_MODE","head",1); setenv("VXMAC_FLOOR","0",1);
    id<MTLDevice> device=MTLCreateSystemDefaultDevice(); assert(device);
    id<MTLCommandQueue> producer=[device newCommandQueue], display=[device newCommandQueue];
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> source=[device newTextureWithDescriptor:d]; assert(source);
    // The actual GPU copy has been encoded, but not committed: it must not show.
    fill(source,1); id<MTLCommandBuffer> first=[producer commandBuffer];
    dispatch_semaphore_t copied=dispatch_semaphore_create(0);
    vx_xros_vr_submit((__bridge void *)first,(__bridge void *)source,16,16,released,(__bridge void *)copied);
    assert(!vx_xros_vr_begin_frame(head,CACurrentMediaTime()+.01)); vx_xros_vr_end_frame(NULL);
    [first commit]; wait_signal(copied);
    assert(g_pipeline_on==enabled);
    VXReader *held=reader(display,1); // Leave an actual GPU reader uncommitted.
    submit(producer,source,2,NO);
    assert(vx_xros_vr_begin_frame(head,CACurrentMediaTime()+.01)); vx_xros_vr_end_frame(NULL); // Cancellation releases exactly once.
    vx_xros_vr_end_frame(NULL);
    submit(producer,source,3,NO);
    submit(producer,source,4,NO); // #2 held, #3 newest, #1 still read: the fourth image needs its own storage.
    assert(g_present_seq==4);
    if (enabled) assert(g_pipeline.capacity_drops==(VXFP_SLOTS==3 ? 1 : 0));
    finish_reader(held); // Must still contain #1, never an overwritten newer image.
    submit(producer,source,5,NO);
    finish_reader(reader(display,5));
    __strong id<MTLTexture> colors[VXFP_SLOTS], previous[VXFP_SLOTS];
    for (int i=0;i<VXFP_SLOTS;i++) { colors[i]=g_slot[i].color; previous[i]=g_slot[i].prev; assert(colors[i] && previous[i]); }
    for (uint32_t n=6;n<=100;n++) { @autoreleasepool {
        submit(producer,source,n,NO); finish_reader(reader(display,n));
        for (int i=0;i<VXFP_SLOTS;i++) assert(g_slot[i].color==colors[i] && g_slot[i].prev==previous[i]);
    }}
    if (enabled) {
        submit(producer,source,101,YES);
        assert(g_pipeline.failed==1);
        finish_reader(reader(display,100)); // A failed completion never replaces the last good image.
        VXReader *readers[VXFP_READERS];
        for (int i=0;i<VXFP_READERS;i++) readers[i]=reader(display,100);
        assert(!vx_xros_vr_begin_frame(head,CACurrentMediaTime()+.01)); vx_xros_vr_end_frame(NULL);
        for (int i=0;i<VXFP_READERS;i++) finish_reader(readers[i]);
        assert(!g_pipeline.rejected_callbacks && g_pipeline.delay_s==0);
        for (int i=0;i<VXFP_SLOTS;i++) assert(!g_pipeline.slots[i].readers);
    }
    for (int i=0;i<VXFP_SLOTS;i++) assert(!g_slot[i].writing && !g_slot[i].readers);
    char fields[6144]; vx_xros_vr_stats(fields,sizeof fields);
    NSString *text=[NSString stringWithFormat:@"{%s}",fields];
    NSDictionary *stats=[NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL]; assert(stats);
    if (enabled) assert([stats[@"frame_pipeline"][@"failed"] unsignedLongLongValue]==1);
    return @{@"version":@"actual-presenter-ownership-v1",@"passed":@YES,@"pipeline_enabled":@(enabled),@"device":device.name,@"readbacks":@(readbacks),
        @"release_callbacks":@(release_count),@"original_textures_reused":@YES,@"game_fps_measurement":@NO,
        @"real_display_measurement":@NO,@"platform_inputs_stubbed":@YES,@"stats":stats};
}}
NSString *vx_presenter_pipeline_app(void) {
    NSDictionary *result=probe(YES);
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
    NSURL *directory=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSError *error=nil;
    if (![json writeToURL:[directory URLByAppendingPathComponent:@"presenter-pipeline-result-v1.json"] options:NSDataWritingAtomic error:&error]) return error.localizedDescription;
    return @"ゲーム側と同じ画像保存・選択・解放処理の検査が完了しました。ゲームのFPS・実表示は未測定です。";
}
#ifndef VXMAC_PRESENTER_APP
int main(int argc, char **argv) { @autoreleasepool {
    assert(argc==3);
    BOOL enabled=!strcmp(argv[1],"on");
    NSDictionary *result=probe(enabled);
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
    assert([json writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES]);
    printf("actual presenter pipeline %s: %u GPU readbacks, original images reused, cancellation/pressure/status checks: ok\n",enabled?"on":"off",readbacks);
    return 0;
}}
#endif
