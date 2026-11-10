// vxpipe.m - the game's own Metal metadata, logged (VXMAC_PIPE_DUMP=<file>; off when unset)
//
// Every library the game makes (its function names), every render / compute pipeline (vertex / fragment / kernel
// function names and labels, attachment formats, blending), once each. With VXMAC_PIPE_REFLECT=1 the game's own
// pipeline calls ask Metal for reflection too (2 = compute only; the same compile, the options added): each buffer binding's name,
// size and struct members (name, offset, type), every distinct struct once. Then, one whole frame every
// VXMAC_PIPE_EVERY seconds (default 10, at most VXMAC_PIPE_FRAMES = 12 frames): each render pass's attachments
// (texture id, size, format, label, load / store), the pipelines it used in order, and the textures it bound
// (setXTexture and useResource), and each compute pass the same - so a target is told by which pipelines write it
// and which later passes read it, not by its pixels.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include "vxmac.h"
#include "vxprof.h"
#include "vxpipe.h"
#include "frame_camera.h"

static FILE *g_f;
static __thread void *tl_rec; static int tl_rec_any(void) { return tl_rec != NULL; }
static void wui_twin(id p, MTLRenderPipelineDescriptor *d, id<MTLFunction> fs);
static pthread_mutex_t g_fl = PTHREAD_MUTEX_INITIALIZER;
static int g_reflect, g_reflect_render;
static Class g_dump_device;
static Class g_dump_rc, g_dump_cc;
static int g_contract;
static void install_dump_encoders(void);
static atomic_int g_dump;           // (this frame is dumped)
static atomic_uint g_frame;
static unsigned g_frames_left = 60;   // (h51: 60 frames, one every 3 s: ~3 min of play)
static double g_every = 3, g_next_at;
static atomic_uint g_pipe_n, g_tex_n, g_pass_n;
static const void *kPID = &kPID, *kTID = &kTID, *kRec = &kRec;
static const void *kStereoInfo = &kStereoInfo, *kStereoSeen = &kStereoSeen;
static atomic_ulong g_stereo_draws, g_stereo_indices, g_stereo_multi_target, g_stereo_single_target, g_stereo_depth_only;
static int stereo_audit_enabled(void) {
    static int enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *e = getenv("VXMAC_STEREO_AUDIT");
        enabled = e && !strcmp(e, "1");
    });
    return enabled;
}

void vxpipe_stereo_stats(char *out, unsigned n) {
    if (!stereo_audit_enabled()) { if (n) out[0] = 0; return; }
    snprintf(out, n, "\"stereo_fg_draws\":%lu,\"stereo_fg_indices\":%lu,\"stereo_fg_multi_target\":%lu,"
                     "\"stereo_fg_single_target\":%lu,\"stereo_fg_depth_only\":%lu",
             atomic_load(&g_stereo_draws), atomic_load(&g_stereo_indices), atomic_load(&g_stereo_multi_target),
             atomic_load(&g_stereo_single_target), atomic_load(&g_stereo_depth_only));
}

static void out(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void out(const char *fmt, ...) {
    if (!g_f) return;
    va_list ap; va_start(ap, fmt);
    pthread_mutex_lock(&g_fl); vfprintf(g_f, fmt, ap); fputc('\n', g_f); fflush(g_f); pthread_mutex_unlock(&g_fl);
    va_end(ap);
}
static const char *s8(NSString *s) { return s.length ? s.UTF8String : "-"; }
static IMP swap(Class c, SEL s, IMP n) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) return NULL;
    if (!class_addMethod(c, s, n, method_getTypeEncoding(m))) return method_setImplementation(class_getInstanceMethod(c, s), n);
    return method_getImplementation(m);
}

// ---- (h62) what the game keeps alive through Metal, counted for the host's "mem" line (vxpipe_mem_stats) ------------
// A small object associated with each pipeline / library the game makes: its dealloc (with the game's object) takes it
// off the live count. Libraries also carry their data's size. VXUIRec / VXPassRec (ours) are counted by their own dealloc.
static _Atomic long g_rp_made, g_rp_live, g_cp_made, g_cp_live, g_lib_made, g_lib_live, g_lib_bytes, g_twins, g_uirec_live, g_passrec_live;
static const void *kLive = &kLive;
@interface VXLive : NSObject { @public _Atomic long *ctr, *bytes_ctr; long bytes; }
@end
@implementation VXLive
- (void)dealloc { if (ctr) atomic_fetch_sub(ctr, 1); if (bytes_ctr) atomic_fetch_sub(bytes_ctr, bytes); }
@end
static void live_tag(id o, _Atomic long *made, _Atomic long *live, _Atomic long *bytes_ctr, long bytes) {
    if (!o) return;
    atomic_fetch_add(made, 1);
    if (objc_getAssociatedObject(o, kLive)) return;   // (the same object handed back twice: counted once)
    VXLive *t = [VXLive new]; t->ctr = live; t->bytes_ctr = bytes_ctr; t->bytes = bytes;
    atomic_fetch_add(live, 1); if (bytes_ctr) atomic_fetch_add(bytes_ctr, bytes);
    objc_setAssociatedObject(o, kLive, t, OBJC_ASSOCIATION_RETAIN);
}

// ---- libraries ----------------------------------------------------------------------------------------------------
// (each library's bytes hashed (FNV-1a 64): the game's shaders are all vs_main_ / ps_main_ / cs_main_, so a shader
//  is known by its hash, the same in every run and on every device; its functions carry it)
static const void *kHash = &kHash;
typedef id (*fn_imp)(id, SEL, id) __attribute__((ns_returns_retained));
typedef id (*fn_c_imp)(id, SEL, id, id, NSError **) __attribute__((ns_returns_retained));
static fn_imp o_fn; static fn_c_imp o_fn_c;
static const void *kLibData = &kLibData;
static void fn_tag(id l, id f) { if (f && l) { id h = objc_getAssociatedObject(l, kHash); if (h) objc_setAssociatedObject(f, kHash, h, OBJC_ASSOCIATION_RETAIN); id d = objc_getAssociatedObject(l, kLibData); if (d) objc_setAssociatedObject(f, kLibData, d, OBJC_ASSOCIATION_RETAIN); } }
__attribute__((ns_returns_retained)) static id h_fn(id self, SEL s, id n) { id f = o_fn(self, s, n); fn_tag(self, f); return f; }
static const void *kConst;
__attribute__((ns_returns_retained)) static id h_fn_c(id self, SEL s, id n, id cv, NSError **e) { id f = o_fn_c(self, s, n, cv, e); fn_tag(self, f); if (f && cv) objc_setAssociatedObject(f, kConst, @1, OBJC_ASSOCIATION_RETAIN); return f; }
static uint64_t fnv(const void *p, size_t n, uint64_t h) { const uint8_t *b = p; for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 0x100000001b3ULL; } return h; }
static void lib_note(id<MTLLibrary> l, const char *how) {
    if (!l) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class lc = object_getClass(l);
        o_fn = (fn_imp)swap(lc, @selector(newFunctionWithName:), (IMP)h_fn);
        o_fn_c = (fn_c_imp)swap(lc, @selector(newFunctionWithName:constantValues:error:), (IMP)h_fn_c);
    });
    if (!g_f) return;   // (h51: the hooks and hashes always (the UI layers are known by them), the listing only in a dump)
    NSArray<NSString *> *fn = l.functionNames;
    NSString *j = [fn componentsJoinedByString:@","];
    if (j.length > 6000) j = [[j substringToIndex:6000] stringByAppendingString:@"..."];
    NSString *hs = objc_getAssociatedObject(l, kHash);
    out("LIB %p %s h=%s label=%s install=%s n=%lu fns=%s", (__bridge void *)l, how, s8(hs), s8(l.label), s8(l.installName), (unsigned long)fn.count, s8(j));
}
typedef id (*lib_data_imp)(id, SEL, id, NSError **) __attribute__((ns_returns_retained));
static lib_data_imp o_lib_data, o_lib_url;
__attribute__((ns_returns_retained)) static id h_lib_data(id self, SEL s, id d, NSError **e) {
    id l = o_lib_data(self, s, d, e);
    if (l) @autoreleasepool { live_tag(l, &g_lib_made, &g_lib_live, &g_lib_bytes, d ? (long)dispatch_data_get_size((dispatch_data_t)d) : 0); }
    if (l && d) {
        __block uint64_t h = 0xcbf29ce484222325ULL;
        dispatch_data_apply((dispatch_data_t)d, ^bool(dispatch_data_t r, size_t off, const void *b, size_t n) { h = fnv(b, n, h); return true; });
        objc_setAssociatedObject(l, kHash, [NSString stringWithFormat:@"%016llx", (unsigned long long)h], OBJC_ASSOCIATION_RETAIN);
        // Save just the missing contracts observed in the player's recordings.
        // Retaining every game library for later pipeline inspection previously
        // exhausted the headset's memory, so copy these few at creation only.
        const char *capture=getenv("VXMAC_VRIK_CAPTURE");
        if(capture && !strcmp(capture,"1") && (h==UINT64_C(0x1de951b843f562a9) ||
           h==UINT64_C(0x67f2959ad8d545c4) || h==UINT64_C(0x91e8d4f9b84276dd) ||
           h==UINT64_C(0xae33a8cf934a8776) || h==UINT64_C(0xc4992d8906495af2) ||
           h==UINT64_C(0x1005b5b247c5ca54))) {
            const void *bytes=NULL;size_t size=0;dispatch_data_t map=dispatch_data_create_map((dispatch_data_t)d,&bytes,&size);
            if(map && size && size<=2*1024*1024) {
                NSData *saved=[NSData dataWithBytes:bytes length:size];
                NSString *hash=[NSString stringWithFormat:@"%016llx",(unsigned long long)h];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
                    NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
                    NSString *dir=[docs stringByAppendingPathComponent:@"vxvs_routes"];
                    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                    [saved writeToFile:[dir stringByAppendingPathComponent:[hash stringByAppendingString:@".metallib"]] atomically:YES];
                }});
            }
        }
        void vxpipe_lib_seen(uint64_t); vxpipe_lib_seen(h);   // (h64: a library made again from the same bytes)
    }
    lib_note(l, "data"); return l;
}
__attribute__((ns_returns_retained)) static id h_lib_url(id self, SEL s, id u, NSError **e) { id l = o_lib_url(self, s, u, e); if (l) @autoreleasepool { live_tag(l, &g_lib_made, &g_lib_live, NULL, 0); } lib_note(l, [[u lastPathComponent] UTF8String] ?: "url"); return l; }

// ---- reflection ---------------------------------------------------------------------------------------------------
static NSMutableDictionary<NSString *, NSNumber *> *g_structs;   // (signature -> id)
static const char *dt(MTLDataType t) {
    switch (t) {
    case MTLDataTypeStruct: return "struct"; case MTLDataTypeArray: return "array"; case MTLDataTypePointer: return "ptr";
    case MTLDataTypeFloat: return "float"; case MTLDataTypeFloat2: return "float2"; case MTLDataTypeFloat3: return "float3"; case MTLDataTypeFloat4: return "float4";
    case MTLDataTypeFloat2x2: return "float2x2"; case MTLDataTypeFloat3x3: return "float3x3"; case MTLDataTypeFloat4x4: return "float4x4";
    case MTLDataTypeFloat3x4: return "float3x4"; case MTLDataTypeFloat4x3: return "float4x3"; case MTLDataTypeFloat2x4: return "float2x4"; case MTLDataTypeFloat4x2: return "float4x2";
    case MTLDataTypeHalf: return "half"; case MTLDataTypeHalf2: return "half2"; case MTLDataTypeHalf4: return "half4";
    case MTLDataTypeInt: return "int"; case MTLDataTypeInt2: return "int2"; case MTLDataTypeInt4: return "int4";
    case MTLDataTypeUInt: return "uint"; case MTLDataTypeUInt2: return "uint2"; case MTLDataTypeUInt3: return "uint3"; case MTLDataTypeUInt4: return "uint4";
    case MTLDataTypeTexture: return "texture"; case MTLDataTypeSampler: return "sampler"; case MTLDataTypeBool: return "bool";
    case MTLDataTypeULong: return "ulong"; case MTLDataTypeLong: return "long";
    default: return NULL;
    }
}
static void type_str(NSMutableString *o, MTLDataType t, MTLStructType *st, MTLArrayType *at, MTLPointerType *pt, int depth);
static long struct_id(MTLStructType *st, int depth) {
    if (!st) return -1;
    NSMutableString *sig = [NSMutableString string];
    for (MTLStructMember *m in st.members) {
        [sig appendFormat:@"%@@%lu:", m.name, (unsigned long)m.offset];
        type_str(sig, m.dataType, m.dataType == MTLDataTypeStruct ? m.structType : nil, m.dataType == MTLDataTypeArray ? m.arrayType : nil,
                 m.dataType == MTLDataTypePointer ? m.pointerType : nil, depth + 1);
        [sig appendString:@"; "];
    }
    long id_;
    int fresh = 0;
    @synchronized (g_structs) {
        NSNumber *n = g_structs[sig];
        if (n) id_ = n.longValue; else { id_ = (long)g_structs.count; g_structs[sig] = @(id_); fresh = 1; }
    }
    if (fresh) out("STRUCT s%ld { %s}", id_, sig.UTF8String);
    return id_;
}
static void type_str(NSMutableString *o, MTLDataType t, MTLStructType *st, MTLArrayType *at, MTLPointerType *pt, int depth) {
    if (depth > 6) { [o appendString:@"..."]; return; }
    if (st) { [o appendFormat:@"s%ld", struct_id(st, depth)]; return; }
    if (at) {
        [o appendFormat:@"[%lu stride %lu]", (unsigned long)at.arrayLength, (unsigned long)at.stride];
        MTLDataType et = at.elementType;
        type_str(o, et, et == MTLDataTypeStruct ? at.elementStructType : nil, et == MTLDataTypeArray ? at.elementArrayType : nil,
                 et == MTLDataTypePointer ? at.elementPointerType : nil, depth + 1);
        return;
    }
    if (pt) {
        [o appendFormat:@"*(size %lu)", (unsigned long)pt.dataSize];
        MTLDataType et = pt.elementType;
        if (et == MTLDataTypeStruct && pt.elementStructType) [o appendFormat:@"s%ld", struct_id(pt.elementStructType, depth + 1)];
        else if (et == MTLDataTypeArray && pt.elementArrayType) type_str(o, et, nil, pt.elementArrayType, nil, depth + 1);
        else { const char *n = dt(et); [o appendFormat:@"%s", n ?: "?"]; }
        return;
    }
    const char *n = dt(t);
    if (n) [o appendFormat:@"%s", n]; else [o appendFormat:@"t%lu", (unsigned long)t];
}
static void bindings_note(unsigned pid, const char *stage, NSArray<id<MTLBinding>> *bs) {
    for (id<MTLBinding> b in bs) {
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"BIND p%u %s %@ type %lu index %lu used %d", pid, stage, b.name, (unsigned long)b.type, (unsigned long)b.index, b.used];
        if (b.type == MTLBindingTypeBuffer && [b conformsToProtocol:@protocol(MTLBufferBinding)]) {
            id<MTLBufferBinding> bb = (id<MTLBufferBinding>)b;
            [o appendFormat:@" size %lu align %lu data %s", (unsigned long)bb.bufferDataSize, (unsigned long)bb.bufferAlignment, dt(bb.bufferDataType) ?: "?"];
            if (bb.bufferStructType) [o appendFormat:@" s%ld", struct_id(bb.bufferStructType, 0)];
            if (bb.bufferPointerType) { [o appendString:@" "]; type_str(o, MTLDataTypePointer, nil, nil, bb.bufferPointerType, 0); }
        } else if (b.type == MTLBindingTypeTexture && [b conformsToProtocol:@protocol(MTLTextureBinding)]) {
            id<MTLTextureBinding> tb = (id<MTLTextureBinding>)b;
            [o appendFormat:@" textype %lu array %lu access %lu", (unsigned long)tb.textureType, (unsigned long)tb.arrayLength, (unsigned long)tb.access];
        }
        [o appendFormat:@" binding_access %lu", (unsigned long)b.access];
        out("%s", o.UTF8String);
    }
}

