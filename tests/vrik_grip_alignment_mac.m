// SPDX-License-Identifier: MIT
// Exercise the actual palette transform with a stale grip captured on equip.
// Uses Metal allocations and a small offline-compiled shader for palette
// indirection. This does not run the game or its shaders/animation system.
#include "../shims/vxpipe.m"
#include <assert.h>

void vxmac_log(const char *format, ...) { (void)format; }
void vxmtl_enc_stats(char *out, unsigned n) { if (n) out[0] = 0; }
void vxmtl_ui_pipe_add(void *pipeline) { (void)pipeline; }
void vxmtl_ui_pipe_set(id encoder, id pipeline) { (void)encoder; (void)pipeline; }
int vxprof_live;
int vxprof_on(void) { return 0; }
void vxprof_pipe(id encoder, id pipeline) { (void)encoder; (void)pipeline; }
void vxprof_pipe_key(id pipeline, NSString *hash, char kind) { (void)pipeline; (void)hash; (void)kind; }

@interface PoseEncoderFixture : NSObject
@property id<MTLDevice> device;
@property id<MTLCommandBuffer> command;
@property NSMutableArray *retained;
@property id<MTLBuffer> bound;
@property id<MTLBuffer> instance;
@property id<MTLRenderCommandEncoder> actual;
@property NSMutableDictionary *restored;
- (void)useResource:(id)resource usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages;
@end
@implementation PoseEncoderFixture
- (void)useResource:(id)resource usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages {
    [_actual useResource:resource usage:usage stages:stages];
}
@end
id vxmtl_command_buffer_for_encoder(id encoder) { return [encoder command]; }
int vxmtl_retain_for_encoder(id encoder, id resource) {
    if (!resource) return 0;
    [[encoder retained] addObject:resource];
    return 1;
}
static void fixture_bind(id encoder, SEL sel, id buffer, NSUInteger offset, NSUInteger index) {
    assert(index == 2 || index == 4);
    if (buffer) assert(offset < [buffer length]);
    if (index == 2) [encoder setBound:buffer];
    else [encoder setInstance:buffer];
    [[encoder actual] setVertexBuffer:buffer offset:offset atIndex:index];
}

static void fixture_bind_dynamic(id encoder, SEL sel, id buffer, NSUInteger offset, NSUInteger stride, NSUInteger index) {
    assert(stride == 80); fixture_bind(encoder, sel, buffer, offset, index);
    [[encoder actual] setVertexBuffer:buffer offset:offset attributeStride:stride atIndex:index];
}
static void fixture_bytes(id encoder, SEL sel, const void *bytes, NSUInteger size, NSUInteger index) {
    [encoder restored][@(index)] = [NSData dataWithBytes:bytes length:size];
}

static VXPoseCopy *fixture_copy(vrik_pal *pal, id command) {
    for (VXPoseCopy *entry in g_pose_buffers.allValues)
        if (entry->capture_id == pal->capture_id && entry->command == command &&
            !memcmp(&entry->object, &pal->obj, sizeof pal->obj)) return entry;
    return nil;
}

static NSUInteger fixture_expected_base;
static int fixture_expected_pose;
static void fixture_native_draw(id encoder, SEL selector, MTLPrimitiveType type,
                                NSUInteger start, NSUInteger count, NSUInteger instances, NSUInteger base) {
    VXEncVM *vm = objc_getAssociatedObject(encoder, kEncVM);
    assert(base == fixture_expected_base && !!vm->pose_bound == fixture_expected_pose);
    [[encoder actual] drawPrimitives:type vertexStart:start vertexCount:count instanceCount:instances baseInstance:base];
}
static void fixture_native_indexed(id encoder, SEL selector, MTLPrimitiveType type, NSUInteger count,
                                  MTLIndexType index_type, id indices, NSUInteger offset, NSUInteger instances,
                                  NSInteger vertex_base, NSUInteger instance_base) {
    VXEncVM *vm = objc_getAssociatedObject(encoder, kEncVM);
    if (instance_base != fixture_expected_base || !!vm->pose_bound != fixture_expected_pose)
        fprintf(stderr,"dispatch base=%lu bound=%d npals=%d owner=%d frame=%u/%u L=%d nb=%u applied=%d skipped=%lu\n",
                instance_base,vm->pose_bound,g_vk.npals,g_vk.held.owner,atomic_load(&g_frame),g_vk.capture_frame,
                g_vk.pals[0].L,g_vk.pals[0].nb,g_vk.pals[0].applied,atomic_load(&g_pose_skipped));
    assert(instance_base == fixture_expected_base && !!vm->pose_bound == fixture_expected_pose);
    [[encoder actual] drawIndexedPrimitives:type indexCount:count indexType:index_type indexBuffer:indices
                         indexBufferOffset:offset instanceCount:instances baseVertex:vertex_base baseInstance:instance_base];
}

static id<MTLBuffer> fixture_registered(id<MTLDevice> device, size_t size) {
    id<MTLBuffer> buffer = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
    assert(buffer); memset(buffer.contents, 0, size); vxpipe_buf_add(buffer); return buffer;
}

