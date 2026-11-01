// VX Mac (h66): the program's use of the macOS audio HAL, and who loads HAL plug-ins into this process (in libvxkit).
//
// ddgame65's malloc trace: the long session's growth (+14-20 MB/min) is BTAudioHALPlugin's: an XPC event handler on a
// GCD worker autoreleases objects (32 B, ~7000 a second under load, ~16000 while the game loads) and the pool holding
// them (4 KB pages, 509 pointers each: 13312 pages = the 6.8 M objects) is never popped. libdispatch pops a worker's
// last-resort pool only when the worker goes idle: a queue that never empties keeps it forever (tests/btpool_mac.m: a
// saturated serial queue keeps every autoreleased object, per-item pools free them). A rate that falls as the game
// takes the CPU is a handler working as fast as it can, not a fixed event rate.
// On macOS HAL plug-ins live in coreaudiod; on visionOS a plug-in is in an app only when something in it brings up a
// HAL of its own - and Cyberpunk's macOS Wwise sinks call the HAL directly (AudioObjectGetPropertyData: the default
// output 'dOut', the device list 'dev#', each device's 'slay' / 'name' / 'srnd' / 'dch2'; AudioObjectSetPropertyData
// kAudioHardwarePropertyRunLoop = NULL; AUGraph with the DefaultOutput unit and kAudioOutputUnitProperty_CurrentDevice).
//
// Here, on by default and changing nothing:
//   - every image the process loads from an Audio/Plug-Ins folder is logged with the time, the thread and the stack
//     that loaded it ("Audio: HAL plug-in loaded"): which call brings BTAudioHALPlugin in;
//   - the program's HAL calls go through counters (its own GOT slots point here, then to CoreAudio as before): calls
//     a second, by selector, the first 48 with their answers ("Audio: HAL ..."), in the mem line and vxmac_now.json;
//   - the busiest threads' CPU each mem line, the busiest one's stack sampled (thr_top): a plug-in spinning shows.
// Default (h67; VXMAC_AUDIO_HAL=1 restores the HAL): the HAL is never called. Its questions are answered as one output device with
// the audio session's channel count and rate; the run loop set and the units' CurrentDevice to that device succeed
// without a call; AUGraph's DefaultOutput node is the RemoteIO unit (visionOS's own output). Not identical to the
// HAL's answers; h66's headset A/B (51 min HAL: malloc 1.3 GB, BTAudioHALPlugin ~0.95 GB of it, 8 HAL plug-ins loaded by
// Wwise's AK::AudioMgr at 3.4 s / 27 min without: 0 plug-ins, malloc 0.22 GB flat, footprint 5.8 vs 7.8 GB) with the
// audio unchanged to the user's ear made it the default.
// VXMAC_AUDIO_WATCH=0: none of it (no hooks, no image watch).
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include "vxmac.h"

typedef int32_t OSStat;
typedef struct { uint32_t sel, scope, elem; } HALAddr;
typedef OSStat (*get_fn)(uint32_t, const HALAddr *, uint32_t, const void *, uint32_t *, void *);
typedef OSStat (*size_fn)(uint32_t, const HALAddr *, uint32_t, const void *, uint32_t *);
typedef OSStat (*set_fn)(uint32_t, const HALAddr *, uint32_t, const void *, uint32_t, const void *);
typedef OSStat (*aus_fn)(void *, uint32_t, uint32_t, uint32_t, const void *, uint32_t);
typedef struct { uint32_t type, subtype, manu, flags, mask; } ACDesc;
typedef OSStat (*addnode_fn)(void *, const ACDesc *, int32_t *);
typedef OSStat (*gstart_fn)(void *);

static get_fn r_get; static size_fn r_size; static set_fn r_set; static aus_fn r_aus; static addnode_fn r_addnode; static gstart_fn r_gstart;
static int g_synth;           // VXMAC_AUDIO_HAL=0
static double g_t0;
static atomic_ulong n_get, n_size, n_set, n_aus, n_synth, n_nodes, n_gstart;
static atomic_int g_plugins; static _Atomic double g_bt_at = -1;

