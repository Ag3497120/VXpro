#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate correctness-probe evidence; never derive game FPS from CPU ticks."""
import argparse
import hashlib
import json
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(path):
    report = json.loads(path.read_text())
    if report.get("version") != "bounded-frame-pipeline-v1" or report.get("passed") is not True:
        raise ValueError(f"{path}: failed or unsupported probe")
    for key in ("game_fps_measurement", "real_display_measurement", "controller_latency_measurement", "npu_model_used", "r1_access"):
        if report.get(key) is not False:
            raise ValueError(f"{path}: unexpected measurement scope: {key}")
    cases = report["cases"]
    if len(cases) != 3 or [c["stress"] for c in cases] != [False, False, True]:
        raise ValueError(f"{path}: missing baseline/buffered/stress cases")
    if cases[0]["delay_ms"] != 0 or not 0 < cases[1]["delay_ms"] < 80 or cases[1]["delay_ms"] != cases[2]["delay_ms"]:
        raise ValueError(f"{path}: incorrect delay cases")
    memory = []
    for c in cases:
        if any(c[k] is not True for k in ("passed", "drained", "idle", "stress_coverage")):
            raise ValueError(f"{path}: incomplete GPU drain or stress coverage")
        if c["errors"] or c["rejected_callbacks"] or c["validated_gpu_outputs"] <= 30:
            raise ValueError(f"{path}: insufficient or mismatched GPU outputs")
        if not 0 < c["pool_allocated_bytes"] <= c["pool_budget_bytes"] <= 16 * 1024 * 1024:
            raise ValueError(f"{path}: memory budget exceeded")
        if not 0 < c["pool_planned_bytes"] <= c["pool_budget_bytes"] or c["pool_texture_count"] != 8 or c["pool_readback_buffer_count"] != 2:
            raise ValueError(f"{path}: unexpected pool layout")
        if not 0 < c["max_pending_frames"] <= 3 or c["input_bypasses"] <= 0 or c["repeats"] <= 0:
            raise ValueError(f"{path}: missing repeated display / input bypass coverage")
        memory.append(c["pool_allocated_bytes"])
    if len(set(memory)) != 1:
        raise ValueError(f"{path}: cases allocated different image pools")
    if any(cases[2][k] <= 0 for k in ("capacity_drops", "late_bypasses", "reordered_completions", "injected_failures")):
        raise ValueError(f"{path}: stress case did not exercise required conditions")
    return {"path": str(path), "sha256": digest(path), "device": report["device"], "os": report["os"],
            "gpu_outputs_checked": sum(c["validated_gpu_outputs"] for c in cases),
            "pool_allocated_bytes": memory[0], "errors": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", type=Path, nargs="+")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    sources = [root / p for p in ("vr/frame_pipeline.c", "vr/frame_pipeline.h", "tests/frame_pipeline_test.c",
                                 "tests/frame_pipeline_bench.m", "tests/frame_pipeline_bench.h",
                                 "tests/frame_pipeline_app.swift", "tests/frame_pipeline_app/project.yml")]
    result = {"status": "prototype_verified_not_adopted", "evidence": [validate(p) for p in args.reports],
              "current_source_sha256": {str(p.relative_to(root)): digest(p) for p in sources},
              "scope": "independent offscreen Metal correctness probe; no real display or game timing",
              "unknown": ["game FPS improvement", "headset display cadence", "controller-to-photon latency",
                          "super-resolution quality", "NPU speedup", "foreground separation in the game"]}
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": result["status"], "devices": [e["device"] for e in result["evidence"]],
                      "gpu_outputs_checked": sum(e["gpu_outputs_checked"] for e in result["evidence"])}, ensure_ascii=False))


if __name__ == "__main__":
    main()