// ---- pipelines ----------------------------------------------------------------------------------------------------
static unsigned pid_of(id p) { NSNumber *n = p ? objc_getAssociatedObject(p, kPID) : nil; return n ? n.unsignedIntValue : 0; }
static void fn_str(NSMutableString *o, const char *k, id<MTLFunction> f) {
    if (!f) return;
    [o appendFormat:@" %s=%@", k, f.name];
    NSString *h = objc_getAssociatedObject(f, kHash);
    if (h) [o appendFormat:@"#%@", h];
    if (f.label.length) [o appendFormat:@"[%@]", f.label];
}
void vxmtl_ui_pipe_add(void *p);   // (vxmtl.m)
static int is_ui_vs(id<MTLFunction> f) {   // (h51: the game's UI vertex shaders, by their library's hash (h50's dump))
    // (2.3.2's two; VXMAC_UI_VS=<hash>,<hash>... replaces them for another build (tools/ui_hashes.py finds them in a dump))
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *e = getenv("VXMAC_UI_VS");
        set = e && *e ? [NSSet setWithArray:[@(e) componentsSeparatedByString:@","]] : [NSSet setWithObjects:@"9659c847a5663c68", @"dd2ffa0fee62e619", nil];
        if (e && *e) vxmac_log("Metal: UI vertex shaders from VXMAC_UI_VS: %s", e);
    });
    NSString *h = f ? objc_getAssociatedObject(f, kHash) : nil;
    return h && [set containsObject:h];
}
// (VRIK: a skinned vertex shader reads bone i of a draw at <bone buffer> + isd.x + i * isd.y, isd = its per-instance
//  attribute instance_skinning_data0 (from the shaders' AIR); where that attribute comes from is kept with the pipeline)
static const void *kISD = &kISD;
static const void *kSkinSpan = &kSkinSpan;
static const void *kSkinByteInputs = &kSkinByteInputs;
static const void *kInstanceRebase = &kInstanceRebase;
static const void *kRigidInstance = &kRigidInstance;
static void vrik_pipe_note(id p, MTLRenderPipelineDescriptor *d) {
    id<MTLFunction> f = d.vertexFunction; if (!f || !d.vertexDescriptor) return;
    // Glass/reticle passes can omit skinning while still using the weapon's
    // instance transform. Keep their reflected layout independently of ISD.
    for(MTLVertexAttribute *a in f.vertexAttributes) {
        if(!a.active || ![a.name isEqualToString:@"instance_transform0"])continue;
        MTLVertexAttributeDescriptor *A=d.vertexDescriptor.attributes[a.attributeIndex];
        MTLVertexBufferLayoutDescriptor *L=d.vertexDescriptor.layouts[A.bufferIndex];
        int rows=1;NSUInteger extent=A.offset+16;
        for(MTLVertexAttribute *b in f.vertexAttributes)if(b.active) {
            MTLVertexAttributeDescriptor *B=d.vertexDescriptor.attributes[b.attributeIndex];
            if(B.bufferIndex==A.bufferIndex)extent=MAX(extent,B.offset+16);
            if([b.name isEqualToString:@"instance_transform1"] && B.bufferIndex==A.bufferIndex && B.offset==A.offset+16)rows|=2;
            if([b.name isEqualToString:@"instance_transform2"] && B.bufferIndex==A.bufferIndex && B.offset==A.offset+32)rows|=4;
        }
        if(rows==7 && A.format==MTLVertexFormatFloat4)
            objc_setAssociatedObject(p,kRigidInstance,@[@(A.bufferIndex),@(A.offset),@(L.stride),@(L.stepFunction),@(L.stepRate),@(extent)],OBJC_ASSOCIATION_RETAIN);
        break;
    }
    // The saved AIR for these libraries uses blendindices * skin.y plus
    // skin.x/current or skin.z/history. Bound the copy from the real vertex
    // format, never from the size of the game's 64 MB allocation arena.
    static NSSet *verified; static dispatch_once_t once;
    dispatch_once(&once, ^{ verified = [NSSet setWithArray:@[
        @"57dd4a0ad9a768b4",@"301a84323c240f3f",@"e04ba6ac5d13409c",@"803d926a019878c2",
        @"d3bcb6137ac8450d",@"08d373dc6993b965",@"13c28302862f084d",@"18c14458f235f75e",
        @"60580b19da79bd40",@"d84e7ce97c759ded",@"c247858edee1ee4b",@"716953424d52fabd",
        @"42bb830ec774f0a8",@"bc3ecaeb59a7586d",@"bbeacd2e43a30c66",@"a9263ad2ea54c8bd",
        @"c303351032556f38",@"d3f3e26df4fc32b2",@"9baf4cb3c1c9702c",@"99e000df370eb065",@"a74841c7f953769d",
        // Device contracts: instance_id is unused; current/history matrices
        // use the reflected byte joint indices and instance skinning offsets.
        @"1de951b843f562a9",@"67f2959ad8d545c4",@"91e8d4f9b84276dd",@"ae33a8cf934a8776",@"c4992d8906495af2"]]; });
    int indices = 0, byte_inputs=1, bounded = [verified containsObject:objc_getAssociatedObject(f, kHash)];
    unsigned formats[2] = {0};
    for (MTLVertexAttribute *a in f.vertexAttributes) {
        if (!a.active || ![a.name hasPrefix:@"blendindices"]) continue;
        indices++;
        MTLVertexFormat format = d.vertexDescriptor.attributes[a.attributeIndex].format;
        if (indices <= 2) formats[indices - 1] = (unsigned)format;
        if (format != MTLVertexFormatUChar && format != MTLVertexFormatUChar2 &&
            format != MTLVertexFormatUChar3 && format != MTLVertexFormatUChar4) bounded = byte_inputs = 0;
    }
    if (bounded && indices) objc_setAssociatedObject(p, kSkinSpan, @256, OBJC_ASSOCIATION_RETAIN);
    // A known mesh can also use a material variant with the same byte-sized
    // joint inputs. This permits a bounded palette copy, but never licenses
    // dropping baseInstance: that optimization still needs the saved contract.
    if(byte_inputs && indices>0 && indices<=2)
        objc_setAssociatedObject(p,kSkinByteInputs,@256,OBJC_ASSOCIATION_RETAIN);
    static atomic_uint reports;
    if (indices && atomic_fetch_add(&reports, 1) < 48)
        vxmac_log("VRIK compact shader %s index_inputs=%d formats=%u/%u bounded=%d", [objc_getAssociatedObject(f, kHash) UTF8String] ?: "unknown", indices, formats[0], formats[1], bounded);
    for (MTLVertexAttribute *a in f.vertexAttributes) {
        if (![a.name isEqualToString:@"instance_skinning_data0"] || !a.active) continue;
        MTLVertexAttributeDescriptor *A = d.vertexDescriptor.attributes[a.attributeIndex];
        MTLVertexBufferLayoutDescriptor *L = d.vertexDescriptor.layouts[A.bufferIndex];
        NSInteger it0 = -1;
        for (MTLVertexAttribute *b in f.vertexAttributes) if ([b.name isEqualToString:@"instance_transform0"] && b.active && d.vertexDescriptor.attributes[b.attributeIndex].bufferIndex == A.bufferIndex) it0 = (NSInteger)d.vertexDescriptor.attributes[b.attributeIndex].offset;
        NSUInteger record_size = 0; int one_record = bounded && indices;
        if ((L.stepFunction == MTLVertexStepFunctionPerInstance && L.stepRate != 1) ||
            (L.stepFunction != MTLVertexStepFunctionPerInstance && L.stepFunction != MTLVertexStepFunctionConstant)) one_record = 0;
        for (MTLVertexAttribute *b in f.vertexAttributes) if (b.active) {
            MTLVertexAttributeDescriptor *B = d.vertexDescriptor.attributes[b.attributeIndex];
            if (d.vertexDescriptor.layouts[B.bufferIndex].stepFunction == MTLVertexStepFunctionPerInstance &&
                B.bufferIndex != A.bufferIndex) one_record = 0;
            if (B.bufferIndex == A.bufferIndex) {
                if (B.format != MTLVertexFormatFloat4 && B.format != MTLVertexFormatUInt4) one_record = 0;
                record_size = MAX(record_size, B.offset + 16);
            }
        }
        // The verified AIR does not consume instance_id. With every instanced
        // attribute in this one binding, the draw can use one private record.
        if (one_record) objc_setAssociatedObject(p, kInstanceRebase, @1, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(p, kISD, @[ @(A.bufferIndex), @(A.offset), @(L.stride), @(L.stepFunction), @(L.stepRate), @(A.format), @(it0), @(record_size) ], OBJC_ASSOCIATION_RETAIN);
        return;
    }

}
static void render_note(id p, MTLRenderPipelineDescriptor *d, MTLRenderPipelineReflection *r, const char *how) {
    if (!p) return;
    live_tag(p, &g_rp_made, &g_rp_live, NULL, 0);
    vrik_pipe_note(p, d);
    if (stereo_audit_enabled()) {
        NSMutableArray *formats = [NSMutableArray array];
        for (int i = 0; i < 8; i++) [formats addObject:@(d.colorAttachments[i].pixelFormat)];
        objc_setAssociatedObject(p, kStereoInfo,
            @{@"formats": formats, @"depth": @(d.depthAttachmentPixelFormat),
              @"vertex": d.vertexFunction ? objc_getAssociatedObject(d.vertexFunction, kHash) ?: @"unknown" : @"none",
              @"fragment": d.fragmentFunction ? objc_getAssociatedObject(d.fragmentFunction, kHash) ?: @"unknown" : @"none",
              @"skinned": @(objc_getAssociatedObject(p, kISD) != nil)}, OBJC_ASSOCIATION_RETAIN);
    }
    if (d.vertexFunction) { id ld = objc_getAssociatedObject(d.vertexFunction, kLibData), lh = objc_getAssociatedObject(d.vertexFunction, kHash); if (ld) objc_setAssociatedObject(p, kLibData, ld, OBJC_ASSOCIATION_RETAIN); if (lh) objc_setAssociatedObject(p, kHash, lh, OBJC_ASSOCIATION_RETAIN); }
    if (is_ui_vs(d.vertexFunction)) { vxmtl_ui_pipe_add((__bridge void *)p); wui_twin(p, d, d.fragmentFunction); }
    if (vxprof_on() == 1) { id<MTLFunction> kf = d.fragmentFunction ?: d.vertexFunction; vxprof_pipe_key(p, kf ? objc_getAssociatedObject(kf, kHash) : nil, d.fragmentFunction ? 'f' : 'v', kf.name); }
    if (!g_f) return;
    unsigned id_ = atomic_fetch_add(&g_pipe_n, 1) + 1;
    objc_setAssociatedObject(p, kPID, @(id_), OBJC_ASSOCIATION_RETAIN);
    NSMutableString *o = [NSMutableString stringWithFormat:@"RPIPE p%u %s label=%s", id_, how, s8(d.label)];
    fn_str(o, "v", d.vertexFunction); fn_str(o, "f", d.fragmentFunction);
    for (int i = 0; i < 8; i++) {
        MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
        if (c.pixelFormat == MTLPixelFormatInvalid) continue;
        [o appendFormat:@" c%d=%lu", i, (unsigned long)c.pixelFormat];
        if (c.blendingEnabled) [o appendFormat:@"/blend(%lu,%lu,%lu,%lu op%lu)", (unsigned long)c.sourceRGBBlendFactor, (unsigned long)c.destinationRGBBlendFactor,
                                              (unsigned long)c.sourceAlphaBlendFactor, (unsigned long)c.destinationAlphaBlendFactor, (unsigned long)c.rgbBlendOperation];
        if (c.writeMask != MTLColorWriteMaskAll) [o appendFormat:@"/mask%lu", (unsigned long)c.writeMask];
    }
    if (d.depthAttachmentPixelFormat) [o appendFormat:@" depth=%lu", (unsigned long)d.depthAttachmentPixelFormat];
    if (d.stencilAttachmentPixelFormat) [o appendFormat:@" stencil=%lu", (unsigned long)d.stencilAttachmentPixelFormat];
    if (d.rasterSampleCount > 1) [o appendFormat:@" msaa=%lu", (unsigned long)d.rasterSampleCount];
    for (int i = 0; i < 31 && d.vertexDescriptor; i++) {   // (h58: the vertex layout - stride per buffer, attributes)
        MTLVertexBufferLayoutDescriptor *L = d.vertexDescriptor.layouts[i];
        if (L.stride) [o appendFormat:@" vl%d=%lu", i, (unsigned long)L.stride];
    }
    for (int i = 0; i < 31 && d.vertexDescriptor; i++) {
        MTLVertexAttributeDescriptor *A = d.vertexDescriptor.attributes[i];
        if (A.format) [o appendFormat:@" va%d=f%lu@%lu/b%lu", i, (unsigned long)A.format, (unsigned long)A.offset, (unsigned long)A.bufferIndex];
    }
    if (d.inputPrimitiveTopology) [o appendFormat:@" topo=%lu", (unsigned long)d.inputPrimitiveTopology];
    out("%s", o.UTF8String);
    if (r) { bindings_note(id_, "vert", r.vertexBindings); bindings_note(id_, "frag", r.fragmentBindings); }
}
static void compute_note(id p, id<MTLFunction> f, NSString *label, MTLComputePipelineReflection *r, const char *how) {
    if (p) live_tag(p, &g_cp_made, &g_cp_live, NULL, 0);
    if (p && vxprof_on() == 1) vxprof_pipe_key(p, f ? objc_getAssociatedObject(f, kHash) : nil, 'k', f.name);
    if (!p || !g_f) return;
    unsigned id_ = atomic_fetch_add(&g_pipe_n, 1) + 1;
    objc_setAssociatedObject(p, kPID, @(id_), OBJC_ASSOCIATION_RETAIN);
    NSMutableString *o = [NSMutableString stringWithFormat:@"CPIPE p%u %s label=%s", id_, how, s8(label)];
    fn_str(o, "k", f);
    id<MTLComputePipelineState> cp = p;
    [o appendFormat:@" tg=%lu simd=%lu", (unsigned long)cp.maxTotalThreadsPerThreadgroup, (unsigned long)cp.threadExecutionWidth];
    out("%s", o.UTF8String);
    if (r) bindings_note(id_, "kern", r.bindings);
}
static const MTLPipelineOption kRefl = MTLPipelineOptionBindingInfo | MTLPipelineOptionBufferTypeInfo;

// ---- (h64) the game's render pipeline creations: counted, timed, and (VXMAC_PIPE_ARCHIVE=1) kept across launches --------
// ddgame63d: 7814 render pipelines made in 30 min against ~3700-4100 alive (the game drops and makes them again: ~170 a
// minute after 15 min), each from a new library (libs_made 4406, alive 4). Counted for the mem line: distinct shaders
// (library hashes) and distinct pipelines (a key over the functions' library hash + name and the descriptor's state)
// against repeats (a pipeline made again that was made before in this session), the time each creation took on the
// game's thread (total, the slowest since the last line, those over 16 ms), the game's descriptors that carry binary
// archives and the game's own archive calls (adds, serialize).
// VXMAC_PIPE_ARCHIVE=1 (off by default): our binary archives in Library/Caches/vxmac_pipes/<device>-<OS build>/:
// every render pipeline the game makes is created with them added to its descriptor's binaryArchives (Metal looks a
// pipeline up in them before compiling; a miss compiles as before); a pipeline not yet in them is added on a serial
// background queue (Metal compiles it there again, once), the archive written every 60 s or each 400 adds (a<n>.bin,
// then reopened from the file and a new one begun), the keys added kept in keys.bin, so the next launch counts
// "pa_known" (made again with its key in an archive: an expected hit). Never in the game's folders.
static uint64_t fnv_s(NSString *s, uint64_t h) { const char *c = s.UTF8String; return c ? fnv(c, strlen(c), h) : h; }
static const void *kConst = &kConst;
static uint64_t fn_key(id<MTLFunction> f) {
    if (!f) return 0;
    NSString *h = objc_getAssociatedObject(f, kHash);
    uint64_t k = h ? strtoull(h.UTF8String, NULL, 16) : (uint64_t)(uintptr_t)f;
    if (objc_getAssociatedObject(f, kConst)) k ^= 0x5bd1e995;   // (made with function constants: their values unseen)
    return fnv_s(f.name, k * 0x100000001b3ULL);
}
static uint64_t rp_key(MTLRenderPipelineDescriptor *d) {
    uint64_t v[24 + 8 * 9 + 31 * 6]; unsigned n = 0;
    v[n++] = fn_key(d.vertexFunction); v[n++] = fn_key(d.fragmentFunction);
    v[n++] = d.depthAttachmentPixelFormat; v[n++] = d.stencilAttachmentPixelFormat; v[n++] = d.rasterSampleCount;
    v[n++] = d.alphaToCoverageEnabled | (d.alphaToOneEnabled << 1) | (d.rasterizationEnabled << 2) | (d.supportIndirectCommandBuffers << 3);
    v[n++] = d.inputPrimitiveTopology; v[n++] = d.maxVertexAmplificationCount;
    for (int i = 0; i < 8; i++) {
        MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
        v[n++] = c.pixelFormat; if (!c.pixelFormat) continue;
        v[n++] = c.blendingEnabled; v[n++] = c.writeMask; v[n++] = c.sourceRGBBlendFactor; v[n++] = c.destinationRGBBlendFactor;
        v[n++] = c.sourceAlphaBlendFactor; v[n++] = c.destinationAlphaBlendFactor; v[n++] = c.rgbBlendOperation; v[n++] = c.alphaBlendOperation;
    }
    MTLVertexDescriptor *vd = d.vertexDescriptor;
    for (int i = 0; vd && i < 31; i++) {
        MTLVertexBufferLayoutDescriptor *L = vd.layouts[i]; MTLVertexAttributeDescriptor *A = vd.attributes[i];
        if (L.stride) { v[n++] = 1000 + i; v[n++] = L.stride; v[n++] = L.stepFunction | ((uint64_t)L.stepRate << 8); }
        if (A.format) { v[n++] = 2000 + i; v[n++] = A.format | ((uint64_t)A.bufferIndex << 32); v[n++] = A.offset; }
    }
    return fnv(v, n * sizeof *v, 0xcbf29ce484222325ULL) | 1;
}
// (a set of 64-bit keys, open addressing, 64K at most; returns 1 when the key is new)
typedef struct { uint64_t *k; unsigned cap, n; pthread_mutex_t l; } keyset;
static int ks_add(keyset *s, uint64_t key) {
    int fresh = 0;
    pthread_mutex_lock(&s->l);
    if (!s->k) { s->cap = 1 << 16; s->k = calloc(s->cap, sizeof *s->k); }
    if (s->k && key) {
        unsigned i = (unsigned)(key * 0x9e3779b97f4a7c15ULL >> 48) & (s->cap - 1);
        while (s->k[i] && s->k[i] != key) i = (i + 1) & (s->cap - 1);
        if (!s->k[i] && s->n * 4 < s->cap * 3) { s->k[i] = key; s->n++; fresh = 1; }
    }
    pthread_mutex_unlock(&s->l);
    return fresh;
}
static int ks_has(keyset *s, uint64_t key) {
    int has = 0;
    pthread_mutex_lock(&s->l);
    if (s->k && key) { unsigned i = (unsigned)(key * 0x9e3779b97f4a7c15ULL >> 48) & (s->cap - 1); while (s->k[i] && s->k[i] != key) i = (i + 1) & (s->cap - 1); has = s->k[i] == key; }
    pthread_mutex_unlock(&s->l);
    return has;
}
static keyset g_libset = { .l = PTHREAD_MUTEX_INITIALIZER }, g_rpset = { .l = PTHREAD_MUTEX_INITIALIZER }, g_pa_keys = { .l = PTHREAD_MUTEX_INITIALIZER };
static _Atomic long g_lib_repeat, g_rp_repeat, g_rp_us, g_rp_max_us, g_rp_slow, g_rp_arch, g_garch_adds, g_garch_ser;
static _Atomic long g_pa_adds, g_pa_add_fail, g_pa_add_us, g_pa_saved, g_pa_known, g_pa_used;
void vxpipe_lib_seen(uint64_t h);
void vxpipe_lib_seen(uint64_t h) { if (!ks_add(&g_libset, h)) atomic_fetch_add(&g_lib_repeat, 1); }
static void rp_timed(double t0, MTLRenderPipelineDescriptor *d) {
    long us = (long)((CACurrentMediaTime() - t0) * 1e6);
    atomic_fetch_add(&g_rp_us, us);
    long m = atomic_load(&g_rp_max_us); while (us > m && !atomic_compare_exchange_weak(&g_rp_max_us, &m, us)) {}
    if (us > 16000) atomic_fetch_add(&g_rp_slow, 1);
    if (d.binaryArchives.count) atomic_fetch_add(&g_rp_arch, 1);
}
// our archives
static int g_pa = -1;
static id<MTLBinaryArchive> g_pa_add;      // (this session's, pipelines added to it)
static NSArray *g_pa_read;                 // (earlier files, opened from Library/Caches)
static NSString *g_pa_dir; static int g_pa_next, g_pa_pending; static double g_pa_saved_at;
static dispatch_queue_t g_pa_q; static pthread_mutex_t g_pa_l = PTHREAD_MUTEX_INITIALIZER;
static void pa_keys_save(void) {   // (keys.bin: every key added so far, through a temporary file)
    pthread_mutex_lock(&g_pa_keys.l);
    NSMutableData *m = [NSMutableData data];
    for (unsigned i = 0; g_pa_keys.k && i < g_pa_keys.cap; i++) if (g_pa_keys.k[i]) [m appendBytes:&g_pa_keys.k[i] length:8];
    pthread_mutex_unlock(&g_pa_keys.l);
    [m writeToFile:[g_pa_dir stringByAppendingPathComponent:@"keys.bin"] atomically:YES];
}
static void pa_serialize(id<MTLDevice> dev, const char *why) {   // (on g_pa_q)
    if (!g_pa_add || !g_pa_pending) return;
    NSURL *u = [NSURL fileURLWithPath:[g_pa_dir stringByAppendingPathComponent:[NSString stringWithFormat:@"a%d.bin", g_pa_next]]];
    NSError *err = nil; double t0 = CACurrentMediaTime();
    BOOL ok = [g_pa_add serializeToURL:u error:&err];
    vxmac_log("Metal: pipeline archive %s written (%s): %d pipeline(s), %.0f ms%s%s", u.lastPathComponent.UTF8String, why, g_pa_pending, (CACurrentMediaTime() - t0) * 1e3,
              ok ? "" : " - failed: ", ok ? "" : err.localizedDescription.UTF8String);
    if (!ok) return;
    atomic_fetch_add(&g_pa_saved, g_pa_pending);
    pa_keys_save();
    // (the written one reopened from its file for lookups; a new one begun for the adds)
    MTLBinaryArchiveDescriptor *rd = [MTLBinaryArchiveDescriptor new]; rd.url = u;
    id<MTLBinaryArchive> r = [dev newBinaryArchiveWithDescriptor:rd error:&err];
    id<MTLBinaryArchive> fresh = [dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:&err];
    pthread_mutex_lock(&g_pa_l);
    if (r) g_pa_read = [g_pa_read arrayByAddingObject:r];
    g_pa_add = (g_pa_next < 15) ? fresh : nil;   // (16 files at most: then lookups only)
    g_pa_next++; g_pa_pending = 0; g_pa_saved_at = CACurrentMediaTime();
    pthread_mutex_unlock(&g_pa_l);
}
static void pa_init(id<MTLDevice> dev) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *e = getenv("VXMAC_PIPE_ARCHIVE");
        g_pa = e && atoi(e) > 0;
        if (!g_pa) return;
        char osb[64] = "?"; size_t ol = sizeof osb; sysctlbyname("kern.osversion", osb, &ol, NULL, 0);
        NSString *devn = [[dev.name componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        g_pa_dir = [caches stringByAppendingPathComponent:[NSString stringWithFormat:@"vxmac_pipes/%@-%s", devn, osb]];
        [NSFileManager.defaultManager createDirectoryAtPath:g_pa_dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableArray *rd = [NSMutableArray array]; NSError *err = nil;
        for (int i = 0; i < 16; i++) {
            NSString *f = [g_pa_dir stringByAppendingPathComponent:[NSString stringWithFormat:@"a%d.bin", i]];
            if (![NSFileManager.defaultManager fileExistsAtPath:f]) { g_pa_next = i; break; }
            MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new]; ad.url = [NSURL fileURLWithPath:f];
            id<MTLBinaryArchive> a = [dev newBinaryArchiveWithDescriptor:ad error:&err];
            if (a) [rd addObject:a]; else vxmac_log("Metal: pipeline archive %s not opened: %s", f.lastPathComponent.UTF8String, err.localizedDescription.UTF8String);
            g_pa_next = i + 1;
        }
        NSData *kd = [NSData dataWithContentsOfFile:[g_pa_dir stringByAppendingPathComponent:@"keys.bin"]];
        for (NSUInteger i = 0; i + 8 <= kd.length; i += 8) { uint64_t k; memcpy(&k, (const uint8_t *)kd.bytes + i, 8); ks_add(&g_pa_keys, k); }
        g_pa_read = rd;
        g_pa_add = g_pa_next < 16 ? [dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:&err] : nil;
        g_pa_q = dispatch_queue_create("vxmac.pipe_archive", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        g_pa_saved_at = CACurrentMediaTime();
        vxmac_log("Metal: pipeline archives on (VXMAC_PIPE_ARCHIVE): %lu file(s) from earlier launches, %u key(s), in %s", (unsigned long)rd.count, g_pa_keys.n, g_pa_dir.UTF8String);
    });
}
static MTLRenderPipelineDescriptor *pa_desc(id dev, MTLRenderPipelineDescriptor *d) {   // (the descriptor the game's call is made with)
    if (g_pa < 0) pa_init(dev);
    if (g_pa <= 0 || !d) return d;
    pthread_mutex_lock(&g_pa_l); NSArray *rd = g_pa_read; id ad = g_pa_add; pthread_mutex_unlock(&g_pa_l);
    if (!rd.count && !ad) return d;
    MTLRenderPipelineDescriptor *c = [d copy];
    NSMutableArray *all = [NSMutableArray arrayWithArray:d.binaryArchives ?: @[]];
    [all addObjectsFromArray:rd]; if (ad) [all addObject:ad];
    c.binaryArchives = all;
    atomic_fetch_add(&g_pa_used, 1);
    return c;
}
static void pa_after(id dev, id p, MTLRenderPipelineDescriptor *d) {   // (a pipeline made: added to our archive if new)
    if (g_pa <= 0 || !p || !d) return;
    uint64_t k = rp_key(d);
    if (ks_has(&g_pa_keys, k)) { atomic_fetch_add(&g_pa_known, 1); return; }
    if (!ks_add(&g_pa_keys, k)) return;
    MTLRenderPipelineDescriptor *a = [d copy]; a.binaryArchives = nil;
    dispatch_async(g_pa_q, ^{ @autoreleasepool {
        pthread_mutex_lock(&g_pa_l); id<MTLBinaryArchive> ar = g_pa_add; pthread_mutex_unlock(&g_pa_l);
        if (!ar) return;
        NSError *err = nil; double t0 = CACurrentMediaTime();
        BOOL ok = [ar addRenderPipelineFunctionsWithDescriptor:a error:&err];
        atomic_fetch_add(&g_pa_add_us, (long)((CACurrentMediaTime() - t0) * 1e6));
        if (ok) { atomic_fetch_add(&g_pa_adds, 1); g_pa_pending++; }
        else if (atomic_fetch_add(&g_pa_add_fail, 1) < 5) vxmac_log("Metal: pipeline archive add failed: %s", err.localizedDescription.UTF8String);
        if (g_pa_pending >= 400 || (g_pa_pending && CACurrentMediaTime() - g_pa_saved_at >= 60)) pa_serialize(dev, g_pa_pending >= 400 ? "400 added" : "60 s");
    } });
}
void vxpipe_archive_flush(const char *why) {   // (vxmtl: the app goes to the background)
    if (g_pa <= 0 || !g_pa_q) return;
    id<MTLDevice> dev = [(id<MTLBinaryArchive>)g_pa_add device];
    if (dev) dispatch_async(g_pa_q, ^{ @autoreleasepool { pa_serialize(dev, why); } });
}
// (the game's own archives' calls, counted: its class hooked when vxmtl's newBinaryArchiveWithDescriptor: hook sees one)
typedef BOOL (*arch_add_imp)(id, SEL, id, NSError **); typedef BOOL (*arch_ser_imp)(id, SEL, NSURL *, NSError **);
static arch_add_imp o_aadd, o_acadd; static arch_ser_imp o_aser;
static int ours_arch(id a) { if (a == g_pa_add) return 1; pthread_mutex_lock(&g_pa_l); BOOL r = [g_pa_read containsObject:a]; pthread_mutex_unlock(&g_pa_l); return r; }
static BOOL h_aadd(id self, SEL s, id d, NSError **e) { if (g_pa <= 0 || !ours_arch(self)) atomic_fetch_add(&g_garch_adds, 1); return o_aadd(self, s, d, e); }
static BOOL h_acadd(id self, SEL s, id d, NSError **e) { if (g_pa <= 0 || !ours_arch(self)) atomic_fetch_add(&g_garch_adds, 1); return o_acadd(self, s, d, e); }
static BOOL h_aser(id self, SEL s, NSURL *u, NSError **e) {
    int ours = g_pa > 0 && ours_arch(self);
    BOOL ok = o_aser(self, s, u, e);
    if (!ours && atomic_fetch_add(&g_garch_ser, 1) < 5) vxmac_log("Metal: the game wrote a binary archive: %s -> %d", u.path.UTF8String, ok);
    return ok;
}
void vxpipe_arch_note(id a) {
    if (!a) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class c = object_getClass(a);
        o_aadd = (arch_add_imp)swap(c, @selector(addRenderPipelineFunctionsWithDescriptor:error:), (IMP)h_aadd);
        o_acadd = (arch_add_imp)swap(c, @selector(addComputePipelineFunctionsWithDescriptor:error:), (IMP)h_acadd);
        o_aser = (arch_ser_imp)swap(c, @selector(serializeToURL:error:), (IMP)h_aser);
    });
}

