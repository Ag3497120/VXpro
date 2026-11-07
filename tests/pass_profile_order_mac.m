// SPDX-License-Identifier: MIT
#include <assert.h>
#include "../shims/vxprof.m"
void vxmac_log(const char *format, ...) { (void)format; }
static VXPFrame *frame(unsigned window, unsigned index) {
    VXPFrame *f = [VXPFrame new]; f->window=window; f->frame=index; f->driving=1;
    f->nrec=1; f->t_cpu=100+window+index*.01;
    f->recs[0].kind='C'; f->recs[0].dispatches=1;
    f->recs[0].t[0]=(window*100+index*2+1)*1000000ULL;
    f->recs[0].t[1]=f->recs[0].t[0]+1000000;
    return f;
}
int main(int argc, char **argv) { @autoreleasepool {
    g_on=1;
    id pa=[NSObject new], pb=[NSObject new], pa2=[NSObject new];
    vxprof_pipe_key(pa,nil,'k',@"cs_a"); vxprof_pipe_key(pb,nil,'k',@"cs_b"); vxprof_pipe_key(pa2,nil,'k',@"cs_a");
    VXPKey *ka=objc_getAssociatedObject(pa,kKey), *kb=objc_getAssociatedObject(pb,kKey), *ka2=objc_getAssociatedObject(pa2,kKey);
    assert(ka->kind=='K' && ka->h && kb->h && ka->h!=kb->h && ka->h==ka2->h);
    assert(g_function_names.count==2);
    vxprof_pipe_key(pa,@"1234",'k',@"cs_a"); ka=objc_getAssociatedObject(pa,kKey);
    assert(ka->kind=='k' && ka->h==0x1234); // Real library identity is preserved.
    // Unwritten counter slots can retain a previous frame's complete pair. A valid-looking duration
    // does not make that pair current. Bounds must belong to this record's command buffer.
    prec r = {0}; r.kind='R';
    r.t[0]=10001000000ULL; r.t[1]=10002000000ULL; // Current vertex stage.
    r.t[2]=4001000000ULL; r.t[3]=4002000000ULL;  // Stale fragment stage.
    validate_timing(&r,10,10.01);
    assert(r.timing_valid==1 && r.timing_omitted==2 && !r.timing_bad);
    assert(!r.t[2] && !r.t[3]);
    r.npipes=1; r.pipes[0].kind='F'; r.t[2]=4001000000ULL; r.t[3]=4002000000ULL;
    validate_timing(&r,10,10.01);
    assert(r.timing_bad==2 && !r.timing_omitted);
    r.kind='C'; r.dispatches=1; r.t[0]=10002000000ULL; r.t[1]=10001000000ULL;
    validate_timing(&r,10,10.01); assert(r.timing_bad==1 && !r.t[0]);
    r.t[0]=10001000000ULL; r.t[1]=10002000000ULL;
    validate_timing(&r,0,0); assert(r.timing_bad==1);
    r.t[0]=10001000000ULL; r.t[1]=10002000000ULL;
    validate_timing(&r,10,10.01); assert(r.timing_valid==1 && !r.timing_bad);
    assert(argc==2); g_frames=3; g_max_windows=4;
    g_f=fopen(argv[1],"w"); assert(g_f);
    // The last frame arriving first must not publish a partial window.
    assert(collect_window_frame(frame(1,2)));
    assert(collect_window_frame(frame(1,0)));
    assert(!g_finished_windows.count && !g_st_frames);
    // Another window can finish first, without splitting the first one.
    assert(collect_window_frame(frame(2,1)));
    assert(collect_window_frame(frame(2,2)));
    assert(collect_window_frame(frame(2,0)));
    assert(g_finished_windows.count==1 && g_st_frames==2);
    assert(collect_window_frame(frame(1,1)));
    assert(g_finished_windows.count==2 && g_st_frames==4 && !g_ready_windows.count);
    assert(!collect_window_frame(frame(1,1))); // No second aggregation.
    assert(!collect_window_frame(frame(3,3))); // Out of range.
    assert(g_st_frames==4);
    fclose(g_f); g_f=NULL;
    puts("pass profile: stale/invalid samples rejected; reversed completions produce complete, unique sweeps: ok");
    return 0;
}}
