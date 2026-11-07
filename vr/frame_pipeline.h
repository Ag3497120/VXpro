// SPDX-License-Identifier: MIT
#pragma once
#include <stddef.h>
#include <stdint.h>

// Owns metadata only. Callers serialize calls and retain GPU resources until
// their completion callbacks release the matching ticket. Init only when idle.
// The game trial can provision an extra bounded image without changing selection or reader ownership.
#ifndef VXFP_SLOTS
#define VXFP_SLOTS 3
#endif
#define VXFP_READERS 8
typedef struct { int slot; uint64_t generation, sequence, reader; } vxfp_ticket;
typedef enum { VXFP_FREE, VXFP_RENDERING, VXFP_PROCESSING, VXFP_READY } vxfp_state;
typedef enum { VXFP_NORMAL, VXFP_WARMUP, VXFP_INPUT, VXFP_LATE } vxfp_reason;
typedef struct {
    vxfp_state state;
    uint64_t generation, sequence;
    unsigned readers;
    double content_time, ready_time;
} vxfp_slot;
typedef struct {
    vxfp_slot slots[VXFP_SLOTS];
    int held;
    uint64_t generation, last_sequence;
    uint64_t reader;
    vxfp_ticket leases[VXFP_READERS];
    uint64_t admitted, capacity_drops, capacity_busy_drops, failed, rejected_callbacks;
    uint64_t selections, repeats, input_bypasses, late_bypasses;
    double delay_s, max_age_s;
} vxfp_pipeline;

// Refuse overflow and budgets that cannot cover the entire simultaneously-live
// pool. Splitting work across time never permits aliasing a still-live image.
int vxfp_memory_plan(size_t bytes_per_slot, size_t bytes_per_output,
                     unsigned outputs, size_t budget, size_t *total);
int vxfp_init(vxfp_pipeline *p, double delay_s, double max_age_s);
int vxfp_acquire(vxfp_pipeline *p, uint64_t sequence, double content_time, vxfp_ticket *ticket);
int vxfp_process(vxfp_pipeline *p, vxfp_ticket ticket);
int vxfp_complete(vxfp_pipeline *p, vxfp_ticket ticket, double ready_time, int success);
// Never waits. Selects complete images only; never rewinds after an input bypass
// or a completion arriving out of order. A returned ticket has a reader lease.
int vxfp_select(vxfp_pipeline *p, double now, int input_active,
                vxfp_ticket *ticket, vxfp_reason *reason);
int vxfp_release(vxfp_pipeline *p, vxfp_ticket ticket);
