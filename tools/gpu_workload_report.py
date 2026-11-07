#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read complete overlap-only GPU timing windows. Never infer game FPS or NPU speedup."""
import argparse
import collections
import hashlib
import json
import math
import re
from pathlib import Path
from urllib.parse import unquote


def kv(line):
    return dict(re.findall(r"(\w+)=(\S+)", line))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def number(row, key):
    value = float(row[key])
    if not math.isfinite(value):
        raise ValueError(f"nonfinite {key}")
    return value


def analyze(profile, host=None, source_kind="game"):
    headers, frames, encoders, windows, warnings = [], {}, collections.defaultdict(dict), collections.defaultdict(list), set()
    function_names = {}
    invalid = collections.defaultdict(list)
    for line in profile.read_text(errors="replace").splitlines():
        if line.startswith("PPROF "):
            headers.append(kv(line))
        elif line.startswith("PNAME "):
            row = kv(line); key = row.get("key", "")
            if not re.fullmatch(r"[KFV][0-9a-f]{16}", key) or row.get("source") != "function_name" or not row.get("name"):
                raise ValueError("invalid function-name metadata")
            name = unquote(row["name"], errors="strict")
            if key in function_names and function_names[key] != name:
                raise ValueError("conflicting function-name metadata")
            function_names[key] = name
        elif line.startswith(("PFRAME ", "PENC ")):
            parts = line.split(); match = re.fullmatch(r"w(\d+)\.(\d+)", parts[1])
            if not match:
                raise ValueError("invalid frame identifier")
            window, index = map(int, match.groups()); fid = (window, index); row = kv(line)
            if parts[0] == "PFRAME":
                if fid in frames:
                    invalid[window].append("duplicate_frame")
                frames[fid] = row
            else:
                if len(parts) < 3 or not re.fullmatch(r"i\d+", parts[2]):
                    raise ValueError("invalid encoder identifier")
                encoder = int(parts[2][1:])
                if encoder in encoders[fid]:
                    invalid[window].append("duplicate_encoder")
                encoders[fid][encoder] = row
        elif line.startswith(("PWIN ", "PWARN ")):
            match = re.match(r"\S+ w(\d+)\b", line)
            if not match:
                raise ValueError("invalid window identifier")
            window = int(match.group(1))
            if line.startswith("PWIN "):
                windows[window].append(kv(line))
            else:
                warnings.add(window)
    if len(headers) != 1:
        raise ValueError("expected one profiling session")
    header = headers[0]; count = int(header["frames"])
    if header.get("timing_bounds") != "1":
        raise ValueError("unbounded counter timestamps; reused unexecuted stages can contain old values; refusing workload totals")
    if not 1 <= count <= 16:
        raise ValueError("unsupported window size")
    used, accepted = [], []
    for window in sorted(set(windows) | {f[0] for f in frames}):
        reasons = invalid[window]
        indices = {index for win, index in frames if win == window}
        if indices != set(range(count)):
            reasons.append("incomplete_frame_set")
        if len(windows[window]) != 1:
            reasons.append("missing_or_duplicate_window_summary")
        if window in warnings:
            reasons.append("profiler_warning")
        selected = []
        if not reasons:
            summary = windows[window][0]
            if summary.get("mode") != "overlap" or int(summary["frames"]) != max(1, count-1):
                reasons.append("incorrect_window_summary")
            for index in range(count):
                fid = (window, index); frame = frames[fid]
                if frame.get("mode") != "overlap":
                    reasons.append("serial_window")
                if int(frame["lead"]) != int(index == 0 and count > 1):
                    reasons.append("incorrect_lead")
                if len(encoders[fid]) != int(frame["encoders"]):
                    reasons.append("missing_encoders")
                if index == 0 and count > 1:
                    continue
                if frame.get("driving") != "1":
                    reasons.append("not_gameplay_tracking")
                total = 0
                for row in encoders[fid].values():
                    share = number(row, "share_ms")
                    if int(row.get("timing_bad", 1)) or "timing_valid" not in row or "timing_omitted" not in row:
                        reasons.append("unvalidated_encoder_timing")
                    if share < 0 or number(row, "span_ms") < 0:
                        reasons.append("negative_interval")
                    if number(row, "span_ms") > number(frame, "cb_busy_ms") + .101:
                        reasons.append("encoder_outside_command_buffer_duration")
                    total += share
                    pipes = row.get("pipes", "0:-").split(":", 1)
                    named_keys = [key for key in pipes[1].split(",") if key[:1] in ("K", "F", "V")]
                    if any(key not in function_names for key in named_keys):
                        reasons.append("missing_function_name")
                    work = int(pipes[0]) > 0 or int(row.get("disp", 0)) > 0 or int(row.get("ind", 0)) > 0 or row["k"] in "BA"
                    if work and number(row, "start_ms") < 0:
                        reasons.append("work_without_timestamp")
                busy, game, ours = (number(frame, k) for k in ("busy_ms", "game_ms", "ours_ms"))
                tolerance = .001 * (len(encoders[fid])+3)
                if min(busy, game, ours) < 0 or abs(total-busy) > tolerance or abs(game+ours-busy) > .004:
                    reasons.append("inconsistent_shares")
                selected.append(fid)
        if reasons:
            invalid[window] = sorted(set(reasons))
        else:
            used.extend(selected); accepted.append(window)
    if not used:
        raise ValueError("no complete overlap gameplay windows; refusing a workload conclusion")
    groups = {}
    for fid in used:
        for row in encoders[fid].values():
            pipes = row.get("pipes", "0:-"); key = (row["k"], row.get("ours") == "1", row.get("att", "-"), pipes)
            if key not in groups:
                groups[key] = {"kind":key[0], "ours":key[1], "attachments":key[2], "pipeline_libraries":pipes,
                               "pipeline_functions":[{"key":p, "name":function_names[p], "identity":"function_name"} for p in pipes.split(":",1)[1].split(",") if p in function_names],
                               "encoders":0, "assigned_share_ms":0, "stage_span_ms":0, "vertex_span_ms":0,
                               "fragment_span_ms":0, "threads":0, "indirect_dispatches":0}
            group = groups[key]; group["encoders"] += 1
            for target, field in [("assigned_share_ms", "share_ms"), ("stage_span_ms", "span_ms"), ("vertex_span_ms", "vtx_ms"), ("fragment_span_ms", "frag_ms")]:
                group[target] += number(row, field)
            group["threads"] += number(row, "mthreads") * 1e6
            group["indirect_dispatches"] += int(row.get("ind", 0))
    for group in groups.values():
        for key in ("assigned_share_ms", "stage_span_ms", "vertex_span_ms", "fragment_span_ms", "threads"):
            group[key + "_per_frame"] = group.pop(key) / len(used)
        group["encoders_per_frame"] = group["encoders"] / len(used)
    ordered = sorted(groups.values(), key=lambda g: -g["assigned_share_ms_per_frame"])
    totals = {key: sum(number(frames[f], key) for f in used)/len(used) for key in
              ("busy_ms", "game_ms", "ours_ms", "render_ms", "compute_ms", "blit_ms", "accel_ms", "cb_busy_ms")}
    thermal = []
    host_evidence = None
    if host:
        host_evidence = {"path":str(host), "sha256":sha(host)}
        host_rows = []
        for line in host.read_text(errors="replace").splitlines():
            try:
                host_rows.append(json.loads(line))
            except ValueError:
                continue
        clocks = [r["t"] for r in host_rows if isinstance(r.get("t"), (int,float))]
        states = sorted((r["t"], r["state"]) for r in host_rows if r.get("event") == "thermal")
        if any(float(r.get("pp_dropped", 0)) > 0 for r in host_rows):
            raise ValueError("profiler dropped encoders; refusing complete-workload totals")
        if "unix_s" in header and "mono_s" in header and clocks:
            offset = number(header, "unix_s") - number(header, "mono_s")
            for fid in used:
                time = number(frames[fid], "t") + offset
                if not min(clocks)-1 <= time <= max(clocks)+1:
                    raise ValueError("profile and host log do not cover the same session time")
                previous = [s for t,s in states if t <= time]
                thermal.append({"frame":f"w{fid[0]}.{fid[1]}", "approx_unix_s":time, "state":previous[-1] if previous else None})
    return {"schema":2, "source_kind":source_kind, "scope":"per-pass validated GPU interval diagnostic; no game FPS or speedup measurement",
            "profile":{"path":str(profile), "sha256":sha(profile)}, "host":host_evidence,
            "accepted_windows":accepted, "used_frames":len(used), "rejected_windows":{str(k):v for k,v in invalid.items() if v},
            "omitted_unused_stage_pairs":sum(int(row["timing_omitted"]).bit_count() for fid in used for row in encoders[fid].values()),
            "mean_assigned_intervals_ms":totals, "heaviest_groups":ordered[:30], "thermal_at_frames":thermal,
            "limits":["Intervals can include scheduling and dependency waits.", "Overlap shares split intervals equally, not by measured hardware utilization.",
                      "Unexecuted stages with invalid or stale samples are omitted; their cost is not measured by these intervals.",
                      "Compute encoders can contain several kernels; library hashes do not identify a replaceable effect.",
                      "Uppercase pipeline keys identify entry names, not compiled source, constants or shader variants.",
                      "Thread counts and attachment sizes alone do not prove resolution-proportional cost.",
                      "Replacing a group with NPU work still requires quality, transfer, memory and complete-pipeline comparisons."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path)
    parser.add_argument("--host", type=Path)
    parser.add_argument("--source-kind", choices=["game", "synthetic"], default="game")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = analyze(args.profile, args.host, args.source_kind)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+"\n")
    print(json.dumps({"used_frames":result["used_frames"], "accepted_windows":result["accepted_windows"],
                      "rejected_windows":result["rejected_windows"], "mean_assigned_intervals_ms":result["mean_assigned_intervals_ms"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