#define FOURCC(a,b,c,d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))
#define SEL_DOUT FOURCC('d','O','u','t')
#define SEL_DIN  FOURCC('d','I','n',' ')
#define SEL_SOUT FOURCC('s','O','u','t')
#define SEL_DEVS FOURCC('d','e','v','#')
#define SEL_RNLP FOURCC('r','n','l','p')
#define SEL_SLAY FOURCC('s','l','a','y')
#define SEL_NAME FOURCC('n','a','m','e')
#define SEL_LNAM FOURCC('l','n','a','m')
#define SEL_UID  FOURCC('u','i','d',' ')
#define SEL_SRND FOURCC('s','r','n','d')
#define SEL_DCH2 FOURCC('d','c','h','2')
#define SEL_NSRT FOURCC('n','s','r','t')
#define SEL_FSIZ FOURCC('f','s','i','z')
#define SEL_LTNC FOURCC('l','t','n','c')
#define SEL_SAFT FOURCC('s','a','f','t')
#define SEL_LIVN FOURCC('l','i','v','n')
#define SCOPE_IN FOURCC('i','n','p','t')
#define ERR_WHO  ((OSStat)FOURCC('w','h','o','?'))
#define ERR_OBJ  ((OSStat)FOURCC('!','o','b','j'))
#define FAKE_DEV 0x7678u     // (the one device of VXMAC_AUDIO_HAL=0)

static double now_s(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec * 1e-9 - g_t0; }
static void cc(uint32_t v, char o[5]) { for (int i = 0; i < 4; i++) { char c = (char)(v >> (24 - 8 * i)); o[i] = c >= 32 && c < 127 && c != '"' && c != '\\' ? c : '?'; } o[4] = 0; }

// ---- counters by selector ---------------------------------------------------------------------------------------------
#define NSEL 32
static _Atomic uint32_t s_sel[NSEL]; static atomic_ulong s_n[NSEL];
static void count_sel(uint32_t sel) {
    for (int i = 0; i < NSEL; i++) {
        uint32_t cur = atomic_load(&s_sel[i]);
        if (cur == sel) { atomic_fetch_add(&s_n[i], 1); return; }
        if (cur == 0) { uint32_t z = 0; if (atomic_compare_exchange_strong(&s_sel[i], &z, sel) || z == sel) { atomic_fetch_add(&s_n[i], 1); return; } }
    }
}
static atomic_int g_logged; static _Atomic uint64_t g_seen[64];
static void log_call(const char *what, uint32_t obj, const HALAddr *a, OSStat st, uint32_t size, const void *data) {
    // (each distinct question once - call, object, selector, scope - up to 48 lines)
    uint64_t key = ((uint64_t)(what[1] ^ (what[0] << 8)) << 48) ^ ((uint64_t)obj << 32) ^ (a ? (uint64_t)a->sel ^ ((uint64_t)a->scope << 13) : 0); if (!key) key = 1;
    for (int i = 0; i < 64; i++) {
        uint64_t cur = atomic_load(&g_seen[i]);
        if (cur == key) return;
        if (!cur) { uint64_t z = 0; if (atomic_compare_exchange_strong(&g_seen[i], &z, key)) break; if (z == key) return; }
        if (i == 63) return;
    }
    if (atomic_fetch_add(&g_logged, 1) >= 48) return;
    char s[5], sc[5]; cc(a ? a->sel : 0, s); cc(a ? a->scope : 0, sc);
    char hex[40] = ""; if (data && st == 0) { const uint8_t *p = data; unsigned n = size < 16 ? size : 16; for (unsigned i = 0; i < n; i++) snprintf(hex + 2 * i, 3, "%02x", p[i]); }
    vxmac_log("Audio: HAL %s '%s' obj %u scope '%s' elem %u -> %d, %u bytes %s%s (%.1f s)", what, s, obj, sc, a ? a->elem : 0, (int)st, size, hex,
              g_synth ? " [answered by VX Mac]" : "", now_s());
}