static void test_render_dispatch(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    PoseEncoderFixture *encoder = [PoseEncoderFixture new];
    encoder.device = device; encoder.command = [queue commandBuffer];
    encoder.retained = [NSMutableArray array]; encoder.restored = [NSMutableDictionary dictionary];
    o_svb2 = fixture_bind; o_svbs = fixture_bind_dynamic; o_svy2 = fixture_bytes;
    w_dpib = fixture_native_draw; w_dxib = fixture_native_indexed;
    id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:@(getenv("VXMAC_TEST_POSE_LIBRARY"))] error:nil];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"pose_copy_vertex"];
    pd.fragmentFunction = [library newFunctionWithName:@"pose_copy_color"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    pd.vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
    pd.vertexDescriptor.attributes[0].format = MTLVertexFormatUInt4;
    pd.vertexDescriptor.attributes[0].bufferIndex = 4;
    pd.vertexDescriptor.layouts[4].stride = 80;
    pd.vertexDescriptor.layouts[4].stepFunction = MTLVertexStepFunctionPerInstance;
    pd.vertexDescriptor.layouts[4].stepRate = 1;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:nil];
    assert(pipeline);
    NSArray *layout = @[@4,@0,@80,@(MTLVertexStepFunctionPerInstance),@1,@(MTLVertexFormatUInt4),@16,@64];
    objc_setAssociatedObject(pipeline, kISD, layout, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(pipeline, kSkinSpan, @256, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(pipeline, kInstanceRebase, @1, OBJC_ASSOCIATION_RETAIN);

    id<MTLBuffer> bones = fixture_registered(device, 258 * 48);
    aff *native = (aff *)((uint8_t *)bones.contents + 96);
    for (unsigned i = 0; i < 256; i++) native[i] = aff_id();
    native[255].m[3] = .9f;
    id<MTLBuffer> view = fixture_registered(device, 640);
    aff identity = aff_id(); memcpy((uint8_t *)view.contents + 384, &identity, sizeof identity);
    id<MTLBuffer> descriptor = fixture_registered(device, 64);
    uint64_t address = view.gpuAddress; memcpy((uint8_t *)descriptor.contents + 24, &address, 8);
    id<MTLBuffer> table = fixture_registered(device, 72);
    address = bones.gpuAddress; memcpy((uint8_t *)table.contents + 48, &address, 8);
    id<MTLBuffer> top = fixture_registered(device, 72);
    address = descriptor.gpuAddress; memcpy(top.contents, &address, 8);
    address = table.gpuAddress; memcpy((uint8_t *)top.contents + 48, &address, 8);
    const NSUInteger base = 4096;
    id<MTLBuffer> instances = fixture_registered(device, (base + 1) * 80);
    uint32_t *skin = (uint32_t *)((uint8_t *)instances.contents + base * 80);
    skin[0] = skin[2] = 96; skin[1] = 48;
    memcpy((uint8_t *)skin + 16, &identity, sizeof identity);
    id<MTLBuffer> indices = fixture_registered(device, 64);
    uint16_t triangle[3] = {0,1,2}; memcpy(indices.contents, triangle, sizeof triangle);
    VXEncVM *vm = [VXEncVM new]; vm->original = top; vm->vbuf[4] = instances;
    vm->pipe = pipeline; vm->vp_fg = 1;
    objc_setAssociatedObject(encoder, kEncVM, vm, OBJC_ASSOCIATION_RETAIN);
    memset(&g_vk, 0, sizeof g_vk); atomic_store(&g_frame, 777);
    g_vk.capture_started = g_vk.capture_body = g_vk.weapon_origin_valid = 1;
    g_vk.capture_frame = g_vk.solve_frame = 777;
    g_vk.obj = g_vk.vcam = g_vk.held.room_from_view = aff_id();
    g_vk.have_h[1] = 1; g_vk.held.owner = 1; g_vk.held.wrists = 2;
    g_vk.held.epoch = 1; g_vk.held.at = CACurrentMediaTime();
    g_vk.held.right_grip_valid = 1; g_vk.held.right_grip_frame = 777;
    g_vk.held.right_grip_view = aff_id(); g_vk.held.right_grip_view.m[3] = .8f;
    g_vk.native_item_grip = (vrik_grip_pose){{0,0,0},{1,0,0},{0,1,0}};
    g_vk.weapon_frame.valid = 1; g_vk.weapon_frame.frame = 777; g_vk.weapon_frame.epoch = 1;
    g_vk.weapon_frame.world_delta = aff_id(); g_vk.weapon_frame.world_delta.m[3] = .8f;
    g_vk.weapon_frame.native_world = g_vk.native_item_grip;
    vrik_pal seed = {.count=3, .indices=(__bridge const void *)indices};
    vrik_item_slot(&seed, 1)->samples = 3;
    MTLRenderPipelineDescriptor *constant_pd = [pd copy];
    constant_pd.vertexDescriptor.layouts[4].stepFunction = MTLVertexStepFunctionConstant;
    constant_pd.vertexDescriptor.layouts[4].stepRate = 0;
    id<MTLRenderPipelineState> constant_pipeline = [device newRenderPipelineStateWithDescriptor:constant_pd error:nil];
    assert(constant_pipeline);
    NSArray *constant_layout = @[@4,@0,@0,@(MTLVertexStepFunctionConstant),@0,@(MTLVertexFormatUInt4),@16,@80];
    objc_setAssociatedObject(constant_pipeline, kISD, constant_layout, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(constant_pipeline, kSkinSpan, @256, OBJC_ASSOCIATION_RETAIN);
    id<MTLTexture> textures[4];
    for (int pass = 0; pass < 4; pass++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
        td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget;
        textures[pass] = [device newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = textures[pass]; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        encoder.actual = [encoder.command renderCommandEncoderWithDescriptor:rp];
        [encoder.actual setRenderPipelineState:pass == 3 ? constant_pipeline : pipeline];
        [encoder.actual setVertexBuffer:top offset:0 atIndex:2];
        vm->voff[4] = pass == 3 ? base * 80 : 0;
        [encoder.actual setVertexBuffer:instances offset:vm->voff[4] atIndex:4];
        [encoder.actual useResource:bones usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
        [encoder.actual useResource:table usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
        fixture_expected_pose = pass != 1; fixture_expected_base = pass == 1 || pass == 3 ? base : 0;
        vm->pipe = pass == 1 ? nil : pass == 3 ? constant_pipeline : pipeline; vm->vp_fg = pass != 1;
        if (pass != 1) wh_dxib(encoder, NULL, MTLPrimitiveTypeTriangle, 3, MTLIndexTypeUInt16, indices, 0, 1, 0, base);
        else wh_dpib(encoder, NULL, MTLPrimitiveTypeTriangle, 0, 3, 1, base);
        if (pass != 1) assert(encoder.instance.length == 80);
        [encoder.actual endEncoding]; encoder.actual = nil;
    }
    vxpipe_pose_seal_command_buffer(encoder.command);
    [encoder.command commit]; [encoder.command waitUntilCompleted];
    assert(encoder.command.status == MTLCommandBufferStatusCompleted && !encoder.command.error);
    for (int pass = 0; pass < 4; pass++) {
        uint8_t pixel[4]; [textures[pass] getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(2,2,1,1) mipmapLevel:0];
        assert(abs(pixel[0] - (pass == 1 ? 0 : 204)) <= 1 && pixel[1] == 255 && abs(pixel[2] - 230) <= 1);
    }
    assert(native[0].m[3] == 0 && skin[0] == 96 && skin[2] == 96);
    objc_setAssociatedObject(encoder, kEncVM, nil, OBJC_ASSOCIATION_RETAIN);
    g_pose_buffers = nil; memset(&g_vk, 0, sizeof g_vk);
    puts("render dispatch: posed indexed GPU draw before encode; native primitive restored; constant and instanced inputs; base 4096 uses one 80-byte record: ok");
}

static void test_saved_shader_profiles(void) {
    const char *path = getenv("VXMAC_TEST_GAME_VS_DIR");
    if (!path) return;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    unsigned checked = 0;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(path) error:nil]) {
        if (![name.pathExtension isEqualToString:@"metallib"]) continue;
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:[@(path) stringByAppendingPathComponent:name]] error:nil];
        assert(library);
        id<MTLFunction> function = [library newFunctionWithName:@"vs_main_"];
        if (!function) continue;
        NSMutableArray *blend = [NSMutableArray array];
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = function; desc.vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
        for (MTLVertexAttribute *attr in function.vertexAttributes) {
            MTLVertexAttributeDescriptor *A = desc.vertexDescriptor.attributes[attr.attributeIndex];
            A.bufferIndex = 5; A.format = MTLVertexFormatFloat4;
            if ([attr.name hasPrefix:@"instance_transform"]) {
                A.bufferIndex = 4;
                A.offset = [attr.name hasSuffix:@"0"] ? 0 : [attr.name hasSuffix:@"1"] ? 16 : 32;
            } else if ([attr.name isEqualToString:@"instance_skinning_data0"]) {
                A.bufferIndex = 4; A.offset = 48; A.format = MTLVertexFormatUInt4;
            }
            if (attr.active && [attr.name hasPrefix:@"blendindices"]) {
                [blend addObject:@(attr.attributeIndex)];
                desc.vertexDescriptor.attributes[attr.attributeIndex].format = MTLVertexFormatUChar4;
            }
        }
        if (!blend.count) continue;
        desc.vertexDescriptor.layouts[4].stride = 64;
        desc.vertexDescriptor.layouts[4].stepFunction = MTLVertexStepFunctionPerInstance;
        desc.vertexDescriptor.layouts[4].stepRate = 1;
        desc.vertexDescriptor.layouts[5].stride = 16;
        desc.vertexDescriptor.layouts[5].stepFunction = MTLVertexStepFunctionPerVertex;
        objc_setAssociatedObject(function, kHash, name.stringByDeletingPathExtension, OBJC_ASSOCIATION_RETAIN);
        NSObject *pipeline = [NSObject new]; vrik_pipe_note(pipeline, desc);
        assert([objc_getAssociatedObject(pipeline, kSkinSpan) unsignedIntValue] == 256);
        assert([objc_getAssociatedObject(pipeline, kInstanceRebase) boolValue]);
        desc.vertexDescriptor.layouts[5].stepFunction = MTLVertexStepFunctionPerInstance;
        pipeline = [NSObject new]; vrik_pipe_note(pipeline, desc);
        assert(![objc_getAssociatedObject(pipeline, kInstanceRebase) boolValue]);
        desc.vertexDescriptor.layouts[5].stepFunction = MTLVertexStepFunctionPerVertex;
        desc.vertexDescriptor.attributes[[blend[0] unsignedIntegerValue]].format = MTLVertexFormatUShort4;
        pipeline = [NSObject new]; vrik_pipe_note(pipeline, desc);
        assert(!objc_getAssociatedObject(pipeline, kSkinSpan));
        desc.vertexDescriptor.attributes[[blend[0] unsignedIntegerValue]].format = MTLVertexFormatUChar4;
        objc_setAssociatedObject(function, kHash, @"unverified", OBJC_ASSOCIATION_RETAIN);
        pipeline = [NSObject new]; vrik_pipe_note(pipeline, desc);
        assert(!objc_getAssociatedObject(pipeline, kSkinSpan));
        checked++;
    }
    assert(checked == 21);
    puts("saved shader reflection: 21 skinning libraries, 8-bit bounds, wider/unknown variants refused: ok");
}

static void test_palette_isolation(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    assert(device);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    PoseEncoderFixture *encoder = [PoseEncoderFixture new];
    encoder.device = device; encoder.command = [queue commandBuffer];
    encoder.retained = [NSMutableArray array];
    const char *library_path = getenv("VXMAC_TEST_POSE_LIBRARY");
    assert(library_path);
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:@(library_path)] error:&error];
    assert(library && !error);
    MTLRenderPipelineDescriptor *pipeline = [MTLRenderPipelineDescriptor new];
    pipeline.vertexFunction = [library newFunctionWithName:@"pose_copy_vertex"];
    pipeline.fragmentFunction = [library newFunctionWithName:@"pose_copy_color"];
    pipeline.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    pipeline.vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
    pipeline.vertexDescriptor.attributes[0].format = MTLVertexFormatUInt4;
    pipeline.vertexDescriptor.attributes[0].bufferIndex = 4;
    pipeline.vertexDescriptor.layouts[4].stride = 80;
    pipeline.vertexDescriptor.layouts[4].stepFunction = MTLVertexStepFunctionPerInstance;
    pipeline.vertexDescriptor.layouts[4].stepRate = 1;
    id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:pipeline error:&error];
    assert(state && !error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> texture = [device newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    encoder.actual = [encoder.command renderCommandEncoderWithDescriptor:pass];
    [encoder.actual setRenderPipelineState:state];
    o_svb2 = fixture_bind; o_svbs = fixture_bind_dynamic; o_svy2 = fixture_bytes;
    encoder.restored = [NSMutableDictionary dictionary];
    VXEncVM *vm = [VXEncVM new];
    uint32_t records[60] = {0}; // Three 80-byte instance records.
    records[40] = 96; records[41] = 48; records[42] = 54 * 1024 * 1024;
    vm->vbytes = [NSMutableDictionary dictionary];
    vm->vbytes[@4] = [NSData dataWithBytes:records length:sizeof records];
    NSArray *layout = @[@4,@0,@80,@(MTLVertexStepFunctionPerInstance),@1,@0,@16];
    aff native[256];
    for (unsigned i = 0; i < 256; i++) { native[i] = aff_id(); native[i].m[3] = .01f * i; }
    native[255].m[3] = .9f;
    aff unchanged[256]; memcpy(unchanged, native, sizeof native);
    memset(&g_vk, 0, sizeof g_vk);
    vrik_pal *first = &g_vk.pals[g_vk.npals++]; first->obj = aff_id();
    assert(vrik_capture_palette(first, (uint8_t *)native, sizeof native, 0x1000, 96, 100));
    first->posed[0].m[3] = .8f; first->posed[1].m[3] = .9f;
    first->applied = 1; first->mod_k1 = 0; first->mod_k2 = 1;
    // A later mesh overlaps the first palette's source. It must see only the
    // game's matrices, even after a previous mesh has been transformed.
    vrik_pal *second = &g_vk.pals[g_vk.npals++]; second->obj = aff_id();
    assert(vrik_capture_palette(second, (uint8_t *)(native + 1), sizeof native - 48, 0x1000, 144, 100));
    assert(!memcmp(second->orig, native + 1, sizeof second->orig));
    assert(!memcmp(native, unchanged, sizeof native));
    assert(vrik_capture_palette(first, (uint8_t *)native, sizeof native, 0x1000, 96, 100));
    assert(first->applied && first->posed[0].m[3] == .8f);

    uint8_t top[72] = {0}, table[72] = {0};
    uint64_t original_address = 0x1000; memcpy(table + 48, &original_address, 8);
    assert(vrik_bind_palette(encoder, vm, top, sizeof top, table, sizeof table, first, layout, 2, 256));
    assert(vm->pose_bound && encoder.retained.count == 3);
    VXPoseCopy *entry = fixture_copy(first, encoder.command);
    id<MTLBuffer> copy = entry->buffer;
    assert(copy && copy.length == sizeof native);
    assert(((aff *)copy.contents)[0].m[3] == .8f);
    assert(!memcmp((uint8_t *)copy.contents + 96, native + 2, sizeof native - 96));
    uint64_t address; memcpy(&address, (uint8_t *)encoder.bound.contents + 48, 8);
    assert(address == encoder.bound.gpuAddress + 4096);
    memcpy(&address, (uint8_t *)encoder.bound.contents + 4096 + 48, 8);
    assert(address == copy.gpuAddress);
    // Base-instance addressing and every unrelated attribute are preserved.
    assert(encoder.instance.length == sizeof records);
    uint32_t expected[60]; memcpy(expected, records, sizeof expected); expected[40] = expected[42] = 0;
    assert(!memcmp(encoder.instance.contents, expected, sizeof expected));
    assert(!memcmp([vm->vbytes[@4] bytes], records, sizeof records));
    assert(!memcmp(native, unchanged, sizeof native));
    assert(!memcmp(table + 48, &original_address, 8));
    [encoder.actual drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:1 baseInstance:2];
    [encoder.actual endEncoding]; encoder.actual = nil;
    // The following draw, even a non-skinned draw, gets the exact native root
    // and instance inputs back. A private skinning offset cannot leak into it.
    vm->bytes = [NSData dataWithBytes:top length:sizeof top];
    objc_setAssociatedObject(encoder, kEncVM, vm, OBJC_ASSOCIATION_RETAIN);
    vrik_apply(encoder, 0, 1, 0, nil, 0, MTLIndexTypeUInt16);
    assert(!vm->pose_bound);
    assert([encoder.restored[@2] isEqualToData:vm->bytes]);
    assert([encoder.restored[@4] isEqualToData:vm->vbytes[@4]]);
    objc_setAssociatedObject(encoder, kEncVM, nil, OBJC_ASSOCIATION_RETAIN);
    assert(vrik_bind_palette(encoder, vm, top, sizeof top, table, sizeof table, first, layout, 2, 256));
    assert(g_pose_buffers.count == 1 && entry->buffer == copy);
    // Every object matrix byte belongs to the key, including its middle rows.
    // A textual NSData description can truncate these bytes and alias poses.
    first->obj.m[7] = .2f;
    assert(vrik_bind_palette(encoder, vm, top, sizeof top, table, sizeof table, first, layout, 2, 256));
    VXPoseCopy *variant = fixture_copy(first, encoder.command);
    assert(variant->buffer != copy);
    first->obj = aff_id();
    first->posed[0].m[3] = .65f; vrik_publish_palette(first);
    assert(((aff *)copy.contents)[0].m[3] == .65f);
    assert(((aff *)variant->buffer.contents)[0].m[3] == .8f);
    first->posed[0].m[3] = .8f; vrik_publish_palette(first);
    // Overlapping native ranges belong to independent consumers. Updating a
    // receiver cannot overwrite the magazine's separately solved palette.
    second->posed[0].m[7] = .3f; second->applied = 1; second->mod_k1 = second->mod_k2 = 0;
    assert(vrik_bind_palette(encoder, vm, top, sizeof top, table, sizeof table, second, layout, 2, 256));
    VXPoseCopy *part = fixture_copy(second, encoder.command);
    assert(part->buffer != copy && ((aff *)part->buffer.contents)[0].m[7] == .3f);
    first->posed[1].m[7] = .4f; vrik_publish_palette(first);
    assert(((aff *)part->buffer.contents)[0].m[7] == .3f);
    // Dynamic strides use the matching setter; invalid or oversized records
    // fail without replacing the native binding.
    vm->vst[4] = 80;
    NSArray *dynamic = @[@4,@0,@(MTLBufferLayoutStrideDynamic),@(MTLVertexStepFunctionPerInstance),@1,@0,@16];
    assert(vrik_bind_palette(encoder, vm, top, sizeof top, table, sizeof table, first, dynamic, 2, 256));
    assert(vm->pose_instance_dynamic);
    assert(!vrik_bind_palette(encoder, vm, top, sizeof top, table, sizeof table, first, layout, 3, 256));

    // Sealing closes the write window before commit, not after status happens
    // to change. The GPU never races a late pose publication.
    id<MTLCommandBuffer> submitted = encoder.command;
    vxpipe_pose_seal_command_buffer(submitted);
    first->posed[0].m[3] = .75f; vrik_publish_palette(first);
    assert(((aff *)copy.contents)[0].m[3] == .8f);
    first->posed[0].m[3] = .8f;
    assert(!vrik_bind_palette(encoder, vm, top, sizeof top, table, sizeof table, first, layout, 2, 256));
    [submitted commit]; [submitted waitUntilCompleted];
    assert(submitted.status == MTLCommandBufferStatusCompleted && !submitted.error);
    uint8_t pixel[4];
    [texture getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(2,2,1,1) mipmapLevel:0];
    assert(abs(pixel[0] - 204) <= 1 && pixel[1] == 255 && abs(pixel[2] - 230) <= 1 && pixel[3] == 255);
    encoder.command = [queue commandBuffer];
    assert(vrik_bind_palette(encoder, vm, top, sizeof top, table, sizeof table, first, layout, 2, 256));
    first->posed[0].m[3] = .7f; vrik_publish_palette(first);
    assert(((aff *)copy.contents)[0].m[3] == .8f);
    VXPoseCopy *active = fixture_copy(first, encoder.command);
    assert(((aff *)active->buffer.contents)[0].m[3] == .7f);
    // The real device used a 54 MB native arena. Its size must never become a
    // per-consumer allocation. Unknown/unbounded shader spans are refused.
    uint8_t *arena = calloc(54 * 1024 * 1024, 1);
    assert(arena); memcpy(arena, native, sizeof native);
    vrik_pal huge = {.obj=aff_id()};
    assert(vrik_capture_palette(&huge, arena, 54 * 1024 * 1024, 0x2000, 0, 101));
    huge.applied = 1; huge.mod_k1 = huge.mod_k2 = 0;
    unsigned long copied_before = atomic_load(&g_pose_copy_bytes);
    assert(vrik_bind_palette(encoder, vm, top, sizeof top, table, sizeof table, &huge, layout, 2, 256));
    VXPoseCopy *bounded = fixture_copy(&huge, encoder.command);
    assert(bounded->buffer.length == 256 * 48);
    assert(atomic_load(&g_pose_copy_bytes) - copied_before == 256 * 48 + 8192 + sizeof records);
    assert(!vrik_bind_palette(encoder, vm, top, sizeof top, table, sizeof table, &huge, layout, 2, 0));
    assert(!vrik_bind_palette(encoder, vm, top, sizeof top, table, sizeof table, &huge, layout, 2, 65536));
    free(arena);
    // A real native animation update invalidates the output cache. New frames
    // cannot modify old command-buffer copies.
    native[0].m[7] = .2f;
    assert(vrik_capture_palette(first, (uint8_t *)native, sizeof native, 0x1000, 96, 101));
    assert(!first->applied && !memcmp(first->P, native, sizeof first->posed));
    first->posed[0].m[3] = .6f; first->applied = 1; first->mod_k1 = first->mod_k2 = 0;
    vrik_publish_palette(first);
    assert(((aff *)copy.contents)[0].m[3] == .8f);
    assert(((aff *)active->buffer.contents)[0].m[3] == .7f);
    [encoder.command commit]; [encoder.command waitUntilCompleted];
    g_pose_buffers = nil;
    memset(&g_vk, 0, sizeof g_vk);
}

static void assert_grip(vrik_grip_pose actual, vrik_grip_pose expected) {
    assert(vrik_distance(actual.at, expected.at) < .00001f);
    assert(v3dot(actual.fwd, expected.fwd) > .99999f);
    assert(v3dot(actual.up, expected.up) > .99999f);
}

static void test_body_space(void) {
    memset(&g_vk, 0, sizeof g_vk);
    g_vk.capture_body = 1; g_vk.rigv = 0; g_vk.held.owner = -1;
    g_vk.solve_frame = g_vk.capture_frame = 42; g_vk.have_af[0] = g_vk.have_af[1] = 1;
    g_vk.obj = aff_rot((float[3]){0,0,1}, .6f, (float[3]){0,0,0});
    g_vk.obj.m[3] = 1.2f; g_vk.obj.m[7] = .8f;
    for (int k = 0; k < 7; k++) {
        g_vk.D[k] = aff_rot((float[3]){0,1,0}, .07f * k, (float[3]){0,0,1.4f});
        g_vk.D[k].m[7] += .02f * k;
    }
    for (int k = 0; k < 2; k++) g_vk.D_w0[k] = g_vk.D_w1[k] = g_vk.D_w2[k] = g_vk.D[k ? 6 : 3];
    int list = -1;
    for (int i = 0; i < VRIK_NLISTS && list < 0; i++) {
        unsigned n = vrik_list_off[i+1] - vrik_list_off[i];
        int hands = 0;
        if (n > 128) continue;
        for (unsigned k = 0; k < n; k++) {
            int name = vrik_list[vrik_list_off[i]+k];
            hands |= name == VRIK_LEFTHAND ? 1 : name == VRIK_RIGHTHAND ? 2 : 0;
        }
        if (hands == 3) list = i;
    }
    assert(list >= 0);
    vrik_pal base = {.L=list, .rig=0, .frame=42, .cap_b=128};
    base.nb = vrik_list_off[list+1] - vrik_list_off[list];
    base.P = (uint8_t *)base.posed; base.obj = g_vk.obj; base.view = aff_id();
    for (unsigned k = 0; k < base.nb; k++) base.orig[k] = aff_id();
    vrik_pal shifted = base; shifted.P = (uint8_t *)shifted.posed;
    aff shift = aff_rot((float[3]){0,0,1}, .06f, (float[3]){0,0,1.4f});
    shift.m[3] += .025f; shift.m[7] -= .012f;
    shifted.obj = aff_mul(base.obj, shift);
    for (unsigned k = 0; k < base.nb; k++) shifted.orig[k] = aff_mul(aff_inv(shift), base.orig[k]);
    vrik_apply_pal_pose(&base); vrik_apply_pal_pose(&shifted);
    assert(base.applied && shifted.applied);
    for (unsigned k = 0; k < base.nb; k++) {
        aff expected = aff_mul(base.obj, base.posed[k]);
        aff actual = aff_mul(shifted.obj, shifted.posed[k]);
        for (int j = 0; j < 12; j++) assert(fabsf(expected.m[j] - actual.m[j]) < .00001f);
    }
    // The holding palm uses the same room target in both body frames, too.
    g_vk.held.owner = 1; g_vk.held.rig = 0; g_vk.held.wrists = 2;
    g_vk.held.room_from_view = aff_id(); g_vk.held.right_grip_valid = 1;
    g_vk.held.right_grip_frame = 42; g_vk.weap[6] = 2;
    vrik_grip_pose target = {{.2f,-.3f,.4f},{0,0,1},{0,1,0}};
    g_vk.held.right_grip_view = vrik_grip_basis(&target);
    base.applied = shifted.applied = 0;
    vrik_apply_pal_pose(&base); vrik_apply_pal_pose(&shifted);
    for (unsigned k = 0; k < base.nb; k++) {
        int name = vrik_list[vrik_list_off[list]+k];
        if (name != VRIK_RIGHTHAND) continue;
        vrik_grip_pose palm;
        assert(vrik_trigger_grip(1, aff_mul(base.obj,base.posed[k]), &palm));
        assert_grip(palm,target);
        assert(vrik_trigger_grip(1, aff_mul(shifted.obj,shifted.posed[k]), &palm));
        assert_grip(palm,target);
    }
}

static void test_palm_contacts(void) {
    memset(&g_vk, 0, sizeof g_vk);
    g_vk.rigv = 0; g_vk.held.owner = 1; g_vk.held.epoch = 3; g_vk.held.at = 1;
    vrik_grip_pose right, left;
    assert(vrik_trigger_grip(1, aff_id(), &right));
    assert(vrik_trigger_grip(0, aff_id(), &left));
    // Intersect the actual rig's two palms at parallel and crossed angles.
    for (int k = 0; k < 8; k++) {
        vrik_grip_pose overlap = right;
        aff turn = aff_rot((float[3]){0,0,1}, .4f*k, right.at);
        overlap = vrik_grip_in(turn, &overlap);
        aff hand = vrik_retarget_grip(left.at, left.fwd, left.up, overlap.at, overlap.fwd, overlap.up);
        vrik_grip_pose wrist;
        assert(vrik_wrist_frame_from(0, hand, wrist.at, wrist.fwd, wrist.up));
        vrik_grip_pose corrected = wrist;
        vrik_separate_support(aff_id(), hand, &corrected);
        aff move = vrik_retarget_grip(wrist.at,wrist.fwd,wrist.up, corrected.at,corrected.fwd,corrected.up);
        float a[2][3], b[2][3], r, l, delta[3];
        assert(vrik_palm_capsule(1, aff_id(), a, &r));
        assert(vrik_palm_capsule(0, aff_mul(move,hand), b, &l));
        assert(vrik_segment_gap(a,b,delta) >= r+l+.0019f);
        assert(v3dot(wrist.fwd,corrected.fwd) > .99999f);
    }
    // A contact stays weapon-local for one button hold, across native ADS/
    // idle changes and frame/camera movement. Releasing allows a new contact.
    g_vk.weap[5] = VRIK_BTN_L_TRIG; g_vk.weap[7] = 2;
    vrik_set_support(&right,&left,1);
    vrik_grip_pose fixed = g_vk.support_local;
    left.at[0] += .2f; g_vk.capture_frame++;
    vrik_set_support(&right,&left,1);
    assert_grip(g_vk.support_local,fixed);
    g_vk.weap[5] = 0;
    vrik_set_support(&right,&left,1);
    assert(!g_vk.support_pose.locked && vrik_distance(g_vk.support_local.at,fixed.at) > .19f);
    g_vk.weap[5] = VRIK_BTN_L_TRIG; g_vk.held.epoch++;
    vrik_set_support(&right,&left,1);
    assert(g_vk.support_pose.locked && g_vk.support_pose.epoch == g_vk.held.epoch);
}

static int magazine_fixture_state;
static double magazine_fixture_started;
static int magazine_fixture(double *started, unsigned *ejection) {
    *started=magazine_fixture_started;*ejection=101;return magazine_fixture_state;
}

static void test_ammunition_parts(void) {
    memset(&g_vk,0,sizeof g_vk);
    g_vk.held.owner=1;g_vk.held.epoch=1;
    g_vk.held.room_from_view=aff_id();g_vk.held.hands_ok[0]=1;
    g_vk.held.hands[0][0]=-.3f;g_vk.held.hands[0][1]=-.2f;g_vk.held.hands[0][2]=-.4f;
    g_vk.held.hands[0][5]=-1;g_vk.held.hands[0][6]=-1;
    g_vk.held.at=CACurrentMediaTime();
    // A mixed palette has two ammunition joints and one receiver. They share
    // a pickup root but keep distinct animated transforms during drop/carry.
    vrik_asset_profile profile={.bones=3,.root=0,.trigger=-1,.slide=-1,.cylinder=-1,
                                .hinge=-1,.support=-1,.ammo=6};
    vrik_pal parts={.asset=&profile,.L=-1,.cap_b=128,.nb=3};
    parts.obj=aff_rot((float[3]){1,0,0},.3f,(float[3]){0,0,0});parts.obj.m[3]=.12f;
    parts.view=aff_rot((float[3]){0,1,0},-.4f,(float[3]){0,0,0});
    parts.P=(uint8_t *)parts.posed;
    parts.orig[0]=aff_id();parts.orig[1]=aff_id();
    parts.orig[2]=aff_rot((float[3]){0,0,1},.17f,(float[3]){0,0,0});parts.orig[2].m[3]=.04f;
    aff original[3];memcpy(original,parts.orig,sizeof original);
    vrik_item_grip item={0};
    vrik_mag_query=magazine_fixture;magazine_fixture_started=CACurrentMediaTime()-.3;
    for(int state=HW_EMPTY;state<=HW_HOLD_NEW;state++) {
        magazine_fixture_state=state;
        aff first=vrik_magazine_pose(&parts,&item,parts.orig[1],1);
        aff second=vrik_magazine_pose(&parts,&item,parts.orig[2],2);
        aff relative=aff_mul(aff_inv(first),second);
        for(int k=0;k<12;k++)assert(fabsf(relative.m[k]-parts.orig[2].m[k])<.0001f);
        assert(!memcmp(parts.orig,original,sizeof original));
        assert(vrik_distance((float[3]){first.m[3],first.m[7],first.m[11]},
                            (float[3]){second.m[3],second.m[7],second.m[11]})>.039f);
    }
    magazine_fixture_state=HW_LOADED;
    aff loaded=vrik_magazine_pose(&parts,&item,parts.orig[2],2);
    assert(!memcmp(&loaded,&original[2],sizeof loaded));
    magazine_fixture_state=HW_EMPTY;
    int identity;parts.indices=&identity;parts.count=999;
    vrik_apply_pal(&parts);
    assert(parts.applied && !memcmp(&parts.posed[0],&original[0],sizeof(aff)));
    assert(memcmp(&parts.posed[1],&original[1],sizeof(aff)));
    assert(memcmp(&parts.posed[2],&original[2],sizeof(aff)));
    assert(!memcmp(parts.orig,original,sizeof original));
    g_vk.capture_frame=parts.frame;g_vk.npals=1;g_vk.pals[0]=parts;
    NSDictionary *snapshot=vrik_capture_snapshot();
    NSError *error=nil;
    NSData *json=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:&error];
    assert(json && !error && json.length<1024*1024);
    NSDictionary *decoded=[NSJSONSerialization JSONObjectWithData:json options:0 error:&error];
    assert(!error && [decoded[@"palettes"] count]==1);
    assert([decoded[@"palettes"][0][@"original"] count]==36);
    assert(!memcmp(g_vk.pals[0].orig,original,sizeof original));
    vrik_mag_query=NULL;
    puts("ammo parts: drop/carry retain joint separation and rotation; loaded pose/source unchanged: ok");
}