typedef id (*rp_imp)(id, SEL, id, NSError **) __attribute__((ns_returns_retained));
typedef id (*rp_opt_imp)(id, SEL, id, MTLPipelineOption, MTLAutoreleasedRenderPipelineReflection *, NSError **) __attribute__((ns_returns_retained));
typedef void (*rp_cb_imp)(id, SEL, id, MTLNewRenderPipelineStateCompletionHandler);
typedef void (*rp_opt_cb_imp)(id, SEL, id, MTLPipelineOption, MTLNewRenderPipelineStateWithReflectionCompletionHandler);
static rp_imp o_rp; static rp_opt_imp o_rp_opt; static rp_cb_imp o_rp_cb; static rp_opt_cb_imp o_rp_opt_cb;
static void rp_made(id self, id p, MTLRenderPipelineDescriptor *d, double t0) {   // (each game creation, whichever call)
    rp_timed(t0, d);
    if (p && !ks_add(&g_rpset, rp_key(d))) atomic_fetch_add(&g_rp_repeat, 1);
    pa_after(self, p, d);
}
__attribute__((ns_returns_retained)) static id h_rp(id self, SEL s, MTLRenderPipelineDescriptor *d0, NSError **e) {
    double t0 = CACurrentMediaTime(); MTLRenderPipelineDescriptor *d = pa_desc(self, d0);
    if (g_reflect_render && o_rp_opt) {
        MTLAutoreleasedRenderPipelineReflection r = nil;
        id p = o_rp_opt(self, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:), d, kRefl, &r, e);
        rp_made(self, p, d, t0); render_note(p, d0, r, "sync+r"); return p;
    }
    id p = o_rp(self, s, d, e); rp_made(self, p, d, t0); render_note(p, d0, nil, "sync"); return p;
}
__attribute__((ns_returns_retained)) static id h_rp_opt(id self, SEL s, MTLRenderPipelineDescriptor *d0, MTLPipelineOption opt, MTLAutoreleasedRenderPipelineReflection *rr, NSError **e) {
    MTLAutoreleasedRenderPipelineReflection r = nil;
    if (g_reflect_render) opt |= kRefl;
    double t0 = CACurrentMediaTime(); MTLRenderPipelineDescriptor *d = pa_desc(self, d0);
    id p = o_rp_opt(self, s, d, opt, &r, e);
    if (rr) *rr = r;
    rp_made(self, p, d, t0); render_note(p, d0, r, "opt"); return p;
}
static void h_rp_cb(id self, SEL s, MTLRenderPipelineDescriptor *d0, MTLNewRenderPipelineStateCompletionHandler h) {
    MTLRenderPipelineDescriptor *d = [d0 copy];   // (the game may reuse its descriptor before the handler runs)
    MTLRenderPipelineDescriptor *du = pa_desc(self, d); double t0 = CACurrentMediaTime();
    if (g_reflect_render && o_rp_opt_cb) {
        o_rp_opt_cb(self, @selector(newRenderPipelineStateWithDescriptor:options:completionHandler:), du, kRefl,
                    ^(id<MTLRenderPipelineState> p, MTLRenderPipelineReflection *r, NSError *e) { rp_made(self, p, du, t0); render_note(p, d, r, "async+r"); h(p, e); });
        return;
    }
    o_rp_cb(self, s, du, ^(id<MTLRenderPipelineState> p, NSError *e) { rp_made(self, p, du, t0); render_note(p, d, nil, "async"); h(p, e); });
}
static void h_rp_opt_cb(id self, SEL s, MTLRenderPipelineDescriptor *d0, MTLPipelineOption opt, MTLNewRenderPipelineStateWithReflectionCompletionHandler h) {
    MTLRenderPipelineDescriptor *d = [d0 copy];
    MTLRenderPipelineDescriptor *du = pa_desc(self, d); double t0 = CACurrentMediaTime();
    o_rp_opt_cb(self, s, du, opt | (g_reflect_render ? kRefl : 0), ^(id<MTLRenderPipelineState> p, MTLRenderPipelineReflection *r, NSError *e) { rp_made(self, p, du, t0); render_note(p, d, r, "async-opt"); h(p, r, e); });
}

typedef id (*cf_imp)(id, SEL, id, NSError **) __attribute__((ns_returns_retained));
typedef id (*cf_opt_imp)(id, SEL, id, MTLPipelineOption, MTLAutoreleasedComputePipelineReflection *, NSError **) __attribute__((ns_returns_retained));
typedef void (*cf_cb_imp)(id, SEL, id, MTLNewComputePipelineStateCompletionHandler);
typedef void (*cf_opt_cb_imp)(id, SEL, id, MTLPipelineOption, MTLNewComputePipelineStateWithReflectionCompletionHandler);
static cf_imp o_cf; static cf_opt_imp o_cf_opt, o_cd_opt; static cf_cb_imp o_cf_cb; static cf_opt_cb_imp o_cf_opt_cb, o_cd_opt_cb;
__attribute__((ns_returns_retained)) static id h_cf(id self, SEL s, id<MTLFunction> f, NSError **e) {
    if (g_reflect && o_cf_opt) {
        MTLAutoreleasedComputePipelineReflection r = nil;
        id p = o_cf_opt(self, @selector(newComputePipelineStateWithFunction:options:reflection:error:), f, kRefl, &r, e);
        compute_note(p, f, nil, r, "sync+r"); return p;
    }
    id p = o_cf(self, s, f, e); compute_note(p, f, nil, nil, "sync"); return p;
}
__attribute__((ns_returns_retained)) static id h_cf_opt(id self, SEL s, id<MTLFunction> f, MTLPipelineOption opt, MTLAutoreleasedComputePipelineReflection *rr, NSError **e) {
    MTLAutoreleasedComputePipelineReflection r = nil;
    id p = o_cf_opt(self, s, f, opt | (g_reflect ? kRefl : 0), &r, e);
    if (rr) *rr = r;
    compute_note(p, f, nil, r, "opt"); return p;
}
__attribute__((ns_returns_retained)) static id h_cd_opt(id self, SEL s, MTLComputePipelineDescriptor *d, MTLPipelineOption opt, MTLAutoreleasedComputePipelineReflection *rr, NSError **e) {
    MTLAutoreleasedComputePipelineReflection r = nil;
    id p = o_cd_opt(self, s, d, opt | (g_reflect ? kRefl : 0), &r, e);
    if (rr) *rr = r;
    compute_note(p, d.computeFunction, d.label, r, "desc"); return p;
}
static void h_cf_cb(id self, SEL s, id<MTLFunction> f, MTLNewComputePipelineStateCompletionHandler h) {
    if (g_reflect && o_cf_opt_cb) {
        o_cf_opt_cb(self, @selector(newComputePipelineStateWithFunction:options:completionHandler:), f, kRefl,
                    ^(id<MTLComputePipelineState> p, MTLComputePipelineReflection *r, NSError *e) { compute_note(p, f, nil, r, "async+r"); h(p, e); });
        return;
    }
    o_cf_cb(self, s, f, ^(id<MTLComputePipelineState> p, NSError *e) { compute_note(p, f, nil, nil, "async"); h(p, e); });
}
static void h_cf_opt_cb(id self, SEL s, id<MTLFunction> f, MTLPipelineOption opt, MTLNewComputePipelineStateWithReflectionCompletionHandler h) {
    o_cf_opt_cb(self, s, f, opt | (g_reflect ? kRefl : 0), ^(id<MTLComputePipelineState> p, MTLComputePipelineReflection *r, NSError *e) { compute_note(p, f, nil, r, "async-opt"); h(p, r, e); });
}
static void h_cd_opt_cb(id self, SEL s, MTLComputePipelineDescriptor *d0, MTLPipelineOption opt, MTLNewComputePipelineStateWithReflectionCompletionHandler h) {
    MTLComputePipelineDescriptor *d = [d0 copy];
    o_cd_opt_cb(self, s, d0, opt | (g_reflect ? kRefl : 0), ^(id<MTLComputePipelineState> p, MTLComputePipelineReflection *r, NSError *e) { compute_note(p, d.computeFunction, d.label, r, "async-desc"); h(p, r, e); });
}

int vxpipe_on(void) { return g_f != NULL; }
void vxpipe_configure_startup(void) {
    // Metal can load before Documents/-env arguments exist. Re-read configuration at
    // host startup, but never truncate an already-open dump or install a hook twice.
    if (g_f) return;
    const char *path = getenv("VXMAC_PIPE_DUMP");
    if (!path || !*path) return;
    // a relative name goes into the app's Documents (the headset: no writable working directory)
    NSString *ps = @(path);
    if (![ps isAbsolutePath]) ps = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:ps];
    g_f = fopen(ps.fileSystemRepresentation, "w");
    if (!g_f) { vxmac_log("Metal: pipeline dump: cannot open %s", ps.fileSystemRepresentation); return; }
    const char *e;
    e = getenv("VXMAC_PIPE_REFLECT");
    int mode = e ? atoi(e) : 0;
    g_reflect = mode != 0;
    g_reflect_render = mode != 0 && mode != 2;
    e = getenv("VXMAC_PIPE_CONTRACT"); g_contract = e && !strcmp(e, "1");
    if ((e = getenv("VXMAC_PIPE_EVERY"))) g_every = atof(e);
    if ((e = getenv("VXMAC_PIPE_FRAMES"))) g_frames_left = (unsigned)atoi(e);
    g_next_at = CACurrentMediaTime() + g_every;
    out("DUMP start reflect=%d render_reflect=%d every=%.1fs frames=%u device=%s contract=%d", mode, g_reflect_render, g_every, g_frames_left, g_dump_device ? class_getName(g_dump_device) : "-", g_contract);
    install_dump_encoders();
    vxmac_log("Metal: pipeline dump to %s (reflection %s)", path, g_reflect ? (g_reflect_render ? "all" : "compute only") : "off");
}
void vxpipe_install_device(Class dc) {
    static int done; if (done++) return;
    g_dump_device = dc;
    g_structs = [NSMutableDictionary dictionary];
#define S(sel, h, o) (o = (__typeof__(o))swap(dc, @selector(sel), (IMP)h))
    S(newLibraryWithData:error:, h_lib_data, o_lib_data);
    S(newLibraryWithURL:error:, h_lib_url, o_lib_url);
    S(newRenderPipelineStateWithDescriptor:error:, h_rp, o_rp);
    S(newRenderPipelineStateWithDescriptor:options:reflection:error:, h_rp_opt, o_rp_opt);
    S(newRenderPipelineStateWithDescriptor:completionHandler:, h_rp_cb, o_rp_cb);
    S(newRenderPipelineStateWithDescriptor:options:completionHandler:, h_rp_opt_cb, o_rp_opt_cb);
    S(newComputePipelineStateWithFunction:error:, h_cf, o_cf);
    S(newComputePipelineStateWithFunction:options:reflection:error:, h_cf_opt, o_cf_opt);
    S(newComputePipelineStateWithDescriptor:options:reflection:error:, h_cd_opt, o_cd_opt);
    S(newComputePipelineStateWithFunction:completionHandler:, h_cf_cb, o_cf_cb);
    S(newComputePipelineStateWithFunction:options:completionHandler:, h_cf_opt_cb, o_cf_opt_cb);
    S(newComputePipelineStateWithDescriptor:options:completionHandler:, h_cd_opt_cb, o_cd_opt_cb);
#undef S
    vxpipe_configure_startup();
}

