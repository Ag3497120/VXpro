#include "hand_weapon.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    hand_weapon_controller c = {0};
    hand_pose p[2] = {{.ok = 1}, {.ok = 1}};
    hand_weapon_contact rendered = { .05f, .30f };
    unsigned both = HW_BTN_L_TRIG | HW_BTN_R_TRIG;
    hand_weapon_controller_update(&c, p, both, 1.00, 1, &rendered);
    assert(!c.fire && !c.support);
    hand_weapon_controller_update(&c, p, 0, 1.05, 1, &rendered);
    hand_weapon_controller_update(&c, p, HW_BTN_L_TRIG, 1.10, 1, &rendered);
    assert(!c.fire && !c.support); // A left tap at the trigger cannot take the gun.
    hand_weapon_controller_update(&c, p, 0, 1.16, 1, &rendered);
    hand_weapon_controller_update(&c, p, HW_BTN_R_TRIG, 1.20, 1, &rendered);
    assert(c.fire && !c.support);
    assert(hand_weapon_controller_actions(&c, 1, 1) == HW_JOY_FIRE);
    assert(hand_weapon_controller_actions(&c, 1, 0) == 0);
    hand_weapon_controller_update(&c, p, HW_BTN_L_TRIG, 1.24, 1, &rendered);
    assert(!c.fire && !c.support);
    rendered.support = .06f; // The held left trigger can approach the foregrip.
    hand_weapon_controller_update(&c, p, both, 1.26, 1, &rendered);
    assert(hand_weapon_controller_actions(&c, 1, 1) == (HW_JOY_FIRE | HW_JOY_AIM));
    rendered.support = .47f; // The recorded foregrip jumps from .09 m to .47 m during ADS.
    hand_weapon_controller_update(&c, p, HW_BTN_L_TRIG, 1.30, 1, &rendered);
    assert(c.support && !c.fire);
    rendered.support = INFINITY;
    hand_weapon_controller_update(&c, p, HW_BTN_L_TRIG, 1.33, 1, &rendered);
    assert(c.support && !c.fire);
    hand_weapon_controller_update(&c, p, HW_BTN_L_TRIG, 1.50, 1, &rendered);
    assert(!c.support && !c.fire);
    rendered.support = .06f;
    p[0].from_arm = 2;
    hand_weapon_controller_update(&c, p, HW_BTN_L_TRIG, 1.52, 1, &rendered);
    assert(!c.support);
    p[0].from_arm = 0;
    hand_weapon_controller_update(&c, p, HW_BTN_L_TRIG, 1.54, 1, &rendered);
    assert(c.support && !c.fire);
    p[0].palm[0] += .13f;
    rendered.support = .47f;
    hand_weapon_controller_update(&c, p, HW_BTN_L_TRIG, 1.545, 1, &rendered);
    assert(!c.support);
    hand_weapon_controller_update(&c, p, 0, 1.55, 1, &rendered);
    assert(!c.support && !c.fire);
    hand_weapon_controller_update(&c, p, 0, 1.60, 0, NULL);
    assert(!c.initialized && !c.fire);

    rendered.button_support = 1;
    rendered.grip = rendered.support = INFINITY;
    p[0].palm[0] = -2.f;
    hand_weapon_controller_update(&c, p, 0, 2.00, 1, &rendered);
    hand_weapon_controller_update(&c, p, HW_BTN_L_TRIG, 2.01, 1, &rendered);
    assert(c.support && hand_weapon_controller_actions(&c, 1, 1) == HW_JOY_AIM);
    p[0].ok = 0; // ZL attaches the authored support pose even outside left-hand tracking.
    hand_weapon_controller_update(&c, p, both, 2.02, 1, &rendered);
    assert(c.support && c.fire);
    hand_weapon_controller_update(&c, p, HW_BTN_R_TRIG, 2.03, 1, &rendered);
    assert(!c.support && c.fire);
    hand_weapon_controller_update(&c, p, both, 2.04, 0, &rendered);
    assert(!c.initialized && !c.support && !c.fire); // Menus release both actions.
    hand_weapon_controller_update(&c, p, both, 2.05, 1, &rendered);
    assert(c.support && !c.fire); // Returning with ZR held still requires its release.
    p[0].ok = 1;

    const float head[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,1.7f,0,1};
    float aim[2];
    assert(hand_weapon_aim_angles((float[3]){.5f,0,-.8660254f}, head, aim));
    assert(fabsf(aim[0] + 30.f) < .01f && fabsf(aim[1]) < .01f);
    assert(hand_weapon_aim_angles((float[3]){0,.3f,-.9539392f}, head, aim));
    assert(fabsf(aim[0]) < .01f && aim[1] > 17.f);
    // Turning the head changes the visible cone, not the world-space shot heading.
    const float turned[16] = {.8660254f,0,.5f,0, 0,1,0,0, -.5f,0,.8660254f,0, 0,1.7f,0,1};
    assert(hand_weapon_aim_angles((float[3]){.5f,0,-.8660254f}, turned, aim));
    assert(fabsf(aim[0] + 30.f) < .01f);
    assert(!hand_weapon_aim_angles((float[3]){0,-1,0}, head, aim));
    assert(!hand_weapon_aim_angles((float[3]){0,0,1}, head, aim));
    puts("fixed right-hand firing, left support, and off-axis aim limits: ok");
    return 0;
}
