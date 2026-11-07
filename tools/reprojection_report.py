#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Analyze the standalone native scene test. No game is started.

Presentation indices/times measure Apple's requested cadence, not scanout.
The report intentionally has no inferred 'effective game FPS' field.
"""
import argparse
import json
import math
from pathlib import Path


def analyze(path):
    lines = path.read_text().splitlines()
    rows = []
    for i, line in enumerate(lines):
        try:
            rows.append(json.loads(line))
        except ValueError:
            if i != len(lines)-1:
                raise ValueError("malformed interior record")
    starts = [r for r in rows if r.get("event") == "start"]
    if len(starts) != 1 or len({r.get("session") for r in rows}) != 1:
        raise ValueError("expected one standalone session")
    if starts[0].get("independent_app_reprojection") is not False or starts[0].get("frame_interpolation") is not False:
        raise ValueError("test must not add app-side image correction")
    gpu = {r["source_id"]: r for r in rows if r.get("event") == "gpu"}
    segments = []
    current = None
    last_id = -1
    for r in rows:
        event = r.get("event")
        if event == "phase":
            current = {"key": r["key"], "nominal_fps": r["nominal_fps"],
                       "repeat_count": r["repeat_count"], "frames": []}
            segments.append(current)
        elif event == "paused":
            current = None
        elif event == "frame":
            if r["source_id"] <= last_id:
                raise ValueError("nonmonotonic source IDs")
            last_id = r["source_id"]
            if current is not None:
                if r.get("key") != current["key"] or not r.get("tracked"):
                    raise ValueError("invalid phase/tracking")
                current["frames"].append(r)
    result = []
    for seg in segments:
        frames = seg.pop("frames")
        if len(frames) < 2:
            continue
        # Omit the first second after a phase change: the old frame-repeat setting
        # can still affect the first returned drawable's schedule.
        first = float(frames[0]["presentation_s"])
        used = [r for r in frames if r["presentation_s"] >= first+1]
        warmup_anomalies = sum(b["presentation_s"] <= a["presentation_s"] or
                               b["presentation_index"] <= a["presentation_index"]
                               for a,b in zip(frames,frames[1:]) if b["presentation_s"] < first+1)
        for a, b in zip(used, used[1:]):
            if not (math.isfinite(b["presentation_s"]) and b["presentation_s"] > a["presentation_s"]
                    and b["presentation_index"] > a["presentation_index"]):
                raise ValueError("invalid presentation schedule")
        if len(used) < 2:
            continue
        a, z = used[0], used[-1]
        span = z["presentation_s"]-a["presentation_s"]
        steps = z["presentation_index"]-a["presentation_index"]
        count = len(used)
        completed = [gpu[r["source_id"]] for r in used if r["source_id"] in gpu]
        intervals = [b["presentation_s"]-a["presentation_s"] for a,b in zip(used,used[1:])]
        result.append({**seg, "seconds": span, "source_submissions": count,
            "excluded_warmup_schedule_anomalies":warmup_anomalies,
            "source_submission_fps": (count-1)/span, "scheduled_display_hz": steps/span,
            "unsubmitted_scheduled_slots": steps-(count-1),
            "mean_scheduled_slots_per_source": steps/(count-1),
            "max_source_schedule_interval_ms": max(intervals)*1000,
            "gpu_completion_records": len(completed),
            "gpu_deadline_exceedances": sum(bool(r["late"]) for r in completed),
            "gpu_failures": sum(bool(r["failed"]) for r in completed),
            "capture_target_seen": any(r.get("capture_targets",0) for r in used)})
    return {"session": starts[0]["session"], "plan": starts[0]["plan"],
        "ended": any(r.get("event") == "end" for r in rows),
        "complete": any(r.get("event") == "end" and r.get("completed_test") is True for r in rows), "phases": result,
        "thermal": [{"unix_s":r["unix_s"],"state":r["state"]} for r in rows if r.get("event") == "thermal"],
        "paused": any(r.get("event") == "paused" for r in rows),
        "actual_panel_fps": None, "apple_object_interpolation_measured": False,
        "limits": ["scheduled_display_hz uses requested presentation indices and times, not final display receipts",
                   "source_submission_fps counts app submissions, not physical presentation",
                   "visual quality and head-motion correction require headset comparison or synchronized optical measurement",
                   "thermal changes, pauses, and capture targets prevent a clean matched comparison"]}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("log",type=Path);p.add_argument("--output",type=Path)
    args = p.parse_args()
    result = analyze(args.log)
    text = json.dumps(result,ensure_ascii=False,indent=2)+"\n"
    if args.output:
        args.output.write_text(text)
    print(text,end="")


if __name__ == "__main__":
    main()
