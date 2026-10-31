// VX Mac Host: the macOS program's start and its surroundings on visionOS (docs/DESIGN.md).
//
//   xcrun devicectl device process launch --device <id> <bundle id> [-image vxmac_test|Cyberpunk2077]
//        [-present vr|flat] [-data <dir in Documents>] [-gcmouse 0|1] [-- program arguments]
//
// The program is one of the images embedded in Frameworks (prepared with tools/macho_prepare.py --as-dylib: the
// executable as a dylib) with its entry point's offset in Resources/<image>.vxmac.plist. Its main() runs on a thread
// of its own ("program main", 64 MB stack) while UIKit keeps the process's main thread; its AppKit calls are
// libvxkit's. -image: default Cyberpunk2077 when embedded, else vxmac_test.
// Game data: Documents/<-data, default <image>.app>/Contents/Data (the Mac bundle's layout): when that directory is
// there, the program's _NSGetExecutablePath (libvxsystem) says Documents/<dir>/Contents/MacOS/<image>, so it finds
// its data where a Mac install has it. Nothing of the game is in this app's bundle but its code.
// Logs: Documents/vxmac_host.jsonl (the host's events, memory every 2 s, the presenter's and the shims' counters),
// Documents/vxmac_program.log (the program's stdout and stderr, and the shims' lines).
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#include <objc/runtime.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <os/proc.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include "xros_vr.h"
#include "vxmac.h"

extern void (*vx_host_jlog)(const char *event, const char *fields);   // (../../vr/vxmac_vr_glue.m)
extern int vx_xros_display_w, vx_xros_display_h;

static char g_docs[1024];
static int g_log = -1;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;
static double t0;
static int g_vr = 1, g_gcmouse = 1, g_space_open, g_keep_window;
int vxmac_keep_window(void) { return g_keep_window; }
static char g_image[128];
static double g_snap_s = 10, g_snap_last;   // (-snap: below)
static double now_s(void) { return CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970; }
static uint64_t footprint_mb(void) {
    task_vm_info_data_t info; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) == KERN_SUCCESS ? info.phys_footprint >> 20 : 0;
}
static void jlog(const char *event, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void jlog(const char *event, const char *fmt, ...) {
    char extra[3072] = "";
    if (fmt) { va_list ap; va_start(ap, fmt); vsnprintf(extra, sizeof extra, fmt, ap); va_end(ap); }
    char line[3584];
    int n = snprintf(line, sizeof line, "{\"t\":%.3f,\"since_start\":%.3f,\"image\":\"%s\",\"event\":\"%s\",\"available_mb\":%llu,\"footprint_mb\":%llu%s%s}\n",
                     now_s(), now_s() - t0, g_image, event, (unsigned long long)(os_proc_available_memory() >> 20),
                     (unsigned long long)footprint_mb(), *extra ? "," : "", extra);
    if (n >= (int)sizeof line) { n = (int)sizeof line - 1; line[n - 1] = '\n'; }
    pthread_mutex_lock(&g_log_lock);
    if (g_log >= 0) write(g_log, line, (size_t)n);
    pthread_mutex_unlock(&g_log_lock);
}
void vxmac_jlog(const char *event, const char *fields) { if (fields) jlog(event, "%s", fields); else jlog(event, NULL); }
static void shim_line(const char *line) {
    char esc[900]; size_t k = 0;
    for (const char *p = line; *p && k < sizeof esc - 2; p++) { if (*p == '"' || *p == '\\') esc[k++] = '\\'; esc[k++] = (*p == '\n' || *p == '\t') ? ' ' : *p; }
    esc[k] = 0;
    jlog("shim", "\"line\":\"%s\"", esc);
}
int vxmac_present_vr(void) { return g_vr; }
void vxmac_vr_space_set(int open) { g_space_open = open; }
int vxmac_vr_space_open(void) { return g_space_open; }
// (h53: a safe quit - the game's own path only (vxkit_request_quit: [NSApp terminate:] as Cmd+Q on a Mac), never a
//  kill: its shutdown runs and the process exits when it is done. Asked by the both-hands pinch held 3 s + confirm,
//  the window's Quit button, or 10 s in the background (closing the app: the Vision Pro warned of heat with the game
//  left running behind). In the background the program's commits wait (no GPU work), its NSApplication is inactive)
#include <stdatomic.h>
static _Atomic int g_quit_asked; static _Atomic unsigned long g_bg_gen;
void vxmac_request_quit(const char *why) {
    if (atomic_exchange(&g_quit_asked, 1)) return;
    jlog("quit_requested", "\"why\":\"%s\"", why ? why : "?");
    vxkit_request_quit();
}
void vxmac_set_foreground(int fg) {
    vxkit_set_active(fg); vxmtl_set_foreground(fg);
    unsigned long gen = atomic_fetch_add(&g_bg_gen, 1) + 1;
    if (!fg) {
        const char *e = getenv("VXMAC_BG_QUIT_S"); double s = e && *e ? atof(e) : 10;
        if (s > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (atomic_load(&g_bg_gen) == gen) vxmac_request_quit("background");
        });
    }
}

