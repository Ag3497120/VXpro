// Training data for the Neural Engine's frame prediction (VX Mac, "method 3", docs/DESIGN.md). Optional module (
// strength_hooks.m's stand-in reads as off in a build without them).
// Off by default: VXMAC_CAPTURE=1 records game frames while vr mode drives the camera (in game), =2 every frame
// (menus, cutscenes too). Nothing else changes: the same frames, the same presenter; a capture adds one compute pass
// (a few hundred thousand texels) to the game's command buffer of a captured frame and nothing to the others.
// Per captured present (host.m present_hook, before the presenter's submit): the frame's colour, the scene's depth
// (the presenter's copy, xros_vr.m) and the game's velocity (velocity.m's copy) sampled at the capture size (default
// 416x240 = the model's input; VXMAC_CAPTURE_SIZE=WxH) into a shared buffer, raw (colour sRGB-encoded 0..1, depth the
// game's reversed value, velocity the target's own values), fp16 planes; when the frame completes, a writer queue
// (utility QoS) deflates it (libcompression ZLIB: raw deflate, Python's zlib reads it) and appends it with the frame's
// times, pose and flags to Documents/vxinterp_capture/cap_<date>.vxic (format: tools/interp_model.py read_capture).
// Rate: bursts of VXMAC_CAPTURE_BURST consecutive presents (default 8: pairs N, N+1 and N, N+2 at the game's real
// gaps) every VXMAC_CAPTURE_EVERY_S seconds (default 2), so ~4 frames a second, ~0.6 MB each deflated; a burst ends
// early when the writer is behind (no free buffer). Stops at VXMAC_CAPTURE_MB (default 4000), with under 5 GB free, or
// when the process's available memory (os_proc_available_memory) falls under VXMAC_CAPTURE_MIN_AVAIL_MB (default 600:
// "stopped":"memory"; ddgame61b's 48-minute capture run was killed by the system at the 8 GB limit, h61c).
// Memory (h61c): nothing grows per frame - the 12 buffers, one deflate output and one deflate scratch (allocated once),
// the file written with write(2) through F_NOCACHE (no stdio buffer, no file pages kept for it), an autorelease pool
// around each capture and each write. tests/interp_capture_mac.m VXT_FRAMES=5000 measures the footprint.
// VXMAC_CAPTURE_DIR: another directory (the Mac test). Stats: cap_* in the stats lines (the footprint and available
// memory with them); interp_capture log lines (one every 250 MB written with the footprint).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <compression.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <pthread.h>
#include <TargetConditionals.h>
#include <unistd.h>
#include <stdatomic.h>
#include <stdio.h>
#include "interp_frame.h"
#include "interp_pack.h"

void vxmac_jlog(const char *event, const char *fields);

enum { kPool = 12 };
typedef struct __attribute__((packed)) {
    char magic[4]; uint32_t header_bytes, payload_bytes, raw_bytes, flags, burst, index;
    uint32_t src_w, src_h, depth_w, depth_h, vel_w, vel_h;
    uint64_t seq, cam_seq; double t, t_prev;
    float vel_k[2], vel_corr, tan[2], nearp, sent[2];
    float cam[16], cam_vel[3], reserved;
} rec_hdr;
_Static_assert(sizeof(rec_hdr) == 196, "the record header is tools/interp_model.py REC_HDR");

static int g_on = -1; static _Atomic int g_state;     // (state: 0 not started, 1 running, -1 stopped)
static uint32_t g_w = 416, g_h = 240, g_burst_len = 8; static double g_every = 2, g_cap_mb = 4000, g_min_avail = 600;
static id<MTLComputePipelineState> g_pso; static id<MTLBuffer> g_dummy_buf; static id<MTLTexture> g_dummy_tex;
static id<MTLBuffer> g_pool[kPool]; static int g_free[kPool], g_nfree;
static pthread_mutex_t g_l = PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t g_q;
static int g_fd = -1; static char g_path[1024];
static uint8_t *g_zout, *g_zscratch; static size_t g_zout_size;   // (the writer queue's: allocated once at start)
static uint32_t g_burst, g_idx; static int g_in_burst; static double g_burst_t;
static unsigned long g_frames, g_bursts, g_dropped, g_short; static double g_bytes, g_raw, g_ms_sum, g_ms_max;
static double g_foot0 = -1, g_avail_min = -1, g_next_log_mb = 250;

