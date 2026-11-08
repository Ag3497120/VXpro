// libvxsystem: libSystem re-exported (for the images prepared with --system-shim: the game executable and
// libGameServicesAppStore), and two names changed for them:
//   - syslog$DARWIN_EXTSN: the macOS variant name of syslog that visionOS's libsystem_c does not export (same
//     arguments: forwarded to vsyslog);
//   - _NSGetExecutablePath: the path the program's own install would have (VXMAC_EXECUTABLE_PATH, set by VX Mac Host:
//     Documents/<Game>.app/Contents/MacOS/<exe>, a placeholder file beside the game's Contents/Data), so a game that
//     finds its data from its executable's path finds the copy in Documents. Without the variable: the real one.
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
void vx_syslog_extsn(int pri, const char *fmt, ...) __asm("_syslog$DARWIN_EXTSN");
void vx_syslog_extsn(int pri, const char *fmt, ...) { va_list ap; va_start(ap, fmt); vsyslog(pri, fmt, ap); va_end(ap); }

int _NSGetExecutablePath(char *buf, uint32_t *size) {
    const char *p = getenv("VXMAC_EXECUTABLE_PATH");
    if (p && *p) {
        uint32_t n = (uint32_t)strlen(p) + 1;
        if (*size < n) { *size = n; return -1; }
        memcpy(buf, p, n);
        return 0;
    }
    static int (*real)(char *, uint32_t *);
    if (!real) real = (int (*)(char *, uint32_t *))dlsym(dlopen("/usr/lib/system/libdyld.dylib", RTLD_NOLOAD | RTLD_LAZY), "_NSGetExecutablePath");
    return real ? real(buf, size) : -1;
}

// - readdir: a symbolic link listed as what it points to (DT_REG / DT_DIR), as the game's file scan keeps only
//   regular files and directories: so a data directory can be a tree of links to the game's files (the visionOS
//   simulator's run reads the Mac install in place). opendir/closedir keep each stream's path for the stat.
//   VXMAC_TRACE_FS=1: each opendir logged.
#include <dirent.h>
#include <pthread.h>
#include <sys/stat.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include "network_ca_path.h"
static struct { DIR *d; char *path; } g_dirs[64];
static pthread_mutex_t g_dirs_lock = PTHREAD_MUTEX_INITIALIZER;
static void *libsys(const char *name) { return dlsym(dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOLOAD | RTLD_LAZY), name); }

static void overlay_open_notice(const char *overlay) {
    const char *name = strrchr(overlay, '/');
    if (!name) return;
    if (!strcmp(name,"/cert.pem")) return;
    static unsigned logged;
    if (!strcmp(name, "/final.redscripts")) {
        void (*poll)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "vx_weapon_bridge_poll");
        if (poll) poll();
    }
    unsigned bit = !strcmp(name, "/inputContexts.xml") ? 1u :
                   !strcmp(name, "/inputUserMappings.xml") ? 2u : 4u;
    if (!(__atomic_fetch_or(&logged, bit, __ATOMIC_RELAXED) & bit))
        fprintf(stderr, "vxmac: VX Hands opened %s\n", overlay);
}
static int has_suffix(const char *path, const char *suffix) {
    size_t n = strlen(path), m = strlen(suffix);
    return n >= m && !strcmp(path + n - m, suffix) && (n == m || path[n - m - 1] == '/');
}
// Optional per-user script overlay. The original game data stays untouched; a missing overlay falls back to the game.
static const char *script_overlay(const char *path, char out[2048]) {
    const char *enabled = getenv("VXMAC_NO_AUTO_RELOAD"), *home = getenv("HOME"), *custom = getenv("VXMAC_SCRIPT_OVERLAY");
    const char *directory=getenv("VXMAC_MANUAL_MAG_DIR");
    if (!enabled || strcmp(enabled, "1") || !path || (!home && !custom && !directory)) return path;
    static int (*real_access)(const char *, int);
    if (!real_access) real_access = (int (*)(const char *, int))libsys("access");
    if (!real_access) return path;
    const char *manual = getenv("VXMAC_MANUAL_MAG_ACTIVE");
    int script = has_suffix(path, "r6/cache/final.redscripts");
    int k;
    if (manual && !strcmp(manual, "1") && (home || (directory && directory[0]=='/'))) {
        const char *name = script ? "final.redscripts" :
                           has_suffix(path, "r6/config/inputUserMappings.xml") ? "inputUserMappings.xml" :
                           has_suffix(path, "r6/config/inputContexts.xml") ? "inputContexts.xml" : NULL;
        if (!name) return path;
        k = directory && directory[0]=='/' ? snprintf(out,2048,"%s/%s",directory,name) :
            snprintf(out, 2048, "%s/Documents/vxhands_manual/%s", home, name);
    } else {
        if (!script) return path;
        k = custom && custom[0] == '/' ? snprintf(out, 2048, "%s", custom) :
            home ? snprintf(out, 2048, "%s/Documents/vxhands_no_auto_reload.redscripts", home) : -1;
    }
    if (k < 0 || k >= 2048) return path;
    if (real_access(out, R_OK)) return path;
    return out;
}
static const char *read_overlay(const char *path,char out[2048]) {
    const char *ca=vx_network_ca_path(path,1,getenv("VXMAC_NETWORK"),getenv("HOME"),out,2048);
    return ca!=path ? ca:script_overlay(path,out);
}

