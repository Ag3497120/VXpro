// SPDX-License-Identifier: MIT
#include "../vr/view_stability.h"
#include <assert.h>
#include <stdio.h>
static void delayed_camera(float response,int delay,int legacy) {
    double issued[2048]={0};
    float logical=0,max_tail=0;
    for(int f=1;f<1400;f++) {
        int source=f>delay ? f-delay : 0;
        float head=f<60 ? 0 : f<240 ? 20 : f<420 ? -15 : f<1000 ? 30*sinf((f-420)*.012f) : 0;
        // A slower mouse response and 30-degree vehicle camera offset are
        // independent of the tracking and correction implementation.
        float camera=30+response*(float)issued[source];
        // Several source frames may arrive before the next compositor/input
        // poll. Include scheduled, not yet emitted correction as well.
        for(int poll=0;poll<3;poll++) {
            float pending=(float)(issued[f-1]-issued[source])+head-logical;
            logical-=vx_view_camera_correction(head-camera,legacy ? 0 : pending);
        }
        issued[f]=issued[f-1]+head-logical;
        logical=head;
        if(f>1200)max_tail=fmaxf(max_tail,fabsf(camera));
    }
    if(!legacy) assert(max_tail<.65f);
    // The former loop re-issued the full correction while its previous events
    // were still travelling through the pipeline; at eight frames it oscillated.
    else assert(max_tail>5.f);
}
int main(void) {
    assert(vx_view_vehicle_look(1,0,1,1,0,0));
    assert(vx_view_vehicle_look(1,0,1,3,0,0));
    assert(!vx_view_vehicle_look(0,0,1,1,0,0));
    assert(!vx_view_vehicle_look(1,1,1,1,0,0)); // an orbit must not take head pitch as camera-height input
    assert(!vx_view_vehicle_look(1,0,0,1,0,0)); // cursor free-look alone is not axis capability
    assert(!vx_view_vehicle_look(1,0,1,6,0,0)); // preserve native driver combat
    assert(!vx_view_vehicle_look(1,0,1,1,1,0));
    assert(!vx_view_vehicle_look(1,0,1,1,0,1));
    assert(vx_view_camera_correction(12,12)==0);
    assert(vx_view_camera_correction(-20,-20)==0);
    assert(vx_view_camera_correction(20,0)==3);
    assert(vx_view_camera_correction(NAN,0)==0);
    for(int delay=1;delay<=8;delay++)for(int gain=5;gain<=15;gain+=5)delayed_camera(gain*.1f,delay,0);
    delayed_camera(1,8,1);
    assert(vx_view_native_camera(10,9.9));
    assert(!vx_view_native_camera(10,9.5) && !vx_view_native_camera(10,10.1));
    assert(!vx_view_predict_translation(0,0)); // a head-only turn never invents player movement
    assert(vx_view_predict_translation(1,0)); // keep prediction for commanded walking
    assert(!vx_view_predict_translation(1,1)); // native vehicle/story motion stays anchored
    vx_view_context special={.known=1,.scene=1};
    assert(vx_view_scene_world(1,1,0,&special,1,0));
    assert(!vx_view_scene_world(1,0,0,&special,1,0)); // title/creator before first play
    assert(!vx_view_scene_world(0,1,0,&special,1,0)); // flat video/loading
    assert(!vx_view_scene_world(1,1,0,&special,1,1)); // actual paused menu
    assert(!vx_view_scene_world(1,1,0,&special,0,0)); // old overlay: no guessed menu verdict
    vx_view_context walking={.known=1};
    assert(!vx_view_scene_world(1,1,0,&walking,1,0)); // normal VR keeps its existing gate
    assert(vx_view_scene_world(1,0,1,&special,1,0)); // direct load into a live story scene
    special.scene=0;special.vehicle=1;
    assert(vx_view_scene_world(1,1,0,&special,1,0));
    // A physical turn and a delayed/uneven game response cannot drag the room
    // heading; joystick motion must still use the rendered heading immediately.
    float offset=17.f;
    for(int frame=0;frame<900;frame++) {
        float target=vx_view_wrap(17.f+40.f*sinf(frame*.017f));
        offset=vx_view_heading_offset(offset,target,1./30,0,1,.6f);
        assert(offset==17.f);
    }
    assert(vx_view_heading_offset(17.f,-179.f,1./30,1,1,.6f)==-179.f);
    assert(fabsf(vx_view_wrap(vx_view_heading_offset(179.f,-179.f,1./30,0,0,.6f)-179.f))<.2f);
    // A 70-degree native vehicle turn with a stationary head belongs to the
    // controller/world, not the source image's position in the eye. The old
    // right-stick-only signal leaves a 70-degree source/eye mismatch here.
    float driving=17.f,legacy=17.f;
    for(int frame=1;frame<=180;frame++) {
        float native=17.f+70.f*(float)frame/180.f;
        int turn=vx_view_turn_input(0,0,.8f,1);
        driving=vx_view_heading_offset(driving,native,1./30,turn,1,.6f);
        legacy=vx_view_heading_offset(legacy,native,1./30,0,1,.6f);
        assert(fabsf(vx_view_wrap(native-driving))<1e-5f);
    }
    assert(fabsf(vx_view_wrap(87.f-legacy))>69.f);
    // Walking/strafe alone still cannot move the room zero during head turns.
    for(int frame=0;frame<100;frame++) {
        int turn=vx_view_turn_input(0,0,.8f,0);assert(!turn);
        assert(vx_view_heading_offset(17.f,30.f+sinf(frame*.1f),1./30,turn,1,.6f)==17.f);
    }
    assert(vx_view_turn_input(.8f,0,0,0) && vx_view_turn_input(0,-.8f,0,0));
    assert(!vx_view_turn_input(.1f,-.1f,.1f,1));
    vx_view_context s={0};
    assert(!vx_view_context_update(&s,1,0,0,1) && s.known && !s.scene);
    assert(vx_view_context_update(&s,2,0,0,3) && s.scene);
    // Re-reading a timed-out heartbeat and receiving no new notification are
    // not evidence that the player left the conversation.
    for(int i=0;i<100;i++)assert(!vx_view_context_update(&s,2,0,0,0) && s.scene);
    assert(!vx_view_context_update(&s,0,0,0,0) && s.scene);
    assert(vx_view_context_update(&s,3,1,1,1) && s.vehicle && !s.scene);
    assert(!vx_view_context_update(&s,3,0,0,1) && s.vehicle);
    assert(vx_view_context_update(&s,4,0,0,1) && !s.vehicle);
    for(int y=-80;y<=80;y+=20)for(int p=-60;p<=60;p+=20)for(int r=-40;r<=40;r+=20) {
        float a=y*.01745329252f,b=p*.01745329252f,t=r*.01745329252f;
        float cy=cosf(a),sy=sinf(a),cp=cosf(b),sp=sinf(b);
        float m[16]={cy,0,-sy,0,sy*sp,cp,cy*sp,0,sy*cp,-sp,cy*cp,0,.2f,1.6f,-.3f,1};
        float before[16];memcpy(before,m,sizeof m);vx_view_roll(m,t);
        for(int i=12;i<16;i++)assert(m[i]==before[i]);
        float angle=0;for(int k=0;k<3;k++)angle+=m[k]*before[4+k];
        assert(fabsf(angle-sinf(t))<1e-5f);
        // Build the native camera independently in Z-up game space. A world
        // point reprojected via the reconstructed camera must keep the same
        // direction, including steep slopes and a rolled vehicle camera.
        float right[3]={sy*cosf(t)-sp*cy*sinf(t),-cy*cosf(t)-sp*sy*sinf(t),cp*sinf(t)};
        float up[3]={-sp*cy*cosf(t)-sy*sinf(t),-sp*sy*cosf(t)+cy*sinf(t),cp*cosf(t)};
        float forward[3]={cp*cy,cp*sy,sp};
        float native[9]={-right[1],right[2],-right[0],-up[1],up[2],-up[0],forward[1],-forward[2],forward[0]};
        for(int col=0;col<3;col++)for(int k=0;k<3;k++)assert(fabsf(m[col*4+k]-native[col*3+k])<1e-5f);
        assert(fabsf(atan2f(right[2],up[2])-t)<1e-5f);
        float world[3]={.3f,.7f,-4.f}, projected[3]={0}, restored[3]={0};
        for(int i=0;i<3;i++)for(int k=0;k<3;k++)projected[i]+=native[3*i+k]*world[k];
        for(int k=0;k<3;k++)for(int i=0;i<3;i++)restored[k]+=m[4*i+k]*projected[i];
        for(int k=0;k<3;k++)assert(fabsf(restored[k]-world[k])<1e-5f);
        vx_view_roll(m,-t);
        for(int i=0;i<12;i++)assert(fabsf(m[i]-before[i])<1e-5f);
    }
    puts("view stability: scoped scene/menu guards, stale heartbeats, physical versus stick/vehicle steering heading, 24 delayed camera response trials, 315 native-camera world-point projections: ok");
}
