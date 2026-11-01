// tests/mtrace_mac.m - shims/vxmtrace.c on the Mac: does the sampled stack trace name the code that keeps memory?
//   xcrun clang -O1 -fobjc-arc -fno-omit-frame-pointer tests/mtrace_mac.m shims/vxmtrace.c -framework Foundation -o build/mtrace_mac
//   build/mtrace_mac [rate]
// Three allocation sites run interleaved, 64-byte blocks: leak_c (malloc, every block kept), leak_objc (an NSObject
// subclass with 48 bytes of ivars kept in an array), churn (malloc + free, nothing kept), plus realloc'd buffers. Expected:
// the two leaks on top with their real totals (within the sampling error), the churn absent.
#import <Foundation/Foundation.h>
#include <malloc/malloc.h>
#include <stdio.h>
#include <string.h>
int vxsys_mtrace_start(unsigned rate); void vxsys_mtrace_stats(char *out, unsigned n); int vxsys_mtrace_dump(const char *path);

@interface VXLeakObj : NSObject { @public char pad[48]; }
@end
@implementation VXLeakObj
@end
static void *g_keep[400000]; static int g_nkeep;
static NSMutableArray *g_objs;
__attribute__((noinline)) static void leak_c(void) { g_keep[g_nkeep++] = malloc(64); }
__attribute__((noinline)) static void leak_objc(void) { [g_objs addObject:[VXLeakObj new]]; }
__attribute__((noinline)) static void churn(void) { void *p = malloc(64); memset(p, 1, 64); free(p); }
__attribute__((noinline)) static void grow(void **b, size_t *n) { *n += 256; *b = realloc(*b, *n); }

int main(int argc, char **argv) {
    unsigned rate = argc > 1 ? (unsigned)atoi(argv[1]) : 64;
    if (!vxsys_mtrace_start(rate)) { fprintf(stderr, "no start\n"); return 1; }
    @autoreleasepool {
        g_objs = [NSMutableArray array];
        void *rb = NULL; size_t rn = 0;
        for (int i = 0; i < 300000; i++) {
            leak_c();
            if (i < 200000) leak_objc();
            churn(); churn();
            if (i % 100 == 0) grow(&rb, &rn);
        }
        char s[1200]; vxsys_mtrace_stats(s, sizeof s); printf("%s\n", s);
        vxsys_mtrace_dump("build/mtrace_mac.txt");
        printf("expected: leak_c %.1f MB (300000 x 64 B), leak_objc %.1f MB (200000 x %zu B), realloc'd %.2f MB; churn 0\n",
               300000 * 64 / 1048576.0, 200000 * malloc_size((__bridge void *)g_objs[0]) / 1048576.0, malloc_size((__bridge void *)g_objs[0]), rn / 1048576.0);
        int pass = strstr(s, "leak_c") && strstr(s, "leak_objc") && !strstr(s, "churn");
        printf("%s\n", pass ? "PASS: both leaks named, the churn absent" : "FAIL");
        return pass ? 0 : 1;
    }
}
