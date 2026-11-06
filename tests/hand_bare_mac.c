// MIT licensed with VXMac. Tests gestures without requiring ARKit or a game process.
#include "hand_gestures.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static bare_hands state;
static float head[16], hands[20], wrists[20], middle[2];

static void hand(int h, float x, float y, float z, int pinched) {
    float *p = hands + 10 * h, *w = wrists + 10 * h;
    p[0] = w[0] = 1;
    p[1] = p[7] = w[1] = x;
    p[2] = p[5] = p[8] = w[2] = y;
    p[3] = p[6] = p[9] = w[3] = z;
    p[4] = x + (pinched ? .008f : .06f);
}

static bare_hand_input update(double t, int gameplay, int owner, int can_eject) {
    return bare_hands_update(&state, head, hands, wrists, middle, t, 1, gameplay, owner, can_eject, 0);
}

static void reset(void) {
    memset(&state, 0, sizeof state);
    memset(head, 0, sizeof head);
    head[0] = head[5] = head[10] = head[15] = 1;
    middle[0] = middle[1] = 1;
    hand(0, -.1f, -.2f, -.5f, 0);
    hand(1, .1f, -.2f, -.5f, 0);
    assert(!update(1, 1, 1, 1).pinches);
}

int main(void) {
    reset();
    hand(1, .1f, -.2f, -.5f, 1);
    assert(!update(1.05, 1, 1, 1).pinches);
    hand(1, .1f, -.2f, -.5f, 0);
    assert(update(1.13, 1, 1, 1).pinches == 2);
    assert(!update(1.21, 1, 1, 1).pinches);

    hand(1, .1f, -.2f, -.5f, 1);
    assert(!update(1.25, 1, 1, 1).pinches);
    assert(!update(1.39, 1, 1, 1).pinches);
    assert(update(1.47, 1, 1, 1).pinches == 2);
    hands[10] = 0;
    assert(!update(1.49, 1, 1, 1).pinches);
    hand(1, .1f, -.2f, -.5f, 1);
    assert(!update(1.52, 1, 1, 1).pinches);
    assert(!update(1.65, 1, 1, 1).pinches);
    hand(1, .1f, -.2f, -.5f, 0);
    assert(!update(1.71, 1, 1, 1).pinches);
    hand(1, .1f, -.2f, -.5f, 1);
    assert(!update(1.74, 0, 1, 1).pinches);
    assert(!update(1.92, 1, 1, 1).pinches);
    assert(!update(2.02, 1, 1, 1).pinches);
    assert(!update(2.40, 1, 1, 1).pinches);

    reset();
    hand(1, .1f, -.2f, -.5f, 1);
    assert(!update(1.03, 1, 1, 1).pinches);
    hand(0, -.1f, -.2f, -.5f, 1);
    assert(update(1.13, 1, 1, 1).blocked);
    hand(1, .29f, -.2f, -.5f, 1);
    bare_hand_input r = update(1.19, 1, 1, 1);
    assert(r.menu && r.blocked && !r.pinches);
    hand(0, -.1f, -.2f, -.5f, 0);
    hand(1, -.2325f, .1825f, -.5f, 0); // Phone, first tile
    r = update(1.25, 1, 1, 1);
    assert(r.menu && r.hover == BH_PHONE && r.action < 0);
    hand(1, -.2325f, .1825f, -.5f, 1);
    r = update(1.31, 1, 1, 1);
    assert(!r.menu && r.action == BH_PHONE && !r.pinches);
    assert(!update(1.46, 1, 1, 1).pinches);

    reset();
    head[12] = .13f;
    assert(!update(1.03, 1, 1, 1).eject); // Head moved, wrist stayed fixed.
    hand(1, .21f, -.2f, -.5f, 0);
    assert(!update(1.08, 1, 1, 1).eject);
    hand(1, .11f, -.2f, -.5f, 0);
    assert(update(1.13, 1, 1, 1).eject);
    hand(1, .22f, -.2f, -.5f, 0);
    assert(!update(1.18, 1, 1, 1).eject);
    hand(1, .11f, -.2f, -.5f, 0);
    assert(!update(1.23, 1, 1, 1).eject); // Cooldown.

    reset();
    middle[0] = .01f;
    hand(0, -.15f, -.45f, -.28f, 0);
    assert(!update(1.05, 1, 1, 1).movement);
    hand(0, -.15f, -.45f, -.38f, 0);
    assert(update(1.10, 1, 1, 1).movement == BH_FORWARD);
    wrists[0] = 0;
    assert(!update(1.15, 1, 1, 1).movement);
    hand(0, -.15f, -.45f, -.28f, 0);
    assert(!update(1.19, 1, 1, 1).movement);
    hand(0, -.15f, -.45f, -.38f, 0);
    assert(!update(1.24, 1, 1, 1).movement);

    puts("full hand tracking: trigger, tracking loss, action menu, shake and movement passed");
}
