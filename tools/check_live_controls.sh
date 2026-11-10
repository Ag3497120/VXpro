#!/bin/sh
# SPDX-License-Identifier: MIT
# Actual presenter/menu GPU tests; no game, device or account session.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
out=${VXMAC_LIVE_CHECK_DIR:-build/live-controls-check}
mkdir -p "$out"
xcrun clang -O2 -Wall -Wextra -Werror -fobjc-arc -framework Foundation -framework GameController tests/mode_input_mac.m -o "$out/mode_input_mac"
"$out/mode_input_mac"
xcrun clang -O2 -Wall -Wextra -Werror tests/hand_melee_test.c -o "$out/hand_melee_test"
"$out/hand_melee_test"
for test in menu_transition_mac control_mode_mac; do
    clang -O1 -g -fobjc-arc -fblocks -framework Foundation -framework Metal -framework QuartzCore -framework CoreText \
        -Wl,-dead_strip "tests/$test.m" vr/frame_pipeline.c vr/warp_core.m \
        vr/hand_weapon.c vr/hand_gestures.c app/Sources/weapon_bridge.c -o "$out/$test"
    "$out/$test" "$out/$test.json"
done
