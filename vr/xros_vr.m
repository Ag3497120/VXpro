#include <dlfcn.h>
// The immersive presenter (see xros_vr.h; VISIONOS_PORT.md, "VR presentation"). visionOS only.
//
// Knobs (read once):
//   VXRT_VR_TAN_Y=0.7          the game's tan(vertical FOV / 2) when no FSR2 constants say it (tan_x from the aspect)
//   VXRT_VR_NEAR=0.1, VXRT_VR_FAR=100, VXRT_VR_DEPTH=std|rev   the game's depth without FSR2's constants: standard
//                              (near 0, far 1) or reversed infinite (near / distance), its planes in game units
//   VXRT_VR_SCALE=1            metres per game unit (the stereo's and the head translation's scale)
//   VXRT_VR_PREDICT=1          with the game's motion vectors: each display frame predicted to its time (the NPU
//                              race's predictions); 0: the newest real frame only, reprojected to the head
//   VXRT_VR_REAL_HZ=0          a fixed real rate for the game (sync-interval presents wait for that many compositor
//                              frames: 22.5 at 90 Hz = every 4th); 0: the game's own sync interval
//   VXRT_VR_DEPTH_OUT=1        depth to the compositor (its per-pixel late reprojection); 0: none (rotation only)
//   VXRT_VR_MODE=auto          the default: vr mode below while the game renders a 3D view, the screen otherwise. The
//                              manual toggle (F11; a controller's Home + right stick click; both hands' pinch held 1 s)
//                              goes from auto to the other mode and back to auto; Home + left stick click recentres,
//                              Home + a stick up / down is the sensitivity (src/input.m); a label shows each change
//   VXRT_VR_MODE=screen        screen only: the game's picture on a large flat screen fixed in the room
//                              (world-locked, placed at the head's position and heading when the first frame comes,
//                              VXRT_VR_SCREEN_M=3 metres ahead, VXRT_VR_SCREEN_DEG=60 degrees wide); the head looks
//                              around it, both eyes see the same plane (its stereo is the plane's), its depth goes to
//                              the compositor. head: the model below (the game's camera taken as the head at each
//                              present: head-locked for a game whose camera only the mouse moves; kept for comparison)
//   VXRT_VR_MODE=vr            vr: head yaw and pitch sent to the game as relative mouse moves (raw input and the
//                              mouse deltas: VXRT_VR_COUNTS_PER_DEG=10 counts a degree, the game's sensitivity
//                              decides the real figure: F9 / F10 on a keyboard -/+10 %); the picture is the game's
//                              camera, posed where the moves sent so far put it (yaw, pitch; the head's position),
//                              and the warp reprojects the rest (roll, the moves the game has not used yet).
//                              F11 switches between vr and screen at run time; F12 recentres (screen or vr's zero).
//                              vr mode drives the game's camera only while the game renders a 3D view: frames with
//                              FSR2's constants and motion vectors for VXRT_VR_ENGAGE_S=1 s (VXRT_VR_ENGAGE=fsr2, the
//                              default; depth: the scene's depth is enough; always: the old behaviour). Otherwise
//                              (menus, the terms screen, videos: the game ignores the mouse, the frame would stay
//                              head-locked) the picture is the world-locked screen, placed again ahead of the head
//                              when vr mode lets go of it (no 3D frame for 0.5 s), and no mouse moves are sent
//   VXRT_HAND=1                hand tracking as the mouse (vx_xros_vr_hands): on the screen, the ray from the head
//                              through the hand (VXRT_HAND_RAY=head; shoulder: from an estimated shoulder) is the
//                              pointer (a dot on the screen shows it); a pinch of the primary hand (right, else the
//                              left) is a left click, a pinch held still for 0.3 s a drag, a pinch moved up or down a
//                              wheel scroll (VXRT_HAND_SCROLL_CM=1.5 per notch, the content follows the hand); the
//                              other hand's pinch a right click, held 0.6 s Esc. In vr mode's 3D view: primary pinch
//                              the left button held, the other the right button
//   VXRT_VR_MAX_HZ=45          VR: presents of any sync interval at most this many a second (the game's uncapped menu
//                              at 160 fps took the GPU from the compositor, which fell to 45 Hz); 0: no cap
//
// The model: the game's camera is the head as it was when the frame was presented (the game's own camera is moved by
// the mouse or a controller; the head only looks around within the frame). At each compositor frame, each eye is
// that picture moved from the camera it was rendered with to the eye (rotation, the eye's offset, its frustum), by
// the game's depth: head rotation is reprojected, the two eyes get their parallax, and where the game gave motion
// vectors the picture is predicted on to the frame's display time. Without depth the picture is at VXRT_VR_FAR.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "xros_vr.h"
#include "warp_core.h"
#include "npu_interp.h"
#include "hand_gestures.h"
#include "hand_weapon.h"

void vx_log(const char *fmt, ...);
void vx_xros_pace_tick(void);
extern void (*vx_host_jlog)(const char *event, const char *fields);   // (src/input.m: the app's host_log, or NULL)
void vx_input_chords_poll(void);                  // (src/input.m: a controller's chords for the presenter)                     // (src/xros_ui.m: a compositor frame for sync-interval presents)

static int g_on;
void vx_xros_vr_enable(int on) {
    g_on = on;
    const char *n = getenv("VXRT_NPU_INTERP");
    if (on) vx_log("VR: immersive presentation on (CompositorServices; the window is only a fallback); NPU race %s: %s", n && !strcmp(n, "race") ? "on" : "off",
                   n && !strcmp(n, "race") ? "each compositor frame predicted from the game's motion vectors (when it has them) and reprojected to the head" : "real frames reprojected to the head");
}
int vx_xros_vr_on(void) { return g_on; }

static double g_input_lag_s;                     // (below)
static float envf(const char *n, float d) { const char *e = getenv(n); return e && *e ? (float)atof(e) : d; }
static struct { float tan_y, nearp, farp, scale, real_hz, max_hz, screen_m, screen_deg; int depth_std, predict, depth_out, screen, vr; float cpd, cpd_y;
                float engage_s, scroll_cm; int engage, hand, hand_shoulder, calibrate, dibr, predict_vr; float stereo; } C;
static float g_tan_x_h;   // (VX Mac, h31: the game's horizontal tangent (VXRT_VR_TAN_X): the frame's vertical one from its aspect)
static void config_once(void) {
    C.tan_y = envf("VXRT_VR_TAN_Y", 0.7f);
    {   const char *l = getenv("VXMAC_FOV_LOCK"); g_tan_x_h = l && !strcmp(l, "v") ? 0 : envf("VXRT_VR_TAN_X", 0); }
    C.nearp = envf("VXRT_VR_NEAR", 0.1f);
    C.farp = envf("VXRT_VR_FAR", 100.0f);
    C.scale = envf("VXRT_VR_SCALE", 1.0f);
    C.real_hz = envf("VXRT_VR_REAL_HZ", 0);
    const char *d = getenv("VXRT_VR_DEPTH");
    C.depth_std = !d || strcmp(d, "rev");
    C.predict = envf("VXRT_VR_PREDICT", 1) != 0;
    C.depth_out = envf("VXRT_VR_DEPTH_OUT", 1) != 0;
    C.max_hz = envf("VXRT_VR_MAX_HZ", 45);
    C.screen_m = envf("VXRT_VR_SCREEN_M", 3);
    C.screen_deg = envf("VXRT_VR_SCREEN_DEG", 60);
    const char *m = getenv("VXRT_VR_MODE");
    C.screen = m && !strcmp(m, "screen");
    C.vr = !m || !*m || !strcmp(m, "vr") || !strcmp(m, "auto");    // (auto, the default: vr in a 3D view, the screen otherwise)
    // (VX Mac, h31: yaw and pitch apart. 17.4 (h3b's) was kept by a tuner reading the picture's turn 0.73x low; with
    //  the measurement corrected the game turned 1.40-1.49x the head in yaw and 1.03-1.17x in pitch at 17.4 (h31's
    //  fov_check): 12.0 and 15.8. host.m's bounded tuner trims them further)
    // (h40: 17.4 both again - right on the 16:9 frame (it felt natural; the corrected check reads ~1.0 there); 12.0 /
    //  15.8 matched the tall frame's mis-assumed FOV, not the game)
    C.cpd = envf("VXRT_VR_COUNTS_PER_DEG", 17.4f);
    C.cpd_y = envf("VXRT_VR_COUNTS_PER_DEG_Y", C.cpd);
    const char *e = getenv("VXRT_VR_ENGAGE");
    C.engage = !e || !*e || !strcmp(e, "fsr2") ? 0 : !strcmp(e, "depth") ? 1 : 2;
    C.engage_s = envf("VXRT_VR_ENGAGE_S", 1);
    C.hand = envf("VXRT_HAND", 1) != 0;
    const char *hr = getenv("VXRT_HAND_RAY");
    C.hand_shoulder = hr && !strcmp(hr, "shoulder");
    C.scroll_cm = envf("VXRT_HAND_SCROLL_CM", 1.5f);
    if (getenv("VXRT_VR_INPUT_LAG")) g_input_lag_s = envf("VXRT_VR_INPUT_LAG", 0.044f);
    C.calibrate = envf("VXRT_VR_CALIBRATE", 1) != 0 && !getenv("VXRT_VR_COUNTS_PER_DEG");
    // (the game's depth for the eyes' parallax: 1 (the default) always, 0 never, 2 only while the game is fast enough
    //  for it (frames 55 ms apart or less, the shown one younger than 100 ms); below that its holes and smears were the
    //  worst of h5a's picture. Prediction in vr mode only with VXRT_VR_PREDICT_VR=1, for the same reason)
    C.dibr = (int)envf("VXRT_VR_DIBR", 1);
    C.predict_vr = envf("VXRT_VR_PREDICT_VR", 0) != 0;
    C.stereo = envf("VXRT_VR_STEREO", 1.0f);            // (the eyes' and the head's offsets x this: smaller holes)
    vx_log("VR: vr mode drives the camera %s; hand input %s (ray from the %s)", C.engage == 2 ? "always" : C.engage == 1 ? "while the game renders depth" :
           "while the game renders a 3D view (FSR2's constants and motion vectors)", C.hand ? "on" : "off", C.hand_shoulder ? "shoulder" : "head");
    vx_log("VR: mode %s", C.vr ? "vr (head turns sent to the game as mouse moves)" : C.screen ? "screen (a flat screen fixed in the room)" : "head (the game's camera as the head at each present)");
    if (C.vr) C.screen = 0;
    vx_log("VR: vr mode's mouse: %.2f counts a degree (VXRT_VR_COUNTS_PER_DEG; F9/F10 -/+10%%, F11 toggles vr mode, F12 recentres)", C.cpd);
    if (C.screen) vx_log("VR: the screen %.1f m ahead, %.0f degrees wide", C.screen_m, C.screen_deg);
    vx_log("VR: game projection without FSR2: tan(vFOV/2) %.3f, depth %s near %g far %g; scale %g m/unit; prediction %s; depth to the compositor %s",
           C.tan_y, C.depth_std ? "standard" : "reversed infinite", C.nearp, C.farp, C.scale, C.predict ? "on" : "off", C.depth_out ? "on" : "off");
}
static void config(void) { static pthread_once_t once = PTHREAD_ONCE_INIT; pthread_once(&once, config_once); }

// ---- slots ----
typedef struct {
    __strong id<MTLTexture> color, view, depth, mv, prev, prev_view;   // (prev: the frame before, for the HUD's still check)   // (view: the colour as the warp samples it, sRGB-decoded for 8-bit unorm)
    uint32_t w, h, has_depth, has_mv, has_proj, flags;
    __strong id<MTLBuffer> sdp_tmp;
    __strong id<MTLBuffer> cal_buf; uint32_t cal_n, cal_bpp;   // (the motion vectors' middle strip, for calibration)
    float tan_x, tan_y, z_a, z_b, mv_sx, mv_sy;
    float head[16];                  // (origin from the camera it is shown from: the head at its present)
    float prev_cam[16]; int has_prev; // (vr mode: the camera of the game frame before, for the motion's camera part)
    int head_valid;                  // (0: presented before the first compositor frame; it takes the next frame's head)
    double content_time, interval;
    __strong id<MTLTexture> vmv; int has_vmv; float vk[2];   // (VX Mac, VXMAC_INTERP=vel: the game's velocity of this frame, copied, and its scale)
    double gap_before;               // (VX Mac, method 3: this present's own time since the one before (s, 0 unknown): the
                                     //  interval its velocity covers - the model's motion unit; interval is the smoothed one)
    uint64_t serial;
    uint64_t pseq;                   // (VX Mac: the present's number, vx_xros_vr_next_seq: the SR detail made from it)
    __strong id<MTLTexture> hud, hud_view; int has_hud;   // (VX Mac, h33: the frame's HUD layer, libvxmtl's UI pass)
    int writing, readers;
    float cam_rows[9], cam_vel[3]; int cam_ok;   // (VX Mac, h60: the game camera's axes (rows: right, up, forward; Z up) and velocity at this frame)
} vr_slot;
static vr_slot g_slot[3];
static int g_newest = -1, g_held = -1;
static uint64_t g_serial;
static _Atomic uint64_t g_present_seq;
static __strong id<MTLTexture> g_hud_in, g_hud_keep, g_hud_keep_view; static double g_hud_keep_t;                // (VX Mac, h33: the next submit's HUD layer, vx_xros_vr_set_hud_layer)
void vx_xros_vr_set_hud_layer(void *tex) { g_hud_in = (__bridge id<MTLTexture>)tex; }                  // (VX Mac: every submit's number, slot or not)
uint64_t vx_xros_vr_next_seq(void) { return g_present_seq + 1; }
// (VX Mac: foveation: the eye's rasterization rate map (VXMacImmersive.swift, before each eye), or nil: every pass drawn
//  into the eye goes through it, on the logical screen)
static __strong id<MTLRasterizationRateMap> g_rrm;
void vx_xros_vr_set_rate_map(void *map) { g_rrm = (__bridge id<MTLRasterizationRateMap>)map; }
static id<MTLRenderCommandEncoder> eye_encoder(id<MTLCommandBuffer> cb, MTLRenderPassDescriptor *pass) {
    id<MTLRasterizationRateMap> m = g_rrm;
    pass.rasterizationRateMap = m;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
    if (m) [e setViewport:(MTLViewport){ 0, 0, (double)m.screenSize.width, (double)m.screenSize.height, 0, 1 }];
    return e;
}
static void eye_size(id<MTLTexture> out, float *w, float *h) {
    id<MTLRasterizationRateMap> m = g_rrm;
    *w = m ? (float)m.screenSize.width : (float)out.width; *h = m ? (float)m.screenSize.height : (float)out.height;
}
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static float g_head[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
static double g_last_submit, g_interval = 1.0 / 30;
static double g_present_time;
static int g_head_valid;
// (vr mode's hold on the camera: the game renders a 3D view; see VXRT_VR_ENGAGE)
static int g_engaged; static double g_3d_since, g_3d_last; static unsigned g_engage_changes;
static int g_force;                                     // (0 auto; the manual toggle: 1 vr, 2 the screen)
static double g_label_until;                             // (below, with the label)
static int g_label_big;                                  // (VX Mac, h47: the warp mode's label, larger)
static const char *ui_str(int i);                        // (VX Mac, h47: the labels' languages, below)
static int ui_lang(void);
static int g_label_extra;                                // (VX Mac, h54: the manual toggle's label when it also changed the automatic screen)
static int vr_now(void) { return g_force == 1 || (!g_force && C.vr && (C.engage == 2 || g_engaged)); }   // (the game's camera driven now)
static int screen_now(void) { return g_force == 2 || (!vr_now() && (C.screen || C.vr)); }               // (the world-locked screen shown now)
static double g_fade_at;                                  // (VX Mac: a change between the panel and the head-driven view fades in from black)
static double g_rot_sum; static float g_rot_max; static unsigned g_rot_n;
static double g_roll_sum; static float g_roll_max; static unsigned g_roll_n;   // (VX Mac, h43: the eye's roll against the frame)   // (VX Mac, h33: the warp's applied rotation)
static int g_guard_level; static double g_slow_s;      // (VX Mac, h29: the 90 Hz guard - 1: no SR blend, 2: no world cache either)
static double g_ctrl_t;                                  // (VX Mac, h49: the last controller input (host.m): pinch gestures wait 2 s after it)
void vx_xros_vr_controller_touch(void) { g_ctrl_t = CACurrentMediaTime(); }
static int g_show_mode;                                  // (VX Mac, h47: the warp mode's label due at head-look's start)
static int g_warp_mode = -1;                             // (VX Mac, h37: the warp's A/B mode, live; h38: VXMAC_WARP_MODE, default 2)
// (VX Mac, h37: each present's camera stamp (yaw, pitch, the input-based yaw) - mode 4 replaces it with the picture's
//  measured turn from the frame before, and the step traces read them)
static float g_stamp_y[64], g_stamp_p[64], g_stamp_cons_y[64]; static uint64_t g_stamp_at[64];
static int g_look_hold; static float g_follow_ema = 1;  // (VX Mac: the share of recent head turns the picture followed)                                  // (VX Mac: the game's mouse look on for 3 s: vr mode holds through depth gaps)
static int g_wc_clear = 1;                               // (the world cache cleared at its next update: vr mode entered)
static int g_eff = -1;                                   // (the mode shown at the last compositor frame: 0 head, 1 screen, 2 vr)
static void show_label(const char *text);
// (stats, reset each report)
static double g_max_gap; static unsigned g_dibr_frames;
static float g_outside_sum, g_game_tan[2]; static unsigned g_outside_n;
static unsigned g_frames, g_submits, g_draws, g_noframe, g_depth_frames, g_mv_frames;
static double g_gpu_ms, g_age_ms; static unsigned g_gpu_n;
// (VX Mac, method 3: the warp's use of the model's layers - eyes asked / predicted with them, distinct frames, the
//  predicted time (age) and t, eyes held at the gate, the compositor frames' GPU time with and without the layers;
//  vx_xros_vr_interp_stats, printed only while VXMAC_INTERP is on (npu_model.m))
static unsigned long g_iw_conf_off; static unsigned long g_iw_eyes, g_iw_total, g_iw_frames, g_iw_held, g_iw_gpu_n, g_iw_gpu_n0; static uint64_t g_iw_last_seq;
static double g_iw_age_sum, g_iw_age_max, g_iw_t_sum, g_iw_gpu_ms, g_iw_gpu_ms0; static int g_iw_frame_used;
static double g_last_gap;
// (VX Mac, h63c: VXMAC_INTERP - 1 the model's layers (npu_model.m), vel: the same prediction (timing, t cap, 150 ms hold,
//  camera turn out, no h60 move, depth z-order) on the game's raw velocity with the default kernels (their DIBR hole
//  rule): no Core ML, no Neural Engine; otherwise off)
static int interp_mode(void) {
    static int m = -1;
    if (m < 0) { const char *e = getenv("VXMAC_INTERP"); m = e && !strcmp(e, "1") ? 1 : e && !strcmp(e, "vel") ? 2 : 0; }
    return m;
}
int vx_xros_vr_interp_mode(void) { return interp_mode(); }
static float g_tan_seen[4];

// ---- the scene's depth (as stereo.m: the depth of the back buffer's aspect with the most depth-tested draws; copied
// at the end of every pass that wrote it, since a placed resource may be aliased later in the frame) ----
typedef struct { void *tex; uint32_t w, h, draws; } depth_cand;
static depth_cand g_cand[16];
static int g_ncand, g_copies;
static void *g_pick; static uint32_t g_pick_w, g_pick_h; static MTLPixelFormat g_pick_fmt;
static id<MTLBuffer> g_hold, g_hold_pool[3];
static unsigned g_hold_busy;
static int g_hold_index = -1;
static uint32_t g_back_w, g_back_h;

void vx_xros_vr_depth_pass(void *cbp, void *texp, uint32_t draws, uint32_t writes, uint32_t funcs) {
    (void)funcs;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
    id<MTLTexture> t = (__bridge id<MTLTexture>)texp;
    if (!g_on || !draws || !t || !g_back_w || t.sampleCount > 1 || !(t.textureType == MTLTextureType2D || (t.textureType == MTLTextureType2DArray && t.arrayLength == 1))) return;   // (VX Mac: the Mac game's depth is a one-slice array)
    MTLPixelFormat f = t.pixelFormat;
    if (f != MTLPixelFormatDepth16Unorm && f != MTLPixelFormatDepth32Float && f != MTLPixelFormatDepth32Float_Stencil8) return;
    uint32_t w = (uint32_t)t.width, h = (uint32_t)t.height;
    if (w < 128 || fabs(((double)w / h) / ((double)g_back_w / g_back_h) - 1.0) > 0.03) return;
    pthread_mutex_lock(&g_lock);
    depth_cand *c = NULL;
    for (int k = 0; k < g_ncand; k++) if (g_cand[k].tex == texp) c = &g_cand[k];
    if (!c && writes && g_ncand < 16) { c = &g_cand[g_ncand++]; *c = (depth_cand){ texp, w, h, 0 }; }
    if (c && writes) c->draws += draws;
    // (VX Mac: by the pick's size, not its texture: the Mac game draws its scene depth into two textures by turns
    //  (one Depth32Float, one Depth32Float_Stencil8), so a pick by texture matched every other frame and the depth came
    //  and went - the picture's scale jumped with it (the zoom pulses, h25). The last pass of the frame at that size wins)
    if (g_pick && writes && w == g_pick_w && h == g_pick_h && (g_pick_fmt == MTLPixelFormatDepth32Float_Stencil8 ? f == g_pick_fmt : (f == MTLPixelFormatDepth32Float || f == MTLPixelFormatDepth32Float_Stencil8 || f == g_pick_fmt))) {
        uint32_t bpp = f == MTLPixelFormatDepth16Unorm ? 2 : 4;
        NSUInteger need = (NSUInteger)w * h * bpp;
        if (g_hold_index < 0) {
            for (int i = 0; i < 3; i++) if (!(g_hold_busy & (1u << i))) { g_hold_index = i; g_hold_busy |= 1u << i; break; }
        }
        if (g_hold_index >= 0) {
            if (!g_hold_pool[g_hold_index] || g_hold_pool[g_hold_index].length != need)
                g_hold_pool[g_hold_index] = [cb.device newBufferWithLength:need options:MTLResourceStorageModePrivate];
            g_hold = g_hold_pool[g_hold_index];
        }
        if (g_hold) {
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                      toBuffer:g_hold destinationOffset:0 destinationBytesPerRow:(NSUInteger)w * bpp destinationBytesPerImage:need
                       options:f == MTLPixelFormatDepth32Float_Stencil8 ? MTLBlitOptionDepthFromDepthStencil : MTLBlitOptionNone];
            [b endEncoding];
            g_copies++;
        }
    }
    pthread_mutex_unlock(&g_lock);
}

// (VX Mac, method 3: this frame's scene depth as copied so far, before vx_xros_vr_submit takes it - the training capture
//  and the model read it in the same command buffer; NULL when no pass wrote it this frame)
void *vx_xros_vr_scene_depth(uint32_t *w, uint32_t *h, uint32_t *bpp) {
    pthread_mutex_lock(&g_lock);
    id<MTLBuffer> b = g_copies > 0 ? g_hold : nil;
    *w = g_pick_w; *h = g_pick_h; *bpp = g_pick_fmt == MTLPixelFormatDepth16Unorm ? 2 : 4;
    pthread_mutex_unlock(&g_lock);
    return (__bridge void *)b;
}

static id<MTLTexture> slot_tex(id<MTLDevice> dev, id<MTLTexture> t, MTLPixelFormat f, uint32_t w, uint32_t h) {
    if (t && t.pixelFormat == f && t.width == w && t.height == h) return t;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    td.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:td];
}
// (an 8-bit unorm back buffer holds sRGB-encoded values: sampled through an sRGB view, so the sRGB drawable shows them
//  as they are; VXRT_VR_SRGB=0: as they are, unconverted)
static MTLPixelFormat srgb_of(MTLPixelFormat f) {
    static int on = -1;
    if (on < 0) on = envf("VXRT_VR_SRGB", 1) != 0;
    if (!on) return MTLPixelFormatInvalid;
    return f == MTLPixelFormatRGBA8Unorm ? MTLPixelFormatRGBA8Unorm_sRGB : f == MTLPixelFormatBGRA8Unorm ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatInvalid;
}

// ---- screen mode: the screen's pose in the room (origin from screen: its centre, +z towards the viewer) ----
static void show_label(const char *text);
static float g_screen[16]; static int g_screen_valid, g_recenter;
static float g_cursor_dot[4];                            // (the hand's pointer on the screen: u, v, shown, pinched)
// (VX Mac, h70: the magazine by hand, for the eyes' drawing - the grip's bottom as a ring while a magazine is wanted
//  (lit when the hand is there), a magazine in the off hand while one is held; the room's frame; under g_lock)
static float g_vm_delta[3], g_vm_rot[3], g_vm_off_delta[3], g_vm_off_rot[3];
static int g_vm_active, g_vm_off_active;

int vx_xros_vr_viewmodel_pose(float delta_cam[3], float rot_cam[3]) {
    pthread_mutex_lock(&g_lock);
    int active = g_vm_active;
    if (active) { memcpy(delta_cam, g_vm_delta, sizeof g_vm_delta); memcpy(rot_cam, g_vm_rot, sizeof g_vm_rot); }
    pthread_mutex_unlock(&g_lock);
    return active;
}
int vx_xros_vr_viewmodel_poses(float gun_delta[3], float gun_rot[3], float off_delta[3], float off_rot[3], int *off_ok) {
    pthread_mutex_lock(&g_lock);
    int active = g_vm_active;
    if (active) {
        memcpy(gun_delta, g_vm_delta, sizeof g_vm_delta); memcpy(gun_rot, g_vm_rot, sizeof g_vm_rot);
        memcpy(off_delta, g_vm_off_delta, sizeof g_vm_off_delta); memcpy(off_rot, g_vm_off_rot, sizeof g_vm_off_rot);
        if (off_ok) *off_ok = g_vm_off_active;
    } else if (off_ok) *off_ok = 0;
    pthread_mutex_unlock(&g_lock);
    return active;
}
static struct { int on, ring, lit, mag, holding, state, gun_ok, slide_hold, weapon_type, two_hand, pinch[2]; float well[3], grip_dir[3], mag_at[3], mag_up[3], skel[134], palm[3], off_palm[3], fwd[3], pull, neutral_palm[3], neutral_fwd[3], neutral_up[3], off_neutral[3]; int off_ok; } g_mag_draw;
void vx_xros_vr_recenter(void) { g_recenter = 1; show_label("Recentred"); }
static void place_screen(const float *head) {
    if (head[12] == 0 && head[13] == 0 && head[14] == 0) return;   // (no pose yet: h2b placed one at the floor)
    float fx = -head[8], fz = -head[10];                 // (the head's forward, -z, on the floor plane)
    float n = sqrtf(fx * fx + fz * fz);
    if (n < 1e-3f) { fx = 0; fz = -1; n = 1; }
    fx /= n; fz /= n;
    // columns: x = right (-fz, 0, fx), y = up, z = back (-forward); centre ahead of the head at its height
    float M[16] = { -fz, 0, fx, 0,  0, 1, 0, 0,  -fx, 0, -fz, 0,
                    head[12] + fx * C.screen_m, head[13], head[14] + fz * C.screen_m, 1 };
    memcpy(g_screen, M, sizeof M);
    g_screen_valid = 1;
    vx_log("VR: screen placed at %.2f %.2f %.2f, facing %.2f %.2f", M[12], M[13], M[14], -fx, -fz);
}
static void inv_rigid(const float *a, float *o) {        // (rotation + translation, column-major)
    for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) o[c * 4 + r] = a[r * 4 + c];
    for (int r = 0; r < 3; r++) o[12 + r] = -(o[r] * a[12] + o[4 + r] * a[13] + o[8 + r] * a[14]);
    o[3] = o[7] = o[11] = 0; o[15] = 1;
}

// ---- vr mode: the head's yaw and pitch as mouse moves; the pose sent so far is the game camera's ----
void vx_raw_mouse(int dx, int dy, uint16_t button_flags, int16_t wheel);   // (src/user32.c: WM_INPUT and the deltas)
static float g_yaw_ref, g_pitch_ref, g_sent_yaw, g_sent_pitch; static int g_vr_ref, g_mouse_counts; static unsigned g_fsr2_frames;
typedef struct { double t; float yaw, pitch; } sent_pose;
static sent_pose g_sent_hist[256]; static unsigned g_sent_n;
// (VX Mac, h28: the frame's camera by what the game had taken. Each send is one mouse event; libvxkit counts the head's
//  events the program has taken from its queue (vxkit_head_consumed). A game frame's camera is the pose of the last
//  send it had taken - K presents before it (the game's pipeline: it simulates one frame while it renders another).
//  K is chosen from the picture: per pair of frames the image check's measured turn (host.m) against each K's camera
//  turn, the smallest error over ~3 s wins (VXMAC_CAM_K=n fixes it). The time-based stamp (sent by now - input lag)
//  made the picture snap back at each new game frame when frames came unevenly (h28's judder: +48 / -40 px).)
typedef struct { unsigned long seq; float yaw, pitch; } send_rec;
static send_rec g_sendq[1024]; static unsigned long g_send_seq;
static unsigned long g_cons[64]; static float g_yk[64][4][2]; static unsigned char g_yk_ok[64][4];
static int g_cam_k = 1, g_cam_k_fixed = -1; static double g_k_err[4]; static unsigned g_k_n;
unsigned long vx_head_consumed(void);   // (vxmac_vr_glue.m: libvxkit's count)
static int sent_by_seq(unsigned long c, float *yaw, float *pitch) {   // (with g_lock held)
    if (!c || c > g_send_seq || g_send_seq - c >= 1024) return 0;
    const send_rec *r = &g_sendq[c % 1024];
    if (r->seq != c) return 0;
    *yaw = r->yaw; *pitch = r->pitch; return 1;
}
static double g_input_lag_s = 0.044;                     // (the game's input latency: VXRT_VR_INPUT_LAG s, else measured)
static float wrap180(float a) { while (a > 180) a -= 360; while (a < -180) a += 360; return a; }
static unsigned long g_pred_eyes, g_pred_eyes_total;   // (VX Mac: eyes drawn with a prediction / all, vx_xros_vr_pred_stats)
void vx_xros_vr_pred_stats(unsigned long *pred, unsigned long *total) { *pred = g_pred_eyes; *total = g_pred_eyes_total; g_pred_eyes = g_pred_eyes_total = 0; }
static float g_cam_off_yaw, g_cam_off_pitch;   // (VX Mac: the controller's share of the camera, vx_xros_vr_add_camera_offset)
static void head_angles(const float *m, float *yaw, float *pitch) {
    float fx = -m[8], fy = -m[9], fz = -m[10];
    *yaw = atan2f(-fx, -fz) * 180 / (float)M_PI;
    *pitch = asinf(fy < -1 ? -1 : fy > 1 ? 1 : fy) * 180 / (float)M_PI;
}
static void camera_pose(float yaw, float pitch, const float *head, float *o) {   // (Ry(yaw) Rx(pitch), the head's position)
    float a = yaw * (float)M_PI / 180, p = pitch * (float)M_PI / 180, ca = cosf(a), sa = sinf(a), cp = cosf(p), sp = sinf(p);
    float M[16] = { ca, 0, -sa, 0,   sa * sp, cp, ca * sp, 0,   sa * cp, -sp, ca * cp, 0,   head[12], head[13], head[14], 1 };
    memcpy(o, M, sizeof M);
}
// The manual toggle (F11, a controller chord, both hands' pinch held): from auto to the other mode than the one shown,
// from a manual mode back to auto.
static int auto_screen(void); static void set_auto_screen(int on); static double g_nocontrol_until, g_ignore_until;   // (h54, below)
void vx_xros_vr_toggle_vr(void) {
    // (VX Mac: no manual mode for the user: the state follows the game's output only. A both-hands pinch forced the
    //  head-driven view over the intro logos, h12. VXMAC_VR_TOGGLE=1 brings the toggle back for debugging)
    // (h47: on again by default, as the user's override of the automatic choice (a cutscene's screen, a menu's panel):
    //  in vr mode -> the world-locked screen, otherwise -> vr mode (the head's pitch sent afresh on entry); a forced vr
    //  mode ends by itself once the automatic choice says vr too. VXMAC_VR_TOGGLE=0: off)
    { const char *e = getenv("VXMAC_VR_TOGGLE"); if (e && !strcmp(e, "0")) { if (g_force) g_force = 0; return; } }
    config();
    pthread_mutex_lock(&g_lock);
    g_force = vr_now() ? 2 : 1;
    int v = vr_now();
    {   // (h54: VR forced while the cutscene screen shows -> the automatic screen off; Screen forced in VR with it off -> on)
        double tn = CACurrentMediaTime();
        if (!v && tn < g_nocontrol_until && auto_screen()) { set_auto_screen(0); g_nocontrol_until = 0; g_label_extra = 11; }
        else if (v && !auto_screen()) { set_auto_screen(1); g_label_extra = 12; }
    }
    g_label_until = 0;
    pthread_mutex_unlock(&g_lock);
    const char *t = ui_str(g_label_extra ? g_label_extra : v ? 7 : 8); g_label_extra = 0;
    vx_log("VR: manual toggle: %s", v ? "VR" : "Screen");
    if (vx_host_jlog) { char f[64]; snprintf(f, sizeof f, "\"to\":\"%s\"", t); vx_host_jlog("manual_toggle", f); }
    show_label(t);
    pthread_mutex_lock(&g_lock); g_label_until = CACurrentMediaTime() + 1.0; pthread_mutex_unlock(&g_lock);
}
void vx_xros_vr_scale(float factor) {
    config(); C.scale *= factor;
    vx_log("VR: world scale %.3f m a game unit", C.scale);
    char t[64]; snprintf(t, sizeof t, "World size %.2f", C.scale); show_label(t);
}
void vx_xros_vr_stereo(float factor) {
    config(); C.stereo *= factor; if (C.stereo > 2) C.stereo = 2;
    vx_log("VR: stereo strength %.2f", C.stereo);
    char t[64]; snprintf(t, sizeof t, "Depth %.0f%%", C.stereo * 100); show_label(t);
}
void vx_xros_vr_sensitivity(float factor) {
    config(); C.cpd *= factor; C.cpd_y *= factor;
    vx_log("VR: vr mode's mouse: %.2f counts a degree", C.cpd);
    char t[64]; snprintf(t, sizeof t, "Sensitivity %.1f counts/deg", C.cpd); show_label(t);
}
static double g_move_sum; static unsigned g_move_n;   // (h60: the translation applied, for the log)
static unsigned g_ref_gen; static unsigned long g_cam_skips, g_yaw_clamps, g_pitch_clamps; static int g_pitch_follows = 1;
static int g_vehicle; static float g_game_hfov;
// (h64: combat input and the game's FOV changing hold the detectors still. A run with fights (hab1 d.jsonl, 1800 s)
//  had 162 vehicle_mode flips at the on-foot FOV (strafing while turning reads as an orbit: |v / w| metres), 89 pitch
//  axis_freeze "camera moves itself" (recoil, aim snap, ADS's zoom read as a shift), pitch_follow flipping with them -
//  head pitch went unsent for seconds at a time. Within 1.5 s of the triggers / mouse buttons (vxmac_combat_input) or
//  1 s of an FOV change: no vehicle entry, no pitch_follow verdict, no "camera moves itself" freeze. VXMAC_COMBAT_GATE=0:
//  off, as before)
static double g_combat_t = -100, g_fov_change_t = -100; static int g_combat_bits; static unsigned long g_gated_freezes, g_gated_vehicle, g_gated_follow;
static int combat_gate_on(void) { static int on = -1; if (on < 0) { const char *e = getenv("VXMAC_COMBAT_GATE"); on = !(e && !strcmp(e, "0")); } return on; }
static int combat_gate(double now) { return combat_gate_on() && (now - g_combat_t < 1.5 || now - g_fov_change_t < 1.0); }
// (h64: the game camera's own pitch per present (libvxmtl's view matrix), for the axis checks instead of the picture's
//  row profile when both frames have one - ADS's zoom and muzzle flashes moved the profile, not the camera)
static float g_gp_of[64]; static uint64_t g_gp_seq[64];
static double g_gain_sxy[2], g_gain_sxx[2]; static unsigned g_gain_n[2];   // (h64: the game's yaw per sent yaw, free / aiming)
// (h64: warp mode 7 - free look and controller aim; below with vr_mouse)
static int aim_on(void);
static float g_hand_aim_y, g_hand_aim_p;
static int g_hand_draw_zone;
int vx_xros_vr_draw_zone(void) { pthread_mutex_lock(&g_lock); int z = g_hand_draw_zone; pthread_mutex_unlock(&g_lock); return z; }
static float g_aim_push_p; static int g_rebase_due; static double g_aim_cam_t;                                // (pitch the cone's edge asks of the game, sent at the next vr_mouse)
static float g_xh[2][2]; static int g_xh_ok[2];           // (each eye's tangents of the frame's centre: the crosshair's place)
static float g_cam_rows[9], g_cam_vel[3]; static int g_cam_now_ok;   // (h60: the newest game camera's axes and velocity, m/s)   // (h57e/f: the game's camera is a vehicle's (third-person orbit, below); the game's horizontal FOV)   // (h57: vr mode's zero set again; game camera reads not shown)
static int g_cam_src = -1, g_cam_src_on = -1; static float g_cam_sy = 1, g_cam_sp = 1, g_cam_off_y, g_cam_off_p; static int g_cam_off_ok, g_cam_pitch_ok;
static double g_last_poll;
static float g_pitch_hi = 80, g_pitch_lo = -80;          // (VX Mac, h43: the game's pitch limits as found)
static double g_freeze_until[2];                          // (VX Mac, h48: an axis (0 yaw, 1 pitch) the game does not follow now: not sent)
static float g_pitch_off;                                 // (VX Mac, h43: the estimated game pitch - head pitch, from the picture)   // (VX Mac, h38: the last poll-hook send)
static int g_poll_in = -1;   // (VX Mac, h38: the head's delta sent when the game polls its events (vx_xros_vr_input_poll), not at each compositor frame; VXMAC_POLL_INPUT=0: the old way)
// (h64: the learned pitch limit (h43) from the picture is the old way only - VXMAC_PITCH_LEARN=1. With the game's own
//  pitch read from its constants the closed loop needs no limit (the game drops mouse moves past its own), and the
//  picture's rule fired on a menu's cut (hab1 d.jsonl 1429 s: -28.7 deg, kept for the rest of the session: the head
//  could not look further down). The limits now also start again at each vr mode zero)
static int pitch_learn_old(void) { static int on = -1; if (on < 0) { const char *e = getenv("VXMAC_PITCH_LEARN"); on = e && !strcmp(e, "1"); } return on; }
// (h64: the pitch account moved back to the head's zero (with g_lock held). Vehicle mode and the free-look cone absorb
//  the head's pitch into g_pitch_ref; left there, the sent pitch drifted 40-60 deg from the head's (d.jsonl 300-470 s)
//  and the 80-deg clamp and the pitch limit acted on the drifted account. Every stored sent pitch moves with it, so
//  the frames' input-based pitch and the game's absolute one stay as they were)
static void pitch_rebase(void) {
    float r = g_pitch_ref;
    if (fabsf(r) < 0.01f) return;
    g_pitch_ref = 0; g_sent_pitch += r;
    for (unsigned k = 0; k < 256; k++) g_sent_hist[k].pitch += r;
    for (unsigned k = 0; k < 1024; k++) g_sendq[k].pitch += r;
    for (int i = 0; i < 64; i++) { for (int k = 0; k < 4; k++) g_yk[i][k][1] += r; g_stamp_p[i] += r; }
    if (vx_host_jlog) { char f[64]; snprintf(f, sizeof f, "\"moved_deg\":%.1f", r); vx_host_jlog("pitch_rebase", f); }
}
// (h64: warp mode 7, free look and controller aim (VXMAC_AIM=1 starts in it; VXMAC_AIM=cycle only adds it to the warp
//  mode cycle; unset: no mode 7 at all). The head looks around inside a cone (VXMAC_AIM_CONE="yaw,pitch" half-angles,
//  default 20,12 deg) without moving the game's camera: the frame stays where the game's camera points, world-fixed, the
//  off-frame fill and fade around it, and the HUD's crosshair is drawn at the frame's centre, not the head's. Past the
//  cone's edge the camera is pulled along with the head (yaw: the cone's edge sent 1:1; pitch: the game's own pitch
//  brought back to the edge, as h52b's loop). The right stick's pitch reaches the game (host.m), so the stick / mouse
//  aims. VXMAC_AIM_DRIFT=<deg/s> (default 0, off): the camera drifts toward the head inside the cone)
static int g_aim_avail = -1; static float g_aim_cone_y = 20, g_aim_cone_p = 12, g_aim_drift = 0;
static void aim_config(void) {
    if (g_aim_avail >= 0) return;
    const char *e = getenv("VXMAC_AIM");
    g_aim_avail = e && *e && strcmp(e, "0") ? (!strcmp(e, "cycle") ? 1 : 2) : 0;
    const char *c = getenv("VXMAC_AIM_CONE");
    if (c && *c) { float a = 0, b = 0; int n = sscanf(c, "%f,%f", &a, &b); if (n >= 1 && a >= 0) g_aim_cone_y = a; if (n >= 2 && b >= 0) g_aim_cone_p = b; else if (n == 1) g_aim_cone_p = a * 0.6f; }
    const char *d = getenv("VXMAC_AIM_DRIFT"); if (d && *d) g_aim_drift = (float)atof(d);
    if (g_aim_avail) vx_log("VR: warp mode 7 (free look + controller aim) %s; cone +-%.0f yaw, +-%.0f pitch; drift %.1f deg/s", g_aim_avail == 2 ? "at the start" : "in the cycle", g_aim_cone_y, g_aim_cone_p, g_aim_drift);
}
static int g_aim_was;
static int aim_on(void) { return g_warp_mode == 7 && vr_now(); }
int vx_xros_vr_aim_mode(void) { return aim_on(); }
static int warp_start_mode(void) {   // (VXMAC_WARP_MODE 0-6, default 6; h64: 7 with VXMAC_AIM, which starts in it when =1)
    aim_config();
    const char *e = getenv("VXMAC_WARP_MODE"); int m = e && *e ? atoi(e) : g_aim_avail == 2 ? 7 : 6;
    return m >= 0 && m <= (g_aim_avail ? 7 : 6) ? m : 6;
}
static void vr_mouse(const float *m, double now, int send) {        // (with g_lock held)
    float yaw, pitch; head_angles(m, &yaw, &pitch);
    if (g_rebase_due) { g_rebase_due = 0; pitch_rebase(); }   // (h64: after vehicle mode, here: no present half-way)
    if (!g_vr_ref || g_recenter) {
        { const char *e = getenv("VXMAC_PITCH_LIMIT"); if (e && *e) { g_pitch_hi = (float)atof(e); g_pitch_lo = -g_pitch_hi; } else if (!pitch_learn_old()) { g_pitch_hi = 80; g_pitch_lo = -80; } }
        g_aim_push_p = 0;
        g_pitch_off = 0;
        g_recenter = 0; g_vr_ref = 1; g_yaw_ref = yaw; g_ref_gen++; g_cam_off_ok = 0; g_pitch_ref = 0; g_sent_yaw = 0; g_sent_pitch = 0; g_sent_n = 0; g_cam_off_yaw = g_cam_off_pitch = 0;
        vx_log("VR: vr mode's zero: yaw %.1f (the game's camera is taken as level there)", yaw);
    }
    float want_y = wrap180(yaw - g_yaw_ref), want_p = pitch - g_pitch_ref;
    if (g_vehicle) { g_pitch_ref += want_p - g_sent_pitch; want_p = g_sent_pitch; }   // (h57e: on a vehicle no head pitch is sent: the vehicle camera keeps its own)
    if (now < g_ignore_until) {   // (h54: the game ignores the head and VR stays: the head's moves go into the zero, nothing sent)
        g_yaw_ref = wrap180(g_yaw_ref + wrap180(want_y - g_sent_yaw)); g_pitch_ref += want_p - g_sent_pitch;
        want_y = g_sent_yaw; want_p = g_sent_pitch;
    }
    {   // (h64: mode 7's cone - yaw: nothing sent while the head is within the cone of the sent yaw (the frame's, after
        //  the yaw filter), the cone's edge dragged 1:1 past it; pitch: the head's never sent, only the loop's push)
        int a = aim_on();
        if (a) {
            static double lt; double dt = lt > 0 && now - lt < 0.2 ? now - lt : 0; lt = now;
            float e = wrap180(want_y - g_sent_yaw);
            if (e > g_aim_cone_y) want_y = wrap180(want_y - g_aim_cone_y);
            else if (e < -g_aim_cone_y) want_y = wrap180(want_y + g_aim_cone_y);
            else if (g_aim_drift > 0 && fabsf(e) > 1.0f) { float s = g_aim_drift * (float)dt; want_y = wrap180(g_sent_yaw + (e > 0 ? fminf(s, e) : fmaxf(-s, e))); }
            else want_y = g_sent_yaw;
            if (now - g_aim_cam_t < 0.5) { g_pitch_ref += want_p - g_sent_pitch; want_p = g_sent_pitch + g_aim_push_p; }
            else {   // (no game camera read: the pitch cone against the sent pitch, as yaw's)
                float ep = want_p - g_sent_pitch;
                want_p = ep > g_aim_cone_p ? want_p - g_aim_cone_p : ep < -g_aim_cone_p ? want_p + g_aim_cone_p : g_sent_pitch;
            }
            g_aim_push_p = 0;
        }
        if (a != g_aim_was) { g_aim_was = a; g_aim_push_p = 0; if (!a) g_rebase_due = 1;
            if (vx_host_jlog) { char f[96]; snprintf(f, sizeof f, "\"on\":%d,\"cone\":[%.0f,%.0f]", a, g_aim_cone_y, g_aim_cone_p); vx_host_jlog("aim_mode", f); } }
    }
    g_yaw_ref = wrap180(g_yaw_ref - g_hand_aim_y); g_pitch_ref -= g_hand_aim_p;
    g_hand_aim_y = g_hand_aim_p = 0;
    // (h43: the game's pitch limits - VXMAC_PITCH_LIMIT, else 80, narrowed when the picture stops pitching while the
    //  sent pitch goes on (vx_xros_vr_seen_turn2): never sent beyond them, so the game's pitch and the head's stay one)
    if (want_p > g_pitch_hi) want_p = g_pitch_hi; if (want_p < g_pitch_lo) want_p = g_pitch_lo;
    float dy = wrap180(want_y - g_sent_yaw), dp = want_p - g_sent_pitch;
    if (now < g_freeze_until[0]) dy = 0;                  // (h48: an axis the game ignores now is not sent - nothing piles up)
    if (now < g_freeze_until[1]) dp = 0;
    int cx = (int)lroundf(-dy * C.cpd), cy = (int)lroundf(-dp * C.cpd_y);   // (left turn: mouse left; head up: mouse up)
    if (send && (cx || cy)) {
        g_sent_yaw = wrap180(g_sent_yaw - cx / C.cpd); g_sent_pitch -= cy / C.cpd_y;
        vx_raw_mouse(cx, cy, 0, 0);
        g_mouse_counts += abs(cx) + abs(cy);
        unsigned long q = ++g_send_seq; g_sendq[q % 1024] = (send_rec){ q, g_sent_yaw, g_sent_pitch };
    }
    g_sent_hist[g_sent_n++ % 256] = (sent_pose){ now, g_sent_yaw, g_sent_pitch };
}
static int sent_at(double t, float *yaw, float *pitch) {   // (the pose sent by time t; with g_lock held)
    int got = 0;
    for (unsigned k = 0; k < 256 && k < g_sent_n; k++) {
        const sent_pose *e = &g_sent_hist[(g_sent_n - 1 - k) % 256];
        *yaw = e->yaw; *pitch = e->pitch; got = 1;
        if (e->t <= t) break;
    }
    return got;
}

// ---- vr mode's calibration (VXRT_VR_CALIBRATE=1, unless VXRT_VR_COUNTS_PER_DEG is given): the camera's turn between
// two game frames seen in the motion vectors (the median of a strip through the middle of the picture: the far
// scene, mostly the camera's own turn), against the turns sent by then, for several input latencies. Every ~3 s of
// turning: the latency that fits best, and the counts a degree that make the game turn as far as the head
// (applied when the fit is good: correlation 0.7 or more). Logged (host_log "vr_calibration", vxrt.log).
static const double kLags[] = { 0, 0.011, 0.022, 0.033, 0.044, 0.056, 0.067, 0.089, 0.111, 0.133, 0.178, 0.222 };
#define NLAGS (sizeof kLags / sizeof *kLags)
typedef struct { double sxy[NLAGS], sxx[NLAGS], syy[NLAGS]; } cal_sums;
static struct { cal_sums yaw, pitch; unsigned n, rounds; double prev_t; float last_gain, last_corr, last_gain_y, last_corr_y; } g_cal;
static int cmpf(const void *a, const void *b) { float x = *(const float *)a, y = *(const float *)b; return x < y ? -1 : x > y; }
static int cal_best(const cal_sums *c, double *corr) {
    int best = -1; double bc = 0;
    for (unsigned l = 0; l < NLAGS; l++) {
        double r = c->sxx[l] > 0 && c->syy[l] > 0 ? c->sxy[l] / sqrt(c->sxx[l] * c->syy[l]) : 0;
        if (best < 0 || fabs(r) > fabs(bc)) { bc = r; best = (int)l; }
    }
    *corr = bc;
    return best;
}
// (a factor for counts/deg from a fit: the game turns gain degrees a degree sent; applied in steps of at most 2x)
static float cal_factor(double gain, double corr, int *applied) {
    *applied = 0;
    if (fabs(corr) < 0.7 || fabs(gain) < 0.05) return 1;
    double f = 1 / fabs(gain);
    if (f > 2) f = 2; if (f < 0.5) f = 0.5;
    if (fabs(f - 1) <= 0.06) return 1;
    *applied = 1;
    return (float)f;
}
// (VX Mac: the game must also take the head: two calibration rounds in a row with the sent turns not in its motion
//  (|yaw correlation| < 0.2) hand the picture back to the world-locked panel, for 20 s, then 60, 180... (menus,
//  character creation and cutscenes render 3D but ignore the mouse; the picture must never be head-locked there))
static double g_nocontrol_until, g_nocontrol_for = 20; static int g_cal_fail, g_nocontrol_strong;
// (VX Mac, h54: the automatic screen for a game that ignores the head (cutscenes) can be turned off - VXMAC_AUTO_SCREEN=0,
//  or remembered from the user's manual toggle: VR forced while that screen shows -> off; Screen forced in VR -> on
//  (NSUserDefaults vxmac_auto_screen). Off: vr mode stays (world-locked reprojection, the game's own pitch), and while
//  the game ignores the head nothing is sent - the head's moves go into the zero (no pile-up, no catch-up after))
static int g_auto_screen = -1; static double g_ignore_until;
static int auto_screen(void) {
    if (g_auto_screen < 0) {
        const char *e = getenv("VXMAC_AUTO_SCREEN");
        if (e && *e) g_auto_screen = atoi(e) != 0;
        else { id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"vxmac_auto_screen"]; g_auto_screen = v ? [v boolValue] : 1; }
        vx_log("VR: automatic screen for cutscenes %s", g_auto_screen ? "on" : "off (VR stays)");
    }
    return g_auto_screen;
}
static void set_auto_screen(int on) {
    g_auto_screen = on; [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"vxmac_auto_screen"];
    vx_log("VR: automatic screen for cutscenes %s (remembered)", on ? "on" : "off");
}
static void nocontrol(double t, double for_s) {   // (the game does not follow the head: the panel, or with it off the hold)
    if (auto_screen()) g_nocontrol_until = t + for_s;
    else { g_ignore_until = t + 4; if (vx_host_jlog) vx_host_jlog("ignore_hold", "\"s\":4"); }
}
// (VX Mac: the game's camera also turns by a controller's stick, which the head knows nothing of: the image check
//  measures each frame's turn, and what the sent mouse does not explain goes here - the warp poses the frame where the
//  game's camera really was; vr mode's mouse is not touched by it (it keeps following the head))
void vx_xros_vr_add_camera_offset(float dyaw, float dpitch) {
    pthread_mutex_lock(&g_lock);
    g_cam_off_yaw = wrap180(g_cam_off_yaw + dyaw); g_cam_off_pitch += dpitch;
    if (g_cam_off_pitch > 80) g_cam_off_pitch = 80; if (g_cam_off_pitch < -80) g_cam_off_pitch = -80;
    pthread_mutex_unlock(&g_lock);
}
float vx_xros_vr_sent_pitch(void) { return g_sent_pitch; }
int vx_game_mouse_look(void);   // (VX Mac glue: the game's mouse look is on)
// (VX Mac: for the host's image-based check (no motion vectors on the Mac route): the yaw sent so far (degrees,
//  wrapped), whether vr mode drives the camera now, the game's frame tangent, and the verdict "the game does not
//  follow the head": the panel for the backoff above)
float vx_xros_vr_sent_yaw(void) { return g_sent_yaw; }
int vx_xros_vr_driving(void) { return vr_now(); }
float vx_xros_vr_game_tan_x(void) { config(); return g_game_tan[0] > 0 ? g_game_tan[0] : g_tan_x_h > 0 ? g_tan_x_h : C.tan_y * (g_back_h ? (float)g_back_w / g_back_h : 16.f / 9.f); }
// (VX Mac, h29: the game's own camera. libvxmtl finds rotation matrices in the constants of the scene passes; each
//  one gives 12 readings (any of its 3 rows or 3 columns as the view axis, with Y or Z up: yaw and elevation). Each
//  reading is a tracker; per pair of frames its turn is compared with the picture's measured turn. One with
//  correlation 0.9 or more and a scale within 0.7-1.4 over 120 turning frames is the game's camera: from then on each
//  frame's camera is that reading (sign and offset matched to the sent pose), not a guess from the input.
//  VXMAC_CAM_SRC=0: off (the input-based stamp).)
typedef struct { uint32_t key; int var; float yaw[64], pitch[64]; uint64_t at[64]; double sxy, sxx, syy, pxy, pxx, pyy; unsigned n, pn; } cam_tracker;
static cam_tracker g_ct[192]; static int g_nct;
static double g_cam_src_log;
void vx_xros_vr_cam_candidates(uint64_t pseq, const void *cands_, int n) {
    typedef struct { uint32_t key; float m[16]; } cand;
    const cand *c = cands_;
    if (g_cam_src_on < 0) { const char *e = getenv("VXMAC_CAM_SRC"); g_cam_src_on = !(e && !strcmp(e, "0")); }
    if (!g_cam_src_on) return;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < n; i++) {
        for (int v = 0; v < 12; v++) {
            int ax = v % 6, zup = v / 6; float a[3];
            for (int j = 0; j < 3; j++) a[j] = ax < 3 ? c[i].m[ax * 4 + j] : c[i].m[j * 4 + (ax - 3)];
            float up = zup ? a[2] : a[1], h0 = a[0], h1 = zup ? a[1] : a[2];
            float yaw = atan2f(h1, h0) * 180 / (float)M_PI, pit = asinf(fmaxf(-1.f, fminf(1.f, up))) * 180 / (float)M_PI;
            int t = -1;
            for (int k = 0; k < g_nct; k++) if (g_ct[k].key == c[i].key && g_ct[k].var == v) { t = k; break; }
            if (t < 0 && g_nct < 192) t = g_nct++;
            else if (t < 0) {   // (h29: full - the table filled with the first frames' matrices and later ones were never
                                //  tracked: the one unseen for longest (not the camera in use) gives its place)
                uint64_t oldest = UINT64_MAX;
                for (int k = 0; k < g_nct; k++) { uint64_t last = 0; for (int q = 0; q < 64; q++) if (g_ct[k].at[q] > last) last = g_ct[k].at[q];
                    if (k != g_cam_src && last < oldest && pseq - last > 30) { oldest = last; t = k; } }
                if (t < 0) continue;
            }
            if (g_ct[t].key != c[i].key || g_ct[t].var != v) { memset(&g_ct[t], 0, sizeof g_ct[t]); g_ct[t].key = c[i].key; g_ct[t].var = v; }
            g_ct[t].yaw[pseq % 64] = yaw; g_ct[t].pitch[pseq % 64] = pit; g_ct[t].at[pseq % 64] = pseq;
        }
    }
    pthread_mutex_unlock(&g_lock);
}
static int cam_src_now(uint64_t pseq, float *yaw, float *pitch) {   // (with g_lock held)
    if (g_cam_src < 0) return 0;
    cam_tracker *t = &g_ct[g_cam_src];
    if (t->at[pseq % 64] != pseq) return 0;
    *yaw = g_cam_sy * t->yaw[pseq % 64]; *pitch = g_cam_sp * t->pitch[pseq % 64];
    return 1;
}
static void cam_src_seen(uint64_t pseq, float sx, float sy) {   // (with g_lock held)
    if (pseq < 2) return;
    for (int k = 0; k < g_nct; k++) {
        cam_tracker *t = &g_ct[k];
        if (t->at[pseq % 64] != pseq || t->at[(pseq - 1) % 64] != pseq - 1) continue;
        float d = wrap180(t->yaw[pseq % 64] - t->yaw[(pseq - 1) % 64]), dp = t->pitch[pseq % 64] - t->pitch[(pseq - 1) % 64];
        if (fabsf(sx) > 0.2f || fabsf(d) > 0.2f) { t->sxy += (double)sx * d; t->sxx += (double)d * d; t->syy += (double)sx * sx; t->n++; }
        if (fabsf(sy) > 0.2f || fabsf(dp) > 0.2f) { t->pxy += (double)sy * dp; t->pxx += (double)dp * dp; t->pyy += (double)sy * sy; t->pn++; }
    }
    double now = CACurrentMediaTime();
    if (now - g_cam_src_log < 5) return;
    g_cam_src_log = now;
    int best = -1; double bc = 0;
    for (int k = 0; k < g_nct; k++) {
        cam_tracker *t = &g_ct[k];
        if (t->n < 120 || t->sxx <= 0 || t->syy <= 0) continue;
        double corr = t->sxy / sqrt(t->sxx * t->syy), sc = t->sxy / t->sxx;
        if (fabs(corr) > bc && fabs(sc) > 0.7 && fabs(sc) < 1.4) { bc = fabs(corr); best = k; }
    }
    if (best < 0) { if (vx_host_jlog) { char f[96]; snprintf(f, sizeof f, "\"trackers\":%d,\"found\":0", g_nct); vx_host_jlog("vr_cam_src", f); } return; }
    cam_tracker *t = &g_ct[best];
    double sc = t->sxy / t->sxx, pc = t->pxx > 0 && t->pyy > 0 ? t->pxy / sqrt(t->pxx * t->pyy) : 0, psc = t->pxx > 0 ? t->pxy / t->pxx : 0;
    char f[300];
    snprintf(f, sizeof f, "\"trackers\":%d,\"key\":%u,\"var\":%d,\"corr\":%.3f,\"scale\":%.3f,\"frames\":%u,\"pitch_corr\":%.3f,\"pitch_scale\":%.3f,\"used\":%d",
             g_nct, t->key, t->var, bc, sc, t->n, pc, psc, bc >= 0.9);
    if (vx_host_jlog) vx_host_jlog("vr_cam_src", f);
    if (bc >= 0.9 && best != g_cam_src) {
        g_cam_src = best; g_cam_sy = sc < 0 ? -1 : 1; g_cam_pitch_ok = fabs(pc) >= 0.7; g_cam_sp = psc < 0 ? -1 : 1; g_cam_off_ok = 0;
        vx_log("VR: the game's camera found in its constants (key %u, reading %d): turn correlation %.3f, scale %.3f; pitch %s", t->key, t->var, bc, sc, g_cam_pitch_ok ? "too" : "from the input");
    }
}
// (host.m's image check: frame pseq's measured turn against the frame before (degrees, the sent yaw's sign))
void vx_xros_vr_seen_turn2(uint64_t pseq, float seen, float seen_y) {
    pthread_mutex_lock(&g_lock); cam_src_seen(pseq, seen, seen_y);
    if (pseq >= 1 && g_stamp_at[pseq % 64] == pseq && g_stamp_at[(pseq - 1) % 64] == pseq - 1) {
        // (mode 4: this frame's camera = the frame before's + the picture's measured turn, drawn 5 % a frame toward the
        //  input-based stamp (no drift); the slot showing it takes the new pose for the rest of its display)
        if (g_warp_mode == 4) {
            float y = g_stamp_y[(pseq - 1) % 64] + seen, pc = g_stamp_p[(pseq - 1) % 64] + seen_y;
            y += 0.05f * wrap180(g_stamp_cons_y[pseq % 64] - y);
            g_stamp_y[pseq % 64] = y; g_stamp_p[pseq % 64] = pc;
            for (int k = 0; k < 3; k++) if (g_slot[k].pseq == pseq && g_slot[k].head_valid)
                camera_pose(g_yaw_ref + y + g_cam_off_yaw, g_pitch_ref + pc + g_cam_off_pitch, g_slot[k].head, g_slot[k].head);
        }
        {   // (h37: step traces - after a turn stops (5 frames over 0.8 deg a frame, then one under 0.15), the next 12 frames'
            //  input-based turn and the picture's measured turn; also after a turn starts. A camera that lags or smooths the
            //  input shows the picture still turning after the input stopped. Logged as step_trace, 20 at most)
            static float hist[6]; static int trace = 0, kind = 0, logged = 0; static float tr_sent[12], tr_seen[12];
            float d = wrap180(g_stamp_cons_y[pseq % 64] - g_stamp_cons_y[(pseq - 1) % 64]);
            int was_moving = 1, was_still = 1;
            for (int i = 0; i < 5; i++) { if (fabsf(hist[i]) < 0.8f) was_moving = 0; if (fabsf(hist[i]) > 0.15f) was_still = 0; }
            if (!trace && logged < 20) {
                if (was_moving && fabsf(d) < 0.15f) { trace = 1; kind = 0; }
                else if (was_still && fabsf(d) > 0.8f) { trace = 1; kind = 1; }
            }
            if (trace) {
                tr_sent[trace - 1] = d; tr_seen[trace - 1] = seen;
                if (++trace > 12) {
                    char f[600]; size_t l = 0;
                    l += snprintf(f + l, sizeof f - l, "\"kind\":\"%s\",\"sent\":[", kind ? "start" : "stop");
                    for (int i = 0; i < 12; i++) l += snprintf(f + l, sizeof f - l, "%s%.2f", i ? "," : "", tr_sent[i]);
                    l += snprintf(f + l, sizeof f - l, "],\"seen\":[");
                    for (int i = 0; i < 12; i++) l += snprintf(f + l, sizeof f - l, "%s%.2f", i ? "," : "", tr_seen[i]);
                    snprintf(f + l, sizeof f - l, "]");
                    if (vx_host_jlog) vx_host_jlog("step_trace", f);
                    trace = 0; logged++;
                }
            }
            memmove(hist + 1, hist, 5 * sizeof *hist); hist[0] = d;
        }
    }
    if (pseq >= 6 && g_yk_ok[pseq % 64][1] && g_yk_ok[(pseq - 1) % 64][1]) {
        // (h48: per axis, at any angle - the response collapsing (sent > 0.5 deg a frame, the picture under 15 % of it, 6
        //  frames: a dialogue's look cone, a clamp) or the picture moving on its own (over 1 deg a frame with under 0.2
        //  sent, 6 frames: a cutscene's camera): that axis is not sent for 1 s and the last 6 frames' sent turn taken back,
        //  so the game's camera and the head stay one; logged axis_freeze)
        static int stuck[2], own[2];
        float sent[2] = { wrap180(g_yk[pseq % 64][1][0] - g_yk[(pseq - 1) % 64][1][0]), g_yk[pseq % 64][1][1] - g_yk[(pseq - 1) % 64][1][1] };
        float seen2[2] = { seen, seen_y };
        double tnow = CACurrentMediaTime();
        // (h64: the pitch from the game's own camera when both frames have it; the gate holds "camera moves itself")
        int cam_p = combat_gate_on() && g_gp_seq[pseq % 64] == pseq && g_gp_seq[(pseq - 1) % 64] == pseq - 1;
        if (cam_p) seen2[1] = g_gp_of[pseq % 64] - g_gp_of[(pseq - 1) % 64];
        int gate = combat_gate(tnow);
        for (int a = 0; a < 2; a++) {
            if (fabsf(sent[a]) > 0.5f && fabsf(seen2[a]) < 0.15f * fabsf(sent[a])) stuck[a]++; else stuck[a] = 0;
            if (fabsf(seen2[a]) > 1.0f && fabsf(sent[a]) < 0.2f) own[a]++; else own[a] = 0;
            if (gate && own[a] >= 6 && stuck[a] < 6) { own[a] = 0; g_gated_freezes++; continue; }
            if (aim_on() && a == 1) { stuck[a] = own[a] = 0; continue; }   // (mode 7: the stick pitches the game; the head's pitch is not sent)
            if ((stuck[a] >= 6 || own[a] >= 6) && tnow >= g_freeze_until[a]) {
                if (stuck[a] >= 6 && g_yk_ok[(pseq - 6) % 64][1]) {
                    float back = a == 0 ? wrap180(g_yk[pseq % 64][1][0] - g_yk[(pseq - 6) % 64][1][0]) : g_yk[pseq % 64][1][1] - g_yk[(pseq - 6) % 64][1][1];
                    if (a == 0) g_sent_yaw = wrap180(g_sent_yaw - back); else g_sent_pitch -= back;
                }
                g_freeze_until[a] = tnow + 1.0;
                if (vx_host_jlog) { char f[200]; snprintf(f, sizeof f, "\"axis\":\"%s\",\"why\":\"%s\",\"src\":\"%s\",\"sent\":%.2f,\"seen\":%.2f,\"combat\":%d,\"fov\":%.1f", a ? "pitch" : "yaw", stuck[a] >= 6 ? "no response" : "camera moves itself",
                                             a && cam_p ? "camera" : "picture", sent[a], seen2[a], g_combat_bits, g_game_hfov); vx_host_jlog("axis_freeze", f); }
                stuck[a] = own[a] = 0;
            }
        }
    }
    if (pseq >= 1 && g_yk_ok[pseq % 64][1] && g_yk_ok[(pseq - 1) % 64][1]) {   // (h43: the game's pitch limit and offset)
        float dpi = g_yk[pseq % 64][1][1] - g_yk[(pseq - 1) % 64][1][1], cur = g_yk[pseq % 64][1][1];
        static int stuck;
        if (fabsf(dpi) > 0.5f) {
            g_pitch_off = g_pitch_off * 0.98f + (seen_y - dpi);   // (the picture's pitch against the sent, summed with a slow decay)
            if (fabsf(cur) > 25 && fabsf(seen_y) < 0.15f * fabsf(dpi) && (cur > 0) == (dpi > 0)) stuck++; else stuck = 0;
            if (stuck >= 6 && !pitch_learn_old() && g_gp_seq[pseq % 64] == pseq) stuck = 0;   // (h64: the game's own pitch is known: no limit learned)
            if (stuck >= 6) {   // (the game stopped pitching: its limit is about where it stopped)
                float lim = cur - dpi * 6;
                if (cur > 0 && lim < g_pitch_hi) { g_pitch_hi = lim; g_sent_pitch = fminf(g_sent_pitch, lim); }
                if (cur < 0 && lim > g_pitch_lo) { g_pitch_lo = lim; g_sent_pitch = fmaxf(g_sent_pitch, lim); }
                vx_log("VR: the game's pitch stops at %.1f deg: the sent pitch kept within it (limits %.1f / %.1f)", lim, g_pitch_lo, g_pitch_hi);
                if (vx_host_jlog) { char f[96]; snprintf(f, sizeof f, "\"limit\":%.1f,\"lo\":%.1f,\"hi\":%.1f", lim, g_pitch_lo, g_pitch_hi); vx_host_jlog("pitch_clamp", f); }
                stuck = 0;
            }
        }
    }
    if (pseq >= 1 && g_yk_ok[pseq % 64][1] && g_yk_ok[(pseq - 1) % 64][1]) {   // (did a sent turn show in the picture?)
        float d = fabsf(wrap180(g_yk[pseq % 64][1][0] - g_yk[(pseq - 1) % 64][1][0]));
        if (d > 0.5f) g_follow_ema = g_follow_ema * 0.9f + (fabsf(seen) > 0.2f ? 0.1f : 0.0f);
    }
    pthread_mutex_unlock(&g_lock);
    void vx_xros_vr_seen_turn(uint64_t, float); vx_xros_vr_seen_turn(pseq, seen);
}
void vx_xros_vr_seen_turn(uint64_t pseq, float seen) {
    pthread_mutex_lock(&g_lock);
    int any = 0;
    for (int k = 0; k < 4; k++) {
        if (!g_yk_ok[pseq % 64][k] || !g_yk_ok[(pseq - 1) % 64][k]) continue;
        float pred = wrap180(g_yk[pseq % 64][k][0] - g_yk[(pseq - 1) % 64][k][0]);
        g_k_err[k] += (double)(seen - pred) * (seen - pred); any = 1;
    }
    if (any && fabsf(seen) > 0.2f && ++g_k_n >= 90) {
        int best = 0; for (int k = 1; k < 4; k++) if (g_k_err[k] < g_k_err[best]) best = k;
        vx_log("VR: the frame's camera: K %d (squared error a frame by K 0-3: %.2f %.2f %.2f %.2f)%s", best, g_k_err[0] / g_k_n, g_k_err[1] / g_k_n,
               g_k_err[2] / g_k_n, g_k_err[3] / g_k_n, g_cam_k_fixed < 4 ? " - fixed by VXMAC_CAM_K" : "");
        if (vx_host_jlog) { char f[200]; snprintf(f, sizeof f, "\"k\":%d,\"err\":[%.2f,%.2f,%.2f,%.2f]", best, g_k_err[0] / g_k_n, g_k_err[1] / g_k_n, g_k_err[2] / g_k_n, g_k_err[3] / g_k_n); vx_host_jlog("vr_cam_k", f); }
        if (g_cam_k_fixed >= 4) g_cam_k = best;
        for (int k = 0; k < 4; k++) g_k_err[k] *= 0.5; g_k_n /= 2;
    }
    pthread_mutex_unlock(&g_lock);
}
static int g_zero_run;   // (VX Mac, h47: follow windows in a row with no response at all)
void vx_xros_vr_follow_verdict(int follows, float gain, float sent_deg) {
    double t = CACurrentMediaTime();
    g_zero_run = gain < 0.05f ? g_zero_run + 1 : 0;
    if (follows) {
        g_cal_fail = 0; g_nocontrol_for = 20;
        // (the picture turned, by gain x the head's turn: counts per degree scaled toward 1, at most x2 / x0.5 a window)
        // (h17: 17.4 -> 34.8 -> 28.2 -> 14.6 from single windows: now only windows of 15 degrees or more count, two in a
        //  row must miss the same way, and a step is at most x1.25)
        // (h28: off unless VXMAC_VR_TUNE=1 - |seen| against |sent| summed per window reads low when the per-frame turns
        //  are uneven (17.4 -> 21.75 -> 27.2 in h26-h27), and a raised count over-turned the game: a snap at each frame)
        static int tune = -1; if (tune < 0) { const char *e = getenv("VXMAC_VR_TUNE"); tune = e && !strcmp(e, "1"); }
        if (!tune) return;
        static int last_dir;
        int dir = !(sent_deg >= 15) || gain <= 0.25f || gain >= 4.0f ? 0 : gain < 0.85f ? -1 : gain > 1.2f ? 1 : 0;
        if (dir && dir == last_dir) {
            float f = 1.0f / gain; if (f > 1.25f) f = 1.25f; if (f < 0.8f) f = 0.8f;
            float before = C.cpd; C.cpd *= f; C.cpd_y *= f;
            vx_log("VR: the picture turned %.2f x the head twice: counts a degree %.1f -> %.1f", gain, before, C.cpd);
            dir = 0;
        }
        last_dir = dir;
        return;
    }
    // (h45: three windows in a row while the game's mouse look is on - a cutscene that ignores the mouse: the frame
    //  world-locked until it follows again (h44's tilt: pitch sent through a cutscene the game ignored))
    // (h47: with the mouse look on, only on six windows in a row (~9 s) of no response at all (gain under 0.05) - a
    //  vehicle's orbiting camera follows partly and stays in vr mode (h46 left vr mode on a bike's jump))
    if (++g_cal_fail >= 2) {
        g_nocontrol_strong = g_zero_run >= 6;
        if (g_look_hold && !g_nocontrol_strong) return;
        g_cal_fail = 0; nocontrol(t, g_nocontrol_for);
        vx_log("VR: the picture does not turn with the head (gain %.2f): %s for %.0f s", gain, auto_screen() ? "the world-locked panel" : "nothing sent (VR stays)", auto_screen() ? g_nocontrol_for : 4.0);
        if (g_nocontrol_for < 600) g_nocontrol_for *= 3;
    }
}
static void calibrate_frame(vr_slot *S, double t) {
    uint32_t n = S->cal_n; if (n > 4096) n = 4096;
    static float xs[4096], ys[4096];
    const uint8_t *p = S->cal_buf.contents;
    uint32_t k = 0;
    for (uint32_t i = 0; i < n; i++) {
        float x = S->cal_bpp == 4 ? (float)((const __fp16 *)p)[i * 2] : ((const float *)p)[i * 2];
        float y = S->cal_bpp == 4 ? (float)((const __fp16 *)p)[i * 2 + 1] : ((const float *)p)[i * 2 + 1];
        if (isfinite(x) && isfinite(y)) { xs[k] = x; ys[k] = y; k++; }
    }
    double prev = g_cal.prev_t; g_cal.prev_t = t;
    if (k < 64 || prev <= 0 || t - prev > 0.5) return;
    qsort(xs, k, sizeof *xs, cmpf); qsort(ys, k, sizeof *ys, cmpf);
    // (the strip's raw units to the picture's: FSR2's motion vector scale, uv per unit; then the turn at the centre)
    float ux = xs[k / 2] * (S->mv_sx / (float)(S->w ? S->w : 1)), uy = ys[k / 2] * (S->mv_sy / (float)(S->h ? S->h : 1));
    float ox = atanf(2 * ux * S->tan_x) * 180 / (float)M_PI, oy = atanf(2 * uy * S->tan_y) * 180 / (float)M_PI;
    pthread_mutex_lock(&g_lock);
    float sy[NLAGS], sp[NLAGS];
    int ok = 1;
    for (unsigned l = 0; l < NLAGS && ok; l++) {
        float y1 = 0, y0 = 0, p1 = 0, p0 = 0;
        ok = sent_at(t - kLags[l], &y1, &p1) && sent_at(prev - kLags[l], &y0, &p0);
        sy[l] = wrap180(y1 - y0); sp[l] = p1 - p0;
    }
    pthread_mutex_unlock(&g_lock);
    if (!ok || fabsf(ox) > 30 || fabsf(oy) > 30) return;
    for (unsigned l = 0; l < NLAGS; l++) {
        g_cal.yaw.sxy[l] += ox * sy[l]; g_cal.yaw.sxx[l] += sy[l] * sy[l]; g_cal.yaw.syy[l] += ox * ox;
        g_cal.pitch.sxy[l] += oy * sp[l]; g_cal.pitch.sxx[l] += sp[l] * sp[l]; g_cal.pitch.syy[l] += oy * oy;
    }
    g_cal.n++;
    if (g_cal.n < 40 || g_cal.yaw.sxx[4] < 30) return;     // (enough turning: 30 deg^2 of frame-to-frame turns)
    double cy, cp;
    int by = cal_best(&g_cal.yaw, &cy), bp = cal_best(&g_cal.pitch, &cp);
    double gy = g_cal.yaw.sxy[by] / g_cal.yaw.sxx[by];
    double gp = g_cal.pitch.sxx[bp] > 5 ? g_cal.pitch.sxy[bp] / g_cal.pitch.sxx[bp] : 0;
    float before = C.cpd, before_y = C.cpd_y;
    int ay, ap;
    float fy = cal_factor(gy, cy, &ay), fp = g_cal.pitch.sxx[bp] > 5 ? cal_factor(gp, cp, &ap) : (ap = 0, 1);
    // (h5a jumped 27 -> 18 counts/deg between rounds: a change only when two rounds in a row agree (correlation 0.8 or
    //  more, factors within 15 % of each other), then half way, at most 1.3x, at most once in 20 s)
    {
        static float last_fy, last_fp; static double last_apply;
        int agree_y = ay && fabs(cy) >= 0.8 && last_fy > 0 && fabsf(fy / last_fy - 1) < 0.15;
        int agree_p = ap && fabs(cp) >= 0.8 && last_fp > 0 && fabsf(fp / last_fp - 1) < 0.15;
        last_fy = ay && fabs(cy) >= 0.8 ? fy : 0; last_fp = ap && fabs(cp) >= 0.8 ? fp : 0;
        if (t - last_apply < 20) agree_y = agree_p = 0;
        float sy2 = agree_y ? sqrtf(fy) : 1, sp2 = agree_p ? sqrtf(fp) : 1;
        if (sy2 > 1.3f) sy2 = 1.3f; if (sy2 < 1 / 1.3f) sy2 = 1 / 1.3f;
        if (sp2 > 1.3f) sp2 = 1.3f; if (sp2 < 1 / 1.3f) sp2 = 1 / 1.3f;
        if (getenv("VXMAC_MVCAL_APPLY")) { C.cpd *= sy2; C.cpd_y *= sp2; }   // (VX Mac: log only; the image check owns counts per degree)
        ay = agree_y; ap = agree_p;
        if (ay || ap) last_apply = t;
    }
    if (ay) g_input_lag_s = kLags[by];
    if (fabs(cy) < 0.2) {
        if (++g_cal_fail >= 2) {
            g_cal_fail = 0; nocontrol(t, g_nocontrol_for);
            vx_log("VR: the game does not follow the head (correlation %.2f): %s", cy, auto_screen() ? "the world-locked panel" : "nothing sent (VR stays)");
            if (g_nocontrol_for < 600) g_nocontrol_for *= 3;
        }
    } else { g_cal_fail = 0; g_nocontrol_for = 20; }
    g_cal.rounds++; g_cal.last_gain = (float)gy; g_cal.last_corr = (float)cy; g_cal.last_gain_y = (float)gp; g_cal.last_corr_y = (float)cp;
    vx_log("VR: calibration round %u: %u frames; yaw: latency %.0f ms, correlation %.2f, %.3f deg turned a degree sent, counts/deg %.2f -> %.2f; "
           "pitch: latency %.0f ms, correlation %.2f, %.3f, counts/deg %.2f -> %.2f", g_cal.rounds, g_cal.n, kLags[by] * 1e3, cy, gy, before, C.cpd,
           kLags[bp] * 1e3, cp, gp, before_y, C.cpd_y);
    if (vx_host_jlog) {
        char f[480];
        snprintf(f, sizeof f, "\"round\":%u,\"frames\":%u,\"yaw_latency_ms\":%.0f,\"yaw_correlation\":%.2f,\"yaw_game_deg_per_sent_deg\":%.3f,"
                 "\"counts_per_deg_before\":%.2f,\"counts_per_deg\":%.2f,\"yaw_applied\":%d,\"pitch_latency_ms\":%.0f,\"pitch_correlation\":%.2f,"
                 "\"pitch_game_deg_per_sent_deg\":%.3f,\"pitch_counts_per_deg\":%.2f,\"pitch_applied\":%d,\"input_lag_ms\":%.0f",
                 g_cal.rounds, g_cal.n, kLags[by] * 1e3, cy, gy, before, C.cpd, ay, kLags[bp] * 1e3, cp, gp, C.cpd_y, ap, g_input_lag_s * 1e3);
        vx_host_jlog("vr_calibration", f);
    }
    // (no label: it popped up over the view; host_log has each round)
    memset(&g_cal.yaw, 0, sizeof g_cal.yaw); memset(&g_cal.pitch, 0, sizeof g_cal.pitch); g_cal.n = 0;
}

// (VX Mac, h48: the game camera's pitch and roll against gravity from its own depth - the floor. Every 6th game frame in
//  vr mode a 32 x 16 grid over the frame's lower 60 % is unprojected to view space (x right, y up, z ahead); each cell's
//  normal from its neighbours; normals mostly "up" vote; with 60 or more agreeing within 3 degrees the floor's normal n
//  gives the camera's pitch (-atan2(n.z, n.y), up positive) and roll. That is the game's real pitch: against the pitch
//  we believe it has (the frame's stamp) the difference is put into the sent pitch, so the next send brings the game's
//  camera to the head's pitch. At most once each 1.5 s, at most 15 degrees. VXMAC_FLOOR=0: off. Logged floor_pitch.)
static NSString *const kFloorSrc = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct F { float tx, ty, za, zb; uint std_; };\n"
    "kernel void fl(texture2d<float> d [[texture(0)]], device float4 *o [[buffer(0)]], constant F &p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x >= 32 || g.y >= 16) return;\n"
    "    float2 uv = float2((g.x + 0.5f) / 32.0f, 0.4f + (g.y + 0.5f) / 16.0f * 0.6f);\n"
    "    uint2 px = min(uint2(uv * float2(d.get_width(), d.get_height())), uint2(d.get_width(), d.get_height()) - 1);\n"
    "    if (g.y == 0 && g.x < 5) { float2 q[5] = {float2(.5,.1),float2(.14,.72),float2(.515625,.86875),float2(.703125,.86875),float2(.765625,.94375)}; uint2 r = min(uint2(q[g.x] * float2(d.get_width(), d.get_height())), uint2(d.get_width(), d.get_height()) - 1); o[512 + g.x] = float4(d.read(r).r, 0, 0, 0); }\n"
    "    float dv = d.read(px).r; if (p.std_) dv = 1 - dv;\n"
    "    float z = abs(p.za / (dv - p.zb));\n"
    "    if (!isfinite(z) || z <= 0 || z > 1e4) { o[g.y * 32 + g.x] = float4(0); return; }\n"
    "    float2 nd = float2(uv.x * 2 - 1, 1 - uv.y * 2);\n"
    "    o[g.y * 32 + g.x] = float4(nd.x * p.tx * z, nd.y * p.ty * z, z, 1);\n"
    "}\n";
static id<MTLComputePipelineState> g_floor_pso; static int g_floor_on = -1; static double g_floor_last;
static float g_floor_pitch, g_floor_conf;
static pthread_mutex_t g_floor_lock = PTHREAD_MUTEX_INITIALIZER;
static id<MTLBuffer> g_floor_buf[2];
static unsigned g_floor_busy;
static void floor_fit(id<MTLCommandBuffer> cb, vr_slot *S, uint64_t pseq) {
    if (g_floor_on < 0) { const char *e = getenv("VXMAC_FLOOR"); g_floor_on = !(e && !strcmp(e, "0")); }
    if (!g_floor_on || !vr_now() || !S->has_depth || !S->depth || pseq % 6) return;
    if (!g_floor_pso) {
        NSError *err = nil;
        id<MTLLibrary> lib = [cb.device newLibraryWithSource:kFloorSrc options:nil error:&err];
        g_floor_pso = lib ? [cb.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fl"] error:&err] : nil;
        if (!g_floor_pso) { vx_log("VR: the floor fit: %s", err.localizedDescription.UTF8String); g_floor_on = 0; return; }
    }
    pthread_mutex_lock(&g_floor_lock);
    int slot = -1;
    for (int i = 0; i < 2; i++) if (!(g_floor_busy & (1u << i))) { slot = i; g_floor_busy |= 1u << i; break; }
    if (slot >= 0 && !g_floor_buf[slot]) g_floor_buf[slot] = [cb.device newBufferWithLength:517 * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> o = slot >= 0 ? g_floor_buf[slot] : nil;
    if (slot >= 0 && !o) g_floor_busy &= ~(1u << slot);
    pthread_mutex_unlock(&g_floor_lock);
    if (!o) return;
    struct { float tx, ty, za, zb; uint32_t std_; } P = { S->tan_x, S->tan_y, S->z_a, S->z_b, (S->flags & VXW_DEPTH_STD) ? 1u : 0u };
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    if (!e) { pthread_mutex_lock(&g_floor_lock); g_floor_busy &= ~(1u << slot); pthread_mutex_unlock(&g_floor_lock); return; }
    [e setComputePipelineState:g_floor_pso]; [e setTexture:S->depth atIndex:0]; [e setBuffer:o offset:0 atIndex:0]; [e setBytes:&P length:sizeof P atIndex:1];
    [e dispatchThreads:MTLSizeMake(32, 16, 1) threadsPerThreadgroup:MTLSizeMake(32, 16, 1)];
    [e endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> d) {
        if (d.status != MTLCommandBufferStatusCompleted) goto floor_done;
        const float *v = o.contents;
        if (!(P.std_) && v[512 * 4] > .85f) goto floor_done;
        float pit[512], rol[512]; int n = 0;
        for (int y = 0; y < 15; y++) for (int x = 0; x < 31; x++) {
            const float *a = v + (y * 32 + x) * 4, *b = v + (y * 32 + x + 1) * 4, *c = v + ((y + 1) * 32 + x) * 4;
            if (a[3] < 1 || b[3] < 1 || c[3] < 1) continue;
            float u[3] = { b[0] - a[0], b[1] - a[1], b[2] - a[2] }, w[3] = { c[0] - a[0], c[1] - a[1], c[2] - a[2] };
            float nn[3] = { u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0] };
            float l = sqrtf(nn[0] * nn[0] + nn[1] * nn[1] + nn[2] * nn[2]); if (l < 1e-9f) continue;
            for (int k = 0; k < 3; k++) nn[k] /= l;
            if (nn[1] < 0) for (int k = 0; k < 3; k++) nn[k] = -nn[k];
            if (nn[1] < 0.7f) continue;                    // (roughly up: a floor, not a wall)
            pit[n] = -atan2f(nn[2], nn[1]) * 180 / (float)M_PI; rol[n] = atan2f(-nn[0], nn[1]) * 180 / (float)M_PI; n++;
        }
        {   // (h49: why no fit - the valid points, the up-facing normals and a sample point, every 10 s)
            static double lt; double tn = CACurrentMediaTime();
            if (tn - lt > 10) { lt = tn; int valid = 0; for (int k = 0; k < 512; k++) if (v[k * 4 + 3] >= 1) valid++;
                const float *m = v + (12 * 32 + 16) * 4;
                vx_log("VR: floor fit: %d valid points, %d up-facing normals; sample (%.2f %.2f %.2f) w %.0f", valid, n, m[0], m[1], m[2], m[3]);
                vx_log("VR: depth samples raw sky %.6f left %.6f center %.6f right %.6f low-right %.6f; za %.6f zb %.6f std %u", v[512*4], v[513*4], v[514*4], v[515*4], v[516*4], P.za, P.zb, P.std_); }
        }
        if (n < 60) { g_floor_conf = (float)n / 450.f; goto floor_done; }
        // (the median, and how many lie within 3 degrees of it)
        float tmp[512]; memcpy(tmp, pit, n * sizeof *pit);
        for (int i = 1; i < n; i++) { float t = tmp[i]; int j = i - 1; while (j >= 0 && tmp[j] > t) { tmp[j + 1] = tmp[j]; j--; } tmp[j + 1] = t; }
        float med = tmp[n / 2]; int agree = 0; for (int i = 0; i < n; i++) if (fabsf(pit[i] - med) < 3) agree++;
        (void)rol;
        g_floor_pitch = med; g_floor_conf = (float)agree / 450.f;
        if (agree < 60) goto floor_done;
        pthread_mutex_lock(&g_lock);
        double t = CACurrentMediaTime();
        if (g_stamp_at[pseq % 64] == pseq && t - g_floor_last > 1.5) {
            float delta = med - g_stamp_p[pseq % 64];
            if (fabsf(delta) > 2 && fabsf(delta) < 40) {
                if (delta > 15) delta = 15; if (delta < -15) delta = -15;
                g_sent_pitch += delta; g_floor_last = t;
                if (vx_host_jlog) { char f[160]; snprintf(f, sizeof f, "\"floor_pitch_deg\":%.1f,\"believed_deg\":%.1f,\"corrected_deg\":%.1f,\"agree\":%d", med, g_stamp_p[pseq % 64], delta, agree); vx_host_jlog("floor_pitch", f); }
            }
        }
        pthread_mutex_unlock(&g_lock);
    floor_done:
        pthread_mutex_lock(&g_floor_lock); g_floor_busy &= ~(1u << slot); pthread_mutex_unlock(&g_floor_lock);
    }];
}
void vx_xros_vr_submit(void *cbp, void *backp, uint32_t w, uint32_t h, void (*release)(void *), void *arg) {
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
    id<MTLTexture> back = (__bridge id<MTLTexture>)backp;
    id<MTLDevice> dev = cb.device;
    config();
    double now = CACurrentMediaTime();
    pthread_mutex_lock(&g_lock);
    if (g_last_submit > 0 && now - g_last_submit > g_max_gap) g_max_gap = now - g_last_submit;
    if (g_last_submit > 0) { double d = now - g_last_submit; if (d > 0 && d < 0.5) g_interval = g_interval * 0.8 + d * 0.2;
        // (h60: the game frames' pacing - mean, spread and the longest, every 5 s, with the translation the warp applied)
        static double ps, pss, pmx, plog; static unsigned pn; static unsigned long over100;
        if (d > 0 && d < 1) { ps += d; pss += d * d; pn++; if (d > pmx) pmx = d; if (d > 0.1) over100++; }
        if (now - plog > 5 && pn > 5 && vx_host_jlog) { double m = ps / pn, sd = sqrt(fmax(0, pss / pn - m * m)); char f[200];
            snprintf(f, sizeof f, "\"mean_ms\":%.1f,\"sd_ms\":%.1f,\"max_ms\":%.0f,\"over100\":%lu,\"frames\":%u,\"move_mean_m\":%.3f", m * 1e3, sd * 1e3, pmx * 1e3, over100, pn, g_move_n ? g_move_sum / g_move_n : 0);
            vx_host_jlog("frame_pacing", f); ps = pss = pmx = 0; pn = 0; over100 = 0; plog = now; g_move_sum = 0; g_move_n = 0; } }
    g_last_gap = g_last_submit > 0 && now - g_last_submit > 0 && now - g_last_submit < 0.5 ? now - g_last_submit : 0;
    g_last_submit = now;
    g_back_w = w; g_back_h = h;
    {   // (VX Mac, h56: the game's own projection when libvxmtl reads it - the FOV it really renders with (2.5.0 reset it to
        //  80 under the settings' 110: stretched turns); the settings' value only until then. VXMAC_GAME_TAN=0: off)
        int vxmtl_game_tan(float *tx, float *ty); float tx, ty; static int on = -1;
        if (on < 0) { const char *e = getenv("VXMAC_GAME_TAN"); on = !(e && !strcmp(e, "0")); }
        if (on && vxmtl_game_tan(&tx, &ty) && tx > 0.1f && ty > 0.1f) {
            g_tan_x_h = tx; if (w && h) C.tan_y = ty;
            float hf = 2 * atanf(tx) * 180 / (float)M_PI;
            if (g_game_hfov > 0 && fabsf(hf - g_game_hfov) > 0.5f) g_fov_change_t = now;   // (h64: ADS's zoom, a vehicle's camera)
            g_game_hfov = hf;
        }
        else if (g_tan_x_h > 0 && w && h) C.tan_y = g_tan_x_h * (float)h / (float)w;   // (VX Mac, h31: the horizontal FOV kept at any aspect)
    }
    uint64_t pseq = ++g_present_seq;
    {   int vxmac_combat_input(void); int cb_bits = vxmac_combat_input();   // (h64: the triggers / mouse buttons, for the gate)
        if (cb_bits) g_combat_t = now;
        g_combat_bits = cb_bits; }
    int s = -1;
    for (int k = 0; k < 3 && s < 0; k++) if (k != g_held && k != g_newest && !g_slot[k].writing && !g_slot[k].readers) s = k;
    // (the scene's depth this frame, and the pick for the next)
    int had_depth = g_copies > 0 && g_hold;
    id<MTLBuffer> hold = g_hold; uint32_t dw = g_pick_w, dh = g_pick_h; MTLPixelFormat df = g_pick_fmt;
    int best = -1;
    for (int k = 0; k < g_ncand; k++) if (g_cand[k].draws) {
        id<MTLTexture> t = (__bridge id<MTLTexture>)g_cand[k].tex;
        id<MTLTexture> old = best >= 0 ? (__bridge id<MTLTexture>)g_cand[best].tex : nil;
        if (best < 0 || (t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 && old.pixelFormat != MTLPixelFormatDepth32Float_Stencil8) ||
            ((t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) == (old.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) && g_cand[k].draws > g_cand[best].draws)) best = k;
    }
    for (int k = 0; k < g_ncand && best >= 0; k++) {
        id<MTLTexture> t = (__bridge id<MTLTexture>)g_cand[k].tex;
        id<MTLTexture> b = (__bridge id<MTLTexture>)g_cand[best].tex;
        if (g_cand[k].tex == g_pick && t.pixelFormat == b.pixelFormat && g_cand[k].draws * 10 >= g_cand[best].draws * 6) { best = k; break; }
    }
    void *np = best >= 0 ? g_cand[best].tex : NULL;
    if (np != g_pick) {
        g_pick = np;
        if (np) {
            id<MTLTexture> t = (__bridge id<MTLTexture>)np;
            g_pick_w = (uint32_t)t.width; g_pick_h = (uint32_t)t.height; g_pick_fmt = t.pixelFormat;
            vx_log("VR: the scene's depth: %ux%u format %lu (%u depth-tested draws)", g_pick_w, g_pick_h, (unsigned long)g_pick_fmt, g_cand[best].draws);
        }
    }
    g_ncand = 0; g_copies = 0;
    int hold_index = g_hold_index; g_hold_index = -1; g_hold = nil;
    if (hold_index >= 0) [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        (void)done; pthread_mutex_lock(&g_lock); g_hold_busy &= ~(1u << hold_index); pthread_mutex_unlock(&g_lock);
    }];
    if (s >= 0) g_slot[s].writing = 1;
    float head[16]; memcpy(head, g_head, sizeof head);
    int head_valid = g_head_valid;
    {   // (VX Mac: this present's camera for each K, from the head's events the game had taken)
        g_cons[pseq % 64] = vx_head_consumed();
        for (int k = 0; k < 4; k++) {
            float y, pc;
            g_yk_ok[pseq % 64][k] = pseq > (uint64_t)k && sent_by_seq(g_cons[(pseq - k) % 64], &y, &pc);
            if (g_yk_ok[pseq % 64][k]) { g_yk[pseq % 64][k][0] = y; g_yk[pseq % 64][k][1] = pc; }
        }
        if (g_cam_k_fixed < 0) { const char *e = getenv("VXMAC_CAM_K"); g_cam_k_fixed = e && *e ? atoi(e) : 9; if (g_cam_k_fixed < 4) g_cam_k = g_cam_k_fixed; }
    }
    if (vr_now() && g_vr_ref) {                        // (the camera the game rendered: the moves it had about a frame ago)
        float y, pch, cons_y;
        int got = g_yk_ok[pseq % 64][g_cam_k];
        if (got) { y = g_yk[pseq % 64][g_cam_k][0]; pch = g_yk[pseq % 64][g_cam_k][1]; }
        else got = sent_at(now - g_input_lag_s, &y, &pch);
        cons_y = y;
        {   // (VX Mac, h29: the game's own camera when found: its reading, offset once to the input-based pose)
            float cy, cp;
            if (got && cam_src_now(pseq, &cy, &cp)) {
                if (!g_cam_off_ok) { g_cam_off_y = wrap180(y - cy); g_cam_off_p = pch - cp; g_cam_off_ok = 1; }
                y = wrap180(cy + g_cam_off_y);
                if (g_cam_pitch_ok) pch = cp + g_cam_off_p;
            }
        }
        {   // (VX Mac, h52: the frame's pitch is the game's own - its view matrix, read from its constants by libvxmtl
            //  (forward row, Z up): absolute against the horizon, so a pitch the game ignored (cutscenes, dialogue cones,
            //  its limits) no longer tilts the turn. The controller's share is in the game's pitch already: taken back out
            //  of the stamp below. Yaw stays the input's. VXMAC_GAME_CAM=0: off)
            uint64_t vxmtl_game_camera(float m[16]);
            static uint64_t last_q, last_q2; static double last_t, log_t, ylog_t; float gm[16];
            uint64_t q = got ? vxmtl_game_camera(gm) : 0;
            int fresh = 0;
            if (q && q != last_q) { last_q = q; last_t = now; fresh = 1; }
            static float resid; static int corr_on = -1;
            if (corr_on < 0) { const char *e = getenv("VXMAC_PITCH_CORR"); corr_on = !(e && !strcmp(e, "0")); }
            if (q && now - last_t < 0.25) {
                float gp = asinf(fmaxf(-1.f, fminf(1.f, gm[10]))) * 180 / (float)M_PI;
                float np = gp - g_pitch_ref - g_cam_off_pitch;
                // (h57d: does the game's camera follow the sent pitch? Over ~1 s windows with 2 deg or more sent: the game's
                //  pitch change against the sent one (regression gain); under 0.25 it does not follow (a vehicle camera),
                //  over 0.5 it does (on foot). Not following: the frame's pitch is drawn to the head's (input-based) with a
                //  0.3 s time constant and the closed loop stops (nothing piles up) - looking down on a bike no longer
                //  shows the area below the frame; following: back to the game's absolute pitch, same time constant)
                static float pgp, ppi, Kp; static double psxy, psxx, pwin, pkt; static int pfollow = 1;
                if (fresh) {
                    float pin = pch + g_pitch_ref, dg = gp - pgp, ds = pin - ppi;
                    // (h64: not while the gate holds (ADS's zoom sensitivity, recoil, aim assist), nor in mode 7 (the stick
                    //  pitches; the frame is the game's absolute pitch there))
                    int pgate = combat_gate(now) || aim_on();
                    if (pgate) { if (psxx > 0) g_gated_follow++; psxy = psxx = 0; pwin = now; if (aim_on()) pfollow = 1; }
                    if (!pgate && pkt > 0 && fabsf(ds) < 15 && fabsf(dg) < 15) { psxy += (double)dg * ds; psxx += (double)ds * ds; }
                    pgp = gp; ppi = pin;
                    g_gp_of[pseq % 64] = gp; g_gp_seq[pseq % 64] = pseq;   // (h64: for the axis checks)
                    if (now - pwin > 1.0) {
                        if (psxx > 4) { double gain = psxy / psxx; int was = pfollow; pfollow = gain > 0.5 ? 1 : gain < 0.25 ? 0 : pfollow;
                            if (was != pfollow && vx_host_jlog) { char f[80]; snprintf(f, sizeof f, "\"follows\":%d,\"gain\":%.2f", pfollow, gain); vx_host_jlog("pitch_follow", f); } }
                        psxy = psxx = 0; pwin = now;
                    }
                    double dt = pkt > 0 ? now - pkt : 0; pkt = now; if (dt > 0.5) dt = 0.5;
                    float target = pfollow ? 0 : pch - np;
                    Kp += (target - Kp) * (float)(1 - exp(-dt / 0.3));
                }
                {   // (h60: the game camera's position (from its view matrix) and velocity between game frames, smoothed;
                    //  a jump over 30 m/s (a cut, a teleport) zeroes it)
                    static float lp[3]; static double lt; static int lok;
                    if (fresh) {
                        float P[3]; for (int i = 0; i < 3; i++) P[i] = -(gm[3] * gm[i] + gm[7] * gm[4 + i] + gm[11] * gm[8 + i]);
                        double dt = now - lt;
                        if (lok && dt > 0.01 && dt < 0.3) {
                            float v[3], n = 0; for (int i = 0; i < 3; i++) { v[i] = (P[i] - lp[i]) / (float)dt; n += v[i] * v[i]; }
                            if (n > 900) for (int i = 0; i < 3; i++) g_cam_vel[i] = 0;
                            else for (int i = 0; i < 3; i++) g_cam_vel[i] = 0.5f * g_cam_vel[i] + 0.5f * v[i];
                        } else for (int i = 0; i < 3; i++) g_cam_vel[i] = 0;
                        memcpy(lp, P, sizeof P); lt = now; lok = 1;
                        for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) g_cam_rows[r * 3 + c] = gm[r * 4 + c];
                    }
                    g_cam_now_ok = 1;
                }
                {   // (h57f: vehicle mode from the camera's own motion, independent of the FOV setting - a first-person camera
                    //  turns about itself, a vehicle's third-person camera orbits a point metres in front of it: for frames where
                    //  the camera turned (over 0.5 deg), the pivot distance d that keeps p + d*f still (p its position, f its
                    //  view axis: least squares); the median of the last 15 over 2 m for 1 s -> vehicle, under 1 m for 1 s
                    //  -> on foot. VXMAC_VEHICLE=0 off; vehicle_signal logged every 5 s)
                    // (h64: entry also needs the pivot with the camera's own translation taken out - its velocity from the
                    //  recent frames that did not turn - over 1.5 m (strafing while turning gave |v / w|: 2-7 m on foot,
                    //  d.jsonl), 2 s of it, and not within the combat gate (triggers, mouse buttons, an FOV change); samples
                    //  across an FOV change are skipped. Leaving is as before. VXMAC_COMBAT_GATE=0: h57f's rule as it was)
                    static float pp[3], pf[3], ring[15], ring2[15], vh[3]; static int have, nr, veh_on = -1; static double hi_since, lo_since, slog, vt;
                    if (veh_on < 0) { const char *e = getenv("VXMAC_VEHICLE"); veh_on = !(e && !strcmp(e, "0")); }
                    if (fresh && veh_on) {
                        int gate_on = combat_gate_on();
                        float P[3], Fv[3] = { gm[8], gm[9], gm[10] };
                        for (int i = 0; i < 3; i++) P[i] = -(gm[3] * gm[i] + gm[7] * gm[4 + i] + gm[11] * gm[8 + i]);
                        double vdt = vt > 0 ? now - vt : 0; vt = now;
                        if (have && !(gate_on && now - g_fov_change_t < 0.5)) {
                            float df[3], dp[3], ff = 0, pf_ = 0;
                            for (int i = 0; i < 3; i++) { df[i] = Fv[i] - pf[i]; dp[i] = P[i] - pp[i]; ff += df[i] * df[i]; pf_ += dp[i] * df[i]; }
                            if (vdt > 0.005 && vdt < 0.3 && ff < 0.0035f * 0.0035f) for (int i = 0; i < 3; i++) vh[i] = 0.5f * vh[i] + 0.5f * dp[i] / (float)vdt;
                            if (vdt >= 0.3) for (int i = 0; i < 3; i++) vh[i] = 0;
                            if (ff > 0.0087f * 0.0087f) { float d = fabsf(-pf_ / ff);
                                if (d < 50) { float q = 0; for (int i = 0; i < 3; i++) q += (dp[i] - vh[i] * (float)(vdt < 0.3 ? vdt : 0)) * df[i];
                                    ring[nr % 15] = d; ring2[nr % 15] = -q / ff; nr++; } }
                        }
                        memcpy(pp, P, sizeof P); memcpy(pf, Fv, sizeof Fv); have = 1;
                        int n = nr < 15 ? nr : 15; float med = 0, med2 = 0;
                        if (n >= 5) { float t2[15]; memcpy(t2, ring, n * sizeof(float)); qsort(t2, n, sizeof(float), cmpf); med = t2[n / 2];
                                      memcpy(t2, ring2, n * sizeof(float)); qsort(t2, n, sizeof(float), cmpf); med2 = t2[n / 2]; }
                        int gated = gate_on && combat_gate(now);
                        int enter = n >= 5 && med > 2.0f && (!gate_on || med2 > 1.5f);
                        if (enter && gated) { if (hi_since) g_gated_vehicle++; enter = 0; }
                        if (enter) { if (!hi_since) hi_since = now; } else hi_since = 0;
                        if (n >= 5 && med < 1.0f) { if (!lo_since) lo_since = now; } else lo_since = 0;
                        int was = g_vehicle;
                        if (!g_vehicle && hi_since && now - hi_since > (gate_on ? 2.0 : 1.0)) g_vehicle = 1;
                        if (g_vehicle && lo_since && now - lo_since > 1.0) g_vehicle = 0;
                        if (was != g_vehicle) { vx_log("VR: vehicle mode %s (the camera's pivot %.1f m ahead, %.1f without its translation; FOV %.1f)", g_vehicle ? "on: no head pitch sent, the frame within 10 deg of the head's pitch" : "off", med, med2, g_game_hfov);
                            if (vx_host_jlog) { char f[160]; snprintf(f, sizeof f, "\"on\":%d,\"pivot_m\":%.2f,\"pivot_vc_m\":%.2f,\"fov\":%.1f,\"combat\":%d", g_vehicle, med, med2, g_game_hfov, g_combat_bits); vx_host_jlog("vehicle_mode", f); }
                            if (!g_vehicle && gate_on) g_rebase_due = 1; }
                        if (now - slog > 5 && vx_host_jlog) { slog = now; char f[240];
                            snprintf(f, sizeof f, "\"pivot_m\":%.2f,\"pivot_vc_m\":%.2f,\"samples\":%d,\"vehicle\":%d,\"fov\":%.1f,\"combat\":%d,\"gated_vehicle\":%lu,\"gated_freezes\":%lu,\"gated_follow\":%lu",
                                     med, med2, n, g_vehicle, g_game_hfov, g_combat_bits, g_gated_vehicle, g_gated_freezes, g_gated_follow);
                            vx_host_jlog("vehicle_signal", f); }
                    }
                }
                if (!g_vehicle) np += Kp;
                g_pitch_follows = pfollow && !g_vehicle;
                {   // (h57c: at most 25 deg from the input-based pitch; h57e: on a vehicle 10 - the frame's centre follows the head's
                    //  pitch within 10 deg, the vehicle camera's own pitch inside that)
                    float lim = g_vehicle ? 10.f : 25.f;
                    if (!aim_on() && fabsf(np - pch) > lim) { np = pch + (np > pch ? lim : -lim); g_pitch_clamps++; }   // (h64: mode 7 - the stick pitches: the game's own pitch, unclamped)
                }
                // (h52b: the loop closed on the game's true pitch - each new game frame, the head's pitch (the controller's
                //  share left out) against the game's: a quarter of the error, at most 3 deg a frame, outside 0.3 deg, is
                //  sent on top of the head's moves (the sent pitch's account moved by it, vr_mouse sends the difference),
                //  so the game's camera converges to the head's and the warp turns the frame by little. Not while the pitch
                //  axis is frozen, the game ignores the head (cinematic) or its mouse look is off. VXMAC_PITCH_CORR=0: off)
                if (fresh && g_head_valid) {
                    float hy, hp; head_angles(g_head, &hy, &hp);
                    float err = (hp - g_cam_off_pitch) - gp; resid = err;
                    if (aim_on()) {   // (h64: mode 7 - only past the cone's edge: half the excess a game frame, at most 4 deg)
                        float ex = fabsf(err) - g_aim_cone_p;
                        g_aim_cam_t = now;
                        if (ex > 0 && !g_vehicle && now >= g_nocontrol_until && now >= g_ignore_until && g_look_hold) { float c = 0.5f * ex; if (c > 4) c = 4; g_aim_push_p += err > 0 ? c : -c; }
                    }
                    else if (corr_on && g_pitch_follows && fabsf(err) > 0.3f && now >= g_freeze_until[1] && now >= g_nocontrol_until && now >= g_ignore_until && g_look_hold) {
                        float c = 0.25f * err; if (c > 3) c = 3; if (c < -3) c = -3;
                        g_sent_pitch -= c;
                    }
                }
                if (now - log_t > 5 && vx_host_jlog) { log_t = now; char f[240];
                    snprintf(f, sizeof f, "\"game_pitch\":%.2f,\"input_pitch\":%.2f,\"diff\":%.2f,\"roll\":%.2f,\"head_minus_game\":%.2f,\"corr\":%d", gp, g_pitch_ref + pch + g_cam_off_pitch, gp - (g_pitch_ref + pch + g_cam_off_pitch),
                             asinf(fmaxf(-1.f, fminf(1.f, gm[2]))) * 180 / (float)M_PI, resid, corr_on);
                    vx_host_jlog("game_cam", f); }
                pch = np;
                // (h57: the frame's yaw is the game's own too - the forward row's heading (Z up; positive = left, as the
                //  sent yaw), anchored once to the input-based pose at vr mode's zero (K = game - input, kept: stick turns
                //  and cinematic moves are in the game's heading already, so the frame is posed where its camera really
                //  was; the input's timing no longer decides it - h56's snap-back on turns). VXMAC_GAME_YAW=0: off)
                static int yaw_on = -1; static float K, yresid, ysign = 1; static int k_ok; static unsigned k_gen;
                if (yaw_on < 0) { const char *e = getenv("VXMAC_GAME_YAW"); yaw_on = !(e && !strcmp(e, "0")); const char *sgn = getenv("VXMAC_GAME_YAW_SIGN"); if (sgn && atoi(sgn) < 0) ysign = -1; }
                if (yaw_on) {
                    float gy = ysign * atan2f(gm[9], gm[8]) * 180 / (float)M_PI;
                    if (!k_ok || k_gen != g_ref_gen) { K = wrap180(gy - (y + g_cam_off_yaw)); k_ok = 1; k_gen = g_ref_gen;
                        vx_log("VR: the frame's yaw from the game's camera, anchored (offset %.1f deg)", K); }
                    {   // (the sign checked on the game's own turns: over frames where both the game's heading and the input-based
                        //  yaw moved 0.3 deg or more, they must turn the same way; 40 such frames disagreeing -> flipped, re-anchored)
                        static float pgy, pin; static int have, n_ag, n_dis;
                        float dg = wrap180(gy - pgy), di = wrap180((cons_y + g_cam_off_yaw) - pin);
                        if (have && fresh && fabsf(dg) > 0.3f && fabsf(di) > 0.3f && fabsf(dg) < 20) { if ((dg > 0) == (di > 0)) n_ag++; else n_dis++; }
                        if (fresh) { pgy = gy; pin = cons_y + g_cam_off_yaw; have = 1; }
                        if (n_ag + n_dis >= 40) {
                            if (n_dis > 3 * n_ag) { ysign = -ysign; gy = -gy; K = wrap180(gy - (cons_y + g_cam_off_yaw)); pgy = gy; vx_log("VR: the game's heading turns against the input (%d of %d frames): its sign flipped, re-anchored", n_dis, n_ag + n_dis); }
                            else vx_log("VR: the game's heading turns with the input in %d of %d frames", n_ag, n_ag + n_dis);
                            n_ag = n_dis = -100000;   // (decided once)
                        }
                    }
                    {   // (h64: the game's turn per sent turn, aiming (left trigger / right mouse button) and not: ADS's own
                        //  sensitivity, aim assist and snap show here; logged with game_cam_yaw)
                        static float lgy, lci; static int lh;
                        if (fresh) {
                            float dg = wrap180(gy - lgy), di = wrap180((cons_y + g_cam_off_yaw) - lci);
                            int vxmac_stick_active(void);
                            if (lh && fabsf(di) > 0.3f && fabsf(di) < 20 && fabsf(dg) < 20 && !vxmac_stick_active()) {
                                int ai = (g_combat_bits & 1) != 0; g_gain_sxy[ai] += (double)dg * di; g_gain_sxx[ai] += (double)di * di; g_gain_n[ai]++; }
                            lgy = gy; lci = cons_y + g_cam_off_yaw; lh = 1;
                        }
                    }
                    {   // (h57c: one rule, a complementary filter - the offset (game heading - input heading) follows its target
                        //  with a 0.6 s time constant, always (0.05 s while the right stick is out): a head turn's timing error
                        //  (under ~0.2 s) stays corrected by the game's heading (no snap-back, no haze), while any lasting camera
                        //  motion the head did not make - a vehicle camera recentring or following the bike, the stick,
                        //  cinematics, scripted turns - is absorbed and the frame stays in front. h57b's frozen offset let a
                        //  bike's camera push the picture around (71 deg at 185 s). VXMAC_YAW_TAU=<s>)
                        int vxmac_stick_active(void); static double kt, stick_t, settle_t; static float tau = -1, pgy2; static int settling;
                        if (tau < 0) { const char *e = getenv("VXMAC_YAW_TAU"); tau = e && *e ? (float)atof(e) : 0.6f; }
                        float target = wrap180(gy - (cons_y + g_cam_off_yaw));
                        if (fresh) {
                            double dt = kt > 0 ? now - kt : 0; kt = now; if (dt > 0.5) dt = 0.5;
                            // (h57e: the stick 1:1 - while it is out, and after its release until the game's heading has settled
                            //  (under 5 deg/s for 100 ms, 500 ms at most), the offset is exactly the target every frame: no inertia;
                            //  only then the slow filter (vehicle recentring...), with a 1.5 deg dead band (no drift on foot))
                            float rate = dt > 0 ? fabsf(wrap180(gy - pgy2)) / (float)dt : 0; pgy2 = gy;
                            if (vxmac_stick_active()) { stick_t = now; settling = 1; settle_t = 0; }
                            if (settling && now - stick_t > 0.0) {
                                if (rate < 5) { if (!settle_t) settle_t = now; } else settle_t = 0;
                                if ((settle_t && now - settle_t >= 0.1) || now - stick_t > 0.5) settling = 0;
                            }
                            if (settling) K = target;
                            else if (fabsf(wrap180(target - K)) > 1.5f) K = wrap180(K + wrap180(target - K) * (float)(1 - exp(-dt / tau)));
                        }
                        // (a sane bound: the frame's heading never more than 25 deg from the input-based one; clamps counted)
                        float dk = wrap180(target - K);
                        if (fabsf(dk) > 25) { K = wrap180(target - (dk > 0 ? 25.f : -25.f)); g_yaw_clamps++; }
                    }
                    float yt = wrap180(gy - K);
                    cons_y = y; y = wrap180(yt - g_cam_off_yaw);
                    if (fresh && g_head_valid) { float hy, hp; head_angles(g_head, &hy, &hp); yresid = wrap180((hy - g_yaw_ref) - y); }
                }
                if (now - ylog_t > 5 && vx_host_jlog && yaw_on) { ylog_t = now; char f[360];
                    snprintf(f, sizeof f, "\"game_minus_input_yaw\":%.2f,\"head_minus_frame_yaw\":%.2f,\"cam_reads_skipped\":%lu,\"yaw_offset\":%.1f,\"yaw_clamps\":%lu,\"pitch_clamps\":%lu,"
                             "\"free_gain\":%.2f,\"free_n\":%u,\"aim_gain\":%.2f,\"aim_n\":%u,\"aim_mode\":%d", wrap180(y - cons_y), yresid, g_cam_skips, K, g_yaw_clamps, g_pitch_clamps,
                             g_gain_sxx[0] > 0 ? g_gain_sxy[0] / g_gain_sxx[0] : 0.0, g_gain_n[0], g_gain_sxx[1] > 0 ? g_gain_sxy[1] / g_gain_sxx[1] : 0.0, g_gain_n[1], aim_on());
                    memset(g_gain_sxy, 0, sizeof g_gain_sxy); memset(g_gain_sxx, 0, sizeof g_gain_sxx); memset(g_gain_n, 0, sizeof g_gain_n);
                    vx_host_jlog("game_cam_yaw", f); }
            }
            if (q && q != last_q2) { if (last_q2 && q > last_q2 + 1) g_cam_skips += q - last_q2 - 1; last_q2 = q; }
        }
        if (got) { camera_pose(g_yaw_ref + y + g_cam_off_yaw, g_pitch_ref + pch + g_cam_off_pitch, g_head, head); head_valid = 1;
                   g_stamp_y[pseq % 64] = y; g_stamp_p[pseq % 64] = pch; g_stamp_cons_y[pseq % 64] = cons_y; g_stamp_at[pseq % 64] = pseq; }
    }
    double interval = g_interval;
    pthread_mutex_unlock(&g_lock);
    // the frame's scene from the D3D12 layer (FSR2's inputs: motion vectors, depth, constants), taken every frame
    void *mvp = NULL, *dpp = NULL; uint32_t consts[32];
    int scene = npu_interp_take_scene(&mvp, &dpp, consts);
    id<MTLTexture> smv = scene ? (__bridge_transfer id<MTLTexture>)mvp : nil, sdp = scene ? (__bridge_transfer id<MTLTexture>)dpp : nil;
    if (s < 0) {                                      // (all three in use: this frame is not shown; the game is faster than the GPU)
        if (release) [cb addCompletedHandler:^(id<MTLCommandBuffer> d) { (void)d; release(arg); }];
        return;
    }
    vr_slot *S = &g_slot[s];
    id<MTLTexture> was = S->color;
    {   // (VX Mac, h44: the slot's colour with a mip chain - outside the frame the warp reads its edge blurred by one
        //  sample from a coarser level (24 samples a pixel cost 9 ms of the GPU in h44's first run))
        id<MTLTexture> t = S->color;
        if (!t || t.pixelFormat != back.pixelFormat || t.width != w || t.height != h || t.mipmapLevelCount < 2) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:back.pixelFormat width:w height:h mipmapped:YES];
            td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView; td.storageMode = MTLStorageModePrivate;
            S->color = [dev newTextureWithDescriptor:td];
        }
    }
    if (S->color != was || !S->view) {
        MTLPixelFormat sf = srgb_of(back.pixelFormat);
        S->view = sf != MTLPixelFormatInvalid ? [S->color newTextureViewWithPixelFormat:sf] : S->color;
    }
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    {   // (the frame before, as it was shown: the HUD and text that stay put between two frames are held, not predicted)
        static __strong id<MTLTexture> last;
        S->prev = slot_tex(dev, S->prev, back.pixelFormat, w, h);
        if (!S->prev_view || S->prev_view.width != w || S->prev_view.height != h) {
            MTLPixelFormat sf = srgb_of(back.pixelFormat);
            S->prev_view = sf != MTLPixelFormatInvalid ? [S->prev newTextureViewWithPixelFormat:sf] : S->prev;
        }
        id<MTLTexture> from = last && last.width == w && last.height == h && last.pixelFormat == back.pixelFormat ? last : back;
        [b copyFromTexture:from sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                 toTexture:S->prev destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        last = S->color;                                 // (our copy: its slot is not written while it is the newest)
    }
    [b copyFromTexture:back sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
             toTexture:S->color destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [b generateMipmapsForTexture:S->color];   // (h44: the blurred edge outside the frame, one sample)
    S->w = w; S->h = h;
    S->has_depth = S->has_mv = S->has_proj = 0;
    S->has_hud = 0;
    S->has_vmv = 0;
    if (interp_mode() == 2) {   // (h63c: the game's newest velocity copy (velocity.m: this frame's, verified or not) kept with the frame)
        void *vxmac_vel_latest_tex(uint32_t *w, uint32_t *h, float k[2], float *corr, int *verified);
        uint32_t vw = 0, vh = 0; float k[2] = { 0, 0 }, corr = 0; int ver = 0;
        id<MTLTexture> vt = (__bridge id<MTLTexture>)vxmac_vel_latest_tex(&vw, &vh, k, &corr, &ver);
        if (vt && vw && vh) {
            S->vmv = slot_tex(dev, S->vmv, vt.pixelFormat, vw, vh);
            [b copyFromTexture:vt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(vw, vh, 1)
                     toTexture:S->vmv destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            static float kdef = 0; if (!kdef) { const char *e = getenv("VXMAC_INTERP_VEL_K"); kdef = e && *e ? (float)atof(e) : -1.05f; }
            int kok = ver && fabsf(k[0]) > 0.1f;
            S->vk[0] = kok ? k[0] : kdef; S->vk[1] = kok ? k[1] : kdef; S->has_vmv = 1;
        }
    }
    if (g_hud_in) {   // (VX Mac, h33: the HUD layer copied with the frame, in the same command buffer after the UI pass)
        id<MTLTexture> hin = g_hud_in; g_hud_in = nil;
        id<MTLTexture> was_h = S->hud;
        S->hud = slot_tex(dev, S->hud, hin.pixelFormat, (uint32_t)hin.width, (uint32_t)hin.height);
        if (S->hud != was_h || !S->hud_view) { MTLPixelFormat sf = srgb_of(hin.pixelFormat); S->hud_view = sf != MTLPixelFormatInvalid ? [S->hud newTextureViewWithPixelFormat:sf] : S->hud; }
        [b copyFromTexture:hin sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(hin.width, hin.height, 1)
                 toTexture:S->hud destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        S->has_hud = 1;
        // (h47: a copy kept apart from the slots: a game frame without a capture shows the last one for up to 300 ms -
        //  the minimap blinked at 19 fps against 43 Hz)
        if (!g_hud_keep || g_hud_keep.width != hin.width || g_hud_keep.height != hin.height || g_hud_keep.pixelFormat != hin.pixelFormat) {
            g_hud_keep = slot_tex(dev, nil, hin.pixelFormat, (uint32_t)hin.width, (uint32_t)hin.height);
            MTLPixelFormat sf = srgb_of(hin.pixelFormat); g_hud_keep_view = sf != MTLPixelFormatInvalid ? [g_hud_keep newTextureViewWithPixelFormat:sf] : g_hud_keep;
        }
        [b copyFromTexture:hin sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(hin.width, hin.height, 1)
                 toTexture:g_hud_keep destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        g_hud_keep_t = now;
    }
    float th = 0, d2v[4], mvs[2]; uint32_t disp[2];
    if (scene & 2) S->has_proj = npu_fsr2_parse(consts, &th, d2v, mvs, disp) != 0;
    if (scene && smv) {                                // (FSR2's depth and motion vectors: render size. VX Mac: motion
                                                        //  vectors alone too - the NPU flow; the depth then comes from the passes)
        MTLPixelFormat f = sdp ? sdp.pixelFormat : MTLPixelFormatInvalid;
        uint32_t sw = sdp ? (uint32_t)sdp.width : 0, sh = sdp ? (uint32_t)sdp.height : 0, bpp = f == MTLPixelFormatDepth16Unorm ? 2 : 4;
        MTLPixelFormat to = f == MTLPixelFormatDepth16Unorm ? MTLPixelFormatR16Unorm : MTLPixelFormatR32Float;
        if (sdp) S->depth = slot_tex(dev, S->depth, to, sw, sh);
        if (f == MTLPixelFormatR32Float) {
            [b copyFromTexture:sdp sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(sw, sh, 1)
                     toTexture:S->depth destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            S->has_depth = 1;
        } else if (f == MTLPixelFormatDepth32Float || f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatDepth16Unorm) {
            NSUInteger need = (NSUInteger)sw * sh * bpp;
            if (!S->sdp_tmp || S->sdp_tmp.length != need) S->sdp_tmp = [dev newBufferWithLength:need options:MTLResourceStorageModePrivate];
            id<MTLBuffer> tmp = S->sdp_tmp;
            if (tmp) {
                [b copyFromTexture:sdp sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(sw, sh, 1)
                          toBuffer:tmp destinationOffset:0 destinationBytesPerRow:(NSUInteger)sw * bpp destinationBytesPerImage:(NSUInteger)sw * sh * bpp
                           options:f == MTLPixelFormatDepth32Float_Stencil8 ? MTLBlitOptionDepthFromDepthStencil : MTLBlitOptionNone];
                [b copyFromBuffer:tmp sourceOffset:0 sourceBytesPerRow:(NSUInteger)sw * bpp sourceBytesPerImage:(NSUInteger)sw * sh * bpp
                       sourceSize:MTLSizeMake(sw, sh, 1) toTexture:S->depth destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                S->has_depth = 1;
            }
        }
        S->mv = slot_tex(dev, S->mv, smv.pixelFormat, (uint32_t)smv.width, (uint32_t)smv.height);
        [b copyFromTexture:smv sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(smv.width, smv.height, 1)
                 toTexture:S->mv destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        S->has_mv = S->has_proj;                       // (their scale comes with FSR2's constants)
        // (calibration: a strip through the middle of the motion vectors, read back once the frame is copied)
        MTLPixelFormat mf = smv.pixelFormat;
        uint32_t mbpp = mf == MTLPixelFormatRG16Float ? 4 : mf == MTLPixelFormatRG32Float ? 8 : 0;
        if (C.calibrate && mbpp && S->has_mv && vr_now() && smv.width >= 64 && smv.height >= 64) {
            uint32_t sw = (uint32_t)smv.width < 512 ? (uint32_t)smv.width : 512, sh = 8;
            if (!S->cal_buf || S->cal_buf.length < (NSUInteger)sw * sh * mbpp) S->cal_buf = [dev newBufferWithLength:(NSUInteger)512 * 8 * 8 options:MTLResourceStorageModeShared];
            [b copyFromTexture:smv sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake((smv.width - sw) / 2, (smv.height - sh) / 2, 0) sourceSize:MTLSizeMake(sw, sh, 1)
                      toBuffer:S->cal_buf destinationOffset:0 destinationBytesPerRow:(NSUInteger)sw * mbpp destinationBytesPerImage:(NSUInteger)sw * sh * mbpp];
            S->cal_n = sw * sh; S->cal_bpp = mbpp;
        } else S->cal_n = 0;
    } else S->cal_n = 0;
    if (!S->has_depth && had_depth && hold) {          // (the depth pass's copy)
        MTLPixelFormat to = df == MTLPixelFormatDepth16Unorm ? MTLPixelFormatR16Unorm : MTLPixelFormatR32Float;
        uint32_t bpp = df == MTLPixelFormatDepth16Unorm ? 2 : 4;
        S->depth = slot_tex(dev, S->depth, to, dw, dh);
        [b copyFromBuffer:hold sourceOffset:0 sourceBytesPerRow:(NSUInteger)dw * bpp sourceBytesPerImage:(NSUInteger)dw * dh * bpp
               sourceSize:MTLSizeMake(dw, dh, 1) toTexture:S->depth destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        S->has_depth = 1;
    }
    [b endEncoding];
    // the projection: FSR2's, else the knobs'
    vxw_params p = { 0 };
    if (S->has_proj && vxw_projection_from_fsr2(&p, th, d2v)) {
        S->tan_x = p.tan_x; S->tan_y = p.tan_y; S->z_a = p.z_a; S->z_b = p.z_b; S->flags = 0;
        g_game_tan[0] = p.tan_x; g_game_tan[1] = p.tan_y;
        S->mv_sx = mvs[0] * w; S->mv_sy = mvs[1] * h;
    } else {
        S->has_proj = 0; S->has_mv = 0;
        S->tan_y = C.tan_y; S->tan_x = C.tan_y * (float)w / (float)h;
        if (C.depth_std) { S->z_a = C.farp * C.nearp / (C.farp - C.nearp); S->z_b = -C.nearp / (C.farp - C.nearp); S->flags = VXW_DEPTH_STD; }
        else { S->z_a = C.nearp; S->z_b = 0; S->flags = 0; }
    }
    {   // (is the game rendering a 3D view? vr mode takes the camera after engage_s of it, lets go after 0.5 s without)
        int is3d = C.engage == 1 ? S->has_depth : (S->has_proj && S->has_mv);
        // (VX Mac: the game's own signal first: its mouse look is on (the cursor dissociated, CGAssociateMouse...) only in
        //  free-look gameplay; menus, character creation, loading and cutscenes keep it off: the panel there. A new
        //  mouse-look period clears the image check's backoff)
        {
            static int was_look, seen3d; static double look_since;
            if (is3d) seen3d = 1;   // (the raw signal, before this gate)
            int look = vx_game_mouse_look();
            // (a mouse-look period counts from when it began after the game had drawn 3D at least once: the game turns it
            //  on at 3 s during the logos and keeps it on into the main menu (h18), and for ~2 s while a save loads;
            //  then on for 3 s before the head takes the camera)
            if (look && !was_look) { g_nocontrol_until = 0; g_nocontrol_for = 20; g_cal_fail = 0; look_since = seen3d ? now : 0; }
            was_look = look;
            if (!look || !look_since || now - look_since < 3.0) is3d = 0;
            g_look_hold = look && look_since && now - look_since >= 3.0;
        }
        if (now < g_nocontrol_until && (!g_look_hold || g_nocontrol_strong)) is3d = 0;   // (VX Mac: the game ignores the head now, above - while its mouse look is on only on strong evidence, h45)
        if (now >= g_nocontrol_until) g_nocontrol_strong = 0;
        pthread_mutex_lock(&g_lock);
        // (hysteresis, h2b flapped: a 3D view for engage_s (1.5 s) takes the camera, none for 2 s lets go, and no change
        //  within 3 s of the last one)
        static double last_change;
        if (is3d) { if (!g_3d_since || now - g_3d_last > 2.0) g_3d_since = now; g_3d_last = now; }
        // (VX Mac, h27: gameplay dropped to the panel for a moment - 2 s without the scene's depth (loading, a brief
        //  gap). While the game's mouse look is on, vr mode holds for 8 s without depth; menus (look off) go at once)
        double hold = g_look_hold && g_follow_ema > 0.4f ? 8.0 : 2.0;   // (h29: and while the picture turns with the head - a loading screen does not)
        int want = is3d ? (g_engaged || now - g_3d_since >= C.engage_s) : g_engaged && now - g_3d_last <= hold;
        if (g_force == 1 && want && g_engaged) g_force = 0;   // (h47: the forced vr mode ends once the automatic choice is vr too)
        if (C.vr && C.engage != 2 && want != g_engaged && now - last_change >= 3.0) {
            g_engaged = want; g_engage_changes++; last_change = now;
            vx_log("VR: vr mode %s", want ? "takes the game's camera (a 3D view)" : "lets go of the camera: the world-locked screen (no 3D view)");
            if (vx_host_jlog) { char f[160]; snprintf(f, sizeof f, "\"engaged\":%d,\"why\":\"%s\",\"3d_for_s\":%.1f,\"no_3d_for_s\":%.1f", want,
                                                     want ? "3D view" : "no 3D view", is3d ? now - g_3d_since : 0.0, is3d ? 0.0 : now - g_3d_last); vx_host_jlog("vr_auto", f); }
        }
        if (C.vr && !vr_now()) { memcpy(head, g_head, sizeof head); head_valid = g_head_valid; }
        pthread_mutex_unlock(&g_lock);
    }
    {   // (the previous game frame's camera: the motion vectors run from it)
        static float prev[16]; static int prev_ok; static double prev_t;
        int v = vr_now() && head_valid;
        S->has_prev = v && prev_ok && now - prev_t < 0.5;
        memcpy(S->prev_cam, prev, sizeof prev);
        if (v) { memcpy(prev, head, sizeof prev); prev_t = now; }
        prev_ok = v;
    }
    memcpy(S->head, head, sizeof head);
    S->head_valid = head_valid;
    S->content_time = now; S->interval = interval;
    pthread_mutex_lock(&g_lock); S->gap_before = g_last_gap; pthread_mutex_unlock(&g_lock);
    pthread_mutex_lock(&g_lock);
    S->cam_ok = g_cam_now_ok; g_cam_now_ok = 0; memcpy(S->cam_rows, g_cam_rows, sizeof g_cam_rows); memcpy(S->cam_vel, g_cam_vel, sizeof g_cam_vel);
    pthread_mutex_unlock(&g_lock);
    uint64_t serial = ++g_serial;
    S->pseq = pseq;
    floor_fit(cb, S, pseq);                               // (VX Mac, h48: the game camera's pitch from the floor in the depth)
    [cb addCompletedHandler:^(id<MTLCommandBuffer> d) {
        (void)d;
        pthread_mutex_lock(&g_lock);
        S->writing = 0; S->serial = serial;
        if (g_newest < 0 || g_slot[g_newest].serial < serial) g_newest = s;
        g_submits++;
        if (S->has_depth) g_depth_frames++;
        if (S->has_mv) g_mv_frames++;
        if (S->has_proj) g_fsr2_frames++;
        pthread_mutex_unlock(&g_lock);
        if (S->cal_n) calibrate_frame(S, now);
        if (release) release(arg);
    }];
    static int told;
    if (!told++) vx_log("VR: first frame %ux%u format %lu into slot %d (depth %s, motion vectors %s, FSR2 projection %s)", w, h,
                        (unsigned long)back.pixelFormat, s, S->has_depth ? "yes" : "not yet", S->has_mv ? "yes" : "no", S->has_proj ? "yes" : "no");
}

// ---- the compositor loop ----
static vxw_core *g_core;
static int g_frame_slot = -1;
static id<MTLTexture> g_zero_mv, g_far_depth;
static double g_report;


int vx_xros_vr_begin_frame(const float m_in[16], double presentation_time) {
    config();
    // (h64: no device anchor this frame (VXMacImmersive.swift passes the identity then): the last tracked head is kept -
    //  the identity sent the game's camera to the zero's heading and back in one frame. Logged as head_tracking on each
    //  loss and recovery. VXMAC_HEAD_HOLD=0: the identity as before)
    const float *m = m_in;
    {   static float last[16]; static int have, lost, on = -1; static double lost_t; static unsigned long losses, lost_frames;
        if (on < 0) { const char *e = getenv("VXMAC_HEAD_HOLD"); on = !(e && !strcmp(e, "0")); }
        int ident = m_in[0] == 1 && m_in[5] == 1 && m_in[10] == 1 && m_in[15] == 1 && m_in[12] == 0 && m_in[13] == 0 && m_in[14] == 0 &&
                    m_in[1] == 0 && m_in[2] == 0 && m_in[4] == 0 && m_in[6] == 0 && m_in[8] == 0 && m_in[9] == 0;
        if (ident && have) {
            lost_frames++;
            if (!lost) { lost = 1; losses++; lost_t = CACurrentMediaTime();
                if (vx_host_jlog) { char f[96]; snprintf(f, sizeof f, "\"lost\":1,\"losses\":%lu,\"held\":%d", losses, on); vx_host_jlog("head_tracking", f); } }
            if (on) m = last;
        } else if (!ident) {
            if (lost) { lost = 0;
                if (vx_host_jlog) { char f[128]; snprintf(f, sizeof f, "\"lost\":0,\"lost_s\":%.2f,\"lost_frames\":%lu", CACurrentMediaTime() - lost_t, lost_frames); vx_host_jlog("head_tracking", f); } }
            memcpy(last, m_in, sizeof last); have = 1;
        }
    }
    vx_input_chords_poll();
    {   // (the mode shown changed: vr's zero at the head as it is now; the screen placed again ahead of it)
        pthread_mutex_lock(&g_lock);
        int eff = vr_now() ? 2 : screen_now() ? 1 : 0, was = g_eff;
        if (eff != g_eff) { g_eff = eff; if (eff == 2) { g_vr_ref = 0; g_wc_clear = 1; g_show_mode = 1; } if (eff == 1 && was >= 0) g_recenter = 1; if (was >= 0) g_fade_at = CACurrentMediaTime(); }
        pthread_mutex_unlock(&g_lock);
        if (was >= 0 && eff != was && g_force) { char t[64]; snprintf(t, sizeof t, "%s%s", eff == 2 ? "VR" : eff == 1 ? "Screen" : "Head", g_force ? " (manual)" : " (auto)"); show_label(t); }
        if (eff == 2 && eff != was) {
            const char *e = getenv("VXMAC_GESTURES");
            const char *a = getenv("VXMAC_ARMS");
            if (!(e && !strcmp(e, "0")) && !(a && !strcmp(a, "0"))) show_label("VXHands ON (Hand + Arm + Joy-Con)");
        }
    }
    if (screen_now() && (!g_screen_valid || g_recenter) && (m[12] != 0 || m[13] != 0 || m[14] != 0)) { g_recenter = 0; place_screen(m); }
    vx_xros_pace_tick();
    pthread_mutex_lock(&g_lock);
    memcpy(g_head, m, sizeof g_head);
    g_head_valid = 1;
    if (g_poll_in < 0) { const char *e = getenv("VXMAC_POLL_INPUT"); g_poll_in = e && !strcmp(e, "1"); }   // (h40: off by default - the compositor-paced path was the known-good one; =1 on)
    {   // (h38: the compositor's send only when the poll path is off - or silent for 100 ms: a game blocked waiting for
        //  events never drains, and the head must still turn its camera)
        double t = CACurrentMediaTime();
        if (vr_now()) vr_mouse(m, t, !g_poll_in || t - g_last_poll > 0.1);
    }
    for (int k = 0; k < 3; k++) if (!g_slot[k].writing && !g_slot[k].head_valid) { memcpy(g_slot[k].head, m, sizeof g_head); g_slot[k].head_valid = 1; }
    g_present_time = presentation_time;
    g_frames++;
    if (g_newest >= 0) g_held = g_newest;
    int have = g_held >= 0;
    if (have) g_slot[g_held].readers++;              // (until this frame's command buffer completes: vx_xros_vr_end_frame)
    g_frame_slot = g_held;
    if (have) g_age_ms += (presentation_time - g_slot[g_held].content_time) * 1e3; else g_noframe++;
    pthread_mutex_unlock(&g_lock);
    return have;
}

static void mul4(const float *a, const float *b, float *o) {     // (column-major: o = a * b)
    for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) {
        float v = 0;
        for (int k = 0; k < 4; k++) v += a[k * 4 + r] * b[c * 4 + k];
        o[c * 4 + r] = v;
    }
}

// ---- screen mode: each eye's ray met with the screen's plane (one fullscreen draw per eye) ----
static NSString *const kScreenSrc = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct SP { float4x4 screen_from_eye; float4 tan; float2 half_size; float near_m; float pad; float4 cursor; };\n"
    "struct VO { float4 pos [[position]]; float2 uv; };\n"
    "vertex VO vs(uint i [[vertex_id]]) { float2 p = float2((i << 1) & 2, i & 2); VO o; o.pos = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y); return o; }\n"
    "struct FO { float4 c [[color(0)]]; float d [[depth(any)]]; };\n"
    "fragment FO fs(VO in [[stage_in]], constant SP &p [[buffer(0)]], texture2d<float> img [[texture(0)]]) {\n"
    "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
    "    float3 dir = float3(mix(-p.tan.x, p.tan.y, in.uv.x), mix(p.tan.z, -p.tan.w, in.uv.y), -1);\n"
    "    float3 o = (p.screen_from_eye * float4(0, 0, 0, 1)).xyz, d = (p.screen_from_eye * float4(dir, 0)).xyz;\n"
    "    FO r; r.c = float4(0, 0, 0, 1); r.d = 0;   // (VX Mac: black: 0.02 linear is a visible grey in the sRGB drawable)\n"
    "    if (abs(d.z) < 1e-6) return r;\n"
    "    float t = -o.z / d.z;\n"
    "    if (t <= 0) return r;\n"
    "    float2 q = (o + d * t).xy / p.half_size;\n"
    // (around the screen: its plane's depth too, so the system's late reprojection sees no edge there; with depth 0
    //  outside, the edge came out as a grey, stepped frame offset behind the picture, h4)
    "    if (abs(q.x) > 1 || abs(q.y) > 1) { r.d = p.near_m / t; return r; }\n"
    "    float2 uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);\n"
    // (VX Mac, h29: 4 samples over the pixel's footprint - text on loading screens and menus read smeared from one
    //  bilinear sample of a frame larger than its place on the eye)
    "    float2 du = dfdx(uv) * 0.25, dv = dfdy(uv) * 0.25;\n"
    "    r.c = float4((img.sample(s, uv + du + dv).rgb + img.sample(s, uv - du + dv).rgb + img.sample(s, uv + du - dv).rgb + img.sample(s, uv - du - dv).rgb) * 0.25, 1);\n"
    "    if (p.cursor.z > 0) {\n"
    "        float2 dd = (uv - p.cursor.xy) * float2(p.half_size.x / p.half_size.y, 1);\n"
    "        float rr = length(dd), rad = p.cursor.w > 0 ? 0.008 : 0.011;\n"
    "        if (rr < rad) r.c = rr > rad - 0.003 ? float4(0, 0, 0, 1) : (p.cursor.w > 0 ? float4(0.3, 0.9, 1, 1) : float4(1, 1, 1, 1));\n"
    "    }\n"
    "    r.d = p.near_m / t;\n"
    "    return r;\n"
    "}\n";
static id<MTLRenderPipelineState> g_screen_pso; static MTLPixelFormat g_screen_cf, g_screen_df;
static id<MTLDepthStencilState> g_screen_ds;
static int draw_screen(id<MTLCommandBuffer> cb, vr_slot *S, const float *view_from_origin, const float *tan, float near_m, void *outp, void *odp) {
    if (!g_screen_valid) return 0;
    id<MTLTexture> out = (__bridge id<MTLTexture>)outp, od = (__bridge id<MTLTexture>)odp;
    id<MTLDevice> dev = cb.device;
    if (!g_screen_pso || g_screen_cf != out.pixelFormat || g_screen_df != (od ? od.pixelFormat : MTLPixelFormatInvalid)) {
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kScreenSrc options:nil error:&err];
        if (!lib) { vx_log("VR: the screen's shader: %s", err.localizedDescription.UTF8String); return 0; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = out.pixelFormat;
        if (od) pd.depthAttachmentPixelFormat = od.pixelFormat;
        g_screen_pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!g_screen_pso) { vx_log("VR: the screen's pipeline: %s", err.localizedDescription.UTF8String); return 0; }
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES;
        g_screen_ds = [dev newDepthStencilStateWithDescriptor:dd];
        g_screen_cf = out.pixelFormat; g_screen_df = od ? od.pixelFormat : MTLPixelFormatInvalid;
        vx_log("VR: screen pipeline for colour %lu depth %lu", (unsigned long)g_screen_cf, (unsigned long)g_screen_df);
    }
    struct { float m[16]; float tan[4]; float half_size[2]; float near_m, pad; float cursor[4]; } P;
    float eye_from_world[16], world_from_eye[16], screen_inv[16];
    memcpy(eye_from_world, view_from_origin, sizeof eye_from_world);
    inv_rigid(eye_from_world, world_from_eye);
    inv_rigid(g_screen, screen_inv);
    mul4(screen_inv, world_from_eye, P.m);
    memcpy(P.tan, tan, sizeof P.tan);
    P.half_size[0] = C.screen_m * tanf(C.screen_deg * 0.5f * (float)M_PI / 180);
    P.half_size[1] = P.half_size[0] * (float)S->h / (float)(S->w ? S->w : 1);
    P.near_m = near_m; P.pad = 0;
    pthread_mutex_lock(&g_lock); memcpy(P.cursor, g_cursor_dot, sizeof P.cursor); pthread_mutex_unlock(&g_lock);
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture = out; pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (od) { pass.depthAttachment.texture = od; pass.depthAttachment.loadAction = MTLLoadActionDontCare; pass.depthAttachment.storeAction = MTLStoreActionStore; }
    id<MTLRenderCommandEncoder> e = eye_encoder(cb, pass);
    [e setRenderPipelineState:g_screen_pso];
    if (od) [e setDepthStencilState:g_screen_ds];
    [e setFragmentBytes:&P length:sizeof P atIndex:0];
    [e setFragmentTexture:S->view atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    pthread_mutex_lock(&g_lock); g_draws++; pthread_mutex_unlock(&g_lock);
    static int told;
    if (!told++) vx_log("VR: first screen eye: frame %ux%u -> %lux%lu, frustum %.3f %.3f %.3f %.3f, screen %.2f x %.2f m",
                        S->w, S->h, (unsigned long)out.width, (unsigned long)out.height, tan[0], tan[1], tan[2], tan[3],
                        2 * P.half_size[0], 2 * P.half_size[1]);
    return 1;
}

// ---- a short label in front of the eyes (the mode, the sensitivity), 2.5 s, head-locked ----
static id<MTLTexture> g_label_tex; static double g_label_until; static char g_label_text[160]; static int g_label_dirty;
static id<MTLRenderPipelineState> g_label_pso; static MTLPixelFormat g_label_cf;
static void show_label(const char *text) {
    pthread_mutex_lock(&g_lock);
    snprintf(g_label_text, sizeof g_label_text, "%s", text);
    g_label_dirty = 1; g_label_until = CACurrentMediaTime() + 2.5; g_label_big = 0;
    pthread_mutex_unlock(&g_lock);
}
static id<MTLTexture> label_texture(id<MTLDevice> dev, const char *text) {
    const size_t W = 1024, H = 128;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, W, H, 8, W * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c) return nil;
    CGContextClearRect(c, CGRectMake(0, 0, W, H));
    CGContextSetRGBFillColor(c, 0.05, 0.05, 0.08, 0.78);
    CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(4, 4, W - 8, H - 8), 40, 40, NULL);
    CGContextAddPath(c, path); CGContextFillPath(c); CGPathRelease(path);
    // (h47: the system UI font - its cascade draws Japanese, Chinese and Korean; smaller when the text is wide)
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, strlen(text) > 36 ? 44 : 54, NULL);
    if (!font) font = CTFontCreateWithName(CFSTR("Helvetica-Bold"), 54, NULL);
    CGColorRef white = CGColorCreateGenericRGB(1, 1, 1, 1);
    CFStringRef str = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName }, *vals[] = { font, white };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, str ? str : CFSTR("?"), attrs);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    CGRect b = CTLineGetImageBounds(line, c);
    CGContextSetTextPosition(c, (W - b.size.width) / 2 - b.origin.x, (H - b.size.height) / 2 - b.origin.y);
    CTLineDraw(line, c);
    CFRelease(line); CFRelease(as); CFRelease(attrs); if (str) CFRelease(str); CGColorRelease(white); CFRelease(font);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    // (the bitmap's rows run bottom-up in CoreGraphics' coordinates, but the memory is top row first)
    [t replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:CGBitmapContextGetData(c) bytesPerRow:W * 4];
    CGContextRelease(c);
    return t;
}
static NSString *const kLabelSrc = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VO { float4 pos [[position]]; float2 uv; };\n"
    "vertex VO vs(uint i [[vertex_id]], constant float4 &r [[buffer(0)]]) {\n"
    "    float2 c = float2(i & 1, (i >> 1) & 1); VO o;\n"
    "    o.pos = float4(mix(r.x, r.z, c.x), mix(r.w, r.y, c.y), 0, 1); o.uv = float2(c.x, 1 - c.y); return o; }\n"
    "fragment float4 fs(VO in [[stage_in]], texture2d<float> t [[texture(0)]]) {\n"
    "    constexpr sampler s(filter::linear, address::clamp_to_edge); return t.sample(s, in.uv); }\n";
static void draw_label(id<MTLCommandBuffer> cb, void *outp) {
    id<MTLTexture> out = (__bridge id<MTLTexture>)outp;
    double now = CACurrentMediaTime();
    char text[160]; int dirty;
    pthread_mutex_lock(&g_lock);
    if (now > g_label_until) { pthread_mutex_unlock(&g_lock); return; }
    dirty = g_label_dirty; g_label_dirty = 0; memcpy(text, g_label_text, sizeof text);
    pthread_mutex_unlock(&g_lock);
    id<MTLDevice> dev = cb.device;
    if (dirty || !g_label_tex) g_label_tex = label_texture(dev, text);
    if (!g_label_tex) return;
    if (!g_label_pso || g_label_cf != out.pixelFormat) {
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kLabelSrc options:nil error:&err];
        if (!lib) { vx_log("VR: the label's shader: %s", err.localizedDescription.UTF8String); g_label_until = 0; return; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = out.pixelFormat;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        g_label_pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!g_label_pso) { vx_log("VR: the label's pipeline: %s", err.localizedDescription.UTF8String); g_label_until = 0; return; }
        g_label_cf = out.pixelFormat;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture = out; pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = eye_encoder(cb, pass);
    float ew, eh; eye_size(out, &ew, &eh);
    float aspect = ew / (eh > 0 ? eh : 1);
    float hw = g_label_big ? 0.5f : 0.32f, hh = hw * aspect * 128.0f / 1024.0f;   // (h47: the mode's label larger)
    float r[4] = { -hw, 0.42f + hh, hw, 0.42f - hh };   // (left, top, right, bottom in NDC, a little above the centre)
    [e setRenderPipelineState:g_label_pso];
    [e setVertexBytes:r length:sizeof r atIndex:0];
    [e setFragmentTexture:g_label_tex atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
}

// (VX Mac: the fade after a change of state: black over the eye, 1 -> 0 over 0.35 s, no jump between the panel and
//  the head-driven view)
static id<MTLRenderPipelineState> g_fade_pso; static MTLPixelFormat g_fade_cf;
static void draw_fade(id<MTLCommandBuffer> cb, void *outp) {
    float a = g_fade_at > 0 ? 1.0f - (float)((CACurrentMediaTime() - g_fade_at) / 0.35) : 0;
    if (a <= 0) return;
    id<MTLTexture> out = (__bridge id<MTLTexture>)outp;
    if (!g_fade_pso || g_fade_cf != out.pixelFormat) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 fv(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); return float4(q * 2 - 1, 0, 1); }\n"
            "fragment float4 ff(constant float &a [[buffer(0)]]) { return float4(0, 0, 0, a); }\n";
        NSError *err = nil;
        id<MTLLibrary> lib = [cb.device newLibraryWithSource:src options:nil error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"fv"]; pd.fragmentFunction = [lib newFunctionWithName:@"ff"];
        pd.colorAttachments[0].pixelFormat = out.pixelFormat;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        g_fade_pso = lib ? [cb.device newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
        g_fade_cf = out.pixelFormat;
        if (!g_fade_pso) { vx_log("VR: the fade's pipeline: %s", err.localizedDescription.UTF8String); g_fade_at = 0; return; }
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture = out; pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = eye_encoder(cb, pass);
    [e setRenderPipelineState:g_fade_pso];
    [e setFragmentBytes:&a length:sizeof a atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// (VX Mac: in vr mode the eye sees beyond the game's frame (eye tangents up 1.0, down 1.19, sides 1.0/1.73 against the
//  frame's 1.19 x 0.67 at FOV 100), and the warp shows the frame's edge where it ends: a hard frame below and, while
//  the head turns between 18 fps frames, at the sides. A vignette in the eye's own space darkens smoothly from 93 % of
//  the frame's angular extent to black at its edge, so no edge is seen; VXMAC_VR_VIGNETTE=0 turns it off,
//  VXMAC_VR_VIGNETTE=<0..1> sets where it starts)
static id<MTLRenderPipelineState> g_vig_pso; static MTLPixelFormat g_vig_cf;
// (VX Mac, h26: the world cache - the band below and around the game's frame. The eye sees 50 degrees down, the frame
//  ends at 34: that was a black band ("the frame at the bottom"). Each new game frame in the head-driven view is
//  painted into a low-resolution panorama of directions in the room (2048 x 1024 equirectangular, 5.7 px/deg, its
//  central part only: the HUD in the frame's corners stays out), and outside the frame each eye shows the panorama
//  there, a little darker, where it has been seen (looking down once fills the floor), black where never. The vignette
//  is the blend between them over the frame's last 7 %. Cleared when the view enters vr mode (another place).
//  VXMAC_VR_CACHE=0: off (black outside, as before); VXMAC_VR_CACHE_DIM: its brightness (default 0.8))
static id<MTLTexture> g_wc; static id<MTLComputePipelineState> g_wc_splat; static uint64_t g_wc_serial; static int g_wc_on = -1;
static float g_wc_dim = 0.85f;   // (h38: a little dimmer - it reads as the periphery)   // (0.8 until h27: the band read as a frame)
static NSString *const kWcSrc = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct P { float h[9]; float gx, gy; };\n"          // (h: the frame's camera from the room, rows; gx, gy: its tangents)
    "static float3 wc_dir(float2 uv) { float lon = (uv.x * 2 - 1) * M_PI_F, lat = (0.5f - uv.y) * M_PI_F;\n"
    "    return float3(cos(lat) * sin(lon), sin(lat), -cos(lat) * cos(lon)); }\n"
    "kernel void splat(texture2d<float> f [[texture(0)]], texture2d<float, access::write> c [[texture(1)]], constant P &p [[buffer(0)]],\n"
    "                  constant uint &clear [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x >= c.get_width() || g.y >= c.get_height()) return;\n"
    "    if (clear) { c.write(float4(0), g); }\n"
    "    float3 d = wc_dir((float2(g) + 0.5f) / float2(c.get_width(), c.get_height()));\n"
    "    float3 q = float3(p.h[0] * d.x + p.h[1] * d.y + p.h[2] * d.z, p.h[3] * d.x + p.h[4] * d.y + p.h[5] * d.z, p.h[6] * d.x + p.h[7] * d.y + p.h[8] * d.z);\n"
    "    if (q.z > -1e-3f) return;\n"
    "    float2 nd = float2(q.x / -q.z / p.gx, q.y / -q.z / p.gy);\n"
    // (the frame's middle only: |x| < 0.8, y -0.6 .. 0.55 - the HUD's corners, subtitles and the weapon stay out)
    "    if (abs(nd.x) > 0.85f || nd.y < -0.7f || nd.y > 0.55f) return;\n"
    "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
    "    c.write(float4(f.sample(s, float2(nd.x * 0.5f + 0.5f, 0.5f - nd.y * 0.5f), level(0)).rgb, 1), g);\n"
    "}\n";
static void wc_update(id<MTLCommandBuffer> cb) {
    if (g_wc_on < 0) { const char *e = getenv("VXMAC_VR_CACHE"); g_wc_on = e && !strcmp(e, "1");   // (h44: off - stale and dimmed, it separated from the frame and read as a shadow; =1 on)
                       e = getenv("VXMAC_VR_CACHE_DIM"); if (e && *e) g_wc_dim = (float)atof(e); }
    if (!g_wc_on || g_eff != 2 || g_guard_level >= 3) return;
    pthread_mutex_lock(&g_lock); int s = g_frame_slot; pthread_mutex_unlock(&g_lock);
    if (s < 0) return;
    vr_slot *S = &g_slot[s];
    if (!S->view || !S->w || !S->head_valid || (S->serial == g_wc_serial && !g_wc_clear)) return;
    id<MTLDevice> dev = cb.device;
    if (!g_wc) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:2048 height:1024 mipmapped:NO];   // (h38: 2048 again - at 1024 its texels read as blocks at the frame's side)
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; td.storageMode = MTLStorageModePrivate;
        g_wc = [dev newTextureWithDescriptor:td];
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kWcSrc options:nil error:&err];
        g_wc_splat = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"splat"] error:&err] : nil;
        if (!g_wc || !g_wc_splat) { vx_log("VR: the world cache: %s", err ? err.localizedDescription.UTF8String : "no texture"); g_wc_on = 0; return; }
        vx_log("VR: world cache on (2048x1024, outside the frame, dim %.2f)", g_wc_dim);
    }
    config();
    struct { float h[9]; float gx, gy; } P;
    for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) P.h[r * 3 + c] = S->head[r * 4 + c];   // (camera from room: H^T)
    P.gy = C.tan_y; P.gx = C.tan_y * (float)S->w / (float)S->h;
    uint32_t clear = g_wc_clear; g_wc_clear = 0; g_wc_serial = S->serial;
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:g_wc_splat];
    [e setTexture:S->view atIndex:0]; [e setTexture:g_wc atIndex:1];
    [e setBytes:&P length:sizeof P atIndex:0]; [e setBytes:&clear length:4 atIndex:1];
    [e dispatchThreads:MTLSizeMake(2048, 1024, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [e endEncoding];
}
static void draw_vignette(id<MTLCommandBuffer> cb, void *outp, const float tan[4], const float view_from_origin[16]) {
    static float start = -1;
    // (0.93: only the last 7 % of the frame's extent; 0.72 until h26 put the HUD's corners - the minimap, quests,
    //  health - in the dark)
    // (h33: 0.97 - the tall frame covers the eye up and down; at the sides a dark band moving with the frame showed it as
    //  a screen. The blend to the world cache over the last 3 % only, the cache undimmed)
    // (h38: 0.93 - a 7 % blend from the frame to the cache; 3 % left a hard seam)
    if (start < 0) { const char *e = getenv("VXMAC_VR_VIGNETTE"); start = e && *e ? (float)atof(e) : 0.93f; }
    if (start <= 0 || g_eff != 2) return;
    pthread_mutex_lock(&g_lock); int s = g_frame_slot; pthread_mutex_unlock(&g_lock);
    if (s < 0) return;
    vr_slot *S = &g_slot[s];
    id<MTLTexture> out = (__bridge id<MTLTexture>)outp;
    if (!g_vig_pso || g_vig_cf != out.pixelFormat) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 p [[position]]; float2 uv; };\n"
            "vertex V vv(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V o; o.p = float4(q * 2 - 1, 0, 1); o.uv = float2(q.x, 1 - q.y); return o; }\n"
            // (e: how far out the eye's ray is in the frame's camera, 1 at its edge; the cache by the ray's room direction)
            "struct U { float l, r, u, d, gx, gy, s, dim; float we[9]; float cw[9]; uint cache; };\n"
            "fragment float4 vf(V i [[stage_in]], constant U &k [[buffer(0)]], texture2d<float> wc [[texture(0)]]) {\n"
            "  float x = mix(-k.l, k.r, i.uv.x), y = mix(k.u, -k.d, i.uv.y);\n"
            "  float3 v = float3(x, y, -1);\n"
            "  float3 w = float3(k.we[0] * v.x + k.we[1] * v.y + k.we[2] * v.z, k.we[3] * v.x + k.we[4] * v.y + k.we[5] * v.z, k.we[6] * v.x + k.we[7] * v.y + k.we[8] * v.z);\n"
            "  float3 q = float3(k.cw[0] * w.x + k.cw[1] * w.y + k.cw[2] * w.z, k.cw[3] * w.x + k.cw[4] * w.y + k.cw[5] * w.z, k.cw[6] * w.x + k.cw[7] * w.y + k.cw[8] * w.z);\n"
            "  float e = q.z < -1e-3f ? max(abs(q.x / -q.z) / k.gx, abs(q.y / -q.z) / k.gy) : 10.0f;\n"
            "  float a = smoothstep(k.s, 1.0, e);\n"
            // (h40: a head-locked soft dark band at the bottom of the eye's view (a visor's rim), from 26 to 34 degrees down:
            //  the 16:9 frame's lower edge is never seen as an edge, and nothing moves with the turn there)
            "  float band = 0.0;\n"   // (h44: no head-locked band - it did not move with the scene)
            "  if (!k.cache) { if (band <= 0) discard_fragment(); return float4(0, 0, 0, band); }\n"
            "  a = max(a, band);\n"
            "  if (a <= 0) discard_fragment();\n"
            // (h27: the panorama only where it has been seen; elsewhere the warp's own mirrored edge stays - never black)
            "  float3 d = normalize(w); float2 uv = float2((atan2(d.x, -d.z) / M_PI_F + 1) * 0.5f, 0.5f - asin(clamp(d.y, -1.0f, 1.0f)) / M_PI_F);\n"
            // (h38: 9 samples over ~1.5 texels: soft, never blocks)
            "  constexpr sampler s(filter::linear, address::repeat); float2 px = 1.5 / float2(wc.get_width(), wc.get_height()); float4 t = 0;\n"
            "  for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) t += wc.sample(s, uv + float2(x, y) * px); t /= 9;\n"
            "  a *= t.a; if (a <= 0) discard_fragment();\n"
            "  return float4(t.rgb * k.dim * a, a); }\n";
        NSError *err = nil;
        id<MTLLibrary> lib = [cb.device newLibraryWithSource:src options:nil error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vv"]; pd.fragmentFunction = [lib newFunctionWithName:@"vf"];
        pd.colorAttachments[0].pixelFormat = out.pixelFormat;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        g_vig_pso = lib ? [cb.device newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
        g_vig_cf = out.pixelFormat;
        if (!g_vig_pso) { vx_log("VR: the vignette's pipeline: %s", err.localizedDescription.UTF8String); start = 0; return; }
    }
    config();
    float gy = C.tan_y, gx = C.tan_y * (S->h ? (float)S->w / (float)S->h : 16.f / 9.f);
    struct { float l, r, u, d, gx, gy, s, dim; float we[9]; float cw[9]; uint32_t cache; } k = { tan[0], tan[1], tan[2], tan[3], gx, gy, start, g_wc_dim };
    // (room from eye: the transpose of view_from_origin's rotation; the frame's camera from room: the transpose of its head's)
    for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) { k.we[r * 3 + c] = view_from_origin[r * 4 + c]; k.cw[r * 3 + c] = S->head[r * 4 + c]; }
    k.cache = g_wc_on > 0 && g_wc != nil && g_guard_level < 3;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture = out; pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = eye_encoder(cb, pass);
    [e setRenderPipelineState:g_vig_pso];
    [e setFragmentBytes:&k length:sizeof k atIndex:0];
    [e setFragmentTexture:g_wc atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// (VX Mac, h26: the HUD nearer the centre. The game's HUD sits in the frame's corners - the minimap and quest top right,
//  health top left, the weapon bottom right - at 40-50 degrees out, where the eye's view ends or reading is hard. In
//  the head-driven view each region of the game's frame is drawn again, head-locked at ~1.5 m, moved in towards the
//  centre at the same angular size (scale 1: orthostereo kept). The regions are where Cyberpunk's default HUD is; any
//  game's can be given: VXMAC_HUD="u0 v0 u1 v1 x y s; ..." (frame UV rectangle -> the centre's direction in degrees,
//  right/up positive, and a scale), VXMAC_HUD=1 the default regions; unset or 0: off)
typedef struct { float u0, v0, u1, v1, x, y, sc; int masked; int vis, on_n, off_n; } hud_region;
static hud_region g_hud[8]; static int g_hud_n = -1;
static id<MTLRenderPipelineState> g_hud_pso; static MTLPixelFormat g_hud_cf;
// (h28: the HUD's own pixels only. A region's crop held the scene around the HUD too - ghost rectangles of the world,
//  empty dark panels when the weapon or health were hidden. Masked regions now draw only the pixels that are the
//  HUD: bright, and still on the screen while the camera turns (the scene moves under them) - a mask built over the
//  frames the head turns in (hud_mask), shown with a soft shadow, nothing where there is no HUD. The originals in the
//  frame's corners are filled from around them in the warp (no duplicate text). The minimap is drawn whole (it turns
//  with the player: no still pixels), its crop tight.)
static __strong id<MTLTexture> g_hm[2]; static int g_hm_i; static id<MTLComputePipelineState> g_hm_pso;
static uint64_t g_hm_serial; static float g_hm_fwd[3];
static float g_hud_aspect = 16.f / 9.f;   // (the frame's aspect when the regions were chosen)
static void hud_config(void) {
    if (g_hud_n >= 0) return;
    // (on by default; VXMAC_HUD=0 off; VXMAC_HUD="u0 v0 u1 v1 x y s m; ..." regions: the frame's UV rectangle, its centre's
    //  direction in degrees (right/up), a scale, m 1: masked (the HUD's pixels only), 0: whole. The defaults are for
    //  Cyberpunk's layout at HudSafezoneHor 0, the text regions generous (the mask keeps only the HUD), placed so the
    //  content (right-aligned quest and weapon, left-aligned health) lands within ~28 deg of the centre:
    //  minimap (m 2: by brightness, 0.8x) x ~6.5..21, y ~2..20; quest text ending ~28 right, y -16..-4; health from ~30 left, y 10..20;
    //  weapon ending ~28 right, y -26..-9)
    // (h37: off by default - the fixed colour-key panels covered the weapon wheel and cutscenes and stood empty most of
    //  the time; the UI target's layer (libvxmtl) brings all of the UI in. VXMAC_HUD=1 (or regions): on)
    const char *e = getenv("VXMAC_HUD");
    if (!e || !*e || !strcmp(e, "0")) { g_hud_n = 0; return; }
    // (h31: measured from a 1040x1004 frame (snap): the minimap's frame u .850-.969, v .028-.169; the quest text
    //  u .799-.887, v .189-.215; the health chevrons u .09-.17, v .125-.145 - near-square frames (aspect < 1.3) use these)
    const char *def = g_hud_aspect < 1.3f
        ? "0.845 0.022 0.975 0.175 14 11 0.9 3; 0.79 0.180 0.935 0.228 16 -3 1 3; 0.08 0.112 0.185 0.158 -15 15 1 3"
        : "0.85 0.03 0.97 0.27 14 11 0.8 3; 0.78 0.30 0.985 0.40 17 -3 0.9 3";
    if (!e || !*e) e = "1";
    const char *p = !strcmp(e, "1") ? def : e;
    g_hud_n = 0;
    while (*p && g_hud_n < 8) {
        hud_region r = { 0 };
        int used = 0;
        int n = sscanf(p, " %f %f %f %f %f %f %f %d%n", &r.u0, &r.v0, &r.u1, &r.v1, &r.x, &r.y, &r.sc, &r.masked, &used);
        if (n < 8) { used = 0; r.masked = 0; if (sscanf(p, " %f %f %f %f %f %f %f%n", &r.u0, &r.v0, &r.u1, &r.v1, &r.x, &r.y, &r.sc, &used) != 7) break; }
        g_hud[g_hud_n++] = r;
        p += used;
        while (*p == ' ' || *p == ';') p++;
    }
    vx_log("VR: HUD regions drawn near the centre: %d (%s)", g_hud_n, strcmp(e, "1") ? "VXMAC_HUD" : "Cyberpunk's default layout");
}
static NSString *const kHudMaskSrc = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct M { float4 r[8]; uint n, moving; };\n"
    "kernel void hm(texture2d<float> f [[texture(0)]], texture2d<float> pf [[texture(1)]], texture2d<float> old [[texture(2)]],\n"
    "               texture2d<float, access::write> o [[texture(3)]], constant M &m [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x >= o.get_width() || g.y >= o.get_height()) return;\n"
    "    float2 uv = (float2(g) + 0.5f) / float2(o.get_width(), o.get_height());\n"
    "    bool in = false;\n"
    "    for (uint k = 0; k < m.n; k++) if (all(uv >= m.r[k].xy) && all(uv <= m.r[k].zw)) in = true;\n"
    "    if (!in) { o.write(float4(0), g); return; }\n"
    "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
    "    float3 c = f.sample(s, uv, level(0)).rgb, pc = pf.sample(s, uv, level(0)).rgb;\n"
    "    float v = old.read(g).r;\n"
    // (h29: the HUD's colours - saturated yellow / cyan / red, or near-white - and still while the scene around it
    //  moves: of 8 samples 6 texels out at least 4 changed. A still close-up (an NPC's cap in a dialogue) has a still
    //  surrounding and is not HUD)
    "    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));\n"
    "    bool bright = (mx > 0.22f && mx - mn > 0.5f * mx) || mn > 0.6f;\n"
    "    bool still = all(abs(c - pc) < 0.04f);\n"
    "    int moved = 0; float2 px = 6.0f / float2(o.get_width(), o.get_height());\n"
    "    for (int k = 0; k < 8; k++) { float an = k * 0.7854f; float2 q = uv + float2(cos(an), sin(an)) * px;\n"
    "        if (any(abs(f.sample(s, q, level(0)).rgb - pf.sample(s, q, level(0)).rgb) > 0.06f)) moved++; }\n"
    "    if (m.moving) v = mix(v, (bright && still && moved >= 4) ? 1.0f : 0.0f, 0.3f);\n"
    "    else if (!bright) v = mix(v, 0.0f, 0.3f);\n"            // (still camera: what is not bright fades out)
    "    o.write(float4(v), g);\n"
    "}\n";
// (once per new game frame in vr mode: the mask's update, and whether the camera turned since the last: the head's
//  forward between the two frames' cameras more than 0.4 degrees)
// (h30: no per-pixel mask any more - it formed partly and broke the quest text into dots. Each region is an opaque
//  panel, shown while its crop holds HUD-coloured pixels: counted per game frame on the GPU (saturated yellow / cyan /
//  red or near-white at half resolution), shown after 3 frames over 0.4 % of its pixels, hidden after 20 under 0.15 %.
//  The minimap is always shown. Where a panel is shown, the frame's own copy of that rectangle is darkened in the warp.)
static NSString *const kHudCountSrc = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct M { float4 r[8]; uint n; };\n"
    "kernel void hc(texture2d<float> f [[texture(0)]], device atomic_uint *cnt [[buffer(1)]], constant M &m [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    uint W = f.get_width() / 2, H = f.get_height() / 2; if (g.x >= W || g.y >= H) return;\n"
    "    float2 uv = (float2(g) + 0.5f) / float2(W, H);\n"
    "    float3 c = f.read(g * 2).rgb; float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));\n"
    "    bool hud = (mx > 0.25f && mx - mn > 0.55f * mx) || mn > 0.6f;\n"
    "    for (uint k = 0; k < m.n; k++) if (all(uv >= m.r[k].xy) && all(uv <= m.r[k].zw)) { atomic_fetch_add_explicit(&cnt[k * 2], 1, memory_order_relaxed); if (hud) atomic_fetch_add_explicit(&cnt[k * 2 + 1], 1, memory_order_relaxed); }\n"
    "}\n";
static id<MTLComputePipelineState> g_hc_pso; static uint64_t g_hc_serial;
static void hud_mask_update(id<MTLCommandBuffer> cb) {
    if (g_hud_n < 0) { pthread_mutex_lock(&g_lock); int s0 = g_frame_slot; pthread_mutex_unlock(&g_lock);
                       if (s0 < 0 || !g_slot[s0].w) return; g_hud_aspect = (float)g_slot[s0].w / (float)g_slot[s0].h; }
    hud_config();
    if (!g_hud_n || g_eff != 2) return;
    pthread_mutex_lock(&g_lock); int s = g_frame_slot; pthread_mutex_unlock(&g_lock);
    if (s < 0) return;
    vr_slot *S = &g_slot[s];
    if (!S->view || !S->w || S->serial == g_hc_serial) return;
    g_hc_serial = S->serial;
    id<MTLDevice> dev = cb.device;
    if (!g_hc_pso) {
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kHudCountSrc options:nil error:&err];
        g_hc_pso = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"hc"] error:&err] : nil;
        if (!g_hc_pso) { vx_log("VR: the HUD count: %s", err.localizedDescription.UTF8String); g_hud_n = 0; return; }
    }
    struct { float r[8][4]; uint32_t n; } M = { { { 0 } }, (uint32_t)g_hud_n };
    for (int k = 0; k < g_hud_n; k++) { M.r[k][0] = g_hud[k].u0; M.r[k][1] = g_hud[k].v0; M.r[k][2] = g_hud[k].u1; M.r[k][3] = g_hud[k].v1; }
    id<MTLBuffer> cnt = [dev newBufferWithLength:16 * 4 options:MTLResourceStorageModeShared];
    memset(cnt.contents, 0, 64);
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:g_hc_pso];
    [e setTexture:S->view atIndex:0]; [e setBytes:&M length:sizeof M atIndex:0]; [e setBuffer:cnt offset:0 atIndex:1];
    [e dispatchThreads:MTLSizeMake(S->w / 2, S->h / 2, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [e endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> d) {
        (void)d;
        const uint32_t *c = cnt.contents;
        pthread_mutex_lock(&g_lock);
        for (int k = 0; k < g_hud_n; k++) {
            hud_region *r = &g_hud[k];
            if (r->masked == 3 && k == 0) { r->vis = 1; continue; }   // (the minimap: always)
            float share = c[k * 2] ? (float)c[k * 2 + 1] / c[k * 2] : 0;
            if (share > 0.004f) { r->off_n = 0; if (++r->on_n >= 3) r->vis = 1; }
            else if (share < 0.0015f) { r->on_n = 0; if (++r->off_n >= 20) r->vis = 0; }
        }
        pthread_mutex_unlock(&g_lock);
    }];
}
// (the shown panels' rectangles for the warp: their originals darkened)
static int hud_shown_rects(float out[16]) {
    int n = 0;
    pthread_mutex_lock(&g_lock);
    for (int k = 0; k < g_hud_n && n < 4; k++) if (g_hud[k].vis) { out[n * 4] = g_hud[k].u0; out[n * 4 + 1] = g_hud[k].v0; out[n * 4 + 2] = g_hud[k].u1; out[n * 4 + 3] = g_hud[k].v1; n++; }
    pthread_mutex_unlock(&g_lock);
    return n;
}
static id<MTLTexture> hud_mask_now(void) { return nil; }
// (VX Mac, h33: the whole HUD layer as one head-locked panel at ~1.5 m, its half-width VXMAC_HUD_DEG degrees (default
//  28), sampled once (no warp), premultiplied over the eye - the game's own HUD, shapes and tilt as designed)
static id<MTLRenderPipelineState> g_hl_pso; static MTLPixelFormat g_hl_cf;
static int draw_hud_layer(id<MTLCommandBuffer> cb, void *outp, int eye, const float tan[4]) {
    if (g_eff != 2) return 0;
    pthread_mutex_lock(&g_lock); int s = g_frame_slot; pthread_mutex_unlock(&g_lock);
    if (s < 0) return 0;
    vr_slot *S = &g_slot[s];
    // (h43: a menu / guide over the scene (the UI covers over 30 %): the whole frame, scene and UI, as the centred
    //  head-locked panel (+-30 deg), opaque - world-size its edge popups fell out of view)
    int vxmtl_ui_menu(void);
    int menu = vxmtl_ui_menu() && S->view && g_force != 1;   // (h47: a forced vr mode shows no menu panel)
    id<MTLTexture> hv = S->has_hud && S->hud_view ? S->hud_view : (g_hud_keep_view && CACurrentMediaTime() - g_hud_keep_t < 0.3 ? g_hud_keep_view : nil);
    if (!menu && !hv) return 0;
    id<MTLTexture> out = (__bridge id<MTLTexture>)outp;
    if (!g_hl_pso || g_hl_cf != out.pixelFormat) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 p [[position]]; float2 uv; };\n"
            "struct LP { int opaque; int pad[3]; float4 ex; float4 uvr; float4 ex2; };\n"   // (ex, ex2: UV rectangles left out; uvr: the part of the texture drawn)
            "vertex V lv(uint i [[vertex_id]], constant float4 &r [[buffer(0)]], constant LP &l [[buffer(1)]]) { float2 c = float2(i & 1, i >> 1); V o;\n"
            "  o.p = float4(mix(r.x, r.z, c.x), mix(r.y, r.w, c.y), 0, 1); o.uv = mix(l.uvr.xy, l.uvr.zw, c); return o; }\n"
            "fragment float4 lf(V i [[stage_in]], texture2d<float> t [[texture(0)]], constant LP &l [[buffer(0)]]) {\n"
            "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
            "  if (l.ex.z > l.ex.x && all(i.uv >= l.ex.xy) && all(i.uv <= l.ex.zw)) discard_fragment();\n"
            "  if (l.ex2.z > l.ex2.x && all(i.uv >= l.ex2.xy) && all(i.uv <= l.ex2.zw)) discard_fragment();\n"
            "  if (l.opaque == 2) return float4(0, 0, 0, 0.92);\n"   // (h46: the menu's backdrop)
            "  int opaque = l.opaque;\n"
            "  float2 du = dfdx(i.uv) * 0.25, dv = dfdy(i.uv) * 0.25;\n"
            "  float4 c = (t.sample(s, i.uv + du + dv) + t.sample(s, i.uv - du + dv) + t.sample(s, i.uv + du - dv) + t.sample(s, i.uv - du - dv)) * 0.25;\n"
            "  float a = max(c.a, max(c.r, max(c.g, c.b)));\n"   // (UI drawn with its alpha unwritten still shows: its colour as cover)
            "  if (opaque) return float4(c.rgb, 1);\n"            // (h43: the menu's whole frame)
            "  return float4(c.rgb, saturate(a)); }\n";
        NSError *err = nil;
        id<MTLLibrary> lib = [cb.device newLibraryWithSource:src options:nil error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"lv"]; pd.fragmentFunction = [lib newFunctionWithName:@"lf"];
        pd.colorAttachments[0].pixelFormat = out.pixelFormat;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        g_hl_pso = lib ? [cb.device newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
        g_hl_cf = out.pixelFormat;
        if (!g_hl_pso) { vx_log("VR: the HUD layer's pipeline: %s", err.localizedDescription.UTF8String); return 0; }
    }
    static float deg = -1; if (deg < 0) { const char *e = getenv("VXMAC_HUD_DEG"); deg = e && *e ? (float)atof(e) : 28; }
    id<MTLTexture> src = menu ? S->view : hv;
    float hw = tanf((menu ? 30.f : deg) * (float)M_PI / 180), hh = hw * (float)src.height / (float)src.width;
    float shift = (eye == 0 ? 1 : -1) * 0.032f / 1.5f;
    float l = -hw + shift, rt = hw + shift, t = hh, bt = -hh;
    float r[4] = { (l + tan[0]) / (tan[0] + tan[1]) * 2 - 1, (t + tan[3]) / (tan[2] + tan[3]) * 2 - 1,
                   (rt + tan[0]) / (tan[0] + tan[1]) * 2 - 1, (bt + tan[3]) / (tan[2] + tan[3]) * 2 - 1 };
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture = out; pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = eye_encoder(cb, pass);
    [e setRenderPipelineState:g_hl_pso];
    [e setVertexBytes:r length:sizeof r atIndex:0];
    if (menu) {   // (h46: a dark backdrop over the eye first - the world-placed frame behind the menu panel never shows doubled)
        float full[4] = { -1, 1, 1, -1 };
        struct { int opaque; int pad[3]; float ex[4]; float uvr[4]; float ex2[4]; } B = { 2, { 0 }, { 0, 0, 0, 0 }, { 0, 0, 1, 1 }, { 0, 0, 0, 0 } };
        [e setVertexBytes:full length:sizeof full atIndex:0];
        [e setVertexBytes:&B length:sizeof B atIndex:1];
        [e setFragmentBytes:&B length:sizeof B atIndex:0];
        [e setFragmentTexture:src atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [e setVertexBytes:r length:sizeof r atIndex:0];
    }
    [e setFragmentTexture:src atIndex:0];
    // (h45: the subtitles' band (u 0.15-0.85, v 0.78-0.97) left out of the layer and drawn on its own, 0.8x, from 8 to
    //  ~14 deg below the centre - they sat low; VXMAC_SUB=0: as part of the layer)
    static int sub = -1; if (sub < 0) { const char *ev = getenv("VXMAC_SUB"); sub = !(ev && !strcmp(ev, "0")); }
    struct { int opaque; int pad[3]; float ex[4]; float uvr[4]; float ex2[4]; } L = { menu, { 0 }, { 0, 0, 0, 0 }, { 0, 0, 1, 1 }, { 0, 0, 0, 0 } };
    if (sub && !menu) { L.ex[0] = 0.15f; L.ex[1] = 0.78f; L.ex[2] = 0.85f; L.ex[3] = 0.97f; }
    // (h64: mode 7 - the crosshair (the HUD's centre, VXMAC_AIM_XHAIR half-width in UV, default 0.05) cut from the
    //  head-locked layer and drawn where the frame's centre is in this eye, at the layer's own scale: the gun's aim)
    static float xh = -1; if (xh < 0) { const char *ev = getenv("VXMAC_AIM_XHAIR"); xh = ev && *ev ? (float)atof(ev) : 0.05f; if (xh > 0.3f) xh = 0.3f; }
    int xhair = !menu && eye >= 0 && eye < 2 && g_xh_ok[eye] && xh > 0;
    float xv = xh * (float)src.width / (float)src.height;
    if (xhair) { L.ex2[0] = 0.5f - xh; L.ex2[1] = 0.5f - xv; L.ex2[2] = 0.5f + xh; L.ex2[3] = 0.5f + xv; }
    [e setVertexBytes:&L length:sizeof L atIndex:1];
    [e setFragmentBytes:&L length:sizeof L atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    if (sub && !menu) {
        float bw = 0.70f * 2 * hw * 0.8f, bh = 0.19f * 2 * hh * 0.8f;   // (the band's size in tangents, 0.8x)
        float top = -tanf(8 * (float)M_PI / 180), cx2 = shift;
        float r2[4] = { (cx2 - bw / 2 + tan[0]) / (tan[0] + tan[1]) * 2 - 1, (top + tan[3]) / (tan[2] + tan[3]) * 2 - 1,
                        (cx2 + bw / 2 + tan[0]) / (tan[0] + tan[1]) * 2 - 1, (top - bh + tan[3]) / (tan[2] + tan[3]) * 2 - 1 };
        struct { int opaque; int pad[3]; float ex[4]; float uvr[4]; float ex2[4]; } L2 = { 0, { 0 }, { 0, 0, 0, 0 }, { 0.15f, 0.78f, 0.85f, 0.97f }, { 0, 0, 0, 0 } };
        [e setVertexBytes:r2 length:sizeof r2 atIndex:0];
        [e setVertexBytes:&L2 length:sizeof L2 atIndex:1];
        [e setFragmentBytes:&L2 length:sizeof L2 atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    if (xhair) {
        float cx3 = g_xh[eye][0] + shift, cy3 = g_xh[eye][1], bw = 2 * hw * 2 * xh, bh = 2 * hh * 2 * xv;
        float r3[4] = { (cx3 - bw / 2 + tan[0]) / (tan[0] + tan[1]) * 2 - 1, (cy3 + bh / 2 + tan[3]) / (tan[2] + tan[3]) * 2 - 1,
                        (cx3 + bw / 2 + tan[0]) / (tan[0] + tan[1]) * 2 - 1, (cy3 - bh / 2 + tan[3]) / (tan[2] + tan[3]) * 2 - 1 };
        struct { int opaque; int pad[3]; float ex[4]; float uvr[4]; float ex2[4]; } L3 = { 0, { 0 }, { 0, 0, 0, 0 }, { 0.5f - xh, 0.5f - xv, 0.5f + xh, 0.5f + xv }, { 0, 0, 0, 0 } };
        [e setVertexBytes:r3 length:sizeof r3 atIndex:0];
        [e setVertexBytes:&L3 length:sizeof L3 atIndex:1];
        [e setFragmentBytes:&L3 length:sizeof L3 atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [e endEncoding];
    static int told; if (!told++) vx_log("VR: the game's HUD layer shown as a head-locked panel, +-%.0f degrees wide", deg);
    static int was_menu = -1; if (menu != was_menu) { was_menu = menu; vx_log("VR: %s", menu ? "a menu / guide over the scene: the whole frame as the centred panel" : "the HUD layer again"); }
    return 1;
}
static void draw_hud(id<MTLCommandBuffer> cb, void *outp, int eye, const float tan[4]) {
    if (draw_hud_layer(cb, outp, eye, tan)) return;      // (h33: the layer when there is one; the crops otherwise)
    hud_config();
    if (!g_hud_n || g_eff != 2) return;
    pthread_mutex_lock(&g_lock); int s = g_frame_slot; pthread_mutex_unlock(&g_lock);
    if (s < 0 || !g_slot[s].view || !g_slot[s].w) return;
    vr_slot *S = &g_slot[s];
    id<MTLTexture> mask = hud_mask_now();
    id<MTLTexture> out = (__bridge id<MTLTexture>)outp;
    if (!g_hud_pso || g_hud_cf != out.pixelFormat) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 p [[position]]; float2 uv; float2 q; };\n"
            "struct R { float4 ndc; float4 uv; uint masked; };\n"     // (ndc: left, top, right, bottom; uv: u0, v0, u1, v1)
            "vertex V hv(uint i [[vertex_id]], constant R &r [[buffer(0)]]) { float2 c = float2(i & 1, i >> 1); V o;\n"
            "  o.p = float4(mix(r.ndc.x, r.ndc.z, c.x), mix(r.ndc.y, r.ndc.w, c.y), 0, 1); o.uv = mix(r.uv.xy, r.uv.zw, c); o.q = c; return o; }\n"
            "fragment float4 hf(V i [[stage_in]], constant R &r [[buffer(0)]], texture2d<float> t [[texture(0)]], texture2d<float> mk [[texture(1)]]) {\n"
            "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
            "  float3 c = t.sample(s, i.uv).rgb;\n"
            "  float e = min(min(i.q.x, 1 - i.q.x), min(i.q.y, 1 - i.q.y));\n"
            "  if (r.masked == 0) { float a = smoothstep(0.0, 0.03, e) * 0.97; return float4(c * a, a); }\n"
            // (2, h28's minimap: its lines and icons by brightness, a soft fade at the edges, at most 30 % darker behind -
            //  part of the HUD, not a window)
            // (3, h29's minimap: an opaque dark panel with soft corners; the crop's HUD colours at full, anything else -
            //  the scene through the game's translucent map - at 20 %: no scene chunks)
            // (3: an opaque dark panel, soft corners; inside it only the HUD's pixels - saturated yellow / cyan / green or
            //  near-white text, never dark, desaturated or red-dominant (the scene's red) - over the panel's colour: no
            //  scene at all (h32))
            "  if (r.masked == 3) { float f = smoothstep(0.0, 0.06, e); float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));\n"
            "    bool red = c.r > 1.5 * c.g && c.r > 1.5 * c.b;\n"
            "    float sat = (mx - mn) / max(mx, 1e-3);\n"
            "    float hud = red ? 0.0 : max(smoothstep(0.45, 0.65, sat) * smoothstep(0.18, 0.32, mx), smoothstep(0.55, 0.75, mn));\n"
            "    float3 o = float3(0.03, 0.035, 0.045) * (1 - hud) + c * 1.3 * hud;\n"
            "    return float4(o * f, f); }\n"
            "  if (r.masked == 2) { float f = smoothstep(0.0, 0.12, e); float a = smoothstep(0.10, 0.28, max(c.r, max(c.g, c.b))) * f; float bk = 0.3 * f;\n"
            "    float al = a + bk * (1 - a); if (al < 0.01) discard_fragment(); return float4(c * a, al); }\n"
            // (masked: the HUD's pixels (the mask, a little widened), and a soft shadow around them)
            "  float2 px = 1.0 / float2(mk.get_width(), mk.get_height());\n"
            "  float m = 0, sh = 0;\n"
            "  for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) m = max(m, mk.sample(s, i.uv + float2(x, y) * px).r);\n"
            "  for (int y = -2; y <= 2; y++) for (int x = -2; x <= 2; x++) sh += mk.sample(s, i.uv + float2(x, y) * px * 2).r;\n"
            "  float a = smoothstep(0.35, 0.7, m); float sa = saturate(sh / 25 * 2.5) * 0.5;\n"
            "  float al = a + sa * (1 - a); if (al < 0.01) discard_fragment();\n"
            "  return float4(c * a, al); }\n";
        NSError *err = nil;
        id<MTLLibrary> lib = [cb.device newLibraryWithSource:src options:nil error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"hv"]; pd.fragmentFunction = [lib newFunctionWithName:@"hf"];
        pd.colorAttachments[0].pixelFormat = out.pixelFormat;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        g_hud_pso = lib ? [cb.device newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
        g_hud_cf = out.pixelFormat;
        if (!g_hud_pso) { vx_log("VR: the HUD's pipeline: %s", err.localizedDescription.UTF8String); g_hud_n = 0; return; }
    }
    config();
    // (the game's frame in tangents: x = (u * 2 - 1) * tan_x, y = (1 - v * 2) * tan_y; at 1.5 m the eye sees it shifted
    //  by half the eyes' distance: 0.032 / 1.5 in tangent, inwards)
    float gy = C.tan_y, gx = C.tan_y * (float)S->w / (float)S->h, shift = (eye == 0 ? 1 : -1) * 0.032f / 1.5f;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture = out; pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = eye_encoder(cb, pass);
    [e setRenderPipelineState:g_hud_pso];
    [e setFragmentTexture:S->view atIndex:0];
    [e setFragmentTexture:mask atIndex:1];
    for (int k = 0; k < g_hud_n; k++) {
        hud_region *r = &g_hud[k];
        if (r->masked == 1 && !mask) continue;
        if (r->masked == 3 && !r->vis) continue;
        float w = (r->u1 - r->u0) * 2 * gx * r->sc, h = (r->v1 - r->v0) * 2 * gy * r->sc;   // (its size in tangents)
        float cx = tanf(r->x * (float)M_PI / 180) + shift, cy = tanf(r->y * (float)M_PI / 180);
        float l = cx - w / 2, rt = cx + w / 2, t = cy + h / 2, b = cy - h / 2;
        // (tangents to the eye's NDC: x from -tan[0] .. tan[1], y from -tan[3] .. tan[2])
        struct { float ndc[4]; float uv[4]; uint32_t masked; } R = {
            { (l + tan[0]) / (tan[0] + tan[1]) * 2 - 1, (t + tan[3]) / (tan[2] + tan[3]) * 2 - 1,
              (rt + tan[0]) / (tan[0] + tan[1]) * 2 - 1, (b + tan[3]) / (tan[2] + tan[3]) * 2 - 1 },
            { r->u0, r->v0, r->u1, r->v1 }, (uint32_t)r->masked };
        [e setVertexBytes:&R length:sizeof R atIndex:0];
        [e setFragmentBytes:&R length:sizeof R atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [e endEncoding];
}

// (VX Mac, h70) The magazine by hand drawn over the eye: a magazine in the off hand while one is held (a box 12 x 3.5 x
// 2.2 cm along the fist's knuckles, shaded by face), and the grip's bottom as a ring across the grip's line while a
// magazine is wanted - lit (larger, brighter) when the hand is there. Points in the room's frame, through the eye's
// view and tangents to its NDC; no depth test: drawn over the game, like the label.
static id<MTLRenderPipelineState> g_mag_pso; static MTLPixelFormat g_mag_cf;
typedef struct { float p[4], c[4]; } MV;
static float vdot(const float *a, const float *b) { return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; }
static void vcross(const float *a, const float *b, float *c) {
    c[0]=a[1]*b[2]-a[2]*b[1]; c[1]=a[2]*b[0]-a[0]*b[2]; c[2]=a[0]*b[1]-a[1]*b[0];
}
static int vnorm(float *a) { float n=sqrtf(vdot(a,a)); if (n < 1e-5f) return 0; for(int i=0;i<3;i++) a[i]/=n; return 1; }
static int mag_project(const float *q, float *out, const float *vfo, const float *tan) {
    float e[3]; for(int r=0;r<3;r++) e[r]=vfo[r]*q[0]+vfo[4+r]*q[1]+vfo[8+r]*q[2]+vfo[12+r];
    if(e[2]>-.05f) return 0; float z=-e[2];
    out[0]=(e[0]/z+tan[0])/(tan[0]+tan[1])*2-1; out[1]=(e[1]/z+tan[3])/(tan[2]+tan[3])*2-1;
    out[2]=0; out[3]=1; return 1;
}
// A tapered, face-shaded prism in room coordinates.
static void add_beam(MV *v, int *n, const float *A, const float *B, const float *hint,
                     float ra, float rb, const float *col, const float *vfo, const float *tan) {
    if (*n + 36 > 8192) return;
    float d[3], u[3], side[3]; for(int i=0;i<3;i++) d[i]=B[i]-A[i];
    if(!vnorm(d)) return; vcross(d,hint,side);
    if(!vnorm(side)) { float ref[3]={0,1,0}; if(fabsf(d[1])>.9f) { ref[0]=1; ref[1]=0; } vcross(d,ref,side); if(!vnorm(side)) return; }
    vcross(side,d,u); vnorm(u);
    float c[8][3], projected[8][4];
    for(int k=0;k<8;k++) { for(int i=0;i<3;i++) c[k][i]=(k&1?B[i]:A[i])+(k&2?1:-1)*side[i]*(k&1?rb:ra)+(k&4?1:-1)*u[i]*(k&1?rb:ra);
        if(!mag_project(c[k],projected[k],vfo,tan)) return; }
    static const int faces[6][6]={{0,2,6,0,6,4},{1,3,7,1,7,5},{0,1,5,0,5,4},{2,3,7,2,7,6},{0,1,3,0,3,2},{4,5,7,4,7,6}};
    static const float shade[6]={.55f,.85f,.65f,.75f,.5f,1};
    for(int f=0;f<6;f++) for(int j=0;j<6;j++) { MV *x=&v[(*n)++]; memcpy(x->p,projected[faces[f][j]],sizeof x->p); for(int i=0;i<3;i++) x->c[i]=col[i]*shade[f]; x->c[3]=col[3]; }
}
// The game's viewmodel is a depth-masked, hand-relative patch of the current frame.
static id<MTLRenderPipelineState> g_vm_pso; static MTLPixelFormat g_vm_cf;
typedef struct { float p[4], uv[2], orig_uv[2], mode[4]; } VMV;
typedef struct { float za, zb; uint32_t std_depth, has_depth; float hand_uv[4]; float lefty; } VMP;
typedef struct { float pivot[4], delta[4], nr[4], nu[4], nf[4], right[4], up[4], fwd[4], off[4], view[16], tan[4], source[4]; } VMT;
static void draw_game_viewmodel(id<MTLCommandBuffer> cb, id<MTLTexture> out, vr_slot *S,
                                const __typeof__(g_mag_draw) *D, const float *M, const float *tan, int eye) {
    (void)eye;
    if (!S || !S->view || !S->has_depth || !S->depth || !S->head_valid || !D->gun_ok || S->tan_x <= 0 || S->tan_y <= 0) return;
    if (!g_vm_pso || g_vm_cf != out.pixelFormat) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct VMV { float4 p; float2 uv; float2 orig_uv; float4 mode; };\n"
        "struct VMP { float za, zb; uint std_depth, has_depth; float4 hand_uv; float lefty; };\n"
        "struct VMT { float4 pivot, delta, nr, nu, nf, right, up, fwd, off; float4x4 view; float4 tan, source; };\n"
        "struct O { float4 p [[position]]; float2 uv; float2 orig_uv; float4 mode; };\n"
        "float dist(texture2d<float> d, sampler s, float2 uv, constant VMP &p) { float dv=d.sample(s,uv,level(0)).r; if(p.std_depth) dv=1.0-dv; return abs(p.za/max(abs(dv-p.zb),1e-5)); }\n"
        "float mask(texture2d<float> d, sampler s, float2 uv, constant VMP &p) {\n"
        "  float2 m=float2(p.lefty>0.5 ? 1.0-uv.x : uv.x,uv.y);\n"
        "  if (!p.has_depth || m.x<0.15 || m.x>0.98 || m.y<0.32 || m.y>0.99) return 0.0;\n"
        "  float z=dist(d,s,uv,p); return (isfinite(z) && z>=0.03 && z<0.48) ? 1.0 : 0.0; }\n"
        "vertex O vm_vs(uint id [[vertex_id]], constant VMV *v [[buffer(0)]], constant VMP &p [[buffer(1)]], constant VMT &t [[buffer(2)]], texture2d<float> dep [[texture(0)]]) {\n"
        " O o; VMV a=v[id]; o.p=a.p; o.uv=a.uv; o.orig_uv=a.orig_uv; o.mode=a.mode;\n"
        " float z=0.22;\n"
        " float3 q=float3((2.0*a.uv.x-1.0)*t.source.x*z,(1.0-2.0*a.uv.y)*t.source.y*z,-z);\n"
        " if (a.mode.x>0.5) q.xy+=t.delta.xy;\n"
        " float4 e=t.view*float4(q,1); float ez=max(-e.z,0.001);\n"
        " o.p=float4(((e.x/ez+t.tan.x)/(t.tan.x+t.tan.y)*2.0-1.0)*ez, ((e.y/ez+t.tan.w)/(t.tan.z+t.tan.w)*2.0-1.0)*ez,0,ez); return o; }\n"
        "fragment float4 vm_fs(O i [[stage_in]], constant VMP &p [[buffer(0)]], texture2d<float> col [[texture(0)]], texture2d<float> dep [[texture(1)]]) {\n"
        " constexpr sampler s(filter::nearest,address::clamp_to_edge);\n"
        " constexpr sampler linear_s(filter::linear,address::clamp_to_edge);\n"
        " if (i.mode.x<0.5) { if (mask(dep,s,i.orig_uv,p)<0.5) discard_fragment();\n"
        "  float3 sum=0; float weights=0;\n"
        "  for (int d=0; d<8; ++d) { float a=3.1415926536+float(d)*0.4487989505; float2 dir=float2(cos(a),sin(a));\n"
        "   for (int j=1; j<=80; ++j) { float r=float(j)*0.008; float2 q=i.orig_uv+dir*r;\n"
        "    if (any(q<0.0) || any(q>1.0)) break; float z=dist(dep,s,q,p);\n"
        "    if (isfinite(z) && z>=0.55 && mask(dep,s,q,p)<0.05) { float w=exp(-r*r*20.0)/(0.02+r); sum+=col.sample(linear_s,q).rgb*w; weights+=w; break; } } }\n"
        "  if (weights<=0.0) return float4(col.sample(s,float2(i.orig_uv.x,clamp(i.orig_uv.y-0.38,0.05,0.35))).rgb, 1.0); return float4(sum/weights,1.0); }\n"
        " float fg=mask(dep,s,i.uv,p); if (fg<0.5) discard_fragment();\n"
        " return float4(col.sample(linear_s,i.uv).rgb,1.0); }\n";
        NSError *err = nil; id<MTLLibrary> lib = [cb.device newLibraryWithSource:src options:nil error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vm_vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"vm_fs"];
        pd.colorAttachments[0].pixelFormat = out.pixelFormat; pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne; pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne; pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        g_vm_pso = lib ? [cb.device newRenderPipelineStateWithDescriptor:pd error:&err] : nil; g_vm_cf = out.pixelFormat;
        if (!g_vm_pso) { vx_log("VR: game viewmodel pipeline: %s", err.localizedDescription.UTF8String); return; }
    }
    const char *left = getenv("VXMAC_GESTURE_LEFTY"); int lefty = left && !strcmp(left,"1");
    const float *h = S->head;
    float dp[3];
    for (int i=0;i<3;i++) dp[i]=D->palm[i]-D->neutral_palm[i];
    float dx=vdot(dp,h), dy=vdot(dp,h+4)-D->pull*.4f;
    if (D->off_ok) {
        float off_dp[3]={D->off_palm[0]-D->off_neutral[0],D->off_palm[1]-D->off_neutral[1],D->off_palm[2]-D->off_neutral[2]};
        dx+=.35f*vdot(off_dp,h); dy+=.35f*vdot(off_dp,h+4);
    }
    dx*=.65f; dy*=.65f;
    float dlen=hypotf(dx,dy);
    if (dlen>.065f) { dx*=.065f/dlen; dy*=.065f/dlen; dlen=.065f; }
    if (dlen<.003f) return;
    VMP p={S->z_a,S->z_b,(S->flags & VXW_DEPTH_STD)?1u:0u,(S->has_depth && S->depth)?1u:0u,{.15f,.32f,.98f,.99f},lefty?1.f:0.f};
    VMT t={0}; t.delta[0]=dx; t.delta[1]=dy; t.delta[2]=0;
    memcpy(t.view,M,sizeof t.view); memcpy(t.tan,tan,sizeof t.tan); t.source[0]=S->tan_x; t.source[1]=S->tan_y;
    enum { NX=64, NY=48, MAXV=NX*NY*6 }; VMV *verts=malloc(sizeof(*verts)*MAXV); if(!verts) return;
    static const int tri[6][2]={{0,0},{1,0},{1,1},{0,0},{1,1},{0,1}};
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor new]; pass.colorAttachments[0].texture=out; pass.colorAttachments[0].loadAction=MTLLoadActionLoad; pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e=eye_encoder(cb,pass); [e setRenderPipelineState:g_vm_pso];
    [e setVertexBytes:&p length:sizeof p atIndex:1]; [e setVertexBytes:&t length:sizeof t atIndex:2]; [e setVertexTexture:p.has_depth ? S->depth : S->view atIndex:0];
    [e setFragmentBytes:&p length:sizeof p atIndex:0]; [e setFragmentTexture:S->view atIndex:0]; [e setFragmentTexture:p.has_depth ? S->depth : S->view atIndex:1];
    for(int mode=0;mode<2;mode++) { int n=0;
      for(int y=0;y<NY;y++) for(int x=0;x<NX;x++) { VMV cell[6]; int valid=1;
        for(int k=0;k<6;k++) { float u=(lefty?.02f:.15f)+.83f*(x+tri[k][0])/NX, v=.32f+.67f*(y+tri[k][1])/NY;
          VMV *a=&cell[k]; memset(a,0,sizeof *a); a->uv[0]=a->orig_uv[0]=u; a->uv[1]=a->orig_uv[1]=v; a->mode[0]=mode;
        } if(valid) { memcpy(verts+n,cell,sizeof cell); n+=6; }
      }
      if(n) { id<MTLBuffer> buf=[cb.device newBufferWithBytes:verts length:n*sizeof(*verts) options:MTLResourceStorageModeShared];
        if(buf) { [e setVertexBuffer:buf offset:0 atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:n]; } }
    }
    [e endEncoding]; free(verts);
}

static void draw_v_hand(MV *v, int *n, const float *s, int pinch, const float *vfo, const float *tan) {
    if(s[0]<.5f) return;
    #define J(i) (s+1+(i)*3)
    const float metal[4]={.10f,.11f,.12f,.98f}, finger[4]={.65f,.40f,.29f,.98f}, cyan[4]={.10f,.48f,.51f,.95f}, yellow[4]={.64f,.46f,.19f,.95f};
    float across[3], up[3], along[3], elbow[3];
    for(int i=0;i<3;i++) { across[i]=J(19)[i]-J(7)[i]; along[i]=J(11)[i]-J(1)[i]; elbow[i]=J(0)[i]; }
    vcross(across,along,up); if(!vnorm(up)) { up[0]=0;up[1]=1;up[2]=0; }
    float elen=0; for(int i=0;i<3;i++) elen+=(elbow[i]-J(1)[i])*(elbow[i]-J(1)[i]);
    if(elen<.0025f) { vnorm(along); for(int i=0;i<3;i++) elbow[i]=J(1)[i]-.22f*along[i]; }
    add_beam(v,n,elbow,J(1),up,.035f,.025f,metal,vfo,tan);
    float a[3],b[3]; for(int i=0;i<3;i++) { a[i]=elbow[i]+up[i]*.035f; b[i]=J(1)[i]+up[i]*.026f; }
    add_beam(v,n,a,b,across,.002f,.002f,yellow,vfo,tan);
    vnorm(along); float cuff[3]; for(int i=0;i<3;i++) cuff[i]=J(1)[i]-.035f*along[i];
    add_beam(v,n,cuff,J(1),up,.030f,.029f,metal,vfo,tan);
    const int palm[]={2,7,11,15,19};
    for(int k=0;k<4 && *n+3<=8192;k++) {
        float p[3][4]; if(!mag_project(J(1),p[0],vfo,tan) || !mag_project(J(palm[k]),p[1],vfo,tan) || !mag_project(J(palm[k+1]),p[2],vfo,tan)) continue;
        for(int j=0;j<3;j++) { memcpy(v[*n].p,p[j],sizeof p[j]); memcpy(v[(*n)++].c,finger,sizeof finger); }
    }
    const int bases[]={2,7,11,15,19};
    for(int i=0;i<5;i+=2) add_beam(v,n,J(1),J(bases[i]),up,.012f,.009f,metal,vfo,tan);
    for(int i=1;i<4;i++) add_beam(v,n,J(bases[i]),J(bases[i+1]),up,.002f,.002f,cyan,vfo,tan);
    const int start[]={2,6,10,14,18};
    for(int f=0;f<5;f++) for(int j=0;j<3;j++)
        add_beam(v,n,J(start[f]+j),J(start[f]+j+1),up,j==0?.008f:.006f,j==2?.004f:.006f,(pinch && j==2 && f<2)?cyan:finger,vfo,tan);
    for(int f=0;f<5;f++) for(int j=0;j<3;j++) {
        const float *joint=J(start[f]+j); float a[3],b[3];
        for(int i=0;i<3;i++) { a[i]=joint[i]-up[i]*.002f; b[i]=joint[i]+up[i]*.002f; }
        add_beam(v,n,a,b,across,.008f,.008f,(pinch && f<2)?cyan:metal,vfo,tan);
    }
    #undef J
}
static void draw_mag(id<MTLCommandBuffer> cb, void *outp, const float vfo[16], const float tan[4], int eye, const float *warp_M) {
    pthread_mutex_lock(&g_lock);
    __typeof__(g_mag_draw) D = g_mag_draw;
    vr_slot *S = (g_frame_slot >= 0) ? &g_slot[g_frame_slot] : NULL;
    pthread_mutex_unlock(&g_lock);
    static int game_hands = -1; if (game_hands < 0) { const char *e = getenv("VXMAC_FLAT_VM"); game_hands = e && !strcmp(e, "1"); }
    static int v_hands = -1; if (v_hands < 0) { const char *e = getenv("VXMAC_V_HANDS"); v_hands = e && !strcmp(e, "1"); }
    if (g_eff != 2 || (!D.on && !(v_hands && (D.skel[0] > .5f || D.skel[67] > .5f))) || (!game_hands && !v_hands && !D.ring && !D.mag)) return;
    id<MTLTexture> out = (__bridge id<MTLTexture>)outp;
    if (game_hands && warp_M) draw_game_viewmodel(cb, out, S, &D, warp_M, tan, eye);
    static int mag_box = -1; if (mag_box < 0) { const char *e = getenv("VXMAC_MAG_BOX"); mag_box = e && !strcmp(e, "1"); }
    if (!v_hands && (!mag_box || (!D.mag && !D.ring))) return;
    if (!g_mag_pso || g_mag_cf != out.pixelFormat) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct VI { float4 p; float4 c; };\n"
            "struct V { float4 p [[position]]; float4 c; };\n"
            "vertex V mv(uint i [[vertex_id]], constant VI *v [[buffer(0)]]) { V o; o.p = v[i].p; o.c = v[i].c; return o; }\n"
            "fragment float4 mf(V i [[stage_in]]) { return float4(i.c.rgb * i.c.a, i.c.a); }\n";
        NSError *err = nil;
        id<MTLLibrary> lib = [cb.device newLibraryWithSource:src options:nil error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"mv"]; pd.fragmentFunction = [lib newFunctionWithName:@"mf"];
        pd.colorAttachments[0].pixelFormat = out.pixelFormat;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        g_mag_pso = lib ? [cb.device newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
        g_mag_cf = out.pixelFormat;
        if (!g_mag_pso) { vx_log("VR: the magazine's pipeline: %s", err.localizedDescription.UTF8String); return; }
    }
    MV v[8192]; int n = 0, behind = 0;          // (the box 36, the ring 72)
    // (a room point to the eye's NDC; behind the eye or nearer than 5 cm: the shape is not drawn)
    #define MAG_NDC(P, O) do { const float *q_ = (P); float e_[3]; \
        for (int r_ = 0; r_ < 3; r_++) e_[r_] = vfo[r_] * q_[0] + vfo[4 + r_] * q_[1] + vfo[8 + r_] * q_[2] + vfo[12 + r_]; \
        if (e_[2] > -0.05f) behind = 1; float z_ = e_[2] < -0.05f ? -e_[2] : 0.05f; \
        (O)[0] = (e_[0] / z_ + tan[0]) / (tan[0] + tan[1]) * 2 - 1; (O)[1] = (e_[1] / z_ + tan[3]) / (tan[2] + tan[3]) * 2 - 1; \
        (O)[2] = 0; (O)[3] = 1; } while (0)
    #define MAG_TRI(A, B, C_, col) do { MAG_NDC(A, v[n].p); memcpy(v[n++].c, col, 16); MAG_NDC(B, v[n].p); memcpy(v[n++].c, col, 16); \
        MAG_NDC(C_, v[n].p); memcpy(v[n++].c, col, 16); } while (0)
    if (v_hands) {
        draw_v_hand(v,&n,D.skel,D.pinch[0] || (D.holding && !(getenv("VXMAC_GESTURE_LEFTY") && !strcmp(getenv("VXMAC_GESTURE_LEFTY"), "1"))),vfo,tan);
        draw_v_hand(v,&n,D.skel+67,D.pinch[1] || (D.holding && (getenv("VXMAC_GESTURE_LEFTY") && !strcmp(getenv("VXMAC_GESTURE_LEFTY"), "1"))),vfo,tan);

    }
    int overlay_start = n;
    if (mag_box && D.mag && n + 36 <= 8192) {            // (the box: up the magazine, across it, its thickness)
        float u[3] = { D.mag_up[0], D.mag_up[1], D.mag_up[2] }, a[3] = { u[1] * 0 - u[2] * 1, u[2] * 0 - u[0] * 0, u[0] * 1 - u[1] * 0 };
        float an = sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]); if (an < 1e-3f) { a[0] = 1; a[1] = 0; a[2] = 0; an = 1; }
        for (int i = 0; i < 3; i++) a[i] /= an;
        float b[3] = { u[1] * a[2] - u[2] * a[1], u[2] * a[0] - u[0] * a[2], u[0] * a[1] - u[1] * a[0] };
        float c[8][3];
        float length = D.weapon_type == HW_WPN_SHOTGUN ? .025f : D.weapon_type == HW_WPN_RIFLE ? .085f : D.holding ? 0.06f : (D.lit ? 0.045f : 0.035f);
        float width = D.weapon_type == HW_WPN_SHOTGUN ? .009f : .0175f;
        for (int k = 0; k < 8; k++) for (int i = 0; i < 3; i++)
            c[k][i] = D.mag_at[i] + u[i] * ((k & 1) ? length : -length) + a[i] * ((k & 2) ? width : -width) + b[i] * ((k & 4) ? 0.011f : -0.011f);
        static const int f[6][4] = { { 0, 2, 6, 4 }, { 1, 3, 7, 5 }, { 0, 1, 5, 4 }, { 2, 3, 7, 6 }, { 0, 1, 3, 2 }, { 4, 5, 7, 6 } };
        static const float shade[6] = { 0.55f, 0.85f, 0.65f, 0.75f, 0.45f, 0.95f };
        for (int k = 0; k < 6; k++) {
            float col[4] = { 0.25f * shade[k], 0.85f * shade[k], 0.9f * shade[k], 0.55f };
            if (D.lit && !D.holding) { col[0] = 0.95f * shade[k]; col[1] = 0.8f * shade[k]; col[2] = 0.2f * shade[k]; }
            if (D.holding && k == 1) { col[0] = 0.95f; col[1] = 0.3f; col[2] = 0.45f; col[3] = 0.7f; }   // (its top - the end that goes in)
            MAG_TRI(c[f[k][0]], c[f[k][1]], c[f[k][2]], col); MAG_TRI(c[f[k][0]], c[f[k][2]], c[f[k][3]], col);
        }
    }
    if (mag_box && D.ring) {                              // (the ring: 12 segments across the grip's line)
        float g[3] = { D.grip_dir[0], D.grip_dir[1], D.grip_dir[2] }, a[3] = { g[1] * 0 - g[2] * 1, g[2] * 0 - g[0] * 0, g[0] * 1 - g[1] * 0 };
        float an = sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]); if (an < 1e-3f) { a[0] = 1; a[1] = 0; a[2] = 0; an = 1; }
        for (int i = 0; i < 3; i++) a[i] /= an;
        float b[3] = { g[1] * a[2] - g[2] * a[1], g[2] * a[0] - g[0] * a[2], g[0] * a[1] - g[1] * a[0] };
        float r0 = D.lit ? 0.035f : 0.028f, r1 = r0 + (D.lit ? 0.01f : 0.006f);
        float col[4] = { 1.0f, D.lit ? 0.95f : 0.8f, D.lit ? 0.4f : 0.2f, D.lit ? 0.85f : 0.5f };
        for (int k = 0; k < 12 && n + 6 <= 8192; k++) {
            float t0 = k * (float)M_PI / 6, t1 = (k + 1) * (float)M_PI / 6, p[4][3];
            for (int i = 0; i < 3; i++) {
                p[0][i] = D.well[i] + (a[i] * cosf(t0) + b[i] * sinf(t0)) * r0; p[1][i] = D.well[i] + (a[i] * cosf(t0) + b[i] * sinf(t0)) * r1;
                p[2][i] = D.well[i] + (a[i] * cosf(t1) + b[i] * sinf(t1)) * r1; p[3][i] = D.well[i] + (a[i] * cosf(t1) + b[i] * sinf(t1)) * r0;
            }
            MAG_TRI(p[0], p[1], p[2], col); MAG_TRI(p[0], p[2], p[3], col);
        }
    }
    #undef MAG_TRI
    #undef MAG_NDC
    if (behind) n = overlay_start;
    if (!n) return;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture = out; pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = eye_encoder(cb, pass);
    [e setRenderPipelineState:g_mag_pso];
    id<MTLBuffer> vertices = [cb.device newBufferWithBytes:v length:n * sizeof *v options:MTLResourceStorageModeShared];
    if (!vertices) { [e endEncoding]; return; }
    [e setVertexBuffer:vertices offset:0 atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:n];
    [e endEncoding];
}

static int draw_eye_inner(void *cbp, int eye, const float view_from_origin[16], const float tan[4], float near_m, void *outp, void *odp, float *warp_M, int *warp_valid);
int vx_xros_vr_draw_eye(void *cbp, int eye, const float view_from_origin[16], const float tan[4], float near_m, void *outp, void *odp) {
    float warp_M[16]; int warp_valid = 0;
    int ok = draw_eye_inner(cbp, eye, view_from_origin, tan, near_m, outp, odp, warp_M, &warp_valid);
    {   // (VX Mac: the centre's density, once: with foveation the rate map's centre scale; px/deg = screen px per tangent x
        //  that scale x pi/180)
        static int told_fov;
        id<MTLRasterizationRateMap> m = g_rrm; id<MTLTexture> out = (__bridge id<MTLTexture>)outp;
        if (ok && !told_fov++) {
            float sw = m ? (float)m.screenSize.width : (float)out.width, sh = m ? (float)m.screenSize.height : (float)out.height, sc = 1;
            MTLSize ph = m ? [m physicalSizeForLayer:0] : MTLSizeMake(out.width, out.height, 1);
            if (m) {
                MTLCoordinate2D a = [m mapScreenToPhysicalCoordinates:(MTLCoordinate2D){ sw * 0.5f, sh * 0.5f } forLayer:0];
                MTLCoordinate2D b = [m mapScreenToPhysicalCoordinates:(MTLCoordinate2D){ sw * 0.5f + 16, sh * 0.5f } forLayer:0];
                sc = (b.x - a.x) / 16;
            }
            float ppd = sw / (tan[0] + tan[1]) * sc * (float)M_PI / 180;
            char f[400];
            snprintf(f, sizeof f, "\"foveation\":%d,\"screen\":[%.0f,%.0f],\"physical\":[%lu,%lu],\"texture\":[%lu,%lu],\"centre_scale\":%.3f,\"centre_px_per_deg\":%.1f,\"tan\":[%.3f,%.3f,%.3f,%.3f]",
                     m != nil, sw, sh, (unsigned long)ph.width, (unsigned long)ph.height, (unsigned long)out.width, (unsigned long)out.height, sc, ppd, tan[0], tan[1], tan[2], tan[3]);
            if (vx_host_jlog) vx_host_jlog("vr_eye_density", f);
        }
    }
    if (ok) { wc_update((__bridge id<MTLCommandBuffer>)cbp); draw_vignette((__bridge id<MTLCommandBuffer>)cbp, outp, tan, view_from_origin); draw_hud((__bridge id<MTLCommandBuffer>)cbp, outp, eye, tan); draw_mag((__bridge id<MTLCommandBuffer>)cbp, outp, view_from_origin, tan, eye, warp_valid ? warp_M : NULL); draw_fade((__bridge id<MTLCommandBuffer>)cbp, outp); draw_label((__bridge id<MTLCommandBuffer>)cbp, outp); }
    return ok;
}
static int draw_eye_inner(void *cbp, int eye, const float view_from_origin[16], const float tan[4], float near_m, void *outp, void *odp, float *warp_M, int *warp_valid) {
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
    pthread_mutex_lock(&g_lock);
    int s = g_frame_slot;
    double pt = g_present_time;
    if (eye >= 0 && eye < 2) memcpy(&g_tan_seen[0], tan, 4 * sizeof *tan);
    pthread_mutex_unlock(&g_lock);
    if (s < 0) return 0;
    vr_slot *S = &g_slot[s];
    id<MTLDevice> dev = cb.device;
    if (!g_core) {
        g_core = vxw_create((__bridge void *)dev);
        float zero[2] = { 0, 0 };
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float width:1 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        g_zero_mv = [dev newTextureWithDescriptor:td];
        [g_zero_mv replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:zero bytesPerRow:8];
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:1 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        g_far_depth = [dev newTextureWithDescriptor:td];
        vx_log("VR: warp core %s", g_core ? "ready" : "did not compile");
    }
    if (!g_core) return 0;
    if (screen_now()) return draw_screen(cb, S, view_from_origin, tan, near_m, outp, odp);
    // the eye from the camera the frame was shown from (both ARKit's right-up-back), then in the warp's right-up-forward
    float M[16];
    mul4(view_from_origin, S->head, M);
    vxw_params p = { 0 };
    p.w = S->w; p.h = S->h;
    p.flags = VXW_POSE | S->flags;
    p.tan_x = S->tan_x; p.tan_y = S->tan_y; p.z_a = S->z_a; p.z_b = S->z_b;
    // (VX Mac, h26: the gate was 55 ms / 100 ms: at the game's 28-31 fps the shown frame is 83-96 ms old, so eyes went
    //  between the depth warp and the far-plane one as the age crossed 100 ms (20 % of eyes) - the same scale jump as the
    //  zoom pulses. Now 110 ms / 250 ms: depth whenever the game is at a playable rate)
    int use_dibr = S->has_depth && (C.dibr == 1 || (C.dibr == 2 && S->interval <= 0.11 && pt - S->content_time < 0.25));
    static int warp_depth = -1; if (warp_depth < 0) { const char *e = getenv("VXMAC_WARP_DEPTH"); warp_depth = !(e && !strcmp(e, "0")); }
    if (!warp_depth) use_dibr = 0;                       // (VX Mac, h33: VXMAC_WARP_DEPTH=0 - rotation only, for an A/B)
    g_dibr_frames += use_dibr;
    // (VX Mac, method 3: the Neural Engine's layers of this very frame (app/Sources/npu_model.m, VXMAC_INTERP=1; off,
    //  or no result for this frame yet: none, and everything below is as before). With them the frame is predicted to
    //  this eye's time with the model's cleaned motion, its holes filled from the model's fill, weighted by its conf -
    //  needs the frame's own interval (its velocity's) and, in vr mode, the camera of the frame before (its turn is
    //  the head's, taken out of the motion: the pose reprojects it))
    void *i_tex = NULL; uint32_t i_w = 0, i_h = 0;
    int vxmac_interp_result(uint64_t seq, void **tex, uint32_t *w, uint32_t *h);
    int i_vel = interp_mode() == 2;
    int i_use = (i_vel ? S->has_vmv : vxmac_interp_result(S->pseq, &i_tex, &i_w, &i_h)) && C.predict && S->gap_before > 0.005 && S->gap_before < 0.4 &&
                (!vr_now() || S->has_prev);
    static int i_move = -1; if (i_move < 0) { const char *e = getenv("VXMAC_INTERP_MOVE"); i_move = e && !strcmp(e, "1"); }
    static const float sg[3] = { 1, 1, -1 };
    {   // (VX Mac, h37: the eye's position against the frame's camera (leaning, the neck, the eye's offset) - the depth warp's
        //  parallax, 6DoF; clamped to 15 cm: a frame that old is not moved further. The warp mode (L3+R3 held 1 s cycles it,
        //  vx_xros_vr_cycle_warp_mode): 0 depth + translation, 1 depth without translation, 2 no depth (rotation only),
        //  3 depth + translation within 3 cm)
        if (g_warp_mode < 0) {   // (h38: the start mode - 2, the frame turned whole like a monitor (no per-pixel depth): the
                                 //  user read the depth warp's parallax as distortion; VXMAC_WARP_MODE=0-5)
            g_warp_mode = warp_start_mode();
            vx_log("VR: warp mode %d at the start", g_warp_mode);
            if (vx_host_jlog) { char f[48]; snprintf(f, sizeof f, "\"mode\":%d,\"start\":1", g_warp_mode); vx_host_jlog("warp_mode", f); }
        }
        if (g_show_mode) { g_show_mode = 0; void show_warp_mode_label_ext(void); show_warp_mode_label_ext(); }   // (h47: the mode at head-look's start)
        float lim = g_warp_mode == 3 ? 0.03f : 0.15f;
        if (g_warp_mode == 1) { M[12] = M[13] = M[14] = 0; }
        float n = sqrtf(M[12] * M[12] + M[13] * M[13] + M[14] * M[14]);
        if (n > lim) { float k = lim / n; M[12] *= k; M[13] *= k; M[14] *= k; }
        if (g_warp_mode == 2) use_dibr = 0;
        if (g_warp_mode == 6 || g_warp_mode == 7) {   // (h64: 7 draws as 6) (6, the default since h38: the frame turned whole with the head (no head translation, no
                                  //  depth-dependent term from motion) and each eye's fixed half-IPD baseline from the depth
                                  //  - stereo that never changes with head motion: 3D without swimming. VXMAC_IPD (m, 0.064))
            static float ipd = -1; if (ipd < 0) { const char *e = getenv("VXMAC_IPD"); ipd = e && *e ? (float)atof(e) : 0.064f; }
            M[12] = (eye == 0 ? 0.5f : -0.5f) * ipd; M[13] = 0; M[14] = 0;   // (the centre camera seen from this eye)
            // (h60: the game camera's own motion since its frame - running, a vehicle - carried on to this eye's time:
            //  velocity x the frame's age, in the frame camera's axes, as a translation of the depth warp (at most
            //  VXMAC_MOVE_MAX m, default 0.3; VXMAC_MOVE=0 off): new frames no longer step forward every 50-150 ms)
            static int mv_on = -1; static float mv_max = 0.3f;
            if (mv_on < 0) { const char *e = getenv("VXMAC_MOVE"); mv_on = !(e && !strcmp(e, "0")); e = getenv("VXMAC_MOVE_MAX"); if (e && *e) mv_max = (float)atof(e); }
            // (method 3: not with the model's motion - the camera's own motion is in it (VXMAC_INTERP_MOVE=1: both))
            if (mv_on && use_dibr && S->cam_ok && vr_now() && !(i_use && !i_move)) {
                float age = (float)(pt - S->content_time); if (age < 0) age = 0; if (age > 0.2f) age = 0.2f;
                float dw[3] = { S->cam_vel[0] * age, S->cam_vel[1] * age, S->cam_vel[2] * age };
                float d[3] = { S->cam_rows[0] * dw[0] + S->cam_rows[1] * dw[1] + S->cam_rows[2] * dw[2],
                               S->cam_rows[3] * dw[0] + S->cam_rows[4] * dw[1] + S->cam_rows[5] * dw[2],
                               -(S->cam_rows[6] * dw[0] + S->cam_rows[7] * dw[1] + S->cam_rows[8] * dw[2]) };   // (right, up, back: ARKit's)
                float n = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
                if (n > mv_max) { float k = mv_max / n; d[0] *= k; d[1] *= k; d[2] *= k; }
                M[12] -= d[0]; M[13] -= d[1]; M[14] -= d[2];   // (the frame's camera as seen from the moved eye)
                pthread_mutex_lock(&g_lock); g_move_sum += n; g_move_n++; pthread_mutex_unlock(&g_lock);
            }
        }
        if (g_warp_mode == 5) {   // (5: no warp - the frame as rendered, in the eye's own view: head-locked between game frames)
            use_dibr = 0; M[12] = M[13] = M[14] = 0;
            for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) M[c * 4 + r] = r == c ? 1.f : 0.f;
        }
    }
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) p.rot[r * 3 + c] = sg[r] * M[c * 4 + r] * sg[c];
        p.pos[r] = sg[r] * M[12 + r] / C.scale * (use_dibr ? C.stereo : 1);
    }
    if (warp_M) {
        memcpy(warp_M, M, sizeof M);
        warp_M[12] = M[12] / C.scale * (use_dibr ? C.stereo : 1);
        warp_M[13] = M[13] / C.scale * (use_dibr ? C.stereo : 1);
        warp_M[14] = M[14] / C.scale * (use_dibr ? C.stereo : 1);
    }
    if (warp_valid) *warp_valid = 1;
    memcpy(p.dst_tan, tan, sizeof p.dst_tan);
    {   // (VX Mac, h43: the eye's roll against the frame's camera (the frame has none): the head's own tilt, for the log)
        float r = asinf(fmaxf(-1.f, fminf(1.f, p.rot[3]))) * 180 / (float)M_PI;   // (the eye's x axis' up component)
        pthread_mutex_lock(&g_lock); g_roll_sum += fabsf(r); g_roll_n++; if (fabsf(r) > g_roll_max) g_roll_max = fabsf(r); pthread_mutex_unlock(&g_lock);
    }
    {   // (VX Mac, h33: the rotation the warp applies this eye (the eye's forward against the frame's camera's), for the log)
        float c = p.rot[8]; c = c > 1 ? 1 : c < -1 ? -1 : c;
        float a = acosf(c) * 180 / (float)M_PI;
        pthread_mutex_lock(&g_lock); g_rot_sum += a; g_rot_n++; if (a > g_rot_max) g_rot_max = a; pthread_mutex_unlock(&g_lock);
    }
    if (eye >= 0 && eye < 2) {   // (h64: mode 7 - the frame's centre (the gun's aim) in this eye's tangents, for the crosshair)
        float ex = p.rot[2], ey = p.rot[5], ez = p.rot[8];
        g_xh_ok[eye] = aim_on() && ez > 0.2f;
        if (g_xh_ok[eye]) { g_xh[eye][0] = ex / ez; g_xh[eye][1] = ey / ez; }
    }
    {   // (how much of this eye's view lies outside the game's frame: a 16 x 16 grid of its directions, for the log)
        int out = 0;
        for (int j = 0; j < 16; j++) for (int i = 0; i < 16; i++) {
            float yx = -tan[0] + (tan[0] + tan[1]) * (i + 0.5f) / 16, yy = tan[2] - (tan[2] + tan[3]) * (j + 0.5f) / 16;
            float X[3];
            for (int r = 0; r < 3; r++) X[r] = p.rot[0 * 3 + r] * yx + p.rot[1 * 3 + r] * yy + p.rot[2 * 3 + r] * 1;
            if (X[2] <= 1e-4f || fabsf(X[0] / X[2]) > p.tan_x || fabsf(X[1] / X[2]) > p.tan_y) out++;
        }
        pthread_mutex_lock(&g_lock); g_outside_sum += out / 256.0f; g_outside_n++; pthread_mutex_unlock(&g_lock);
    }
    p.dst_near = C.depth_out && odp ? near_m / C.scale : 0;
    int use_depth = use_dibr;                            // (otherwise rotation only: everything far)
    // (method 3: the model's motion needs the depth's z-order (what passes in front of what) at any rate; outside the dibr
    //  gate it comes without the eyes' baseline - no parallax, as the far plane gave)
    if (i_use && !use_depth && S->has_depth && warp_depth) { use_depth = 1; p.pos[0] = p.pos[1] = p.pos[2] = 0; }
    id<MTLTexture> depth = use_depth ? S->depth : g_far_depth;
    if (!use_depth) {                                // (no depth: everything at the far plane)
        float far1 = S->flags & VXW_DEPTH_STD ? 1.0f : S->z_a / C.farp;
        [g_far_depth replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&far1 bytesPerRow:4];
    }
    // (while vr mode drives the camera the motion vectors hold the camera's own turn, which the pose already
    //  reprojects: predicted on as well it was counted twice, h2b's repeated neon. Its part is taken out first
    //  (VXW_CAM_MV, from the sent camera of the frame before): only the objects' own motion is predicted)
    int vr = vr_now();
    if (vr && C.predict_vr && S->has_mv && S->has_prev) {
        float ia[16], R[16];
        inv_rigid(S->prev_cam, ia);
        mul4(ia, S->head, R);                            // (A's camera from B's, ARKit's axes)
        for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) p.cam[r * 3 + c] = sg[r] * R[c * 4 + r] * sg[c];
        p.flags |= VXW_CAM_MV;
    }
    // (no prediction across long gaps: with game frames 150 ms or more apart, or this one that old, the motion of one
    //  frame says nothing about the next; h5's block noise at 4-8 fps)
    g_pred_eyes_total++;
    if (g_warp_mode == 5) i_use = 0;                     // (no warp: no prediction either)
    float i_conf_t = 0, i_conf_fade = 0;
    if (i_use) {   // (method 3: t = age / the frame's own interval, as in training (tau = gap / interval). The gate is the
                   //  model's: up to VXMAC_INTERP_MAX_MS (150) of age, where t is then held (no jump back); from
                   //  VXMAC_INTERP_FADE_MS (100) on, low-conf pixels' own motion fades towards conf x it; t at most
                   //  VXMAC_INTERP_TMAX (1.5: tests/interp_warp_mac.m on 1783 captured pairs - 4: 24.74 dB, 2: 25.06, 1.5:
                   //  25.21, 1.25: 25.25; further extrapolation of one interval's motion overshoots))
        static float max_s = -1, fade_s, tmax;
        if (max_s < 0) { const char *e = getenv("VXMAC_INTERP_MAX_MS"); max_s = (e && *e ? (float)atof(e) : 150) / 1e3f;
                         e = getenv("VXMAC_INTERP_FADE_MS"); fade_s = (e && *e ? (float)atof(e) : 100) / 1e3f; if (fade_s > max_s) fade_s = max_s;
                         e = getenv("VXMAC_INTERP_TMAX"); tmax = e && *e ? (float)atof(e) : 1.5f; }
        double age = pt - S->content_time; if (age < 0) age = 0;
        int held = age > max_s;
        double ag = held ? max_s : age;
        float t = (float)(ag / S->gap_before); p.t = t < 0 ? 0 : t > tmax ? tmax : t;
        if (vr && !(p.flags & VXW_CAM_MV)) {
            float ia[16], R[16];
            inv_rigid(S->prev_cam, ia);
            mul4(ia, S->head, R);
            for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) p.cam[r * 3 + c] = sg[r] * R[c * 4 + r] * sg[c];
            p.flags |= VXW_CAM_MV;
        }
        i_conf_t = p.t < 1 ? p.t : 1;
        // (VXMAC_INTERP_CONF: auto (default) uses the model's conf unless it has collapsed - mean under 0.05: run1's
        //  model gives 0.004 everywhere (tests/interp_warp_mac.m), a weight that says nothing; 1 always, 0 never)
        static int conf_mode = -1;
        if (conf_mode < 0) { const char *e = getenv("VXMAC_INTERP_CONF"); conf_mode = e && !strcmp(e, "1") ? 1 : e && !strcmp(e, "0") ? 0 : 2; }
        float vxmac_interp_conf_mean(void);
        int conf_off = i_vel || conf_mode == 0 || (conf_mode == 2 && vxmac_interp_conf_mean() < 0.05f);
        if (conf_off) i_conf_t = 0;
        i_conf_fade = max_s > fade_s ? (float)((age - fade_s) / (max_s - fade_s)) : (age >= max_s ? 1.f : 0.f);
        i_conf_fade = i_conf_fade < 0 ? 0 : i_conf_fade > 1 ? 1 : i_conf_fade * i_conf_fade * (3 - 2 * i_conf_fade);
        if (conf_off) i_conf_fade = 0;   // (a collapsed conf would stop every pixel's motion in the fade)
        pthread_mutex_lock(&g_lock);
        g_iw_eyes++; g_iw_conf_off += conf_off; g_iw_age_sum += age; if (age > g_iw_age_max) g_iw_age_max = age; g_iw_t_sum += p.t; g_iw_held += held;
        if (S->pseq != g_iw_last_seq) { g_iw_last_seq = S->pseq; g_iw_frames++; }
        g_iw_frame_used = 1;
        pthread_mutex_unlock(&g_lock);
    } else if (S->has_mv && C.predict && S->interval > 0 && S->interval < 0.15 && pt - S->content_time < 0.15 && (!vr || (p.flags & VXW_CAM_MV))) {
        g_pred_eyes++;
        float t = (float)((pt - S->content_time) / S->interval);
        p.t = t < 0 ? 0 : t > 2 ? 2 : t;
        p.mv_sx = S->mv_sx; p.mv_sy = S->mv_sy;
    }
    id<MTLTexture> mv = S->has_mv ? S->mv : g_zero_mv;
    if (i_use && i_vel) { mv = S->vmv; p.mv_sx = -S->vk[0] * (float)S->w; p.mv_sy = -S->vk[1] * (float)S->h; }   // (h63c: the raw velocity as motion vectors)
    void *a = NULL;
    if (p.flags & VXW_CAM_MV && S->prev_view) { a = (__bridge void *)S->prev_view; p.flags |= VXW_STILL; p.thr = 0.03f; }
    {   // (VX Mac: the Neural Engine's sharper centre of this very frame, when it is ready (app/Sources/fsr.m; off: none))
        int vxmac_fsr_detail(uint64_t seq, void **tex, float rect[4]);
        void *dt = NULL; float dr[4] = { 0 };
        int ok = g_guard_level < 2 && vxmac_fsr_detail(S->pseq, &dt, dr);
        if (ok) {   // (h42: an older result only while the camera has not turned since its frame (0.15 deg): at a turn's start
                    //  the old centre, shifted, flickered over the new frame)
            uint64_t vxmac_fsr_result_seq(void); uint64_t rs = vxmac_fsr_result_seq();
            if (rs != S->pseq) {
                pthread_mutex_lock(&g_lock);
                int known = g_stamp_at[rs % 64] == rs && g_stamp_at[S->pseq % 64] == S->pseq;
                float dyw = known ? fabsf(wrap180(g_stamp_y[S->pseq % 64] - g_stamp_y[rs % 64])) : 99, dpt = known ? fabsf(g_stamp_p[S->pseq % 64] - g_stamp_p[rs % 64]) : 99;
                pthread_mutex_unlock(&g_lock);
                if (dyw > 0.15f || dpt > 0.15f) ok = 0;
            }
        }
        vxw_set_detail(g_core, ok ? dt : NULL, dr);
    }
    {   // (VX Mac, method 3: the model's layers for this eye's encode, or none: the encode exactly as before)
        int lin = S->view && S->color && S->view.pixelFormat != S->color.pixelFormat;   // (sampled through an sRGB view)
        if (!vxw_set_interp(g_core, cbp, i_use && !i_vel ? i_tex : NULL, i_w, i_h, S->pseq, lin, i_conf_t, i_conf_fade) && i_use && !i_vel) {
            p.t = 0;   // (the layers could not be used (their pipelines): no prediction, as without them)
            pthread_mutex_lock(&g_lock); g_iw_eyes--; pthread_mutex_unlock(&g_lock);
        }
        pthread_mutex_lock(&g_lock); g_iw_total++; pthread_mutex_unlock(&g_lock);
    }
    // Carry the actual warp transform, including stereo scaling and camera motion, to the viewmodel.
    memset(warp_M, 0, 16*sizeof(float)); warp_M[15]=1;
    for (int r=0;r<3;r++) { for (int c=0;c<3;c++) warp_M[c*4+r]=sg[r]*p.rot[r*3+c]*sg[c]; warp_M[12+r]=sg[r]*p.pos[r]; }
    *warp_valid = 1;
    {   // The game's transformed geometry and the fallback warp must not both move the viewmodel.
        float delta[3], rot[3];
        static int (*pipe_active)(void); static dispatch_once_t once;
        dispatch_once(&once, ^{ pipe_active = dlsym(RTLD_DEFAULT, "vxpipe_viewmodel_active"); });
        static int warp_vm = -1;
        if (warp_vm < 0) { const char *e = getenv("VXMAC_WARP_VM"); warp_vm = e && !strcmp(e, "1"); }
        if (warp_vm && g_eff == 2 && vx_xros_vr_viewmodel_pose(delta, rot) && !(pipe_active && pipe_active()))
            vxw_set_viewmodel(g_core, delta, rot);
        else vxw_set_viewmodel(g_core, NULL, NULL);
    }
    vxw_set_rate_map(g_core, (__bridge void *)g_rrm);
    hud_mask_update(cb);                                 // (VX Mac: the HUD's mask, once per game frame)
    vxw_set_hud_mask(g_core, NULL);
    { float hr[16]; int hn = S->has_hud ? 0 : hud_shown_rects(hr); vxw_set_hud_rects(g_core, hr, hn); }   // (the originals of shown panels darkened)
    int ok;
    {   // (h60f: the warp at a lower internal size - VXMAC_WARP_SCALE (default 0.75) of the eye's texture, into a texture of
        //  our own, then one bilinear draw into the eye (its depth cleared far: rotational reprojection by the system). The
        //  warp is a gather over every output pixel (5.3-6.5 ms on M2 beside the game; 0.75 is 56 % of the pixels); missed
        //  deadlines put the app at 45 Hz for good (h60d). Not with foveation (its own logical size); 1: off)
        static float sc = -1; if (sc < 0) { const char *e = getenv("VXMAC_WARP_SCALE"); sc = e && *e ? (float)atof(e) : 1.0f; if (sc > 1 || sc < 0.3f) sc = 1; }   // (h60g: 1 by default until verified - Home launches (no -e) went black with 0.75 in h60f)
        id<MTLTexture> out = (__bridge id<MTLTexture>)outp;
        if (sc < 1 && !g_rrm && out) {
            static __strong id<MTLTexture> mid[2]; static __strong id<MTLRenderPipelineState> up; static MTLPixelFormat upf, upd;
            int ei = eye ? 1 : 0;
            NSUInteger mw = (NSUInteger)(out.width * sc), mh = (NSUInteger)(out.height * sc);
            if (!mid[ei] || mid[ei].width != mw || mid[ei].height != mh || mid[ei].pixelFormat != out.pixelFormat) {
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:out.pixelFormat width:mw height:mh mipmapped:NO];
                // (h60g: no shader write - the warp then draws it in a render pass, as it does the eye's own texture; an
                //  sRGB texture written by the compute gather is the prime suspect for h60f's black view)
                td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
                mid[ei] = [cb.device newTextureWithDescriptor:td];
                vx_log("VR: the warp at %.2f of the eye: %lux%lu, drawn up to %lux%lu", sc, (unsigned long)mw, (unsigned long)mh, (unsigned long)out.width, (unsigned long)out.height);
            }
            id<MTLTexture> od = (__bridge id<MTLTexture>)odp;
            if (!up || upf != out.pixelFormat || upd != (od ? od.pixelFormat : MTLPixelFormatInvalid)) {
                NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                    "struct V { float4 p [[position]]; float2 uv; };\n"
                    "vertex V uv_(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V o; o.p = float4(q * 2 - 1, 0, 1); o.uv = float2(q.x, 1 - q.y); return o; }\n"
                    "struct F { float4 c [[color(0)]]; float d [[depth(any)]]; };\n"
                    "fragment F uf(V i [[stage_in]], texture2d<float> t [[texture(0)]]) { constexpr sampler s(filter::linear, address::clamp_to_edge); F o; o.c = t.sample(s, i.uv); o.d = 0.02f; return o; }\n";   // (h60g: a real depth (near / 10 m), not 0: h60g's 0.75 run warped every eye yet showed black - depth 0 is the prime suspect (the system's composition treats it as no content); unverified, the path stays off by default)
                NSError *err = nil; id<MTLLibrary> lib = [cb.device newLibraryWithSource:src options:nil error:&err];
                MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
                pd.vertexFunction = [lib newFunctionWithName:@"uv_"]; pd.fragmentFunction = [lib newFunctionWithName:@"uf"];
                pd.colorAttachments[0].pixelFormat = out.pixelFormat; if (od) pd.depthAttachmentPixelFormat = od.pixelFormat;
                up = lib ? [cb.device newRenderPipelineStateWithDescriptor:pd error:&err] : nil; upf = out.pixelFormat; upd = od ? od.pixelFormat : MTLPixelFormatInvalid;
                if (!up) vx_log("VR: the warp's upscale: %s", err.localizedDescription.UTF8String);
            }
            ok = up ? vxw_encode_eye(g_core, cbp, &p, (__bridge void *)S->view, a, (__bridge void *)mv, (__bridge void *)depth, (__bridge void *)mid[ei], NULL) : 0;
            if (ok) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = out; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                if (od) { rp.depthAttachment.texture = od; rp.depthAttachment.loadAction = MTLLoadActionDontCare; rp.depthAttachment.storeAction = MTLStoreActionStore; }
                static __strong id<MTLDepthStencilState> dss;
                if (!dss) { MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES; dss = [cb.device newDepthStencilStateWithDescriptor:dd]; }
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                [re setRenderPipelineState:up]; if (od) [re setDepthStencilState:dss];
                [re setFragmentTexture:mid[ei] atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
            }
        } else ok = vxw_encode_eye(g_core, cbp, &p, (__bridge void *)S->view, a, (__bridge void *)mv, (__bridge void *)depth, outp,
                                   C.depth_out ? odp : NULL);
    }
    pthread_mutex_lock(&g_lock);
    if (ok) g_draws++;
    pthread_mutex_unlock(&g_lock);
    static int told;
    if (!told++) vx_log("VR: first eye: %s, frame %ux%u -> %lux%lu, frustum %.3f %.3f %.3f %.3f, game tan %.3f %.3f, depth %s, pos %.4f %.4f %.4f",
                        ok ? "warped" : "NOT encoded", S->w, S->h, (unsigned long)((__bridge id<MTLTexture>)outp).width,
                        (unsigned long)((__bridge id<MTLTexture>)outp).height, tan[0], tan[1], tan[2], tan[3], p.tan_x, p.tan_y,
                        S->has_depth ? "the game's" : "none (far)", p.pos[0], p.pos[1], p.pos[2]);
    return ok;
}

void vx_xros_vr_end_frame(void *cbp) {
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
    pthread_mutex_lock(&g_lock);
    int s = g_frame_slot;
    g_frame_slot = -1;
    if (!cb && s >= 0) g_slot[s].readers--;           // (a frame the compositor cancelled)
    int iu = g_iw_frame_used; g_iw_frame_used = 0;    // (method 3: this frame's eyes used the model's layers)
    pthread_mutex_unlock(&g_lock);
    if (!cb) return;
    void vxmtl_warp_begin(void), vxmtl_warp_end(void);   // (h55: the game's commits wait while the warp is on the GPU)
    vxmtl_warp_begin();
    [cb addCompletedHandler:^(id<MTLCommandBuffer> d) {
        vxmtl_warp_end();
        pthread_mutex_lock(&g_lock);
        if (s >= 0) g_slot[s].readers--;
        if (d.GPUEndTime > d.GPUStartTime) { g_gpu_ms += (d.GPUEndTime - d.GPUStartTime) * 1e3; g_gpu_n++;
            if (iu) { g_iw_gpu_ms += (d.GPUEndTime - d.GPUStartTime) * 1e3; g_iw_gpu_n++; } else { g_iw_gpu_ms0 += (d.GPUEndTime - d.GPUStartTime) * 1e3; g_iw_gpu_n0++; } }
        pthread_mutex_unlock(&g_lock);
    }];
}

// ---- hand input (VXRT_HAND): the app's hand tracking, each compositor frame ----
void vx_xros_hand_pointer(double x, double y);           // (src/xros_ui.m: the display's pointer, WM_MOUSEMOVE)
void vx_xros_hand_button(int which, int down);           // (0 left, 1 right: as a mouse's)
void vx_xros_hand_wheel(int delta);                      // (raw wheel input and WM_MOUSEWHEEL)
void vx_xros_hand_key(int hid_usage, int down);
extern int vx_xros_display_w, vx_xros_display_h;
static char g_hand_stats[400] = "\"hands\":\"none yet\"";
static int g_hand_stats_reset;
static char g_gesture_stats[240];                       // (VX Mac, h68: the hand gestures made, reload / melee / grenade / heal)
typedef struct {
    int pinched, phase;                 // (phase: 0 none, 1 pending, 2 drag or held, 3 scroll)
    double t0; float y0, y_last; float scroll_acc;
} hand_gesture;
static hand_gesture g_hg[2];
static float g_cur_u = 0.5f, g_cur_v = 0.5f, g_cur_hist[8][2]; static unsigned g_cur_n; static int g_cur_on;
static double g_up_at[2];               // (a click's button-up time, per button)
static unsigned g_clicks, g_rclicks, g_drags, g_scroll_notches, g_escs, g_tracked_frames[2], g_hand_frames;
static float dist3(const float *a, const float *b) { float x = a[0] - b[0], y = a[1] - b[1], z = a[2] - b[2]; return sqrtf(x * x + y * y + z * z); }
// The ray from o along d met with the screen: its place on the picture (0..1, y down). 0: it misses the plane.
static int screen_hit(const float *o, const float *d, float *u, float *v) {
    if (!g_screen_valid) return 0;
    float si[16]; inv_rigid(g_screen, si);
    float lo[3], ld[3];
    for (int r = 0; r < 3; r++) {
        lo[r] = si[r] * o[0] + si[4 + r] * o[1] + si[8 + r] * o[2] + si[12 + r];
        ld[r] = si[r] * d[0] + si[4 + r] * d[1] + si[8 + r] * d[2];
    }
    if (fabsf(ld[2]) < 1e-6f) return 0;
    float t = -lo[2] / ld[2];
    if (t <= 0) return 0;
    float hx = C.screen_m * tanf(C.screen_deg * 0.5f * (float)M_PI / 180);
    float hy = hx * (g_back_h ? (float)g_back_h / (float)(g_back_w ? g_back_w : 1) : 9.0f / 16);
    *u = ((lo[0] + ld[0] * t) / hx) * 0.5f + 0.5f;
    *v = 0.5f - ((lo[1] + ld[1] * t) / hy) * 0.5f;
    return 1;
}
// (h70: the hands' joints for the magazine by hand, from the same frame as the vx_xros_vr_hands call that follows)
static float g_joints[2 * HW_JOINTS], g_arms[14], g_skel[134];
void vx_xros_vr_hand_skeleton(const float skel[134]) { memcpy(g_skel, skel, sizeof g_skel); }
static unsigned g_controller_buttons;
static double g_controller_time;
static unsigned g_weapon_cycles;
void vx_xros_vr_cycle_weapon_type(void) {
    pthread_mutex_lock(&g_lock); g_weapon_cycles++; pthread_mutex_unlock(&g_lock);
}
void vx_xros_vr_hand_arms(const float arms[14]) { memcpy(g_arms, arms, sizeof g_arms); }
void vx_xros_vr_controller_state(unsigned btns, double now) {
    pthread_mutex_lock(&g_lock); g_controller_buttons = btns; g_controller_time = now; pthread_mutex_unlock(&g_lock);
}
unsigned vx_xros_vr_controller_buttons(double now) {
    pthread_mutex_lock(&g_lock); unsigned b = now - g_controller_time <= .25 ? g_controller_buttons : 0; pthread_mutex_unlock(&g_lock); return b;
}
void vx_xros_vr_hand_joints(const float joints[50]) { memcpy(g_joints, joints, sizeof g_joints); }
// hands: per hand (left, right) 10 floats in the room's frame: tracked (0/1), the thumb's tip, the index finger's
// tip, the pointing anchor (between the index finger's and the thumb's knuckles); head: origin from device.
// (VRIK: each hand's frame in the head's frame, for V's arms: the wrist, and axes forward (wrist -> middle knuckle),
//  across (little -> index knuckle), normal (forward x across); head: x right, y up, -z forward. Copied with the head of
//  the same frame, read by vxpipe.m on the game's render threads)
static float g_ik_head[16], g_ik_joints[2 * HW_JOINTS], g_ik_skel[134], g_ik_slide_pull, g_ik_weap[8];
static double g_ik_time; static pthread_mutex_t g_ik_lock = PTHREAD_MUTEX_INITIALIZER;
static float g_ik_sm[2][12]; static double g_ik_seen[2];

int vx_xros_vr_hand_frames(float out[2][12], int ok[2]) {
    float H[16], J[2 * HW_JOINTS]; double t, now = CACurrentMediaTime();
    pthread_mutex_lock(&g_ik_lock); memcpy(H, g_ik_head, sizeof H); memcpy(J, g_ik_joints, sizeof J); t = g_ik_time;
    int any = 0;
    for (int h = 0; h < 2; h++) {
        const float *j = J + h * HW_JOINTS; ok[h] = 0;
        int valid = (now - t <= 0.25 && j[0] >= 0.5f);
        float raw[12];
        if (valid) {
            const float *w = j + 1, *ik = j + 4, *mk = j + 7, *lk = j + 10;
            float wp[3], f[3], a[3], n[3];
            for (int i = 0; i < 3; i++) { float d = w[i] - H[12 + i]; wp[i] = d; f[i] = mk[i] - w[i]; a[i] = (h ? ik[i] - lk[i] : lk[i] - ik[i]); }
            float fl = sqrtf(f[0]*f[0] + f[1]*f[1] + f[2]*f[2]);
            float al_raw = sqrtf(a[0]*a[0] + a[1]*a[1] + a[2]*a[2]);
            if (fl >= 0.015f && al_raw >= 0.015f) {
                for (int i = 0; i < 3; i++) f[i] /= fl;
                float ad = a[0]*f[0] + a[1]*f[1] + a[2]*f[2]; for (int i = 0; i < 3; i++) a[i] -= ad * f[i];
                float al = sqrtf(a[0]*a[0] + a[1]*a[1] + a[2]*a[2]);
                if (al >= 1e-4f) {
                    for (int i = 0; i < 3; i++) a[i] /= al;
                    n[0] = f[1]*a[2] - f[2]*a[1]; n[1] = f[2]*a[0] - f[0]*a[2]; n[2] = f[0]*a[1] - f[1]*a[0];
                    const float *vs[4] = { wp, f, a, n };
                    for (int k = 0; k < 4; k++) for (int c = 0; c < 3; c++) raw[k * 3 + c] = vs[k][0] * H[c * 4 + 0] + vs[k][1] * H[c * 4 + 1] + vs[k][2] * H[c * 4 + 2];
                } else valid = 0;
            } else valid = 0;
        }
        if (valid) {
            if (now - g_ik_seen[h] > 0.30) {
                memcpy(g_ik_sm[h], raw, sizeof raw);
            } else {
                // Velocity-adaptive (1-Euro style) filter in head space: kills millimeter knuckle jitter while keeping fast motion lag-free
                float dp = dist3(raw, g_ik_sm[h]);
                float df = dist3(raw + 3, g_ik_sm[h] + 3);
                float da = dist3(raw + 6, g_ik_sm[h] + 6);
                float ap = fminf(0.85f, fmaxf(0.22f, dp * 18.0f));
                float af = fminf(0.80f, fmaxf(0.15f, df * 4.5f));
                float aa = fminf(0.70f, fmaxf(0.10f, da * 3.5f));
                for (int i = 0; i < 3; i++) {
                    g_ik_sm[h][i]     += (raw[i]     - g_ik_sm[h][i])     * ap;
                    g_ik_sm[h][3 + i] += (raw[3 + i] - g_ik_sm[h][3 + i]) * af;
                    g_ik_sm[h][6 + i] += (raw[6 + i] - g_ik_sm[h][6 + i]) * aa;
                }
                float *sf = g_ik_sm[h] + 3, *sa = g_ik_sm[h] + 6, *sn = g_ik_sm[h] + 9;
                float fl = sqrtf(sf[0]*sf[0] + sf[1]*sf[1] + sf[2]*sf[2]);
                if (fl > 1e-4f) { sf[0] /= fl; sf[1] /= fl; sf[2] /= fl; }
                float ad = sa[0]*sf[0] + sa[1]*sf[1] + sa[2]*sf[2];
                for (int i = 0; i < 3; i++) sa[i] -= ad * sf[i];
                float al = sqrtf(sa[0]*sa[0] + sa[1]*sa[1] + sa[2]*sa[2]);
                if (al > 1e-4f) { sa[0] /= al; sa[1] /= al; sa[2] /= al; }
                sn[0] = sf[1]*sa[2] - sf[2]*sa[1]; sn[1] = sf[2]*sa[0] - sf[0]*sa[2]; sn[2] = sf[0]*sa[1] - sf[1]*sa[0];
            }
            g_ik_seen[h] = now;
        }
        if (now - g_ik_seen[h] <= 0.25) {
            memcpy(out[h], g_ik_sm[h], sizeof(float) * 12);
            ok[h] = 1; any = 1;
        }
    }
    pthread_mutex_unlock(&g_ik_lock);
    return any;
}

int vx_xros_vr_hand_curls(float out[2][6], float weap_out[8]) {
    static float sm_curls[2][6] = { { 0.25f, 0.25f, 0.25f, 0.25f, 0.25f, 0.0f }, { 0.25f, 0.25f, 0.25f, 0.25f, 0.25f, 0.0f } };
    float S[134], J[2 * HW_JOINTS]; double t, now = CACurrentMediaTime();
    pthread_mutex_lock(&g_ik_lock);
    memcpy(S, g_ik_skel, sizeof S); memcpy(J, g_ik_joints, sizeof J); t = g_ik_time;
    if (weap_out) memcpy(weap_out, g_ik_weap, sizeof g_ik_weap);
    if (now - t <= 0.25) {
        for (int h = 0; h < 2; h++) {
            const float *sk = S + h * 67;
            const float *hj = J + h * HW_JOINTS;
            float raw[6]; memcpy(raw, sm_curls[h], sizeof raw);
            int got = 0;
            if (sk[0] > 0.5f) {
                const float *W  = sk + 1 + 1 * 3;
                const float *TT = sk + 1 + 5 * 3;
                const float *IK = sk + 1 + 7 * 3,  *IT = sk + 1 + 9 * 3;
                const float *MK = sk + 1 + 11 * 3, *MT = sk + 1 + 13 * 3;
                const float *RK = sk + 1 + 15 * 3, *RT = sk + 1 + 17 * 3;
                const float *LK = sk + 1 + 19 * 3, *LT = sk + 1 + 21 * 3;
                float d_mw = dist3(MK, W);
                if (d_mw > 0.02f) {
                    const float *ks[4] = { IK, MK, RK, LK }, *ts[4] = { IT, MT, RT, LT };
                    float avg = 0;
                    for (int f = 0; f < 4; f++) {
                        float dk = dist3(ks[f], W);
                        float r = dk > 0.02f ? dist3(ts[f], W) / dk : 1.55f;
                        raw[1 + f] = fminf(1.0f, fmaxf(0.0f, (1.76f - r) / (1.76f - 1.04f)));
                        avg += raw[1 + f] * 0.25f;
                    }
                    float rt = dist3(TT, MK) / d_mw;
                    raw[0] = fminf(1.0f, fmaxf(0.0f, (0.95f - rt) / (0.95f - 0.42f)));
                    float kw = dist3(IK, LK);
                    float sp = kw > 0.02f ? dist3(IT, LT) / kw : 1.2f;
                    raw[5] = fminf(1.0f, fmaxf(0.0f, (sp - 1.08f) / (1.65f - 1.08f))) * (1.0f - 0.75f * avg);
                    got = 1;
                }
            } else if (hj[0] > 0.5f) {
                const float *pt = hj + 1;
                const float *W = pt + HW_WRIST * 3, *IK = pt + HW_INDEX_K * 3, *MK = pt + HW_MIDDLE_K * 3, *LK = pt + HW_LITTLE_K * 3;
                const float *IT = pt + HW_INDEX_T * 3, *MT = pt + HW_MIDDLE_T * 3, *RT = pt + HW_RING_T * 3, *LT = pt + HW_LITTLE_T * 3;
                float km = dist3(MK, W), ki = dist3(IK, W), kl = dist3(LK, W);
                if (km > 0.02f && ki > 0.02f && kl > 0.02f) {
                    float rs[4] = { dist3(IT, W) / ki, dist3(MT, W) / km, dist3(RT, W) / km, dist3(LT, W) / kl };
                    float avg = 0;
                    for (int f = 0; f < 4; f++) {
                        raw[1 + f] = fminf(1.0f, fmaxf(0.0f, (1.76f - rs[f]) / (1.76f - 1.04f)));
                        avg += raw[1 + f] * 0.25f;
                    }
                    raw[0] = avg;
                    float kw = dist3(IK, LK);
                    float sp = kw > 0.02f ? dist3(IT, LT) / kw : 1.2f;
                    raw[5] = fminf(1.0f, fmaxf(0.0f, (sp - 1.08f) / (1.65f - 1.08f))) * (1.0f - 0.75f * avg);
                    got = 1;
                }
            }
            if (got) {
                for (int c = 0; c < 6; c++) sm_curls[h][c] += (raw[c] - sm_curls[h][c]) * 0.35f;
            }
        }
    }
    memcpy(out, sm_curls, sizeof sm_curls);
    pthread_mutex_unlock(&g_ik_lock);
    return 1;
}

void vx_xros_vr_hands(const float head[16], const float hands[20], double now) {
    config();
    pthread_mutex_lock(&g_ik_lock); memcpy(g_ik_head, head, sizeof g_ik_head); memcpy(g_ik_joints, g_joints, sizeof g_ik_joints); memcpy(g_ik_skel, g_skel, sizeof g_ik_skel); g_ik_time = CACurrentMediaTime(); pthread_mutex_unlock(&g_ik_lock);
    if (!C.hand) { pthread_mutex_lock(&g_lock); g_vm_active = 0; memset(g_vm_delta, 0, sizeof g_vm_delta); memset(g_vm_rot, 0, sizeof g_vm_rot); pthread_mutex_unlock(&g_lock); return; }
    if (g_hand_stats_reset) { g_hand_stats_reset = 0; g_clicks = g_rclicks = g_drags = g_scroll_notches = g_escs = 0; g_tracked_frames[0] = g_tracked_frames[1] = 0; g_hand_frames = 0; }
    g_hand_frames++;
    for (int b = 0; b < 2; b++) if (g_up_at[b] > 0 && now >= g_up_at[b]) { g_up_at[b] = 0; vx_xros_hand_button(b, 0); }
    int tr[2] = { hands[0] > 0.5f, hands[10] > 0.5f };
    for (int h = 0; h < 2; h++) if (tr[h]) g_tracked_frames[h]++;
    int prim = tr[1] ? 1 : tr[0] ? 0 : -1, sec = prim < 0 ? -1 : 1 - prim;
    int scr = screen_now(), vr = vr_now();
    // the pointer: the ray through the primary hand's anchor
    int hit = 0; float u = 0, v = 0;
    if (prim >= 0 && scr) {
        const float *a = hands + prim * 10 + 7;
        float o[3] = { head[12], head[13] - (C.hand_shoulder ? 0.15f : 0), head[14] };
        if (C.hand_shoulder) {                            // (the shoulder: across from the head's yaw, its own side)
            float fx = -head[8], fz = -head[10], n = sqrtf(fx * fx + fz * fz); if (n < 1e-3f) { fx = 0; fz = -1; n = 1; }
            fx /= n; fz /= n; float side = prim ? 0.18f : -0.18f;
            o[0] += -fz * side; o[2] += fx * side;
        }
        float d[3] = { a[0] - o[0], a[1] - o[1], a[2] - o[2] };
        hit = screen_hit(o, d, &u, &v);
    }
    // the gestures
    for (int h = 0; h < 2; h++) {
        hand_gesture *g = &g_hg[h];
        const float *H = hands + h * 10;
        float pd = tr[h] ? dist3(H + 1, H + 4) : 1;
        int was = g->pinched;
        g->pinched = tr[h] && (was ? pd < 0.03f : pd < 0.015f);
        int is_prim = h == prim, is_sec = h == sec;
        float y = H[8];
        if (g->pinched && !was) {
            g->t0 = now; g->y0 = g->y_last = y; g->scroll_acc = 0; g->phase = 1;
            if (is_prim && scr && g_cur_n >= 6) {         // (the pointer from just before the pinch: the pinch moves the hand)
                g_cur_u = g_cur_hist[(g_cur_n - 6) % 8][0]; g_cur_v = g_cur_hist[(g_cur_n - 6) % 8][1];
                vx_xros_hand_pointer(g_cur_u * vx_xros_display_w, g_cur_v * vx_xros_display_h);
            }
            // (h39: in vr mode a pinch no longer holds a mouse button (the game is played on the controller; a long pinch
            //  fired the gun) - VXMAC_VR_PINCH_BUTTONS=1 restores it; held 1 s it cycles the warp mode instead)
            static int vr_btn = -1; if (vr_btn < 0) { const char *e = getenv("VXMAC_VR_PINCH_BUTTONS"); vr_btn = e && !strcmp(e, "1"); }
            if (vr_btn && is_prim && vr) { vx_xros_hand_button(0, 1); g->phase = 2; }
            if (vr_btn && is_sec && vr) { vx_xros_hand_button(1, 1); g->phase = 2; }
        } else if (g->pinched) {
            if (vr && g->phase == 1 && now - g->t0 >= 1.0 && !g_hg[1 - h].pinched && now - g_ctrl_t > 2.0) {   // (h39: a pinch held 1 s in vr mode: the next warp mode; not with both hands)
                g->phase = 4; void vx_xros_vr_cycle_warp_mode(void);
                vx_xros_vr_cycle_warp_mode();   // (the hands' state is not under g_lock here)
            }
            if (is_prim && scr && g->phase == 1) {
                if (fabsf(y - g->y0) > 0.025f) { g->phase = 3; g->y_last = y; }
                else if (now - g->t0 > 0.3 && !(sec >= 0 && g_hg[sec].pinched)) { g->phase = 2; vx_xros_hand_button(0, 1); g_drags++; }
            }
            if (is_prim && g->phase == 3) {               // (hand up: the content up, as a touch drag: wheel down)
                g->scroll_acc += (y - g->y_last) * 100; g->y_last = y;
                while (g->scroll_acc >= C.scroll_cm) { g->scroll_acc -= C.scroll_cm; vx_xros_hand_wheel(-120); g_scroll_notches++; }
                while (g->scroll_acc <= -C.scroll_cm) { g->scroll_acc += C.scroll_cm; vx_xros_hand_wheel(120); g_scroll_notches++; }
            }
            if (is_sec && !vr && g->phase == 1 && now - g->t0 > 0.6 && !(prim >= 0 && g_hg[prim].pinched)) { g->phase = 2; vx_xros_hand_key(0x29, 1); g_escs++; }
        } else if (was) {
            if (g->phase == 2) {
                if (vr) vx_xros_hand_button(is_sec ? 1 : 0, 0);
                else if (is_sec) vx_xros_hand_key(0x29, 0);
                else vx_xros_hand_button(0, 0);
            } else if (g->phase == 1 && scr) {
                if (is_prim) { vx_xros_hand_button(0, 1); g_up_at[0] = now + 0.06; g_clicks++; }
                else if (is_sec) { vx_xros_hand_button(1, 1); g_up_at[1] = now + 0.06; g_rclicks++; }
            }
            g->phase = 0;
        }
        if (!tr[h] && g->phase == 2) {                    // (a hand lost while it held a button)
            if (vr || !is_sec) vx_xros_hand_button(vr && is_sec ? 1 : 0, 0); else vx_xros_hand_key(0x29, 0);
            g->phase = 0; g->pinched = 0;
        }
    }
    // both hands' pinch held still for 1 s: the manual vr / screen toggle (the pinches then do nothing more)
    {
        static double both_since, quit_ask_until; static float both_y[2]; static int both_done, both_armed;
        if (g_hg[0].pinched && g_hg[1].pinched) {
            if (!both_since) { both_since = now; both_y[0] = hands[8]; both_y[1] = hands[18]; both_done = 0; }
            int still = fabsf(hands[8] - both_y[0]) < 0.05f && fabsf(hands[18] - both_y[1]) < 0.05f;
            if (!still) both_done = 1;
            // (h49: 1 s, and not within 2 s of controller input - holding the Joy-Cons read as both hands pinching and
            //  toggled VR / Screen at random in h48)
            // (h53: held 1 s the pinches are let go and wait: on release before 3 s the vr / screen toggle; held 3 s the
            //  quit question ("Quit? pinch both hands again", 6 s); a both-hands pinch then (0.4 s) quits the game through
            //  its own path (host.m vxmac_request_quit))
            if (!both_done && now - both_since >= (now < quit_ask_until ? 0.4 : 1.0) && now - g_ctrl_t > 2.0 && both_armed == 0) {
                for (int h = 0; h < 2; h++) {             // (whatever the pinches held is let go; their release does nothing)
                    if (g_hg[h].phase == 2) { if (vr) vx_xros_hand_button(h == sec ? 1 : 0, 0); else if (h == sec) vx_xros_hand_key(0x29, 0); else vx_xros_hand_button(0, 0); }
                    g_hg[h].phase = 4;
                }
                both_armed = 1;
                if (now < quit_ask_until) { both_armed = 3; both_done = 1; quit_ask_until = 0; void vxmac_request_quit(const char *); show_label(ui_str(10));
                    pthread_mutex_lock(&g_lock); g_label_until = now + 3; g_label_big = 1; pthread_mutex_unlock(&g_lock); vxmac_request_quit("both-hands pinch"); }
            }
            if (both_armed == 1 && !both_done && now - both_since >= 3.0) {
                both_armed = 2; both_done = 1; quit_ask_until = now + 6;
                show_label(ui_str(9));
                pthread_mutex_lock(&g_lock); g_label_until = now + 6; g_label_big = 1; pthread_mutex_unlock(&g_lock);
            }
        } else {
            if (both_armed == 1 && both_since && now - both_since < 3.0) vx_xros_vr_toggle_vr();
            both_since = 0; both_armed = 0;
        }
    }
    // (VX Mac, h68: the game's actions from the hands' motion in vr mode's 3D view - hand_gestures.h; VXMAC_GESTURES=0 turns them off)
    {
        static int on = -1, labels; static hand_gestures hg; static double up_at[HG_N]; static int act[HG_N];
        if (on < 0) {
            const char *e = getenv("VXMAC_GESTURES"); on = !(e && !strcmp(e, "0"));
            e = getenv("VXMAC_GESTURE_LABELS"); labels = e && !strcmp(e, "1");
            e = getenv("VXMAC_GESTURE_LEFTY"); hg.lefty = e && !strcmp(e, "1");
            // (the game's default bindings: Reload R, QuickMelee Q, CombatGadget the middle button, UseConsumable X;
            //  VXMAC_GESTURE_KEYS="reload=15,melee=14,grenade=m2,heal=1b" - a HID keyboard usage in hex, or m0-m2 a mouse button)
            act[0] = 0x15; act[1] = 0x14; act[2] = -3; act[3] = 0x1B; act[4] = 0x09; act[5] = 0x2B;
            static const char *names[HG_N] = { "reload", "melee", "grenade", "heal", "interact", "scan" };
            if ((e = getenv("VXMAC_GESTURE_KEYS")))
                for (int i = 0; i < HG_N; i++) {
                    char k[16]; snprintf(k, sizeof k, "%s=", names[i]);
                    const char *v = strstr(e, k); if (!v) continue;
                    v += strlen(k);
                    act[i] = v[0] == 'm' ? -1 - (int)strtol(v + 1, NULL, 10) : (int)strtol(v, NULL, 16);
                }
            if (on && (e = getenv("VXMAC_GESTURE_TUNE"))) hand_gestures_tune(e);
            if (on) { char pr[512]; hand_gestures_params(pr, sizeof pr); vx_log("VR: hand gesture thresholds %s", pr); }
            if (on) vx_log("VR: hand gestures on (gun hand %s): reload %s%x, melee %s%x, grenade %s%x, heal %s%x", hg.lefty ? "left" : "right",
                           act[0] < 0 ? "mouse " : "key 0x", act[0] < 0 ? -1 - act[0] : act[0], act[1] < 0 ? "mouse " : "key 0x", act[1] < 0 ? -1 - act[1] : act[1],
                           act[2] < 0 ? "mouse " : "key 0x", act[2] < 0 ? -1 - act[2] : act[2], act[3] < 0 ? "mouse " : "key 0x", act[3] < 0 ? -1 - act[3] : act[3]);
        }
        for (int i = 0; i < HG_N; i++) if (up_at[i] > 0 && now >= up_at[i]) {
            up_at[i] = 0;
            if (act[i] < 0) vx_xros_hand_button(-1 - act[i], 0); else vx_xros_hand_key(act[i], 0);
        }
        // (the first VXMAC_HAND_RECORD=5 minutes of hands with the gestures on, each frame a CSV line - time, vr, the
        //  head's 16, the hands' 20, the gestures made - in Documents/hand_record.csv, for tests/hand_gestures_replay.c)
        static FILE *rec; static double rec_until = -1;
        if (on && rec_until < 0) {
            const char *e = getenv("VXMAC_HAND_RECORD"); double mins = e && *e ? atof(e) : 5;
            rec_until = 0;
            if (mins > 0 && getenv("HOME")) {
                char path[1024]; snprintf(path, sizeof path, "%s/Documents/hand_record.csv", getenv("HOME"));
                if ((rec = fopen(path, "w"))) { rec_until = now + mins * 60; vx_log("VR: hand record to %s for %.0f min", path, mins); }
            }
        }
        // (h70: the magazine by hand - hand_weapon.h; VXMAC_MAG=1. It takes the place of the reload gesture above.)
        static int mag = -1, mag_labels; static hand_weapon hw; static int mact[HW_EV_N]; static double mup_at[HW_EV_N];
        static FILE *prec; static double prec_until = -1;
        if (mag < 0) {
            const char *e = getenv("VXMAC_MAG"); mag = !(e && !strcmp(e, "0"));
            e = getenv("VXMAC_HAND_MODE");
            hw.mode = e && !strcmp(e, "bare") ? HW_MODE_BARE : e && !strcmp(e, "hybrid") ? HW_MODE_HYBRID : HW_MODE_AUTO;
            e = getenv("VXMAC_AUTO_MAG"); hand_weapon_set_auto_mag(&hw, !(e && !strcmp(e, "0")));
            e = getenv("VXMAC_MAG_RACK"); hw.rack = !(e && !strcmp(e, "0"));
            e = getenv("VXMAC_GESTURE_LEFTY"); hw.lefty = e && !strcmp(e, "1");
            e = getenv("VXMAC_GESTURE_LABELS"); mag_labels = !(e && !strcmp(e, "0"));
            // (the keys: the game's reload (R) when the magazine is in (and racked); VXMAC_MAG_KEYS="out=..,grab=..,
            //  in=..,rack=..,done=15,cancel=.." gives a step its own key - for the VX Hands mod - a HID usage in hex or m0-m2)
            for (int i = 0; i < HW_EV_N; i++) mact[i] = 0;
            mact[4] = 0x15;
            static const char *names[HW_EV_N] = { "out", "grab", "in", "rack", "done", "cancel" };
            if ((e = getenv("VXMAC_MAG_KEYS")))
                for (int i = 0; i < HW_EV_N; i++) {
                    char k[16]; snprintf(k, sizeof k, "%s=", names[i]);
                    const char *v = strstr(e, k); if (!v) continue;
                    v += strlen(k);
                    mact[i] = v[0] == 'm' ? -1 - (int)strtol(v + 1, NULL, 10) : (int)strtol(v, NULL, 16);
                }
            if (mag && (e = getenv("VXMAC_MAG_TUNE"))) hand_weapon_tune(e);
            if (mag) { char pr[512]; hand_weapon_params(pr, sizeof pr); vx_log("VR: magazine by hand on (gun hand %s, rack %d, done key 0x%x): %s", hw.lefty ? "left" : "right", hw.rack, mact[4], pr); }
        }
        for (int i = 0; i < HW_EV_N; i++) if (mup_at[i] > 0 && now >= mup_at[i]) {
            mup_at[i] = 0;
            if (mact[i] < 0) vx_xros_hand_button(-1 - mact[i], 0); else vx_xros_hand_key(mact[i], 0);
        }
        if (mag && prec_until < 0) {            // (the joints' record: Documents/hand_pose_record.csv, tests/hand_weapon_replay.c)
            const char *e = getenv("VXMAC_HAND_RECORD"); double mins = e && *e ? atof(e) : 5;
            prec_until = 0;
            if (mins > 0 && getenv("HOME")) {
                char path[1024]; snprintf(path, sizeof path, "%s/Documents/hand_pose_record.csv", getenv("HOME"));
                if ((prec = fopen(path, "w"))) { prec_until = now + mins * 60; vx_log("VR: hand pose record to %s for %.0f min", path, mins); }
            }
        }
        unsigned controller, cycles; double controller_time;
        pthread_mutex_lock(&g_lock); controller = g_controller_buttons; controller_time = g_controller_time; cycles = g_weapon_cycles; g_weapon_cycles = 0; pthread_mutex_unlock(&g_lock);
        if (now - controller_time > .25) controller = 0;
        hw.weapon_type = (hw.weapon_type + cycles % HW_WPN_N) % HW_WPN_N;
        hand_weapon_set_controller(&hw, controller, controller_time);
        hand_weapon_set_arms(&hw, g_arms);
        int mb = 0;
        if (mag && vr) {
            mb = hand_weapon_update(&hw, head, g_joints, now);
            for (int i = 0; i < HW_EV_N; i++) if (mb & (1 << i)) {
                vx_log("VR: magazine %s (%s)", hand_weapon_event_name(1 << i), hand_weapon_state_name(hw.state));
                if (mact[i] && !mup_at[i]) {
                    if (mact[i] < 0) vx_xros_hand_button(-1 - mact[i], 1); else vx_xros_hand_key(mact[i], 1);
                    mup_at[i] = now + 0.08;
                }
            }
            int shown = mb & ~HW_EV_DONE; if (hw.rack && (mb & HW_EV_RACK)) shown = HW_EV_RACK;
            if (mag_labels && shown) {          // (a short label for the step: out, a new one, in, racked, cancelled)
                static const char *ms[8][HW_EV_N] = {
                    { "Magazine out", "New magazine", "Magazine in", "Chambered", "", "Reload cancelled" },
                    { "マガジンを抜いた", "新しいマガジン", "マガジンを差した", "装填", "", "リロード中止" },
                    { "弹匣已取出", "新弹匣", "弹匣已插入", "已上膛", "", "取消装弹" },
                    { "彈匣已取出", "新彈匣", "彈匣已插入", "已上膛", "", "取消裝彈" },
                    { "탄창 분리", "새 탄창", "탄창 장착", "장전 완료", "", "재장전 취소" },
                    { "Chargeur retiré", "Nouveau chargeur", "Chargeur inséré", "Chambré", "", "Rechargement annulé" },
                    { "Magazin raus", "Neues Magazin", "Magazin drin", "Durchgeladen", "", "Nachladen abgebrochen" },
                    { "Cargador fuera", "Cargador nuevo", "Cargador dentro", "Recámara cargada", "", "Recarga cancelada" } };
                int i = 0; while (i < HW_EV_N - 1 && !(shown & (1 << i))) i++;
                if (shown & HW_EV_RACK) i = 3;
                if (ms[ui_lang()][i][0]) {
                    show_label(ms[ui_lang()][i]);
                    pthread_mutex_lock(&g_lock); g_label_until = now + 0.7; g_label_big = 0; pthread_mutex_unlock(&g_lock);
                }
            }
        }
        // (h70b: the gun drawn, put away, aimed and fired by hand - VXMAC_ARMS=1; the trigger only with VXMAC_TRIGGER=1.
        //  The keys: weapon 1 (1), weapon 2 (2), holster (B), aim held (the right button), trigger held (the left);
        //  VXMAC_ARMS_KEYS="hip=1e,back=1f,holster=05,aim=m1,trigger=m0")
        static int arms = -1, trig_on, akey[5], aim_down, trig_down; static double aup_at[3];
        if (arms < 0) {
            const char *e = getenv("VXMAC_ARMS"); arms = !(e && !strcmp(e, "0"));
            e = getenv("VXMAC_TRIGGER"); trig_on = e && !strcmp(e, "1");
            akey[0] = 0x1E; akey[1] = 0x1F; akey[2] = 0x05; akey[3] = -2; akey[4] = -1;
            static const char *names[5] = { "hip", "back", "holster", "aim", "trigger" };
            if ((e = getenv("VXMAC_ARMS_KEYS")))
                for (int i = 0; i < 5; i++) {
                    char k[16]; snprintf(k, sizeof k, "%s=", names[i]);
                    const char *v = strstr(e, k); if (!v) continue;
                    v += strlen(k);
                    akey[i] = v[0] == 'm' ? -1 - (int)strtol(v + 1, NULL, 10) : (int)strtol(v, NULL, 16);
                }
            if (arms) vx_log("VR: the gun by hand on (draw, holster, aim%s)", trig_on ? ", trigger" : "");
        }
        #define AKEY(k, d) do { if ((k) < 0) vx_xros_hand_button(-1 - (k), d); else if (k) vx_xros_hand_key(k, d); } while (0)
        for (int i = 0; i < 3; i++) if (aup_at[i] > 0 && now >= aup_at[i]) { aup_at[i] = 0; AKEY(akey[i], 0); }
        int grab = 0;
        if ((arms || mag) && vr) {
            if (!mag) hand_weapon_update(&hw, head, g_joints, now);   // (the arms use the magazine's state and the grip's line)
            int ab = hand_weapon_arms(&hw, head, g_joints, now, trig_on);
            grab = ab & HW_ARM_INTERACT;
            for (int i = 0; i < 3; i++) if (arms && (ab & (1 << i)) && !aup_at[i]) {
                AKEY(akey[i], 1); aup_at[i] = now + 0.08;
                static const char *an[3] = { "draw (hip)", "draw (back)", "holster" };
                vx_log("VR: gun %s", an[i]);
            }
        }
        static int auto_draw_done;
        if (!vr) auto_draw_done = 0;
        hand_pose *draw_gun = &hw.pose[hw.lefty ? 0 : 1];
        if (arms && vr && !auto_draw_done && !hw.weapon_drawn && draw_gun->ok &&
            draw_gun->palm[1] - head[13] > -.38f && !aup_at[0] && !aup_at[1] && !aup_at[2] && akey[0]) {
            AKEY(akey[0], 1); aup_at[0] = now + .08; hw.weapon_drawn = 1; auto_draw_done = 1;
            vx_log("VR: gun draw (raised hand)");
        }
        static int hand_ads = -1;
        if (hand_ads < 0) { const char *e = getenv("VXMAC_HAND_ADS"); hand_ads = e && !strcmp(e, "1"); }
        int want_aim = arms && hand_ads && vr && hw.ads && !hand_weapon_is_hybrid(&hw, now);
        int want_trig = arms && trig_on && vr && hw.trigger && !hand_weapon_is_hybrid(&hw, now);
        if (want_aim != aim_down) { aim_down = want_aim; AKEY(akey[3], aim_down); }
        if (want_trig != trig_down) { trig_down = want_trig; AKEY(akey[4], trig_down); }
        #undef AKEY
        pthread_mutex_lock(&g_lock);
        int off_hand = hw.lefty ? 1 : 0;
        hand_pose *visual_off = &hw.pose[off_hand];
        static float last_skel[134], last_palm[2][3]; static double last_skel_at[2];
        for (int h = 0; h < 2; h++) {
            float *dst = g_mag_draw.skel + h * 67, *src = g_skel + h * 67;
            if (src[0] > .5f) {
                memcpy(dst, src, 67 * sizeof(float)); memcpy(last_skel + h * 67, src, 67 * sizeof(float));
                if (hw.pose[h].ok) memcpy(last_palm[h], hw.pose[h].palm, sizeof last_palm[h]);
                else memcpy(last_palm[h], src + 4, sizeof last_palm[h]);
                last_skel_at[h] = now;
            } else if (last_skel_at[h] > 0 && now - last_skel_at[h] <= .35 && hw.pose[h].ok) {
                memcpy(dst, last_skel + h * 67, 67 * sizeof(float));
                for (int j = 0; j < 22; j++) for (int i = 0; i < 3; i++)
                    dst[1 + j * 3 + i] += hw.pose[h].palm[i] - last_palm[h][i];
            } else memset(dst, 0, 67 * sizeof(float));
            g_mag_draw.pinch[h] = g_hg[h].pinched;
        }
        hand_pose *gun = &hw.pose[hw.lefty ? 0 : 1];
        float rel_g[3] = { gun->palm[0]-head[12], gun->palm[1]-head[13], gun->palm[2]-head[14] };
        float lp[3] = { vdot(rel_g,head), vdot(rel_g,head+4), vdot(rel_g,head+8) };
        float rel_o[3] = { visual_off->palm[0]-head[12], visual_off->palm[1]-head[13], visual_off->palm[2]-head[14] };
        float lo[3] = { vdot(rel_o,head), vdot(rel_o,head+4), vdot(rel_o,head+8) };
        const float rest_lp[3] = { hw.lefty ? -0.18f : 0.18f, -0.26f, -0.34f };
        const float rest_lo[3] = { hw.lefty ? 0.18f : -0.18f, -0.26f, -0.34f };
        int rest_ok = gun->ok && vr, rest_off_ok = visual_off->ok && vr;
        const float neutral_lf[3] = { 0, 0, -1 }, neutral_lu[3] = { 0, 1, 0 };
        for(int i=0;i<3;i++) {
            g_mag_draw.neutral_palm[i]=head[12+i]; g_mag_draw.off_neutral[i]=head[12+i];
            g_mag_draw.neutral_fwd[i]=g_mag_draw.neutral_up[i]=0;
            for(int j=0;j<3;j++) { g_mag_draw.neutral_palm[i]+=head[4*j+i]*(rest_ok ? rest_lp[j] : lp[j]); g_mag_draw.neutral_fwd[i]+=head[4*j+i]*neutral_lf[j]; g_mag_draw.neutral_up[i]+=head[4*j+i]*neutral_lu[j]; g_mag_draw.off_neutral[i]+=head[4*j+i]*(rest_off_ok ? rest_lo[j] : lo[j]); }
        }
        g_mag_draw.off_ok = visual_off->ok && vr;
        g_mag_draw.gun_ok = gun->ok && (hw.weapon_drawn || vr);
        memcpy(g_mag_draw.off_palm, visual_off->palm, sizeof visual_off->palm);
        memcpy(g_mag_draw.palm, gun->palm, sizeof gun->palm); memcpy(g_mag_draw.fwd, gun->fwd, sizeof gun->fwd);
        g_mag_draw.two_hand = hw.ads && hw.off_fist;
        g_mag_draw.weapon_type = hw.weapon_type; g_mag_draw.state = hw.state; g_mag_draw.slide_hold = hw.slide_hold;
        static double s_slide_t, s_suppress_until;
        double dt_s = s_slide_t > 0 ? fmin(0.1, fmax(0.0, now - s_slide_t)) : 0.016;
        s_slide_t = now;
        if (mb & HW_EV_DONE) s_suppress_until = now + 2.1;
        if (hw.slide_hold && visual_off->ok) {
            float raw_p = 0;
            for (int i = 0; i < 3; i++) raw_p += (hw.grab_at[i] - visual_off->palm[i]) * gun->fwd[i];
            g_mag_draw.pull = fminf(.068f, fmaxf(0.0f, raw_p));
        } else {
            g_mag_draw.pull = fmaxf(0.0f, g_mag_draw.pull - (float)dt_s * 0.80f);
        }
        float mag_mode = 0.0f, well_d = 9.0f, drop_prog = 0.0f;
        if (visual_off->ok && hw.well_ok) well_d = dist3(visual_off->palm, hw.well);
        if (hw.state == HW_HOLD_OLD || hw.state == HW_HOLD_NEW) {
            mag_mode = 1.0f;
        } else if (hw.state == HW_LOADED && hw.pull_ready && visual_off->ok && hw.well_ok) {
            float rel_w[3] = { visual_off->palm[0] - hw.well[0], visual_off->palm[1] - hw.well[1], visual_off->palm[2] - hw.well[2] };
            if (dist3(rel_w, hw.pull_at) >= 0.02f) mag_mode = 1.0f;
        } else if (hw.state == HW_EMPTY) {
            mag_mode = 2.0f;
            drop_prog = fminf(1.0f, fmaxf(0.0f, (float)(now - hw.state_at) * 3.0f));
        }
        float supp = (now < s_suppress_until || mag_mode > 0.5f || g_mag_draw.pull > 0.002f) ? 1.0f : 0.0f;
        pthread_mutex_lock(&g_ik_lock);
        g_ik_slide_pull = g_mag_draw.pull;
        g_ik_weap[0] = g_mag_draw.pull;
        g_ik_weap[1] = mag_mode;
        g_ik_weap[2] = well_d;
        g_ik_weap[3] = drop_prog;
        g_ik_weap[4] = supp;
        pthread_mutex_unlock(&g_ik_lock);
        const char *game_hands = getenv("VXMAC_GAME_HANDS");
        static float sm_lp[3], sm_ypr[3], sm_lo[3], sm_oypr[3];
        static float ref_lp[3], ref_ypr[3], ref_lo[3], ref_oypr[3];
        static int sm_ok, sm_off_ok;
        if (!vr || !g_mag_draw.gun_ok) sm_ok = 0;
        if (!vr || !g_mag_draw.off_ok) sm_off_ok = 0;
        if (vr && g_mag_draw.gun_ok && !(game_hands && !strcmp(game_hands, "0"))) {
            float fx = vdot(gun->fwd, head), fy = vdot(gun->fwd, head + 4), fz = -vdot(gun->fwd, head + 8);
            float ax = vdot(gun->across, head) * (hw.lefty ? -1.f : 1.f), ay = vdot(gun->across, head + 4);
            float raw_yaw = atan2f(fx, fmaxf(.22f, fz));
            float raw_pitch = atan2f(fy, fmaxf(.22f, hypotf(fx, fz)));
            float raw_roll = gun->from_arm ? 0.f : atan2f(ay, ax);
            if (!sm_ok) {
                memcpy(sm_lp, lp, sizeof sm_lp);
                ref_lp[0] = fmaxf(-.22f, fminf(.22f, lp[0]));
                ref_lp[1] = fmaxf(-.34f, fminf(-.14f, lp[1]));
                ref_lp[2] = fmaxf(-.42f, fminf(-.24f, lp[2]));
                sm_ypr[0] = raw_yaw; sm_ypr[1] = raw_pitch; sm_ypr[2] = raw_roll;
                ref_ypr[0] = fmaxf(-.25f, fminf(.25f, raw_yaw));
                ref_ypr[1] = fmaxf(-.40f, fminf(-.05f, raw_pitch));
                ref_ypr[2] = raw_roll;
                sm_ok = 1;
            } else {
                for (int i = 0; i < 3; i++) {
                    sm_lp[i] += (lp[i] - sm_lp[i]) * 0.35f;
                    ref_lp[i] += (sm_lp[i] - ref_lp[i]) * 0.008f;
                }
                sm_ypr[0] += (raw_yaw - sm_ypr[0]) * 0.35f;
                sm_ypr[1] += (raw_pitch - sm_ypr[1]) * 0.35f;
                float rdiff = atan2f(sinf(raw_roll - sm_ypr[2]), cosf(raw_roll - sm_ypr[2]));
                sm_ypr[2] = atan2f(sinf(sm_ypr[2] + rdiff * 0.25f), cosf(sm_ypr[2] + rdiff * 0.25f));
                ref_ypr[0] += (fmaxf(-.30f, fminf(.30f, sm_ypr[0])) - ref_ypr[0]) * 0.012f;
                ref_ypr[1] += (fmaxf(-.45f, fminf(.05f, sm_ypr[1])) - ref_ypr[1]) * 0.012f;
                float ref_rdiff = atan2f(sinf(sm_ypr[2] - ref_ypr[2]), cosf(sm_ypr[2] - ref_ypr[2]));
                ref_ypr[2] = atan2f(sinf(ref_ypr[2] + fmaxf(-.02f, fminf(.02f, ref_rdiff * 0.025f))), cosf(ref_ypr[2] + fmaxf(-.02f, fminf(.02f, ref_rdiff * 0.025f))));
            }
            float dx = sm_lp[0] - ref_lp[0], dy = sm_lp[1] - ref_lp[1] - g_mag_draw.pull * .4f, dz = -(sm_lp[2] - ref_lp[2]);
            float droll = atan2f(sinf(sm_ypr[2] - ref_ypr[2]), cosf(sm_ypr[2] - ref_ypr[2]));
            if (fabsf(droll) < 0.12f) droll = 0.f;
            else droll = (droll > 0 ? droll - 0.12f : droll + 0.12f) * 0.75f;
            g_vm_delta[0] = fmaxf(-.24f, fminf(.24f, dx));
            g_vm_delta[1] = fmaxf(-.20f, fminf(.20f, dy));
            g_vm_delta[2] = fmaxf(-.16f, fminf(.18f, dz));
            g_vm_rot[0] = fmaxf(-.65f, fminf(.65f, sm_ypr[0] - ref_ypr[0]));
            g_vm_rot[1] = fmaxf(-.50f, fminf(.50f, sm_ypr[1] - ref_ypr[1]));
            g_vm_rot[2] = fmaxf(-.45f, fminf(.45f, droll));
            g_vm_active = hw.lefty ? -1 : 1;
            if (g_mag_draw.off_ok) {
                float ofx = vdot(visual_off->fwd, head), ofy = vdot(visual_off->fwd, head + 4), ofz = -vdot(visual_off->fwd, head + 8);
                float oax = vdot(visual_off->across, head) * (hw.lefty ? 1.f : -1.f), oay = vdot(visual_off->across, head + 4);
                float oraw_yaw = atan2f(ofx, fmaxf(.22f, ofz));
                float oraw_pitch = atan2f(ofy, fmaxf(.22f, hypotf(ofx, ofz)));
                float oraw_roll = visual_off->from_arm ? 0.f : atan2f(oay, oax);
                if (!sm_off_ok) {
                    memcpy(sm_lo, lo, sizeof sm_lo);
                    ref_lo[0] = fmaxf(-.22f, fminf(.22f, lo[0]));
                    ref_lo[1] = fmaxf(-.34f, fminf(-.14f, lo[1]));
                    ref_lo[2] = fmaxf(-.42f, fminf(-.24f, lo[2]));
                    sm_oypr[0] = oraw_yaw; sm_oypr[1] = oraw_pitch; sm_oypr[2] = oraw_roll;
                    ref_oypr[0] = fmaxf(-.25f, fminf(.25f, oraw_yaw));
                    ref_oypr[1] = fmaxf(-.40f, fminf(-.05f, oraw_pitch));
                    ref_oypr[2] = oraw_roll;
                    sm_off_ok = 1;
                } else {
                    for (int i = 0; i < 3; i++) {
                        sm_lo[i] += (lo[i] - sm_lo[i]) * 0.35f;
                        ref_lo[i] += (sm_lo[i] - ref_lo[i]) * 0.008f;
                    }
                    sm_oypr[0] += (oraw_yaw - sm_oypr[0]) * 0.35f;
                    sm_oypr[1] += (oraw_pitch - sm_oypr[1]) * 0.35f;
                    float ordiff = atan2f(sinf(oraw_roll - sm_oypr[2]), cosf(oraw_roll - sm_oypr[2]));
                    sm_oypr[2] = atan2f(sinf(sm_oypr[2] + ordiff * 0.25f), cosf(sm_oypr[2] + ordiff * 0.25f));
                    ref_oypr[0] += (fmaxf(-.30f, fminf(.30f, sm_oypr[0])) - ref_oypr[0]) * 0.012f;
                    ref_oypr[1] += (fmaxf(-.45f, fminf(.05f, sm_oypr[1])) - ref_oypr[1]) * 0.012f;
                    float oref_rdiff = atan2f(sinf(sm_oypr[2] - ref_oypr[2]), cosf(sm_oypr[2] - ref_oypr[2]));
                    ref_oypr[2] = atan2f(sinf(ref_oypr[2] + fmaxf(-.02f, fminf(.02f, oref_rdiff * 0.025f))), cosf(ref_oypr[2] + fmaxf(-.02f, fminf(.02f, oref_rdiff * 0.025f))));
                }
                float odx = sm_lo[0] - ref_lo[0], ody = sm_lo[1] - ref_lo[1], odz = -(sm_lo[2] - ref_lo[2]);
                float odroll = atan2f(sinf(sm_oypr[2] - ref_oypr[2]), cosf(sm_oypr[2] - ref_oypr[2]));
                if (fabsf(odroll) < 0.12f) odroll = 0.f;
                else odroll = (odroll > 0 ? odroll - 0.12f : odroll + 0.12f) * 0.75f;
                g_vm_off_delta[0] = fmaxf(-.24f, fminf(.24f, odx));
                g_vm_off_delta[1] = fmaxf(-.20f, fminf(.20f, ody));
                g_vm_off_delta[2] = fmaxf(-.16f, fminf(.18f, odz));
                g_vm_off_rot[0] = fmaxf(-.65f, fminf(.65f, sm_oypr[0] - ref_oypr[0]));
                g_vm_off_rot[1] = fmaxf(-.50f, fminf(.50f, sm_oypr[1] - ref_oypr[1]));
                g_vm_off_rot[2] = fmaxf(-.45f, fminf(.45f, odroll));
                g_vm_off_active = 1;
            } else {
                g_vm_off_active = 0; memset(g_vm_off_delta, 0, sizeof g_vm_off_delta); memset(g_vm_off_rot, 0, sizeof g_vm_off_rot);
            }
        } else {
            g_vm_active = g_vm_off_active = 0;
            memset(g_vm_delta, 0, sizeof g_vm_delta); memset(g_vm_rot, 0, sizeof g_vm_rot);
            memset(g_vm_off_delta, 0, sizeof g_vm_off_delta); memset(g_vm_off_rot, 0, sizeof g_vm_off_rot);
        }
        g_mag_draw.on = vr && ((mag || arms) || g_mag_draw.skel[0] || g_mag_draw.skel[67]);
        int reloading = hw.mag_shown || hw.state != HW_LOADED;
        g_mag_draw.ring = reloading && hw.well_ok;
        g_mag_draw.lit = hw.near_well; g_mag_draw.mag = reloading && visual_off->ok && hw.mag_shown; g_mag_draw.holding = hw.mag_shown;
        memcpy(g_mag_draw.well, hw.well, sizeof hw.well); memcpy(g_mag_draw.grip_dir, hw.grip_dir, sizeof hw.grip_dir);
        if (visual_off->ok) for (int i = 0; i < 3; i++) {
            g_mag_draw.mag_at[i] = visual_off->palm[i]; g_mag_draw.mag_up[i] = -visual_off->across[i];
            if (hw.state == HW_HOLD_NEW && hw.well_ok) {
                float distance = dist3(visual_off->palm, hw.well);
                float t = fmaxf(0, fminf(1, (0.12f - distance) / 0.12f));
                g_mag_draw.mag_at[i] += t * (hw.well[i] - visual_off->palm[i]);
            }
        }
        g_hand_draw_zone = vr && (hw.draw_zone || hw.draw_from || hw.in_hip);
        {
            static int enabled = -1; static float applied_y, applied_p;
            if (enabled < 0) { const char *e = getenv("VXMAC_HAND_AIM"); enabled = e && !strcmp(e, "1"); }
            float target_y=0, target_p=0;
            if (enabled && vr && gun->ok && gun->from_arm != 2 && rest_ok) {
                target_y=fmaxf(-14.f,fminf(14.f,-(lp[0]-rest_lp[0])*55.f));
                target_p=fmaxf(-10.f,fminf(10.f,(lp[1]-rest_lp[1])*50.f));
            } else { target_y=applied_y*.8f; target_p=applied_p*.8f; }
            g_hand_aim_y += target_y-applied_y; g_hand_aim_p += target_p-applied_p;
            applied_y=target_y; applied_p=target_p;
        }
        pthread_mutex_unlock(&g_lock);
        if (prec) {
            if (now < prec_until) {
                fprintf(prec, "%.4f,%d", now, vr);
                for (int i = 0; i < 16; i++) fprintf(prec, ",%.4f", head[i]);
                for (int i = 0; i < 2 * HW_JOINTS; i++) fprintf(prec, ",%.4f", g_joints[i]);
                fprintf(prec, ",%d\n", mb);
                static double pflushed; if (now - pflushed > 2) { pflushed = now; fflush(prec); }
            } else { fclose(prec); prec = NULL; vx_log("VR: hand pose record done"); }
        }
        int b = 0;
        if (on && vr && !mag && !arms) hand_weapon_update(&hw, head, g_joints, now);
        float gesture_hands[20]; memcpy(gesture_hands, hands, sizeof gesture_hands);
        for (int h = 0; h < 2; h++) if (hw.pose[h].ok && hw.pose[h].from_arm) {
            hand_gestures_arm_pose(gesture_hands, h, hw.pose[h].palm, hw.pose[h].across);
        }
        if ((on || grab) && vr) {
            hg.suppress_interact = (mag && hw.state != HW_LOADED) || (arms && (hw.ads || hw.draw_from));
            hand_gestures_set_controller(&hg, hand_weapon_is_hybrid(&hw, now), hw.lefty ?
                !!(controller & (HW_BTN_R_GRAB | HW_BTN_R_TRIG | HW_BTN_ACT_Y)) :
                !!(controller & (HW_BTN_L_GRAB | HW_BTN_L_TRIG | HW_BTN_ACT_X)));
            b = on ? hand_gestures_update(&hg, head, gesture_hands, now) : 0;
            if (grab && (!hg.last[4] || now - hg.last[4] >= .45)) { b |= HG_INTERACT; hg.last[4] = now; hg.count[4]++; }
            if (mag) b &= ~HG_RELOAD;           // (h70: the magazine by hand reloads instead)
            for (int i = 0; i < HG_N; i++) if ((b & (1 << i)) && !up_at[i]) {
                if (i != 5) { if (act[i] < 0) vx_xros_hand_button(-1 - act[i], 1); else vx_xros_hand_key(act[i], 1); }
                if (i != 5) up_at[i] = now + 0.08;  // scanner stays down until the hand leaves the temple
                vx_log("VR: hand gesture %s", hand_gesture_name(1 << i));
                if (labels) {                       // (a short label: the gesture was seen, whatever the game makes of the key)
                    static const char *gs[8][HG_N] = {
                        { "Reload", "Melee", "Grenade", "Heal", "Grab / interact", "Scan" }, { "リロード", "近接攻撃", "グレネード", "回復", "拾う / 操作", "スキャン" },
                        { "装弹", "近战", "手雷", "治疗", "拾取 / 互动", "扫描" }, { "裝彈", "近戰", "手榴彈", "治療", "拾取 / 互動", "掃描" }, { "재장전", "근접 공격", "수류탄", "회복", "잡기 / 상호작용", "스캔" },
                        { "Recharger", "Mêlée", "Grenade", "Soin", "Saisir / interagir", "Scanner" }, { "Nachladen", "Nahkampf", "Granate", "Heilen", "Greifen / interagieren", "Scannen" },
                        { "Recargar", "Cuerpo a cuerpo", "Granada", "Curar", "Agarrar / interactuar", "Escanear" } };
                    show_label(gs[ui_lang()][i]);
                    pthread_mutex_lock(&g_lock); g_label_until = now + 0.7; g_label_big = 0; pthread_mutex_unlock(&g_lock);
                }
            }
        }
        static int climb_up, climb_down;
        int climb = on && vr && hg.climbing ? (hg.climb_dir > 0 ? 1 : -1) : 0;
        if ((climb > 0) != climb_up) { climb_up = climb > 0; vx_xros_hand_key(0x1a, climb_up); }
        if ((climb < 0) != climb_down) { climb_down = climb < 0; vx_xros_hand_key(0x16, climb_down); }
        static int scan_down;
        int want_scan = on && vr && (hg.scan_latched || hg.scan_button_latched);
        if (want_scan != scan_down) {
            scan_down = want_scan;
            if (act[5] < 0) vx_xros_hand_button(-1 - act[5], want_scan); else if (act[5]) vx_xros_hand_key(act[5], want_scan);
        }
        if (rec) {
            if (now < rec_until) {
                fprintf(rec, "%.4f,%d", now, vr);
                for (int i = 0; i < 16; i++) fprintf(rec, ",%.4f", head[i]);
                for (int i = 0; i < 20; i++) fprintf(rec, ",%.4f", hands[i]);
                fprintf(rec, ",%d\n", b);
                static double flushed; if (now - flushed > 2) { flushed = now; fflush(rec); }   // (an app ended early keeps all but 2 s)
            } else { fclose(rec); rec = NULL; vx_log("VR: hand record done"); }
        }
        if (on || mag || arms) snprintf(g_gesture_stats, sizeof g_gesture_stats, ",\"gestures\":[%u,%u,%u,%u,%u,%u],\"magazine\":[%u,%u,%u,%u,%u,%u],\"gun\":[%u,%u,%u,%u,%u]",
                                hg.count[0], hg.count[1], hg.count[2], hg.count[3], hg.count[4], hg.count[5], hw.count[0], hw.count[1], hw.count[2], hw.count[3], hw.count[4], hw.count[5],
                                hw.arm_count[0], hw.arm_count[1], hw.arm_count[2], hw.ads_count, hw.shots);
    }
    // the pointer moves unless the primary hand is in a pinch that has not become a drag
    int frozen = prim >= 0 && g_hg[prim].pinched && g_hg[prim].phase != 2;
    if (hit && !frozen) {
        float a = 0.35f;
        float du = u - g_cur_u, dv = v - g_cur_v;
        if (du * du + dv * dv > 0.0025f) a = 0.7f;        // (a fast move: less smoothing)
        g_cur_u += (u - g_cur_u) * a; g_cur_v += (v - g_cur_v) * a;
        g_cur_hist[g_cur_n % 8][0] = g_cur_u; g_cur_hist[g_cur_n % 8][1] = g_cur_v; g_cur_n++;
        float cu = g_cur_u < 0 ? 0 : g_cur_u > 1 ? 1 : g_cur_u, cv = g_cur_v < 0 ? 0 : g_cur_v > 1 ? 1 : g_cur_v;
        vx_xros_hand_pointer(cu * vx_xros_display_w, cv * vx_xros_display_h);
    }
    int on = hit && scr && g_cur_u >= -0.02f && g_cur_u <= 1.02f && g_cur_v >= -0.02f && g_cur_v <= 1.02f;
    if (on != g_cur_on) { g_cur_on = on; }
    pthread_mutex_lock(&g_lock);
    g_cursor_dot[0] = g_cur_u; g_cursor_dot[1] = g_cur_v; g_cursor_dot[2] = on; g_cursor_dot[3] = prim >= 0 && g_hg[prim].pinched;
    pthread_mutex_unlock(&g_lock);
    snprintf(g_hand_stats, sizeof g_hand_stats, "\"hands\":{\"frames\":%u,\"left_tracked\":%u,\"right_tracked\":%u,\"pointer_on\":%d,"
             "\"pointer\":[%.3f,%.3f],\"clicks\":%u,\"right_clicks\":%u,\"drags\":%u,\"wheel_notches\":%u,\"esc\":%u%s}",
             g_hand_frames, g_tracked_frames[0], g_tracked_frames[1], on, g_cur_u, g_cur_v, g_clicks, g_rclicks, g_drags, g_scroll_notches, g_escs, g_gesture_stats);
}

void vx_xros_vr_stats(char *out, unsigned size) {
    double now = CACurrentMediaTime();
    float hy = 0, hp = 0;
    pthread_mutex_lock(&g_lock); head_angles(g_head, &hy, &hp); if (g_vr_ref) hy = wrap180(hy - g_yaw_ref); pthread_mutex_unlock(&g_lock);
    pthread_mutex_lock(&g_lock);
    double dt = g_report > 0 ? now - g_report : 1;
    g_report = now;
    unsigned have = g_frames - g_noframe;
    {   // (VX Mac, h29: the compositor must hold 90 Hz. In vr mode under 80 Hz for 3 s: the SR blend off; 5 s more: the
        //  world cache off too. Logged (vr_guard). h28 fell to 45 Hz with foveation and SR on)
        double hz = dt > 0 ? g_frames / dt : 90;
        // (h42: off by default (VXMAC_GUARD=1 on) - the user keeps SR, the panorama and the UI at full rate; and no
        //  longer sticky: 5 s back at 85 Hz or more undoes one step)
        static int guard = -1; if (guard < 0) { const char *e = getenv("VXMAC_GUARD"); guard = e && !strcmp(e, "1"); }
        static double fast_s;
        if (!guard) { g_slow_s = 0; fast_s = 0; }
        if (guard && vr_now() && hz < 80 && dt > 0.2) { g_slow_s += dt; fast_s = 0; }
        else if (hz >= 85) { g_slow_s = 0; fast_s += dt; }
        if (guard && g_guard_level > 0 && fast_s > 5) {
            g_guard_level--; fast_s = 0;
            if (g_guard_level == 0) { void vxmtl_ui_half(int); vxmtl_ui_half(0); }
            vx_log("VR: the compositor back at %.0f Hz: guard level %d", hz, g_guard_level);
            if (vx_host_jlog) { char f[80]; snprintf(f, sizeof f, "\"level\":%d,\"hz\":%.1f,\"back\":1", g_guard_level, hz); vx_host_jlog("vr_guard", f); }
        }
        // (h38: 1 the UI copied every other frame, 2 the SR blend off, 3 the world cache off too)
        if (guard && g_slow_s > (g_guard_level ? 5.0 : 3.0) && g_guard_level < 3) {
            g_guard_level++; g_slow_s = 0;
            if (g_guard_level == 1) { void vxmtl_ui_half(int); vxmtl_ui_half(1); }
            vx_log("VR: the compositor at %.0f Hz in vr mode: %s", hz, g_guard_level == 1 ? "the UI copied every other frame" : g_guard_level == 2 ? "the SR blend off" : "the world cache off too");
            if (vx_host_jlog) { char f[80]; snprintf(f, sizeof f, "\"level\":%d,\"hz\":%.1f", g_guard_level, hz); vx_host_jlog("vr_guard", f); }
        }
    }
    snprintf(out, size, "\"compositor_hz\":%.1f,\"game_fps\":%.1f,\"eyes_warped_per_s\":%.1f,\"no_frame\":%u,\"warp_gpu_ms\":%.2f,"
             "\"frame_age_ms\":%.1f,\"game_interval_ms\":%.1f,\"depth_frames\":%u,\"mv_frames\":%u,\"tan\":[%.3f,%.3f,%.3f,%.3f],"
             "\"mode\":\"%s\",\"mode_source\":\"%s\",\"engage_changes\":%u,\"vr_counts_per_deg\":%.2f,\"vr_sent_yaw\":%.1f,\"vr_sent_pitch\":%.1f,"
             "\"vr_head_yaw\":%.1f,\"vr_head_pitch\":%.1f,\"vr_mouse_counts\":%d,\"vr_input_lag_ms\":%.0f,\"vr_scale\":%.3f,\"vr_stereo\":%.2f,\"dibr\":%d,\"dibr_eyes\":%u,\"max_frame_gap_ms\":%.0f,\"vr_outside_frac\":%.3f,\"game_tan\":[%.3f,%.3f],\"vr_cal_rounds\":%u,\"vr_cal_gain\":%.3f,\"vr_cal_corr\":%.2f,\"vr_cal_gain_pitch\":%.3f,\"vr_cal_corr_pitch\":%.2f,\"vr_counts_per_deg_pitch\":%.2f,\"fsr2_frames\":%u,%s",
             g_frames / dt, g_submits / dt, g_draws / dt, g_noframe, g_gpu_n ? g_gpu_ms / g_gpu_n : 0, have ? g_age_ms / have : 0,
             g_interval * 1e3, g_depth_frames, g_mv_frames, g_tan_seen[0], g_tan_seen[1], g_tan_seen[2], g_tan_seen[3],
             vr_now() ? "vr" : screen_now() ? "screen" : "head", g_force ? "manual" : "auto", g_engage_changes, C.cpd, g_sent_yaw, g_sent_pitch,
             hy, hp, g_mouse_counts, g_input_lag_s * 1e3, C.scale, C.stereo, C.dibr, g_dibr_frames, g_max_gap * 1e3, g_outside_n ? g_outside_sum / g_outside_n : 0, g_game_tan[0], g_game_tan[1], g_cal.rounds, g_cal.last_gain, g_cal.last_corr, g_cal.last_gain_y, g_cal.last_corr_y, C.cpd_y, g_fsr2_frames, g_hand_stats);
    {   size_t l = strlen(out); snprintf(out + l, size > l ? size - l : 0, ",\"warp_rot_deg_mean\":%.2f,\"warp_rot_deg_max\":%.2f", g_rot_n ? g_rot_sum / g_rot_n : 0.0, g_rot_max);
        g_rot_sum = 0; g_rot_n = 0; g_rot_max = 0;
        l = strlen(out); snprintf(out + l, size > l ? size - l : 0, ",\"roll_deg_mean\":%.2f,\"roll_deg_max\":%.2f,\"pitch_offset_deg\":%.2f,\"pitch_limits\":[%.1f,%.1f],\"floor_pitch_deg\":%.1f,\"floor_conf\":%.2f",
                                  g_roll_n ? g_roll_sum / g_roll_n : 0.0, g_roll_max, g_pitch_off, g_pitch_lo, g_pitch_hi, g_floor_pitch, g_floor_conf);
        g_roll_sum = 0; g_roll_n = 0; g_roll_max = 0; }
    g_mouse_counts = 0; g_fsr2_frames = 0; g_max_gap = 0; g_dibr_frames = 0; g_outside_sum = 0; g_outside_n = 0;
    g_hand_stats_reset = 1;
    g_frames = g_submits = g_draws = g_noframe = g_depth_frames = g_mv_frames = 0;
    g_gpu_ms = g_age_ms = 0; g_gpu_n = 0;
    pthread_mutex_unlock(&g_lock);
}

float vx_xros_vr_real_hz(void) { config(); return C.real_hz; }

// (VX Mac, method 3: the warp's side of the model's stats, since the last call; npu_model.m prints it while on.
//  iw_gpu_ms / iw_gpu_ms_plain: the compositor frames' GPU time with the layers / without (both eyes and the rest of
//  the frame: their difference is the layers' cost, taken at the same time))
void vx_xros_vr_interp_stats(char *out, unsigned size) {
    pthread_mutex_lock(&g_lock);
    double gi = g_iw_gpu_n ? g_iw_gpu_ms / g_iw_gpu_n : 0, g0 = g_iw_gpu_n0 ? g_iw_gpu_ms0 / g_iw_gpu_n0 : 0;
    snprintf(out, size, "\"iw_eyes\":%lu,\"iw_eyes_asked\":%lu,\"iw_frames\":%lu,\"iw_dt_ms_mean\":%.1f,\"iw_dt_ms_max\":%.0f,\"iw_t_mean\":%.2f,"
             "\"iw_held\":%lu,\"iw_conf_off\":%lu,\"iw_gpu_ms\":%.2f,\"iw_gpu_ms_plain\":%.2f,\"iw_gpu_extra_ms\":%.2f,\"iw_gpu_frames\":[%lu,%lu]",
             g_iw_eyes, g_iw_total, g_iw_frames, g_iw_eyes ? g_iw_age_sum / g_iw_eyes * 1e3 : 0.0, g_iw_age_max * 1e3,
             g_iw_eyes ? g_iw_t_sum / g_iw_eyes : 0.0, g_iw_held, g_iw_conf_off, gi, g0, g_iw_gpu_n && g_iw_gpu_n0 ? gi - g0 : 0.0, g_iw_gpu_n, g_iw_gpu_n0);
    g_iw_conf_off = 0; g_iw_eyes = g_iw_total = g_iw_frames = g_iw_held = g_iw_gpu_n = g_iw_gpu_n0 = 0;
    g_iw_age_sum = g_iw_age_max = g_iw_t_sum = g_iw_gpu_ms = g_iw_gpu_ms0 = 0;
    pthread_mutex_unlock(&g_lock);
}
float vx_xros_vr_max_hz(void) { config(); return C.max_hz; }

float vx_xros_vr_tan_y(void) { config(); return C.tan_y; }   // (VX Mac, h31: the frame's vertical tangent now, for the glue and host)

// (VX Mac, h31: host.m's bounded tuner - counts a degree scaled per axis (each factor 0.95-1.05))
void vx_xros_vr_scale_counts(float fx, float fy) {
    config();
    pthread_mutex_lock(&g_lock);
    float bx = C.cpd, by = C.cpd_y;
    if (fx >= 0.95f && fx <= 1.05f) C.cpd *= fx;
    if (fy >= 0.95f && fy <= 1.05f) C.cpd_y *= fy;
    pthread_mutex_unlock(&g_lock);
    vx_log("VR: counts a degree yaw %.2f -> %.2f, pitch %.2f -> %.2f (the picture's turn against the head's)", bx, C.cpd, by, C.cpd_y);
}

// (VX Mac, h47: the labels in the device's language (its first preferred language; VXMAC_LANG=xx overrides): en, ja,
//  zh-Hans, zh-Hant, ko, fr, de, es. 0-6 the warp modes (number and a short name; 13 mode 7, h64), 7 "VR", 8 "Screen", 9 the quit question, 10 quitting, 11/12 the automatic screen off / on)
static const char *g_strs[8][14] = {
    { "Mode 0: depth + head position", "Mode 1: depth, rotation only", "Mode 2: rotation only (flat)", "Mode 3: depth + position 3 cm",
      "Mode 4: camera from the picture", "Mode 5: no warp", "Mode 6: rotation + fixed stereo", "VR", "Screen", "Quit? Pinch both hands again", "Quitting the game...", "VR: cutscenes stay in VR", "Screen: cutscenes switch to Screen", "Mode 7: free look + controller aim" },
    { "補正 0：深度＋頭の位置", "補正 1：深度・回転のみ", "補正 2：回転のみ（平面）", "補正 3：深度＋位置 3 cm",
      "補正 4：画像から測るカメラ", "補正 5：補正なし", "補正 6：回転＋固定の立体", "VR", "スクリーン", "終了しますか？もう一度両手でピンチ", "ゲームを終了しています…", "VR：カットシーンも VR のまま", "スクリーン：カットシーンはスクリーンに切替", "補正 7：見回し＋コントローラーで照準" },
    { "模式 0：深度＋头部位置", "模式 1：深度，仅旋转", "模式 2：仅旋转（平面）", "模式 3：深度＋位置 3 厘米",
      "模式 4：由画面测得的相机", "模式 5：无补偿", "模式 6：旋转＋固定立体", "VR", "屏幕", "退出？请再次双手捏合", "正在退出游戏…", "VR：过场动画保持 VR", "屏幕：过场动画切换到屏幕", "模式 7：自由环视＋手柄瞄准" },
    { "模式 0：深度＋頭部位置", "模式 1：深度，僅旋轉", "模式 2：僅旋轉（平面）", "模式 3：深度＋位置 3 公分",
      "模式 4：由畫面測得的相機", "模式 5：無補償", "模式 6：旋轉＋固定立體", "VR", "螢幕", "結束？請再次雙手捏合", "正在結束遊戲…", "VR：過場動畫保持 VR", "螢幕：過場動畫切換到螢幕", "模式 7：自由環視＋手把瞄準" },
    { "모드 0: 깊이 + 머리 위치", "모드 1: 깊이, 회전만", "모드 2: 회전만 (평면)", "모드 3: 깊이 + 위치 3 cm",
      "모드 4: 화면에서 측정한 카메라", "모드 5: 보정 없음", "모드 6: 회전 + 고정 입체", "VR", "화면", "종료할까요? 양손으로 다시 핀치", "게임을 종료하는 중…", "VR: 컷신도 VR 유지", "화면: 컷신은 화면으로 전환", "모드 7: 자유 시점 + 컨트롤러 조준" },
    { "Mode 0 : profondeur + position de la tête", "Mode 1 : profondeur, rotation seule", "Mode 2 : rotation seule (plat)", "Mode 3 : profondeur + position 3 cm",
      "Mode 4 : caméra mesurée sur l'image", "Mode 5 : sans correction", "Mode 6 : rotation + stéréo fixe", "VR", "Écran", "Quitter ? Pincez à nouveau des deux mains", "Fermeture du jeu…", "VR : cinématiques en VR", "Écran : cinématiques sur l'écran", "Mode 7 : regard libre + visée à la manette" },
    { "Modus 0: Tiefe + Kopfposition", "Modus 1: Tiefe, nur Drehung", "Modus 2: nur Drehung (flach)", "Modus 3: Tiefe + Position 3 cm",
      "Modus 4: Kamera aus dem Bild", "Modus 5: keine Korrektur", "Modus 6: Drehung + feste Stereo", "VR", "Bildschirm", "Beenden? Erneut mit beiden Händen pinchen", "Spiel wird beendet…", "VR: Zwischensequenzen bleiben in VR", "Bildschirm: Zwischensequenzen auf dem Bildschirm", "Modus 7: freier Blick + Zielen mit dem Controller" },
    { "Modo 0: profundidad + posición de la cabeza", "Modo 1: profundidad, solo rotación", "Modo 2: solo rotación (plano)", "Modo 3: profundidad + posición 3 cm",
      "Modo 4: cámara medida en la imagen", "Modo 5: sin corrección", "Modo 6: rotación + estéreo fijo", "VR", "Pantalla", "¿Salir? Pellizca de nuevo con ambas manos", "Cerrando el juego…", "VR: cinemáticas en VR", "Pantalla: cinemáticas en pantalla", "Modo 7: mirada libre + apuntar con el mando" } };
static int ui_lang(void) {
    static int l = -1;
    if (l >= 0) return l;
    const char *e = getenv("VXMAC_LANG"); NSString *p = e && *e ? @(e) : (NSLocale.preferredLanguages.firstObject ?: @"en");
    l = [p hasPrefix:@"ja"] ? 1 : [p hasPrefix:@"zh-Hant"] || [p hasPrefix:@"zh-TW"] || [p hasPrefix:@"zh-HK"] ? 3 : [p hasPrefix:@"zh"] ? 2 :
        [p hasPrefix:@"ko"] ? 4 : [p hasPrefix:@"fr"] ? 5 : [p hasPrefix:@"de"] ? 6 : [p hasPrefix:@"es"] ? 7 : 0;
    vx_log("VR: labels in %s (%s)", (const char *[]){ "en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es" }[l], p.UTF8String);
    return l;
}
static const char *ui_str(int i) { return g_strs[ui_lang()][i]; }
#define g_warp_names_at(i) ui_str(i)
static void show_warp_mode_label(void) {
    if (g_warp_mode < 0 || g_warp_mode > 7) return;
    show_label(g_warp_names_at(g_warp_mode == 7 ? 13 : g_warp_mode));
    pthread_mutex_lock(&g_lock); g_label_until = CACurrentMediaTime() + 1.5; g_label_big = 1; pthread_mutex_unlock(&g_lock);
}
// (VX Mac, h37: the warp's A/B mode, cycled live (host.m: the controller's Home button held 1 s); a 1 s label and a log line each change)
void vx_xros_vr_cycle_warp_mode(void) {
    if (g_warp_mode < 0) g_warp_mode = warp_start_mode();
    aim_config();
    g_warp_mode = (g_warp_mode + 1) % (g_aim_avail ? 8 : 7);   // (h64: 7, free look + controller aim, only with VXMAC_AIM)
    show_warp_mode_label();
    const char *nm = g_warp_names_at(g_warp_mode == 7 ? 13 : g_warp_mode);
    vx_log("VR: %s", nm);
    if (vx_host_jlog) { char f[160]; snprintf(f, sizeof f, "\"mode\":%d,\"name\":\"%s\"", g_warp_mode, nm); vx_host_jlog("warp_mode", f); }
}

// (VX Mac, h38: the game is about to drain its events (libvxkit's poll hook, the game's thread): the head's delta since
//  the last one, from the newest head pose (the compositor's, for its display time), as one mouse event first in line)
void vx_xros_vr_input_poll(void) {
    if (g_poll_in != 1) return;
    pthread_mutex_lock(&g_lock);
    if (vr_now() && g_head_valid) { double t = CACurrentMediaTime(); vr_mouse(g_head, t, 1); g_last_poll = t; }
    pthread_mutex_unlock(&g_lock);
}

void show_warp_mode_label_ext(void) { show_warp_mode_label(); }
