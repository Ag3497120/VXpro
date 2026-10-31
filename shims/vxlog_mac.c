// (Mac tests only: vxmac_log for libvxmtl / libvxmtlfx without libvxkit, which cannot load beside AppKit)
#include <stdarg.h>
#include <stdio.h>
void vxmac_log(const char *fmt, ...) { va_list ap; va_start(ap, fmt); fprintf(stderr, "vxmac: "); vfprintf(stderr, fmt, ap); fputc('\n', stderr); va_end(ap); }
