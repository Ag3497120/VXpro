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
static struct { DIR *d; char *path; } g_dirs[64];
static pthread_mutex_t g_dirs_lock = PTHREAD_MUTEX_INITIALIZER;
static void *libsys(const char *name) { return dlsym(dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOLOAD | RTLD_LAZY), name); }
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
//   instead (off by default); each call's real figure is logged once.
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

// - mmap / mprotect / munmap of the game's images, watched (VXMAC_VM_WATCH=0: off): each reservation of 256 MB or
//   more is logged with its caller, and how far into it the program has committed (mprotect to readable or writable,
//   or a MAP_FIXED map inside it) is logged as it passes 50, 75, 90 and 100 % of it: a pool the size patch made too
//   small shows here before it overflows.
#include <sys/mman.h>
#include <mach-o/dyld.h>
typedef struct { uintptr_t base, size, hi; int step; } vx_res;
static vx_res g_res[96]; static int g_nres;
static pthread_mutex_t g_res_lock = PTHREAD_MUTEX_INITIALIZER;
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
    if ((flags & MAP_FIXED) && prot != PROT_NONE) commit_seen((uintptr_t)p, len, __builtin_return_address(0));
    else if (len >= (256u << 20) && !(flags & MAP_FIXED)) {
        char c[160]; caller_of(__builtin_return_address(0), c, sizeof c);
        fprintf(stderr, "vxmac: vm: reserve %lu MB prot %d at %p by %s\n", (unsigned long)(len >> 20), prot, p, c);
        pthread_mutex_lock(&g_res_lock);
        if (g_nres < 96) { g_res[g_nres].base = (uintptr_t)p; g_res[g_nres].size = len; g_res[g_nres].hi = 0; g_res[g_nres].step = 0; g_nres++; }
        pthread_mutex_unlock(&g_res_lock);
        if (prot != PROT_NONE) commit_seen((uintptr_t)p, len, __builtin_return_address(0));
    }
    return p;
}
int mprotect(void *addr, size_t len, int prot) {
    static int (*real)(void *, size_t, int);
    if (!real) real = (int (*)(void *, size_t, int))libsys("mprotect");
    int r = real(addr, len, prot);
    if (r == 0 && vm_watch() && prot != PROT_NONE) commit_seen((uintptr_t)addr, len, __builtin_return_address(0));
    return r;
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