// ---- passes (dumped frames only) ----------------------------------------------------------------------------------
@interface VXPassRec : NSObject
@property unsigned n, frame, ntl, ndraw; @property int compute, scene, ui;
@property (strong) NSMutableDictionary *vb; @property (strong) NSString *scissor; @property (strong) id curpipe; @property (strong) NSData *lasttl;
@property (strong) id last0, last1;
@property (strong) NSMutableString *pipes, *reads;
@property (strong) NSMutableSet<NSNumber *> *seen;
@property (strong) NSString *head;
@end
@implementation VXPassRec
- (instancetype)init { if ((self = [super init])) atomic_fetch_add(&g_passrec_live, 1); return self; }
- (void)dealloc { atomic_fetch_sub(&g_passrec_live, 1); }
@end
static unsigned tex_id(id<MTLTexture> t) {
    if (!t) return 0;
    NSNumber *n = objc_getAssociatedObject(t, kTID);
    if (n) return n.unsignedIntValue;
    unsigned id_ = atomic_fetch_add(&g_tex_n, 1) + 1;
    objc_setAssociatedObject(t, kTID, @(id_), OBJC_ASSOCIATION_RETAIN);
    id<MTLTexture> par = t.parentTexture;
    out("TEX t%u %lux%lux%lu type %lu fmt %lu mips %lu usage %lu storage %lu%s label=%s%s", id_, (unsigned long)t.width, (unsigned long)t.height,
        (unsigned long)(t.textureType == MTLTextureType3D ? t.depth : t.arrayLength), (unsigned long)t.textureType, (unsigned long)t.pixelFormat,
        (unsigned long)t.mipmapLevelCount, (unsigned long)t.usage, (unsigned long)t.storageMode, t.iosurface ? " iosurface(drawable?)" : "", s8(t.label),
        par ? [NSString stringWithFormat:@" view-of t%u", tex_id(par)].UTF8String : "");
    return id_;
}
static VXPassRec *rec(id e) { return atomic_load(&g_dump) ? objc_getAssociatedObject(e, kRec) : nil; }
static void rec_read(id e, id t, const char *how) {
    VXPassRec *r = rec(e);
    if (!r || !t || ![t conformsToProtocol:@protocol(MTLTexture)]) return;
    unsigned id_ = tex_id(t);
    if ([r.seen containsObject:@(id_)]) return;
    [r.seen addObject:@(id_)];
    [r.reads appendFormat:@" t%u%s", id_, how];
}
void vxpipe_frame(void) {   // (at each nextDrawable)
    unsigned f = atomic_fetch_add(&g_frame, 1) + 1;   // (h52: counted always - the camera's read once a frame)
    if (!g_f) return;
    if (atomic_load(&g_dump)) { atomic_store(&g_dump, 0); out("FRAME end %u", f - 1); }
    double now = CACurrentMediaTime();
    {   // (h57f: VXMAC_PIPE_START=engage - the dumped frames start when head-look gameplay engages (the presenter drives the
        //  camera), not at the first drawable: menus and loading no longer use them up)
        static int mode = -1, started; static int (*drv)(void);
        if (mode < 0) { const char *e = getenv("VXMAC_PIPE_START"); mode = e && !strcmp(e, "engage"); if (mode) drv = dlsym(RTLD_DEFAULT, "vx_xros_vr_driving"); }
        if (mode && !started) {
            if (drv && drv()) { started = 1; g_next_at = now; out("DUMP engaged at frame %u", f); }
            else return;
        }
    }
    if (g_frames_left && now >= g_next_at) {
        g_frames_left--; g_next_at = now + g_every; out("FRAME begin %u t=%.2f", f, now); atomic_store(&g_dump, 1);
        // (h51: what the presenter had sent so far, for the camera's place in the constants (cbv_find.py))
        static float (*sy)(void), (*sp)(void); static int (*dr)(void), (*ml)(void); static int once;
        if (!once++) { sy = dlsym(RTLD_DEFAULT, "vx_xros_vr_sent_yaw"); sp = dlsym(RTLD_DEFAULT, "vx_xros_vr_sent_pitch"); dr = dlsym(RTLD_DEFAULT, "vx_xros_vr_driving"); ml = dlsym(RTLD_DEFAULT, "vx_game_mouse_look"); }
        out("SENT f%u yaw %.3f pitch %.3f driving %d mouselook %d", f, sy ? sy() : 0.f, sp ? sp() : 0.f, dr ? dr() : -1, ml ? ml() : -1);
    }
}
static void pass_begin(id e, NSString *head, int compute) {
    VXPassRec *r = [VXPassRec new];
    r.n = atomic_fetch_add(&g_pass_n, 1) + 1; r.frame = atomic_load(&g_frame); r.compute = compute;
    r.pipes = [NSMutableString string]; r.reads = [NSMutableString string]; r.seen = [NSMutableSet set]; r.head = head;
    objc_setAssociatedObject(e, kRec, r, OBJC_ASSOCIATION_RETAIN);
}
static const char *load_s(MTLLoadAction a) { return a == MTLLoadActionClear ? "clear" : a == MTLLoadActionLoad ? "load" : "dontcare"; }
static const char *store_s(MTLStoreAction a) { return a == MTLStoreActionStore ? "store" : a == MTLStoreActionDontCare ? "dontcare" : a == MTLStoreActionMultisampleResolve ? "resolve" : "other"; }
static const void *kEncVM = &kEncVM;
@interface VXEncVM : NSObject { @public int vp_fg, draw_idx, pose_bound, pose_instance_dynamic, pose_rebase; NSUInteger pose_instance; id<MTLBuffer> original, vb0; NSUInteger offset, vb0_off, vb0_stride; NSData *bytes; id pipe; __unsafe_unretained id camera_buffer; int had_fg, cam_ok; float cam_m[16], cam_tx, cam_ty; __strong id vbuf[31]; NSUInteger voff[31], vst[31]; NSMutableDictionary *vbytes; }
@end
@implementation VXEncVM
@end
static atomic_uint g_vm_last_frame;
int vxpipe_viewmodel_active(void) {
    unsigned last = atomic_load(&g_vm_last_frame), now = atomic_load(&g_frame);
    return last && now - last <= 2;
}
static const void *kCamPass = &kCamPass;
static _Atomic unsigned g_cframe;
static void cam_pass_note(id e, MTLRenderPassDescriptor *pd,id buffer) {   // (h52: the frame's first G-buffer pass: depth + 3 colour targets or more)
    if (!pd.depthAttachment.texture || !pd.colorAttachments[2].texture || !pd.colorAttachments[1].texture || !pd.colorAttachments[0].texture) return;
    if (vx_frame_camera_read(buffer,NULL,NULL,NULL)) return;
    objc_setAssociatedObject(e, kCamPass, @((int)pd.depthAttachment.loadAction + 1), OBJC_ASSOCIATION_RETAIN);
}
void vxpipe_enc_clear(id e) { objc_setAssociatedObject(e, kCamPass, nil, OBJC_ASSOCIATION_ASSIGN); objc_setAssociatedObject(e, kEncVM, nil, OBJC_ASSOCIATION_ASSIGN); }   // (h64: vxmtl's enc_clear)
void vxpipe_render_begin(id e, MTLRenderPassDescriptor *pd,id buffer) {
    if (e) { cam_pass_note(e, pd,buffer); if (pd.depthAttachment.texture.width >= 1024) {VXEncVM *vm=[VXEncVM new];vm->camera_buffer=buffer;objc_setAssociatedObject(e, kEncVM, vm, OBJC_ASSOCIATION_RETAIN);} }
    if (!g_f || !e || !atomic_load(&g_dump)) return;
    NSMutableString *h = [NSMutableString string];
    for (int i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *c = pd.colorAttachments[i];
        if (!c.texture) continue;
        [h appendFormat:@" c%d=t%u", i, tex_id(c.texture)];
        if (c.slice || c.level) [h appendFormat:@"[s%lu m%lu]", (unsigned long)c.slice, (unsigned long)c.level];
        [h appendFormat:@"/%s/%s", load_s(c.loadAction), store_s(c.storeAction)];
        if (c.resolveTexture) [h appendFormat:@"->t%u", tex_id(c.resolveTexture)];
    }
    if (pd.depthAttachment.texture) [h appendFormat:@" d=t%u/%s/%s", tex_id(pd.depthAttachment.texture), load_s(pd.depthAttachment.loadAction), store_s(pd.depthAttachment.storeAction)];
    if (pd.stencilAttachment.texture && pd.stencilAttachment.texture != pd.depthAttachment.texture) [h appendFormat:@" s=t%u", tex_id(pd.stencilAttachment.texture)];
    if (pd.renderTargetArrayLength > 1) [h appendFormat:@" layers=%lu", (unsigned long)pd.renderTargetArrayLength];
    pass_begin(e, h, 0);
    int nc = 0; for (int i = 0; i < 8; i++) if (pd.colorAttachments[i].texture) nc++;
    static unsigned sframe, sn; unsigned fr = atomic_load(&g_frame); if (fr != sframe) { sframe = fr; sn = 0; }
    if (nc >= 3 && pd.depthAttachment.texture && sn++ < 2) ((VXPassRec *)objc_getAssociatedObject(e, kRec)).scene = 1;   // (h51: a G-buffer pass)
    {   // (h58: the UI layers' passes - frame-sized colour 0 with a mip chain, no depth: per-draw records (UIDRAW))
        id<MTLTexture> t0 = pd.colorAttachments[0].texture;
        if (t0 && !pd.depthAttachment.texture && t0.mipmapLevelCount > 1 && t0.width >= 1024 && pd.colorAttachments[0].level == 0) {
            VXPassRec *r = objc_getAssociatedObject(e, kRec); r.ui = 1; r.vb = [NSMutableDictionary dictionary];
            out("UIPASS #%u f%u c0=t%u %lux%lu fmt %lu", r.n, r.frame, tex_id(t0), (unsigned long)t0.width, (unsigned long)t0.height, (unsigned long)t0.pixelFormat);
        }
    }
}
static void pass_end(id e) {
    VXPassRec *r = objc_getAssociatedObject(e, kRec);
    if (!r) return;
    objc_setAssociatedObject(e, kRec, nil, OBJC_ASSOCIATION_RETAIN);
    NSString *lab = [(id<MTLCommandEncoder>)e label];
    out("%s #%u f%u label=%s%s | pipes%s | reads%s", r.compute ? "CPASS" : "RPASS", r.n, r.frame, s8(lab), r.head.UTF8String,
        r.pipes.length ? r.pipes.UTF8String : " -", r.reads.length ? r.reads.UTF8String : " -");
}
static void cam_commit(const float m[16], float tx, float ty,uint64_t sequence);
void vxpipe_render_end(id e) {
    VXEncVM *vm = e ? objc_getAssociatedObject(e, kEncVM) : nil;
    if (vm && vm->cam_ok && !vm->had_fg) {
        uint64_t sequence=vx_frame_camera_store(vm->camera_buffer,vm->cam_m,vm->cam_tx,vm->cam_ty);
        unsigned fr = atomic_load(&g_frame);
        if (atomic_exchange(&g_cframe, fr) != fr) cam_commit(vm->cam_m, vm->cam_tx, vm->cam_ty,sequence);
    } else if (vm && vm->cam_ok) { static atomic_uint n; if (atomic_fetch_add(&n, 1) < 10) vxmac_log("Metal: a foreground encoder's camera skipped (fov %.1f)", 2 * atanf(vm->cam_tx) * 57.2958f); }
    if (g_f) pass_end(e);
}

