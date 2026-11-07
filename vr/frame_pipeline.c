// SPDX-License-Identifier: MIT
#include "frame_pipeline.h"
#include <limits.h>
#include <math.h>
#include <string.h>

int vxfp_memory_plan(size_t slot, size_t output, unsigned outputs, size_t budget, size_t *total) {
    if (total) *total = 0;
    if (!total || !slot || !output || !outputs || slot > SIZE_MAX / VXFP_SLOTS || output > SIZE_MAX / outputs) return 0;
    size_t a = slot * VXFP_SLOTS, b = output * outputs;
    if (a > SIZE_MAX - b || a + b > budget) return 0;
    *total = a + b;
    return 1;
}
int vxfp_init(vxfp_pipeline *p, double delay, double max_age) {
    if (!p || !isfinite(delay) || !isfinite(max_age) || delay < 0 || max_age <= delay) return 0;
    memset(p, 0, sizeof *p);
    p->held = -1; p->delay_s = delay; p->max_age_s = max_age;
    return 1;
}
static vxfp_ticket ticket_at(const vxfp_pipeline *p, int i) {
    return (vxfp_ticket){ .slot = i, .generation = p->slots[i].generation, .sequence = p->slots[i].sequence };
}
static vxfp_slot *match(vxfp_pipeline *p, vxfp_ticket t) {
    if (t.slot < 0 || t.slot >= VXFP_SLOTS) return NULL;
    vxfp_slot *s = &p->slots[t.slot];
    return s->generation == t.generation && s->sequence == t.sequence ? s : NULL;
}
static int newest(const vxfp_pipeline *p, double now) {
    int best = -1;
    for (int i = 0; i < VXFP_SLOTS; i++) {
        const vxfp_slot *s = &p->slots[i];
        if (s->state == VXFP_READY && s->ready_time <= now && s->content_time <= now &&
            (best < 0 || s->sequence > p->slots[best].sequence)) best = i;
    }
    return best;
}
int vxfp_acquire(vxfp_pipeline *p, uint64_t seq, double time, vxfp_ticket *t) {
    if (!p || !t || !seq || seq <= p->last_sequence || !isfinite(time) || time < 0 || p->generation == UINT64_MAX) return 0;
    p->last_sequence = seq;
    int pick = -1, latest = newest(p, INFINITY);
    for (int i = 0; i < VXFP_SLOTS; i++) if (p->slots[i].state == VXFP_FREE) { pick = i; break; }
    if (pick < 0) for (int i = 0; i < VXFP_SLOTS; i++) {
        vxfp_slot *s = &p->slots[i];
        if (s->state == VXFP_READY && !s->readers && i != p->held && i != latest &&
            (pick < 0 || s->sequence < p->slots[pick].sequence)) pick = i;
    }
    if (pick < 0) {
        unsigned busy = 0;
        for (int i = 0; i < VXFP_SLOTS; i++) {
            const vxfp_slot *s = &p->slots[i];
            if (s->state == VXFP_RENDERING || s->state == VXFP_PROCESSING || s->readers) busy++;
        }
        p->capacity_drops++;
        if (busy == VXFP_SLOTS) p->capacity_busy_drops++;
        return 0;
    }
    p->slots[pick] = (vxfp_slot){ .state = VXFP_RENDERING, .sequence = seq,
        .generation = ++p->generation, .content_time = time };
    p->admitted++; *t = ticket_at(p, pick);
    return 1;
}
int vxfp_process(vxfp_pipeline *p, vxfp_ticket t) {
    vxfp_slot *s = match(p, t);
    if (!s || t.reader || s->state != VXFP_RENDERING) { p->rejected_callbacks++; return 0; }
    s->state = VXFP_PROCESSING;
    return 1;
}
int vxfp_complete(vxfp_pipeline *p, vxfp_ticket t, double ready, int success) {
    vxfp_slot *s = match(p, t);
    if (!s || t.reader || (s->state != VXFP_RENDERING && s->state != VXFP_PROCESSING)) { p->rejected_callbacks++; return 0; }
    if (!success || !isfinite(ready) || ready < s->content_time || s->state != VXFP_PROCESSING) {
        s->state = VXFP_FREE; p->failed++; return 1;
    }
    s->ready_time = ready; s->state = VXFP_READY;
    return 1;
}
int vxfp_select(vxfp_pipeline *p, double now, int input, vxfp_ticket *t, vxfp_reason *why) {
    if (!p || !t || !why || !isfinite(now) || now < 0) return 0;
    int latest = newest(p, now), pick = -1;
    if (latest < 0) return 0;
    int lease = -1;
    for (int i = 0; i < VXFP_READERS; i++) if (!p->leases[i].reader) { lease = i; break; }
    if (lease < 0 || p->reader == UINT64_MAX) return 0;
    *why = VXFP_NORMAL;
    uint64_t floor = p->held >= 0 ? p->slots[p->held].sequence : 0;
    if (input) { pick = latest; *why = VXFP_INPUT; p->input_bypasses++; }
    else {
        for (int i = 0; i < VXFP_SLOTS; i++) {
            vxfp_slot *s = &p->slots[i];
            if (s->state == VXFP_READY && s->ready_time <= now && s->content_time <= now - p->delay_s &&
                s->sequence >= floor && (pick < 0 || s->sequence > p->slots[pick].sequence)) pick = i;
        }
        if (pick < 0) {
            if (p->held >= 0) pick = p->held;
            else { pick = latest; *why = VXFP_WARMUP; }
        }
        if (now - p->slots[pick].content_time > p->max_age_s) {
            pick = latest; *why = VXFP_LATE; p->late_bypasses++;
        }
    }
    if (p->slots[pick].sequence < floor) pick = p->held;
    if (p->slots[pick].readers == UINT_MAX) return 0;
    if (pick == p->held) p->repeats++;
    p->held = pick; p->slots[pick].readers++; p->selections++;
    *t = ticket_at(p, pick);
    t->reader = ++p->reader; p->leases[lease] = *t;
    return 1;
}
int vxfp_release(vxfp_pipeline *p, vxfp_ticket t) {
    vxfp_slot *s = match(p, t);
    if (!s || s->state != VXFP_READY || !s->readers) { p->rejected_callbacks++; return 0; }
    int lease = -1;
    for (int i = 0; i < VXFP_READERS; i++) {
        vxfp_ticket a = p->leases[i];
        if (t.reader && a.reader == t.reader && a.slot == t.slot && a.generation == t.generation && a.sequence == t.sequence) { lease = i; break; }
    }
    if (lease < 0) { p->rejected_callbacks++; return 0; }
    p->leases[lease].reader = 0;
    s->readers--;
    return 1;
}
