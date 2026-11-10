// SPDX-License-Identifier: MIT
// Exercise actual presenter handoff and bridge, including outstanding inputs.
#include "../app/Sources/weapon_bridge.h"
static vx_game_context control_context;
static vx_game_context control_context_fixture(void) {return control_context;}
#define vx_weapon_bridge_context control_context_fixture
#define main pipeline_cases
#include "presenter_pipeline_mac.m"
#undef main
#undef vx_weapon_bridge_context
#undef vx_xros_hand_key
#undef vx_xros_hand_button
#include "../vr/control_chord.h"
static int keys_down[256],buttons_down[8];
static unsigned downs,ups;
void vx_xros_hand_key(int key,int down) {assert(key>=0 && key<256);keys_down[key]=down;down?downs++:ups++;}
void vx_xros_hand_button(int button,int down) {assert(button>=0 && button<8);buttons_down[button]=down;down?downs++:ups++;}
void vx_xros_hand_pointer(double x,double y) {(void)x;(void)y;}
void vx_xros_hand_wheel(int delta) {(void)delta;}
void vxmac_request_quit(const char *why) {(void)why;assert(!"no quit requested by a mode switch");}
static void switch_to(int tracking) {vx_xros_vr_set_tracking(tracking);vx_xros_vr_input_poll();assert(vx_xros_vr_tracking_enabled()==tracking);}
int main(void) { @autoreleasepool {
    setenv("VXRT_VR_MODE","vr",1);setenv("VXMAC_GESTURES","0",1);setenv("VXMAC_ARMS","0",1);
    setenv("VXMAC_JOY_HOLD","1",1);setenv("VXMAC_MAG","0",1);setenv("VXRT_VR_ENGAGE","always",1);
    config();g_engaged=1;g_force=1;g_eff=2;g_poll_in=0;
    float before_head[16];memcpy(before_head,g_head,sizeof before_head);g_yaw_ref=23;g_pitch_ref=-4;g_ref_gen=77;
    assert(vx_xros_vr_tracking_enabled());
    tracked_key(0x85,1);tracked_key(0x15,1);tracked_button(0,1);tracked_button(1,1);
    assert(keys_down[0x85] && buttons_down[0] && buttons_down[1]);
    g_controller_buttons=HW_BTN_R_TRIG|HW_BTN_ACT_X;
    g_ik_weapon_owner=2;g_ik_mag_state=HW_HOLD_NEW;g_ik_slide_active=1;g_ik_time=CACurrentMediaTime();g_ik_weap[6]=2;
    g_vm_active=1;g_muzzle.steering=1;
    switch_to(0);
    for(int i=0;i<256;i++)assert(!keys_down[i]);for(int i=0;i<8;i++)assert(!buttons_down[i]);
    assert(!vx_weapon_bridge_tracking() && g_control_neutral && g_ik_mag_state==-1 && !g_ik_slide_active && !g_vm_active && !g_muzzle.steering);
    assert(g_yaw_ref==23 && g_pitch_ref==-4 && g_ref_gen==77 && !memcmp(before_head,g_head,sizeof before_head));
    float rendered[2][12],H[16];int ok[2]={1,1};unsigned epoch,wrists;
    assert(!vx_xros_vr_render_hands(rendered,ok,H,&epoch,&wrists) && !ok[0] && !ok[1]);
    unsigned prior=downs;tracked_button(0,1);tracked_key(0x85,1);assert(downs==prior);
    vx_xros_vr_controller_state(HW_BTN_R_TRIG,CACurrentMediaTime());assert(g_control_neutral);
    vx_xros_vr_controller_state(0,CACurrentMediaTime());assert(!g_control_neutral);
    control_context.script_revision=6;control_context.control_known=1;control_context.control_tracking=1;
    assert(vx_xros_vr_control_neutral_required()); // script still owns tracked reload
    control_context.control_tracking=0;assert(!vx_xros_vr_control_neutral_required());
    float hands[20]={0};vx_xros_vr_hands(head,hands,CACurrentMediaTime());assert(!g_ik_weapon_owner && !g_joy_fire_mask);
    vx_xros_vr_controller_state(HW_BTN_R_TRIG,CACurrentMediaTime());switch_to(1);
    control_context.control_tracking=1;
    g_joy_fire_mask=HW_BTN_R_TRIG;g_joy_fire_ready_at=CACurrentMediaTime();
    vx_xros_vr_controller_state(HW_BTN_R_TRIG,CACurrentMediaTime());assert(!buttons_down[0]);
    vx_xros_vr_controller_state(0,CACurrentMediaTime());vx_xros_vr_controller_state(HW_BTN_R_TRIG,CACurrentMediaTime());assert(buttons_down[0]);
    switch_to(0);assert(!buttons_down[0]);vx_xros_vr_controller_state(0,CACurrentMediaTime());
    control_context.script_revision=0;
    for(int i=0;i<32;i++) {switch_to(1);vx_xros_vr_hands(head,hands,CACurrentMediaTime());switch_to(0);}
    vx_control_chord chord={0};assert(!vx_control_chord_update(&chord,1,0,1));
    assert(!vx_control_chord_update(&chord,1,1,2));assert(!vx_control_chord_update(&chord,1,1,2.9));
    assert(vx_control_chord_update(&chord,1,1,3));assert(!vx_control_chord_update(&chord,1,1,10));
    assert(!vx_control_chord_update(&chord,1,0,11));assert(!vx_control_chord_update(&chord,1,1,12));assert(!vx_control_chord_update(&chord,1,1,14));
    assert(!vx_control_chord_update(&chord,0,0,15));assert(!vx_control_chord_update(&chord,1,1,16));assert(vx_control_chord_update(&chord,1,1,17));
    printf("control mode: live hand/controller switch, all synthetic releases incl custom key, trigger/face release barrier, inactive hands, head/reference invariance, 32 roundtrips, one-shot plus/minus chord: ok (%u downs/%u ups)\n",downs,ups);
} }