// ---- (h51) the scene's constants for the camera (dumped frames only) ------------------------------------------------
// The converted shaders (Metal shader converter) read their root signature from the top-level argument buffer, bound
// at buffer index 2 of the vertex and fragment stages: root constants inline, root CBVs / descriptor tables as GPU
// addresses. Every shared buffer the game makes is kept by its gpuAddress range; in the G-buffer passes of a dumped
// frame (depth + 3 colour targets or more) the first top-level buffers bound are read at the pass's end: "TLAB" (its
// first 256 bytes as 64-bit words), and every word that is an address inside a known buffer: "CBV" (2 KB from it, hex)
// and one level further (8 addresses at most in it, 512 bytes each: descriptor tables). With "SENT" (the yaw / pitch
// the presenter has sent so far) per frame, tools/cbv_find.py finds the view matrix's place offline.
typedef struct { uint64_t a, len; __unsafe_unretained id b; } bufrange;
static bufrange *g_br; static size_t g_nbr, g_cbr;
static pthread_mutex_t g_brl = PTHREAD_MUTEX_INITIALIZER;
static const void *kBR = &kBR;
@interface VXBufGone : NSObject
@property uint64_t a;
@end
@implementation VXBufGone
- (void)dealloc {
    pthread_mutex_lock(&g_brl);
    for (size_t i = 0; i < g_nbr; i++) if (g_br[i].a == _a) { memmove(g_br + i, g_br + i + 1, (g_nbr - i - 1) * sizeof *g_br); g_nbr--; break; }
    pthread_mutex_unlock(&g_brl);
}
@end
void vxpipe_buf_add(id buf) {   // (vxmtl.m's buffer hooks, and the heap's below; h52: always - the camera's constants)
    if (!buf) return;
    id<MTLBuffer> b = buf;
    if (b.storageMode != MTLStorageModeShared || b.length < 64) return;
    uint64_t a = b.gpuAddress; if (!a) return;
    VXBufGone *g = [VXBufGone new]; g.a = a;
    objc_setAssociatedObject(b, kBR, g, OBJC_ASSOCIATION_RETAIN);
    pthread_mutex_lock(&g_brl);
    if (g_nbr == g_cbr) { g_cbr = g_cbr ? g_cbr * 2 : 4096; g_br = realloc(g_br, g_cbr * sizeof *g_br); }
    size_t lo = 0, hi = g_nbr; while (lo < hi) { size_t m = (lo + hi) / 2; if (g_br[m].a < a) lo = m + 1; else hi = m; }
    memmove(g_br + lo + 1, g_br + lo, (g_nbr - lo) * sizeof *g_br);
    g_br[lo].a = a; g_br[lo].len = b.length; g_br[lo].b = b; g_nbr++;
    pthread_mutex_unlock(&g_brl);
}
static const uint8_t *buf_at(uint64_t v, uint64_t *avail, uint64_t *base) {   // (with g_brl held)
    size_t lo = 0, hi = g_nbr; while (lo < hi) { size_t m = (lo + hi) / 2; if (g_br[m].a <= v) lo = m + 1; else hi = m; }
    if (!lo) return NULL;
    bufrange *r = &g_br[lo - 1];
    if (v >= r->a + r->len) return NULL;
    *avail = r->a + r->len - v; *base = r->a;
    return (const uint8_t *)[(id<MTLBuffer>)r->b contents] + (v - r->a);
}
typedef id (*hb_imp)(id, SEL, NSUInteger, NSUInteger) __attribute__((ns_returns_retained));
typedef id (*hbo_imp)(id, SEL, NSUInteger, NSUInteger, NSUInteger) __attribute__((ns_returns_retained));
static hb_imp o_hb; static hbo_imp o_hbo;
__attribute__((ns_returns_retained)) static id h_hb(id self, SEL s, NSUInteger l, NSUInteger o) { id b = o_hb(self, s, l, o); vxpipe_buf_add(b); return b; }
__attribute__((ns_returns_retained)) static id h_hbo(id self, SEL s, NSUInteger l, NSUInteger o, NSUInteger off) { id b = o_hbo(self, s, l, o, off); vxpipe_buf_add(b); return b; }
void vxpipe_install_heap(Class hc) {
    if (!hc) return;
    o_hb = (hb_imp)swap(hc, @selector(newBufferWithLength:options:), (IMP)h_hb);
    o_hbo = (hbo_imp)swap(hc, @selector(newBufferWithLength:options:offset:), (IMP)h_hbo);
}
static void hex_out(const char *head, const uint8_t *p, size_t n) {
    NSMutableString *o = [NSMutableString stringWithCapacity:n * 2 + 128];
    [o appendFormat:@"%s ", head];
    for (size_t i = 0; i < n; i++) [o appendFormat:@"%02x", p[i]];
    out("%s", o.UTF8String);
}
static void tlab_dump(VXPassRec *r, int stage, NSUInteger idx, const uint8_t *p, size_t n, const char *how) {
    if (!p || n < 8) return;
    if (n > 256) n = 256;
    char h[160]; snprintf(h, sizeof h, "TLAB #%u f%u %s idx %lu %s len %zu", r.n, r.frame, stage ? "frag" : "vert", (unsigned long)idx, how, n);
    hex_out(h, p, n);
    pthread_mutex_lock(&g_brl);
    int ncbv = 0;
    for (size_t q = 0; q + 8 <= n && ncbv < 12; q += 8) {
        uint64_t v; memcpy(&v, p + q, 8);
        uint64_t avail, base; const uint8_t *c = buf_at(v, &avail, &base);
        if (!c) continue;
        size_t m = avail < 2048 ? (size_t)avail : 2048;
        snprintf(h, sizeof h, "CBV #%u f%u %s q%zu addr %llx buf+%llx", r.n, r.frame, stage ? "frag" : "vert", q / 8, (unsigned long long)v, (unsigned long long)(v - base));
        hex_out(h, c, m); ncbv++;
        int n2 = 0;
        for (size_t k = 0; k + 8 <= m && k < 512 && n2 < 4; k += 8) {
            uint64_t v2; memcpy(&v2, c + k, 8);
            uint64_t av2, b2; const uint8_t *c2 = buf_at(v2, &av2, &b2);
            if (!c2) continue;
            snprintf(h, sizeof h, "CBV2 #%u f%u %s q%zu at %zu addr %llx", r.n, r.frame, stage ? "frag" : "vert", q / 8, k, (unsigned long long)v2);
            hex_out(h, c2, av2 < 512 ? (size_t)av2 : 512); n2++;
        }
    }
    pthread_mutex_unlock(&g_brl);
}
typedef void (*sb_imp)(id, SEL, id, NSUInteger, NSUInteger);
typedef void (*sbo_imp)(id, SEL, NSUInteger, NSUInteger);
typedef void (*sby_imp)(id, SEL, const void *, NSUInteger, NSUInteger);
static sb_imp o_svb2, o_sfb2; static sbo_imp o_svo2, o_sfo2; static sby_imp o_svy2, o_sfy2;
typedef void (*sbs_imp)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger);
typedef void (*sbos_imp)(id, SEL, NSUInteger, NSUInteger, NSUInteger);
typedef void (*sbys_imp)(id, SEL, const void *, NSUInteger, NSUInteger, NSUInteger);
static sbs_imp o_svbs; static sbos_imp o_svos; static sbys_imp o_svys;
// (h52: the game's camera, found from h51's dump (tools/cbv_find.py): in the G-buffer passes the vertex stage's
//  top-level buffer's first word is a descriptor table; its second entry (byte 24) is the address of the view
//  constants, whose bytes 320-383 are the world-to-view matrix, row-major: rows right, up, forward in the game's world
//  (Z up), translation in the 4th column. Read once a frame from the first G-buffer pass's first binding; kept only
//  when its 3x3 is a rotation. VXMAC_GAME_CAM=0: off)
static pthread_mutex_t g_gcl = PTHREAD_MUTEX_INITIALIZER;
static float g_gcam[16], g_gtan[2]; static uint64_t g_gcam_seq; static unsigned long g_gcam_bad;
// (h56: the projection too - the same constants' bytes 128-191 hold it: 1/tan of the half-angles at [0] and [5]. 2.5.0
//  reset the game's FieldOfView to 80 while the presenter still took 110 from the settings it had read: the frame turned
//  at the wrong rate and stretched on each turn. Now the frame's own tangents, every frame (sprint / zoom change them))
int vxmtl_game_tan(float *tx, float *ty) { pthread_mutex_lock(&g_gcl); int ok = g_gtan[0] > 0; if (ok) { *tx = g_gtan[0]; *ty = g_gtan[1]; } pthread_mutex_unlock(&g_gcl); return ok; }
uint64_t vxmtl_game_camera(float m[16]) { pthread_mutex_lock(&g_gcl); uint64_t q = g_gcam_seq; if (q) memcpy(m, g_gcam, sizeof g_gcam); pthread_mutex_unlock(&g_gcl); return q; }
uint64_t vxmtl_game_camera_for_buffer(void *buffer,float m[16],float *tx,float *ty,int *matched) {
    uint64_t q=vx_frame_camera_read((__bridge id)buffer,m,tx,ty);
    *matched=q!=0;
    if(q)return q;
    // Split command buffers keep the legacy source, read atomically with its
    // projection. Do not claim a frame match when ownership is unavailable.
    pthread_mutex_lock(&g_gcl);q=g_gcam_seq;
    if(q) {memcpy(m,g_gcam,sizeof g_gcam);*tx=g_gtan[0];*ty=g_gtan[1];}
    pthread_mutex_unlock(&g_gcl);return q;
}
static int cam_parse(const uint8_t *tl, size_t n, float m[16], float *otx, float *oty) {
    static int on = -1; if (on < 0) { const char *v = getenv("VXMAC_GAME_CAM"); on = !(v && !strcmp(v, "0")); }
    if (!on || !tl || n < 8) return 0;
    // (the place, 2.3.2's by default: top-level word 0, table byte 24, matrix byte 320; VXMAC_CAM_PATH=<word>:<table
    //  byte>:<matrix byte> for another build (tools/cbv_find.py prints it))
    static unsigned qw = 0, tb = 24, mb = 320; static dispatch_once_t once;
    dispatch_once(&once, ^{ const char *e = getenv("VXMAC_CAM_PATH"); if (e && sscanf(e, "%u:%u:%u", &qw, &tb, &mb) == 3) vxmac_log("Metal: the camera's place from VXMAC_CAM_PATH: %u:%u:%u", qw, tb, mb); });
    if (n < (qw + 1) * 8) return 0;
    int ok = 0; *otx = 0; *oty = 0;
    pthread_mutex_lock(&g_brl);
    uint64_t v; memcpy(&v, tl + qw * 8, 8);
    uint64_t av, base; const uint8_t *d = buf_at(v, &av, &base);
    if (d && av >= tb + 8) {
        uint64_t v2; memcpy(&v2, d + tb, 8);
        const uint8_t *c = buf_at(v2, &av, &base);
        if (c && av >= mb + 64) { memcpy(m, c + mb, 64); ok = 1; }
        if (c && av >= 192 && mb == 320) {   // (2.3.2 / 2.5.0's layout: the projection at byte 128)
            float proj[16]; memcpy(proj, c + 128, sizeof proj);
            static atomic_uint matrices_logged; unsigned mi = atomic_fetch_add(&matrices_logged, 1);
            if (mi < 10) vxmac_log("Metal: camera projection P #%u: [%.4f %.4f %.4f %.4f] [%.4f %.4f %.4f %.4f] [%.4f %.4f %.4f %.4f] [%.4f %.4f %.4f %.4f]", mi + 1, proj[0], proj[1], proj[2], proj[3], proj[4], proj[5], proj[6], proj[7], proj[8], proj[9], proj[10], proj[11], proj[12], proj[13], proj[14], proj[15]);
            (void)vx_frame_camera_projection(proj,otx,oty);
        }
    }
    pthread_mutex_unlock(&g_brl);
    if (ok) {
        for (int r = 0; r < 3 && ok; r++) { float l = m[r*4]*m[r*4] + m[r*4+1]*m[r*4+1] + m[r*4+2]*m[r*4+2]; if (!(fabsf(l - 1) < 0.02f)) ok = 0; }
        if (ok && fabsf(m[0]*m[4] + m[1]*m[5] + m[2]*m[6]) > 0.02f) ok = 0;
        if (ok && fabsf(m[4]*m[8] + m[5]*m[9] + m[6]*m[10]) > 0.02f) ok = 0;
        if (ok && fabsf(m[15] - 1) > 1e-3f) ok = 0;
    }
    if (!ok || !(*otx>0) || !(*oty>0)) { if (g_gcam_bad++ < 10) vxmac_log("Metal: the game's camera: no view with its own perspective projection (%lu)", g_gcam_bad); return 0; }
    return 1;
}
// Publish a view and its own lens together. Never attach the previous world's
// lens to a shadow or foreground view when no world-only pass was captured.
static void cam_commit(const float m[16], float tx, float ty,uint64_t sequence) {
    if (!(tx>0) || !(ty>0)) return;
    if(!sequence)sequence=vx_frame_camera_next();
    pthread_mutex_lock(&g_gcl); memcpy(g_gcam, m, 64); g_gcam_seq=sequence; uint64_t q = g_gcam_seq; float o = g_gtan[0]; if (tx > 0) { g_gtan[0] = tx; g_gtan[1] = ty; } pthread_mutex_unlock(&g_gcl);
    if (q == 1) vxmac_log("Metal: the game's camera read from its view constants (forward %.3f %.3f %.3f)", m[8], m[9], m[10]);
    if (tx > 0 && fabsf(o - tx) > 0.01f) vxmac_log("Metal: the game's projection: horizontal %.1f deg, vertical %.1f deg (f%u)", 2 * atanf(tx) * 57.2958f, 2 * atanf(ty) * 57.2958f, atomic_load(&g_frame));
}
static void vm_mul(float out[16], const float a[16], const float b[16]) {
    float t[16];
    for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) {
        t[r*4+c] = 0; for (int k = 0; k < 4; k++) t[r*4+c] += a[r*4+k] * b[k*4+c];
    }
    memcpy(out, t, sizeof t);
}
// ---- (VRIK step 1) find V's bone palette in the foreground (hands / weapon) draws ----------------------------------
// A skinned draw's vertex stage reads its bones as an array of 3x4 (48 bytes) or 4x4 (64 bytes) matrices whose 3x3 parts
// are rotations. For the first draws of the foreground pass (every 600 frames) every address in the top-level buffer and
// one level below (descriptor tables) is followed, and each run of 4 or more consecutive rotation matrices is logged:
// "VRIK palette draw#d path tl.qW[.tK] +off stride S bones N vb0stride V" - where to write the solved arm bones.
static int vrik_isrot(const float *m, int stride_f) {
    (void)stride_f;
    for (int r = 0; r < 3; r++) { float l = m[r*4]*m[r*4] + m[r*4+1]*m[r*4+1] + m[r*4+2]*m[r*4+2]; if (!isfinite(l) || fabsf(l - 1) > 0.03f) return 0; }
    if (fabsf(m[0]*m[4] + m[1]*m[5] + m[2]*m[6]) > 0.03f) return 0;
    if (fabsf(m[4]*m[8] + m[5]*m[9] + m[6]*m[10]) > 0.03f) return 0;
    for (int r = 0; r < 3; r++) if (!isfinite(m[r*4+3]) || fabsf(m[r*4+3]) > 50) return 0;
    return 1;
}
static int vrik_run(const uint8_t *c, size_t av, size_t o, int st) {
    int nb = 0;
    while (nb < 512 && o + (size_t)(nb + 1) * st <= av && vrik_isrot((const float *)(c + o + (size_t)nb * st), st / 4)) nb++;
    return nb;
}
// (step 1b: the bones live in one big shared buffer the CPU rewrites each frame, the table points at its start; the
//  draw's own place in it must be a root constant. Every 32-bit word of the draw's top-level buffer and tables that is
//  not an address is tried as an offset (x1, x16, x48, x64) into each big buffer the draw points at)
static void vrik_scan(int draw, const uint8_t *tl, size_t n, VXEncVM *vm) {
    static unsigned last_frame; unsigned fr = atomic_load(&g_frame);
    static int ndraw;
    if (draw == 0) { if (fr - last_frame < 600 && last_frame) return; last_frame = fr; ndraw = 0; }
    else if (last_frame != fr || ndraw >= 48) return;
    ndraw++;
    if (n > 512) n = 512;
    pthread_mutex_lock(&g_brl);
    const uint8_t *big[8]; size_t biglen[8]; char bigname[8][24]; int nbig = 0;
    const uint8_t *src[16]; size_t srclen[16]; char srcname[16][16]; int nsrc = 0;
    src[nsrc] = tl; srclen[nsrc] = n; snprintf(srcname[nsrc], 16, "tl"); nsrc++;
    for (size_t q = 0; q + 8 <= n; q += 8) {
        uint64_t v; memcpy(&v, tl + q, 8);
        uint64_t av, base; const uint8_t *c = buf_at(v, &av, &base);
        if (!c) continue;
        size_t m = av < 1024 ? (size_t)av : 1024;
        if (nsrc < 16) { src[nsrc] = c; srclen[nsrc] = m; snprintf(srcname[nsrc], 16, "q%zu", q / 8); nsrc++; }
        for (size_t k = 0; k + 8 <= m; k += 8) {
            uint64_t v2; memcpy(&v2, c + k, 8);
            uint64_t av2, b2; const uint8_t *c2 = buf_at(v2, &av2, &b2);
            if (!c2 || av2 < (1u << 20)) continue;
            int dup = 0; for (int i = 0; i < nbig; i++) if (big[i] == c2) dup = 1;
            if (!dup && nbig < 8) { big[nbig] = c2; biglen[nbig] = (size_t)(av2 > (64u << 20) ? (64u << 20) : av2); snprintf(bigname[nbig], 24, "q%zu.t%zu+%llx", q / 8, k, (unsigned long long)(v2 - b2)); nbig++; }
        }
    }
    char line[1024]; int ln = snprintf(line, sizeof line, "VRIK draw#%d f%u tl:", draw, fr);
    for (size_t q = 0; q + 4 <= 64 && q + 4 <= n; q += 4) { uint32_t w; memcpy(&w, tl + q, 4); ln += snprintf(line + ln, sizeof line - ln, " %08x", w); }
    vxmac_log("%s", line);
    static const int muls[4] = { 1, 16, 48, 64 };
    int hits = 0;
    for (int si = 0; si < nsrc && hits < 12; si++) for (size_t q = 0; q + 4 <= srclen[si] && hits < 12; q += 4) {
        uint32_t w; memcpy(&w, src[si] + q, 4);
        if (w < 1 || w > (64u << 20)) continue;
        for (int bi = 0; bi < nbig; bi++) for (int mi = 0; mi < 4; mi++) {
            size_t o = (size_t)w * muls[mi]; if (o & 15) continue; if (o + 48 * 8 > biglen[bi]) continue;
            for (int st = 48; st <= 64; st += 16) {
                int nb = vrik_run(big[bi], biglen[bi], o, st);
                if (nb >= 8) {
                    const float *f = (const float *)(big[bi] + o);
                    vxmac_log("VRIK bones draw#%d %s+%zu=%u x%d -> %s @%zu stride %d bones %d t0=%.3f %.3f %.3f", draw, srcname[si], q, w, muls[mi], bigname[bi], o, st, nb, f[3], f[7], f[11]);
                    hits++;
                }
            }
        }
    }
    pthread_mutex_unlock(&g_brl);
}
// (VRIK step 2: each skinned foreground draw's bones - the draw's skinning data, the bone buffer the shader reads
//  (top-level +48 -> table entry 2 (24-byte entries) -> its address), the bones' translations. Every 600 frames, the
//  foreground draws of one frame)
// (VRIK step 3: the raw bones of each skinned foreground mesh every 20 frames for 3000 frames - their joints are solved
//  offline from many poses: two bones meeting at a joint j move it alike, S_a j = S_b j)
static void vrik_dump(VXEncVM *vm, NSArray *isd_i, NSUInteger count, NSUInteger bi, id ib, NSUInteger io) {
    static unsigned first, lastf; static NSMutableSet *seen; unsigned fr = atomic_load(&g_frame);
    if (!first) first = fr;
    if (fr - first > 9000 || fr % 30) return;
    if (fr != lastf) { lastf = fr; seen = [NSMutableSet set]; }
    NSString *key = [NSString stringWithFormat:@"%@:%p:%lu:%lu", objc_getAssociatedObject(vm->pipe, kHash), (__bridge void *)ib, (unsigned long)io, (unsigned long)count];
    if ([seen containsObject:key] || seen.count >= 4) return;
    [seen addObject:key];
    NSUInteger bidx = [isd_i[0] unsignedIntegerValue], aoff = [isd_i[1] unsignedIntegerValue], lst = [isd_i[2] unsignedIntegerValue], step = [isd_i[3] unsignedIntegerValue], rate = [isd_i[4] unsignedIntegerValue]; NSInteger it0 = [isd_i[6] integerValue];
    if (lst == MTLBufferLayoutStrideDynamic && bidx < 31) lst = vm->vst[bidx];
    NSUInteger el = step == MTLVertexStepFunctionPerInstance ? bi / (rate ? rate : 1) : 0;
    const uint8_t *ip = NULL; size_t ia = 0;
    NSData *bd = bidx < 31 ? vm->vbytes[@(bidx)] : nil;
    if (bd) { ip = bd.bytes; ia = bd.length; } else if (bidx < 31 && vm->vbuf[bidx]) { id<MTLBuffer> b = vm->vbuf[bidx]; if (b.storageMode == MTLStorageModeShared && vm->voff[bidx] < b.length) { ip = (const uint8_t *)b.contents + vm->voff[bidx]; ia = b.length - vm->voff[bidx]; } }
    if (!ip || el * lst + aoff + 16 > ia) return;
    uint32_t isd[4]; memcpy(isd, ip + el * lst + aoff, 16);
    float itf[12] = {0}; if (it0 >= 0 && el * lst + (size_t)it0 + 48 <= ia) memcpy(itf, ip + el * lst + it0, 48);
    const uint8_t *tl = NULL; size_t n = 0;
    if (vm->bytes) { tl = vm->bytes.bytes; n = vm->bytes.length; }
    else if (vm->original && vm->original.storageMode == MTLStorageModeShared && vm->offset < vm->original.length) { tl = (const uint8_t *)vm->original.contents + vm->offset; n = vm->original.length - vm->offset; }
    if (!tl || n < 56 || isd[1] != 48) return;
    float view[16]; vxmtl_game_camera(view);
    pthread_mutex_lock(&g_brl);
    uint64_t ta; memcpy(&ta, tl + 48, 8); uint64_t av, base; const uint8_t *t = buf_at(ta, &av, &base); const uint8_t *bb = NULL;
    if (t && av >= 72) { uint64_t ba; memcpy(&ba, t + 48, 8); bb = buf_at(ba, &av, &base); }
    int nb = 0, nrot = 0;   // (bones until clearly not a transform - twist / scale bones are not pure rotations)
    if (bb) while (nb < 96 && (uint64_t)isd[0] + (uint64_t)(nb + 1) * 48 <= av) {
        const float *f = (const float *)(bb + isd[0] + (size_t)nb * 48); int ok = 1;
        for (int k = 0; k < 12; k++) if (!isfinite(f[k]) || fabsf(f[k]) > 100) ok = 0;
        float l0 = f[0]*f[0] + f[1]*f[1] + f[2]*f[2]; if (l0 < 0.25f || l0 > 4) ok = 0;
        if (!ok) break;
        if (vrik_isrot(f, 4)) nrot++;
        nb++;
    }
    // (binary, to Documents/vrik_bones.bin - a log line holds 1 KB: 'VRK3', frame, key hash, nb, itf[12], view[16], bones[nb][12])
    if (nb >= 4 && nrot * 2 >= nb) {
        static FILE *bf; static pthread_mutex_t bl = PTHREAD_MUTEX_INITIALIZER; static long written;
        pthread_mutex_lock(&bl);
        if (!bf) { NSString *pth = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"vrik_bones.bin"]; bf = fopen(pth.fileSystemRepresentation, "wb"); }
        if (bf && written < (64L << 20)) {
            uint32_t hdr[4] = { 0x334b5256u, fr, 0, (uint32_t)nb }; uint64_t kh = fnv(key.UTF8String, strlen(key.UTF8String), 0xcbf29ce484222325ULL);
            fwrite(hdr, 4, 2, bf); fwrite(&kh, 8, 1, bf); fwrite(&hdr[3], 4, 1, bf); fwrite(itf, 4, 12, bf); fwrite(view, 4, 16, bf); fwrite(bb + isd[0], 48, nb, bf);
            written += 16 + 4 + 112 + nb * 48; fflush(bf);
        }
        pthread_mutex_unlock(&bl);
    }
    pthread_mutex_unlock(&g_brl);
}
static void vrik_draw_(id e, NSUInteger count, NSUInteger inst, NSUInteger bi, id ib, NSUInteger io);
#include "vrik.inc"   // (V's arms by the player's hands: two-bone IK on the bone buffer)
// (the VRIK diagnostics: off unless VXMAC_VRIK_DIAG=1 - their dumps made the app be killed on the headset)
static int vrik_diag(void) { static int on = -1; if (on < 0) { const char *v = getenv("VXMAC_VRIK_DIAG"); on = v && !strcmp(v, "1"); } return on; }
static void vrik_draw(id e, NSUInteger count, NSUInteger inst, NSUInteger bi, id ib, NSUInteger io, MTLIndexType it) { @autoreleasepool { vrik_apply(e, count, inst, bi, ib, io, it); } if (!vrik_diag()) return; @autoreleasepool { vrik_draw_(e, count, inst, bi, ib, io); } }
static void vrik_draw_(id e, NSUInteger count, NSUInteger inst, NSUInteger bi, id ib, NSUInteger io) {
    VXEncVM *vm = objc_getAssociatedObject(e, kEncVM);
    if (!vm || !vm->vp_fg || !vm->pipe) return;
    @autoreleasepool { NSArray *isd_d = objc_getAssociatedObject(vm->pipe, kISD); if (isd_d) vrik_dump(vm, isd_d, count, bi, ib, io); }
    static unsigned sframe; static int nd; unsigned fr = atomic_load(&g_frame);
    if (fr != sframe) { if (fr - sframe < 600 && sframe) return; sframe = fr; nd = 0; }
    if (nd >= 40) return;
    nd++;
    NSArray *isd_i = objc_getAssociatedObject(vm->pipe, kISD);
    NSString *h = objc_getAssociatedObject(vm->pipe, kHash);
    if (!isd_i) { vxmac_log("VRIK2 f%u draw count %lu inst %lu vs %s: not skinned", fr, (unsigned long)count, (unsigned long)inst, h.UTF8String ?: "-"); return; }
    NSUInteger bidx = [isd_i[0] unsignedIntegerValue], aoff = [isd_i[1] unsignedIntegerValue], lst = [isd_i[2] unsignedIntegerValue], step = [isd_i[3] unsignedIntegerValue], rate = [isd_i[4] unsignedIntegerValue];
    if (lst == MTLBufferLayoutStrideDynamic && bidx < 31) lst = vm->vst[bidx];
    NSUInteger el = step == MTLVertexStepFunctionPerInstance ? bi / (rate ? rate : 1) : 0;
    uint32_t isd[4] = {0}; int have = 0;
    NSData *bd = bidx < 31 ? vm->vbytes[@(bidx)] : nil;
    if (bd) { size_t o = el * lst + aoff; if (o + 16 <= bd.length) { memcpy(isd, (const uint8_t *)bd.bytes + o, 16); have = 1; } }
    else if (bidx < 31 && vm->vbuf[bidx]) { id<MTLBuffer> b = vm->vbuf[bidx]; size_t o = vm->voff[bidx] + el * lst + aoff; if (b.storageMode == MTLStorageModeShared && o + 16 <= b.length) { memcpy(isd, (const uint8_t *)b.contents + o, 16); have = 1; } }
    const uint8_t *tl = NULL; size_t n = 0;
    if (vm->bytes) { tl = vm->bytes.bytes; n = vm->bytes.length; }
    else if (vm->original && vm->original.storageMode == MTLStorageModeShared && vm->offset < vm->original.length) { tl = (const uint8_t *)vm->original.contents + vm->offset; n = vm->original.length - vm->offset; }
    char line[1400]; int ln = snprintf(line, sizeof line, "VRIK2 f%u draw count %lu inst %lu bi %lu vs %s isd buf%lu+%lu stride %lu step %lu: %s %u %u %u %u",
        fr, (unsigned long)count, (unsigned long)inst, (unsigned long)bi, h.UTF8String ?: "-", (unsigned long)bidx, (unsigned long)aoff, (unsigned long)lst, (unsigned long)step, have ? "isd" : "no isd", isd[0], isd[1], isd[2], isd[3]);
    if (have && tl && n >= 56) {
        pthread_mutex_lock(&g_brl);
        uint64_t ta; memcpy(&ta, tl + 48, 8); uint64_t av, base; const uint8_t *t = buf_at(ta, &av, &base);
        if (t && av >= 72) {
            uint64_t ba; memcpy(&ba, t + 48, 8); const uint8_t *bb = buf_at(ba, &av, &base);
            ln += snprintf(line + ln, sizeof line - ln, " bonebuf %llx(+%llx len %llu)", (unsigned long long)ba, (unsigned long long)(ba - base), (unsigned long long)av);
            if (bb && isd[1] >= 48 && isd[1] <= 256) {
                int nb = 0; while (nb < 128 && (uint64_t)isd[0] + (uint64_t)(nb + 1) * isd[1] <= av && vrik_isrot((const float *)(bb + isd[0] + (size_t)nb * isd[1]), 4)) nb++;
                ln += snprintf(line + ln, sizeof line - ln, " rot %d t:", nb);
                for (int i = 0; i < 48 && (uint64_t)isd[0] + (uint64_t)(i + 1) * isd[1] <= av && ln < (int)sizeof line - 40; i++) { const float *f = (const float *)(bb + isd[0] + (size_t)i * isd[1]); ln += snprintf(line + ln, sizeof line - ln, " %d(%.2f,%.2f,%.2f)", i, f[3], f[7], f[11]); }
            }
        } else ln += snprintf(line + ln, sizeof line - ln, " no table");
        pthread_mutex_unlock(&g_brl);
    }
    vxmac_log("%s", line);
}
static int vrik_on(void);
static void vm_bind(id e, VXEncVM *vm) {
    if (!vm || !vm->vp_fg) return;
    if (vrik_on()) return;   // (VRIK moves the arms' bones themselves: no whole-viewmodel offset)
    const uint8_t *tl = NULL; size_t n = 0;
    if (vm->bytes) { tl = vm->bytes.bytes; n = vm->bytes.length; }
    else if (vm->original && vm->original.storageMode == MTLStorageModeShared && vm->offset < vm->original.length) {
        tl = (const uint8_t *)vm->original.contents + vm->offset; n = vm->original.length - vm->offset;
    }
    if (!tl || n < 8) return;
    if (vrik_diag()) vrik_scan(vm->draw_idx, tl, n, vm);
    if (vrik_diag() && vm->pipe) {   // (VRIK: each foreground vertex shader once, to Documents/vxvs/<hash>.metallib - how it reads its bones)
        static NSMutableSet *done; static pthread_mutex_t dl = PTHREAD_MUTEX_INITIALIZER;
        NSString *h = objc_getAssociatedObject(vm->pipe, kHash); id ld = objc_getAssociatedObject(vm->pipe, kLibData);
        pthread_mutex_lock(&dl); if (!done) done = [NSMutableSet set];
        int fresh = h && ![done containsObject:h] && done.count < 64; if (fresh) [done addObject:h]; pthread_mutex_unlock(&dl);
        if (fresh) {
            NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"vxvs"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
            int ok = 0;
            if (ld) { NSData *nd = (NSData *)ld; ok = [nd writeToFile:[dir stringByAppendingPathComponent:[h stringByAppendingString:@".metallib"]] atomically:NO]; }
            vxmac_log("VRIK vs draw#%d f%u hash %s bytes %s", vm->draw_idx, atomic_load(&g_frame), h.UTF8String, ok ? "saved" : (ld ? "write failed" : "not kept"));
        }
    }
    static int (*poses)(float *, float *, float *, float *, int *);
    static int (*pose)(float *, float *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        poses = dlsym(RTLD_DEFAULT, "vx_xros_vr_viewmodel_poses");
        pose = dlsym(RTLD_DEFAULT, "vx_xros_vr_viewmodel_pose");
    });
    float g_delta[3]={0}, g_rot[3]={0}, o_delta[3]={0}, o_rot[3]={0}; int off_ok = 0;
    int side = poses ? poses(g_delta, g_rot, o_delta, o_rot, &off_ok) : (pose ? pose(g_delta, g_rot) : 0);
    if (!side) return;
    int cur_draw = vm->draw_idx++;
    // Keep each draw's argument data alive until the command buffer has completed.
    id<MTLBuffer> shadow = [[e device] newBufferWithLength:16384 options:MTLResourceStorageModeShared];
    if (!shadow) return;
    uint8_t *dst = shadow.contents, *table = dst + 4096, *constants = dst + 8192;
    memset(dst, 0, 16384); memcpy(dst, tl, n < 4096 ? n : 4096);
    uint64_t addr, av, base; memcpy(&addr, tl, 8);
    pthread_mutex_lock(&g_brl);
    const uint8_t *d = buf_at(addr, &av, &base); int ok = d && av >= 32;
    size_t tbl_len = (ok && av < 4096) ? (size_t)av : 4096;
    if (ok) { memcpy(table, d, tbl_len); memcpy(&addr, d + 24, 8); const uint8_t *c = buf_at(addr, &av, &base); ok = c && av >= 512; if (ok) memcpy(constants, c, av < 2048 ? (size_t)av : 2048); }
    pthread_mutex_unlock(&g_brl);
    if (!ok) return;
    float p[16], v[16]; memcpy(p, constants + 128, 64); memcpy(v, constants + 320, 64);
    for (int r = 0; r < 3; r++) { float l = 0; for (int c = 0; c < 3; c++) l += v[r*4+c]*v[r*4+c]; if (!(fabsf(l-1) < .02f)) return; }
    if (fabsf(v[15] - 1) > .001f || !isfinite(p[0]) || fabsf(p[0]) < .2f) return;
    // Single consistent transform across all foreground pass draws so the weapon and hands never vibrate or tear apart across sub-meshes
    const float *delta = g_delta;
    const float *rot = g_rot;
    float piv_side = (float)side;
    float yaw=fmaxf(-.75f,fminf(.75f,rot[0]));
    float pitch=fmaxf(-.55f,fminf(.55f,-rot[1]));
    float roll=fmaxf(-.55f,fminf(.55f,-rot[2]));
    float sh_delta[3]={
        fmaxf(-.24f,fminf(.24f,delta[0])),
        fmaxf(-.20f,fminf(.20f,delta[1])),
        fmaxf(-.16f,fminf(.18f,delta[2]))
    };
    float cy=cosf(yaw), sy=sinf(yaw), cp=cosf(pitch), sp=sinf(pitch), cr=cosf(roll), sr=sinf(roll);
    float ry[16]={cy,0,sy,0, 0,1,0,0, -sy,0,cy,0, 0,0,0,1};
    float rx[16]={1,0,0,0, 0,cp,-sp,0, 0,sp,cp,0, 0,0,0,1};
    float rz[16]={cr,-sr,0,0, sr,cr,0,0, 0,0,1,0, 0,0,0,1};
    float m[16], tmp[16], pivot[3]={piv_side < 0 ? -.14f : .14f, -.16f, .28f};
    vm_mul(tmp, rx, ry); vm_mul(m, rz, tmp);
    for (int r=0;r<3;r++) m[r*4+3] = pivot[r] + sh_delta[r] - (m[r*4]*pivot[0]+m[r*4+1]*pivot[1]+m[r*4+2]*pivot[2]);
    for (int i=0;i<2;i++) { memcpy(v, constants + 320 + i*64, 64); vm_mul(v,m,v); memcpy(constants + 320 + i*64,v,64); vm_mul(tmp,p,v); memcpy(constants + (i ? 448 : 0),tmp,64); memcpy(constants + (i ? 256 : 192),tmp,64); }
    addr = shadow.gpuAddress + 4096; memcpy(dst,&addr,8); addr = shadow.gpuAddress + 8192; memcpy(table+24,&addr,8);
    [e useResource:shadow usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
    o_svb2(e, @selector(setVertexBuffer:offset:atIndex:), shadow, 0, 2);
    atomic_store(&g_vm_last_frame, atomic_load(&g_frame));
    static atomic_uint logged; unsigned lg = atomic_fetch_add(&logged,1);
    if (lg < 12 || (lg % 300 == 0 && (fabsf(delta[0]) > .02f || fabsf(rot[0]) > .08f || fabsf(rot[2]) > .08f)))
        vxmac_log("Metal: 3D viewmodel CBV draw#%d (dx=%.3f dy=%.3f dz=%.3f yaw=%.2f pitch=%.2f roll=%.2f)",cur_draw,delta[0],delta[1],delta[2],yaw,pitch,roll);
}
typedef void (*vm_vp_imp)(id, SEL, MTLViewport);
static vm_vp_imp o_vm_vp;
static void vm_viewport(id e, MTLViewport v) {
    VXEncVM *vm = objc_getAssociatedObject(e,kEncVM); if (!vm) return;
    static atomic_uint logged;
    if (!((fabs(v.znear)<1e-4 && fabs(v.zfar-1)<1e-4) || (fabs(v.znear-1)<1e-4 && fabs(v.zfar)<1e-4)) && atomic_fetch_add(&logged,1)<12)
        vxmac_log("Metal: scene viewport znear=%.4f zfar=%.4f",v.znear,v.zfar);
    int fg = fabs(v.zfar-v.znear)<=.25 && ((v.znear>=.8 && v.znear<=1) || (v.zfar>=.8 && v.zfar<=1 && v.znear>.01));
    if (fg) vm->had_fg = 1;
    if (fg != vm->vp_fg) { vm->vp_fg=fg; if (fg) vm->draw_idx=0; if (vm->original) o_svb2(e,@selector(setVertexBuffer:offset:atIndex:),vm->original,vm->offset,2); else if (vm->bytes) o_svy2(e,@selector(setVertexBytes:length:atIndex:),vm->bytes.bytes,vm->bytes.length,2); vm_bind(e,vm); }
}
typedef void (*vm_vps_imp)(id, SEL, const MTLViewport *, NSUInteger);
static vm_vps_imp o_vm_vps;
static void h_vm_vp(id e, SEL s, MTLViewport v) { o_vm_vp(e, s, v); vm_viewport(e, v); }
static void h_vm_vps(id e, SEL s, const MTLViewport *v, NSUInteger n) { o_vm_vps(e, s, v, n); if (v && n) vm_viewport(e, v[0]); }
static void ui_bind(id e, int stage, id buf, NSUInteger off, NSUInteger idx, const void *bytes, NSUInteger len, int offonly) {
    VXPassRec *r = g_f ? rec(e) : nil;
    if (!r || !r.ui || stage) return;
    NSNumber *k = @(idx);
    if (bytes) { r.vb[k] = @[ [NSData dataWithBytes:bytes length:len < 4096 ? len : 4096], @0 ]; return; }
    if (offonly) { NSArray *o = r.vb[k]; if (o && ![o[0] isKindOfClass:[NSData class]]) r.vb[k] = @[ o[0], @(off) ]; return; }
    if (buf) r.vb[k] = @[ buf, @(off) ];
}
static void tl_note(id e, int stage, id buf, NSUInteger off, NSUInteger idx, const void *bytes, NSUInteger len, int offonly) {
    ui_bind(e, stage, buf, off, idx, bytes, len, offonly);
    if (stage == 0 && idx < 31) {
        VXEncVM *vm = objc_getAssociatedObject(e, kEncVM);
        if (vm) {
            if (bytes) { if (!vm->vbytes) vm->vbytes = [NSMutableDictionary dictionary]; vm->vbytes[@(idx)] = [NSData dataWithBytes:bytes length:len < 65536 ? len : 65536]; vm->vbuf[idx] = nil; vm->voff[idx] = 0; }
            else if (offonly) vm->voff[idx] = off;
            else { vm->vbuf[idx] = buf; vm->voff[idx] = off; [vm->vbytes removeObjectForKey:@(idx)]; }
        }
    }
    if (stage == 0 && idx == 0) {
        VXEncVM *vm = objc_getAssociatedObject(e, kEncVM);
        if (vm) {
            if (offonly) vm->vb0_off = off;
            else if (buf) { vm->vb0 = buf; vm->vb0_off = off; }
        }
    }
    if (idx != 2) return;
    // (the camera first, from the game's own unmodified binding, and never from the foreground (hands / weapon) pass:
    //  its fixed 105 deg projection alternated with the world's 84 deg while aiming - the whole frame shook)
    // (the camera from the game's own unmodified binding. A frame's G-buffer is drawn by several parallel encoders, on
    //  several threads: the one with the hands / weapon (the foreground depth range) carries a projection of its own (105 deg
    //  while the world's is 84 deg aiming) - the frame shook as either won the race. Each encoder's first reading is kept
    //  with it; at its end it is committed only when the encoder drew nothing in the foreground range, once a frame)
    if (stage == 0 && objc_getAssociatedObject(e, kCamPass)) {
        objc_setAssociatedObject(e, kCamPass, nil, OBJC_ASSOCIATION_RETAIN);
        VXEncVM *cvm = objc_getAssociatedObject(e, kEncVM);
        float m[16], tx, ty; int got = 0;
        if (bytes) got = cam_parse(bytes, len, m, &tx, &ty);
        else if (buf && !offonly) { id<MTLBuffer> b = buf; if (b.storageMode == MTLStorageModeShared && off + 8 <= b.length) got = cam_parse((const uint8_t *)b.contents + off, b.length - off, m, &tx, &ty); }
        if (got) {
            if (cvm) { memcpy(cvm->cam_m, m, 64); cvm->cam_tx = tx; cvm->cam_ty = ty; cvm->cam_ok = 1; }
            else if (atomic_exchange(&g_cframe, atomic_load(&g_frame)) != atomic_load(&g_frame)) cam_commit(m, tx, ty,0);
        }
    }
    if (stage == 0) {
        VXEncVM *vm = objc_getAssociatedObject(e, kEncVM);
        if (vm) {
            if (bytes) { vm->bytes = [NSData dataWithBytes:bytes length:len]; vm->original = nil; }
            else if (offonly) { vm->offset = off; }
            else { vm->original = buf; vm->offset = off; vm->bytes = nil; }
            vm_bind(e, vm);
        }
    }
    if (!g_f) return;
    VXPassRec *r = rec(e);
    if (!r || !r.scene) return;
    if (offonly) buf = stage ? r.last1 : r.last0;
    else if (buf) { if (stage) r.last1 = buf; else r.last0 = buf; }
    if (r.ntl >= 2) return;   // (size: 2 a pass, the first 2 G-buffer passes a frame)
    r.ntl++;
    if (bytes) { tlab_dump(r, stage, idx, bytes, len, "bytes"); return; }
    if (!buf) return;
    id<MTLBuffer> b = buf;
    if (b.storageMode != MTLStorageModeShared || off >= b.length) { out("TLAB #%u f%u %s idx 2 private-or-out storage %lu off %lu len %lu", r.n, r.frame, stage ? "frag" : "vert", (unsigned long)b.storageMode, (unsigned long)off, (unsigned long)b.length); return; }
    // (read now: the game writes the argument buffer before it binds it)
    tlab_dump(r, stage, idx, (const uint8_t *)b.contents + off, b.length - off, offonly ? "buffer(offset)" : "buffer");
}
static void h_svb2(id self, SEL s, id b, NSUInteger o, NSUInteger i) { o_svb2(self, s, b, o, i); tl_note(self, 0, b, o, i, NULL, 0, 0); }
static void h_sfb2(id self, SEL s, id b, NSUInteger o, NSUInteger i) { o_sfb2(self, s, b, o, i); tl_note(self, 1, b, o, i, NULL, 0, 0); }
static void h_svo2(id self, SEL s, NSUInteger o, NSUInteger i) { VXEncVM *vm = i == 2 ? objc_getAssociatedObject(self, kEncVM) : nil; if (vm && vm->original) o_svb2(self, @selector(setVertexBuffer:offset:atIndex:), vm->original, o, i); else o_svo2(self, s, o, i); tl_note(self, 0, nil, o, i, NULL, 0, 1); }
static void h_sfo2(id self, SEL s, NSUInteger o, NSUInteger i) { o_sfo2(self, s, o, i); tl_note(self, 1, nil, o, i, NULL, 0, 1); }
static void h_svy2(id self, SEL s, const void *b, NSUInteger l, NSUInteger i) { o_svy2(self, s, b, l, i); tl_note(self, 0, nil, 0, i, b, l, 0); }
static void h_sfy2(id self, SEL s, const void *b, NSUInteger l, NSUInteger i) { o_sfy2(self, s, b, l, i); tl_note(self, 1, nil, 0, i, b, l, 0); }
// (h58: per-draw records in the UI passes of dumped frames - pipeline, primitive, counts, scissor, the vertex buffers'
//  bytes the draw reads (from the binding's offset, its vertex range when indexed), the top-level argument buffer when it
//  changes and the CBVs it points into: tools/ui_draws.py tells world-anchored widgets from screen HUD)
static void hexs(NSMutableString *o, const uint8_t *p, size_t n) { for (size_t i = 0; i < n; i++) [o appendFormat:@"%02x", p[i]]; }
static const uint8_t *buf_bytes(id x, NSUInteger off, size_t *n) {
    if ([x isKindOfClass:[NSData class]]) { *n = [x length]; return [x bytes]; }
    id<MTLBuffer> b = x; if (b.storageMode != MTLStorageModeShared || off >= b.length) { *n = 0; return NULL; }
    *n = b.length - off; return (const uint8_t *)b.contents + off;
}
static void ui_draw(id e, int prim, NSUInteger vstart, NSUInteger count, NSUInteger inst, id ib, NSUInteger ioff, int itype, NSInteger base) {
    VXPassRec *r = g_f ? rec(e) : nil;
    if (!r || !r.ui || r.ndraw >= 300) return;
    r.ndraw++;
    NSMutableString *o = [NSMutableString stringWithFormat:@"UIDRAW #%u f%u d%u pipe=p%u prim=%d vstart=%lu count=%lu inst=%lu base=%ld scissor=%@",
                          r.n, r.frame, r.ndraw, pid_of(r.curpipe), prim, (unsigned long)vstart, (unsigned long)count, (unsigned long)inst, (long)base, r.scissor ?: @"-"];
    uint32_t vmin = (uint32_t)vstart, vmax = (uint32_t)(vstart + (count ? count - 1 : 0));
    if (ib) {
        size_t n; const uint8_t *p = buf_bytes(ib, ioff, &n);
        size_t isz = itype ? 4 : 2, m = count * isz < n ? count * isz : n; if (m > 96 * isz) m = 96 * isz;
        if (p) { [o appendString:@" idx="]; hexs(o, p, m); vmin = UINT32_MAX; vmax = 0;
            for (size_t i = 0; i + isz <= m; i += isz) { uint32_t v = isz == 4 ? *(const uint32_t *)(p + i) : *(const uint16_t *)(p + i); if (v < vmin) vmin = v; if (v > vmax) vmax = v; } }
        vmin += (uint32_t)base; vmax += (uint32_t)base;
    }
    [o appendFormat:@" vrange=%u-%u", vmin, vmax];
    for (NSString *sk in r.vb.allKeys) if ([sk isKindOfClass:[NSString class]]) [o appendFormat:@" stride%@=%@", [sk substringFromIndex:1], r.vb[sk]];
    NSMutableArray *nk = [NSMutableArray array]; for (id k in r.vb.allKeys) if ([k isKindOfClass:[NSNumber class]]) [nk addObject:k];
    for (NSNumber *k in [nk sortedArrayUsingSelector:@selector(compare:)]) {
        if (k.intValue == 2) continue;
        NSArray *b = r.vb[k]; size_t n; const uint8_t *p = buf_bytes(b[0], [b[1] unsignedIntegerValue], &n);
        if (!p) { [o appendFormat:@" vb%d=private", k.intValue]; continue; }
        size_t m = n < 1024 ? n : 1024;
        [o appendFormat:@" vb%d=", k.intValue]; hexs(o, p, m);   // (from the binding's offset; the stride is in the RPIPE vertex layout)
    }
    NSArray *tl = r.vb[@2];
    if (tl) { size_t n; const uint8_t *p = buf_bytes(tl[0], [tl[1] unsignedIntegerValue], &n);
        if (p && n >= 8) { NSData *d = [NSData dataWithBytes:p length:n < 128 ? n : 128];
            if (![d isEqualToData:r.lasttl]) { r.lasttl = d; [o appendString:@" tlab="]; hexs(o, d.bytes, d.length);
                pthread_mutex_lock(&g_brl);
                for (size_t q = 0; q + 8 <= d.length && q < 64; q += 8) { uint64_t v; memcpy(&v, (const uint8_t *)d.bytes + q, 8); uint64_t av, bs; const uint8_t *c = buf_at(v, &av, &bs);
                    if (c) { [o appendFormat:@" cbv%zu=", q / 8]; hexs(o, c, av < 256 ? (size_t)av : 256); } }
                pthread_mutex_unlock(&g_brl); } } }
    out("%s", o.UTF8String);
}
typedef void (*dp_imp)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger);
typedef void (*dpi_imp)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger);
typedef void (*dpib_imp)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger, NSUInteger);
typedef void (*dx_imp)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger);
typedef void (*dxi_imp)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger, NSUInteger);
typedef void (*dxib_imp)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger, NSUInteger, NSInteger, NSUInteger);
typedef void (*sc_imp)(id, SEL, MTLScissorRect);
static dp_imp o_dp; static dpi_imp o_dpi; static dpib_imp o_dpib; static dx_imp o_dx; static dxi_imp o_dxi; static dxib_imp o_dxib; static sc_imp o_sc;
static void h_dp(id s_, SEL s, MTLPrimitiveType t, NSUInteger v, NSUInteger c) { o_dp(s_, s, t, v, c); ui_draw(s_, (int)t, v, c, 1, nil, 0, 0, 0); }
static void h_dpi(id s_, SEL s, MTLPrimitiveType t, NSUInteger v, NSUInteger c, NSUInteger i) { o_dpi(s_, s, t, v, c, i); ui_draw(s_, (int)t, v, c, i, nil, 0, 0, 0); }
static void h_dpib(id s_, SEL s, MTLPrimitiveType t, NSUInteger v, NSUInteger c, NSUInteger i, NSUInteger bi) { o_dpib(s_, s, t, v, c, i, bi); ui_draw(s_, (int)t, v, c, i, nil, 0, 0, 0); }
static void h_dx(id s_, SEL s, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id ib, NSUInteger io) { o_dx(s_, s, t, c, it, ib, io); ui_draw(s_, (int)t, 0, c, 1, ib, io, it == MTLIndexTypeUInt32, 0); }
static void h_dxi(id s_, SEL s, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id ib, NSUInteger io, NSUInteger i) { o_dxi(s_, s, t, c, it, ib, io, i); ui_draw(s_, (int)t, 0, c, i, ib, io, it == MTLIndexTypeUInt32, 0); }
static void h_dxib(id s_, SEL s, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id ib, NSUInteger io, NSUInteger i, NSInteger bv, NSUInteger bi) { o_dxib(s_, s, t, c, it, ib, io, i, bv, bi); ui_draw(s_, (int)t, 0, c, i, ib, io, it == MTLIndexTypeUInt32, bv); }
static void h_sc(id s_, SEL s, MTLScissorRect r) { o_sc(s_, s, r); VXPassRec *p = g_f ? rec(s_) : nil; if (p && p.ui) p.scissor = [NSString stringWithFormat:@"%lu,%lu,%lu,%lu", (unsigned long)r.x, (unsigned long)r.y, (unsigned long)r.width, (unsigned long)r.height]; }
static void install_draws(Class rc) {
#define S(c, sel, h, o) (o = (__typeof__(o))swap(c, @selector(sel), (IMP)h))
    S(rc, drawPrimitives:vertexStart:vertexCount:, h_dp, o_dp);
    S(rc, drawPrimitives:vertexStart:vertexCount:instanceCount:, h_dpi, o_dpi);
    S(rc, drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:, h_dpib, o_dpib);
    S(rc, drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:, h_dx, o_dx);
    S(rc, drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:, h_dxi, o_dxi);
    S(rc, drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:, h_dxib, o_dxib);
    S(rc, setScissorRect:, h_sc, o_sc);
#undef S
}
// (h57g: the converted shaders bind their vertex buffers with a dynamic stride (stride from the call): h58's dump had no
//  vertex data without these)
static void h_svbs(id self, SEL s, id b, NSUInteger o, NSUInteger st, NSUInteger i) { o_svbs(self, s, b, o, st, i); if (i < 31) { VXEncVM *v = objc_getAssociatedObject(self, kEncVM); if (v) v->vst[i] = st; } if (i == 0) { VXEncVM *vm = objc_getAssociatedObject(self, kEncVM); if (vm) vm->vb0_stride = st; } tl_note(self, 0, b, o, i, NULL, 0, 0); VXPassRec *r = g_f ? rec(self) : nil; if (r && r.ui) r.vb[[NSString stringWithFormat:@"s%lu", (unsigned long)i]] = @(st); }
static void h_svos(id self, SEL s, NSUInteger o, NSUInteger st, NSUInteger i) { if (i < 31) { VXEncVM *v = objc_getAssociatedObject(self, kEncVM); if (v) v->vst[i] = st; } VXEncVM *vm = i == 2 ? objc_getAssociatedObject(self, kEncVM) : nil; if (i == 0) { VXEncVM *v0 = objc_getAssociatedObject(self, kEncVM); if (v0) v0->vb0_stride = st; } if (vm && vm->original) o_svbs(self, @selector(setVertexBuffer:offset:attributeStride:atIndex:), vm->original, o, st, i); else o_svos(self, s, o, st, i); tl_note(self, 0, nil, o, i, NULL, 0, 1); VXPassRec *r = g_f ? rec(self) : nil; if (r && r.ui) r.vb[[NSString stringWithFormat:@"s%lu", (unsigned long)i]] = @(st); }
static void h_svys(id self, SEL s, const void *b, NSUInteger l, NSUInteger st, NSUInteger i) { o_svys(self, s, b, l, st, i); tl_note(self, 0, nil, 0, i, b, l, 0); VXPassRec *r = g_f ? rec(self) : nil; if (r && r.ui) r.vb[[NSString stringWithFormat:@"s%lu", (unsigned long)i]] = @(st); }
static void install_tl(Class rc) {
#define S(c, sel, h, o) (o = (__typeof__(o))swap(c, @selector(sel), (IMP)h))
    S(rc, setVertexBuffer:offset:attributeStride:atIndex:, h_svbs, o_svbs);
    S(rc, setVertexBufferOffset:attributeStride:atIndex:, h_svos, o_svos);
    S(rc, setVertexBytes:length:attributeStride:atIndex:, h_svys, o_svys);
    S(rc, setViewport:, h_vm_vp, o_vm_vp);
    S(rc, setViewports:count:, h_vm_vps, o_vm_vps);
    S(rc, setVertexBuffer:offset:atIndex:, h_svb2, o_svb2);
    S(rc, setFragmentBuffer:offset:atIndex:, h_sfb2, o_sfb2);
    S(rc, setVertexBufferOffset:atIndex:, h_svo2, o_svo2);
    S(rc, setFragmentBufferOffset:atIndex:, h_sfo2, o_sfo2);
    S(rc, setVertexBytes:length:atIndex:, h_svy2, o_svy2);
    S(rc, setFragmentBytes:length:atIndex:, h_sfy2, o_sfy2);
#undef S
}