static double foot_mb(void) {
    task_vm_info_data_t i; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &n) == KERN_SUCCESS ? i.phys_footprint / 1048576.0 : -1;
}
// (the process's available memory before the system's limit, MB; -1 unknown: on macOS there is no limit, the Mac test
//  sets one with VXMAC_CAPTURE_FAKE_LIMIT_MB = limit - footprint)
static double avail_mb(void) {
#if TARGET_OS_OSX
    const char *e = getenv("VXMAC_CAPTURE_FAKE_LIMIT_MB");
    return e && *e ? atof(e) - foot_mb() : -1;
#else
    return (double)os_proc_available_memory() / 1048576.0;
#endif
}

int vxmac_capture_on(void) {
    if (g_on < 0) {
        const char *e = getenv("VXMAC_CAPTURE"); g_on = e && *e ? atoi(e) : 0;
        if (g_on < 0 || g_on > 2) g_on = 0;
        if ((e = getenv("VXMAC_CAPTURE_SIZE")) && *e) { unsigned w, h; if (sscanf(e, "%ux%u", &w, &h) == 2 && w >= 64 && h >= 64 && w <= 1920 && h <= 1080) { g_w = w; g_h = h; } }
        if ((e = getenv("VXMAC_CAPTURE_BURST")) && *e) { int b = atoi(e); if (b >= 2 && b <= 64) g_burst_len = (uint32_t)b; }
        if ((e = getenv("VXMAC_CAPTURE_EVERY_S")) && *e) g_every = atof(e);
        if ((e = getenv("VXMAC_CAPTURE_MB")) && *e) g_cap_mb = atof(e);
        if ((e = getenv("VXMAC_CAPTURE_MIN_AVAIL_MB")) && *e) g_min_avail = atof(e);
    }
    return g_on > 0 && g_state >= 0;
}

// (once, from the present thread or the writer queue; the file is closed and the deflate buffers freed on the writer
//  queue after the records already queued, which see the state and skip. The 12 GPU buffers stay: a frame in flight
//  may still write one)
static void stop(const char *why) {
    if (atomic_exchange(&g_state, -1) != 1) return;
    char f[400]; snprintf(f, sizeof f, "\"stopped\":\"%s\",\"frames\":%lu,\"mb\":%.1f,\"foot_mb\":%.0f,\"avail_mb\":%.0f",
                          why, g_frames, g_bytes / 1e6, foot_mb(), avail_mb());
    vxmac_jlog("interp_capture", f);
    if (g_q) dispatch_async(g_q, ^{
        if (g_fd >= 0) { close(g_fd); g_fd = -1; }
        free(g_zout); g_zout = NULL; free(g_zscratch); g_zscratch = NULL;
    });
}

static int write_all(const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) { ssize_t k = write(g_fd, b, n); if (k < 0 && errno == EINTR) continue; if (k <= 0) return 0; b += k; n -= (size_t)k; }
    return 1;
}