// ---- the launch arguments ----------------------------------------------------------------------------------------
static int g_argc; static char **g_argv;          // (the program's: argv[0] its path, then what follows "--")
static char g_data[256];
static void parse_args(void) {
    NSArray<NSString *> *a = NSProcessInfo.processInfo.arguments;
    // (Documents/vxmac_args.txt: arguments that also apply when the app is opened from the home view, before the
    // launch's own; one per line or space-separated, e.g. "-env VXMAC_BINARY_ARCHIVES=0". A home-view reopen dropped
    // run 2's -env, h12)
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *extra = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"vxmac_args.txt"] encoding:NSUTF8StringEncoding error:nil];
    if (extra.length) {
        NSMutableArray *m = [NSMutableArray arrayWithObject:a.firstObject];
        for (NSString *w in [extra componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) if (w.length) [m addObject:w];
        [m addObjectsFromArray:[a subarrayWithRange:NSMakeRange(1, a.count - 1)]];
        a = m;
    }
    NSMutableArray<NSString *> *prog = [NSMutableArray array];
    BOOL pass = NO;
    for (NSUInteger i = 1; i < a.count; i++) {
        NSString *s = a[i];
        if (pass) { [prog addObject:s]; continue; }
        if ([s isEqualToString:@"--"]) { if (i > 1) pass = YES; continue; }   // (devicectl's own "--" comes first)
        if (i + 1 < a.count) {
            if ([s isEqualToString:@"-image"]) { snprintf(g_image, sizeof g_image, "%s", a[++i].UTF8String); continue; }
            if ([s isEqualToString:@"-present"]) { g_vr = ![a[++i] isEqualToString:@"flat"]; continue; }
            if ([s isEqualToString:@"-data"]) { snprintf(g_data, sizeof g_data, "%s", a[++i].UTF8String); continue; }
            if ([s isEqualToString:@"-gcmouse"]) { g_gcmouse = a[++i].intValue; continue; }
            if ([s isEqualToString:@"-snap"]) { g_snap_s = a[++i].doubleValue; continue; }
            if ([s isEqualToString:@"-window"]) { g_keep_window = [a[++i] isEqualToString:@"keep"]; continue; }
            // (-env NAME=VALUE: a variable for the shims and the presenter, e.g. VXMAC_GPU_WORKING_SET_MB=4096)
            if ([s isEqualToString:@"-env"]) { NSString *kv = a[++i]; NSRange r = [kv rangeOfString:@"="];
                if (r.location != NSNotFound) setenv([kv substringToIndex:r.location].UTF8String, [kv substringFromIndex:r.location + 1].UTF8String, 1); continue; }
        }
    }
    NSString *fw = NSBundle.mainBundle.privateFrameworksPath;
    if (!*g_image) snprintf(g_image, sizeof g_image, "%s",
        [NSFileManager.defaultManager fileExistsAtPath:[fw stringByAppendingPathComponent:@"Cyberpunk2077.dylib"]] ? "Cyberpunk2077" : "vxmac_test");
    if (!*g_data) snprintf(g_data, sizeof g_data, "%s.app", g_image);
    // (the game's profile: the GPU working set it is told, 4096 MB (with the device's 10922 MB it made a 3 GB heap and
    // was killed for memory loading into the game, h11; with 4096 it ran at 6.55 GB, h10). -env overrides it)
    if (!strcmp(g_image, "Cyberpunk2077")) {
        setenv("VXMAC_GPU_WORKING_SET_MB", "4096", 0);
        // (the presenter: the scene's depth from the game's main pass (no motion vectors: MetalFX temporal is not used),
        //  reversed infinite (REDengine), 0.2 m near; vr mode engages on depth, and the image check above hands back to
        //  the panel when the picture does not turn with the head)
        setenv("VXRT_VR_ENGAGE", "depth", 0);
        setenv("VXRT_VR_DEPTH", "rev", 0);
        setenv("VXRT_VR_NEAR", "0.2", 0);
        // (NPU flow on (VXMAC_NPU=0: off): the presenter predicts in vr mode too, from the flow's objects' motion)
        { const char *n = getenv("VXMAC_NPU"); if (!(n && !strcmp(n, "0"))) setenv("VXRT_VR_PREDICT_VR", "1", 0); }
    }
    if (!prog.count && !strcmp(g_image, "vxmac_test")) [prog addObjectsFromArray:@[ @"-seconds", @"60", @"-displaylink" ]];
    g_argc = (int)prog.count + 1;
    g_argv = calloc((size_t)g_argc + 1, sizeof *g_argv);
    g_argv[0] = strdup([fw stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.dylib", g_image]].UTF8String);
    for (NSUInteger i = 0; i < prog.count; i++) g_argv[i + 1] = strdup(prog[i].UTF8String);
}

// ---- the frames ---------------------------------------------------------------------------------------------------
static _Atomic unsigned long g_frames;
// (-snap S: every S seconds (default 10, 0 off) the program's frame as Documents/snap.png, half size: what the game
// shows, readable from the Mac with devicectl copy from)
static void snapshot(id<MTLCommandBuffer> cb, id<MTLTexture> t) {
    if (t.pixelFormat != MTLPixelFormatBGRA8Unorm && t.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB) return;
    NSUInteger w = t.width, h = t.height, row = w * 4;
    id<MTLBuffer> b = [cb.device newBufferWithLength:row * h options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
              toBuffer:b destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * h];
    [e endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        (void)c;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef full = CGBitmapContextCreate(b.contents, w, h, 8, row, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
            CGImageRef img = CGBitmapContextCreateImage(full);
            CGContextRef half = CGBitmapContextCreate(NULL, w / 2, h / 2, 8, 0, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
            CGContextDrawImage(half, CGRectMake(0, 0, w / 2, h / 2), img);
            CGImageRef small = CGBitmapContextCreateImage(half);
            NSData *png = UIImagePNGRepresentation([UIImage imageWithCGImage:small]);
            [png writeToFile:[@(g_docs) stringByAppendingPathComponent:@"snap.png"] atomically:YES];
            CGImageRelease(small); CGImageRelease(img); CGContextRelease(half); CGContextRelease(full); CGColorSpaceRelease(cs);
        });
    }];
}
// ---- does the game's picture turn with the head? (no motion vectors on the Mac route: from the frames themselves) ----
// While vr mode drives the game's camera, each frame's column-brightness profile (160 columns) and row profile (90
// rows) - a small compute pass in the game's own command buffer - are compared with the frame before: the shifts that
// match best are the picture's turn, left/right and up/down. Two uses:
//   - the follow check: over 1.5 s windows with at least 4 degrees of yaw sent, the picture turning by under 10 % of
//     it is "does not follow" (two in a row: the panel, with backoff, xros_vr.m), otherwise follows, and its ratio
//     tunes counts per degree (xros_vr.m: 15 degrees or more, two misses the same way);
//   - a controller's stick: the game's camera also turns by it, which the presenter's pose (head + sent mouse) does not
//     know - the warp then posed the frame wrongly and head turns looked distorted (h19). While the right stick is out
//     of its dead zone (or a frame turned more than the sent mouse explains by over 2 degrees), those frames count in no
//     follow window and tune nothing; the frame stays placed by the head (the stick turns the world, h21).
float vx_xros_vr_sent_yaw(void);
float vx_xros_vr_sent_pitch(void);
int vx_xros_vr_driving(void);
float vx_xros_vr_game_tan_x(void);
void vx_xros_vr_follow_verdict(int follows, float gain, float sent_deg);
void vx_xros_vr_add_camera_offset(float dyaw, float dpitch);
enum { kCols = 160, kRows = 90 };
static id<MTLComputePipelineState> g_prof_pso;
static dispatch_queue_t g_prof_q;
static float g_prev_prof[kCols + kRows]; static int g_have_prev;
static double g_win_start, g_win_sent, g_win_seen; static float g_last_yaw, g_last_pitch;
static unsigned g_follow_windows; static _Atomic unsigned g_stick_frames;
static float g_img_total;   // (the measured turn summed, degrees: npu_flow.m compares the flow with it)
float vxmac_image_turn_total(void) { return g_img_total; }
static float best_shift(const float *a, const float *b, int n, int range) {
    int best = 0; double bestv = 1e30;
    for (int sft = -range; sft <= range; sft++) {
        double sum = 0; int m = 0;
        for (int x = range; x < n - range; x++) { double d = a[x] - b[x + sft]; sum += d * d; m++; }
        if (sum / m < bestv) { bestv = sum / m; best = sft; }
    }
    return (float)best;
}
static int stick_active(void) {
    for (GCController *c in GCController.controllers) {
        GCExtendedGamepad *g = c.extendedGamepad;
        if (g && (fabsf(g.rightThumbstick.xAxis.value) > 0.15f || fabsf(g.rightThumbstick.yAxis.value) > 0.15f)) return 1;
    }
    return 0;
}
static float wrapd(float d) { while (d > 180) d -= 360; while (d < -180) d += 360; return d; }
void vxmac_vel_verify(float ux, float uy, const float *mean);
void *vxmac_vel_latest_mean(void);
void vxmac_vel_target(void *cb, void *tex, int index);
float vx_xros_vr_tan_y(void);
void vx_xros_vr_seen_turn2(uint64_t pseq, float seen, float seen_y);
void vx_xros_vr_cam_candidates(uint64_t pseq, const void *cands, int n);
int vxmac_stick_active(void) { return stick_active(); }   // (h57b: for the presenter's yaw offset)
static void follow_sample(const float *prof, float yaw_sent, float pitch_sent, int stick, const float *vel_mean, uint64_t pseq) {
    if (!vx_xros_vr_driving()) { g_have_prev = 0; g_win_start = 0; return; }
    double now = CACurrentMediaTime();
    if (g_have_prev) {
        // (h31: the shift as an angle at the frame's middle - shift / width x 2 tan / 1 rad; it was shift / width x the
        //  whole FOV, which reads ~0.73 of the turn at FOV 100 (the h17-h27 tuner raised the counts on that). The frame's
        //  real vertical tangent from the presenter (its aspect))
        float tx = vx_xros_vr_game_tan_x(), ty = vx_xros_vr_tan_y();
        float hfov = 2 * atanf(tx) * 180 / (float)M_PI, vfov = 2 * atanf(ty) * 180 / (float)M_PI;
        float seen_x = best_shift(g_prev_prof, prof, kCols, 24) / kCols * 2 * tx * 180 / (float)M_PI;
        float seen_y = best_shift(g_prev_prof + kCols, prof + kCols, kRows, 14) / kRows * 2 * ty * 180 / (float)M_PI;
        (void)hfov; (void)vfov;
        float dy = wrapd(yaw_sent - g_last_yaw), dp = pitch_sent - g_last_pitch;
        float ry = seen_x - dy, rp = seen_y - dp;
        g_img_total += seen_x;
        {   // (h31: the frame's real angles: the picture's turn against the sent turn, each axis; 1 means the assumed
            //  tangent is right, r means the real one is assumed / r - logged every 5 s as fov_check)
            static double sxy, sxx, pyy, pxy; static unsigned n, pn; static double last;
            if (!stick && fabsf(dy) > 0.3f) { sxy += (double)seen_x * dy; sxx += (double)dy * dy; n++; }
            if (!stick && fabsf(dp) > 0.2f) { pxy += (double)seen_y * dp; pyy += (double)dp * dp; pn++; }   // (h37: pitch from smaller nods)
            if (now - last > 5 && n >= 30) {
                last = now;
                double rx = sxy / sxx, ry = pn >= 15 && pyy > 0 ? pxy / pyy : 0;
                {   // (h31: the bounded tuner - ratio = picture / head; counts / ratio makes it 1; at most 5 % a step, only
                    //  past 5 % off, 30 head-only turning frames an axis (pitch 20); VXMAC_VR_TUNE2=0 off; logged vr_tune)
                    // (off by default since h38: per-frame traces showed the picture turning with the input in the same
                    //  frame and the 5-s windows swinging 0.6-1.7 - it walked yaw from 12.0 to 9.2-10.2; VXMAC_VR_TUNE2=1 on)
                    static int on = -1; if (on < 0) { const char *e = getenv("VXMAC_VR_TUNE2"); on = e && !strcmp(e, "1"); }
                    void vx_xros_vr_scale_counts(float fx, float fy);
                    float fx = 1, fy = 1;
                    if (on && rx > 0.5 && rx < 2 && fabs(rx - 1) > 0.05) fx = (float)fmax(0.95, fmin(1.05, 1 / rx));
                    if (on && ry > 0.5 && ry < 2 && fabs(ry - 1) > 0.05) fy = (float)fmax(0.95, fmin(1.05, 1 / ry));
                    if (fx != 1 || fy != 1) {
                        vx_xros_vr_scale_counts(fx, fy);
                        jlog("vr_tune", "\"ratio_x\":%.3f,\"ratio_y\":%.3f,\"factor_x\":%.3f,\"factor_y\":%.3f", rx, ry, fx, fy);
                        sxy = sxx = pxy = pyy = 0; n = pn = 0;   // (measure afresh at the new counts)
                    }
                }
                jlog("fov_check", "\"ratio_x\":%.3f,\"ratio_y\":%.3f,\"frames\":%u,\"pitch_frames\":%u,\"assumed_half_deg\":[%.1f,%.1f],\"measured_half_deg\":[%.1f,%.1f]",
                     rx, ry, n, pn, atanf(tx) * 180 / M_PI, atanf(ty) * 180 / M_PI, rx > 0.2 ? atan(tx / rx) * 180 / M_PI : 0.0, ry > 0.2 ? atan(ty / ry) * 180 / M_PI : 0.0);
                sxy *= 0.5; sxx *= 0.5; pxy *= 0.5; pyy *= 0.5; n /= 2; pn /= 2;
            }
        }
        if (!stick) vx_xros_vr_seen_turn2(pseq, seen_x, seen_y);   // (the presenter picks which frame's input the picture shows)
        vxmac_vel_verify(seen_x / hfov, seen_y / vfov, vel_mean);   // (velocity.m: is the game's target its motion?)
        if (stick || fabsf(ry) > 2.f || fabsf(rp) > 2.f) {
            if (stick) g_stick_frames++;
            // (h21: the stick's turn added to the camera offset moved the frame off the eye - a tilted, swinging quad
            //  over black. The stick turns the game's world, not the frame: the frame stays placed by the head and the
            //  sent mouse, and the stick's frames only stay out of the follow windows and the tuning. VXMAC_STICK_OFFSET=1
            //  keeps the old attribution, clamped to 3 degrees a frame, for comparison)
            static int use_off = -1; if (use_off < 0) { const char *e = getenv("VXMAC_STICK_OFFSET"); use_off = e && !strcmp(e, "1"); }
            if (use_off) { float cy = fmaxf(-3.f, fminf(3.f, ry)), cp = fmaxf(-3.f, fminf(3.f, rp)); vx_xros_vr_add_camera_offset(cy, cp); }
            g_win_start = 0;                         // (no follow window across a stick turn)
        } else { g_win_sent += fabsf(dy); g_win_seen += fabsf(seen_x); }
    }
    memcpy(g_prev_prof, prof, sizeof g_prev_prof); g_have_prev = 1; g_last_yaw = yaw_sent; g_last_pitch = pitch_sent;
    if (!g_win_start) { g_win_start = now; g_win_sent = g_win_seen = 0; return; }
    if (now - g_win_start < 1.5) return;
    if (g_win_sent >= 4) {
        float gain = (float)(g_win_seen / g_win_sent);
        int verdict = gain < 0.1f ? 0 : 1;   // (a small gain is a sensitivity to tune, xros_vr.m; under 0.1 the picture does not turn)
        g_follow_windows++;
        jlog("vr_follow", "\"sent_deg\":%.1f,\"seen_deg\":%.1f,\"gain\":%.2f,\"verdict\":%d,\"stick_frames\":%u", g_win_sent, g_win_seen, gain, verdict, g_stick_frames);
        vx_xros_vr_follow_verdict(verdict, gain, (float)g_win_sent);
    }
    g_win_start = now; g_win_sent = g_win_seen = 0;
}
static void follow_encode(id<MTLCommandBuffer> cb, id<MTLTexture> t) {
    if (!vx_xros_vr_driving()) { g_have_prev = 0; return; }
    if (!g_prof_pso) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void prof(texture2d<float, access::sample> t [[texture(0)]], device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
            "  constexpr sampler s(filter::linear, address::clamp_to_edge); float sum = 0;\n"
            "  if (i < 160) { for (uint y = 0; y < 48; y++) sum += dot(t.sample(s, float2((i + 0.5) / 160.0, (y + 0.5) / 48.0)).rgb, float3(0.3, 0.59, 0.11)); o[i] = sum / 48.0; }\n"
            "  else if (i < 250) { uint r = i - 160; for (uint x = 0; x < 64; x++) sum += dot(t.sample(s, float2((x + 0.5) / 64.0, (r + 0.5) / 90.0)).rgb, float3(0.3, 0.59, 0.11)); o[i] = sum / 64.0; } }\n";
        NSError *err = nil;
        id<MTLLibrary> lib = [cb.device newLibraryWithSource:src options:nil error:&err];
        g_prof_pso = lib ? [cb.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"prof"] error:&err] : nil;
        g_prof_q = dispatch_queue_create("vxmac follow", DISPATCH_QUEUE_SERIAL);
        if (!g_prof_pso) { jlog("vr_follow_error", "\"what\":\"pipeline\""); return; }
    }
    id<MTLBuffer> b = [cb.device newBufferWithLength:(kCols + kRows) * sizeof(float) options:MTLResourceStorageModeShared];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:g_prof_pso]; [e setTexture:t atIndex:0]; [e setBuffer:b offset:0 atIndex:0];
    [e dispatchThreads:MTLSizeMake(kCols + kRows, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
    [e endEncoding];
    float yaw = vx_xros_vr_sent_yaw(), pitch = vx_xros_vr_sent_pitch(); int stick = stick_active(); uint64_t pseq = vx_xros_vr_next_seq();
    id<MTLBuffer> vm = (__bridge id<MTLBuffer>)vxmac_vel_latest_mean();
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; dispatch_async(g_prof_q, ^{ follow_sample((const float *)b.contents, yaw, pitch, stick, vm ? (const float *)vm.contents : NULL, pseq); }); }];
}
void vxmac_npu_frame(void *cb, void *tex, uint32_t w, uint32_t h);
void vxmac_npu_stats(char *out, unsigned size);
int vxmac_npu_on(void);
// (each render pass's depth to the presenter: it picks the scene's from the biggest of the frame's aspect)
// (not the compositor's own passes: its queue is "VX Mac compositor", VXMacImmersive.swift)
static void pass_hook(void *cb, void *depth, int stores) {
    NSString *label = ((__bridge id<MTLCommandBuffer>)cb).commandQueue.label;
    if ([label hasPrefix:@"VX Mac"]) return;
    id<MTLTexture> t = (__bridge id<MTLTexture>)depth;
    if (t.parentTexture && t.parentTexture.pixelFormat == t.pixelFormat && t.parentTexture.width == t.width) t = t.parentTexture;   // (the game passes a new view each time)
    vx_xros_vr_depth_pass(cb, (__bridge void *)t, 1, (uint32_t)stores, 0);
}

