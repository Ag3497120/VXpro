// vxprof.h - libvxmtl's per-pass GPU profile (vxprof.m; VXMAC_PASS_PROFILE=1), between vxmtl.m / vxpipe.m and it.
// All of it does nothing unless the profile is on; vxprof_live is 1 only while a sampled frame is being encoded.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
extern int vxprof_live;
extern int vxprof_enabled;                                      // (1 once the profile is on)
void vxprof_end(id enc);                                        // (a render encoder's endEncoding, before the original)
int vxprof_on(void);
void vxprof_frame(void);                                        // (each present of the game's drawable)
void vxprof_install_cb_class(Class c);                          // (each command buffer class hooked)
void vxprof_install_encoders(Class render_cls, Class compute_cls);
MTLRenderPassDescriptor *vxprof_render_pd(id cb, MTLRenderPassDescriptor *pd, void **ctx, int parallel);   // (while live)
void vxprof_render_enc(id enc, void *ctx);                      // (ctx from vxprof_render_pd; NULL: nothing)
void vxprof_pipe(id enc, id pipeline);                          // (setRenderPipelineState:)
void vxprof_pipe_key(id pipeline, NSString *hash, char kind);   // (a pipeline made: 'f' / 'v' / 'k' and its function's library hash)
void vxprof_ours(int delta);                                     // (+1 / -1 around the host's hooks: what it encodes there is ours)
void vxprof_stats(char *out, unsigned n);                       // ("" when off)
