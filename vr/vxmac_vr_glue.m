// What the immersive presenter (xros_vr.m and warp_core.m, copied unchanged from avp-port's VXRuntime/src at the
// commit named in docs/DESIGN.md) needs from its surroundings, for VX Mac: in VXRuntime these come from the Windows
// layers (user32's raw mouse, xros_ui.m's pointer and keys, input.m's chords, npu_interp's FSR2 scene); here they go
// to libvxkit's macOS events and come from libvxmtlfx's MetalFX capture.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdarg.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "../shims/vxmac.h"
#include "npu_interp.h"

void (*vx_host_jlog)(const char *event, const char *fields);
int vx_xros_display_w = 1920, vx_xros_display_h = 1080;    // (the game's frame in pixels: set at each present)

void vx_log(const char *fmt, ...) {
    char line[1024];
    va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
    vxmac_log("%s", line);
}
void vx_xros_pace_tick(void) {}
int vx_game_mouse_look(void) { return !vxkit_cursor_associated(); }
unsigned long vx_head_consumed(void) { return vxkit_head_consumed(); }   // (the game dissociated the cursor: its mouse look)
void vx_input_chords_poll(void) {}

// (the display's pixels to the key window's points)
static void to_points(double x, double y, double *px, double *py) {
    double ww, wh; vxkit_window_size(&ww, &wh);
    *px = ww > 0 && vx_xros_display_w ? x * ww / vx_xros_display_w : x;
    *py = wh > 0 && vx_xros_display_h ? y * wh / vx_xros_display_h : y;
}
void vx_raw_mouse(int dx, int dy, uint16_t button_flags, int16_t wheel) {
    (void)button_flags;
    if (dx || dy) vxkit_post_mouse_delta(dx, dy);
    if (wheel) vxkit_post_scroll(0, wheel / 120.0, 0);
}
void vx_xros_hand_pointer(double x, double y) { double px, py; to_points(x, y, &px, &py); vxkit_post_mouse_pos(px, py); }
void vx_xros_hand_button(int which, int down) { vxkit_post_mouse_button(which, down); }
void vx_xros_hand_wheel(int delta) { vxkit_post_scroll(0, delta / 120.0, 0); }
void vx_xros_hand_key(int hid_usage, int down) { vxkit_post_hid_key((uint32_t)hid_usage, down); }

