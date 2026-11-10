// SPDX-License-Identifier: MIT
// Drive actual presenter submission/selection with a paused-menu event, including
// unfinished producer commands. Render the real screen shader and read it back.
#include "../app/Sources/weapon_bridge.h"
static vx_game_context context_fixture;
static vx_game_context menu_fixture_context(void) { return context_fixture; }
#define vx_weapon_bridge_context menu_fixture_context
#define main existing_presenter_cases
#include "presenter_pipeline_mac.m"
#undef main
#undef vx_weapon_bridge_context

static id<MTLTexture> fixture_depth;
static int take_menu_scene(void **mv, void **depth, uint32_t *c) {
    *mv=NULL; *depth=(void *)CFBridgingRetain(fixture_depth);memset(c,0,128);return 1;
}
static unsigned transitions;
static void event(const char *name,const char *fields) {
    (void)fields;if(!strcmp(name,"presentation_mode")) transitions++;
}
static void begin(int mode) {
    assert(vx_xros_vr_begin_frame(head,CACurrentMediaTime()+.01));
    assert(g_eff==mode && screen_now()==(mode==1) && vr_now()==(mode==2));
}
static void end(void) { vx_xros_vr_end_frame(NULL); }

static unsigned screen_pixels(id<MTLCommandQueue> queue) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:128 height:128 mipmapped:NO];
    d.usage=MTLTextureUsageRenderTarget;d.storageMode=MTLStorageModePrivate;
    id<MTLTexture> out=[queue.device newTextureWithDescriptor:d];assert(out);
    d.pixelFormat=MTLPixelFormatDepth32Float;id<MTLTexture> depth=[queue.device newTextureWithDescriptor:d];assert(depth);
    d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;
    id<MTLTexture> color=[queue.device newTextureWithDescriptor:d],hud=[queue.device newTextureWithDescriptor:d];
    uint8_t base[1024],ui[1024];
    for(int y=0;y<16;y++) for(int x=0;x<16;x++) {
        int i=(y*16+x)*4;base[i]=base[i+1]=0;base[i+2]=base[i+3]=255;
        ui[i]=(x>=4 && x<12 && y>=4 && y<12)?255:0;
        ui[i+1]=ui[i+2]=0;ui[i+3]=ui[i];
    }
    [color replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:base bytesPerRow:64];
    [hud replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:ui bytesPerRow:64];
    vr_slot slot={0};slot.view=color;slot.hud_view=hud;slot.has_hud=1;slot.w=slot.h=16;
    C.screen_m=2;C.screen_deg=60;place_screen(head);
    unsigned checked=0;
    for(int pass=0;pass<3;pass++) {
        float eye[16],view[16],tan[4]={1,1,1,1};memcpy(eye,head,sizeof eye);
        if(pass==1) eye[12]+=.12f; // world-locked plane and pointer must agree after head translation
        inv_rigid(eye,view);slot.has_hud=pass!=2;
        id<MTLCommandBuffer> cb=[queue commandBuffer];
        assert(draw_screen(cb,&slot,view,tan,.01,(__bridge void *)out,(__bridge void *)depth));
        // No second HUD/menu pass may draw over the screen.
        assert(!draw_hud_layer(cb,(__bridge void *)out,0,tan));
        id<MTLBuffer> data=[queue.device newBufferWithLength:128*512 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
        [blit copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(128,128,1) toBuffer:data destinationOffset:0 destinationBytesPerRow:512 destinationBytesPerImage:128*512];
        [blit endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted);
        const uint8_t *bytes=data.contents;
        for(int y=0;y<128;y++)for(int x=0;x<128;x++) {
            float direction[3]={(x+.5f)/64-1,1-(y+.5f)/64,-1},u,v;
            assert(screen_hit(eye+12,direction,&u,&v));
            const uint8_t *p=bytes+y*512+x*4;
            if(u<-.03 || u>1.03 || v<-.03 || v>1.03) { assert(p[0]==0 && p[1]==0 && p[2]==0);checked++; }
            else if(u>.36 && u<.64 && v>.36 && v<.64) {
                assert(p[0]==(pass==2?0:255) && p[1]==0 && p[2]==(pass==2?255:0));checked++;
            } else if(u>.06 && u<.16 && v>.4 && v<.6) { assert(p[0]==0 && p[1]==0 && p[2]==255);checked++; }
        }
    }
    return checked;
}
int main(int argc,char **argv) { @autoreleasepool {
    assert(argc==2);
    setenv("VXMAC_FRAME_PIPELINE","1",1);setenv("VXRT_VR_MODE","vr",1);
    setenv("VXRT_VR_ENGAGE","depth",1);setenv("VXMAC_FLOOR","0",1);
    setenv("VXMAC_GESTURES","0",1);setenv("VXMAC_ARMS","0",1);
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);
    id<MTLCommandQueue> producer=[device newCommandQueue],display=[device newCommandQueue];
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;
    id<MTLTexture> source=[device newTextureWithDescriptor:d];
    d.pixelFormat=MTLPixelFormatR32Float;fixture_depth=[device newTextureWithDescriptor:d];assert(fixture_depth);
    scene_fixture=take_menu_scene;context_fixture=(vx_game_context){.known=1,.menu_known=1,.sequence=1,.scene_tier=1};
    fixture_look=1;config();g_engaged=1;g_3d_last=CACurrentMediaTime();vx_host_jlog=event;
    submit(producer,source,1,NO);begin(2);end();
    context_fixture.menu_open=1;fixture_look=0;fixture_menu_cursor=1;
    fill(source,2);id<MTLCommandBuffer> pending=[producer commandBuffer];dispatch_semaphore_t ready=dispatch_semaphore_create(0);
    vx_xros_vr_submit((__bridge void *)pending,(__bridge void *)source,16,16,released,(__bridge void *)ready);
    begin(1);assert(g_slot[g_frame_slot].pseq==1);float plane[16];memcpy(plane,g_screen,sizeof plane);end();
    [pending commit];wait_signal(ready);begin(1);assert(g_slot[g_frame_slot].pseq==2);end();
    // Opening subpages and moving the head must not resize/re-anchor the screen.
    head[12]+=.08f;
    for(unsigned n=3;n<=8;n++) {
        g_3d_last-=10;submit(producer,source,n,NO);begin(1);
        assert(g_engaged && !memcmp(plane,g_screen,sizeof plane));end();
    }
    unsigned pixels=0;fixture_log=1;begin(1);pixels=screen_pixels(display);end();
    context_fixture.menu_open=0;fixture_look=1;fixture_menu_cursor=0;
    fill(source,9);pending=[producer commandBuffer];ready=dispatch_semaphore_create(0);
    vx_xros_vr_submit((__bridge void *)pending,(__bridge void *)source,16,16,released,(__bridge void *)ready);
    begin(1);assert(g_slot[g_frame_slot].pseq==8);end(); // UI still selected while close image is unfinished
    [pending commit];wait_signal(ready);begin(2);assert(g_slot[g_frame_slot].pseq==9);end();
    assert(g_engaged && transitions==3);
    // Cursor association is also used in scripted/vehicle gameplay. A known
    // closed-menu signal must keep those views on the existing VR route.
    fixture_menu_cursor=1;
    for(unsigned n=10;n<=11;n++) {
        context_fixture.sequence++;context_fixture.vehicle_mode=n==10?1:0;
        context_fixture.scene_tier=n==10?1:3;
        begin(2);end();submit(producer,source,n,NO);begin(2);end();
    }
    context_fixture.menu_known=0;
    begin(2);end(); // old bridge: never guess a story is a menu
    context_fixture.sequence++;context_fixture.scene_tier=1;begin(1);end(); // old bridge: cursor fallback on foot
    fixture_menu_cursor=0;begin(2);end();
    g_force=2;begin(1);end();g_force=0;begin(2);end();
    g_force=1;context_fixture.menu_known=1;context_fixture.menu_open=1;begin(1);end();
    context_fixture.menu_open=0;begin(2);end();g_force=0;
    for(int i=0;i<VXFP_SLOTS;i++)assert(!g_slot[i].writing && !g_slot[i].readers);
    NSDictionary *result=@{@"passed":@YES,@"device":device.name,@"pixel_assertions":@(pixels),@"menu_entry_exit_transitions":@3,
        @"in_flight_open_and_close":@YES,@"subpage_pose_stable":@YES,@"pointer_plane_matches_pixels":@YES,
        @"vehicle_story_preserved":@YES,@"game_visual_acceptance":@"not measured"};
    assert([[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:@(argv[1]) atomically:YES]);
    printf("menu transition: entry/exit, in-flight images, subpages, vehicle/story, %u GPU pixel assertions: ok\n",pixels);
} }
