#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Summarize verified native synthetic GPU/ANE trials, not game frame rates.

Latency summaries are medians of per-block medians, not pooled percentiles.
Only compare the same number of in-flight slots; keep thermal states visible.
"""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import statistics


def spread(values):
    return {"median": statistics.median(values), "min": min(values), "max": max(values), "blocks": len(values)}


def summarize(path):
    raw = path.read_bytes()
    report = json.loads(raw)
    if report.get("benchmark_version") != "fixed-sr-offload-v2-slot-ownership":
        raise ValueError(f"{path}: older unsafe slot ownership; results are not accepted")
    if "blocks" not in report or not report.get("backings_verified"):
        raise ValueError(f"{path}: no verified measurement")
    if not all(case.get("accepted") and case["max_byte_error"] <= 3 for case in report["quality"]["cases"]):
        raise ValueError(f"{path}: quality comparison failed")
    groups = defaultdict(list)
    capacities = {"gpu_only": 2, "offload_overlap": 2, "gpu_serial": 1, "offload_serial": 1}
    for block in report["blocks"]:
        if block["mode"] not in capacities or block["slots"] != capacities[block["mode"]]:
            raise ValueError("unknown mode or mismatched pipeline capacity")
        if not block.get("frame_stamps_verified") or block["frames"] < 3:
            raise ValueError("stale/unverified frames or insufficient block length")
        groups[(block["work_iterations"], block["mode"])].append(block)
    rows, comparisons = [], []
    lookup = {}
    for (work, mode), blocks in sorted(groups.items()):
        row = {"work_iterations": work, "mode": mode, "slots": capacities[mode], "frames": sum(b["frames"] for b in blocks),
               "block_period_ms": spread([b["elapsed_ms"]/b["frames"] for b in blocks]),
               "completion_interval_block_means_ms": spread([b["completion_interval_ms"]["mean"] for b in blocks]),
               "frame_ready_age_block_medians_ms": spread([b["frame_ready_age_ms"]["median"] for b in blocks]),
               "frame_ready_age_block_p95_ms": spread([b["frame_ready_age_ms"]["p95"] for b in blocks]),
               "postprocess_gpu_command_block_medians_ms": spread([b["postprocess_and_compose_gpu_ms"]["median"] for b in blocks]),
               "inference_block_medians_ms": spread([b["coreml_predict_ms"]["median"] for b in blocks]),
               "gpu_command_span_coverage": spread([b["gpu_command_span_coverage"] for b in blocks]),
               "thermal_states": sorted({b[k] for b in blocks for k in ("thermal_start", "thermal_end")})}
        rows.append(row)
        lookup[(work, mode)] = row
    for work in sorted({key[0] for key in groups}):
        for baseline, offload in (("gpu_only", "offload_overlap"), ("gpu_serial", "offload_serial")):
            if (work, baseline) not in lookup or (work, offload) not in lookup:
                continue
            a, b = lookup[(work, baseline)], lookup[(work, offload)]
            period_a, period_b = a["block_period_ms"]["median"], b["block_period_ms"]["median"]
            comparisons.append({"work_iterations": work, "baseline": baseline, "offload": offload,
                                "matched_slots": a["slots"], "gpu_period_ms": period_a, "offload_period_ms": period_b,
                                "offload_throughput_change_percent": 100*(period_a/period_b-1),
                                "gpu_ready_age_ms": a["frame_ready_age_block_medians_ms"]["median"],
                                "offload_ready_age_ms": b["frame_ready_age_block_medians_ms"]["median"],
                                "gpu_block_period_range_ms": [a["block_period_ms"]["min"], a["block_period_ms"]["max"]],
                                "offload_block_period_range_ms": [b["block_period_ms"]["min"], b["block_period_ms"]["max"]]})
    return {"source": str(path), "sha256": hashlib.sha256(raw).hexdigest(), "gpu": report["gpu"], "os": report["os"],
            "scope": report["scope"], "quality": report["quality"], "rows": rows, "comparisons": comparisons,
            "notes": ["block period includes pipeline fill/drain; steady completion intervals are reported separately",
                      "GPU command spans can include scheduling stalls and are not hardware busy-cycle counters",
                      "frame-ready age is not measured headset input-to-photon latency"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", type=Path, nargs="+")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    build = Path(__file__).resolve().parents[1] / "build"
    args.out.resolve().relative_to(build.resolve())
    if args.out.exists():
        parser.error("refusing to overwrite an existing summary")
    output = {"adoption_approved": False, "game_fps_measured": False, "runs": [summarize(p) for p in args.reports]}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(output, indent=2)+"\n")
    for run in output["runs"]:
        print(run["gpu"], run["source"])
        for row in run["comparisons"]:
            print(json.dumps(row))


if __name__ == "__main__":
    main()