int open(const char *path, int flags, ...) {
    static int (*real_open)(const char *, int, ...);
    if (!real_open) real_open = (int (*)(const char *, int, ...))libsys("open");
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    char overlay[2048];
    if ((flags & O_ACCMODE) == O_RDONLY && !(flags & (O_CREAT | O_TRUNC))) path = read_overlay(path, overlay);
    int fd = (flags & O_CREAT) ? real_open(path, flags, mode) : real_open(path, flags);
    if (fd >= 0 && path == overlay) overlay_open_notice(path);
    return fd;
}
FILE *fopen(const char *path, const char *mode) {
    static FILE *(*real_fopen)(const char *, const char *);
    if (!real_fopen) real_fopen = (FILE *(*)(const char *, const char *))libsys("fopen");
    char overlay[2048];
    if (mode && mode[0] == 'r' && !strchr(mode, '+')) path = read_overlay(path, overlay);
    FILE *file = real_fopen(path, mode);
    if (file && path == overlay) overlay_open_notice(path);
    return file;
}
int stat(const char *path, struct stat *st) {
    static int (*real_stat)(const char *, struct stat *);
    if (!real_stat) real_stat = (int (*)(const char *, struct stat *))libsys("stat");
    char overlay[2048]; return real_stat(read_overlay(path, overlay), st);
}
int lstat(const char *path, struct stat *st) {
    static int (*real_lstat)(const char *, struct stat *);
    if (!real_lstat) real_lstat = (int (*)(const char *, struct stat *))libsys("lstat");
    char overlay[2048]; return real_lstat(read_overlay(path, overlay), st);
}
int access(const char *path, int amode) {
    static int (*real_access)(const char *, int);
    if (!real_access) real_access = (int (*)(const char *, int))libsys("access");
    char overlay[2048]; return real_access((amode&~R_OK) ? path:read_overlay(path, overlay), amode);
}
DIR *opendir(const char *path) {
    static DIR *(*real)(const char *);
    if (!real) real = (DIR *(*)(const char *))libsys("opendir");
    DIR *d = real(path);
    static int trace = -1; if (trace < 0) trace = getenv("VXMAC_TRACE_FS") != NULL;
    if (trace) fprintf(stderr, "vxmac: fs: opendir %s -> %s\n", path, d ? "ok" : "failed");
    if (d) {
        pthread_mutex_lock(&g_dirs_lock);
        for (int i = 0; i < 64; i++) if (!g_dirs[i].d) { g_dirs[i].d = d; g_dirs[i].path = strdup(path); break; }
        pthread_mutex_unlock(&g_dirs_lock);
    }
    return d;
}
int closedir(DIR *d) {
    static int (*real)(DIR *);
    if (!real) real = (int (*)(DIR *))libsys("closedir");
    pthread_mutex_lock(&g_dirs_lock);
    for (int i = 0; i < 64; i++) if (g_dirs[i].d == d) { free(g_dirs[i].path); g_dirs[i].d = NULL; g_dirs[i].path = NULL; break; }
    pthread_mutex_unlock(&g_dirs_lock);
    return real(d);
}
struct dirent *readdir(DIR *d) {
    static struct dirent *(*real)(DIR *);
    if (!real) real = (struct dirent *(*)(DIR *))libsys("readdir");
    struct dirent *e = real(d);
    if (e && e->d_type == DT_LNK) {
        char p[2048] = "";
        pthread_mutex_lock(&g_dirs_lock);
        for (int i = 0; i < 64; i++) if (g_dirs[i].d == d) { snprintf(p, sizeof p, "%s/%s", g_dirs[i].path, e->d_name); break; }
        pthread_mutex_unlock(&g_dirs_lock);
        struct stat st;
        if (*p && stat(p, &st) == 0) e->d_type = S_ISDIR(st.st_mode) ? DT_DIR : S_ISREG(st.st_mode) ? DT_REG : DT_LNK;
    }
    return e;
}