static int present_hook(void *cb, void *tex, uint32_t w, uint32_t h) {
    vx_xros_display_w = (int)w; vx_xros_display_h = (int)h;
    if (g_frames++ == 0) vxkit_set_program_ready();
    double tn = CACurrentMediaTime();
    if (g_snap_s > 0 && tn - g_snap_last >= g_snap_s) { g_snap_last = tn; snapshot((__bridge id<MTLCommandBuffer>)cb, (__bridge id<MTLTexture>)tex); }
    if (!g_vr) return 1;                             // (flat: the layer is in the window, presented as usual)
    { void vx_xros_vr_set_hud_layer(void *); vx_xros_vr_set_hud_layer(vxmtl_hud_take()); vxmtl_hud_want(vx_xros_vr_driving()); }   // (h33: this frame's HUD layer, or none)
    { vxmtl_cam_cand cc[16]; int n = vxmtl_camera_candidates(cc, 16);   // (h29: the game's camera candidates for this frame)
      vx_xros_vr_cam_candidates(vx_xros_vr_next_seq(), cc, n); }
    follow_encode((__bridge id<MTLCommandBuffer>)cb, (__bridge id<MTLTexture>)tex);
    vxmac_npu_frame(cb, tex, w, h);   // (npu_flow.m: the frame scaled down for the Neural Engine's optical flow)
    { void vxmac_fsr_frame(void *, void *, uint32_t, uint32_t, uint64_t);   // (fsr.m: the centre to the Neural Engine's SR; off: nothing)
      vxmac_fsr_frame(cb, tex, w, h, vx_xros_vr_next_seq()); }
    vx_xros_vr_submit(cb, tex, w, h, NULL, NULL);
    return 0;                                        // (VR: the presenter shows it; the offscreen layer's present is dropped)
}

