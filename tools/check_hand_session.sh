#!/bin/sh
# SPDX-License-Identifier: MIT
# Local checks; no app/device/session is launched. Optional argument: the user's
# private 2.5.0 dylib with macOS load commands for the native string ABI test.
set -eu
vxmac_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir="$vxmac_dir/build/hand-session-v2/checks"
mkdir -p "$check_dir"
for test_name in weapon_bridge_mac weapon_commands_mac weapon_hands_mac; do
    xcrun clang -O2 -Wall -Wextra -Werror "$vxmac_dir/tests/$test_name.c" -o "$check_dir/$test_name"
    "$check_dir/$test_name"
done
xcrun -sdk macosx metal -c "$vxmac_dir/tests/vrik_palette_copy.metal" -o "$check_dir/vrik_palette_copy.air"
xcrun -sdk macosx metallib "$check_dir/vrik_palette_copy.air" -o "$check_dir/vrik_palette_copy.metallib"
xcrun clang -O2 -fobjc-arc -fblocks -framework Foundation -framework Metal -framework QuartzCore \
    "$vxmac_dir/tests/vrik_grip_alignment_mac.m" -o "$check_dir/vrik_grip_alignment_mac"
VXMAC_TEST_POSE_LIBRARY="$check_dir/vrik_palette_copy.metallib" "$check_dir/vrik_grip_alignment_mac"
if [ -n "${VXMAC_TEST_METAL_SHIM:-}" ]; then
    xcrun clang -O2 -fobjc-arc -fblocks -framework Foundation -framework Metal -framework QuartzCore \
        "$vxmac_dir/tests/pose_resource_lifetime_mac.m" -o "$check_dir/pose_resource_lifetime_mac"
    VXMAC_MAC_TEST=1 DYLD_INSERT_LIBRARIES="$VXMAC_TEST_METAL_SHIM" "$check_dir/pose_resource_lifetime_mac"
fi
if [ "$#" -gt 0 ]; then
    image_dir=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)
    xcrun clang -O2 -Wall -Wextra -Werror "$vxmac_dir/tests/weapon_bridge_native_mac.c" \
        "-Wl,-rpath,$image_dir" -o "$check_dir/weapon_bridge_native_mac"
    "$check_dir/weapon_bridge_native_mac" "$image_dir/$(basename -- "$1")"
fi
