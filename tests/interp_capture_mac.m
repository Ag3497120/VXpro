// The training capture on the Mac's GPU (app/Sources/interp_capture.m built as it is, optional file): a
// 1280x720 BGRA8 frame (a gradient), a 853x480 RG16Float velocity (0.01, -0.02) and a 853x480 Depth32Float copy
// (0.05) presented 20 times, 40 ms apart; mode 2, bursts of 4 every 0.1 s. tools/interp_model.py reads the file back
// (interp_model.py info; read_capture gives the values back: colour, depth 0.05, velocity, k, tangents).
//   clang -fobjc-arc -O2 -framework Foundation -framework Metal -framework QuartzCore -lcompression tests/interp_capture_mac.m -o build/interp_capture_mac
//   VXMAC_CAPTURE_DIR=<dir> build/interp_capture_mac && python3 tools/interp_model.py info --data <dir>
// The footprint (h61c): VXT_FRAMES=6000 VXT_GAP_MS=28 VXT_EVERY_S=0 VXT_REPORT=1000 VXMAC_CAPTURE_MB=100000 prints
// "foot" lines (phys_footprint with the cap_* stats) - flat over 5969 frames / 2.26 GB; VXT_OFF=1 the baseline,
// VXT_NOPOOL=1 no autorelease pool per present, VXMAC_CAPTURE_FAKE_LIMIT_MB=630 the memory stop ("stopped":"memory").
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <unistd.h>
void *objc_autoreleasePoolPush(void); void objc_autoreleasePoolPop(void *);
void vxmac_jlog(const char *event, const char *fields) { printf("%s {%s}\n", event, fields ? fields : ""); }
#include "../app/Sources/interp_capture.m"
#include <mach/mach.h>

static double t_foot(void) {   // (phys_footprint, MB: what the system's memory limit counts)
    task_vm_info_data_t i; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &n) == KERN_SUCCESS ? i.phys_footprint / 1048576.0 : 0;
}