// ---- VXMAC_AUDIO_HAL=0: the answers without the HAL -------------------------------------------------------------------
static uint32_t session_channels(void) {
    static uint32_t ch; if (ch) return ch;
    Class c = NSClassFromString(@"AVAudioSession"); long n = 0;
    if (c) { id s = ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("sharedInstance")); if (s) n = ((long (*)(id, SEL))objc_msgSend)(s, sel_registerName("outputNumberOfChannels")); }
    ch = n > 0 && n <= 16 ? (uint32_t)n : 2;
    return ch;
}
static double session_rate(void) {
    Class c = NSClassFromString(@"AVAudioSession"); double r = 0;
    if (c) { id s = ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("sharedInstance")); if (s) r = ((double (*)(id, SEL))objc_msgSend)(s, sel_registerName("sampleRate")); }
    return r > 0 ? r : 48000;
}
// (size, and the bytes when buf != NULL; 0 when known)
static OSStat synth(uint32_t obj, const HALAddr *a, uint32_t *size, void *buf) {
    uint8_t tmp[512]; uint32_t n = 0; memset(tmp, 0, sizeof tmp);
    if (obj == 1) {
        switch (a->sel) {
        case SEL_DOUT: case SEL_SOUT: { uint32_t v = FAKE_DEV; memcpy(tmp, &v, 4); n = 4; break; }
        case SEL_DIN: { n = 4; break; }                               // (kAudioObjectUnknown: no input)
        case SEL_DEVS: { uint32_t v = FAKE_DEV; memcpy(tmp, &v, 4); n = 4; break; }
        case SEL_RNLP: { n = sizeof(void *); break; }
        default: return ERR_WHO;
        }
    } else if (obj == FAKE_DEV) {
        uint32_t ch = a->scope == SCOPE_IN ? 0 : session_channels();
        switch (a->sel) {
        case SEL_SLAY: {   // AudioBufferList: mNumberBuffers, then {mNumberChannels, mDataByteSize, mData} at 8
            uint32_t nb = ch ? 1 : 0; memcpy(tmp, &nb, 4);
            if (nb) { memcpy(tmp + 8, &ch, 4); n = 24; } else n = 8;
            break; }
        case SEL_NAME: { const char *s = "VX Mac audio output"; n = (uint32_t)strlen(s) + 1; memcpy(tmp, s, n); break; }
        case SEL_LNAM: case SEL_UID: {
            CFStringRef s = CFStringCreateWithCString(NULL, a->sel == SEL_UID ? "VXMacAudioOutput" : "VX Mac audio output", kCFStringEncodingUTF8);
            n = sizeof s; if (buf && *size >= n) { memcpy(buf, &s, n); *size = n; return 0; }
            CFRelease(s); break; }
        case SEL_SRND: {   // AudioChannelLayout, UseChannelDescriptions: tag, bitmap, n, then {label, flags, coords[3]} each
            if (!ch) return ERR_WHO;
            static const uint32_t labels[8] = { 1, 2, 3, 4, 5, 6, 33, 34 };   // (L R C LFE Ls Rs Rls Rrs)
            uint32_t z = 0; memcpy(tmp, &z, 4); memcpy(tmp + 4, &z, 4); memcpy(tmp + 8, &ch, 4);
            for (uint32_t i = 0; i < ch && i < 16; i++) { uint32_t l = i < 8 ? labels[i] : 0; memcpy(tmp + 12 + 20 * i, &l, 4); }
            n = 12 + 20 * ch; break; }
        case SEL_DCH2: { uint32_t v[2] = { 1, 2 }; memcpy(tmp, v, 8); n = 8; break; }
        case SEL_NSRT: { double r = session_rate(); memcpy(tmp, &r, 8); n = 8; break; }
        case SEL_FSIZ: { uint32_t v = 512; memcpy(tmp, &v, 4); n = 4; break; }
        case SEL_LTNC: case SEL_SAFT: { n = 4; break; }
        case SEL_LIVN: { uint32_t v = 1; memcpy(tmp, &v, 4); n = 4; break; }
        default: return ERR_WHO;
        }
    } else return ERR_OBJ;
    if (buf) { uint32_t m = *size < n ? *size : n; memcpy(buf, tmp, m); *size = m; }
    else *size = n;
    return 0;
}