// - sysctlbyname("hw.memsize"): the game's images ask it to size their memory budgets. VXMAC_MEMSIZE_MB reports that
//   instead (off by default); each call's real figure is logged once. (h62: what it decides - Cyberpunk2077 +0x1b060, a
//   "low-memory device" test (hw.memsize >> 30 < 10, kept after its first answer) that 39 sites read, e.g. a 1 MB
//   buffer made 512 KB at start (+0x3426c); the engine's VM backend keeps it too (+0x14450). The headset reports
//   15744 MB while the app may use ~8 GB: VXMAC_MEMSIZE_MB=8192 takes the game's own low-memory path. sysctl() with
//   {CTL_HW, HW_MEMSIZE} is answered the same way; libvxkit's NSProcessInfo.physicalMemory too.)
#include <sys/sysctl.h>
int sysctlbyname(const char *name, void *old, size_t *oldlen, void *newp, size_t newlen) {
    static int (*real)(const char *, void *, size_t *, void *, size_t);
    if (!real) real = (int (*)(const char *, void *, size_t *, void *, size_t))libsys("sysctlbyname");
    int r = real(name, old, oldlen, newp, newlen);
    if (r == 0 && name && old && oldlen && (!strcmp(name, "hw.model") || !strcmp(name, "machdep.cpu.brand_string"))) {
        static int n; if (n++ < 6) fprintf(stderr, "vxmac: sysctl %s = %.*s\n", name, (int)*oldlen, (const char *)old);
    }
    if (r == 0 && name && !strcmp(name, "hw.memsize") && old && oldlen && *oldlen == 8) {
        static int logged;
        if (!logged++) fprintf(stderr, "vxmac: sysctl hw.memsize %llu MB%s\n", (unsigned long long)(*(uint64_t *)old >> 20), getenv("VXMAC_MEMSIZE_MB") ? " (reported differently: VXMAC_MEMSIZE_MB)" : "");
        const char *e = getenv("VXMAC_MEMSIZE_MB");
        if (e && *e) *(uint64_t *)old = strtoull(e, NULL, 10) << 20;
    }
    return r;
}

int sysctl(int *mib, u_int n, void *old, size_t *oldlen, void *newp, size_t newlen) {
    static int (*real)(int *, u_int, void *, size_t *, void *, size_t);
    if (!real) real = (int (*)(int *, u_int, void *, size_t *, void *, size_t))libsys("sysctl");
    int r = real(mib, n, old, oldlen, newp, newlen);
    if (r == 0 && mib && n == 2 && mib[0] == CTL_HW && mib[1] == HW_MEMSIZE && old && oldlen && *oldlen == 8) {
        static int logged;
        if (!logged++) fprintf(stderr, "vxmac: sysctl {hw, memsize} %llu MB%s\n", (unsigned long long)(*(uint64_t *)old >> 20), getenv("VXMAC_MEMSIZE_MB") ? " (reported differently: VXMAC_MEMSIZE_MB)" : "");
        const char *e = getenv("VXMAC_MEMSIZE_MB");
        if (e && *e) *(uint64_t *)old = strtoull(e, NULL, 10) << 20;
    }
    return r;
}

