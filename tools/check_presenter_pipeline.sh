#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_dir=build/frame-pipeline-integration
mkdir -p "$task_dir"
clang -O1 -g -fobjc-arc -fblocks -framework Foundation -framework Metal -framework QuartzCore -framework CoreText \
    -Wl,-dead_strip tests/presenter_pipeline_mac.m vr/frame_pipeline.c vr/warp_core.m \
    vr/hand_weapon.c vr/hand_gestures.c app/Sources/weapon_bridge.c \
    -o "$task_dir/presenter_pipeline_mac"
"$task_dir/presenter_pipeline_mac" on "$task_dir/presenter-on.json"
"$task_dir/presenter_pipeline_mac" off "$task_dir/presenter-off.json"
