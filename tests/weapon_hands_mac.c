// SPDX-License-Identifier: MIT
#include "../app/Sources/weapon_bridge.c"
#include <assert.h>

static atomic_bool finished;
static void *publish(void *unused) {
    (void)unused;
    for (unsigned n = 1; n <= 20000; n++) {
        float head[16], wrists[20];
        for (int i = 0; i < 16; i++) head[i] = (float)n;
        for (int i = 0; i < 20; i++) wrists[i] = (float)n;
        vx_weapon_bridge_publish_hands(head, wrists, n, (double)n);
    }
    atomic_store(&finished, 1);
    return NULL;
}

int main(void) {
    atomic_store(&commands_enabled, 1);
    float head[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,1.7f,0,1};
    float wrists[20] = {1,-.3f,-1.2f,.4f, 0,0,-1, 1,0,0,
                        1,.3f,.1f,.4f, 0,0,-1, 1,0,0};
    vx_weapon_bridge_publish_hands(head, wrists, 2, 10);
    vx_weapon_hand_frame a = vx_weapon_bridge_hands();
    assert(a.valid && a.sequence == 1 && !memcmp(a.wrists, wrists, sizeof wrists));
    // A head turn/translation must not move the room-space hands or clamp a low hand.
    head[0] = head[10] = 0; head[2] = 1; head[8] = -1; head[12] = .2f;
    vx_weapon_bridge_publish_hands(head, wrists, 0, 11);
    vx_weapon_hand_frame b = vx_weapon_bridge_hands();
    assert(b.valid && b.sequence > a.sequence && !b.buttons);
    assert(!memcmp(a.wrists, b.wrists, sizeof wrists) && b.wrists[2] == -1.2f);
    wrists[1] = NAN;
    vx_weapon_bridge_publish_hands(head, wrists, 0, 12);
    b = vx_weapon_bridge_hands();
    assert(b.valid && !b.wrists[0] && b.wrists[10] == 1);
    wrists[1] = -.3f; head[0] = NAN;
    vx_weapon_bridge_publish_hands(head, wrists, 0, 13);
    b = vx_weapon_bridge_hands(); assert(!b.valid && !b.wrists[0] && !b.wrists[10]);
    head[0] = 0;
    vx_weapon_bridge_publish_hands(head, wrists, 0, 14);
    hand_frame.received_at -= 1;
    b = vx_weapon_bridge_hands(); assert(!b.valid && !b.wrists[0] && !b.wrists[10]);

    // The game thread must never see the head from one publication and wrists
    // or controller buttons from another, even while ARKit publishes concurrently.
    pthread_t writer;
    assert(!pthread_create(&writer, NULL, publish, NULL));
    unsigned checked = 0;
    do {
        vx_weapon_hand_frame frame = vx_weapon_bridge_hands();
        if (!frame.valid || frame.sampled_at == 14) continue;
        float n = (float)frame.sampled_at;
        for (int i = 0; i < 16; i++) assert(frame.head[i] == n);
        for (int i = 0; i < 20; i++) assert(frame.wrists[i] == n);
        assert(frame.buttons == (unsigned)n);
        checked++;
    } while (!atomic_load(&finished));
    assert(!pthread_join(writer, NULL) && checked > 0);
    puts("hand frames: independent room poses, button release, stale/invalid data and concurrent publication: ok");
}
