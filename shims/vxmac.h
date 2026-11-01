// VX Mac: what the shims (libvxkit: AppKit, libvxmtl: Metal + the present hook, libvxmtlfx: MetalFX) offer the
// host app (VX Mac Host, app/Sources) and each other. A macOS program runs on visionOS with its AppKit calls answered
// by libvxkit (windows and views are plain objects: nothing is shown by UIKit), its frames taken at present by
// libvxmtl and shown by the host's immersive presenter, its MetalFX temporal scaler's inputs (colour, depth, motion
// vectors, jitter) captured by libvxmtlfx for the presenter's warp. docs/DESIGN.md has the whole picture.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- libvxkit (AppKit) ------------------------------------------------------------------------------------------
// The "screen" the program sees (NSScreen, CGDisplay*): points, scale, refresh rate. Before the program starts.
void vxkit_set_screen(double width_pt, double height_pt, double scale, double hz);
// Input as macOS events, queued for the program's nextEventMatchingMask:. Positions are in the key window's content
// view, top-left origin, points (converted to AppKit's bottom-left). keycode: a macOS virtual key code (kVK_*).
void vxkit_post_key(uint16_t keycode, int down, const char *chars);
void vxkit_post_hid_key(uint32_t hid_usage, int down);          // (a USB HID keyboard usage: mapped to kVK_* + chars)
void vxkit_post_mouse_pos(double x, double y);                  // (absolute: a mouseMoved / dragged with the delta)
void vxkit_post_mouse_delta(double dx, double dy);
unsigned long vxkit_head_consumed(void);
void vxkit_set_poll_hook(void (*hook)(void));   // (h38: called when the program starts draining its events: the head's delta goes in then)                     // (the head's deltas the program has taken from its queue)              // (relative only: the pointer stays, deltas as raw)
void vxkit_post_mouse_button(int button, int down);             // (0 left, 1 right, 2 other)
void vxkit_post_scroll(double dx, double dy, int precise);
// The program asked for these (CGWarpMouseCursorPosition / CGAssociateMouseAndMouseCursorPosition / NSCursor hide).
int vxkit_cursor_associated(void);
int vxkit_cursor_hidden(void);
// The application object's state (active, hidden) as the host's scene phase says.
void vxkit_set_active(int active);
// The calling thread is the program's "main thread": the observers it registers are called there (host: before main).
void vxkit_set_program_thread(void);
void vxkit_request_quit(void);
void vxmtl_compositor_interval(double ms);   // (h64: each 5 s window's mean present interval -> VXMAC_GPU_CAP_HALF)
double vxmtl_gpu_cap(int *half);            // (h64: the cap now; *half: the half-rate start in use)
void vxmtl_pacing_report(int missed);   // (h60f: the compositor's missed deadlines each 5 s -> the game's GPU cap)   // (h53: [NSApp terminate:] on the program's thread - the program's own quit path)
// The program presented its first frame (host): GameController notifications held until then are delivered.
void vxkit_set_program_ready(void);
// The program's key window's content size in points (0 before it has one) and its CAMetalLayer (or NULL).
void vxkit_window_size(double *w, double *h);
void *vxkit_metal_layer(void);
// One line of the shims' log (stderr and the host's log callback).
void vxmac_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void vxmac_set_log_sink(void (*sink)(const char *line));
// The AppKit selectors that reached the catch-all (unimplemented methods), for the host's log: "Class -sel, ...".
void vxkit_unknown_selectors(char *out, unsigned size);
// (h66, vxaudio.m: the program's HAL calls and the HAL plug-ins loaded; slot 0 the mem line, with the busiest threads,
//  slot 1 vxmac_now.json. vxaudio_hook_image: the program's image after dlopen - its GOT slots to the counters)
void vxaudio_stats(char *out, unsigned size, int slot);
void vxaudio_hook_image(const void *mh);

// ---- libvxmtl (Metal) -------------------------------------------------------------------------------------------
// Called at each [commandBuffer presentDrawable:...] of a CAMetalLayer drawable, before the original, on the
// program's thread: cb (id<MTLCommandBuffer>) is not yet committed, texture (id<MTLTexture>) is the drawable's
// (framebufferOnly is turned off by libvxmtl so it can be read). Return 1 to keep the present, 0 to drop it (the
// drawable is then released unshown, as the host shows the frame itself).
typedef int (*vxmtl_present_hook)(void *cb, void *texture, uint32_t width, uint32_t height);
void vxmtl_set_present_hook(vxmtl_present_hook hook);
// The app in the foreground (1) or the background (0): the program's command-buffer commits wait while 0 (visionOS
// refuses GPU work in the background, and the game stops on that error).
void vxmtl_set_foreground(int fg);
// Each render pass with a depth attachment, when its encoder ends (the program's thread): cb (not committed yet),
// the depth texture, and whether the pass stores it. For the presenter's scene depth.
typedef void (*vxmtl_pass_hook)(void *cb, void *depth_texture, int stores);
void vxmtl_set_pass_hook(vxmtl_pass_hook hook);
// Each two-channel float colour target (RG16Float / RG16Snorm, stored) of a pass with depth, when the pass ends: the
// game's velocity buffer's candidates. index: the colour attachment's.
typedef void (*vxmtl_target_hook)(void *cb, void *texture, int index);
void vxmtl_set_target_hook(vxmtl_target_hook hook);
// (h29) Rotation matrices found in the constants of the last frame's scene passes (16 at most): where (key) and the
// 16 floats as found. The host finds the game's camera among them by its turn.
typedef struct { uint32_t key; float m[16]; } vxmtl_cam_cand;
int vxmtl_camera_candidates(vxmtl_cam_cand *out, int max);
// (h33) The HUD layer of the frame being presented (the UI pass sent to a texture of its own, transparent outside the
// HUD), or NULL when the frame drew its UI into the drawable (menus, full-screen UI). Valid until the next frame.
void *vxmtl_hud_take(void);
void vxmtl_hud_want(int on);
void vxmtl_ui_half(int on);
int vxmtl_ui_menu(void);   // (h43: the UI target holds a menu / full-screen UI now (over 30 %))   // (h38: the 90 Hz guard's first step - the UI copied every other frame)   // (the UI pass redirected only while 1: the presenter shows the HUD layer)
// CAMetalDisplayLink stand-in (offscreen layers get no display link callbacks on visionOS): the host ticks it once
// per compositor frame (or it runs on its own timer at the link's preferred rate when the host never ticks).
void vxmtl_displaylink_tick(double target_presentation_time);
// Counters for the host's log: presents seen, presents of drawables, display link callbacks.
void vxmtl_stats(char *out, unsigned size);

// ---- libvxmtlfx (MetalFX) ---------------------------------------------------------------------------------------
// The inputs of the program's most recent temporal-scaler encode (all retained ids, NULL when absent), taken once:
// returns 1 with a new set since the last take (the caller releases the textures with CFRelease), 0 otherwise.
typedef struct {
    void *color, *depth, *motion, *output;   // id<MTLTexture>
    float jitter_x, jitter_y, mv_scale_x, mv_scale_y;
    uint32_t input_w, input_h, output_w, output_h;
    int reset, depth_reversed, fallback;      // (fallback: our scaler did the upscale, MetalFX had none)
    double time;                              // (CACurrentMediaTime of the encode)
} vxfx_frame;
int vxfx_take_frame(vxfx_frame *out);
void vxfx_stats(char *out, unsigned size);

#ifdef __cplusplus
}
#endif
