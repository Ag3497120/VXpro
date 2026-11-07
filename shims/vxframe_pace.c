// SPDX-License-Identifier: MIT
#include "vxframe_pace.h"
#include <math.h>
#include <stdlib.h>
#include <errno.h>

double vxfp_clock_limit(const char *text) {
    if (!text || !*text) return 45;
    char *end;
    errno = 0;
    double hz = strtod(text, &end);
    if (end == text || *end || errno == ERANGE || !isfinite(hz) || (hz != 0 && (hz < 15 || hz > 90))) return 45;
    return hz;
}
double vxfp_clock_reserve(vxfp_clock *clock, double now, double hz) {
    if (!isfinite(now) || now < 0) return 0;
    if (!isfinite(hz) || hz <= 0) { clock->initialized = 0; return now; }
    if (!clock->initialized || clock->hz != hz || now < clock->last_now) {
        clock->next = now; clock->initialized = 1; clock->hz = hz;
    }
    double deadline = fmax(now,clock->next);
    clock->next = deadline + 1.0/hz;
    clock->last_now = now;
    return deadline;
}