// ---- input: a keyboard and a mouse (GameController) as macOS events -------------------------------------------------
static void watch_keyboard(GCKeyboard *k) {
    k.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *ki, GCControllerButtonInput *b, GCKeyCode code, BOOL pressed) {
        (void)ki; (void)b; vxkit_post_hid_key((uint32_t)code, pressed);
    };
    jlog("input_source", "\"source\":\"keyboard\"");
}
static void watch_mouse(GCMouse *m) {
    if (!g_gcmouse) return;
    GCMouseInput *in = m.mouseInput;
    in.mouseMovedHandler = ^(GCMouseInput *mi, float dx, float dy) { (void)mi; vxkit_post_mouse_delta(dx, -dy); };
    in.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { (void)b; (void)v; vxkit_post_mouse_button(0, p); };
    in.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { (void)b; (void)v; vxkit_post_mouse_button(1, p); };
    in.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { (void)b; (void)v; vxkit_post_mouse_button(2, p); };
    in.scroll.valueChangedHandler = ^(GCControllerDirectionPad *d, float x, float y) { (void)d; vxkit_post_scroll(x, y, 0); };
    jlog("input_source", "\"source\":\"mouse\"");
}
// ---- the right stick's pitch in head control ------------------------------------------------------------------------
// While the head drives the game's camera, pitch comes from the head only: the right stick's vertical axis reads 0
// to the game (yaw stays on the stick, as VR mods do). A stick pitch left the camera tilted where the presenter
// assumed the head's pitch, and later head turns warped wrongly, h23. GameController's own objects, in this process:
// -[GCControllerAxisInput value] for the right sticks' y axes, and the handlers set on right sticks get y = 0.
// VXMAC_STICK_PITCH=1: the stick's pitch kept.
int vx_xros_vr_driving(void);
static NSHashTable *g_right_y, *g_right_pads;
static _Atomic unsigned long g_stick_y_zeroed;   // (reads of the right stick's y answered 0, for the stats)
static int stick_pitch_blocked(void) {
    static int keep = -1; if (keep < 0) { const char *e = getenv("VXMAC_STICK_PITCH"); keep = e && !strcmp(e, "1"); }
    return !keep && vx_xros_vr_driving();
}
static void note_controller(GCController *c) {
    GCExtendedGamepad *g = c.extendedGamepad; if (!g) return;
    @synchronized (g_right_pads) { [g_right_pads addObject:g.rightThumbstick]; [g_right_y addObject:g.rightThumbstick.yAxis]; }
}
typedef float (*axis_imp)(id, SEL);
static axis_imp o_axis_value;
static float h_axis_value(id self, SEL s) {
    float v = o_axis_value(self, s);
    if (v != 0 && stick_pitch_blocked()) { BOOL r; @synchronized (g_right_pads) { r = [g_right_y containsObject:self]; } if (r) { g_stick_y_zeroed++; return 0; } }
    return v;
}
typedef void (*sethandler_imp)(id, SEL, id);
static sethandler_imp o_set_pad_handler;
static void h_set_pad_handler(id self, SEL s, GCControllerDirectionPadValueChangedHandler h) {
    if (!h) { o_set_pad_handler(self, s, h); return; }
    __weak id pad = self;
    GCControllerDirectionPadValueChangedHandler wrapped = ^(GCControllerDirectionPad *d, float x, float y) {
        BOOL r = NO; if (y != 0 && stick_pitch_blocked()) { @synchronized (g_right_pads) { r = [g_right_pads containsObject:pad]; } }
        if (r) g_stick_y_zeroed++;
        h(d, x, r ? 0 : y);
    };
    o_set_pad_handler(self, s, wrapped);
}
static sethandler_imp o_set_axis_handler;
static void h_set_axis_handler(id self, SEL s, GCControllerAxisValueChangedHandler h) {
    if (!h) { o_set_axis_handler(self, s, h); return; }
    __weak id axis = self;
    GCControllerAxisValueChangedHandler wrapped = ^(GCControllerAxisInput *a, float v) {
        BOOL r = NO; if (v != 0 && stick_pitch_blocked()) { @synchronized (g_right_pads) { r = [g_right_y containsObject:axis]; } }
        if (r) g_stick_y_zeroed++;
        h(a, r ? 0 : v);
    };
    o_set_axis_handler(self, s, wrapped);
}
static void stick_pitch_setup(void) {
    o_set_axis_handler = (sethandler_imp)method_setImplementation(class_getInstanceMethod([GCControllerAxisInput class], @selector(setValueChangedHandler:)), (IMP)h_set_axis_handler);
    g_right_y = [NSHashTable weakObjectsHashTable]; g_right_pads = [NSHashTable weakObjectsHashTable];
    o_axis_value = (axis_imp)method_setImplementation(class_getInstanceMethod([GCControllerAxisInput class], @selector(value)), (IMP)h_axis_value);
    o_set_pad_handler = (sethandler_imp)method_setImplementation(class_getInstanceMethod([GCControllerDirectionPad class], @selector(setValueChangedHandler:)), (IMP)h_set_pad_handler);
    for (GCController *c in GCController.controllers) note_controller(c);
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { note_controller(n.object); }];
}
// (h38: the controller's Home button held 1 s cycles the warp's A/B mode (the presenter's label shows it); polled at
//  20 Hz. h37's L3 + R3 clashed with the game's own actions; Home is not the game's)
static void warp_mode_poll_start(void) {
    static dispatch_source_t t;
    t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        static double since; static int fired;
        int both = 0;
        for (GCController *c in GCController.controllers) {
            GCExtendedGamepad *g = c.extendedGamepad;
            if (g && g.buttonHome && g.buttonHome.pressed) both = 1;
            // (h49: any controller input - the presenter's pinch gestures wait 2 s after it)
            if (g && (g.buttonA.pressed || g.buttonB.pressed || g.buttonX.pressed || g.buttonY.pressed || g.leftShoulder.pressed || g.rightShoulder.pressed ||
                      g.leftTrigger.pressed || g.rightTrigger.pressed || fabsf(g.leftThumbstick.xAxis.value) > 0.2f || fabsf(g.leftThumbstick.yAxis.value) > 0.2f ||
                      fabsf(g.rightThumbstick.xAxis.value) > 0.2f || fabsf(g.rightThumbstick.yAxis.value) > 0.2f || g.dpad.up.pressed || g.dpad.down.pressed ||
                      g.dpad.left.pressed || g.dpad.right.pressed)) { void vx_xros_vr_controller_touch(void); vx_xros_vr_controller_touch(); }
        }
        double now = CACurrentMediaTime();
        if (!both) { since = 0; fired = 0; return; }
        if (!since) since = now;
        if (!fired && now - since >= 1.0) { fired = 1; void vx_xros_vr_cycle_warp_mode(void); vx_xros_vr_cycle_warp_mode(); }
    });
    dispatch_resume(t);
}
static void input_setup(void) {
    stick_pitch_setup();
    warp_mode_poll_start();
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:GCKeyboardDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { watch_keyboard(n.object); }];
    [nc addObserverForName:GCMouseDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { watch_mouse(n.object); }];
    if (GCKeyboard.coalescedKeyboard) watch_keyboard(GCKeyboard.coalescedKeyboard);
    for (GCMouse *m in GCMouse.mice) watch_mouse(m);
}