// ---- the program's GOT slots point here ---------------------------------------------------------------------------------
static OSStat w_get(uint32_t obj, const HALAddr *a, uint32_t qs, const void *q, uint32_t *size, void *data) {
    atomic_fetch_add(&n_get, 1); if (a) count_sel(a->sel);
    OSStat st;
    if (g_synth && a && size) { atomic_fetch_add(&n_synth, 1); st = synth(obj, a, size, data); }
    else st = r_get ? r_get(obj, a, qs, q, size, data) : ERR_WHO;
    log_call("get", obj, a, st, size ? *size : 0, data);
    return st;
}
static OSStat w_size(uint32_t obj, const HALAddr *a, uint32_t qs, const void *q, uint32_t *size) {
    atomic_fetch_add(&n_size, 1); if (a) count_sel(a->sel);
    OSStat st;
    if (g_synth && a && size) { atomic_fetch_add(&n_synth, 1); st = synth(obj, a, size, NULL); }
    else st = r_size ? r_size(obj, a, qs, q, size) : ERR_WHO;
    log_call("size", obj, a, st, size ? *size : 0, NULL);
    return st;
}
static OSStat w_set(uint32_t obj, const HALAddr *a, uint32_t qs, const void *q, uint32_t size, const void *data) {
    atomic_fetch_add(&n_set, 1); if (a) count_sel(a->sel);
    OSStat st;
    if (g_synth) { atomic_fetch_add(&n_synth, 1); st = obj == 1 || obj == FAKE_DEV ? 0 : ERR_OBJ; }
    else st = r_set ? r_set(obj, a, qs, q, size, data) : ERR_WHO;
    log_call("set", obj, a, st, size, data);
    return st;
}
static OSStat w_aus(void *unit, uint32_t prop, uint32_t scope, uint32_t elem, const void *data, uint32_t size) {
    atomic_fetch_add(&n_aus, 1);
    if (prop == 2000) {   // kAudioOutputUnitProperty_CurrentDevice
        uint32_t dev = data && size >= 4 ? *(const uint32_t *)data : 0;
        if (g_synth && dev == FAKE_DEV) { static int once; if (!once++) vxmac_log("Audio: an output unit's CurrentDevice -> VX Mac's device: answered, the unit keeps its own output"); return 0; }
        static atomic_int n; if (atomic_fetch_add(&n, 1) < 4) vxmac_log("Audio: AudioUnitSetProperty CurrentDevice %u (%.1f s)", dev, now_s());
    }
    return r_aus(unit, prop, scope, elem, data, size);
}
static OSStat w_addnode(void *graph, const ACDesc *d, int32_t *node) {
    atomic_fetch_add(&n_nodes, 1);
    ACDesc c = d ? *d : (ACDesc){0};
    char t[5], s[5], m[5]; cc(c.type, t); cc(c.subtype, s); cc(c.manu, m);
    if (g_synth && c.type == FOURCC('a','u','o','u') && c.subtype == FOURCC('d','e','f',' ')) {
        c.subtype = FOURCC('r','i','o','c');
        vxmac_log("Audio: AUGraph node %s/%s/%s -> RemoteIO (VXMAC_AUDIO_HAL=0)", t, s, m);
        return r_addnode(graph, &c, node);
    }
    vxmac_log("Audio: AUGraph node %s/%s/%s (%.1f s)", t, s, m, now_s());
    return r_addnode(graph, d, node);
}
static OSStat w_gstart(void *graph) {
    atomic_fetch_add(&n_gstart, 1);
    OSStat st = r_gstart(graph);
    vxmac_log("Audio: AUGraphStart -> %d (%.1f s)", (int)st, now_s());
    return st;
}