// - mmap / mprotect / munmap / madvise of the game's images, watched (VXMAC_VM_WATCH=0: off): each reservation of 256 MB
//   or more is logged with its caller, and how far into it the program has committed (mprotect to readable or writable,
//   or a MAP_FIXED map inside it) is logged as it passes 50, 75, 90 and 100 % of it: a pool the size patch made too
//   small shows here before it overflows. (h62: a reservation mapped readable and writable at once - the engine's
//   Darwin backend (Cyberpunk2077 +0x14700: mmap RW, commit = madvise MADV_FREE_REUSE, decommit = MADV_FREE_REUSABLE,
//   release = munmap) - is not reported as "committed": its pages count only as the program writes them. munmap drops
//   a reservation (logged with its own size, "vm: release"), so one reserved again at the same place is a new one.)
//   Counters for the host's "mem" line (vxsys_vm_stats): the program's own mappings still mapped (MB), maps and
//   unmaps, the bytes it decommitted (REUSABLE) and recommitted (REUSE) and its other madvise calls, mprotect to none,
//   and the reservations that hold the most memory (dirty + compressed, from the VM itself).
#include <sys/mman.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <stdatomic.h>
typedef struct { uintptr_t base, size, hi; int step, rw; char caller[48]; } vx_res;
static vx_res g_res[128]; static int g_nres;
static pthread_mutex_t g_res_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t g_map_live, g_maps, g_unmaps, g_adv_reusable, g_adv_reuse, g_adv_free, g_adv_dontneed, g_adv_other, g_adv_calls,
                        g_prot_none;