// ---- the program -------------------------------------------------------------------------------------------------
typedef int (*entry_fn)(int, char **, char **, char **);
static void *program_main(void *arg) {
    (void)arg;
    pthread_setname_np("program main");
    vxkit_set_program_thread();
    NSString *fw = NSBundle.mainBundle.privateFrameworksPath;
    NSString *path = [fw stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.dylib", g_image]];
    NSDictionary *img = [NSDictionary dictionaryWithContentsOfFile:[NSBundle.mainBundle pathForResource:@(g_image) ofType:@"vxmac.plist"]];
    if (!img[@"entry_offset"]) { jlog("program_error", "\"what\":\"no %s.vxmac.plist (entry offset)\"", g_image); return NULL; }
    double t = now_s();
    void *h = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        char esc[1500]; size_t k = 0; const char *e = dlerror();
        for (const char *p = e ? e : "?"; *p && k < sizeof esc - 2; p++) { if (*p == '"' || *p == '\\') esc[k++] = '\\'; esc[k++] = *p == '\n' ? ' ' : *p; }
        esc[k] = 0;
        jlog("program_error", "\"what\":\"dlopen\",\"error\":\"%s\"", esc);
        return NULL;
    }
    const struct mach_header *mh = NULL;
    for (uint32_t i = 0; i < _dyld_image_count() && !mh; i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && (!strcmp(n, path.UTF8String) || strstr(n, [NSString stringWithFormat:@"/%s.dylib", g_image].UTF8String))) mh = _dyld_get_image_header(i);
    }
    if (!mh) { jlog("program_error", "\"what\":\"loaded image not found\""); return NULL; }
    entry_fn entry = (entry_fn)((const char *)mh + [img[@"entry_offset"] unsignedLongLongValue]);
    jlog("program_loaded", "\"load_s\":%.2f,\"base\":\"%p\",\"entry\":\"%p\",\"argc\":%d", now_s() - t, (void *)mh, (void *)entry, g_argc);
    char apple0[1100]; snprintf(apple0, sizeof apple0, "executable_path=%s", getenv("VXMAC_EXECUTABLE_PATH") ?: g_argv[0]);
    char *apple[] = { apple0, NULL };
    int rc = entry(g_argc, g_argv, *_NSGetEnviron(), apple);
    jlog("program_exit", "\"rc\":%d", rc);
    fflush(stdout); fflush(stderr);
    exit(rc);   // (h53: as on a Mac - the process ends with its program's main; it left the app running with nothing to show)
    return NULL;
}

