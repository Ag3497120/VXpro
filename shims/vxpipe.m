// vxpipe.m - the game's own Metal metadata, logged (VXMAC_PIPE_DUMP=<file>; off when unset)
//
// Every library the game makes (its function names), every render / compute pipeline (vertex / fragment / kernel
// function names and labels, attachment formats, blending), once each. With VXMAC_PIPE_REFLECT=1 the game's own
// pipeline calls ask Metal for reflection too (the same compile, the options added): each buffer binding's name,
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
#include "vxmac.h"

static FILE *g_f;
static __thread void *tl_rec; static int tl_rec_any(void) { return tl_rec != NULL; }
static void wui_twin(id p, MTLRenderPipelineDescriptor *d, id<MTLFunction> fs);
static pthread_mutex_t g_fl = PTHREAD_MUTEX_INITIALIZER;
static int g_reflect;
static atomic_int g_dump;           // (this frame is dumped)
static atomic_uint g_frame;
static unsigned g_frames_left = 60;   // (h51: 60 frames, one every 3 s: ~3 min of play)
static double g_every = 3, g_next_at;
static atomic_uint g_pipe_n, g_tex_n, g_pass_n;
static const void *kPID = &kPID, *kTID = &kTID, *kRec = &kRec;

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

// ---- libraries ----------------------------------------------------------------------------------------------------
// (each library's bytes hashed (FNV-1a 64): the game's shaders are all vs_main_ / ps_main_ / cs_main_, so a shader
//  is known by its hash, the same in every run and on every device; its functions carry it)
static const void *kHash = &kHash;
typedef id (*fn_imp)(id, SEL, id) __attribute__((ns_returns_retained));
typedef id (*fn_c_imp)(id, SEL, id, id, NSError **) __attribute__((ns_returns_retained));
static fn_imp o_fn; static fn_c_imp o_fn_c;
static void fn_tag(id l, id f) { if (f && l) { id h = objc_getAssociatedObject(l, kHash); if (h) objc_setAssociatedObject(f, kHash, h, OBJC_ASSOCIATION_RETAIN); } }
__attribute__((ns_returns_retained)) static id h_fn(id self, SEL s, id n) { id f = o_fn(self, s, n); fn_tag(self, f); return f; }
__attribute__((ns_returns_retained)) static id h_fn_c(id self, SEL s, id n, id cv, NSError **e) { id f = o_fn_c(self, s, n, cv, e); fn_tag(self, f); return f; }
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
    if (l && d) {
        __block uint64_t h = 0xcbf29ce484222325ULL;
        dispatch_data_apply((dispatch_data_t)d, ^bool(dispatch_data_t r, size_t off, const void *b, size_t n) { h = fnv(b, n, h); return true; });
        objc_setAssociatedObject(l, kHash, [NSString stringWithFormat:@"%016llx", (unsigned long long)h], OBJC_ASSOCIATION_RETAIN);
    }
    lib_note(l, "data"); return l;
}
__attribute__((ns_returns_retained)) static id h_lib_url(id self, SEL s, id u, NSError **e) { id l = o_lib_url(self, s, u, e); lib_note(l, [[u lastPathComponent] UTF8String] ?: "url"); return l; }

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
static void render_note(id p, MTLRenderPipelineDescriptor *d, MTLRenderPipelineReflection *r, const char *how) {
    if (!p) return;
    if (is_ui_vs(d.vertexFunction)) { vxmtl_ui_pipe_add((__bridge void *)p); wui_twin(p, d, d.fragmentFunction); }
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

typedef id (*rp_imp)(id, SEL, id, NSError **) __attribute__((ns_returns_retained));
typedef id (*rp_opt_imp)(id, SEL, id, MTLPipelineOption, MTLAutoreleasedRenderPipelineReflection *, NSError **) __attribute__((ns_returns_retained));
typedef void (*rp_cb_imp)(id, SEL, id, MTLNewRenderPipelineStateCompletionHandler);
typedef void (*rp_opt_cb_imp)(id, SEL, id, MTLPipelineOption, MTLNewRenderPipelineStateWithReflectionCompletionHandler);
static rp_imp o_rp; static rp_opt_imp o_rp_opt; static rp_cb_imp o_rp_cb; static rp_opt_cb_imp o_rp_opt_cb;
__attribute__((ns_returns_retained)) static id h_rp(id self, SEL s, MTLRenderPipelineDescriptor *d, NSError **e) {
    if (g_reflect && o_rp_opt) {
        MTLAutoreleasedRenderPipelineReflection r = nil;
        id p = o_rp_opt(self, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:), d, kRefl, &r, e);
        render_note(p, d, r, "sync+r"); return p;
    }
    id p = o_rp(self, s, d, e); render_note(p, d, nil, "sync"); return p;
}
__attribute__((ns_returns_retained)) static id h_rp_opt(id self, SEL s, MTLRenderPipelineDescriptor *d, MTLPipelineOption opt, MTLAutoreleasedRenderPipelineReflection *rr, NSError **e) {
    MTLAutoreleasedRenderPipelineReflection r = nil;
    if (g_reflect) opt |= kRefl;
    id p = o_rp_opt(self, s, d, opt, &r, e);
    if (rr) *rr = r;
    render_note(p, d, r, "opt"); return p;
}
static void h_rp_cb(id self, SEL s, MTLRenderPipelineDescriptor *d0, MTLNewRenderPipelineStateCompletionHandler h) {
    MTLRenderPipelineDescriptor *d = [d0 copy];   // (the game may reuse its descriptor before the handler runs)
    if (g_reflect && o_rp_opt_cb) {
        o_rp_opt_cb(self, @selector(newRenderPipelineStateWithDescriptor:options:completionHandler:), d0, kRefl,
                    ^(id<MTLRenderPipelineState> p, MTLRenderPipelineReflection *r, NSError *e) { render_note(p, d, r, "async+r"); h(p, e); });
        return;
    }
    o_rp_cb(self, s, d0, ^(id<MTLRenderPipelineState> p, NSError *e) { render_note(p, d, nil, "async"); h(p, e); });
}
static void h_rp_opt_cb(id self, SEL s, MTLRenderPipelineDescriptor *d0, MTLPipelineOption opt, MTLNewRenderPipelineStateWithReflectionCompletionHandler h) {
    MTLRenderPipelineDescriptor *d = [d0 copy];
    o_rp_opt_cb(self, s, d0, opt | (g_reflect ? kRefl : 0), ^(id<MTLRenderPipelineState> p, MTLRenderPipelineReflection *r, NSError *e) { render_note(p, d, r, "async-opt"); h(p, r, e); });
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
void vxpipe_install_device(Class dc) {
    static int done; if (done++) return;
    const char *path = getenv("VXMAC_PIPE_DUMP");
    if (path && *path) {
    // a relative name goes into the app's Documents (the headset: no writable working directory)
    NSString *ps = @(path);
    if (![ps isAbsolutePath]) ps = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:ps];
    g_f = fopen(ps.fileSystemRepresentation, "w");
    if (!g_f) vxmac_log("Metal: pipeline dump: cannot open %s", ps.fileSystemRepresentation);
    }
    const char *e;
    g_reflect = (e = getenv("VXMAC_PIPE_REFLECT")) && atoi(e);
    if ((e = getenv("VXMAC_PIPE_EVERY"))) g_every = atof(e);
    if ((e = getenv("VXMAC_PIPE_FRAMES"))) g_frames_left = (unsigned)atoi(e);
    g_structs = [NSMutableDictionary dictionary];
    g_next_at = CACurrentMediaTime() + g_every;
    if (!g_f) g_reflect = 0;
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
    out("DUMP start reflect=%d every=%.1fs frames=%u device=%s", g_reflect, g_every, g_frames_left, class_getName(dc));
    if (g_f) vxmac_log("Metal: pipeline dump to %s (reflection %s)", path, g_reflect ? "on" : "off");
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
static const void *kCamPass = &kCamPass;
static void cam_pass_note(id e, MTLRenderPassDescriptor *pd) {   // (h52: the frame's first G-buffer pass: depth + 3 colour targets or more)
    static _Atomic unsigned cframe;
    if (!pd.depthAttachment.texture || !pd.colorAttachments[2].texture || !pd.colorAttachments[1].texture || !pd.colorAttachments[0].texture) return;
    unsigned fr = atomic_load(&g_frame);
    if (atomic_exchange(&cframe, fr) == fr) return;
    objc_setAssociatedObject(e, kCamPass, @1, OBJC_ASSOCIATION_RETAIN);
}
void vxpipe_render_begin(id e, MTLRenderPassDescriptor *pd) {
    if (e) cam_pass_note(e, pd);
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
void vxpipe_render_end(id e) { if (g_f) pass_end(e); }

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
static void cam_read(const uint8_t *tl, size_t n) {
    static int on = -1; if (on < 0) { const char *v = getenv("VXMAC_GAME_CAM"); on = !(v && !strcmp(v, "0")); }
    if (!on || !tl || n < 8) return;
    // (the place, 2.3.2's by default: top-level word 0, table byte 24, matrix byte 320; VXMAC_CAM_PATH=<word>:<table
    //  byte>:<matrix byte> for another build (tools/cbv_find.py prints it))
    static unsigned qw = 0, tb = 24, mb = 320; static dispatch_once_t once;
    dispatch_once(&once, ^{ const char *e = getenv("VXMAC_CAM_PATH"); if (e && sscanf(e, "%u:%u:%u", &qw, &tb, &mb) == 3) vxmac_log("Metal: the camera's place from VXMAC_CAM_PATH: %u:%u:%u", qw, tb, mb); });
    if (n < (qw + 1) * 8) return;
    float m[16]; int ok = 0;
    pthread_mutex_lock(&g_brl);
    uint64_t v; memcpy(&v, tl + qw * 8, 8);
    uint64_t av, base; const uint8_t *d = buf_at(v, &av, &base);
    if (d && av >= tb + 8) {
        uint64_t v2; memcpy(&v2, d + tb, 8);
        const uint8_t *c = buf_at(v2, &av, &base);
        if (c && av >= mb + 64) { memcpy(m, c + mb, 64); ok = 1; }
        if (c && av >= 192 && mb == 320) {   // (2.3.2 / 2.5.0's layout: the projection at byte 128)
            float p0, p5; memcpy(&p0, c + 128, 4); memcpy(&p5, c + 148, 4);
            if (p0 > 0.2f && p0 < 5 && p5 > 0.2f && p5 < 8) {
                pthread_mutex_lock(&g_gcl); float o = g_gtan[0]; g_gtan[0] = 1 / p0; g_gtan[1] = 1 / p5; pthread_mutex_unlock(&g_gcl);
                if (fabsf(o - 1 / p0) > 0.01f) vxmac_log("Metal: the game's projection: horizontal %.1f deg, vertical %.1f deg", 2 * atanf(1 / p0) * 57.2958f, 2 * atanf(1 / p5) * 57.2958f);
            }
        }
    }
    pthread_mutex_unlock(&g_brl);
    if (ok) {
        for (int r = 0; r < 3 && ok; r++) { float l = m[r*4]*m[r*4] + m[r*4+1]*m[r*4+1] + m[r*4+2]*m[r*4+2]; if (!(fabsf(l - 1) < 0.02f)) ok = 0; }
        if (ok && fabsf(m[0]*m[4] + m[1]*m[5] + m[2]*m[6]) > 0.02f) ok = 0;
        if (ok && fabsf(m[4]*m[8] + m[5]*m[9] + m[6]*m[10]) > 0.02f) ok = 0;
        if (ok && fabsf(m[15] - 1) > 1e-3f) ok = 0;
    }
    if (!ok) { if (g_gcam_bad++ < 10) vxmac_log("Metal: the game's camera: no rotation at the known place this frame (%lu)", g_gcam_bad); return; }
    pthread_mutex_lock(&g_gcl); memcpy(g_gcam, m, sizeof m); g_gcam_seq++; uint64_t q = g_gcam_seq; pthread_mutex_unlock(&g_gcl);
    if (q == 1) vxmac_log("Metal: the game's camera read from its view constants (forward %.3f %.3f %.3f)", m[8], m[9], m[10]);
}
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
    if (idx != 2) return;
    if (stage == 0 && objc_getAssociatedObject(e, kCamPass)) {
        objc_setAssociatedObject(e, kCamPass, nil, OBJC_ASSOCIATION_RETAIN);
        if (bytes) cam_read(bytes, len);
        else if (buf && !offonly) { id<MTLBuffer> b = buf; if (b.storageMode == MTLStorageModeShared && off + 8 <= b.length) cam_read((const uint8_t *)b.contents + off, b.length - off); }
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
static void h_svo2(id self, SEL s, NSUInteger o, NSUInteger i) { o_svo2(self, s, o, i); tl_note(self, 0, nil, o, i, NULL, 0, 1); }
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
typedef void (*sbs_imp)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger);
typedef void (*sbos_imp)(id, SEL, NSUInteger, NSUInteger, NSUInteger);
typedef void (*sbys_imp)(id, SEL, const void *, NSUInteger, NSUInteger, NSUInteger);
static sbs_imp o_svbs; static sbos_imp o_svos; static sbys_imp o_svys;
static void h_svbs(id self, SEL s, id b, NSUInteger o, NSUInteger st, NSUInteger i) { o_svbs(self, s, b, o, st, i); ui_bind(self, 0, b, o, i, NULL, 0, 0); VXPassRec *r = g_f ? rec(self) : nil; if (r && r.ui) r.vb[[NSString stringWithFormat:@"s%lu", (unsigned long)i]] = @(st); }
static void h_svos(id self, SEL s, NSUInteger o, NSUInteger st, NSUInteger i) { o_svos(self, s, o, st, i); ui_bind(self, 0, nil, o, i, NULL, 0, 1); VXPassRec *r = g_f ? rec(self) : nil; if (r && r.ui) r.vb[[NSString stringWithFormat:@"s%lu", (unsigned long)i]] = @(st); }
static void h_svys(id self, SEL s, const void *b, NSUInteger l, NSUInteger st, NSUInteger i) { o_svys(self, s, b, l, st, i); ui_bind(self, 0, nil, 0, i, b, l, 0); VXPassRec *r = g_f ? rec(self) : nil; if (r && r.ui) r.vb[[NSString stringWithFormat:@"s%lu", (unsigned long)i]] = @(st); }
static void install_tl(Class rc) {
#define S(c, sel, h, o) (o = (__typeof__(o))swap(c, @selector(sel), (IMP)h))
    if (g_f) { S(rc, setVertexBuffer:offset:attributeStride:atIndex:, h_svbs, o_svbs); S(rc, setVertexBufferOffset:attributeStride:atIndex:, h_svos, o_svos); S(rc, setVertexBytes:length:attributeStride:atIndex:, h_svys, o_svys); }
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
static void h_rps(id self, SEL s, id p) { id use = p; if (tl_rec_any() && wui_pipe(self, p, &use)) o_rps(self, s, use); else o_rps(self, s, p); vxmtl_ui_pipe_set(self, p); if (g_f) { pipe_add(self, p); VXPassRec *r = rec(self); if (r && r.ui) r.curpipe = p; } }
static void h_rft(id self, SEL s, id t, NSUInteger i) { o_rft(self, s, t, i); rec_read(self, t, "(f)"); }
static void h_rvt(id self, SEL s, id t, NSUInteger i) { o_rvt(self, s, t, i); rec_read(self, t, "(v)"); }
static void h_rfts(id self, SEL s, const id __unsafe_unretained *t, NSRange r) { o_rfts(self, s, t, r); for (NSUInteger i = 0; t && i < r.length; i++) rec_read(self, t[i], "(f)"); }
static void h_ruse(id self, SEL s, id t, MTLResourceUsage u, MTLRenderStages st) { o_ruse(self, s, t, u, st); rec_read(self, t, (u & MTLResourceUsageWrite) ? "(uw)" : "(u)"); }
static void h_ruses(id self, SEL s, const id __unsafe_unretained *t, NSUInteger n, MTLResourceUsage u, MTLRenderStages st) {
    o_ruses(self, s, t, n, u, st); for (NSUInteger i = 0; t && i < n; i++) rec_read(self, t[i], (u & MTLResourceUsageWrite) ? "(uw)" : "(u)");
}
// compute encoder
static void h_cps(id self, SEL s, id p) {
    o_cps(self, s, p);
    if (atomic_load(&g_dump) && !objc_getAssociatedObject(self, kRec)) pass_begin(self, @"", 1);
    pipe_add(self, p);
}
static void h_ctt(id self, SEL s, id t, NSUInteger i) { o_ctt(self, s, t, i); rec_read(self, t, ""); }
static void h_ctts(id self, SEL s, const id __unsafe_unretained *t, NSRange r) { o_ctts(self, s, t, r); for (NSUInteger i = 0; t && i < r.length; i++) rec_read(self, t[i], ""); }
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
    if (tw) objc_setAssociatedObject(p, kTwin, tw, OBJC_ASSOCIATION_RETAIN);
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
static void wdraw(id e, int kind, NSUInteger a0, NSUInteger a1, NSUInteger a2, NSUInteger inst, id ib, NSUInteger io, NSInteger base, NSUInteger bi) {
    VXUIRec *r = wrec(e);
    if (r && !r.segment) r.npre++;
    if (!r || r.segment || !r.pipe || r.draws.count >= 64) return;
    if (!r.masking || !objc_getAssociatedObject(r.pipe, kTwin)) return;   // (not masked: drawn into the layer as it is, not drawn again)
    [r.draws addObject:@{ @"pipe": r.pipe, @"vb": [r.vb copy], @"fb": [r.fb copy], @"vt": [r.vt copy], @"ft": [r.ft copy], @"fs": [r.fs copy],
                          @"res": [r.res copy], @"heaps": [r.heaps copy], @"sc": r.scissor ?: [NSNull null], @"vp": r.viewport ?: [NSNull null],
                          @"k": @[ @(kind), @(a0), @(a1), @(a2), @(inst), ib ?: [NSNull null], @(io), @(base), @(bi) ] }];
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
typedef void (*w_dp_imp)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger);
typedef void (*w_dpi_imp)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger);
typedef void (*w_dpib_imp)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger, NSUInteger);
typedef void (*w_dx_imp)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger);
typedef void (*w_dxi_imp)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger, NSUInteger);
typedef void (*w_dxib_imp)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger, NSUInteger, NSInteger, NSUInteger);
static w_b_imp w_vb, w_fb; static w_bo_imp w_vbo, w_fbo; static w_by_imp w_vby, w_fby; static w_bs_imp w_vbs; static w_bos_imp w_vbos; static w_bys_imp w_vbys;
static w_t_imp w_vt, w_ft, w_fs; static w_u_imp w_u; static w_us_imp w_us; static w_h_imp w_h; static w_hs_imp w_hs; static w_sc_imp w_sc; static w_vp_imp w_vp;
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
static void wh_dp(id self, SEL s, MTLPrimitiveType t, NSUInteger v, NSUInteger c) { w_dp(self, s, t, v, c); wdraw(self, 0, t, v, c, 1, nil, 0, 0, 0); }
static void wh_dpi(id self, SEL s, MTLPrimitiveType t, NSUInteger v, NSUInteger c, NSUInteger i) { w_dpi(self, s, t, v, c, i); wdraw(self, 0, t, v, c, i, nil, 0, 0, 0); }
static void wh_dpib(id self, SEL s, MTLPrimitiveType t, NSUInteger v, NSUInteger c, NSUInteger i, NSUInteger bi) { w_dpib(self, s, t, v, c, i, bi); wdraw(self, 0, t, v, c, i, nil, 0, 0, bi); }
static void wh_dx(id self, SEL s, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id ib, NSUInteger io) { w_dx(self, s, t, c, it, ib, io); wdraw(self, 1, t, c, it, 1, ib, io, 0, 0); }
static void wh_dxi(id self, SEL s, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id ib, NSUInteger io, NSUInteger i) { w_dxi(self, s, t, c, it, ib, io, i); wdraw(self, 1, t, c, it, i, ib, io, 0, 0); }
static void wh_dxib(id self, SEL s, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id ib, NSUInteger io, NSUInteger i, NSInteger bv, NSUInteger bi) { w_dxib(self, s, t, c, it, ib, io, i, bv, bi); wdraw(self, 1, t, c, it, i, ib, io, bv, bi); }
#undef R_
static void install_wui(Class rc) {
    if (g_wui < 0) { const char *v = getenv("VXMAC_WORLD_UI"); g_wui = !(v && !strcmp(v, "0")); }
    if (!g_wui) return;
#define S(sel, h, o) (o = (__typeof__(o))swap(rc, @selector(sel), (IMP)h))
    S(setVertexBuffer:offset:atIndex:, wh_vb, w_vb); S(setFragmentBuffer:offset:atIndex:, wh_fb, w_fb);
    S(setVertexBufferOffset:atIndex:, wh_vbo, w_vbo); S(setFragmentBufferOffset:atIndex:, wh_fbo, w_fbo);
    S(setVertexBytes:length:atIndex:, wh_vby, w_vby); S(setFragmentBytes:length:atIndex:, wh_fby, w_fby);
    S(setVertexBuffer:offset:attributeStride:atIndex:, wh_vbs, w_vbs); S(setVertexBufferOffset:attributeStride:atIndex:, wh_vbos, w_vbos);
    S(setVertexBytes:length:attributeStride:atIndex:, wh_vbys, w_vbys);
    S(setVertexTexture:atIndex:, wh_vt, w_vt); S(setFragmentTexture:atIndex:, wh_ft, w_ft); S(setFragmentSamplerState:atIndex:, wh_fs, w_fs);
    S(useResource:usage:stages:, wh_u, w_u); S(useResources:count:usage:stages:, wh_us, w_us);
    S(useHeap:stages:, wh_h, w_h); S(useHeaps:count:stages:, wh_hs, w_hs);
    S(setScissorRect:, wh_sc, w_sc); S(setViewport:, wh_vp, w_vp);
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
    if (!g_f) return;
    if (rc) {
        S(rc, setFragmentTexture:atIndex:, h_rft, o_rft);
        S(rc, setVertexTexture:atIndex:, h_rvt, o_rvt);
        S(rc, setFragmentTextures:withRange:, h_rfts, o_rfts);
        S(rc, useResource:usage:stages:, h_ruse, o_ruse);
        S(rc, useResources:count:usage:stages:, h_ruses, o_ruses);
        if (!getenv("VXMAC_UI_DRAWS") || strcmp(getenv("VXMAC_UI_DRAWS"), "0")) install_draws(rc);   // (h58: dump runs only; VXMAC_UI_DRAWS=0 off)
    }
    if (cc) {
        S(cc, setComputePipelineState:, h_cps, o_cps);
        S(cc, setTexture:atIndex:, h_ctt, o_ctt);
        S(cc, setTextures:withRange:, h_ctts, o_ctts);
        S(cc, useResource:usage:, h_cuse, o_cuse);
        S(cc, useResources:count:usage:, h_cuses, o_cuses);
        S(cc, endEncoding, h_cend, o_cend);
    }
#undef S
    out("DUMP encoders %s %s", rc ? class_getName(rc) : "-", cc ? class_getName(cc) : "-");
}
