#define main hand_weapon_full_suite
#include "hand_weapon_mac.c"
#undef main
#include <assert.h>

static void buttons(unsigned b) { hand_weapon_set_controller(&w, b, t); }

static void rack_frame(float wrists[20], int moved, int free_valid) {
    float shift = moved ? .12f : 0;
    wrists[0] = free_valid;
    wrists[1] = -.08f;
    wrists[2] = 1.32f;
    wrists[3] = -.52f + shift;
    wrists[6] = -1;
    wrists[10] = 1;
    wrists[11] = .10f;
    wrists[12] = 1.28f;
    wrists[13] = -.32f + shift;
    wrists[16] = -1;
    w.rack_contact_valid = 4;
    w.rack_contact[0] = -.08f;
    w.rack_contact[1] = 1.32f;
    w.rack_contact[2] = -.55f + shift;
    w.rack_axis[2] = -1;
    hand_weapon_set_wrist_frames(&w, wrists);
}

static int shake_frame(float wrists[20], float x, float y, int tracked) {
    wrists[10] = tracked;
    wrists[11] = x;
    wrists[12] = y;
    hand_weapon_set_wrist_frames(&w, wrists);
    t += .04;
    return hand_weapon_update(&w, head, joints, t);
}

int main(void) {
    reset(0, 0); w.manual_mag = 1; w.rack = 1;
    buttons(HW_BTN_ACT_X); step();
    assert(w.state == HW_EMPTY && seen[0] == 1 && seen[4] == 0);
    double ejected_at = w.state_at;
    buttons(0); hold(.2);
    buttons(HW_BTN_ACT_X); step();
    assert(w.state == HW_EMPTY && seen[0] == 2 && w.manual_ejections == 1 && w.state_at == ejected_at);
    buttons(0); step();
    float hip[3] = { -.15f, 1.0f, -.05f };
    move(off_h, hip, .1f, .4);
    hold(.3); assert(w.state == HW_EMPTY && seen[1] == 0);
    buttons(HW_BTN_L_TRIG); step();
    assert(w.state == HW_HOLD_NEW && seen[1] == 1);
    move(off_h, WELL, .1f, .4);
    assert(w.state == HW_IN_NO_ROUND && seen[2] == 1 && seen[4] == 0);
    w.game_reload_known=1;w.game_reload_phase=5;w.game_ammo=0;
    buttons(0);hold(.3);
    assert(w.state==HW_IN_NO_ROUND && seen[4]==0); // do not auto-complete a seated, unchambered magazine
    buttons(0); step();
    float slide[3];
    const float *ik = joints + gun_h * HW_JOINTS + 1 + HW_INDEX_K * 3;
    for (int i = 0; i < 3; i++) slide[i] = ik[i] + w.grip_dir[i] * .04f;
    move(off_h, slide, .1f, .4);
    buttons(HW_BTN_L_TRIG); step();
    slide[2] += .10f; move(off_h, slide, .1f, .4);
    assert(w.state == HW_LOADED && seen[3] == 1 && seen[4] == 1);

    reset(0, 0);
    w.manual_mag = w.auto_chamber = 1;
    buttons(HW_BTN_ACT_X); step();
    assert(!hand_weapon_has_magazine(&w) && seen[0] == 1);
    move(off_h, hip, .1f, .4);
    buttons(HW_BTN_L_TRIG); step();
    assert(w.state == HW_HOLD_NEW && seen[2] == 0);
    move(off_h, WELL, .1f, .4);
    assert(w.state == HW_LOADED && hand_weapon_has_magazine(&w) && seen[2] == 1);
    assert(seen[3] == 0 && seen[4] == 0); // Insertion is the sole game command.
    buttons(0); step();
    move(off_h, slide, .1f, .4);
    buttons(HW_BTN_L_TRIG); step();
    assert(!w.slide_hold && seen[4] == 0);

    reset(1, 0); w.manual_mag = 1;
    buttons(HW_BTN_ACT_X); step(); assert(w.state == HW_EMPTY);
    buttons(0); step();
    hip[0] = .15f;
    move(off_h, WELL, .1f, .4);
    buttons(HW_BTN_R_TRIG); step(); assert(w.state == HW_EMPTY);
    move(off_h, hip, .1f, .4);
    assert(w.state == HW_HOLD_NEW);
    move(off_h, WELL, .1f, .4); assert(w.state == HW_IN_NO_ROUND);
    buttons(HW_BTN_L_TRIG); step(); assert(w.state == HW_IN_NO_ROUND && seen[4] == 0);
    buttons(0); step();
    ik = joints + gun_h * HW_JOINTS + 1 + HW_INDEX_K * 3;
    for (int i = 0; i < 3; i++) slide[i] = ik[i] + w.grip_dir[i] * .04f;
    move(off_h, slide, .1f, .4);
    buttons(HW_BTN_R_TRIG); step();
    slide[2] += .10f; move(off_h, slide, .1f, .4);
    assert(w.state == HW_LOADED && seen[4] == 1);
    hold(.3); assert(seen[4] == 1);
    reset(0, 0); w.manual_mag = 1; w.state = HW_IN_NO_ROUND;
    float wrists[20] = {0};
    rack_frame(wrists, 0, 1);
    buttons(HW_BTN_R_TRIG); step();
    assert(w.state == HW_IN_NO_ROUND && seen[3] == 0 && seen[4] == 0);
    buttons(0); step();
    wrists[3] -= .28f;
    hand_weapon_set_wrist_frames(&w, wrists);
    buttons(HW_BTN_L_TRIG); step();
    assert(!w.slide_hold);
    rack_frame(wrists, 0, 1); step(); // Approach after ZL is already down.
    assert(w.slide_hold && seen[3] == 0);
    rack_frame(wrists, 1, 1); step(); // Both hands move together.
    assert(w.slide_hold && seen[3] == 0 && w.manual_pull < .001f);
    rack_frame(wrists, 1, 0); step();
    assert(w.slide_hold && seen[3] == 0);
    rack_frame(wrists, 1, 1); step(); // Still holding the same button.
    assert(w.slide_hold && seen[3] == 0 && w.manual_pull < .001f);
    buttons(0); step();
    buttons(HW_BTN_L_TRIG); step(); assert(w.slide_hold);
    wrists[3] += .06f; // Only the racking hand pulls back.
    hand_weapon_set_wrist_frames(&w, wrists); step();
    assert(w.state == HW_LOADED && seen[3] == 1 && seen[4] == 1);
    // An already loaded weapon can be manually cycled after drawing it.
    rack_frame(wrists, 0, 1);
    buttons(0); step();
    buttons(HW_BTN_L_TRIG); step(); assert(w.slide_hold);
    wrists[3] += .06f;
    hand_weapon_set_wrist_frames(&w, wrists); step();
    assert(w.state == HW_LOADED && seen[3] == 2 && seen[4] == 2);
    // The controller hides all finger joints. Wrist poses alone must allow
    // pouch pickup and insertion. Losing the weapon wrist blocks insertion.
    reset(0, 0);
    w.manual_mag = w.wrist_primary = 1;
    memset(wrists, 0, sizeof wrists);
    for (int h = 0; h < 2; h++) {
        float *wrist = wrists + 10 * h;
        wrist[0] = 1;
        wrist[1] = h ? .10f : -.15f;
        wrist[2] = h ? 1.28f : 1.0f;
        wrist[3] = h ? -.32f : -.05f;
        wrist[6] = -1;
        wrist[7] = -1;
    }
    float missing_joints[2 * HW_JOINTS] = {0};
    hand_weapon_set_wrist_frames(&w, wrists);
    buttons(HW_BTN_ACT_X);
    t += .016;
    assert(hand_weapon_update(&w, head, missing_joints, t) & HW_EV_OUT);
    buttons(HW_BTN_L_TRIG);
    t += .016;
    assert(hand_weapon_update(&w, head, missing_joints, t) & HW_EV_GRAB);
    w.well_contact_model = 3;
    memcpy(w.well_contact, w.well, sizeof w.well);
    w.well_contact[0] += .23f; // The tilted gun's displayed well differs from the wrist estimate.
    memcpy(wrists + 1, w.well, sizeof w.well);
    wrists[3] += .035f;
    hand_weapon_set_wrist_frames(&w, wrists);
    t += .016;
    assert(!(hand_weapon_update(&w, head, missing_joints, t) & HW_EV_IN));
    w.well_contact_model = 0; // Missing draw must not fall back to the old estimate mid-insertion.
    t += .016;
    assert(!(hand_weapon_update(&w, head, missing_joints, t) & HW_EV_IN));
    w.well_contact_model = 3;
    memcpy(wrists + 1, w.well_contact, sizeof w.well_contact);
    wrists[3] += .035f;
    wrists[10] = 0;
    hand_weapon_set_wrist_frames(&w, wrists);
    t += .016;
    assert(!(hand_weapon_update(&w, head, missing_joints, t) & HW_EV_IN));
    assert(w.state == HW_HOLD_NEW);
    wrists[10] = 1;
    hand_weapon_set_wrist_frames(&w, wrists);
    t += .016;
    assert(hand_weapon_update(&w, head, missing_joints, t) & HW_EV_IN);
    reset(0, 0);
    w.manual_mag = w.shake_enabled = w.wrist_primary = 1;
    shake_frame(wrists, .10f, 1.30f, 1);
    assert(!shake_frame(wrists, .10f, 1.23f, 1));
    assert(!shake_frame(wrists, .10f, 1.16f, 1)); // A quick lowering alone does not eject.
    assert(!shake_frame(wrists, .10f, 1.20f, 0));
    assert(!shake_frame(wrists, .10f, 1.25f, 1)); // Tracking reacquisition cannot finish the shake.
    assert(!shake_frame(wrists, .26f, 1.18f, 1));
    assert(!shake_frame(wrists, .26f, 1.11f, 1)); // A lateral motion does not count.
    assert(!shake_frame(wrists, .26f, 1.18f, 1));
    buttons(HW_BTN_R_TRIG);
    assert(!shake_frame(wrists, .26f, 1.11f, 1));
    assert(!shake_frame(wrists, .26f, 1.04f, 1));
    assert(!shake_frame(wrists, .26f, 1.13f, 1)); // Recoil motion with ZR held cannot eject.
    buttons(0);
    assert(!shake_frame(wrists, .26f, 1.30f, 1));
    assert(!shake_frame(wrists, .26f, 1.23f, 1));
    assert(!shake_frame(wrists, .26f, 1.16f, 1));
    assert(shake_frame(wrists, .26f, 1.24f, 1) & HW_EV_OUT);
    assert(w.state == HW_EMPTY && w.manual_ejections == 1);
    assert(!shake_frame(wrists, .26f, 1.16f, 1));
    assert(!shake_frame(wrists, .26f, 1.24f, 1));
    assert(w.manual_ejections == 1);
    reset(0, 0);
    w.manual_mag = w.wrist_primary = 1;
    w.state = HW_IN_NO_ROUND;
    memset(wrists, 0, sizeof wrists);
    rack_frame(wrists, 0, 1);
    wrists[1] += .070f; // Approach beside the slide, rather than its exact centre.
    wrists[7] = -1; wrists[17] = 1;
    hand_weapon_set_wrist_frames(&w, wrists);
    buttons(0); step();
    assert(!w.slide_hold);
    buttons(HW_BTN_L_TRIG); step();
    assert(w.slide_hold && fabsf(w.slide_contact[0] - w.rack_contact[0]) < .001f);
    assert(fabsf(w.slide_axis[2] + 1.f) < .001f);
    float snapped_z = w.slide_contact[2];
    wrists[3] += .020f;
    hand_weapon_set_wrist_frames(&w, wrists); step();
    assert(w.slide_hold && fabsf(w.manual_pull - .020f) < .001f);
    assert(fabsf(w.slide_contact[2] - snapped_z - .020f) < .001f);
    buttons(0); step();
    assert(!w.slide_hold && seen[4] == 0); // Releasing ZL detaches without chambering.
    buttons(HW_BTN_L_TRIG); step();
    assert(w.slide_hold);
    wrists[3] += .050f;
    hand_weapon_set_wrist_frames(&w, wrists); step();
    assert(!w.slide_hold && w.state == HW_LOADED && seen[4] == 1);

    // The physical insertion/cocking stroke cannot shake its magazine back out.
    w.state = HW_IN_NO_ROUND;
    w.state_at = t - 2;
    w.shake_enabled = 1;
    buttons(0);
    shake_frame(wrists, .10f, 1.30f, 1);
    assert(!shake_frame(wrists, .10f, 1.23f, 1));
    assert(!shake_frame(wrists, .10f, 1.16f, 1));
    assert(!shake_frame(wrists, .10f, 1.24f, 1));
    assert(w.state == HW_IN_NO_ROUND);
    printf("manual reload: pouch, rendered well, slide contact snap, pull/release and shake isolation: ok\n");
    return 0;
}