// ---- GOT slots: an image's pointer to one of the functions above -> ours -----------------------------------------------
static struct { void **real; void *ours; const char *name; } g_targets[6];
static int g_ntargets;
static atomic_int g_slots;
static void patch_image(const struct mach_header_64 *mh, intptr_t slide) {
    if (!mh || mh->magic != MH_MAGIC_64 || (mh->flags & 0x80000000u /* MH_DYLIB_IN_CACHE */) || !g_ntargets) return;
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, p += ((const struct load_command *)p)->cmdsize) {
        const struct segment_command_64 *sg = (const struct segment_command_64 *)p;
        if (sg->cmd != LC_SEGMENT_64 || strncmp(sg->segname, "__DATA", 6)) continue;
        const struct section_64 *sc = (const struct section_64 *)(sg + 1);
        for (uint32_t j = 0; j < sg->nsects; j++, sc++) {
            uint32_t ty = sc->flags & SECTION_TYPE;
            if (ty != S_NON_LAZY_SYMBOL_POINTERS && ty != S_LAZY_SYMBOL_POINTERS && strcmp(sc->sectname, "__got")) continue;
            void **slot = (void **)(sc->addr + slide); size_t cnt = sc->size / sizeof(void *);
            for (size_t k = 0; k < cnt; k++) for (int t = 0; t < g_ntargets; t++) {
                if (!*g_targets[t].real || slot[k] != *g_targets[t].real) continue;
                vm_address_t pg = (vm_address_t)&slot[k] & ~(vm_address_t)(vm_page_size - 1);
                vm_region_basic_info_data_64_t bi; mach_msg_type_number_t ic = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t on = MACH_PORT_NULL;
                vm_address_t ra = pg; vm_size_t rs = 0; vm_prot_t was = VM_PROT_READ;
                if (vm_region_64(mach_task_self(), &ra, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi, &ic, &on) == KERN_SUCCESS) was = bi.protection;
                int writable = (was & VM_PROT_WRITE) != 0;
                if (!writable && vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
                    vxmac_log("Audio: GOT slot of %s not writable: not counted", g_targets[t].name); continue; }
                slot[k] = g_targets[t].ours;
                if (!writable) vm_protect(mach_task_self(), pg, vm_page_size, 0, was);
                atomic_fetch_add(&g_slots, 1);
            }
        }
    }
}
void vxaudio_hook_image(const void *mh) {   // (the host after dlopen as well: idempotent)
    Dl_info di; intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) if (_dyld_get_image_header(i) == mh) { slide = _dyld_get_image_vmaddr_slide(i); break; }
    int before = atomic_load(&g_slots);
    patch_image((const struct mach_header_64 *)mh, slide);
    int now = atomic_load(&g_slots);
    if (now > before) vxmac_log("Audio: %d HAL / AudioUnit imports of %s go through VX Mac's counters%s", now - before,
                                dladdr(mh, &di) && di.dli_fname ? (strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname) : "?",
                                g_synth ? " (VXMAC_AUDIO_HAL=0: the HAL is not called)" : "");
}