// (the address space and memory beyond the footprint: reserved VA (a pool left at its Mac size shows here), the
// compressor's share, and the largest regions of 1 GB or more)
static void vm_line(char *out, size_t n) {
    task_vm_info_data_t i; mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &c) != KERN_SUCCESS) { snprintf(out, n, "\"vm\":null"); return; }
    char big[600] = ""; size_t k = 0; int nb = 0;
    vm_address_t a = 0; vm_size_t sz = 0;
    for (;;) {
        natural_t depth = 0; vm_region_submap_info_data_64_t r; mach_msg_type_number_t rc = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_64_t)&r, &rc) != KERN_SUCCESS) break;
        if (sz >= (1ull << 30) && nb < 12) { k += (size_t)snprintf(big + k, sizeof big - k, "%s[\"%#llx\",%llu,%d]", nb ? "," : "", (unsigned long long)a, (unsigned long long)(sz >> 20), r.protection); nb++; }
        a += sz;
    }
    snprintf(out, n, "\"virtual_gb\":%.1f,\"compressed_mb\":%llu,\"internal_mb\":%llu,\"regions_1gb\":[%s]",
             i.virtual_size / 1073741824.0, (unsigned long long)(i.compressed >> 20), (unsigned long long)(i.internal >> 20), big);
}
static void stats_tick(void) {
    char vr[1400] = "", mt[900] = "", fx[300] = "", unk[1200] = "", npu[1100] = "";
    vxmac_npu_stats(npu, sizeof npu);
    { void vxmac_fsr_stats(char *, unsigned); char fs[400]; vxmac_fsr_stats(fs, sizeof fs);
      size_t l = strlen(npu); snprintf(npu + l, sizeof npu - l, ",%s", fs); }
    {   // (h59: the device's thermal state - the display fell to 44 Hz for good 60-90 s into each heavy head-look run with
        //  nothing else changing: is it the system's thermal mitigation? Logged in stats and on each change)
        static long last = -1; long th = (long)[NSProcessInfo processInfo].thermalState;
        if (th != last) { jlog("thermal", "\"state\":%ld", th); last = th; }
        size_t l = strlen(npu); snprintf(npu + l, sizeof npu - l, ",\"thermal\":%ld", th); }
    { unsigned long pe, pt; void vx_xros_vr_pred_stats(unsigned long *, unsigned long *); vx_xros_vr_pred_stats(&pe, &pt);
      size_t l = strlen(npu); snprintf(npu + l, sizeof npu - l, ",\"pred_eyes\":%lu,\"eyes\":%lu,\"stick_y_zeroed\":%lu", pe, pt, (unsigned long)g_stick_y_zeroed); }
    if (g_vr) vx_xros_vr_stats(vr, sizeof vr);
    vxmtl_stats(mt, sizeof mt); vxfx_stats(fx, sizeof fx); vxkit_unknown_selectors(unk, sizeof unk);
    double ww, wh; vxkit_window_size(&ww, &wh);
    static int tick; char vm[900] = "\"vm\":0";
    if (tick++ % 5 == 0) vm_line(vm, sizeof vm);
    jlog("stats", "%s,%s,\"frames\":%lu,\"window\":[%.0f,%.0f],\"display\":[%d,%d],%s%s%s,%s,\"unknown_appkit\":\"%s\"",
         vm, npu, (unsigned long)g_frames, ww, wh, vx_xros_display_w, vx_xros_display_h, vr, *vr ? "," : "", mt, fx, unk);
}

