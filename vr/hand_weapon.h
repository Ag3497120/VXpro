// A gun's magazine handled by hand in vr mode (VX Mac, h70): the off hand takes the magazine out of the grip, takes a
// new one from a pouch and puts it in, as in Half-Life: Alyx - the game's reload sent when the new magazine is in (or
// after the slide is racked, VXMAC_MAG_RACK=1). No game state is read: the hands' motion becomes keys (and, with the
// VX Hands mod, a key for each step: VXMAC_MAG_KEYS).
//   out    the off hand's fist closed on the grip's bottom (the gun hand's little-finger side), pulled 12 cm down
//          out of it within 2.5 s (a support hand held under the grip while aiming is not a magazine)
//   grab   the off hand's fist closed at a pouch: the hip (50 cm below the eyes) or the chest, while the gun is empty
//   in     the fist with the new magazine brought to the grip's bottom and pushed 3 cm up into it
//   rack   (VXMAC_MAG_RACK=1) the off hand's fist on the slide (above the gun hand) pulled 6 cm back
// The gun hand's grip (a fist) gives the grip's line: from the index finger's knuckle down to the little finger's;
// without a fist the grip's bottom is taken 10 cm below the gun hand.
// VXMAC_MAG=1 turns it on (off by default; it takes the place of h68's reload gesture); VXMAC_MAG_TUNE: the thresholds
// by name (hand_weapon_params).
#pragma once

// Each hand's joints in the room's frame (y up), from the system's hand skeleton: HW_JOINTS floats per hand -
// tracked (0/1), then 8 points: the wrist, the index finger's knuckle, the middle finger's knuckle, the little
// finger's knuckle, the middle finger's tip, the ring finger's tip, the little finger's tip, the index finger's tip.
enum { HW_WRIST, HW_INDEX_K, HW_MIDDLE_K, HW_LITTLE_K, HW_MIDDLE_T, HW_RING_T, HW_LITTLE_T, HW_INDEX_T, HW_POINTS };
enum { HW_JOINTS = 1 + HW_POINTS * 3 };

// The steps, as events (bits) and as the gun's state.
enum { HW_EV_OUT = 1, HW_EV_GRAB = 2, HW_EV_IN = 4, HW_EV_RACK = 8, HW_EV_DONE = 16, HW_EV_CANCEL = 32, HW_EV_N = 6 };
enum { HW_LOADED, HW_HOLD_OLD, HW_EMPTY, HW_HOLD_NEW, HW_IN_NO_ROUND };

typedef struct {
    float grip;                         // (0 open .. 1 a fist: the middle, ring and little fingers curled)
    float index;                        // (the index finger's tip from the wrist over its knuckle's: ~1.9 straight)
    float palm[3];                      // (between the wrist and the middle finger's knuckle)
    float fwd[3], across[3];            // (wrist -> middle knuckle; index knuckle -> little knuckle; unit)
    int ok, from_arm;
} hand_pose;

// Visual weapon ownership. Tracking loss never counts as an intentional release.
typedef struct {
    int initialized, owner, support, closed[2];
} hand_weapon_hold;

void hand_weapon_hold_update(hand_weapon_hold *hold, const hand_pose pose[2], int default_owner, int enabled);

#ifndef VX_HAND_BUTTONS_DEFINED
#define VX_HAND_BUTTONS_DEFINED
enum { HW_BTN_L_GRAB = 1u << 0, HW_BTN_L_TRIG = 1u << 1, HW_BTN_R_GRAB = 1u << 2,
       HW_BTN_R_TRIG = 1u << 3, HW_BTN_ACT_A = 1u << 4, HW_BTN_ACT_B = 1u << 5,
       HW_BTN_ACT_X = 1u << 6, HW_BTN_ACT_Y = 1u << 7, HW_BTN_ACTIVE = 1u << 15 };
#endif
enum { HW_MODE_AUTO, HW_MODE_BARE, HW_MODE_HYBRID };
enum { HW_WPN_PISTOL = 0, HW_WPN_RIFLE, HW_WPN_SHOTGUN, HW_WPN_HEAVY, HW_WPN_N };

typedef struct {
    int initialized, support, support_held, consume, fire;
    unsigned previous;
    double support_seen_at;
    float support_palm[3];
} hand_weapon_controller;
// Shared acquisition radius for the input and viewmodel solvers.
#define HW_SUPPORT_RADIUS .18f
#define HW_SUPPORT_RELEASE .22f
#define HW_SUPPORT_CONTACT_GRACE .22
typedef struct {
    float grip, support; // Distance from the free palm to the rendered contacts, in metres.
    int button_support;  // Long guns attach the support hand on ZL, regardless of distance.
} hand_weapon_contact;

// The right trigger fires. The left trigger can only support the weapon.
void hand_weapon_controller_update(hand_weapon_controller *c, const hand_pose pose[2],
                                   unsigned buttons, double now, int enabled, const hand_weapon_contact *contact);
enum { HW_JOY_FIRE = 1, HW_JOY_AIM = 2 };
int hand_weapon_controller_actions(const hand_weapon_controller *c, int enabled, int loaded);
int hand_weapon_aim_angles(const float forward[3], const float head[16], float out[2]);