static void test_asset_adapter(void) {
    const vrik_asset_profile *rifle=vrik_asset_match(75096,UINT64_C(0xf6ee3549d6f57bd8));
    const vrik_asset_profile *pistol=vrik_asset_match(41373,UINT64_C(0x0c137715f8f56073));
    const vrik_asset_profile *magazine=vrik_asset_match(9588,UINT64_C(0x2f18aa2ea093ed51));
    if (!rifle || !pistol || !magazine) { puts("asset adapter: private catalog absent; fixtures skipped");return; }
    memset(&g_vk,0,sizeof g_vk);
    g_vk.capture_body=g_vk.weapon_origin_valid=g_vk.have_h[1]=1;
    g_vk.rigv=g_vk.held.rig=0;g_vk.capture_frame=g_vk.solve_frame=101;
    g_vk.held.owner=1;g_vk.held.epoch=3;g_vk.held.wrists=3;g_vk.held.at=CACurrentMediaTime();
    g_vk.obj=g_vk.vcam=g_vk.held.room_from_view=aff_id();
    vrik_grip_pose native;
    assert(vrik_trigger_grip(1,aff_id(),&native));
    g_vk.native_item_grip=native;g_vk.trigger_source.valid=1;
    g_vk.trigger_source.hand=vrik_grip_basis(&native);g_vk.trigger_source.finger=aff_id();
    g_vk.hand_shape[0].ready=g_vk.hand_shape[1].ready=1;
    g_vk.hand_shape[0].count=g_vk.hand_shape[1].count=1;
    g_vk.hand_shape[0].points[0][2]=.035f;g_vk.hand_shape[1].points[0][2]=-.035f;
    g_vk.weap[5]=VRIK_BTN_L_TRIG;g_vk.weap[6]=2;g_vk.weap[7]=2;
    vrik_grip_pose target={{.2f,-.3f,.4f},{0,0,1},{0,1,0}};
    g_vk.held.right_grip_valid=1;g_vk.held.right_grip_frame=101;
    g_vk.held.right_grip_view=vrik_grip_basis(&target);
    vrik_pal receiver={.asset=rifle,.count=rifle->count,.cap_b=128,.nb=rifle->bones,.L=-1,.frame=101};
    receiver.obj=receiver.view=aff_id();receiver.P=(uint8_t *)receiver.posed;
    for(unsigned k=0;k<receiver.nb;k++)receiver.orig[k]=aff_id();
    assert(vrik_asset_latch(&receiver));
    aff fixed=g_vk.asset_grip.in_root;
    float finger[3],local[3],expected[3],actual[3];
    aff_pt(g_vk.trigger_source.finger.m,vrik_bindpos(0,vrik_finger_bones[1][0][2]),finger);
    aff_pt(aff_inv(g_vk.trigger_source.hand).m,finger,local);
    aff_pt(vrik_grip_basis(&target).m,local,expected);
    vrik_apply_pal(&receiver);
    aff_pt(receiver.posed[rifle->root].m,rifle->trigger_at,actual);
    assert(vrik_distance(actual,expected)<.00001f);
    // The body's native ready/ADS animation changes independently. The bound
    // receiver root must keep the exact original hand-relative connection.
    receiver.frame=g_vk.capture_frame=g_vk.solve_frame=g_vk.held.right_grip_frame=102;
    g_vk.weapon_frame.valid=0;g_vk.native_item_grip.at[0]+=.23f;
    aff animated=aff_rot((float[3]){0,0,1},.45f,(float[3]){0,0,0});animated.m[7]=.17f;
    for(unsigned k=0;k<receiver.nb;k++)receiver.orig[k]=animated;
    receiver.view=aff_rot((float[3]){1,0,0},.12f,(float[3]){0,0,0});receiver.view.m[3]=.03f;
    vrik_apply_pal(&receiver);
    assert(!memcmp(&fixed,&g_vk.asset_grip.in_root,sizeof fixed));
    aff shown=aff_mul(receiver.view,receiver.posed[rifle->root]);
    aff_pt(shown.m,rifle->trigger_at,actual);
    assert(vrik_distance(actual,expected)<.00001f);
    // The long-gun support palm is on the measured forward receiver surface,
    // with the palm facing upward, independent of the free wrist's position.
    vrik_grip_pose supported=vrik_grip_in(vrik_grip_basis(&target),&g_vk.support_local);
    vrik_grip_pose left_native;
    assert(vrik_trigger_grip(0,aff_id(),&left_native));
    vrik_grip_pose left_wrist;
    assert(vrik_wrist_frame_from(0,aff_id(),left_wrist.at,left_wrist.fwd,left_wrist.up));
    aff left_pose=vrik_retarget_grip(left_wrist.at,left_wrist.fwd,left_wrist.up,
                                   supported.at,supported.fwd,supported.up);
    vrik_grip_pose palm=vrik_grip_in(left_pose,&left_native);
    float source_point[3];memcpy(source_point,rifle->support_at,sizeof source_point);
    float ends[2][3],radius;assert(vrik_palm_capsule(0,aff_id(),ends,&radius));source_point[2]-=.5f*radius;
    aff root=aff_mul(g_vk.weapon_frame.world_delta,animated);aff_pt(root.m,source_point,expected);
    assert(vrik_distance(palm.at,expected)<.00001f);
    float palm_normal[3];v3cross(palm.fwd,palm.up,palm_normal);
    float receiver_up[3]={root.m[2],root.m[6],root.m[10]};
    assert(-v3dot(palm_normal,receiver_up)>.99f); // Left palm, not its back, faces the gun.
    // A two-hand pistol grip puts the supporting fingers outside the holding
    // finger volume instead of retargeting the two wrist origins onto each other.
    g_vk.support_pose.locked=0;g_vk.weap[7]=1;
    vrik_asset_support(pistol,aff_id(),&g_vk.weapon_frame.native_world);
    float spacing=vrik_pistol_spacing();
    assert(spacing>=.07f);
    assert(g_vk.support_pose.locked);
    // A newly recognized Achilles magazine follows the real empty/held state;
    // its receiver and the game's input matrices are not modified by ejection.
    vrik_mag_query=magazine_fixture;magazine_fixture_started=CACurrentMediaTime()-.25;
    magazine_fixture_state=HW_EMPTY;
    vrik_pal ammo={.asset=magazine,.magazine=VRIK_CATALOG_AMMO,.L=-1,.cap_b=128,
                   .nb=magazine->bones,.count=magazine->count,.frame=102};
    int ammo_identity;ammo.indices=&ammo_identity;ammo.obj=ammo.view=aff_id();ammo.P=(uint8_t *)ammo.posed;
    for(unsigned k=0;k<ammo.nb;k++)ammo.orig[k]=aff_id();
    aff saved=receiver.posed[0];vrik_apply_pal(&ammo);
    assert(ammo.applied && ammo.posed[0].m[7]<-.1f);
    assert(!memcmp(&saved,&receiver.posed[0],sizeof saved));
    assert(!memcmp(&ammo.orig[0],&(aff){{1,0,0,0,0,1,0,0,0,0,1,0}},sizeof(aff)));
    const vrik_asset_profile *cylinder=NULL;
    for(unsigned i=0;i<VRIK_ASSET_COUNT;i++)if(vrik_assets[i].cylinder>=0){cylinder=&vrik_assets[i];break;}
    assert(cylinder);
    vrik_pal revolver={.asset=cylinder};
    aff open=vrik_cylinder_pose(&revolver,aff_id(),cylinder->cylinder);
    assert(fabsf(open.m[0]-1.f)>.1f);
    magazine_fixture_state=HW_LOADED;
    aff closed=vrik_cylinder_pose(&revolver,aff_id(),cylinder->cylinder);
    assert(!memcmp(&closed,&(aff){{1,0,0,0,0,1,0,0,0,0,1,0}},sizeof closed));
    vrik_mag_query=NULL;
    puts("asset adapter: root-bound trigger, native animation/camera changes, surface support, finger clearance, real-magazine ejection and cylinder isolation: ok");
}