// (the first capture: the kernel, the buffers, the file)
static int start(id<MTLDevice> dev) {
    NSString *dir;
    const char *e = getenv("VXMAC_CAPTURE_DIR");
    if (e && *e) dir = @(e);
    else dir = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:@"vxinterp_capture"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *fs = [NSFileManager.defaultManager attributesOfFileSystemForPath:dir error:nil];
    double free_gb = [fs[NSFileSystemFreeSize] doubleValue] / 1e9;
    double av = avail_mb();
    if (av >= 0 && av < g_min_avail) { char f[160]; snprintf(f, sizeof f, "\"error\":\"memory\",\"avail_mb\":%.0f,\"min_avail_mb\":%.0f", av, g_min_avail); vxmac_jlog("interp_capture", f); g_state = -1; return 0; }
    if (fs && free_gb < 5) { char f[120]; snprintf(f, sizeof f, "\"error\":\"under 5 GB free\",\"free_gb\":%.1f", free_gb); vxmac_jlog("interp_capture", f); g_state = -1; return 0; }
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@VXI_PACK_MSL options:nil error:&err];
    g_pso = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"cap_pack"] error:&err] : nil;
    if (!g_pso) { char f[400]; snprintf(f, sizeof f, "\"error\":\"kernel: %s\"", err.localizedDescription.UTF8String); vxmac_jlog("interp_capture", f); g_state = -1; return 0; }
    g_dummy_buf = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead; g_dummy_tex = [dev newTextureWithDescriptor:td];
    for (int i = 0; i < kPool; i++) { g_pool[i] = [dev newBufferWithLength:(NSUInteger)g_w * g_h * 6 * 2 options:MTLResourceStorageModeShared]; g_free[i] = i; }
    g_nfree = kPool;
    g_zout_size = (size_t)g_w * g_h * 6 * 2 + 4096;
    g_zout = malloc(g_zout_size); g_zscratch = malloc(compression_encode_scratch_buffer_size(COMPRESSION_ZLIB));
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyyMMdd_HHmmss";
    snprintf(g_path, sizeof g_path, "%s/cap_%s.vxic", dir.UTF8String, [df stringFromDate:NSDate.date].UTF8String);
    g_fd = open(g_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (g_fd < 0) { vxmac_jlog("interp_capture", "\"error\":\"cannot create the file\""); g_state = -1; return 0; }
    fcntl(g_fd, F_NOCACHE, 1);   // (the written data is not kept in the file cache: GBs over a session)
    struct __attribute__((packed)) { char m[4]; uint32_t ver, w, h, planes, res[3]; } fh = { { 'V', 'X', 'I', 'C' }, 1, g_w, g_h, 6, { 0, 0, 0 } };
    write_all(&fh, sizeof fh);
    g_q = dispatch_queue_create("VX Mac capture", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    char f[1500];
    g_foot0 = foot_mb(); g_avail_min = av;
    snprintf(f, sizeof f, "\"file\":\"%s\",\"size\":[%u,%u],\"mode\":%d,\"burst\":%u,\"every_s\":%.2f,\"cap_mb\":%.0f,\"free_gb\":%.1f,\"foot_mb\":%.0f,\"avail_mb\":%.0f,\"min_avail_mb\":%.0f",
             g_path, g_w, g_h, g_on, g_burst_len, g_every, g_cap_mb, free_gb, g_foot0, av, g_min_avail);
    vxmac_jlog("interp_capture", f);
    g_state = 1;
    return 1;
}

// (the writer queue: one record; the deflate's output and scratch are the queue's own, allocated once)
static void write_rec(int bi, rec_hdr h) {
    double t0 = CACurrentMediaTime();
    size_t raw = (size_t)g_w * g_h * 6 * 2;
    int ok = 0;
    if (g_state > 0 && g_fd >= 0) {
        size_t n = g_zout ? compression_encode_buffer(g_zout, g_zout_size, g_pool[bi].contents, raw, g_zscratch, COMPRESSION_ZLIB) : 0;
        const void *pay = n ? g_zout : g_pool[bi].contents;
        h.payload_bytes = n ? (uint32_t)n : (uint32_t)raw; h.raw_bytes = (uint32_t)raw;
        if (n) h.flags |= VXI_ZLIB;
        ok = write_all(&h, sizeof h) && write_all(pay, h.payload_bytes);
    }
    double ms = (CACurrentMediaTime() - t0) * 1e3;
    pthread_mutex_lock(&g_l);
    g_free[g_nfree++] = bi;
    if (ok) { g_frames++; g_bytes += sizeof h + h.payload_bytes; g_raw += raw; g_ms_sum += ms; if (ms > g_ms_max) g_ms_max = ms; }
    double mb = g_bytes / 1e6;
    pthread_mutex_unlock(&g_l);
    if (g_state <= 0) return;
    if (!ok) { stop("write failed"); return; }
    if (mb >= g_next_log_mb) {   // (the trend: the footprint every 250 MB written)
        g_next_log_mb += 250;
        char f[300]; snprintf(f, sizeof f, "\"mb\":%.0f,\"frames\":%lu,\"foot_mb\":%.0f,\"foot_growth_mb\":%.0f,\"avail_mb\":%.0f",
                              mb, g_frames, foot_mb(), foot_mb() - g_foot0, avail_mb());
        vxmac_jlog("interp_capture", f);
    }
    if (mb >= g_cap_mb) stop("size cap reached");
}

void vxmac_capture_frame(void *cbp, void *texp, uint32_t w, uint32_t h, const vxmac_frame_info *fi) {
    if (!vxmac_capture_on() || !cbp || !texp || !fi) return;
    @autoreleasepool {   // (the encoder and anything Metal autoreleases: drained here, not left to the game's thread)
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
    id<MTLTexture> frame = (__bridge id<MTLTexture>)texp;
    int driving = (fi->flags & VXI_VR) != 0;
    // (the rate: a burst of consecutive presents every g_every seconds; in-game only unless mode 2)
    if (!g_in_burst) {
        if ((g_on == 1 && !driving) || (g_burst_t > 0 && fi->t - g_burst_t < g_every)) return;
        if (!g_state && !start(cb.device)) return;
        if (!(frame.usage & MTLTextureUsageShaderRead)) { stop("the frame is not shader-readable"); return; }
        double av = avail_mb();   // (the memory floor, at each burst's start: the system kills the app at its limit)
        if (av >= 0) { if (g_avail_min < 0 || av < g_avail_min) g_avail_min = av; if (av < g_min_avail) { stop("memory"); return; } }
        g_in_burst = 1; g_idx = 0; g_burst++; g_burst_t = fi->t; g_bursts++;
    }
    if (g_state <= 0) return;
    if (g_on == 1 && !driving) { g_in_burst = 0; g_short++; return; }
    pthread_mutex_lock(&g_l);
    int bi = g_nfree ? g_free[--g_nfree] : -1;
    pthread_mutex_unlock(&g_l);
    if (bi < 0) { g_in_burst = 0; g_dropped++; g_short++; return; }   // (the writer is behind: this burst ends here)
    id<MTLBuffer> db = (__bridge id<MTLBuffer>)fi->depth_buf; id<MTLTexture> vt = (__bridge id<MTLTexture>)fi->vel_tex;
    vxi_pack_params p = { g_w, g_h, fi->depth_w, fi->depth_h, fi->depth_bpp, db && fi->depth_w ? 1u : 0u, vt ? 1u : 0u, fi->vel_k[0], fi->vel_k[1] };
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:g_pso];
    [enc setTexture:frame atIndex:0]; [enc setTexture:vt ?: g_dummy_tex atIndex:1];
    [enc setBuffer:p.has_d ? db : g_dummy_buf offset:0 atIndex:0];
    [enc setBytes:&p length:sizeof p atIndex:1];
    [enc setBuffer:g_pool[bi] offset:0 atIndex:2];
    [enc dispatchThreads:MTLSizeMake(g_w, g_h, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [enc endEncoding];
    rec_hdr r = { { 'V', 'X', 'F', 'R' }, sizeof(rec_hdr), 0, 0, 0, g_burst, g_idx };
    r.flags = (fi->flags & (VXI_VR | VXI_STICK | VXI_HUD_SPLIT | VXI_VEL_OK)) | (p.has_d ? VXI_DEPTH : 0) | (p.has_v ? VXI_VEL : 0) |
              (fi->cam_seq ? VXI_CAM : 0) | (p.has_d && fi->depth_bpp == 2 ? VXI_DEPTH16 : 0);
    r.src_w = w; r.src_h = h; r.depth_w = fi->depth_w; r.depth_h = fi->depth_h; r.vel_w = fi->vel_w; r.vel_h = fi->vel_h;
    r.seq = fi->seq; r.cam_seq = fi->cam_seq; r.t = fi->t; r.t_prev = fi->t_prev;
    r.vel_k[0] = fi->vel_k[0]; r.vel_k[1] = fi->vel_k[1]; r.vel_corr = fi->vel_corr; r.tan[0] = fi->tan[0]; r.tan[1] = fi->tan[1];
    r.nearp = fi->nearp; r.sent[0] = fi->sent[0]; r.sent[1] = fi->sent[1];
    memcpy(r.cam, fi->cam, sizeof r.cam);
    if (++g_idx >= g_burst_len) g_in_burst = 0;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status != MTLCommandBufferStatusCompleted) { pthread_mutex_lock(&g_l); g_free[g_nfree++] = bi; g_dropped++; pthread_mutex_unlock(&g_l); return; }
        dispatch_async(g_q, ^{ @autoreleasepool { write_rec(bi, r); } });
    }];
    }
}

void vxmac_capture_stats(char *out, unsigned size) {
    double ft = foot_mb(), av = avail_mb();
    pthread_mutex_lock(&g_l);
    snprintf(out, size, "\"cap\":%d,\"cap_frames\":%lu,\"cap_bursts\":%lu,\"cap_short\":%lu,\"cap_dropped\":%lu,\"cap_mb\":%.1f,\"cap_ratio\":%.2f,\"cap_write_ms_mean\":%.1f,\"cap_write_ms_max\":%.1f,"
             "\"cap_foot_mb\":%.0f,\"cap_foot_growth_mb\":%.0f,\"cap_avail_mb\":%.0f,\"cap_avail_min_mb\":%.0f",
             g_on > 0 ? (g_state >= 0 ? 1 : -1) : 0, g_frames, g_bursts, g_short, g_dropped, g_bytes / 1e6, g_raw > 0 ? g_bytes / g_raw : 0.0,
             g_frames ? g_ms_sum / g_frames : 0.0, g_ms_max, ft, g_foot0 >= 0 ? ft - g_foot0 : 0.0, av, g_avail_min);
    g_ms_max = 0;
    pthread_mutex_unlock(&g_l);
}
