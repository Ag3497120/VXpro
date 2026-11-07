// SPDX-License-Identifier: MIT
// Run the real file shim against a private data root without changing HOME.
#include <stdlib.h>
#include <string.h>
static char *test_data_root;
static char *test_environment(const char *name);
#define getenv test_environment
#include "../shims/vxsystem.c"
#undef getenv
#include <assert.h>

static char *test_environment(const char *name) {
    return !strcmp(name, "HOME") ? test_data_root : getenv(name);
}

static void write_file(const char *path, const char *text) {
    FILE *f = fopen(path, "w"); assert(f);
    assert(fwrite(text, 1, strlen(text), f) == strlen(text)); fclose(f);
}

static void expect_file(const char *path, const char *text) {
    char actual[32] = {0};
    FILE *f = fopen(path, "r"); assert(f);
    assert(fread(actual, 1, sizeof actual - 1, f) == strlen(text)); fclose(f);
    assert(!strcmp(actual, text));
    struct stat st; assert(!stat(path, &st) && st.st_size == (off_t)strlen(text));
    int fd = open(path, O_RDONLY); assert(fd >= 0);
    memset(actual, 0, sizeof actual);
    assert(read(fd, actual, sizeof actual - 1) == (ssize_t)strlen(text)); close(fd);
    assert(!strcmp(actual, text));
}

int main(void) {
    char root[] = "/tmp/vx-manual-script-XXXXXX";
    test_data_root = mkdtemp(root); assert(test_data_root);
    char path[1024], manual[1024], probe[1024];
    snprintf(path, sizeof path, "%s/Documents", root); assert(!mkdir(path, 0700));
    snprintf(manual, sizeof manual, "%s/Documents/vxhands_manual", root); assert(!mkdir(manual, 0700));
    snprintf(probe, sizeof probe, "%s/Documents/vxhands_weapon_probe", root); assert(!mkdir(probe, 0700));
    snprintf(path, sizeof path, "%s/final.redscripts", probe); write_file(path, "stale probe");
    snprintf(path, sizeof path, "%s/final.redscripts", manual); write_file(path, "current reload policy");
    snprintf(path, sizeof path, "%s/inputContexts.xml", manual); write_file(path, "current contexts");
    snprintf(path, sizeof path, "%s/inputUserMappings.xml", manual); write_file(path, "current mappings");
    assert(!setenv("VXMAC_NO_AUTO_RELOAD", "1", 1));
    assert(!setenv("VXMAC_MANUAL_MAG_ACTIVE", "1", 1));
    assert(!setenv("VXMAC_WEAPON_BRIDGE", "1", 1));
    expect_file("/game/r6/cache/final.redscripts", "current reload policy");
    char bundled[1024];snprintf(bundled,sizeof bundled,"%s/bundled",root);assert(!mkdir(bundled,0700));
    snprintf(path,sizeof path,"%s/final.redscripts",bundled);write_file(path,"matched signed policy");
    snprintf(path,sizeof path,"%s/inputContexts.xml",bundled);write_file(path,"matched signed contexts");
    snprintf(path,sizeof path,"%s/inputUserMappings.xml",bundled);write_file(path,"matched signed mappings");
    assert(!setenv("VXMAC_MANUAL_MAG_DIR",bundled,1));
    expect_file("/game/r6/cache/final.redscripts","matched signed policy");
    expect_file("/game/r6/config/inputContexts.xml","matched signed contexts");
    expect_file("/game/r6/config/inputUserMappings.xml","matched signed mappings");
    assert(!unsetenv("VXMAC_MANUAL_MAG_DIR"));
    expect_file("/game/r6/cache/final.redscripts","current reload policy");
    expect_file("/game/r6/config/inputContexts.xml", "current contexts");
    expect_file("/game/r6/config/inputUserMappings.xml", "current mappings");
    assert(!unsetenv("VXMAC_WEAPON_BRIDGE"));
    expect_file("/game/r6/cache/final.redscripts", "current reload policy");
    puts("manual overlays: bridge cannot select a stale diagnostic script: ok");
    return 0;
}