static void test_geometry_cache(void) {
    g_vk_nmesh=0;memset(g_vk_mesh,0,sizeof g_vk_mesh);
    aff bones[128];
    int list=2651;unsigned start=vrik_list_off[list],nb=vrik_list_off[list+1]-start;
    aff root=aff_id();root.m[3]=.6f;
    int ready[128]={0};
    for(unsigned pass=0;pass<nb;pass++)for(unsigned k=0;k<nb;k++) {
        int parent=vrik_list_par[start+k],name=vrik_list[start+k];
        if(ready[k] || (parent>=0 && !ready[parent]))continue;
        bones[k]=parent>=0 ? bones[parent] : root;
        const float *pivot=vrik_bindpos(0,name);
        if(pivot)bones[k]=aff_mul(bones[k],aff_rot((float[3]){1,0,0},.07f,pivot));
        ready[k]=1;
    }
    assert(vrik_try((uint8_t *)bones,nb,nb,nb,list,0)>=0);
    int mesh_identity,rig=0;
    int identified=vrik_identify(&mesh_identity,4,23928,0,(uint8_t *)bones,nb,nb,nb,&rig);
    assert(identified>=0 && g_vk_nmesh==1);
    for(unsigned offset=48;offset<48000;offset+=48)
        assert(vrik_identify(&mesh_identity,4,23928,offset,(uint8_t *)bones,nb,nb,nb,&rig)==identified);
    assert(g_vk_nmesh==1);
    // Reused index storage must not retain a body identity if its palette no
    // longer agrees on any articulated joints.
    for(unsigned k=0;k<nb;k++)bones[k]=aff_id();
    assert(vrik_identify(&mesh_identity,4,23928,48000,(uint8_t *)bones,nb,nb,nb,&rig)<0);
    assert(g_vk_nmesh==1);
    // Filling the table still admits later live geometry through replacement.
    int identities[260];
    for(int k=0;k<260;k++)vrik_identify(&identities[k],0,6,0,(uint8_t *)bones,nb,nb,nb,&rig);
    assert(g_vk_nmesh==256);
    int found=0;for(int k=0;k<256;k++)if(g_vk_mesh[k].ib==&identities[259])found=1;
    assert(found);
    puts("geometry cache: changing arena offsets reuse identity, stale joints refused, full table replaces entries: ok");
}

