// Exercise ownership transitions without a headset: clang -Ivr tests/hand_weapon_hold_mac.c vr/hand_weapon.c -o /tmp/hand_weapon_hold && /tmp/hand_weapon_hold
#include "hand_weapon.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    hand_weapon_hold h = {0};
    hand_pose p[2]; memset(p, 0, sizeof p);
    for (int i = 0; i < 2; i++) { p[i].ok = 1; p[i].fwd[2] = -1; }
    p[1].grip = 1; p[0].grip = 1; p[0].palm[2] = -.2f;
    hand_weapon_hold_update(&h, p, 1, 1);
    assert(h.owner == 1 && h.support);
    p[1].ok = 0; p[1].grip = 0;
    hand_weapon_hold_update(&h, p, 1, 1);
    assert(h.owner == 1 && h.support);
    p[1].ok = 1; p[1].from_arm = 1;
    hand_weapon_hold_update(&h, p, 1, 1);
    assert(h.owner == 1 && h.support);
    p[1].from_arm = 0;
    hand_weapon_hold_update(&h, p, 1, 1);
    assert(h.owner == 0 && !h.support);
    // The right hand can move away while the left remains the owner.
    p[1].palm[2] = .5f;
    hand_weapon_hold_update(&h, p, 1, 1);
    assert(h.owner == 0 && !h.support);
    // Reacquire with both hands, then intentionally open the left hand.
    p[1].palm[2] = -.3f; p[1].grip = 1;
    hand_weapon_hold_update(&h, p, 1, 1);
    assert(h.owner == 0 && h.support);
    p[0].grip = 0;
    hand_weapon_hold_update(&h, p, 1, 1);
    assert(h.owner == 1 && !h.support);
    hand_weapon_hold_update(&h, p, 1, 0);
    assert(!h.initialized);
    puts("hand weapon hold: ok");
    return 0;
}