// render encoder
typedef void (*set_imp)(id, SEL, id);
typedef void (*settex_imp)(id, SEL, id, NSUInteger);
typedef void (*settexs_imp)(id, SEL, const id __unsafe_unretained *, NSRange);
typedef void (*use_imp)(id, SEL, id, MTLResourceUsage, MTLRenderStages);
typedef void (*uses_imp)(id, SEL, const id __unsafe_unretained *, NSUInteger, MTLResourceUsage, MTLRenderStages);
typedef void (*cuse_imp)(id, SEL, id, MTLResourceUsage);
typedef void (*cuses_imp)(id, SEL, const id __unsafe_unretained *, NSUInteger, MTLResourceUsage);
typedef void (*end_imp)(id, SEL);
static set_imp o_rps, o_cps; static settex_imp o_rft, o_rvt, o_ctt; static settexs_imp o_rfts, o_ctts;
static use_imp o_ruse; static uses_imp o_ruses; static cuse_imp o_cuse; static cuses_imp o_cuses; static end_imp o_cend;
static void pipe_add(id e, id p) {
    VXPassRec *r = rec(e);
    if (!r) return;
    unsigned id_ = pid_of(p);
    NSString *s = [NSString stringWithFormat:@" p%u", id_];
    if (![r.pipes hasSuffix:s]) [r.pipes appendString:s];   // (consecutive repeats once)
}
void vxmtl_ui_pipe_set(id enc, id p);   // (vxmtl.m)
static int wui_pipe(id e, id p, id *use);
static void h_rps(id self, SEL s, id p) { { VXEncVM *vm = objc_getAssociatedObject(self, kEncVM); if (vm) vm->pipe = p; } id use = p; if (tl_rec_any() && wui_pipe(self, p, &use)) o_rps(self, s, use); else o_rps(self, s, p); vxmtl_ui_pipe_set(self, p); if (vxprof_live) vxprof_pipe(self, p); if (g_f) { pipe_add(self, p); VXPassRec *r = rec(self); if (r && r.ui) r.curpipe = p; } }
static void h_rft(id self, SEL s, id t, NSUInteger i) { o_rft(self, s, t, i); rec_read(self, t, "(f)"); }
static void h_rvt(id self, SEL s, id t, NSUInteger i) { o_rvt(self, s, t, i); rec_read(self, t, "(v)"); }
static void h_rfts(id self, SEL s, const id __unsafe_unretained *t, NSRange r) { o_rfts(self, s, t, r); for (NSUInteger i = 0; t && i < r.length; i++) rec_read(self, t[i], "(f)"); }
static void h_ruse(id self, SEL s, id t, MTLResourceUsage u, MTLRenderStages st) { o_ruse(self, s, t, u, st); rec_read(self, t, (u & MTLResourceUsageWrite) ? "(uw)" : "(u)"); }
static void h_ruses(id self, SEL s, const id __unsafe_unretained *t, NSUInteger n, MTLResourceUsage u, MTLRenderStages st) {
    o_ruses(self, s, t, n, u, st); for (NSUInteger i = 0; t && i < n; i++) rec_read(self, t[i], (u & MTLResourceUsageWrite) ? "(uw)" : "(u)");
}
// compute encoder
static VXPassRec *contract_rec(id e) {
    if (!g_contract || !atomic_load(&g_dump)) return nil;
    if (!objc_getAssociatedObject(e, kRec)) pass_begin(e, @"", 1);
    return rec(e);
}
static void contract_texture(id e, id<MTLTexture> t, NSUInteger i) {
    VXPassRec *r = contract_rec(e);
    if (r) out("CSET #%u f%u texture %lu t%u", r.n, r.frame, (unsigned long)i, tex_id(t));
}
typedef void (*cb_imp)(id, SEL, id, NSUInteger, NSUInteger);
typedef void (*cbs_imp)(id, SEL, const id __unsafe_unretained *, const NSUInteger *, NSRange);
typedef void (*cbo_imp)(id, SEL, NSUInteger, NSUInteger);
typedef void (*cby_imp)(id, SEL, const void *, NSUInteger, NSUInteger);
typedef void (*cd_imp)(id, SEL, MTLSize, MTLSize);
typedef void (*cdi_imp)(id, SEL, id, NSUInteger, MTLSize);
static cb_imp o_ctb; static cbs_imp o_ctbs; static cbo_imp o_ctbo; static cby_imp o_ctby;
static cd_imp o_cdg, o_cdt; static cdi_imp o_cdi;
static void contract_buffer(id e, id<MTLBuffer> b, NSUInteger off, NSUInteger i) {
    VXPassRec *r = contract_rec(e);
    if (r) out("CSET #%u f%u buffer %lu b%p offset %lu length %lu storage %lu", r.n, r.frame, (unsigned long)i, (__bridge void *)b,
               (unsigned long)off, (unsigned long)b.length, (unsigned long)b.storageMode);
}
static void h_ctb(id e, SEL s, id b, NSUInteger off, NSUInteger i) { o_ctb(e,s,b,off,i); contract_buffer(e,b,off,i); }
static void h_ctbs(id e, SEL s, const id __unsafe_unretained *b, const NSUInteger *off, NSRange range) {
    o_ctbs(e,s,b,off,range);
    for (NSUInteger j=0; j<range.length; j++) contract_buffer(e,b ? b[j] : nil,off ? off[j] : 0,range.location+j);
}
static void h_ctbo(id e, SEL s, NSUInteger off, NSUInteger i) {
    o_ctbo(e,s,off,i); VXPassRec *r=contract_rec(e);
    if (r) out("CSET #%u f%u offset %lu %lu",r.n,r.frame,(unsigned long)i,(unsigned long)off);
}
static void h_ctby(id e, SEL s, const void *b, NSUInteger len, NSUInteger i) {
    o_ctby(e,s,b,len,i); VXPassRec *r=contract_rec(e);
    if (r) out("CSET #%u f%u bytes %lu length %lu",r.n,r.frame,(unsigned long)i,(unsigned long)len);
}
static void contract_dispatch(id e, const char *kind, MTLSize n, MTLSize tg) {
    VXPassRec *r=contract_rec(e);
    if (r) out("CDISPATCH #%u f%u p%u %s %lu,%lu,%lu tg %lu,%lu,%lu",r.n,r.frame,pid_of(r.curpipe),kind,
               (unsigned long)n.width,(unsigned long)n.height,(unsigned long)n.depth,
               (unsigned long)tg.width,(unsigned long)tg.height,(unsigned long)tg.depth);
}
static void h_cdg(id e, SEL s, MTLSize n, MTLSize tg) { contract_dispatch(e,"groups",n,tg); o_cdg(e,s,n,tg); }
static void h_cdt(id e, SEL s, MTLSize n, MTLSize tg) { contract_dispatch(e,"threads",n,tg); o_cdt(e,s,n,tg); }
static void h_cdi(id e, SEL s, id b, NSUInteger off, MTLSize tg) {
    // Do not read an indirect argument buffer or wait for the GPU just for metadata.
    contract_dispatch(e,"indirect",MTLSizeMake(0,0,0),tg); o_cdi(e,s,b,off,tg);
}
static void h_cps(id self, SEL s, id p) {
    o_cps(self, s, p);
    if (atomic_load(&g_dump) && !objc_getAssociatedObject(self, kRec)) pass_begin(self, @"", 1);
    pipe_add(self, p);
    VXPassRec *r=contract_rec(self); if (r) r.curpipe=p;
}
static void h_ctt(id self, SEL s, id t, NSUInteger i) { o_ctt(self, s, t, i); contract_texture(self,t,i); rec_read(self, t, ""); }
static void h_ctts(id self, SEL s, const id __unsafe_unretained *t, NSRange r) { o_ctts(self, s, t, r); for (NSUInteger i = 0; i < r.length; i++) { contract_texture(self,t ? t[i] : nil,r.location+i); rec_read(self, t ? t[i] : nil, ""); } }
static void h_cuse(id self, SEL s, id t, MTLResourceUsage u) { o_cuse(self, s, t, u); rec_read(self, t, (u & MTLResourceUsageWrite) ? "(uw)" : "(u)"); }
static void h_cuses(id self, SEL s, const id __unsafe_unretained *t, NSUInteger n, MTLResourceUsage u) {
    o_cuses(self, s, t, n, u); for (NSUInteger i = 0; t && i < n; i++) rec_read(self, t[i], (u & MTLResourceUsageWrite) ? "(uw)" : "(u)");
}
static void h_cend(id self, SEL s) { o_cend(self, s); pass_end(self); }


