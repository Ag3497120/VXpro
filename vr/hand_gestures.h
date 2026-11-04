// Hand gestures for the game's actions in vr mode (VX Mac, h68): reload, quick melee, grenade and heal from the hands'
// motion, Half-Life: Alyx style, as the keys the game already has. No game state is read: the gestures become the
// same key presses and mouse clicks a keyboard would make (the game's default bindings, inputUserMappings.xml).
//   reload   the off hand down to the hip (50 cm below the eyes), then up to the gun hand within 1.5 s: R
//   melee    the gun hand punched forward (over 2.2 m/s, in front of the body): Q
//   grenade  the off hand raised to the head, then thrown forward (over 2.0 m/s) within 0.8 s: the middle button
//   heal     either hand's index finger at the mouth for 0.4 s: X
// VXMAC_GESTURES=0 turns them off; VXMAC_GESTURE_LEFTY=1: the gun hand is the left. With them on, the
// first VXMAC_HAND_RECORD=5 minutes of hands in vr mode go to Documents/hand_record.csv (0: none) for
// tests/hand_gestures_replay.c.
#pragma once

enum { HG_RELOAD = 1, HG_MELEE = 2, HG_GRENADE = 4, HG_HEAL = 8, HG_INTERACT = 16, HG_SCAN = 32, HG_N = 6 };

typedef struct {
    int init, lefty;
    int climbing, climb_last_hand; float climb_dir; double climb_until, climb_stroke_at;
    double t_prev;
    float p_prev[2][3], vel[2][3];      // (each hand's anchor and its smoothed velocity in the room, m/s)
    int suppress_interact, reach_ready, scan_latched;
    int assist, off_button, prev_off_button, scan_button_latched;
    double reach_since, scan_since;
    int fast[2];                        // (consecutive frames over the punch speed)
    double up_at, hip_at, raised_at, mouth_since[2];
    double last[HG_N];                  // (each gesture's last time, for its cooldown)
    unsigned count[HG_N];
} hand_gestures;

// head: origin from device (column major, the room's frame, y up); hands: per hand (left, right) 10 floats -
// tracked (0/1), the thumb's tip, the index finger's tip, the pointing anchor. Returns the gestures made this frame
// (HG_* bits).
void hand_gestures_arm_pose(float hands[20], int side, const float palm[3], const float across[3]);
void hand_gestures_set_controller(hand_gestures *g, int assist, int off_button);
int hand_gestures_update(hand_gestures *g, const float head[16], const float hands[20], double now);
const char *hand_gesture_name(int bit);
// The thresholds by name, "punch_speed=2.0,mouth_r=0.1" (VXMAC_GESTURE_TUNE; the names: hand_gestures_params).
// Returns how many were set.
int hand_gestures_tune(const char *spec);
void hand_gestures_params(char *out, unsigned size);
