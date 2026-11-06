// Link against the Mac-built vxsystem shim; all files are temporary test data.
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void put(const char *path, const char *s) {
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    assert(fd >= 0 && write(fd, s, strlen(s)) == (ssize_t)strlen(s)); close(fd);
}
static void check(const char *path, const char *expected) {
    char b[32] = {0}; int fd = open(path, O_RDONLY); assert(fd >= 0);
    ssize_t n = read(fd, b, sizeof b - 1); close(fd); assert(n >= 0 && !strcmp(b, expected));
    struct stat st; assert(!stat(path, &st) && st.st_size == (off_t)strlen(expected));
    FILE *f = fopen(path, "r"); assert(f); memset(b, 0, sizeof b); assert(fread(b, 1, strlen(expected), f) == strlen(expected));
    fclose(f); assert(!strcmp(b, expected));
}
int main(void) {
    char dir[] = "/tmp/vxscript-test-XXXXXX"; assert(mkdtemp(dir));
    char p[512], a[512], overlay[512];
    snprintf(p, sizeof p, "%s/r6", dir); assert(!mkdir(p, 0700));
    snprintf(p, sizeof p, "%s/r6/cache", dir); assert(!mkdir(p, 0700));
    snprintf(a, sizeof a, "%s/r6/cache/final.redscripts", dir);
    snprintf(overlay, sizeof overlay, "%s/overlay.redscripts", dir);
    put(a, "original"); put(overlay, "overlay123");
    assert(!setenv("VXMAC_SCRIPT_OVERLAY", overlay, 1)); assert(!setenv("VXMAC_NO_AUTO_RELOAD", "1", 1));
    check(a, "overlay123");
    // Other paths and writes must never be redirected.
    put(a, "updated"); check(a, "overlay123");
    assert(!unsetenv("VXMAC_NO_AUTO_RELOAD")); check(a, "updated");
    assert(!setenv("VXMAC_NO_AUTO_RELOAD", "1", 1)); assert(!unlink(overlay)); check(a, "updated");
    puts("script overlay: read, metadata, write isolation, missing fallback: ok");
    return 0;
}