int main(void) {
    @autoreleasepool {
        setenv("VXMAC_CAPTURE", "2", 1); setenv("VXMAC_CAPTURE_BURST", "4", 1); setenv("VXMAC_CAPTURE_EVERY_S", "0.1", 1);
        if (!getenv("VXMAC_CAPTURE_DIR")) setenv("VXMAC_CAPTURE_DIR", "build/interp_capture_test", 1);
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1280 height:720 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> frame = [dev newTextureWithDescriptor:td];
        uint8_t *px = malloc(1280 * 720 * 4);
        for (int y = 0; y < 720; y++) for (int x = 0; x < 1280; x++) { uint8_t *p = px + (y * 1280 + x) * 4; p[0] = 64; p[1] = (uint8_t)(y * 255 / 719); p[2] = (uint8_t)(x * 255 / 1279); p[3] = 255; }   // (B, G, R)
        [frame replaceRegion:MTLRegionMake2D(0, 0, 1280, 720) mipmapLevel:0 withBytes:px bytesPerRow:1280 * 4];
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:853 height:480 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> vel = [dev newTextureWithDescriptor:td];
        __fp16 *vv = malloc(853 * 480 * 4);
        for (int i = 0; i < 853 * 480; i++) { vv[2 * i] = (__fp16)0.01f; vv[2 * i + 1] = (__fp16)-0.02f; }
        [vel replaceRegion:MTLRegionMake2D(0, 0, 853, 480) mipmapLevel:0 withBytes:vv bytesPerRow:853 * 4];
        id<MTLBuffer> depth = [dev newBufferWithLength:853 * 480 * 4 options:MTLResourceStorageModeShared];
        for (int i = 0; i < 853 * 480; i++) ((float *)depth.contents)[i] = 0.05f;
        // (the long run: VXT_FRAMES=5000 VXT_GAP_MS=5 VXT_EVERY_S=0 - the footprint every VXT_REPORT presents, a flat
        //  line or a leak; VXT_OFF=1 the same presents with the capture off: the baseline)
        int frames = getenv("VXT_FRAMES") ? atoi(getenv("VXT_FRAMES")) : 20, gap_us = getenv("VXT_GAP_MS") ? atoi(getenv("VXT_GAP_MS")) * 1000 : 40000;
        int report = getenv("VXT_REPORT") ? atoi(getenv("VXT_REPORT")) : 500;
        if (getenv("VXT_EVERY_S")) setenv("VXMAC_CAPTURE_EVERY_S", getenv("VXT_EVERY_S"), 1);
        if (getenv("VXT_OFF")) setenv("VXMAC_CAPTURE", "0", 1);
        if (frames > 20) {   // (the long run: noise in the colour's low bits, so the deflate works as on a game's frame)
            for (int k = 0; k < 1280 * 720 * 4; k++) if ((k & 3) != 3) px[k] = (uint8_t)((px[k] & 0xf0) | (arc4random() & 0x0f));
            [frame replaceRegion:MTLRegionMake2D(0, 0, 1280, 720) mipmapLevel:0 withBytes:px bytesPerRow:1280 * 4];
        }
        double t0 = CACurrentMediaTime(), tp = t0;
        // (VXT_NOPOOL=1: no autorelease pool around each present - a caller thread that never drains one: what the
        //  capture leaves autoreleased shows as growth against VXT_OFF=1 VXT_NOPOOL=1)
        int nopool = getenv("VXT_NOPOOL") != NULL;
        for (int i = 0; i < frames; i++) {
            void *pool = nopool ? NULL : objc_autoreleasePoolPush();
            id<MTLCommandBuffer> cb = [q commandBuffer];
            double t = CACurrentMediaTime();
            vxmac_frame_info fi = { (__bridge void *)depth, 853, 480, 4, (__bridge void *)vel, 853, 480, { -1.05f, -1.05f }, -0.78f, VXI_VR | VXI_VEL_OK,
                                    (uint64_t)i + 1, t, i ? tp : t - 0.04, { 1.19f, 0.67f }, 0.2f, { (float)i, 0 } };
            vxmac_capture_frame((__bridge void *)cb, (__bridge void *)frame, 1280, 720, &fi);
            [cb commit]; [cb waitUntilCompleted];
            tp = t;
            usleep(gap_us);
            if (frames > 20 && (i + 1) % report == 0) {
                char st[700]; vxmac_capture_stats(st, sizeof st);
                printf("foot {\"presents\":%d,\"foot_mb\":%.1f,%s}\n", i + 1, t_foot(), st); fflush(stdout);
            }
            if (pool) objc_autoreleasePoolPop(pool);
        }
        if (g_q) dispatch_sync(g_q, ^{});
        {   // (the model's input packed by npu_model.m's kernel from the same frame: <dir>/nn_input.f16, 6 planes 416x240,
            //  for tools/interp_model.py's encode_input to be compared with)
            NSError *err = nil;
            id<MTLLibrary> lib = [dev newLibraryWithSource:@VXI_PACK_MSL options:nil error:&err];
            id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"nn_pack"] error:&err];
            MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float width:416 height:6 * 240 mipmapped:NO];
            od.usage = MTLTextureUsageShaderWrite; od.storageMode = MTLStorageModeShared;
            id<MTLTexture> ot = [dev newTextureWithDescriptor:od];
            vxi_pack_params p = { 416, 240, 853, 480, 4, 1, 1, -1.05f, -1.05f };
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:pso]; [e setTexture:frame atIndex:0]; [e setTexture:vel atIndex:1]; [e setBuffer:depth offset:0 atIndex:0];
            [e setBytes:&p length:sizeof p atIndex:1]; [e setTexture:ot atIndex:2];
            [e dispatchThreads:MTLSizeMake(416, 240, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)]; [e endEncoding];
            [cb commit]; [cb waitUntilCompleted];
            NSMutableData *d = [NSMutableData dataWithLength:416 * 6 * 240 * 2];
            [ot getBytes:d.mutableBytes bytesPerRow:416 * 2 fromRegion:MTLRegionMake2D(0, 0, 416, 6 * 240) mipmapLevel:0];
            [d writeToFile:[@(getenv("VXMAC_CAPTURE_DIR")) stringByAppendingPathComponent:@"nn_input.f16"] atomically:YES];
        }
        char s[700]; vxmac_capture_stats(s, sizeof s); printf("stats {%s} in %.2f s\n", s, CACurrentMediaTime() - t0);
        printf("file %s\n", g_path);
        free(px); free(vv);
        printf("foot_end %.1f\n", t_foot());
        return g_frames > 0 || getenv("VXT_OFF") ? 0 : 1;
    }
}
