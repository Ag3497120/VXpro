// dyhost_mac: the Mac test of macho_prepare.py --as-dylib. Loads a main executable turned into a dylib and calls its
// entry point (the offset from VXMacImage.plist, given here) on this thread, as VX Mac Host does on its game thread.
//   dyhost_mac IMAGE ENTRY_OFFSET [-n] [args...]     (-n: load and resolve only, do not call the entry)
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <crt_externs.h>
typedef int (*entry_fn)(int, char **, char **, char **);
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: dyhost_mac IMAGE ENTRY_OFFSET [-n] [args]\n"); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dyhost dlopen: %s\n", dlerror()); return 3; }
    const struct mach_header *mh = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (!strcmp(_dyld_get_image_name(i), argv[1]) || strstr(_dyld_get_image_name(i), strrchr(argv[1], '/') + 1)) mh = _dyld_get_image_header(i);
    if (!mh) { fprintf(stderr, "dyhost: image not found among the loaded ones\n"); return 4; }
    unsigned long off = strtoul(argv[2], NULL, 0);
    entry_fn e = (entry_fn)((const char *)mh + off);
    printf("dyhost loaded %s at %p entry %p\n", argv[1], (void *)mh, (void *)e);
    if (argc > 3 && !strcmp(argv[3], "-n")) return 0;
    char *apple[] = { "executable_path=", NULL };
    argv[2] = argv[1];
    return e(argc - 2, argv + 2, *_NSGetEnviron(), apple);
}