void vxmac_boot(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char args[1024] = ""; size_t k = 0;
        for (int i = 1; i < g_argc && k < sizeof args - 4; i++) k += (size_t)snprintf(args + k, sizeof args - k, "%s%s", i > 1 ? " " : "", g_argv[i]);
        for (char *c = args; *c; c++) if (*c == '"' || *c == '\\') *c = '_';
        jlog("boot", "\"vr\":%d,\"argc\":%d,\"argv0\":\"%s\",\"args\":\"%s\",\"data\":\"%s\"", g_vr, g_argc, g_argv[0], args, g_data);
        // (h31: the screen the game sees: VXMAC_SCREEN=WxH, default 1856x1792 - the eye's texture's aspect, so the game
        //  can render a near-square frame that covers the eye's view up and down at its horizontal FOV; its display
        //  modes are that aspect too (libvxcg). VXMAC_SCREEN=1920x1080: the 16:9 screen of h1-h30)
        // (h40: 1920x1080 again by default - head-look felt natural on the 16:9 frame (h9-h21); the tall frame's real
        //  FOV is not known (the corrected check read 1.45 / 1.1 against "horizontal kept"). VXMAC_SCREEN=1856x1792: tall)
        {   double sw = 1920, sh = 1080; const char *e = getenv("VXMAC_SCREEN");
            if (e && *e) { double a = 0, b = 0; if (sscanf(e, "%lfx%lf", &a, &b) == 2 && a >= 320 && b >= 240) { sw = a; sh = b; } }
            vxkit_set_screen(sw, sh, 1, 90); }
        // the game's FOV for the presenter's projection: its UserSettings.json FieldOfView, a horizontal angle at the
        // frame's aspect (Cyberpunk's slider), as VXMAC_FOV_V unless set (-env VXMAC_FOV_V=deg)
        if (!getenv("VXMAC_FOV_V")) {
            NSString *lib = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
            NSData *js = [NSData dataWithContentsOfFile:[lib stringByAppendingPathComponent:@"CD Projekt Red/Cyberpunk 2077/UserSettings.json"]];
            NSDictionary *us = js ? [NSJSONSerialization JSONObjectWithData:js options:0 error:nil] : nil;
            double fov = 0;
            for (NSDictionary *g in us[@"data"]) for (NSDictionary *o in g[@"options"]) if ([o[@"name"] isEqual:@"FieldOfView"]) fov = [o[@"value"] doubleValue];
            if (fov > 30 && fov < 150) {
                double ty = tan(fov * 0.5 * M_PI / 180) * 9.0 / 16.0;   // (16:9 frames: 1920x1080, 1600x900)
                char v[32]; snprintf(v, sizeof v, "%.2f", 2 * atan(ty) * 180 / M_PI);
                setenv("VXMAC_FOV_V", v, 1);
                // (VXMAC_VR_ZOOM, default 1.15: the frame shown a little larger than the game's real angle, so it covers
                //  more of the eye's view (the frame ends at +-34 degrees vertically, the eye sees +-45/50); the world
                //  looks 15 % nearer, the image check keeps the turn 1:1)
                const char *z = getenv("VXMAC_VR_ZOOM"); double zoom = z && *z ? atof(z) : 1.0;   // (1.15 until h25: the world's angular size must match the head's (orthostereo); the vignette hides the edges) if (zoom < 0.5 || zoom > 2) zoom = 1;
                char ty_s[32]; snprintf(ty_s, sizeof ty_s, "%.4f", ty * zoom); setenv("VXRT_VR_TAN_Y", ty_s, 0);
                // (h31: the horizontal tangent itself: the presenter takes the frame's vertical one from the frame's
                //  aspect at each present - Cyberpunk keeps the horizontal FOV (VXMAC_FOV_LOCK=v: the vertical instead))
                snprintf(ty_s, sizeof ty_s, "%.4f", tan(fov * 0.5 * M_PI / 180) * zoom); setenv("VXRT_VR_TAN_X", ty_s, 0);
                jlog("game_fov", "\"horizontal_deg\":%.1f,\"vertical_deg\":%s", fov, v);
            }
        }
        vxmtl_set_present_hook(present_hook);
        if (g_vr) { vxmtl_set_pass_hook(pass_hook); vxmtl_set_target_hook(vxmac_vel_target);
                    void vx_xros_vr_input_poll(void); vxkit_set_poll_hook(vx_xros_vr_input_poll); }   // (h38: the head's delta at the game's poll)
        vx_xros_vr_enable(g_vr);
        input_setup();
        // the game's data, where its Mac bundle would have it
        NSString *root = [@(g_docs) stringByAppendingPathComponent:@(g_data)];
        BOOL dir = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"Contents/Data"] isDirectory:&dir] && dir) {
            NSString *macos = [root stringByAppendingPathComponent:@"Contents/MacOS"];
            [NSFileManager.defaultManager createDirectoryAtPath:macos withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *exe = [macos stringByAppendingPathComponent:@(g_image)];
            if (![NSFileManager.defaultManager fileExistsAtPath:exe]) [NSData.data writeToFile:exe atomically:NO];
            setenv("VXMAC_EXECUTABLE_PATH", exe.UTF8String, 1);
            jlog("game_data", "\"root\":\"%s\"", root.UTF8String);
        } else jlog("game_data", "\"root\":null,\"looked_in\":\"%s\"", root.UTF8String);
        pthread_attr_t a; pthread_attr_init(&a);
        pthread_attr_setstacksize(&a, 64u << 20);
        pthread_t th; pthread_create(&th, &a, program_main, NULL);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(timer, ^{ stats_tick(); });
        dispatch_resume(timer);
        static dispatch_source_t keep; keep = timer;
    });
}

