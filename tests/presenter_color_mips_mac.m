// SPDX-License-Identifier: MIT
// Verify the presenter's mip allocation and compare real Metal warp output.
#define main original_presenter_main
#include "presenter_pipeline_mac.m"
#undef main

static const struct {
    uint32_t width, height, fullLevels;
    MTLPixelFormat format;
} sources[] = {
    {1280, 720, 11, MTLPixelFormatBGRA8Unorm},
    {1279, 719, 11, MTLPixelFormatRGBA8Unorm},
    {17, 9, 5, MTLPixelFormatBGRA8Unorm},
    {1, 1, 1, MTLPixelFormatBGRA8Unorm},
};

static id<MTLTexture> make_texture(id<MTLDevice> device, MTLPixelFormat format,
                                  NSUInteger width, NSUInteger height, MTLTextureUsage usage) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                            width:width height:height mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = usage;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    assert(texture);
    return texture;
}

static id<MTLTexture> capture(id<MTLCommandQueue> queue, id<MTLTexture> source, double *gpu_ms) {
    id<MTLCommandBuffer> command = [queue commandBuffer];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    vx_xros_vr_submit((__bridge void *)command, (__bridge void *)source, (uint32_t)source.width,
                      (uint32_t)source.height, released, (__bridge void *)done);
    [command commit];
    wait_signal(done);
    assert(command.status == MTLCommandBufferStatusCompleted);
    if (gpu_ms) *gpu_ms = (command.GPUEndTime - command.GPUStartTime) * 1000;
    assert(vx_xros_vr_begin_frame(head, CACurrentMediaTime()+.01));
    assert(g_frame_slot >= 0);
    return g_slot[g_frame_slot].view;
}

static void append_bytes(NSMutableData *data, id<MTLTexture> texture) {
    NSUInteger row = 4 * texture.width, offset = data.length;
    [data increaseLengthBy:row * texture.height];
    [texture getBytes:(uint8_t *)data.mutableBytes + offset bytesPerRow:row
           fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height) mipmapLevel:0];
}