// ---- (h58) world-anchored UI back into the scene ----------------------------------------------------------------------
// The UI layer pass draws its world widgets (markers over people, quest targets: CPU-projected quads) first, then the
// screen HUD, which begins with a draw of the pipeline whose fragment shader is d12f3abf4ca01088 (h59's dump: draws
// before it moved with a turn in 29 of 49 frame pairs, after it 25 of 1008). While the HUD layer is captured, the draws
// before that separator are made with a twin of their pipeline that writes nothing (so the HUD texture has none of
// them), and are recorded with every binding they had; after the layer is captured and cleared they are drawn again
// into it (vxpipe_ui_replay), so the game composites them into its frame and they are warped with the world - on the
// person again. VXMAC_WORLD_UI=0: off (all UI on the HUD panel, as before).
static const void *kTwin = &kTwin, *kSep = &kSep, *kUIRec = &kUIRec;
static int g_wui = -1;
@interface VXUIRec : NSObject
@property NSMutableDictionary *vb, *fb, *vt, *ft, *fs; @property NSMutableArray *res, *heaps, *draws;
@property NSValue *scissor, *viewport; @property id pipe; @property int segment, masking, npre; @property void *tex;
@end
@implementation VXUIRec
- (instancetype)init { if ((self = [super init])) atomic_fetch_add(&g_uirec_live, 1); return self; }
- (void)dealloc { atomic_fetch_sub(&g_uirec_live, 1); }
@end
static void wui_twin(id p, MTLRenderPipelineDescriptor *d, id<MTLFunction> fs) {   // (from render_note, UI pipelines only)
    if (g_wui < 0) { const char *e = getenv("VXMAC_WORLD_UI"); g_wui = !(e && !strcmp(e, "0")); }
    if (!g_wui || !p || !d) return;
    NSString *h = fs ? objc_getAssociatedObject(fs, kHash) : nil;
    if ([h isEqualToString:@"d12f3abf4ca01088"]) objc_setAssociatedObject(p, kSep, @1, OBJC_ASSOCIATION_RETAIN);
    MTLRenderPipelineDescriptor *t = [d copy];
    for (int i = 0; i < 8; i++) if (t.colorAttachments[i].pixelFormat) t.colorAttachments[i].writeMask = MTLColorWriteMaskNone;
    NSError *err = nil;
    id<MTLRenderPipelineState> tw = o_rp ? o_rp([(id<MTLRenderPipelineState>)p device], @selector(newRenderPipelineStateWithDescriptor:error:), t, &err)
                                         : [[(id<MTLRenderPipelineState>)p device] newRenderPipelineStateWithDescriptor:t error:&err];
    if (tw) { objc_setAssociatedObject(p, kTwin, tw, OBJC_ASSOCIATION_RETAIN); atomic_fetch_add(&g_twins, 1); }
}
// (h60b: split only where it held last time - per layer texture, its last pass reached the HUD's separator with at most 8
//  draws before it (markers: 1-2). A weapon window / wheel drawn before the separator, or a pass without it, turns the
//  split off for that layer's next pass (one frame at most shown wrong, then all of it on the HUD panel); counted in
//  stats (world_ui_*))
static void *g_wui_tex[8]; static int g_wui_ok[8];
static _Atomic unsigned long g_wui_passes, g_wui_split, g_wui_draws, g_wui_refused;
static int wui_ok_for(void *t, int set, int v) {
    for (int i = 0; i < 8; i++) if (g_wui_tex[i] == t) { if (set) g_wui_ok[i] = v; return g_wui_ok[i]; }
    if (!set) return 0;   // (a layer not seen yet: not split on its first pass)
    static int nx; int k = nx++ % 8; g_wui_tex[k] = t; g_wui_ok[k] = v; return v;
}
void vxpipe_ui_stats(char *out, unsigned n) {
    snprintf(out, n, "\"world_ui_passes\":%lu,\"world_ui_split\":%lu,\"world_ui_draws\":%lu,\"world_ui_refused\":%lu",
             atomic_exchange(&g_wui_passes, 0), atomic_exchange(&g_wui_split, 0), atomic_exchange(&g_wui_draws, 0), atomic_exchange(&g_wui_refused, 0));
}
void vxpipe_ui_rec_begin(id e, int masking, void *tex) {   // (vxmtl: a UI layer pass begins on this thread)
    if (g_wui < 0) { const char *v = getenv("VXMAC_WORLD_UI"); g_wui = !(v && !strcmp(v, "0")); }
    if (!g_wui || !e) return;
    masking = masking && wui_ok_for(tex, 0, 0);
    VXUIRec *r = [VXUIRec new];
    r.vb = [NSMutableDictionary dictionary]; r.fb = [NSMutableDictionary dictionary]; r.vt = [NSMutableDictionary dictionary];
    r.ft = [NSMutableDictionary dictionary]; r.fs = [NSMutableDictionary dictionary];
    r.res = [NSMutableArray array]; r.heaps = [NSMutableArray array]; r.draws = [NSMutableArray array]; r.masking = masking; r.tex = tex;
    objc_setAssociatedObject(e, kUIRec, r, OBJC_ASSOCIATION_RETAIN);
    tl_rec = (__bridge void *)e;
}
static VXUIRec *wrec(id e) { return (tl_rec == (__bridge void *)e) ? objc_getAssociatedObject(e, kUIRec) : nil; }
static int wui_pipe(id e, id p, id *use) {   // (h_rps: the pipeline to set instead, while the world segment is masked)
    VXUIRec *r = wrec(e);
    if (!r || r.segment) return 0;
    if (objc_getAssociatedObject(p, kSep)) { r.segment = 1; return 0; }
    r.pipe = p;
    id tw = r.masking ? objc_getAssociatedObject(p, kTwin) : nil;
    if (tw) { *use = tw; return 1; }
    return 0;
}
static void wbind(NSMutableDictionary *t, NSUInteger i, id buf, NSUInteger off, NSUInteger stride, const void *bytes, NSUInteger len, int offonly) {
    NSNumber *k = @(i);
    if (bytes) { t[k] = @[ [NSData dataWithBytes:bytes length:len], @0, @(stride) ]; return; }
    if (offonly) { NSArray *o = t[k]; if (o && ![o[0] isKindOfClass:[NSData class]]) t[k] = @[ o[0], @(off), @(stride ? stride : [o[2] unsignedIntegerValue]) ]; return; }
    if (buf) t[k] = @[ buf, @(off), @(stride) ]; else [t removeObjectForKey:k];
}
static void vrik_draw(id e, NSUInteger count, NSUInteger inst, NSUInteger bi, id ib, NSUInteger io, MTLIndexType it);
static void stereo_audit_draw(id e, NSUInteger count, NSUInteger instances) {
    if (!stereo_audit_enabled()) return;
    VXEncVM *vm = objc_getAssociatedObject(e, kEncVM);
    if (!vm || !vm->vp_fg || !vm->pipe) return;
    NSDictionary *info = objc_getAssociatedObject(vm->pipe, kStereoInfo);
    if (!info) return;
    unsigned targets = 0;
    for (NSNumber *format in info[@"formats"]) if (format.unsignedIntegerValue != MTLPixelFormatInvalid) targets++;
    atomic_fetch_add(&g_stereo_draws, 1);
    atomic_fetch_add(&g_stereo_indices, count * instances);
    if (targets > 1) atomic_fetch_add(&g_stereo_multi_target, 1);
    else if (targets == 1) atomic_fetch_add(&g_stereo_single_target, 1);
    else atomic_fetch_add(&g_stereo_depth_only, 1);
    if (!objc_getAssociatedObject(vm->pipe, kStereoSeen)) {
        pthread_mutex_lock(&g_fl);
        int first = objc_getAssociatedObject(vm->pipe, kStereoSeen) == nil;
        if (first) objc_setAssociatedObject(vm->pipe, kStereoSeen, @1, OBJC_ASSOCIATION_RETAIN);
        pthread_mutex_unlock(&g_fl);
        static atomic_uint logged;
        if (first && atomic_fetch_add(&logged, 1) < 32)
            vxmac_log("Stereo foreground: vertex=%s fragment=%s colors=%s depth=%lu skinned=%d indices=%lu instances=%lu",
                      [info[@"vertex"] UTF8String], [info[@"fragment"] UTF8String],
                      [[info[@"formats"] componentsJoinedByString:@","] UTF8String],
                      [info[@"depth"] unsignedLongValue], [info[@"skinned"] boolValue],
                      (unsigned long)count, (unsigned long)instances);
    }
}
static void wdraw(id e, int kind, NSUInteger a0, NSUInteger a1, NSUInteger a2, NSUInteger inst, id ib, NSUInteger io, NSInteger base, NSUInteger bi) {
    VXUIRec *r = wrec(e);
    if (r && !r.segment) r.npre++;
    if (!r || r.segment || !r.pipe || r.draws.count >= 64) return;
    if (!r.masking || !objc_getAssociatedObject(r.pipe, kTwin)) return;   // (not masked: drawn into the layer as it is, not drawn again)
    [r.draws addObject:@{ @"pipe": r.pipe, @"vb": [r.vb copy], @"fb": [r.fb copy], @"vt": [r.vt copy], @"ft": [r.ft copy], @"fs": [r.fs copy],
                          @"res": [r.res copy], @"heaps": [r.heaps copy], @"sc": r.scissor ?: [NSNull null], @"vp": r.viewport ?: [NSNull null],
                          @"k": @[ @(kind), @(a0), @(a1), @(a2), @(inst), ib ?: [NSNull null], @(io), @(base), @(bi) ] }];
}
static NSUInteger wprepare(id e, NSUInteger count, NSUInteger instances, NSUInteger bi, id indices, NSUInteger offset, MTLIndexType type) {
    vrik_draw(e, count, instances, bi, indices, offset, type);
    stereo_audit_draw(e, count, instances);
    VXEncVM *vm = objc_getAssociatedObject(e, kEncVM);
    return vm && vm->pose_bound && vm->pose_rebase ? 0 : bi;
}
int vxpipe_ui_replay(id enc, id cbo, id tex, NSUInteger slice) {   // (vxmtl's ui_end, after the capture and the clear)
    VXUIRec *r = objc_getAssociatedObject(enc, kUIRec);
    if (tl_rec == (__bridge void *)enc) tl_rec = NULL;
    if (!r) return 0;
    objc_setAssociatedObject(enc, kUIRec, nil, OBJC_ASSOCIATION_RETAIN);
    int ok = r.segment && r.npre <= 8;
    wui_ok_for(r.tex, 1, ok);
    g_wui_passes++; if (r.masking) g_wui_split++;
    if (!ok && r.masking) { g_wui_refused++; vxmac_log("Metal: world UI split off for this layer: %d draw(s) before the HUD's separator%s (a window, not markers)", r.npre, r.segment ? "" : ", none reached"); }
    if (!r.draws.count) return 0;
    g_wui_draws += r.draws.count;
    id<MTLCommandBuffer> cb = cbo; id<MTLTexture> t = tex;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].slice = slice; rp.colorAttachments[0].loadAction = MTLLoadActionLoad; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    if (!re) return 0;
    for (NSDictionary *d in r.draws) {
        [re setRenderPipelineState:d[@"pipe"]];
        for (NSNumber *k in d[@"vb"]) { NSArray *b = d[@"vb"][k]; NSUInteger st = [b[2] unsignedIntegerValue];
            if ([b[0] isKindOfClass:[NSData class]]) { if (st) [re setVertexBytes:[b[0] bytes] length:[b[0] length] attributeStride:st atIndex:k.unsignedIntegerValue]; else [re setVertexBytes:[b[0] bytes] length:[b[0] length] atIndex:k.unsignedIntegerValue]; }
            else if (st) [re setVertexBuffer:b[0] offset:[b[1] unsignedIntegerValue] attributeStride:st atIndex:k.unsignedIntegerValue];
            else [re setVertexBuffer:b[0] offset:[b[1] unsignedIntegerValue] atIndex:k.unsignedIntegerValue]; }
        for (NSNumber *k in d[@"fb"]) { NSArray *b = d[@"fb"][k];
            if ([b[0] isKindOfClass:[NSData class]]) [re setFragmentBytes:[b[0] bytes] length:[b[0] length] atIndex:k.unsignedIntegerValue];
            else [re setFragmentBuffer:b[0] offset:[b[1] unsignedIntegerValue] atIndex:k.unsignedIntegerValue]; }
        for (NSNumber *k in d[@"vt"]) [re setVertexTexture:d[@"vt"][k] atIndex:k.unsignedIntegerValue];
        for (NSNumber *k in d[@"ft"]) [re setFragmentTexture:d[@"ft"][k] atIndex:k.unsignedIntegerValue];
        for (NSNumber *k in d[@"fs"]) [re setFragmentSamplerState:d[@"fs"][k] atIndex:k.unsignedIntegerValue];
        for (NSArray *u in d[@"res"]) [re useResource:u[0] usage:[u[1] unsignedIntegerValue] stages:[u[2] unsignedIntegerValue]];
        for (NSArray *u in d[@"heaps"]) [re useHeap:u[0] stages:[u[1] unsignedIntegerValue]];
        if (d[@"sc"] != [NSNull null]) { MTLScissorRect sr; [(NSValue *)d[@"sc"] getValue:&sr size:sizeof sr]; [re setScissorRect:sr]; }
        if (d[@"vp"] != [NSNull null]) { MTLViewport vv; [(NSValue *)d[@"vp"] getValue:&vv size:sizeof vv]; [re setViewport:vv]; }
        NSArray *k = d[@"k"]; int kind = [k[0] intValue];
        MTLPrimitiveType pt = (MTLPrimitiveType)[k[1] unsignedIntegerValue];
        if (kind == 0) [re drawPrimitives:pt vertexStart:[k[2] unsignedIntegerValue] vertexCount:[k[3] unsignedIntegerValue] instanceCount:[k[4] unsignedIntegerValue] baseInstance:[k[8] unsignedIntegerValue]];
        else [re drawIndexedPrimitives:pt indexCount:[k[2] unsignedIntegerValue] indexType:(MTLIndexType)[k[3] unsignedIntegerValue] indexBuffer:k[5] indexBufferOffset:[k[6] unsignedIntegerValue]
                         instanceCount:[k[4] unsignedIntegerValue] baseVertex:[k[7] integerValue] baseInstance:[k[8] unsignedIntegerValue]];
    }
    [re endEncoding];
    static int told; if (told++ < 3) vxmac_log("Metal: world UI drawn again into the layer: %lu draw(s) (out of the HUD panel, warped with the scene)", (unsigned long)r.draws.count);
    return (int)r.draws.count;
}
// the recording hooks (always installed; a call costs one thread-local compare unless it is the UI pass being recorded)
typedef void (*w_b_imp)(id, SEL, id, NSUInteger, NSUInteger);
typedef void (*w_bo_imp)(id, SEL, NSUInteger, NSUInteger);
typedef void (*w_by_imp)(id, SEL, const void *, NSUInteger, NSUInteger);
typedef void (*w_bs_imp)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger);
typedef void (*w_bos_imp)(id, SEL, NSUInteger, NSUInteger, NSUInteger);
typedef void (*w_bys_imp)(id, SEL, const void *, NSUInteger, NSUInteger, NSUInteger);
typedef void (*w_t_imp)(id, SEL, id, NSUInteger);
typedef void (*w_u_imp)(id, SEL, id, MTLResourceUsage, MTLRenderStages);
typedef void (*w_us_imp)(id, SEL, const id __unsafe_unretained *, NSUInteger, MTLResourceUsage, MTLRenderStages);
typedef void (*w_h_imp)(id, SEL, id, MTLRenderStages);
typedef void (*w_hs_imp)(id, SEL, const id __unsafe_unretained *, NSUInteger, MTLRenderStages);
typedef void (*w_sc_imp)(id, SEL, MTLScissorRect);
typedef void (*w_vp_imp)(id, SEL, MTLViewport);
typedef void (*w_vps_imp)(id, SEL, const MTLViewport *, NSUInteger);
typedef void (*w_dp_imp)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger);
typedef void (*w_dpi_imp)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger);
typedef void (*w_dpib_imp)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger, NSUInteger);
typedef void (*w_dx_imp)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger);
typedef void (*w_dxi_imp)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger, NSUInteger);
typedef void (*w_dxib_imp)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger, NSUInteger, NSInteger, NSUInteger);
static w_b_imp w_vb, w_fb; static w_bo_imp w_vbo, w_fbo; static w_by_imp w_vby, w_fby; static w_bs_imp w_vbs; static w_bos_imp w_vbos; static w_bys_imp w_vbys;
static w_t_imp w_vt, w_ft, w_fs; static w_u_imp w_u; static w_us_imp w_us; static w_h_imp w_h; static w_hs_imp w_hs; static w_sc_imp w_sc; static w_vp_imp w_vp;
static w_vps_imp w_vps;
static w_dp_imp w_dp; static w_dpi_imp w_dpi; static w_dpib_imp w_dpib; static w_dx_imp w_dx; static w_dxi_imp w_dxi; static w_dxib_imp w_dxib;
#define R_ if (tl_rec == (__bridge void *)self) { VXUIRec *r = objc_getAssociatedObject(self, kUIRec); if (r && !r.segment)
static void wh_vb(id self, SEL s, id b, NSUInteger o, NSUInteger i) { w_vb(self, s, b, o, i); R_ wbind(r.vb, i, b, o, 0, NULL, 0, 0); } }
static void wh_fb(id self, SEL s, id b, NSUInteger o, NSUInteger i) { w_fb(self, s, b, o, i); R_ wbind(r.fb, i, b, o, 0, NULL, 0, 0); } }
static void wh_vbo(id self, SEL s, NSUInteger o, NSUInteger i) { w_vbo(self, s, o, i); R_ wbind(r.vb, i, nil, o, 0, NULL, 0, 1); } }
static void wh_fbo(id self, SEL s, NSUInteger o, NSUInteger i) { w_fbo(self, s, o, i); R_ wbind(r.fb, i, nil, o, 0, NULL, 0, 1); } }
static void wh_vby(id self, SEL s, const void *b, NSUInteger l, NSUInteger i) { w_vby(self, s, b, l, i); R_ wbind(r.vb, i, nil, 0, 0, b, l, 0); } }
static void wh_fby(id self, SEL s, const void *b, NSUInteger l, NSUInteger i) { w_fby(self, s, b, l, i); R_ wbind(r.fb, i, nil, 0, 0, b, l, 0); } }
static void wh_vbs(id self, SEL s, id b, NSUInteger o, NSUInteger st, NSUInteger i) { w_vbs(self, s, b, o, st, i); R_ wbind(r.vb, i, b, o, st, NULL, 0, 0); } }
static void wh_vbos(id self, SEL s, NSUInteger o, NSUInteger st, NSUInteger i) { w_vbos(self, s, o, st, i); R_ wbind(r.vb, i, nil, o, st, NULL, 0, 1); } }
static void wh_vbys(id self, SEL s, const void *b, NSUInteger l, NSUInteger st, NSUInteger i) { w_vbys(self, s, b, l, st, i); R_ wbind(r.vb, i, nil, 0, st, b, l, 0); } }
static void wh_vt(id self, SEL s, id t, NSUInteger i) { w_vt(self, s, t, i); R_ { if (t) r.vt[@(i)] = t; else [r.vt removeObjectForKey:@(i)]; } } }
static void wh_ft(id self, SEL s, id t, NSUInteger i) { w_ft(self, s, t, i); R_ { if (t) r.ft[@(i)] = t; else [r.ft removeObjectForKey:@(i)]; } } }
static void wh_fs(id self, SEL s, id t, NSUInteger i) { w_fs(self, s, t, i); R_ { if (t) r.fs[@(i)] = t; else [r.fs removeObjectForKey:@(i)]; } } }
static void wh_u(id self, SEL s, id t, MTLResourceUsage u, MTLRenderStages st) { w_u(self, s, t, u, st); R_ { if (t) [r.res addObject:@[ t, @(u), @(st) ]]; } } }
static void wh_us(id self, SEL s, const id __unsafe_unretained *t, NSUInteger n, MTLResourceUsage u, MTLRenderStages st) { w_us(self, s, t, n, u, st); R_ { for (NSUInteger i = 0; t && i < n; i++) if (t[i]) [r.res addObject:@[ t[i], @(u), @(st) ]]; } } }
static void wh_h(id self, SEL s, id h, MTLRenderStages st) { w_h(self, s, h, st); R_ { if (h) [r.heaps addObject:@[ h, @(st) ]]; } } }
static void wh_hs(id self, SEL s, const id __unsafe_unretained *h, NSUInteger n, MTLRenderStages st) { w_hs(self, s, h, n, st); R_ { for (NSUInteger i = 0; h && i < n; i++) if (h[i]) [r.heaps addObject:@[ h[i], @(st) ]]; } } }
static void wh_sc(id self, SEL s, MTLScissorRect v) { w_sc(self, s, v); R_ r.scissor = [NSValue valueWithBytes:&v objCType:@encode(MTLScissorRect)]; } }
static void wh_vp(id self, SEL s, MTLViewport v) { w_vp(self, s, v); R_ r.viewport = [NSValue valueWithBytes:&v objCType:@encode(MTLViewport)]; } }
static void wh_vps(id self, SEL s, const MTLViewport *v, NSUInteger n) { w_vps(self, s, v, n); if (v && n) { R_ r.viewport = [NSValue valueWithBytes:&v[0] objCType:@encode(MTLViewport)]; } } }
static void wh_dp(id self, SEL s, MTLPrimitiveType t, NSUInteger v, NSUInteger c) { wprepare(self,c,1,0,nil,0,0); w_dp(self, s, t, v, c); wdraw(self, 0, t, v, c, 1, nil, 0, 0, 0); }
static void wh_dpi(id self, SEL s, MTLPrimitiveType t, NSUInteger v, NSUInteger c, NSUInteger i) { wprepare(self,c,i,0,nil,0,0); w_dpi(self, s, t, v, c, i); wdraw(self, 0, t, v, c, i, nil, 0, 0, 0); }
static void wh_dpib(id self, SEL s, MTLPrimitiveType t, NSUInteger v, NSUInteger c, NSUInteger i, NSUInteger bi) { NSUInteger draw_bi=wprepare(self,c,i,bi,nil,0,0); w_dpib(self, s, t, v, c, i, draw_bi); wdraw(self, 0, t, v, c, i, nil, 0, 0, bi); }
static void wh_dx(id self, SEL s, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id ib, NSUInteger io) { wprepare(self,c,1,0,ib,io,it); w_dx(self, s, t, c, it, ib, io); wdraw(self, 1, t, c, it, 1, ib, io, 0, 0); }
static void wh_dxi(id self, SEL s, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id ib, NSUInteger io, NSUInteger i) { wprepare(self,c,i,0,ib,io,it); w_dxi(self, s, t, c, it, ib, io, i); wdraw(self, 1, t, c, it, i, ib, io, 0, 0); }
static void wh_dxib(id self, SEL s, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id ib, NSUInteger io, NSUInteger i, NSInteger bv, NSUInteger bi) { NSUInteger draw_bi=wprepare(self,c,i,bi,ib,io,it); w_dxib(self, s, t, c, it, ib, io, i, bv, draw_bi); wdraw(self, 1, t, c, it, i, ib, io, bv, bi); }
#undef R_
static void install_wui(Class rc) {
    if (g_wui < 0) { const char *v = getenv("VXMAC_WORLD_UI"); g_wui = !(v && !strcmp(v, "0")); }
    if (!g_wui && !stereo_audit_enabled()) return;
#define S(sel, h, o) (o = (__typeof__(o))swap(rc, @selector(sel), (IMP)h))
    S(setVertexBuffer:offset:atIndex:, wh_vb, w_vb); S(setFragmentBuffer:offset:atIndex:, wh_fb, w_fb);
    S(setVertexBufferOffset:atIndex:, wh_vbo, w_vbo); S(setFragmentBufferOffset:atIndex:, wh_fbo, w_fbo);
    S(setVertexBytes:length:atIndex:, wh_vby, w_vby); S(setFragmentBytes:length:atIndex:, wh_fby, w_fby);
    S(setVertexBuffer:offset:attributeStride:atIndex:, wh_vbs, w_vbs); S(setVertexBufferOffset:attributeStride:atIndex:, wh_vbos, w_vbos);
    S(setVertexBytes:length:attributeStride:atIndex:, wh_vbys, w_vbys);
    S(setVertexTexture:atIndex:, wh_vt, w_vt); S(setFragmentTexture:atIndex:, wh_ft, w_ft); S(setFragmentSamplerState:atIndex:, wh_fs, w_fs);
    S(useResource:usage:stages:, wh_u, w_u); S(useResources:count:usage:stages:, wh_us, w_us);
    S(useHeap:stages:, wh_h, w_h); S(useHeaps:count:stages:, wh_hs, w_hs);
    S(setScissorRect:, wh_sc, w_sc); S(setViewport:, wh_vp, w_vp); S(setViewports:count:, wh_vps, w_vps);
    S(drawPrimitives:vertexStart:vertexCount:, wh_dp, w_dp); S(drawPrimitives:vertexStart:vertexCount:instanceCount:, wh_dpi, w_dpi);
    S(drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:, wh_dpib, w_dpib);
    S(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:, wh_dx, w_dx);
    S(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:, wh_dxi, w_dxi);
    S(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:, wh_dxib, w_dxib);
#undef S
}

