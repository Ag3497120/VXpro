// The immersive presenter on Vision Pro (src/xros_vr.m; VISIONOS_PORT.md, "VR presentation"). A flat game's D3D12
// swap chain shown in an ImmersiveSpace through CompositorServices instead of a window: each present's picture (and
// the frame's depth and motion vectors when the D3D12 layer finds them) goes into one of three slots with the head pose
// it is shown from; the app's compositor loop (xros/app, VXImmersive.swift) warps the newest slot into each eye on
// every compositor frame (src/warp_core.h: one warp per eye with the eye's real pose and frustum, the game's depth
// giving the stereo and the head-rotation reprojection, its motion vectors the NPU race's predictions to the frame's
// display time) and writes depth for the system's own late reprojection. The game's rate is its own; Present's pacing
// comes from the compositor's frames.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The app turns it on before the program starts (launch argument -present vr, the default); 0: the flat window.
void vx_xros_vr_enable(int on);
int vx_xros_vr_on(void);

// ---- the game's side (src/d3d12.m) ----
// A render pass with a depth attachment ended (cb: its command buffer): as stereo.h's vx_stereo_depth_pass.
void vx_xros_vr_depth_pass(void *cb, void *depth_texture, uint32_t draws, uint32_t writes, uint32_t funcs);
// A present: the back buffer's top-left w x h (and this frame's depth or scene) copied into a slot in cb, which the
// caller commits; waitable_release (or NULL) is called with arg once the GPU has copied it.
void vx_xros_vr_submit(void *cb, void *back, uint32_t w, uint32_t h, void (*waitable_release)(void *), void *arg);

// ---- the compositor loop's side (the app) ----
// Each compositor frame, first: the head's pose for this frame (origin from device, column-major 4x4, ARKit's
// right-up-back axes) and its predicted presentation time (CACurrentMediaTime's clock). Also the tick that paces
// sync-interval presents (src/xros_ui.m). Returns 1 when a game frame is there to show.
int vx_xros_vr_begin_frame(const float origin_from_device[16], double presentation_time);
// Set this drawable's head-from-eye transforms before drawing either eye.
// NULL / a non-stereo drawable clears the pair for this frame.
void vx_xros_vr_set_eye_views(const float left[16], const float right[16]);
int vx_xros_vr_system_stereo(void);
// One eye: the warp of the frame into out (the drawable's colour texture for that view) and out_depth (its depth
// texture), encoded in cb. view_from_origin: the eye's view matrix (inverse of origin-from-device x the view's
// transform), tan: the eye's frustum tangents (left, right, top, bottom, all positive outwards), near_m: the near
// plane the drawable's depth range says (reversed infinite depth: near / distance). 0: nothing encoded (no frame yet).
int vx_xros_vr_draw_eye(void *cb, int eye, const float view_from_origin[16], const float tan[4], float near_m, void *out, void *out_depth);
// (VX Mac) The eye's rasterization rate map (foveation), before each vx_xros_vr_draw_eye, or NULL.
void vx_xros_vr_set_rate_map(void *map);
// (VX Mac) The number the next vx_xros_vr_submit will carry (the SR detail made from that present matches it).
uint64_t vx_xros_vr_next_seq(void);
// Screen mode (VXRT_VR_MODE=screen, the default): the screen placed again ahead of the head at the next frame.
void vx_xros_vr_recenter(void);
// vr mode (VXRT_VR_MODE=vr): on or off at run time (off: screen), and its mouse counts a degree scaled.
void vx_xros_vr_toggle_vr(void);
void vx_xros_vr_sensitivity(float factor);
// Each compositor frame after vx_xros_vr_begin_frame, with hand tracking: per hand (left, right) 10 floats in the
// room's frame (tracked 0/1, the thumb's tip, the index finger's tip, the pointing anchor), the head as above, now in
// seconds (VXRT_HAND, xros_vr.m: the pointer on the screen, pinches as clicks, drags and the wheel).
void vx_xros_vr_hands(const float head[16], const float hands[20], double now);
// (VX Mac, h70) Just before vx_xros_vr_hands: per hand (left, right) 25 floats - tracked, then the wrist, the index,
// middle and little fingers' knuckles, the middle, ring, little and index fingers' tips (vr/hand_weapon.h HW_JOINTS) -
// for the gun handled by hand (VXMAC_MAG=1, VXMAC_ARMS=1).
void vx_xros_vr_hand_joints(const float joints[50]);
void vx_xros_vr_hand_skeleton(const float skel[134]);
// Each tracked wrist: valid, position, palm forward, palm across, in world space.
void vx_xros_vr_wrist_poses(const float wrists[20]);
int vx_xros_vr_bare_enabled(void);
void vx_xros_vr_middle_pinches(const float distances[2]);
unsigned vx_xros_vr_controller_buttons(double now);
#ifndef VX_HAND_BUTTONS_DEFINED
#define VX_HAND_BUTTONS_DEFINED
enum { HW_BTN_L_GRAB = 1u << 0, HW_BTN_L_TRIG = 1u << 1, HW_BTN_R_GRAB = 1u << 2,
       HW_BTN_R_TRIG = 1u << 3, HW_BTN_ACT_A = 1u << 4, HW_BTN_ACT_B = 1u << 5,
       HW_BTN_ACT_X = 1u << 6, HW_BTN_ACT_Y = 1u << 7, HW_BTN_ACTIVE = 1u << 15 };
#endif
void vx_xros_vr_hand_arms(const float arms[14]);
void vx_xros_vr_controller_state(unsigned btns, double now);
void vx_xros_vr_cycle_weapon_type(void);
// After the eyes: cb's completion lets the slot be written again (NULL: the frame was cancelled, nothing encoded).
void vx_xros_vr_end_frame(void *cb);
// One line of JSON fields for the app's log (per second: compositor frames, game frames, warp GPU time, slot age...).
void vx_xros_vr_stats(char *out, unsigned size);

#ifdef __cplusplus
}
#endif