static int vm_watch(void) { static int w = -1; if (w < 0) { const char *e = getenv("VXMAC_VM_WATCH"); w = !e || strcmp(e, "0"); } return w; }
static void caller_of(void *ra, char *out, size_t n) {
    Dl_info di;
    if (dladdr(ra, &di) && di.dli_fname) { const char *b = strrchr(di.dli_fname, '/'); snprintf(out, n, "%s+%#lx", b ? b + 1 : di.dli_fname, (unsigned long)((uintptr_t)ra - (uintptr_t)di.dli_fbase)); }
    else snprintf(out, n, "%p", ra);
}
static void commit_seen(uintptr_t a, size_t len, void *ra) {
    pthread_mutex_lock(&g_res_lock);
    for (int i = 0; i < g_nres; i++) {
        vx_res *r = &g_res[i];
        if (a < r->base || a >= r->base + r->size) continue;
        if (r->rw) break;   // (mapped writable from the start: nothing to learn from a commit)
        uintptr_t end = a + len - r->base; if (end > r->size) end = r->size;
        if (end > r->hi) {
            r->hi = end;
            static const int steps[] = { 50, 75, 90, 100 };
            while (r->step < 4 && r->hi * 100 >= (uintptr_t)steps[r->step] * r->size) {
                char c[160]; caller_of(ra, c, sizeof c);
                fprintf(stderr, "vxmac: vm: reservation %#lx (%lu MB) committed to %d %% (%lu MB) by %s\n", (unsigned long)r->base,
                        (unsigned long)(r->size >> 20), steps[r->step], (unsigned long)(r->hi >> 20), c);
                r->step++;
            }
        }
        break;
    }
    pthread_mutex_unlock(&g_res_lock);
}
void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    static void *(*real)(void *, size_t, int, int, int, off_t);
    if (!real) real = (void *(*)(void *, size_t, int, int, int, off_t))libsys("mmap");
    void *p = real(addr, len, prot, flags, fd, off);
    if (!vm_watch() || p == MAP_FAILED) return p;
    if (!(flags & MAP_FIXED)) { g_map_live += len; g_maps++; }
    if ((flags & MAP_FIXED) && prot != PROT_NONE) commit_seen((uintptr_t)p, len, __builtin_return_address(0));
    else if (len >= (256u << 20) && !(flags & MAP_FIXED)) {
        char c[160]; caller_of(__builtin_return_address(0), c, sizeof c);
        fprintf(stderr, "vxmac: vm: reserve %lu MB prot %d at %p by %s\n", (unsigned long)(len >> 20), prot, p, c);
        pthread_mutex_lock(&g_res_lock);
        if (g_nres < 128) {
            vx_res *r = &g_res[g_nres++]; memset(r, 0, sizeof *r);
            r->base = (uintptr_t)p; r->size = len; r->rw = (prot & PROT_WRITE) != 0; snprintf(r->caller, sizeof r->caller, "%s", c);
        }
        pthread_mutex_unlock(&g_res_lock);
        if (prot != PROT_NONE) commit_seen((uintptr_t)p, len, __builtin_return_address(0));
    }
    return p;
}
int munmap(void *addr, size_t len) {
    static int (*real)(void *, size_t);
    if (!real) real = (int (*)(void *, size_t))libsys("munmap");
    int r = real(addr, len);
    if (r || !vm_watch()) return r;
    g_unmaps++;
    { uint64_t l = atomic_load(&g_map_live); while (!atomic_compare_exchange_weak(&g_map_live, &l, l > len ? l - len : 0)) {} }
    uintptr_t a = (uintptr_t)addr, e = a + len;
    pthread_mutex_lock(&g_res_lock);
    for (int i = 0; i < g_nres; i++) {
        vx_res *x = &g_res[i];
        if (e <= x->base || a >= x->base + x->size) continue;
        if (a <= x->base && e >= x->base + x->size) {   // (all of it: gone)
            fprintf(stderr, "vxmac: vm: release %lu MB at %#lx (reserved by %s)\n", (unsigned long)(x->size >> 20), (unsigned long)x->base, x->caller);
            g_res[i--] = g_res[--g_nres];
        } else if (a <= x->base) { x->size -= e - x->base; x->base = e; }       // (its head trimmed)
        else if (e >= x->base + x->size) x->size = a - x->base;                 // (its tail trimmed)
    }
    pthread_mutex_unlock(&g_res_lock);
    return r;
}
int mprotect(void *addr, size_t len, int prot) {
    static int (*real)(void *, size_t, int);
    if (!real) real = (int (*)(void *, size_t, int))libsys("mprotect");
    int r = real(addr, len, prot);
    if (r == 0 && vm_watch()) { if (prot != PROT_NONE) commit_seen((uintptr_t)addr, len, __builtin_return_address(0)); else g_prot_none += len; }
    return r;
}
int madvise(void *addr, size_t len, int adv) {
    static int (*real)(void *, size_t, int);
    if (!real) real = (int (*)(void *, size_t, int))libsys("madvise");
    int r = real(addr, len, adv);
    if (r == 0 && vm_watch()) {
        g_adv_calls++;
        switch (adv) {
        case MADV_FREE_REUSABLE: g_adv_reusable += len; break;
        case MADV_FREE_REUSE: g_adv_reuse += len; break;
        case MADV_FREE: g_adv_free += len; break;
        case MADV_DONTNEED: g_adv_dontneed += len; break;
        default: g_adv_other += len;
        }
    }
    return r;
}
// (the dirty + compressed memory of [a, a + n): its regions' pages - what the footprint has of it)
static uint64_t held_bytes(uintptr_t a0, uintptr_t n) {
    uint64_t pg = vm_page_size, sum = 0;
    vm_address_t a = a0; uintptr_t end = a0 + n;
    while (a < end) {
        vm_size_t sz = 0; natural_t depth = 0; vm_region_submap_info_data_64_t ri; mach_msg_type_number_t c = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_64_t)&ri, &c) != KERN_SUCCESS || a >= end) break;
        sum += ((uint64_t)ri.pages_dirtied + ri.pages_swapped_out) * pg;   // (reusable pages are not counted dirty)
        a += sz;
    }
    return sum;
}
void vxsys_vm_stats(char *out, unsigned n) {
    if (!vm_watch()) { snprintf(out, n, "\"game_vm\":null"); return; }
    vx_res r[128]; int nr;
    pthread_mutex_lock(&g_res_lock); nr = g_nres; memcpy(r, g_res, (size_t)nr * sizeof *r); pthread_mutex_unlock(&g_res_lock);
    uint64_t held[128], total = 0;
    for (int i = 0; i < nr; i++) { held[i] = held_bytes(r[i].base, r[i].size); total += held[i]; }
    char top[700] = ""; size_t k = 0;
    for (int t = 0; t < 8; t++) {   // (the eight that hold the most)
        int best = -1; for (int i = 0; i < nr; i++) if (held[i] && (best < 0 || held[i] > held[best])) best = i;
        if (best < 0) break;
        const char *pl = strchr(r[best].caller, '+');
        k += (size_t)snprintf(top + k, sizeof top - k, "%s[\"%#lx\",%lu,%llu,\"%s\"]", t ? "," : "", (unsigned long)r[best].base,
                              (unsigned long)(r[best].size >> 20), (unsigned long long)(held[best] >> 20), pl ? pl + 1 : r[best].caller);
        held[best] = 0; if (k >= sizeof top) break;
    }
#define MB(x) (unsigned long long)(atomic_load(&x) >> 20)
    snprintf(out, n, "\"game_vm\":{\"mapped_mb\":%llu,\"maps\":%llu,\"unmaps\":%llu,\"reservations\":%d,\"res_held_mb\":%llu,"
             "\"decommit_mb\":%llu,\"recommit_mb\":%llu,\"madv_free_mb\":%llu,\"madv_dontneed_mb\":%llu,\"madv_other_mb\":%llu,\"madvise_calls\":%llu,"
             "\"prot_none_mb\":%llu,\"top\":[%s]}",
             MB(g_map_live), (unsigned long long)g_maps, (unsigned long long)g_unmaps, nr, (unsigned long long)(total >> 20),
             MB(g_adv_reusable), MB(g_adv_reuse), MB(g_adv_free), MB(g_adv_dontneed), MB(g_adv_other), (unsigned long long)g_adv_calls, MB(g_prot_none), top);
#undef MB
}

