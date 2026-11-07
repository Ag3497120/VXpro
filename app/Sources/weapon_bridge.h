// SPDX-License-Identifier: MIT
#pragma once

#include <stdint.h>

struct mach_header;

typedef struct {
    uint64_t entity, record, generation;
    int known, ranged;
    int type_known, reload_known, handgun, revolver, reload_phase;
    uint32_t ammo, capacity;
    uint64_t reload_report;
    uint64_t shot_count;
    uint64_t command_serial;
    int command_kind, command_status;
    float muzzle[3], forward[3];
} vx_weapon_snapshot;

enum { VX_WEAPON_EJECT = 1, VX_WEAPON_INSERT, VX_WEAPON_CHAMBER };
enum { VX_COMMAND_NONE, VX_COMMAND_PENDING, VX_COMMAND_ACCEPTED, VX_COMMAND_REJECTED,
       VX_COMMAND_TIMEOUT };

void vx_weapon_bridge_prepare(const struct mach_header *image);
void vx_weapon_bridge_poll(void);
vx_weapon_snapshot vx_weapon_bridge_snapshot(void);

typedef struct {
    int known, mounted, vehicle_mode, scene_tier;
    int menu_known, menu_open;
    unsigned script_revision;
    int camera_known, vehicle_perspective, vehicle_pitch_ready, vehicle_fov_owned;
    float native_fov, foot_fov;
    uint64_t sequence;
    double received_at, camera_received_at;
} vx_game_context;
// Independent of equipment: vehicle triggers must work with no weapon equipped.
vx_game_context vx_weapon_bridge_context(void);
// Experimental game-thread mailbox. Acceptance is separate from reload completion:
// ammunition and chamber readiness still come only from the game's R reports.
int vx_weapon_bridge_commands_enabled(void);
int vx_weapon_bridge_commands_ready(void);
uint64_t vx_weapon_bridge_command(int kind);

typedef struct {
    uint64_t sequence;
    double sampled_at, received_at;
    float head[16], wrists[20]; // One room-space sample: left then right, no weapon constraints.
    unsigned buttons;
    int valid;
} vx_weapon_hand_frame;

void vx_weapon_bridge_publish_hands(const float head[16], const float wrists[20],
                                    unsigned buttons, double sampled_at);
vx_weapon_hand_frame vx_weapon_bridge_hands(void);

// Small read-only status for the host's atomic status file. No native object
// pointer is retained; only image-relative vtable identities and counts.
typedef struct {
    int attached, commands_ready;
    uint64_t pose_vtable[4], pose_observations[4]; // Player/weapon controllers, player/weapon roots.
} vx_weapon_bridge_diagnostic;
vx_weapon_bridge_diagnostic vx_weapon_bridge_diagnostics(void);
void vx_weapon_bridge_status_json(char *out, unsigned size);
