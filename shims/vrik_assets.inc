// SPDX-License-Identifier: MIT
typedef struct {
    uint64_t hash;
    uint32_t count;
    uint16_t asset, bones;
    int8_t root, trigger, slide, cylinder, hinge, support;
    uint8_t kind; // receiver, loose ammo, revolver, handgun
    uint64_t ammo;
    float root_at[3], trigger_at[3], slide_at[3], cylinder_at[3], hinge_at[3], support_at[3], ammo_at[3];
} vrik_asset_profile;

#if !defined(VRIK_ASSET_NO_LOCAL) && __has_include("../build/hand-session-v2/weapon_asset_catalog.h")
#include "../build/hand-session-v2/weapon_asset_catalog.h"
#else
static const vrik_asset_profile vrik_assets[1];
#define VRIK_ASSET_COUNT 0
#endif

static unsigned vrik_asset_first(NSUInteger count) {
    unsigned lo = 0, hi = VRIK_ASSET_COUNT;
    while (lo < hi) {
        unsigned mid = lo + (hi - lo) / 2;
        if (vrik_assets[mid].count < count) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

static const vrik_asset_profile *vrik_asset_match(NSUInteger count, uint64_t hash) {
    for (unsigned i = vrik_asset_first(count); i < VRIK_ASSET_COUNT && vrik_assets[i].count == count; i++)
        if (vrik_assets[i].hash == hash) return &vrik_assets[i];
    return NULL;
}