int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 4);
    const char *mode = argv[1];
    const BOOL model = !strcmp(mode, "model") || !strcmp(mode, "full-model");
    const BOOL full = !strcmp(mode, "full") || model;
    assert(full || !strcmp(mode, "normal") || !strcmp(mode, "velocity"));
    if (!strcmp(mode, "full") || !strcmp(mode, "full-model")) unsetenv("VXMAC_COLOR_MIPS");
    else setenv("VXMAC_COLOR_MIPS", "used", 1);
    setenv("VXMAC_INTERP", model ? "1" : !strcmp(mode, "velocity") ? "vel" : "0", 1);
    setenv("VXMAC_FRAME_PIPELINE", "1", 1);
    setenv("VXMAC_HISTORY_COPY", "demand", 1);
    setenv("VXRT_VR_MODE", "head", 1);
    setenv("VXMAC_FLOOR", "0", 1);
    unsetenv("VXMAC_EDGE_FILL");
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    assert(device);
    vx_xros_vr_enable(1);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    vxw_core *warp = vxw_create((__bridge void *)device);
    assert(warp);

    id<MTLTexture> mv = make_texture(device, MTLPixelFormatRG32Float, 1, 1, MTLTextureUsageShaderRead);
    float zero[2] = {0};
    [mv replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:zero bytesPerRow:8];
    id<MTLTexture> dp = make_texture(device, MTLPixelFormatR32Float, 32, 32, MTLTextureUsageShaderRead);
    float depths[32 * 32];
    for (unsigned i = 0; i < 32 * 32; i++) depths[i] = i % 32 > 18 ? .93f : .04f;
    [dp replaceRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0 withBytes:depths bytesPerRow:32 * 4];
    id<MTLTexture> model_result = nil;
    if (model) {
        model_result = make_texture(device, MTLPixelFormatR16Float, 8, 48, MTLTextureUsageShaderRead);
        _Float16 values[8 * 48];
        for (unsigned i = 0; i < 8 * 48; i++) values[i] = i < 8 * 24 ? .4f : 0;
        [model_result replaceRegion:MTLRegionMake2D(0, 0, 8, 48) mipmapLevel:0 withBytes:values bytesPerRow:16];
    }

    NSMutableArray<NSNumber *> *samples = [NSMutableArray array];
    NSMutableData *bytes = [NSMutableData data];
    unsigned cases = 0;
    for (unsigned i = 0; i < sizeof sources / sizeof *sources; i++) {
        const uint32_t w = sources[i].width, h = sources[i].height;
        id<MTLTexture> source = make_texture(device, sources[i].format, w, h, MTLTextureUsageShaderRead);
        uint32_t *pixels = malloc((size_t)w * h * sizeof *pixels);
        assert(pixels);
        for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) {
            pixels[y * w + x] = 0xff000000u | ((x * 31 + y * 7) & 0xff) |
                               (((y * 17) & 0xff) << 8) | (((x ^ y) & 0xff) << 16);
        }
        [source replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:pixels bytesPerRow:w * 4];
        free(pixels);
        if (!i) {
            for (unsigned n = 0; n < 80; n++) { @autoreleasepool {
                double ms = 0;
                (void)capture(queue, source, &ms);
                vx_xros_vr_end_frame(NULL);
                if (n >= 16) [samples addObject:@(ms)];
            }}
        }

        id<MTLTexture> color = capture(queue, source, NULL);
        const NSUInteger expected = full ? sources[i].fullLevels
            : MIN(sources[i].fullLevels, VXW_MAX_PLAIN_COLOR_MIP + 1);
        assert(color.mipmapLevelCount == expected);
        if (model) {
            id<MTLCommandBuffer> command = [queue commandBuffer];
            assert(vxw_set_interp(warp, (__bridge void *)command, (__bridge void *)model_result,
                                  8, 8, i + 1, 1, .75f, 0));
            [command commit];
            [command waitUntilCompleted];
            assert(command.status == MTLCommandBufferStatusCompleted);
        }
        for (unsigned configuration = 0; configuration < 4; configuration++) {
            const BOOL compute = (configuration & 1) != 0;
            MTLTextureUsage usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            if (compute) usage |= MTLTextureUsageShaderWrite;
            MTLPixelFormat format = compute ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatBGRA8Unorm_sRGB;
            id<MTLTexture> out = make_texture(device, format, 133, 115, usage);
            format = compute ? MTLPixelFormatR32Float : MTLPixelFormatDepth32Float;
            id<MTLTexture> out_depth = make_texture(device, format, 133, 115, usage);

            vxw_params p = {.w = w, .h = h, .flags = VXW_POSE, .tan_x = 1, .tan_y = .5625f,
                            .z_a = .2f, .dst_tan = {1.4f, 1.4f, 1, 1}, .dst_near = .01f};
            if (configuration & 2) p.flags |= VXW_EDGE_FILL;
            float vm_delta[3] = {.02f, 0, 0}, vm_rot[3] = {0, .04f, 0};
            vxw_set_viewmodel(warp, vm_delta, vm_rot);
            for (int angle = -2; angle <= 2; angle++) {
                const float yaw = angle * .33f;
                p.rot[0] = p.rot[8] = cosf(yaw);
                p.rot[2] = sinf(yaw);
                p.rot[6] = -p.rot[2];
                p.rot[4] = 1;
                for (int eye = -1; eye <= 1; eye += 2) {
                    p.pos[0] = eye * .032f;
                    id<MTLCommandBuffer> command = [queue commandBuffer];
                    assert(vxw_encode_eye(warp, (__bridge void *)command, &p, (__bridge void *)color, NULL,
                                          (__bridge void *)mv, (__bridge void *)dp, (__bridge void *)out,
                                          (__bridge void *)out_depth));
                    [command commit];
                    [command waitUntilCompleted];
                    assert(command.status == MTLCommandBufferStatusCompleted);
                    append_bytes(bytes, out);
                    append_bytes(bytes, out_depth);
                    cases++;
                }
            }
        }
        vx_xros_vr_end_frame(NULL);
    }
    vxw_destroy(warp);
    assert([bytes writeToFile:@(argv[2]) options:NSDataWritingAtomic error:nil]);
    [samples sortUsingSelector:@selector(compare:)];
    printf("%s: %u warp cases, %lu capture samples, median %.4f ms\n",
           mode, cases, (unsigned long)samples.count, samples[samples.count / 2].doubleValue);
    NSData *timings = [NSJSONSerialization dataWithJSONObject:samples options:0 error:NULL];
    assert([timings writeToFile:@(argv[3]) options:NSDataWritingAtomic error:nil]);
    return 0;
}}
