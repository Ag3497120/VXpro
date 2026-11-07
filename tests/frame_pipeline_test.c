// SPDX-License-Identifier: MIT
#include "../vr/frame_pipeline.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static vxfp_ticket ready(vxfp_pipeline *p, uint64_t n, double t) {
    vxfp_ticket a; assert(vxfp_acquire(p, n, t, &a)); assert(vxfp_process(p, a));
    assert(vxfp_complete(p, a, t + .001, 1)); return a;
}
int main(void) {
    vxfp_pipeline p; vxfp_ticket a, b, c, d, shown; vxfp_reason why;
    size_t bytes = 99;
    assert(!vxfp_memory_plan(SIZE_MAX, 1, 2, SIZE_MAX, &bytes) && !bytes);
    assert(!vxfp_memory_plan(100, SIZE_MAX, 2, SIZE_MAX, &bytes));
    assert(!vxfp_memory_plan(SIZE_MAX / 3, 1, 2, SIZE_MAX, &bytes));
    assert(!vxfp_memory_plan(100, 50, 2, 399, &bytes));
    assert(vxfp_memory_plan(100, 50, 2, 400, &bytes) && bytes == 400);
    assert(!vxfp_init(&p, NAN, .1) && !vxfp_init(&p, .1, .1));
    assert(vxfp_init(&p, .03, .1));
    assert(!vxfp_select(&p, 1, 0, &shown, &why));
    assert(vxfp_acquire(&p, 1, 1, &a)); assert(vxfp_process(&p, a));
    assert(!vxfp_select(&p, 1.02, 0, &shown, &why)); // Never read an unfinished GPU image.
    assert(vxfp_complete(&p, a, 1.02, 1));
    assert(vxfp_select(&p, 1.021, 0, &shown, &why) && shown.sequence == 1 && why == VXFP_WARMUP);
    assert(vxfp_release(&p, shown));
    assert(vxfp_select(&p, 1.022, 0, &shown, &why));
    assert(vxfp_select(&p, 1.023, 0, &b, &why));
    assert(vxfp_release(&p, shown));
    assert(!vxfp_release(&p, shown)); // Duplicate completion cannot release another GPU reader.
    assert(p.slots[b.slot].readers == 1 && vxfp_release(&p, b));
    b = ready(&p, 2, 1.025);
    assert(vxfp_select(&p, 1.04, 0, &shown, &why) && shown.sequence == 1);
    assert(vxfp_release(&p, shown));
    assert(vxfp_select(&p, 1.04, 1, &shown, &why) && shown.sequence == 2 && why == VXFP_INPUT);
    assert(vxfp_release(&p, shown));
    assert(vxfp_select(&p, 1.045, 0, &shown, &why) && shown.sequence == 2); // Release never rewinds.
    assert(vxfp_release(&p, shown));
    c = ready(&p, 3, 1.13);
    assert(vxfp_select(&p, 1.14, 0, &shown, &why) && shown.sequence == 3 && why == VXFP_LATE);
    assert(vxfp_release(&p, shown));
    // Old callback must not publish over a new resource owner, including ABA reuse.
    assert(vxfp_acquire(&p, 4, 1.15, &d)); assert(d.slot == a.slot);
    assert(!vxfp_complete(&p, a, 1.16, 1));
    assert(vxfp_process(&p, d)); assert(vxfp_complete(&p, d, 1.16, 0));
    assert(!vxfp_complete(&p, d, 1.17, 1));
    (void)b; (void)c;
    // A slow processing frame cannot block showing the current complete image.
    assert(vxfp_acquire(&p, 5, 1.17, &d)); assert(vxfp_process(&p, d));
    for (int i = 0; i < 20; i++) {
        assert(vxfp_select(&p, 1.18 + i * .01, 0, &shown, &why) && shown.sequence == 3);
        assert(vxfp_release(&p, shown));
    }
    assert(vxfp_complete(&p, d, 1.4, 1));
    // Completion order differs from content order; no backward selection.
    assert(vxfp_init(&p, 0, .1));
    assert(vxfp_acquire(&p, 1, 1, &a)); assert(vxfp_process(&p, a));
    b = ready(&p, 2, 1.01);
    assert(vxfp_select(&p, 1.02, 0, &shown, &why) && shown.sequence == 2);
    assert(vxfp_complete(&p, a, 1.03, 1));
    c = ready(&p, 3, 1.04);
    assert(vxfp_select(&p, 1.05, 0, &d, &why) && d.sequence == 3);
    assert(vxfp_release(&p, d));
    // Reader #2 still owns its image after #3 becomes the held frame.
    assert(vxfp_acquire(&p, 4, 1.06, &d) && d.slot == a.slot);
    assert(!vxfp_acquire(&p, 5, 1.07, &a));
    assert(vxfp_release(&p, shown));
    assert(vxfp_acquire(&p, 6, 1.08, &a) && a.slot == b.slot);
    assert(!vxfp_release(&p, shown));
    assert(vxfp_complete(&p, d, 1.09, 0)); assert(vxfp_complete(&p, a, 1.09, 0));
    // Long reuse under jitter, a held GPU reader, failures, and out-of-order finishes.
    assert(vxfp_init(&p, .02, .08));
    uint64_t displayed = 0; unsigned checked = 0;
    for (uint64_t n = 1; n <= 50000; n++) {
        double now = n * .003;
        vxfp_ticket job;
        if (vxfp_acquire(&p, n, now, &job)) assert(vxfp_process(&p, job));
        for (int i = VXFP_SLOTS - 1; i >= 0; i--) {
            vxfp_slot *s = &p.slots[i];
            if (s->state == VXFP_PROCESSING && now - s->content_time >= (s->sequence % 5) * .004) {
                vxfp_ticket finish = {.slot=i, .generation=s->generation, .sequence=s->sequence};
                assert(vxfp_complete(&p, finish, now, s->sequence % 17 != 0));
            }
        }
        if (vxfp_select(&p, now, n % 31 == 0, &shown, &why)) {
            assert(shown.sequence >= displayed); displayed = shown.sequence; checked++;
            assert(vxfp_release(&p, shown));
        }
        for (int i = 0; i < VXFP_SLOTS; i++) assert(p.slots[i].readers == 0);
    }
    assert(checked > 49000 && p.capacity_drops && p.failed);
    assert(vxfp_init(&p, 0, .1));
    (void)ready(&p, 1, 1);
    vxfp_ticket readers[VXFP_READERS];
    for (int i = 0; i < VXFP_READERS; i++) assert(vxfp_select(&p, 1.01, 0, &readers[i], &why));
    assert(!vxfp_select(&p, 1.02, 0, &shown, &why));
    assert(p.slots[readers[0].slot].readers == VXFP_READERS);
    for (int i = 0; i < VXFP_READERS; i++) assert(vxfp_release(&p, readers[i]));
    assert(!vxfp_release(&p, readers[0]) && !p.slots[readers[0].slot].readers);
    p.generation = UINT64_MAX;
    assert(!vxfp_acquire(&p, 2, 1.03, &a));
    puts("frame pipeline: bounded memory, reader ownership, late/failed/reordered work and 50000 ticks: ok");
    return 0;
}
