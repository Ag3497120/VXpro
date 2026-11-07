#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
mkdir -p build
clang -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=undefined \
    vr/frame_pipeline.c tests/frame_pipeline_test.c -o build/frame_pipeline_test
build/frame_pipeline_test
clang -fobjc-arc -O2 -Wall -Wextra -Werror -framework Foundation -framework Metal -framework QuartzCore \
    vr/frame_pipeline.c tests/frame_pipeline_bench.m -o build/frame_pipeline_bench
build/frame_pipeline_bench build/frame-pipeline-mac-v1.json
python3 tools/frame_pipeline_report.py build/frame-pipeline-mac-v1.json \
    --output build/frame-pipeline-summary.json
