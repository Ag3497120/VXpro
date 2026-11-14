#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_dir=build/frame-pipeline-integration
mkdir -p "$task_dir"
for test in presenter_pipeline_mac presenter_color_mips_mac; do
    clang -O1 -g -fobjc-arc -fblocks -framework Foundation -framework Metal -framework QuartzCore -framework CoreText \
        -Wl,-dead_strip "tests/$test.m" vr/frame_pipeline.c vr/warp_core.m \
        vr/hand_weapon.c vr/hand_gestures.c app/Sources/weapon_bridge.c -o "$task_dir/$test"
done
"$task_dir/presenter_pipeline_mac" on "$task_dir/presenter-on.json"
"$task_dir/presenter_pipeline_mac" off "$task_dir/presenter-off.json"
for mode in full normal velocity full-model model; do
    "$task_dir/presenter_color_mips_mac" "$mode" "$task_dir/mips-$mode.bin" "$task_dir/mips-$mode.json"
done
cmp "$task_dir/mips-full.bin" "$task_dir/mips-normal.bin"
cmp "$task_dir/mips-full.bin" "$task_dir/mips-velocity.bin"
cmp "$task_dir/mips-full-model.bin" "$task_dir/mips-model.bin"
