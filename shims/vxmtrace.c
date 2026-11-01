// vxmtrace.c (h64) - who holds the malloc growth: sampled allocation stacks still live (VXMAC_MALLOC_TRACE=<N>; off when
// unset or 0).
//
// ddgame63d's 30 min run: malloc_small grew 99 -> 976 MB at ~9000 blocks a second (~50 bytes each), steadily, whatever
// the game's frame rate, the mode (screen / vr) or the pipeline creations did; the game's pools (untagged) levelled off
// at 3.27 GB. The "mem" line has the zone totals only. Here libmalloc's own logger hook (malloc_logger, the one
// MallocStackLogging uses) sees every allocation and free of every zone: one in N addresses (by a hash of the address,
// so its free is told by the same test, no lookup for the others) is kept with its size and the caller's stack (the
// frame-pointer chain, 20 frames at most); a free takes it off. Per distinct stack: live blocks and bytes. Everything in
// fixed tables mapped once (no malloc inside the hook). The host asks for the totals in each "mem" line ("mtrace": the
// live estimate (sampled x N) and the three stacks holding the most, by their first frame outside the allocators) and
// writes Documents/malloc_trace.txt every 60 s: the 30 stacks holding the most, each frame as image+offset (symbol),
// with each stack's growth since the previous dump. Cost: one multiply-shift per malloc / free; the 1-in-N take a lock
// and walk the stack.
#include <dlfcn.h>
#include <malloc/malloc.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t skip);
extern malloc_logger_t *malloc_logger;   // (libsystem_malloc: exported on macOS and visionOS)
enum { LOG_ALLOC = 2, LOG_DEALLOC = 4, LOG_HAS_ZONE = 8, LOG_VM = 16 | 32 };

#define MT_FRAMES 20
#define MT_LIVE_BITS 20          // (1M sampled blocks at most: 16 MB mapped, touched as used)
#define MT_STACK_BITS 16         // (65536 distinct stacks: 13 MB mapped, touched as used)
typedef struct { uintptr_t p; uint32_t size, stack; } mt_live;
typedef struct { uint64_t h; uint32_t depth, used; int64_t blocks, bytes, prev_bytes; uintptr_t f[MT_FRAMES]; } mt_stack;
static mt_live *g_live; static mt_stack *g_st;
static uint64_t g_mask_live, g_mask_st;
static uint64_t g_rate;          // (1 in g_rate addresses)
static os_unfair_lock g_l = OS_UNFAIR_LOCK_INIT;
static int64_t g_live_n, g_live_bytes, g_st_n;
static _Atomic uint64_t g_dropped, g_samples;
static double g_prev_t;
static malloc_logger_t *g_prev_logger;

