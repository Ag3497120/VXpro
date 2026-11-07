// SPDX-License-Identifier: MIT
#pragma once
#include <math.h>
#include <string.h>
// A stale notification is not an exit from a vehicle or conversation.
typedef struct { unsigned long long sequence; int known,vehicle,scene; } vx_view_context;
static inline int vx_view_context_update(vx_view_context *s,unsigned long long sequence,int mounted,int vehicle,int tier) {
    if(!sequence || sequence<=s->sequence) return 0;
    int v=mounted || vehicle!=0, c=tier>=2 && tier<=5;
    int changed=s->known && (v!=s->vehicle || c!=s->scene);
    s->sequence=sequence;s->known=1;s->vehicle=v;s->scene=c;
    return changed;
}
// This exception must never admit a title screen or character creator. It
// requires a play view (or a live player report) and the game's real menu signal.
static inline int vx_view_scene_world(int world3d,int played,int live_player,const vx_view_context *c,int menu_known,int menu_open) {
    return world3d && (played || live_player) && c->known && (c->vehicle || c->scene) && menu_known && !menu_open;
}
static inline float vx_view_wrap(float a) { return a-360.f*floorf((a+180.f)/360.f); }
static inline int vx_view_native_camera(double now,double sample) { return sample>0 && now>=sample && now-sample<.25; }
static inline int vx_view_predict_translation(int walking,int constrained) { return walking && !constrained; }
static inline int vx_view_vehicle_look(int known,int perspective,int pitch_ready,int mode,int scene,int menu) {
    return known && perspective==0 && pitch_ready && (mode==1 || mode==3) && !scene && !menu;
}
static inline float vx_view_heading_offset(float offset,float target,double dt,int stick,int free_look,float tau) {
    if(stick) return target;
    // The captured camera already contains the head input. Moving this room
    // reference as well makes stationary scenery drift during a physical turn.
    if(free_look) return offset;
    if(fabsf(vx_view_wrap(target-offset))>1.5f && dt>0)
        offset=vx_view_wrap(offset+vx_view_wrap(target-offset)*(float)(1-exp(-dt/fmaxf(.01f,tau))));
    float d=vx_view_wrap(target-offset);
    if(fabsf(d)>25.f) offset=vx_view_wrap(target-copysignf(25.f,d));
    return offset;
}
// Account for real mouse deltas already issued after the source frame's input.
// The logical head angle is insufficient: feedback changes its zero without
// retaining the extra mouse movement, so it can repeatedly correct an old error.
static inline float vx_view_camera_correction(float error,float pending) {
    if(!isfinite(error) || !isfinite(pending)) return 0;
    float remaining=error-pending;
    return fabsf(remaining)>.3f ? fmaxf(-3.f,fminf(3.f,.25f*remaining)) : 0;
}
// Apply the rendered camera's roll too; dropping it changes the apparent
// horizon as a head turns across an inclined camera (vehicles and slopes).
static inline void vx_view_roll(float pose[16],float radians) {
    float r[3],u[3],c=cosf(radians),s=sinf(radians);
    memcpy(r,pose,sizeof r);memcpy(u,pose+4,sizeof u);
    for(int i=0;i<3;i++) { pose[i]=r[i]*c+u[i]*s;pose[4+i]=u[i]*c-r[i]*s; }
}
