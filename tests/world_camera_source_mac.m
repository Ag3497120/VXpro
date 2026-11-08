// SPDX-License-Identifier: MIT
// Exercise the production camera hooks with real Metal buffers. Shadow and
// foreground cameras must not replace the world's view or borrow its lens.
#include "../shims/vxpipe.m"
#include <assert.h>

void vxmac_log(const char *format, ...) { (void)format; }
void vxmtl_enc_stats(char *out, unsigned n) { if (n) out[0]=0; }
void vxmtl_ui_pipe_add(void *p) { (void)p; }
void vxmtl_ui_pipe_set(id e,id p) { (void)e;(void)p; }
id vxmtl_command_buffer_for_encoder(id e) { (void)e;return nil; }
int vxmtl_retain_for_encoder(id e,id r) { (void)e;(void)r;return 0; }
int vxprof_live;
int vxprof_on(void) { return 0; }
void vxprof_pipe(id e,id p) { (void)e;(void)p; }
void vxprof_pipe_key(id p,NSString *hash,char kind,NSString *name) { (void)p;(void)hash;(void)kind;(void)name; }
static void binding(id e,SEL s,id b,NSUInteger off,NSUInteger i) { (void)e;(void)s;(void)b;(void)off;(void)i; }

int main(void) { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);
    id<MTLCommandQueue> queue=[device newCommandQueue];assert(queue);
    id<MTLBuffer> view=[device newBufferWithLength:512 options:MTLResourceStorageModeShared];
    id<MTLBuffer> table=[device newBufferWithLength:64 options:MTLResourceStorageModeShared];
    id<MTLBuffer> top=[device newBufferWithLength:64 options:MTLResourceStorageModeShared];
    assert(view && table && top);
    uint64_t address=view.gpuAddress;memcpy((uint8_t *)table.contents+24,&address,8);
    address=table.gpuAddress;memcpy(top.contents,&address,8);
    vxpipe_buf_add(view);vxpipe_buf_add(table);vxpipe_buf_add(top);o_svb2=binding;
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1280 height:720 mipmapped:NO];
    td.usage=MTLTextureUsageRenderTarget;
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    for(int i=0;i<3;i++)pass.colorAttachments[i].texture=[device newTextureWithDescriptor:td];
    td.pixelFormat=MTLPixelFormatDepth32Float;pass.depthAttachment.texture=[device newTextureWithDescriptor:td];
    pass.depthAttachment.loadAction=MTLLoadActionClear;
    float projection[16]={.7f,0,0,0,0,1.2f,0,0,0,0,0,.02f,0,0,1,0};
    float pose[16]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1},captured[16];
    memcpy((uint8_t *)view.contents+128,projection,64);memcpy((uint8_t *)view.contents+320,pose,64);
    id command=[queue commandBuffer],encoder=[NSObject new];
    vxpipe_frame();vxpipe_render_begin(encoder,pass,command);
    tl_note(encoder,0,top,0,2,NULL,0,0);vxpipe_render_end(encoder);
    uint64_t sequence=vxmtl_game_camera(captured);assert(sequence && !memcmp(pose,captured,64));
    float tx,ty;assert(vxmtl_game_tan(&tx,&ty) && fabsf(tx-1/.7f)<1e-6f);
    vxpipe_enc_clear(encoder);
    // Orthographic shadow and missing/NaN projection each have a valid view
    // basis. The old parser accepted these and reused the previous world lens.
    for(int kind=0;kind<3;kind++) {
        float bad[16]={0};if(kind==0)bad[0]=bad[5]=bad[10]=bad[15]=1;
        if(kind==2){memcpy(bad,projection,sizeof bad);bad[14]=NAN;}
        memcpy((uint8_t *)view.contents+128,bad,64);pose[10]=-1;pose[5]=-1;
        memcpy((uint8_t *)view.contents+320,pose,64);
        command=[queue commandBuffer];vxpipe_frame();vxpipe_render_begin(encoder,pass,command);
        tl_note(encoder,0,top,0,2,NULL,0,0);vxpipe_render_end(encoder);
        if(vxmtl_game_camera(captured)!=sequence){fprintf(stderr,"non-world projection %d replaced world camera\n",kind);return 1;}
        assert(!vx_frame_camera_read(command,NULL,NULL,NULL));vxpipe_enc_clear(encoder);
    }
    // A long foreground-only interval must not activate the old zero-lens
    // fallback, even though its own perspective and view are valid.
    memcpy((uint8_t *)view.contents+128,projection,64);
    for(int i=0;i<6;i++) {
        command=[queue commandBuffer];vxpipe_frame();vxpipe_render_begin(encoder,pass,command);
        VXEncVM *vm=objc_getAssociatedObject(encoder,kEncVM);assert(vm);vm->had_fg=1;
        tl_note(encoder,0,top,0,2,NULL,0,0);vxpipe_render_end(encoder);
        assert(vxmtl_game_camera(captured)==sequence);vxpipe_enc_clear(encoder);
    }
    // A real perspective pointing straight down remains valid. Validity comes
    // from the projection, never an arbitrary head-angle clamp.
    command=[queue commandBuffer];vxpipe_frame();vxpipe_render_begin(encoder,pass,command);
    tl_note(encoder,0,top,0,2,NULL,0,0);vxpipe_render_end(encoder);
    assert(vxmtl_game_camera(captured)>sequence && !memcmp(pose,captured,64));vxpipe_enc_clear(encoder);
    puts("world camera source: real pass/binding capture, shadow/missing/NaN rejection, foreground starvation isolation, valid downward perspective: ok");
} }