static float test_determinant(aff m) {
    float x[3]={m.m[0],m.m[4],m.m[8]},y[3]={m.m[1],m.m[5],m.m[9]},z[3];
    v3cross(x,y,z);return z[0]*m.m[2]+z[1]*m.m[6]+z[2]*m.m[10];
}

static void test_view_handedness(void) {
    memset(&g_vk,0,sizeof g_vk);g_vk.vcam=aff_id();g_vk.vcam.m[10]=-1;
    vrik_grip_pose target={{.2f,-.1f,.4f},{1,0,0},{0,1,0}};
    aff view=vrik_view_palm_basis(&target),world=aff_mul(aff_inv(g_vk.vcam),view);
    assert(test_determinant(view)<-.999f && test_determinant(world)>.999f);
    vrik_grip_pose local={{.01f,.02f,.035f},{1,0,0},{0,1,0}};
    vrik_grip_pose from_body=vrik_support_in_body(aff_inv(g_vk.vcam),&target,&local);
    vrik_grip_pose from_view=vrik_grip_in(g_vk.vcam,&from_body);
    vrik_grip_pose directly=vrik_grip_in(view,&local);
    assert_grip(from_view,directly);
    assert(fabsf(directly.at[2]-(target.at[2]-.035f))<.00001f);
    puts("left-handed game camera: physical palm basis, gun rotation and support offsets retain chirality: ok");
}