// - popen: visionOS has no shell. The game asks `system_profiler SPDisplaysDataType | grep "Chipset Model:"` for its
//   GPU (its per-GPU choices), and got nothing (h8: "sh: grep: command not found"). That command is answered as on an
//   M2 Mac ("Chipset Model: Apple M2"; VXMAC_CHIPSET to change it); any other command is logged and reads as empty.
//   pclose closes those streams.
#include <unistd.h>
static FILE *g_fake[8];
FILE *popen(const char *cmd, const char *mode) {
    const char *chip = getenv("VXMAC_CHIPSET");
    char out[256] = "";
    if (cmd && strstr(cmd, "system_profiler") && strstr(cmd, "SPDisplaysDataType"))
        snprintf(out, sizeof out, "      Chipset Model: %s\n", chip && *chip ? chip : "Apple M2");
    fprintf(stderr, "vxmac: popen \"%s\" -> %s", cmd ? cmd : "", *out ? out : "(empty)\n");
    int p[2];
    if (pipe(p)) return NULL;
    if (*out) write(p[1], out, strlen(out));
    close(p[1]);
    FILE *f = fdopen(p[0], mode && *mode ? "r" : "r");
    for (int i = 0; i < 8; i++) if (!g_fake[i]) { g_fake[i] = f; break; }
    return f;
}
int pclose(FILE *f) {
    for (int i = 0; i < 8; i++) if (g_fake[i] == f) { g_fake[i] = NULL; fclose(f); return 0; }
    static int (*real)(FILE *);
    if (!real) real = (int (*)(FILE *))libsys("pclose");
    return real(f);
}