void vxpipe_install_encoders(Class rc, Class cc) {
#define S(c, sel, h, o) (o = (__typeof__(o))swap(c, @selector(sel), (IMP)h))
    if (rc) S(rc, setRenderPipelineState:, h_rps, o_rps);   // (h51: always - the UI layers are told by their pipelines)
    if (rc) install_tl(rc);                                   // (h52: always - the game's camera)
    if (rc) install_wui(rc);                                  // (h58: always - the world UI's draws recorded in the UI pass)
    if (rc) g_dump_rc=rc; if (cc) g_dump_cc=cc;
    install_dump_encoders();
#undef S
}
static void install_dump_encoders(void) {
    // These optional hooks may be enabled after the constructor installed the core
    // camera/hand hooks. Only install the missing dump hooks, never the core twice.
    static int rc_done, cc_done;
    Class rc=g_dump_rc, cc=g_dump_cc;
#define S(c, sel, h, o) (o = (__typeof__(o))swap(c, @selector(sel), (IMP)h))
    if (!g_f) return;
    if (rc && !rc_done++) {
        S(rc, setFragmentTexture:atIndex:, h_rft, o_rft);
        S(rc, setVertexTexture:atIndex:, h_rvt, o_rvt);
        S(rc, setFragmentTextures:withRange:, h_rfts, o_rfts);
        S(rc, useResource:usage:stages:, h_ruse, o_ruse);
        S(rc, useResources:count:usage:stages:, h_ruses, o_ruses);
        if (!getenv("VXMAC_UI_DRAWS") || strcmp(getenv("VXMAC_UI_DRAWS"), "0")) install_draws(rc);   // (h58: dump runs only; VXMAC_UI_DRAWS=0 off)
    }
    if (cc && !cc_done++) {
        S(cc, setComputePipelineState:, h_cps, o_cps);
        S(cc, setTexture:atIndex:, h_ctt, o_ctt);
        S(cc, setTextures:withRange:, h_ctts, o_ctts);
        S(cc, useResource:usage:, h_cuse, o_cuse);
        S(cc, useResources:count:usage:, h_cuses, o_cuses);
        S(cc, endEncoding, h_cend, o_cend);
        if (g_contract) {
            S(cc, setBuffer:offset:atIndex:, h_ctb, o_ctb);
            S(cc, setBuffers:offsets:withRange:, h_ctbs, o_ctbs);
            S(cc, setBufferOffset:atIndex:, h_ctbo, o_ctbo);
            S(cc, setBytes:length:atIndex:, h_ctby, o_ctby);
            S(cc, dispatchThreadgroups:threadsPerThreadgroup:, h_cdg, o_cdg);
            S(cc, dispatchThreads:threadsPerThreadgroup:, h_cdt, o_cdt);
            S(cc, dispatchThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerThreadgroup:, h_cdi, o_cdi);
        }
    }
#undef S
    out("DUMP encoders %s %s", rc ? class_getName(rc) : "-", cc ? class_getName(cc) : "-");
}

void vxpipe_mem_stats(char *out, unsigned n) {   // (h62: the host's "mem" line)
    size_t nb; uint64_t bytes = 0;
    char enc[160]; void vxmtl_enc_stats(char *, unsigned); vxmtl_enc_stats(enc, sizeof enc); strlcat(enc, "}", sizeof enc);
    pthread_mutex_lock(&g_brl); nb = g_nbr; for (size_t i = 0; i < g_nbr; i++) bytes += g_br[i].len; pthread_mutex_unlock(&g_brl);
    snprintf(out, n, "\"mtl\":{\"render_pipes\":%ld,\"render_pipes_made\":%ld,\"compute_pipes\":%ld,\"compute_pipes_made\":%ld,"
             "\"libs\":%ld,\"libs_made\":%ld,\"lib_data_mb\":%.1f,\"ui_twins\":%ld,\"shared_bufs\":%zu,\"shared_buf_mb\":%llu,"
             "\"ui_recs\":%ld,\"pass_recs\":%ld,"
             "\"libs_distinct\":%u,\"libs_repeat\":%ld,\"rp_distinct\":%u,\"rp_repeat\":%ld,\"rp_ms\":%.0f,\"rp_ms_max\":%.1f,\"rp_slow\":%ld,"
             "\"rp_with_archives\":%ld,\"game_arch_adds\":%ld,\"game_arch_writes\":%ld,%s",
             atomic_load(&g_rp_live), atomic_load(&g_rp_made), atomic_load(&g_cp_live), atomic_load(&g_cp_made),
             atomic_load(&g_lib_live), atomic_load(&g_lib_made), atomic_load(&g_lib_bytes) / 1048576.0, atomic_load(&g_twins), nb,
             (unsigned long long)(bytes >> 20), atomic_load(&g_uirec_live), atomic_load(&g_passrec_live),
             g_libset.n, atomic_load(&g_lib_repeat), g_rpset.n, atomic_load(&g_rp_repeat), atomic_load(&g_rp_us) / 1e3, atomic_exchange(&g_rp_max_us, 0) / 1e3,
             atomic_load(&g_rp_slow), atomic_load(&g_rp_arch), atomic_load(&g_garch_adds), atomic_load(&g_garch_ser), enc);
    if (g_pa > 0) { size_t k = strlen(out); if (k + 2 < n) snprintf(out + k - 1, n - k + 1, ",\"pa\":{\"files\":%lu,\"adds\":%ld,\"add_fail\":%ld,\"add_ms\":%.0f,\"saved\":%ld,\"known\":%ld,\"used\":%ld,\"keys\":%u}}",
        (unsigned long)g_pa_read.count, atomic_load(&g_pa_adds), atomic_load(&g_pa_add_fail), atomic_load(&g_pa_add_us) / 1e3, atomic_load(&g_pa_saved), atomic_load(&g_pa_known), atomic_load(&g_pa_used), g_pa_keys.n); }
}
