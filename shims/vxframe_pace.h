// SPDX-License-Identifier: MIT
#ifndef VXFRAME_PACE_H
#define VXFRAME_PACE_H
typedef struct {
    double next, last_now, hz;
    int initialized;
} vxfp_clock;
// Caller serializes access. Late producers start now; no catch-up burst or GPU-time debt.
double vxfp_clock_reserve(vxfp_clock *clock, double now, double hz);
double vxfp_clock_limit(const char *text);
#endif
