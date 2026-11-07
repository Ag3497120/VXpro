#!/bin/sh
# SPDX-License-Identifier: MIT
# Reversible local checks only. Does not launch or install a game.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
out=${VXMAC_CHECK_DIR:-build/release-controls-v1}
mkdir -p "$out"
xcrun clang -O2 -Wall -Wextra -Werror -fobjc-arc -fblocks -framework Foundation -framework Metal tests/frame_camera_mac.m -o "$out/frame_camera_mac"
"$out/frame_camera_mac"
xcrun clang -O2 -Wall -Wextra -Werror tests/view_stability_test.c -o "$out/view_stability_test"
"$out/view_stability_test"
xcrun clang -O2 -Wall -Wextra -Werror tests/room_contact_test.c -o "$out/room_contact_test"
"$out/room_contact_test"
for test in hand_weapon_manual_mac hand_weapon_rack_mac hand_weapon_controller_mac hand_weapon_hold_mac mag_capture_mac; do
    xcrun clang -O2 -I vr "tests/$test.c" vr/hand_weapon.c -o "$out/$test"
    "$out/$test"
done
xcrun clang -O2 -fobjc-arc -framework Foundation -I app/Sources tests/raw_input_mac.m -o "$out/raw_input_mac"
"$out/raw_input_mac"
xcrun clang -O2 tests/script_manual_overlay_mac.c -o "$out/script_manual_overlay_mac"
"$out/script_manual_overlay_mac"
xcrun clang -O2 -fobjc-arc -fblocks -framework Foundation -framework Metal -framework QuartzCore tests/warp_edge_fill_mac.m -o "$out/warp_edge_fill_mac"
"$out/warp_edge_fill_mac"
sh tools/check_hand_session.sh