// The scene for the warp: the newest MetalFX encode's motion vectors and depth (render size), and a projection made
// for it in place of FSR2's constants (the presenter's FSR2 parser is ours too: npu_fsr2_parse reads them back):
//   tan(vertical FOV / 2) from VXMAC_FOV_V (degrees, default 70: the game's FOV setting decides; tan_x from the
//   frame's aspect); depth: MetalFX's isDepthReversed -> reversed infinite (distance = VXMAC_NEAR / d, default 0.2 m),
//   else standard with VXMAC_FAR (default 1000); motion vectors: MetalFX's scale is input pixels per unit, the
//   presenter wants UV units per unit (mvs = scale / input size).
// VXMAC_PROJ=0: no projection (the presenter's knobs, no prediction, no vr mode).
static float envf2(const char *n, float d) { const char *e = getenv(n); return e && *e ? (float)atof(e) : d; }
enum { kTag = 0x58465856 };
float vx_xros_vr_tan_y(void);   // (xros_vr.m: the frame's vertical tangent from its aspect, h31)   // ('VXFX')
int vxmac_npu_take(void **mv, uint32_t *w, uint32_t *h);   // (app/Sources/npu_flow.m)
float vxmac_npu_sign(void);
int npu_interp_take_scene(void **mv, void **depth, uint32_t consts[32]) {
    vxfx_frame f;
    memset(consts, 0, 32 * sizeof *consts);
    // (VX Mac's NPU flow first: the newest optical flow between the game's frames, from the Neural Engine. No depth with
    //  it (the presenter has the scene's depth from the game's passes); the projection the presenter's knobs say:
    //  VXRT_VR_TAN_Y (the game's FOV, zoomed), reversed infinite depth at VXRT_VR_NEAR; the flow's unit is a pixel of
    //  the flow image, so its scale is 1 / its size (VXMAC_NPU_SIGN flips its direction))
    {   // (the game's own velocity target, once verified against the picture (app/Sources/velocity.m): the best motion)
        int vxmac_vel_take(void **mv, float *mvs_x, float *mvs_y);
        void *vel = NULL; float kx = 0, ky = 0;
        if (vxmac_vel_take(&vel, &kx, &ky)) {
            *mv = vel; *depth = NULL;
            float ty = vx_xros_vr_tan_y(), nearp = envf2("VXRT_VR_NEAR", 0.2f);
            float v[9] = { ty, 0, nearp, ty * (float)vx_xros_display_w / (float)(vx_xros_display_h ? vx_xros_display_h : 1), ty,
                           kx, ky, (float)vx_xros_display_w, (float)vx_xros_display_h };
            consts[0] = kTag; consts[1] = 1;
            memcpy(&consts[2], v, sizeof v);
            return 3;
        }
    }
    {
        uint32_t fw = 0, fh = 0; void *flow = NULL;
        if (vxmac_npu_take(&flow, &fw, &fh)) {
            *mv = flow; *depth = NULL;
            float ty = vx_xros_vr_tan_y(), nearp = envf2("VXRT_VR_NEAR", 0.2f), sign = vxmac_npu_sign();
            float v[9] = { ty, 0, nearp, ty * (float)vx_xros_display_w / (float)(vx_xros_display_h ? vx_xros_display_h : 1), ty,
                           sign / (float)fw, sign / (float)fh, (float)vx_xros_display_w, (float)vx_xros_display_h };
            consts[0] = kTag; consts[1] = 1;
            memcpy(&consts[2], v, sizeof v);
            return 3;
        }
    }
    if (!vxfx_take_frame(&f)) return 0;
    if (f.color) CFRelease(f.color);
    if (f.output) CFRelease(f.output);
    if (!f.motion || !f.depth) {
        if (f.motion) CFRelease(f.motion);
        if (f.depth) CFRelease(f.depth);
        return 0;
    }
    *mv = f.motion; *depth = f.depth;
    if (envf2("VXMAC_PROJ", 1) == 0 || !f.input_w || !f.input_h) return 1;
    float fv = envf2("VXMAC_FOV_V", 70), nearp = envf2("VXMAC_NEAR", 0.2f), farp = envf2("VXMAC_FAR", 1000);
    float ty = tanf(fv * 0.5f * (float)M_PI / 180.f), tx = ty * (float)f.input_w / (float)f.input_h;
    float v[9];
    if (f.depth_reversed) { v[1] = 0; v[2] = nearp; }                                    // (z_b, z_a: distance = z_a / (d - z_b))
    else { v[2] = farp * nearp / (farp - nearp); v[1] = -nearp / (farp - nearp); }        // (standard: near 0, far 1, sign flipped below)
    v[0] = ty; v[3] = tx; v[4] = ty;
    v[5] = f.mv_scale_x / (float)f.input_w; v[6] = f.mv_scale_y / (float)f.input_h;
    v[7] = (float)f.output_w; v[8] = (float)f.output_h;
    consts[0] = kTag; consts[1] = f.depth_reversed ? 1 : 0;
    memcpy(&consts[2], v, sizeof v);
    return 3;
}
int npu_fsr2_parse(const uint32_t *consts, float *tan_half_fov_y, float d2v[4], float mvs[2], uint32_t disp[2]) {
    if (consts[0] != kTag) return 0;
    float v[9]; memcpy(v, &consts[2], sizeof v);
    *tan_half_fov_y = v[0];
    d2v[0] = v[1]; d2v[1] = v[2]; d2v[2] = v[3]; d2v[3] = v[4];
    mvs[0] = v[5]; mvs[1] = v[6];
    disp[0] = (uint32_t)v[7]; disp[1] = (uint32_t)v[8];
    return consts[1] ? 1 : 0;   // (standard depth: the presenter's FSR2 path assumes reversed: no projection then)
}
