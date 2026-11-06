// Reuse the synthetic skeleton generator for the rack-required reload boundary.
#define main hand_weapon_full_suite
#include "hand_weapon_mac.c"
#undef main
#include <assert.h>

int main(void) {
    reset(0, 0);
    w.rack = 1;
    w.state = HW_HOLD_NEW;
    w.near_at = t - .1;
    w.in_start = .5f;
    memcpy(H[off_h].palm, WELL, sizeof WELL);
    H[off_h].grip = 1;
    step();
    assert(w.state == HW_IN_NO_ROUND);
    assert(seen[2] == 1 && seen[4] == 0);
    memcpy(H[off_h].palm, REST, sizeof REST);
    H[off_h].grip = 0;
    hold(3.2);
    assert(seen[4] == 0 && seen[5] == 1);
    puts("rack-required reload: no completion before racking; timeout cancels: ok");
    return 0;
}