// ---- -present flat: the program's layer shown in the window ---------------------------------------------------------
@interface VXMacRootController : UIViewController
@end
@implementation VXMacRootController { CADisplayLink *_poll; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _poll = [CADisplayLink displayLinkWithTarget:self selector:@selector(attach)];
    _poll.preferredFrameRateRange = CAFrameRateRangeMake(2, 4, 2);
    [_poll addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)attach {
    CALayer *l = (__bridge CALayer *)vxkit_metal_layer();
    if (!l || l.superlayer) return;
    l.frame = self.view.bounds; l.contentsGravity = kCAGravityResizeAspect;
    [self.view.layer addSublayer:l];
    jlog("flat_layer", "\"w\":%.0f,\"h\":%.0f", l.bounds.size.width, l.bounds.size.height);
    [_poll invalidate]; _poll = nil;
}
@end
UIViewController *vxmac_make_root_controller(void) { return [VXMacRootController new]; }

// ---- before main: the logs ------------------------------------------------------------------------------------------
__attribute__((constructor)) static void host_init(void) {
    t0 = now_s();
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    snprintf(g_docs, sizeof g_docs, "%s", docs.UTF8String);
    char p[1200];
    // (the previous launches' logs kept: .1 the last, .2 the one before; a relaunch from the home view lost h9's)
    const char *logs[] = { "vxmac_host.jsonl", "vxmac_program.log" };
    for (int i = 0; i < 2; i++) {
        char a[1200], b[1200];
        snprintf(a, sizeof a, "%s/%s.1", g_docs, logs[i]); snprintf(b, sizeof b, "%s/%s.2", g_docs, logs[i]); rename(a, b);
        snprintf(b, sizeof b, "%s/%s", g_docs, logs[i]); rename(b, a);
    }
    snprintf(p, sizeof p, "%s/vxmac_host.jsonl", g_docs);
    g_log = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    snprintf(p, sizeof p, "%s/vxmac_program.log", g_docs);
    int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); setvbuf(stdout, NULL, _IOLBF, 0); }
    vxmac_set_log_sink(shim_line);
    vx_host_jlog = vxmac_jlog;
    parse_args();
    jlog("host_init", "\"docs\":\"%s\"", g_docs);
}