static inline uint64_t mix(uint64_t x) { x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33; x *= 0xc4ceb9fe1a85ec53ULL; x ^= x >> 33; return x; }
static inline int sampled(uintptr_t p) { return p && (mix(p) % g_rate) == 0; }
static inline uintptr_t strip(uintptr_t v) {   // (a return address without its pointer-authentication bits: XPACLRI)
#if defined(__arm64__)
    register uintptr_t x30 __asm("x30") = v;
    __asm__ volatile("hint #7" : "+r"(x30));
    return x30;
#else
    return v;
#endif
}
__attribute__((noinline)) static uint32_t stack_id(void) {   // (with g_l held; not inlined: the frames skipped below are its own and live_add's)
    uintptr_t f[MT_FRAMES]; uint32_t n = 0;
    pthread_t self = pthread_self();
    uintptr_t hi = (uintptr_t)pthread_get_stackaddr_np(self), lo = hi - pthread_get_stacksize_np(self);
    uintptr_t *fp = (uintptr_t *)__builtin_frame_address(0);
    int skip = 2;   // (into live_add, into the logger: the allocator's own frames come next)
    while (n < MT_FRAMES && (uintptr_t)fp > lo && (uintptr_t)fp + 16 <= hi && !((uintptr_t)fp & 7)) {
        uintptr_t ret = strip(fp[1]);
        if (!ret) break;
        if (skip > 0) skip--; else f[n++] = ret;
        uintptr_t *next = (uintptr_t *)fp[0];
        if (next <= fp) break;
        fp = next;
    }
    uint64_t h = 0x9e3779b97f4a7c15ULL ^ n;
    for (uint32_t i = 0; i < n; i++) h = mix(h ^ f[i]);
    uint64_t k = h & g_mask_st;
    for (uint64_t probe = 0; probe <= g_mask_st; probe++, k = (k + 1) & g_mask_st) {
        mt_stack *s = &g_st[k];
        if (s->used && s->h == h && s->depth == n) return (uint32_t)k;
        if (!s->used) {
            if (g_st_n * 4 >= (int64_t)(g_mask_st + 1) * 3) return UINT32_MAX;
            s->used = 1; s->h = h; s->depth = n; memcpy(s->f, f, n * sizeof *f); g_st_n++;
            return (uint32_t)k;
        }
    }
    return UINT32_MAX;
}
__attribute__((noinline)) static void live_add(uintptr_t p, size_t size) {   // (with g_l held)
    if (g_live_n * 4 >= (int64_t)(g_mask_live + 1) * 3) { g_dropped++; return; }
    uint32_t sid = stack_id();
    if (sid == UINT32_MAX) { g_dropped++; return; }
    uint64_t k = mix(p * 31) & g_mask_live;
    while (g_live[k].p && g_live[k].p != p) k = (k + 1) & g_mask_live;
    if (g_live[k].p == p) { mt_stack *o = &g_st[g_live[k].stack]; o->blocks--; o->bytes -= g_live[k].size; g_live_n--; g_live_bytes -= g_live[k].size; }   // (a free we missed)
    g_live[k].p = p; g_live[k].size = (uint32_t)(size > UINT32_MAX ? UINT32_MAX : size); g_live[k].stack = sid;
    g_st[sid].blocks++; g_st[sid].bytes += g_live[k].size; g_live_n++; g_live_bytes += g_live[k].size;
    g_samples++;
}
static void live_del(uintptr_t p) {   // (with g_l held; linear probing, the entries after it shifted back)
    uint64_t k = mix(p * 31) & g_mask_live;
    while (g_live[k].p && g_live[k].p != p) k = (k + 1) & g_mask_live;
    if (!g_live[k].p) return;
    mt_stack *s = &g_st[g_live[k].stack]; s->blocks--; s->bytes -= g_live[k].size; g_live_n--; g_live_bytes -= g_live[k].size;
    uint64_t i = k, j = k;
    for (;;) {
        g_live[i].p = 0;
        for (;;) {
            j = (j + 1) & g_mask_live;
            if (!g_live[j].p) return;
            uint64_t home = mix(g_live[j].p * 31) & g_mask_live;
            if (i <= j ? (i < home && home <= j) : (i < home || home <= j)) continue;   // (stays: its home is between)
            break;
        }
        g_live[i] = g_live[j]; i = j;
    }
}
static void logger(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t result, uint32_t skip) {
    if (g_prev_logger) g_prev_logger(type, a1, a2, a3, result, skip);
    if (type & LOG_VM) return;
    uintptr_t freed = 0, made = 0; size_t size = 0;
    if ((type & LOG_ALLOC) && (type & LOG_DEALLOC)) { freed = a2; made = result; size = a3; }   // (realloc: zone, old, size -> new)
    else if (type & LOG_ALLOC) { made = result; size = a2; }                                   // (malloc / calloc / memalign: zone, size)
    else if (type & LOG_DEALLOC) freed = (type & LOG_HAS_ZONE) ? a2 : a1;                       // (free: zone, ptr)
    int sf = sampled(freed), sm = sampled(made);
    if (!sf && !sm) return;
    os_unfair_lock_lock(&g_l);
    if (sf) live_del(freed);
    if (sm) live_add(made, size);
    os_unfair_lock_unlock(&g_l);
}