typedef struct {
    int init, lefty, state, rack;
    int mode, auto_mag, manual_mag, weapon_type, ammo_used, arm_tracked[2], arm_extrapolated[2];
    unsigned manual_prev, manual_ejections;
    double manual_ejected_at;
    double shake_sample_at, shake_started;
    float shake_prev[3], shake_start[3], shake_low;
    int shake_enabled, shake_down;
    int manual_slide_ready, manual_support, has_wrist_frames, wrist_primary;
    int auto_chamber;                  // Rendered long gun; the game still owns the chamber state.
    int game_reload_known, game_reload_phase;
    unsigned game_ammo;
    float wrist_frames[20];
    float well_contact[3];
    int well_contact_model, magazine_grab_model;
    float rack_contact[3], rack_axis[3], rack_start, manual_pull;
    float rack_axis_local[3];
    int rack_contact_valid, rack_suspended;
    float slide_contact[3], slide_axis[3], slide_grab_local[3];
    int auto_approach_ready, reload_block, pull_ready;
    unsigned reload_shots;
    float pull_at[3];
    float forearm_elbow[2][3], forearm_wrist[2][3];
    float last_valid_pos[2][3], last_valid_vel[2][3], last_valid_fwd[2][3], last_valid_across[2][3], last_valid_grip[2];
    double last_valid_t[2], pose_at, ctrl_last_t, buttons_at, well_dwell, draw_dwell;
    hand_pose pose[2];
    unsigned ctrl_btns;
    int prev_gun_btn, prev_off_btn, gun_pressed, gun_released, off_pressed, off_released, draw_zone, well_block;

    double t_prev, state_at, near_at, well_at;
    float off_prev[3], off_vel[3];
    float grab_at[3];                   // (the off hand's palm where its fist closed on the grip / the slide)
    float in_start;                     // (the fist's place along the grip's line when it reached the grip's bottom)
    int off_fist, slide_hold;
    unsigned count[HW_EV_N];
    // for the presenter's drawing (the room's frame)
    int well_ok; float well[3], grip_dir[3];        // (the grip's bottom and the grip's line, upwards into the gun)
    int mag_shown; float mag_at[3], mag_up[3];      // (a magazine in the off hand: its centre and its long axis)
    int near_well;                                  // (the off hand is at the grip's bottom: the target lit)
    // the gun drawn, put away, aimed and fired by hand (hand_weapon_arms)
    int gun_fist, draw_from, in_hip, hip_entered_fist, ads, trigger, trig_frames;
    float idx_s;
    double draw_at, raised_at, ads_since, arm_last[3], gun_seen, off_seen;
    unsigned arm_count[3], ads_count, shots;
    double interact_since[2], interact_last;
    int interact_ready[2], weapon_drawn;
} hand_weapon;

// The gun hand's other moves (VX Mac, h70b; VXMAC_ARMS=1), as in Half-Life: Alyx:
//   draw    a fist closed at the gun side's hip (weapon 1) or over the gun side's shoulder (weapon 2), brought up in
//           front within 1.5 s
//   holster the gun hand brought down from in front to its hip within 1.5 s and opened there
//   aim     (held) the off hand's palm at the gun hand's (11 cm; above the grip's bottom, where magazines are taken)
//           or 12-50 cm ahead of it in line (a rifle's barrel), the gun raised in front, 0.2 s: the aim button down
//           until they part (17 cm) or the gun is lowered; not while a magazine is out
//   trigger (held, VXMAC_TRIGGER=1) the gun hand's fist with its index finger curled (its tip nearer the wrist than
//           1.55 x its knuckle; let go at 1.68), the gun raised
enum { HW_ARM_DRAW_HIP = 1, HW_ARM_DRAW_BACK = 2, HW_ARM_HOLSTER = 4, HW_ARM_INTERACT = 8, HW_ARM_N = 4 };

void hand_weapon_set_auto_mag(hand_weapon *w, int enabled);
int hand_weapon_has_magazine(const hand_weapon *w);
void hand_weapon_set_arms(hand_weapon *w, const float arms[14]);
void hand_pose_from_wrist(const float wrist[10], hand_pose *pose);
void hand_weapon_set_wrist_frames(hand_weapon *w, const float wrists[20]);
void hand_weapon_set_controller(hand_weapon *w, unsigned btns, double now);
void hand_weapon_sample_poses(hand_weapon *w, const float head[16], const float *joints, double now);
int hand_weapon_is_hybrid(const hand_weapon *w, double now);
void hand_pose_from_joints(const float j[HW_JOINTS], hand_pose *p);
// head: origin from device (column major); joints: left then right, HW_JOINTS each. Returns the steps made this frame.
int hand_weapon_update(hand_weapon *w, const float head[16], const float joints[2 * HW_JOINTS], double now);
// After hand_weapon_update in the same frame: the draw / holster made this frame (HW_ARM_* bits); w->ads and
// w->trigger hold while the aim and the trigger are held (trigger only with use_trigger).
int hand_weapon_arms(hand_weapon *w, const float head[16], const float joints[2 * HW_JOINTS], double now, int use_trigger);
const char *hand_weapon_event_name(int bit);
const char *hand_weapon_state_name(int state);
int hand_weapon_tune(const char *spec);
void hand_weapon_params(char *out, unsigned size);