// ---- who loads a HAL plug-in ---------------------------------------------------------------------------------------------
static atomic_int g_initial = 1;
typedef struct { const void *mh; double t; int nf; void *frames[28]; char thr[64]; } load_rec;
static void report_load(load_rec *r) {
    Dl_info di; const char *path = dladdr(r->mh, &di) && di.dli_fname ? di.dli_fname : NULL;
    if (!path || (!strstr(path, "/Audio/Plug-Ins/") && !strstr(path, "BTAudio"))) { free(r); return; }
    const char *base = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
    atomic_fetch_add(&g_plugins, 1);
    if (strstr(base, "BTAudio")) { double x = -1; atomic_compare_exchange_strong(&g_bt_at, &x, r->t); }
    char st[2600]; size_t k = 0; st[0] = 0;
    for (int i = 2; i < r->nf && k < sizeof st - 120; i++) {   // (0, 1: this watcher and dyld's notifier)
        Dl_info f; const char *im = "?", *sym = ""; uintptr_t off = (uintptr_t)r->frames[i];
        if (dladdr(r->frames[i], &f) && f.dli_fname) { im = strrchr(f.dli_fname, '/') ? strrchr(f.dli_fname, '/') + 1 : f.dli_fname; off -= (uintptr_t)f.dli_fbase; sym = f.dli_sname ? f.dli_sname : ""; }
        k += (size_t)snprintf(st + k, sizeof st - k, "%s%s+0x%lx%s%.40s", k ? " < " : "", im, (unsigned long)off, *sym ? " " : "", sym);
    }
    vxmac_log("Audio: HAL plug-in loaded %s at %.1f s on thread %s, from: %s", base, r->t, r->thr, st);
    free(r);
}
static void on_add_image(const struct mach_header *mh, intptr_t slide) {
    if (!(((const struct mach_header_64 *)mh)->flags & 0x80000000u)) patch_image((const struct mach_header_64 *)mh, slide);
    // (dyld's lock is held here: the stack only; the path, the symbols and the log on a queue)
    if (atomic_load(&g_initial)) return;   // (the images already in at registration: not loads)
    load_rec *r = malloc(sizeof *r); if (!r) return;
    r->mh = mh; r->t = now_s(); r->nf = backtrace(r->frames, 28);
    r->thr[0] = 0; pthread_getname_np(pthread_self(), r->thr, sizeof r->thr);
    if (!r->thr[0]) snprintf(r->thr, sizeof r->thr, "%s", pthread_main_np() ? "main" : "(unnamed)");
    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), r, (dispatch_function_t)report_load);
}

__attribute__((constructor)) static void vxaudio_init(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); g_t0 = ts.tv_sec + ts.tv_nsec * 1e-9;
    const char *w = getenv("VXMAC_AUDIO_WATCH"); if (w && !strcmp(w, "0")) return;
    const char *h = getenv("VXMAC_AUDIO_HAL"); g_synth = !(h && !strcmp(h, "1"));   // (h67: on by default; =1 the HAL as before)
    void *ca = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_LAZY);
    void *at = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY);
    if (ca) { r_get = (get_fn)dlsym(ca, "AudioObjectGetPropertyData"); r_size = (size_fn)dlsym(ca, "AudioObjectGetPropertyDataSize"); r_set = (set_fn)dlsym(ca, "AudioObjectSetPropertyData"); }
    if (at) { r_aus = (aus_fn)dlsym(at, "AudioUnitSetProperty"); r_addnode = (addnode_fn)dlsym(at, "AUGraphAddNode"); r_gstart = (gstart_fn)dlsym(at, "AUGraphStart"); }
#define T(r, o, n) if (r) { g_targets[g_ntargets].real = (void **)&r; g_targets[g_ntargets].ours = (void *)o; g_targets[g_ntargets].name = n; g_ntargets++; }
    T(r_get, w_get, "AudioObjectGetPropertyData") T(r_size, w_size, "AudioObjectGetPropertyDataSize") T(r_set, w_set, "AudioObjectSetPropertyData")
    T(r_aus, w_aus, "AudioUnitSetProperty") T(r_addnode, w_addnode, "AUGraphAddNode") T(r_gstart, w_gstart, "AUGraphStart")
#undef T
    _dyld_register_func_for_add_image(on_add_image);   // (called for every image already in, then for each load)
    atomic_store(&g_initial, 0);
    vxmac_log("Audio: HAL watch on (%d functions)%s", g_ntargets, g_synth ? "; VXMAC_AUDIO_HAL=0: the program's HAL questions answered without the HAL" : "");
}