static aff test_json_aff(NSArray *values,unsigned offset) {
    assert(values.count>=offset+12);aff result;
    for(int k=0;k<12;k++)result.m[k]=[values[offset+k] floatValue];
    return result;
}

static void test_device_replays(void) {
    const char *directory=getenv("VXMAC_TEST_REPLAY_DIR");if(!directory)return;
    NSArray *files=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(directory) error:nil];
    unsigned checked=0,unmatched=0;
    for(NSString *file in files) {
        if(![file.pathExtension isEqualToString:@"json"])continue;
        NSData *bytes=[NSData dataWithContentsOfFile:[@(directory) stringByAppendingPathComponent:file]];
        assert(bytes && bytes.length<=1024*1024);
        NSDictionary *record=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
        assert([record[@"schema"] intValue]==1);
        NSDictionary *body=nil,*weapon=nil;int wrist=-1,tip=-1;
        const vrik_asset_profile *profile=NULL;
        for(NSDictionary *p in record[@"palettes"]) {
            int list=[p[@"list"] intValue];
            if(list>=0) {
                unsigned off=vrik_list_off[list],count=vrik_list_off[list+1]-off;
                int w=-1,t=-1;for(unsigned k=0;k<count;k++) {
                    if(vrik_list[off+k]==VRIK_RIGHTHAND)w=k;
                    if(vrik_list[off+k]==vrik_finger_bones[1][0][2])t=k;
                }
                if(w>=0 && t>=0) {body=p;wrist=w;tip=t;}
            } else if([p[@"asset"] intValue]) {
                for(unsigned k=0;k<VRIK_ASSET_COUNT;k++)
                    if(vrik_assets[k].asset==[p[@"asset"] intValue] && (vrik_assets[k].kind&1)) {
                        weapon=p;profile=&vrik_assets[k];break;
                    }
            }
        }
        if(!body || !weapon) {unmatched++;continue;}
        memset(&g_vk,0,sizeof g_vk);
        unsigned frame=[record[@"frame"] unsignedIntValue];
        g_vk.capture_body=g_vk.weapon_origin_valid=g_vk.have_h[1]=1;
        g_vk.rigv=g_vk.held.rig=[body[@"rig"] intValue];g_vk.capture_frame=g_vk.solve_frame=frame;
        g_vk.held.owner=1;g_vk.held.epoch=1;g_vk.held.wrists=3;g_vk.held.at=CACurrentMediaTime();
        g_vk.obj=test_json_aff(body[@"object"],0);g_vk.vcam=test_json_aff(body[@"view"],0);
        g_vk.held.room_from_view=aff_inv(g_vk.vcam);
        g_vk.held.right_grip_view=test_json_aff(record[@"tracked_grip"],0);
        g_vk.held.right_grip_valid=1;g_vk.held.right_grip_frame=frame;
        vrik_grip_pose native,target;
        assert(vrik_trigger_grip(1,test_json_aff(body[@"original"],wrist*12),&native));
        g_vk.native_item_grip=vrik_grip_in(aff_mul(g_vk.vcam,g_vk.obj),&native);
        for(int k=0;k<3;k++) {target.at[k]=g_vk.held.right_grip_view.m[k*4+3];target.fwd[k]=g_vk.held.right_grip_view.m[k*4];target.up[k]=g_vk.held.right_grip_view.m[k*4+1];}
        aff body_from_view=aff_inv(aff_mul(g_vk.vcam,g_vk.obj));
        vrik_grip_pose body_target=vrik_grip_in(body_from_view,&target);
        aff drawn_finger=test_json_aff(body[@"posed"],tip*12);
        // Recover the immutable finger/palm relationship actually shown by
        // this device sample, rather than assuming a synthetic identity hand.
        g_vk.trigger_source.valid=1;g_vk.trigger_source.hand=aff_id();
        g_vk.trigger_source.finger=aff_mul(aff_inv(vrik_grip_basis(&body_target)),drawn_finger);
        vrik_pal receiver={.asset=profile,.count=[weapon[@"indices"] unsignedLongValue],
            .cap_b=128,.nb=profile->bones,.L=-1,.frame=frame};
        receiver.obj=test_json_aff(weapon[@"object"],0);receiver.view=test_json_aff(weapon[@"view"],0);
        receiver.P=(uint8_t *)receiver.posed;
        for(unsigned k=0;k<receiver.nb;k++)receiver.orig[k]=test_json_aff(weapon[@"original"],k*12);
        vrik_apply_pal(&receiver);assert(receiver.applied);
        assert(test_determinant(receiver.posed[profile->root])>.99f);
        float expected[3],actual[3];const float *bind=vrik_bindpos(g_vk.rigv,vrik_finger_bones[1][0][2]);
        aff body_view=aff_mul(g_vk.vcam,g_vk.obj);
        aff_pt(aff_mul(body_view,drawn_finger).m,bind,expected);
        aff shown=aff_mul(aff_mul(receiver.view,receiver.obj),receiver.posed[profile->root]);
        aff_pt(shown.m,profile->trigger_at,actual);
        float gap=vrik_distance(actual,expected);assert(gap<.00002f);
        // Negative control: the former matrix product reflects the gun but
        // not the body. Reproduce it against the very same captured finger.
        aff native_root=aff_mul(receiver.obj,receiver.orig[profile->root]);
        aff root_basis=native_root;float origin[3];aff_pt(root_basis.m,profile->root_at,origin);
        for(int k=0;k<3;k++)root_basis.m[k*4+3]=origin[k];
        aff old_target=aff_mul(aff_inv(g_vk.vcam),g_vk.held.right_grip_view);
        aff old_delta=aff_mul(old_target,aff_inv(aff_mul(root_basis,g_vk.asset_grip.in_root)));
        aff old_shown=aff_mul(receiver.view,aff_mul(old_delta,native_root));
        aff_pt(old_shown.m,profile->trigger_at,actual);
        float old_gap=vrik_distance(actual,expected);
        assert(test_determinant(old_delta)<-.99f && old_gap>.02f);
        if(!(profile->kind&(4|8)) && ((profile->kind&16) || profile->support>=0)) {
            vrik_grip_pose supported=vrik_support_in_body(body_from_view,&target,&g_vk.support_local);
            vrik_grip_pose left_wrist,left_palm;
            assert(vrik_wrist_frame_from(0,aff_id(),left_wrist.at,left_wrist.fwd,left_wrist.up));
            assert(vrik_trigger_grip(0,aff_id(),&left_palm));
            aff left_pose=vrik_retarget_grip(left_wrist.at,left_wrist.fwd,left_wrist.up,
                                           supported.at,supported.fwd,supported.up);
            vrik_grip_pose palm_world=vrik_grip_in(aff_mul(g_vk.obj,left_pose),&left_palm);
            float point[3],ends[2][3],radius;memcpy(point,profile->support_at,sizeof point);
            assert(vrik_palm_capsule(0,aff_id(),ends,&radius));point[2]-=.5f*radius;
            aff root=aff_mul(g_vk.weapon_frame.world_delta,native_root);
            aff_pt(root.m,point,expected);
            assert(vrik_distance(palm_world.at,expected)<.00002f);
            float normal[3],up[3]={root.m[2],root.m[6],root.m[10]};
            v3cross(palm_world.fwd,palm_world.up,normal);
            assert(-v3dot(normal,up)>.99f);
        }
        printf("device replay %s: indices=%lu proper gun rotation, trigger/finger gap %.6f -> %.6f m; applicable support surface checked\n",
               file.UTF8String,(unsigned long)receiver.count,old_gap,gap);
        checked++;
    }
    assert(checked>=3);printf("device replays: %u matched receivers checked; %u samples lack a captured recognized receiver\n",checked,unmatched);
}