int vxsys_mtrace_on(void) { return g_live != NULL; }
int vxsys_mtrace_start(unsigned rate) {
    if (g_live || !rate) return g_live != NULL;
    size_t nl = (size_t)1 << MT_LIVE_BITS, ns = (size_t)1 << MT_STACK_BITS;
    void *a = mmap(NULL, nl * sizeof(mt_live), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    void *b = mmap(NULL, ns * sizeof(mt_stack), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (a == MAP_FAILED || b == MAP_FAILED) return 0;
    g_mask_live = nl - 1; g_mask_st = ns - 1; g_rate = rate; g_st = b;
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); g_prev_t = ts.tv_sec + ts.tv_nsec * 1e-9;
    g_live = a;
    g_prev_logger = malloc_logger;
    malloc_logger = logger;
    return 1;
}
__attribute__((constructor)) static void mtrace_init(void) {
    const char *e = getenv("VXMAC_MALLOC_TRACE");
    if (e && atoi(e) > 0 && vxsys_mtrace_start((unsigned)atoi(e)))
        fprintf(stderr, "vxmac: malloc trace on: 1 in %d addresses, stacks of up to %d frames\n", atoi(e), MT_FRAMES);
}

// (a frame as "image+0xoffset symbol")
static void frame_str(uintptr_t a, char *o, size_t n) {
    Dl_info d;
    if (dladdr((void *)a, &d) && d.dli_fname) {
        const char *base = strrchr(d.dli_fname, '/'); base = base ? base + 1 : d.dli_fname;
        if (d.dli_sname && d.dli_saddr) snprintf(o, n, "%s+%#lx %s+%lu", base, (unsigned long)(a - (uintptr_t)d.dli_fbase), d.dli_sname, (unsigned long)(a - (uintptr_t)d.dli_saddr));
        else snprintf(o, n, "%s+%#lx", base, (unsigned long)(a - (uintptr_t)d.dli_fbase));
    } else snprintf(o, n, "%#lx", (unsigned long)a);
}
static int is_alloc_frame(uintptr_t a) {   // (the allocators' own frames, skipped to name a stack by its caller)
    Dl_info d;
    if (!dladdr((void *)a, &d) || !d.dli_fname) return 0;
    const char *b = strrchr(d.dli_fname, '/'); b = b ? b + 1 : d.dli_fname;
    if (!strcmp(b, "libsystem_malloc.dylib") || !strcmp(b, "libobjc.A.dylib")) return 1;
    if (d.dli_sname && (strstr(d.dli_sname, "alloc") || strstr(d.dli_sname, "operator new") || !strcmp(d.dli_sname, "_Znwm") || !strncmp(d.dli_sname, "_Zn", 3) ||
                        strstr(d.dli_sname, "swift_allocObject") || strstr(d.dli_sname, "swift_slowAlloc") || strstr(d.dli_sname, "_CFRuntimeCreateInstance"))) return 1;
    return 0;
}
typedef struct { uint32_t k; int64_t bytes, blocks, prev; } mt_top;
static int top_of(mt_top *t, int max) {   // (the stacks holding the most, a snapshot under the lock)
    int n = 0;
    os_unfair_lock_lock(&g_l);
    for (uint64_t k = 0; k <= g_mask_st; k++) {
        mt_stack *s = &g_st[k];
        if (!s->used || s->bytes <= 0) continue;
        if (n < max) { t[n].k = (uint32_t)k; t[n].bytes = s->bytes; t[n].blocks = s->blocks; t[n].prev = s->prev_bytes; n++; }
        else if (s->bytes > t[max - 1].bytes) { t[max - 1].k = (uint32_t)k; t[max - 1].bytes = s->bytes; t[max - 1].blocks = s->blocks; t[max - 1].prev = s->prev_bytes; }
        else continue;
        for (int i = (n < max ? n : max) - 1; i > 0 && t[i].bytes > t[i - 1].bytes; i--) { mt_top x = t[i]; t[i] = t[i - 1]; t[i - 1] = x; }
    }
    os_unfair_lock_unlock(&g_l);
    return n;
}
static void caller_str(uint32_t k, char *o, size_t n) {
    mt_stack s; os_unfair_lock_lock(&g_l); s = g_st[k]; os_unfair_lock_unlock(&g_l);
    uint32_t i = 0; while (i + 1 < s.depth && is_alloc_frame(s.f[i])) i++;
    if (s.depth) frame_str(s.f[i], o, n); else snprintf(o, n, "?");
    for (char *c = o; *c; c++) if (*c == '"' || *c == '\\') *c = '\'';
}
// (for the "mem" line: "mtrace":{"rate":N,"est_mb":..,"est_blocks":..,"stacks":..,"dropped":..,"top":[[caller,MB],...]})
void vxsys_mtrace_stats(char *out, unsigned n) {
    if (!g_live) { snprintf(out, n, "\"mtrace\":0"); return; }
    mt_top t[3]; int nt = top_of(t, 3);
    int64_t lb, ln, sn; os_unfair_lock_lock(&g_l); lb = g_live_bytes; ln = g_live_n; sn = g_st_n; os_unfair_lock_unlock(&g_l);
    size_t k = (size_t)snprintf(out, n, "\"mtrace\":{\"rate\":%llu,\"est_mb\":%.1f,\"est_blocks\":%lld,\"stacks\":%lld,\"dropped\":%llu,\"top\":[",
                                (unsigned long long)g_rate, lb * (double)g_rate / 1048576.0, (long long)(ln * (int64_t)g_rate), (long long)sn, (unsigned long long)g_dropped);
    for (int i = 0; i < nt && k < n; i++) {
        char c[200]; caller_str(t[i].k, c, sizeof c);
        k += (size_t)snprintf(out + k, n - k, "%s[\"%s\",%.1f]", i ? "," : "", c, t[i].bytes * (double)g_rate / 1048576.0);
    }
    if (k < n) snprintf(out + k, n - k, "]}");
}
// (the report: the 30 stacks holding the most, their growth since the last report; written to path through a temporary
//  file and a rename)
int vxsys_mtrace_dump(const char *path) {
    if (!g_live || !path) return 0;
    enum { NT = 30 };
    mt_top t[NT]; int nt = top_of(t, NT);
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); double now = ts.tv_sec + ts.tv_nsec * 1e-9, dt = now - g_prev_t; g_prev_t = now;
    char tmp[1100]; snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return 0;
    int64_t lb, ln, sn; os_unfair_lock_lock(&g_l); lb = g_live_bytes; ln = g_live_n; sn = g_st_n; os_unfair_lock_unlock(&g_l);
    double r = (double)g_rate;
    fprintf(f, "malloc trace: 1 in %llu addresses; live (estimate) %.1f MB in %lld blocks; %lld stacks; %llu samples, %llu dropped; %.0f s since the last report\n",
            (unsigned long long)g_rate, lb * r / 1048576.0, (long long)(ln * (int64_t)g_rate), (long long)sn, (unsigned long long)g_samples, (unsigned long long)g_dropped, dt);
    for (int i = 0; i < nt; i++) {
        mt_stack s; os_unfair_lock_lock(&g_l); s = g_st[t[i].k]; g_st[t[i].k].prev_bytes = g_st[t[i].k].bytes; os_unfair_lock_unlock(&g_l);
        fprintf(f, "\n#%d live %.2f MB, %lld blocks, %.0f B each, %+.2f MB/min since the last report\n", i + 1, t[i].bytes * r / 1048576.0,
                (long long)(t[i].blocks * (int64_t)g_rate), t[i].blocks ? (double)t[i].bytes / t[i].blocks : 0, dt > 0 ? (t[i].bytes - t[i].prev) * r / 1048576.0 / dt * 60 : 0);
        for (uint32_t j = 0; j < s.depth; j++) { char fs[300]; frame_str(s.f[j], fs, sizeof fs); fprintf(f, "  %2u %s\n", j, fs); }
    }
    fclose(f);
    return rename(tmp, path) == 0;
}