// ---- the busiest threads (each mem line): CPU since the last sample; the busiest one's stack, sampled ------------------
#define NTHR 192
static struct { uint64_t id; double cpu; } g_thr[NTHR]; static int g_nthr; static double g_thr_t;
static char g_top_short[160] = "";
static void thread_top(char *out, unsigned size) {
    thread_act_array_t th = NULL; mach_msg_type_number_t n = 0; out[0] = 0;
    if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) { snprintf(out, size, "\"thr_top\":[]"); return; }
    double t = now_s(), dt = g_thr_t > 0 ? t - g_thr_t : 0;
    struct { thread_t port; uint64_t id; double pct; } best[3] = {{0}};
    static __typeof__(g_thr) cur; int nc = 0; mach_port_t self = mach_thread_self();
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_basic_info_data_t bi; mach_msg_type_number_t c = THREAD_BASIC_INFO_COUNT;
        thread_identifier_info_data_t ii; mach_msg_type_number_t c2 = THREAD_IDENTIFIER_INFO_COUNT;
        if (thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &c) != KERN_SUCCESS || thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &c2) != KERN_SUCCESS) continue;
        double cpu = bi.user_time.seconds + bi.user_time.microseconds * 1e-6 + bi.system_time.seconds + bi.system_time.microseconds * 1e-6;
        double prev = -1; for (int k = 0; k < g_nthr; k++) if (g_thr[k].id == ii.thread_id) { prev = g_thr[k].cpu; break; }
        if (nc < NTHR) { cur[nc].id = ii.thread_id; cur[nc].cpu = cpu; nc++; }
        if (dt <= 0 || prev < 0) continue;
        double pct = (cpu - prev) / dt * 100;
        for (int b = 0; b < 3; b++) if (pct > best[b].pct) { memmove(&best[b + 1], &best[b], sizeof best[0] * (size_t)(2 - b)); best[b].port = th[i]; best[b].id = ii.thread_id; best[b].pct = pct; break; }
    }
    memcpy(g_thr, cur, sizeof cur[0] * (size_t)nc); g_nthr = nc; g_thr_t = t;
    // (the busiest thread's stack: suspended only while its registers and frame records are read - no allocation then)
    uintptr_t pcs[12]; int npc = 0;
    if (best[0].port && best[0].port != self && best[0].pct >= 20 && thread_suspend(best[0].port) == KERN_SUCCESS) {
        arm_thread_state64_t ts; mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(best[0].port, ARM_THREAD_STATE64, (thread_state_t)&ts, &sc) == KERN_SUCCESS) {
            const uintptr_t mask = 0x0000007fffffffffULL;
            pcs[npc++] = (uintptr_t)arm_thread_state64_get_pc(ts) & mask; pcs[npc++] = (uintptr_t)arm_thread_state64_get_lr(ts) & mask;
            uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(ts) & mask;
            while (fp && npc < 12) {
                uintptr_t rec[2]; vm_size_t got = 0;
                if (vm_read_overwrite(mach_task_self(), fp, sizeof rec, (vm_address_t)rec, &got) != KERN_SUCCESS || got != sizeof rec) break;
                if (rec[1]) pcs[npc++] = rec[1] & mask;
                if ((rec[0] & mask) <= fp) break;
                fp = rec[0] & mask;
            }
        }
        thread_resume(best[0].port);
    }
    size_t k = (size_t)snprintf(out, size, "\"thr_top\":[");
    for (int b = 0; b < 3 && best[b].port; b++) {
        char nm[64] = ""; pthread_t pt = pthread_from_mach_thread_np(best[b].port); if (pt) pthread_getname_np(pt, nm, sizeof nm);
        for (char *c = nm; *c; c++) if (*c == '"' || *c == '\\') *c = '?';
        k += (size_t)snprintf(out + k, k < size ? size - k : 0, "%s[\"%s\",%llu,%.0f", b ? "," : "", nm, (unsigned long long)best[b].id, best[b].pct);
        if (b == 0 && npc) {
            k += (size_t)snprintf(out + k, k < size ? size - k : 0, ",\"");
            g_top_short[0] = 0;
            for (int i = 0; i < npc; i++) {
                Dl_info f; const char *im = "?"; uintptr_t off = pcs[i];
                if (dladdr((void *)pcs[i], &f) && f.dli_fname) { im = strrchr(f.dli_fname, '/') ? strrchr(f.dli_fname, '/') + 1 : f.dli_fname; off -= (uintptr_t)f.dli_fbase; }
                k += (size_t)snprintf(out + k, k < size ? size - k : 0, "%s%s+0x%lx", i ? "<" : "", im, (unsigned long)off);
                // (the short form: the frame on top and the first one outside libsystem / libobjc / libdispatch / CoreFoundation)
                static int have2;
                if (i == 0) { have2 = 0; snprintf(g_top_short, sizeof g_top_short, "%.0f%% %.40s+0x%lx", best[b].pct, im, (unsigned long)off); }
                else if (!have2 && strncmp(im, "libsystem", 9) && strncmp(im, "libdispatch", 11) && strncmp(im, "libobjc", 7) && strcmp(im, "CoreFoundation")) {
                    have2 = 1; size_t l = strlen(g_top_short); snprintf(g_top_short + l, sizeof g_top_short - l, " < %.40s+0x%lx", im, (unsigned long)off); }
            }
            k += (size_t)snprintf(out + k, k < size ? size - k : 0, "\"");
        }
        k += (size_t)snprintf(out + k, k < size ? size - k : 0, "]");
    }
    if (k < size) snprintf(out + k, size - k, "]");
    for (mach_msg_type_number_t i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), th[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)th, sizeof(thread_t) * n);
    mach_port_deallocate(mach_task_self(), self);
}