int main(void) { @autoreleasepool {
    setenv("VXMAC_JOY_HOLD", "1", 1);
    test_saved_shader_profiles();
    test_palette_isolation();
    test_render_dispatch();
    test_body_space();
    test_palm_contacts();
    test_ammunition_parts();
    test_asset_adapter();
    test_geometry_cache();
    test_view_handedness();
    test_device_replays();
    memset(&g_vk, 0, sizeof g_vk);
    g_vk.capture_body = g_vk.weapon_origin_valid = 1;
    g_vk.capture_frame = g_vk.solve_frame = 7;
    g_vk.obj = g_vk.vcam = g_vk.held.room_from_view = aff_id();
    g_vk.have_h[1] = 1;
    g_vk.held.owner = 1;
    g_vk.held.wrists = 2;
    g_vk.held.epoch = 1;
    g_vk.held.at = 1;
    g_vk.held.right_grip_valid = 1;
    g_vk.held.right_grip_frame = 7;
    vrik_grip_pose target = {{.22f,-.28f,.38f},{1,0,0},{0,1,0}};
    g_vk.held.right_grip_view = vrik_grip_basis(&target);
    g_vk.native_item_grip = (vrik_grip_pose){{.02f,-.20f,.45f},{1,0,0},{0,1,0}};
    aff bone = aff_id();
    int index_identity;
    vrik_pal pal = {.P=(uint8_t *)&bone, .cap_b=1, .nb=1, .L=-1,
                    .indices=&index_identity, .count=100, .frame=7};
    pal.view = pal.obj = pal.orig[0] = aff_id();
    pal.obj.m[7] = -.20f; pal.obj.m[11] = .40f;
    vrik_item_grip *item = vrik_item_slot(&pal, 1);
    item->samples = 3;
    item->grip = vrik_grip_in(aff_inv(pal.obj), &g_vk.native_item_grip);
    item->grip.at[0] += .10f;
    vrik_grip_pose local = vrik_grip_in(aff_inv(pal.obj), &g_vk.native_item_grip);
    vrik_apply_pal(&pal);
    assert(pal.applied);
    assert(g_vk.weapon_frame.valid);
    assert_grip(vrik_grip_in(aff_mul(pal.obj, bone), &local), target);
    assert_grip(item->grip, local);

    // An equip/ready animation changes the mesh-to-native-palm relationship.
    // The tracked hand and weapon must still reach exactly the same target.
    pal.frame = g_vk.capture_frame = g_vk.solve_frame = 8;
    g_vk.held.right_grip_frame = 8;
    target = (vrik_grip_pose){{.17f,-.25f,.36f},{0,1,0},{-1,0,0}};
    g_vk.held.right_grip_view = vrik_grip_basis(&target);
    g_vk.native_item_grip.at[0] += .03f;
    g_vk.native_item_grip.at[2] += .02f;
    local = vrik_grip_in(aff_inv(pal.obj), &g_vk.native_item_grip);
    bone = aff_id();
    pal.applied = 0;
    vrik_apply_pal(&pal);
    assert_grip(vrik_grip_in(aff_mul(pal.obj, bone), &local), target);

    // A second part has a different origin, bone poses and render-pass camera.
    // It must receive the exact same world correction as the receiver. A late
    // arm draw in this frame cannot pull only this part to a newly inferred palm.
    aff expected_delta = g_vk.weapon_frame.world_delta;
    aff part_bones[2];
    int part_identity;
    vrik_pal part = {.P=(uint8_t *)part_bones, .cap_b=2, .nb=2, .L=-1,
                     .indices=&part_identity, .count=150, .frame=8};
    part.obj = aff_rot((float[3]){0,0,1}, .37f, (float[3]){0,0,0});
    part.obj.m[3] = .13f; part.obj.m[7] = -.14f; part.obj.m[11] = .31f;
    part.view = aff_rot((float[3]){1,0,0}, .2f, (float[3]){0,0,0});
    part.orig[0] = aff_id();
    part.orig[1] = aff_rot((float[3]){0,1,0}, -.23f, (float[3]){0,0,0});
    part.orig[1].m[3] = .08f; part.orig[1].m[7] = .17f;
    vrik_item_grip *mounted = vrik_item_slot(&part, 1);
    mounted->samples = 3;
    mounted->grip = (vrik_grip_pose){{9,9,9},{1,0,0},{0,1,0}};
    vrik_grip_pose saved_native = g_vk.native_item_grip;
    g_vk.native_item_grip.at[0] += .20f;
    g_vk.native_item_grip.fwd[0] = -1.f;
    g_vk.npals = 1;
    g_vk.pals[0].P = (uint8_t *)(part_bones + 1);
    g_vk.pals[0].frame = part.frame;
    for (int pass = 0; pass < 3; pass++) {
        vrik_apply_pal(&part);
        for (int k = 0; k < 2; k++) {
            aff expected = aff_mul(expected_delta, aff_mul(part.obj, part.orig[k]));
            aff shown = aff_mul(part.obj, part_bones[k]);
            for (int i = 0; i < 12; i++) assert(fabsf(shown.m[i] - expected.m[i]) < .00001f);
        }
    }
    g_vk.npals = 0;
    // Pairwise geometry survives repeated passes; no part is rescaled or bent.
    aff relative = aff_mul(aff_inv(part_bones[0]), part_bones[1]);
    for (int i = 0; i < 12; i++) assert(fabsf(relative.m[i] - part.orig[1].m[i]) < .00001f);
    g_vk.native_item_grip = saved_native;

    // A validated current hand takes precedence over a preliminary wrist draw.
    g_vk.hand_ref_mask = 2;
    g_vk.hand_ref[1] = aff_id(); g_vk.hand_ref[1].m[3] = 5.f;
    g_vk.SH[1] = aff_id(); g_vk.SH[1].m[3] = .08f;
    aff authored_hand;
    assert(vrik_authored_hand(1, 1., &authored_hand));
    assert(fabsf(authored_hand.m[3] - .08f) < .00001f);

    // A missing arm draw uses the most recently observed local grip.
    g_vk.capture_body = 0;
    pal.frame = g_vk.capture_frame = g_vk.held.right_grip_frame = 9;
    target.at[0] += .04f;
    g_vk.held.right_grip_view = vrik_grip_basis(&target);
    bone = aff_id();
    pal.applied = 0;
    vrik_apply_pal(&pal);
    assert_grip(vrik_grip_in(aff_mul(pal.obj, bone), &local), target);

    // Exercise the actual arm palette for button-only support and slide snap.
    int list = -1, left = -1;
    for (int i = 0; i < VRIK_NLISTS && list < 0; i++) {
        unsigned count = vrik_list_off[i + 1] - vrik_list_off[i];
        if (count > 128) continue;
        for (unsigned k = 0; k < count; k++) if (vrik_list[vrik_list_off[i] + k] == VRIK_LEFTHAND) {
            list = i; left = (int)k; break;
        }
    }
    assert(list >= 0);
    aff arm_bones[128];
    vrik_pal arm = {.P=(uint8_t *)arm_bones, .cap_b=128, .L=list, .rig=0, .frame=9};
    arm.nb = vrik_list_off[list + 1] - vrik_list_off[list];
    arm.obj = arm.view = aff_id();
    for (unsigned i = 0; i < arm.nb; i++) arm_bones[i] = arm.orig[i] = aff_id();
    g_vk.rigv = g_vk.held.rig = 0;
    g_vk.weap[5] = HW_BTN_L_TRIG;
    g_vk.weap[7] = 2; // Long gun: the left wrist need not be near its support grip.
    g_vk.support_local_owner = 1;
    g_vk.support_local_at = 1;
    g_vk.support_local = (vrik_grip_pose){{.02f,.23f,0},{1,0,0},{0,1,0}};
    g_vk.support_pose.locked = 1; g_vk.support_pose.epoch = g_vk.held.epoch;
    vrik_grip_pose authored;
    assert(vrik_wrist_frame_from(0, aff_id(), authored.at, authored.fwd, authored.up));
    vrik_apply_pal(&arm);
    vrik_grip_pose support_target = vrik_grip_in(vrik_grip_basis(&target), &g_vk.support_local);
    assert_grip(vrik_grip_in(arm_bones[left], &authored), support_target);
    aff fixed_support[128]; memcpy(fixed_support, arm_bones, sizeof fixed_support);
    for (unsigned k = 0; k < arm.nb; k++) {
        int name = vrik_list[vrik_list_off[list]+k];
        if (vrik_seg[name] == 3) arm.orig[k] = aff_rot((float[3]){0,0,1}, .4f, (float[3]){0,0,1.3f});
    }
    vrik_apply_pal(&arm);
    for (unsigned k = 0; k < arm.nb; k++) {
        int name = vrik_list[vrik_list_off[list]+k];
        if (vrik_seg[name] != 3) continue;
        for (int j = 0; j < 12; j++) assert(fabsf(arm_bones[k].m[j] - fixed_support[k].m[j]) < .00001f);
    }
    for (unsigned k = 0; k < arm.nb; k++) arm.orig[k] = aff_id();
    g_vk.support_pose.locked = 0;
    g_vk.weap[7] = 0;
    g_vk.slide_active = 1;
    g_vk.slide_hand = (vrik_grip_pose){{.11f,-.22f,.44f},{0,1,0},{1,0,0}};
    for (unsigned i = 0; i < arm.nb; i++) arm_bones[i] = arm.orig[i];
    vrik_apply_pal(&arm);
    assert_grip(vrik_grip_in(arm_bones[left], &authored), g_vk.slide_hand);
    g_vk.slide_active = 0; g_vk.weap[5] = 0;
    for (unsigned i = 0; i < arm.nb; i++) arm_bones[i] = arm.orig[i];
    vrik_apply_pal(&arm);
    assert_grip(vrik_grip_in(arm_bones[left], &authored), authored);
    puts("VRIK: immutable sources, independent command-buffer copies, body spaces, palm separation, latched support and slide: ok");
    return 0;
} }