// ---- the stats: slot 0 the mem line (with the threads), 1 vxmac_now.json (short) ----------------------------------------
void vxaudio_stats(char *out, unsigned size, int slot) {
    static double lt[2]; static unsigned long ln[2];
    double t = now_s();
    unsigned long g = atomic_load(&n_get), z = atomic_load(&n_size), s = atomic_load(&n_set), a = atomic_load(&n_aus), all = g + z + s;
    double per_s = lt[slot & 1] > 0 && t > lt[slot & 1] ? (double)(all - ln[slot & 1]) / (t - lt[slot & 1]) : 0;
    lt[slot & 1] = t; ln[slot & 1] = all;
    if (slot == 1) {
        snprintf(out, size, "\"audio_hal\":{\"calls\":%lu,\"per_s\":%.1f,\"aus\":%lu,\"plugins\":%d,\"bt_at\":%.1f,\"synth\":%d},\"thr_top\":\"%s\"",
                 all, per_s, a, atomic_load(&g_plugins), atomic_load(&g_bt_at), g_synth, g_top_short);
        return;
    }
    char top[300] = ""; size_t k = 0;
    unsigned long used[NSEL] = {0};
    for (int r = 0; r < 4; r++) {
        int bi = -1; for (int i = 0; i < NSEL; i++) { unsigned long v = atomic_load(&s_n[i]); if (v && !used[i] && (bi < 0 || v > atomic_load(&s_n[bi]))) bi = i; }
        if (bi < 0) break; used[bi] = 1; char c4[5]; cc(atomic_load(&s_sel[bi]), c4);
        k += (size_t)snprintf(top + k, sizeof top - k, "%s[\"%s\",%lu]", r ? "," : "", c4, atomic_load(&s_n[bi]));
    }
    char th[1000]; thread_top(th, sizeof th);
    snprintf(out, size, "\"audio_hal\":{\"get\":%lu,\"size\":%lu,\"set\":%lu,\"per_s\":%.1f,\"aus\":%lu,\"nodes\":%lu,\"graph_starts\":%lu,\"slots\":%d,"
             "\"synth\":%d,\"answered\":%lu,\"top\":[%s],\"plugins\":%d,\"bt_at\":%.1f},%s",
             g, z, s, per_s, a, atomic_load(&n_nodes), atomic_load(&n_gstart), atomic_load(&g_slots), g_synth, atomic_load(&n_synth), top,
             atomic_load(&g_plugins), atomic_load(&g_bt_at), th);
}
