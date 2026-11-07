#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Passive VXMac FPS observation, with optional VeRantyx harness integration.

No game is launched, no SteamVR level/baseline is asserted. Both stats callers
reset the same counters, so their rates must be combined by interval duration.
"""
import argparse
import bisect
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import shutil
import sys

try:
    import vxrt_run as harness
except ModuleNotFoundError as error:
    if error.name != "vxrt_run":
        raise
    harness = None
REPO = Path(harness.__file__).resolve().parents[1] if harness else Path(__file__).resolve().parents[1]


def analyze(path, seconds=60, end_at=None):
    if not math.isfinite(seconds) or seconds < 1:
        raise ValueError("invalid observation duration")
    lines = path.read_text().splitlines()
    rows = []
    for i, line in enumerate(lines):
        try:
            rows.append(json.loads(line))
        except ValueError:
            if i != len(lines)-1:
                raise ValueError("malformed interior log line")
    if sum(r.get("event") == "host_init" for r in rows) != 1:
        raise ValueError("expected one host session")
    rates = [r for r in rows if r.get("event") in ("stats", "vr") and "game_fps" in r]
    if end_at is not None:
        if not math.isfinite(end_at):raise ValueError("invalid observation end")
        rates = [r for r in rates if float(r["since_start"]) <= end_at]
    if len(rates) < 3:
        raise ValueError("insufficient rate observations")
    end = float(rates[-1]["since_start"]); start = end-seconds
    if float(rates[0]["since_start"]) > start:
        raise ValueError("log does not cover requested window")
    phases = sorted(((float(r["since_start"]), r.get("phase")) for r in rows if r.get("event") == "scene_phase"), key=lambda p:p[0])
    def foreground(t):
        k = bisect.bisect_right([s for s, _ in phases], t)-1
        return k >= 0 and phases[k][1] == "active"
    used = []; previous = rates[0]
    for r in rates[1:]:
        a, z = float(previous["since_start"]), float(r["since_start"])
        if z <= a:
            if max(a,z) >= start and min(a,z) <= end:
                raise ValueError("nonmonotonic or indistinguishable report times in observation window")
            previous = r
            continue
        lo, hi = max(a,start), min(z,end)
        if hi > lo:
            for key in ("game_fps", "compositor_hz"):
                if not math.isfinite(float(r[key])) or float(r[key]) < 0:
                    raise ValueError("invalid rate")
            if (z-a <= 3 and r.get("mode") == previous.get("mode") == "vr"
                    and foreground(a) and foreground(z)
                    and not any(a < t < z and p != "active" for t,p in phases)):
                used.append((hi-lo,r))
        previous = r
    duration = sum(w for w,_ in used)
    if duration < seconds*.95:
        raise ValueError("insufficient foreground VR coverage; load/menu/background excluded")
    submits = [r for r in rates if r.get("event") == "stats" and "frames" in r
               and start <= float(r["since_start"]) <= end and r.get("mode") == "vr" and foreground(float(r["since_start"]))]
    if len(submits) < 2 or any(b["frames"] < a["frames"] for a,b in zip(submits,submits[1:])):
        raise ValueError("missing or reset cumulative submit counter")
    span = submits[-1]["since_start"]-submits[0]["since_start"]
    if span < seconds*.8:
        raise ValueError("insufficient submit-counter coverage")
    return {
        "requested_seconds":seconds, "start_since_start":start, "end_since_start":end,
        "accepted_seconds":duration, "rate_intervals":len(used),
        "received_game_image_fps":sum(w*r["game_fps"] for w,r in used)/duration,
        "compositor_updates_hz":sum(w*r["compositor_hz"] for w,r in used)/duration,
        "game_submit_fps":(submits[-1]["frames"]-submits[0]["frames"])/span,
        "submit_counter_span_seconds":span,
        "submit_frames":submits[-1]["frames"]-submits[0]["frames"],
        "window_end_unix_s":rates[-1]["t"],
    }


def validate_native(result):
    if harness is None:
        raise ValueError("sealed-run validation requires the VeRantyx run harness")
    errors = harness.validate(result)
    source = next(o for o in result["observed"] if o["metric"] == "native_host_log")
    actual = analyze(REPO / source["artifact"], result["request_seconds"], result.get("request_end_since_start"))
    if actual != result["derived"][0]["value"]:
        errors.append("native FPS summary does not reproduce from log")
    return errors


def collect(source, seconds, end_at=None):
    if harness is None:
        raise ValueError("sealed-run collection requires the VeRantyx run harness")
    digest = harness.ledger.sha256_file(str(source))
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")+"-vxmac-fps-"+digest[:8]
    directory = REPO / "runs" / run_id
    directory.mkdir(parents=True)
    snapshot = directory / "host.jsonl"; shutil.copyfile(source,snapshot)
    summary = analyze(snapshot,seconds,end_at)
    ev = harness.Evidence()
    ref = ev.observe("native_host_log",{"format":"vxmac_host.jsonl","scope":"foreground VR telemetry"},str(snapshot))
    ev.derived.append({"id":"d1","claim":"native_fps_observation","holds":True,
        "value":summary,"rule":"time-weight both reset-counter reporters; submit FPS from cumulative count delta",
        "from":[ref]})
    commit,dirty = harness.git_state()
    result = {"run_id":run_id,"game":"vxmac-cyberpunk2077","scenario":"passive-fps-observation",
        "measurement_kind":"native-player-session-observation","status":"observed","baseline":None,
        "quality":"current-installed-settings","request_seconds":seconds,
        "request_end_since_start":end_at,
        "environment":{"commit":commit,"dirty":dirty,"collector_sha256":harness.ledger.sha256_file(__file__)},
        "observed":ev.observed,"derived":ev.derived,"inferred":[],
        "unknown":[{"item":"FPS improvement versus prior build","reason":"no same-scene alternating baseline"},
                   {"item":"per-frame 1% low and physical panel timing","reason":"aggregate telemetry only"},
                   {"item":"exact game scene/menu state","reason":"VR mode is the available filter"}],
        "limits":["game_fps counts completed captured images, not every game render submission",
                  "compositor_hz counts presenter updates, not new game images",
                  "rates are rounded and event timestamps approximate counter sampling times",
                  "passive native observation, not an isolated SteamVR run or playability classification"]}
    result["native_validation"] = validate_native(result)
    if result["native_validation"]:
        raise ValueError(result["native_validation"])
    return harness.finish(result,str(directory),lambda _:None)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host",type=Path,nargs="?");parser.add_argument("--seconds",type=float,default=60)
    parser.add_argument("--end-since-start",type=float,help="use complete reports ending at or before this session time")
    parser.add_argument("--validate",type=Path)
    parser.add_argument("--summary",action="store_true",help="print an unsealed summary without the optional VeRantyx harness")
    args=parser.parse_args()
    if args.validate:
        if harness is None:parser.error("--validate requires the VeRantyx run harness; use --summary for standalone analysis")
        result=json.loads((args.validate/"result.json").read_text());errors=validate_native(result)
        print(json.dumps({"valid":not errors,"errors":errors}));return 1 if errors else 0
    if not args.host:parser.error("host log required")
    if args.summary or harness is None:
        print(json.dumps({"summary":analyze(args.host,args.seconds,args.end_since_start),
                          "evidence":"standalone summary; not a sealed harness run"},ensure_ascii=False))
        return 0
    result=collect(args.host,args.seconds,args.end_since_start)
    print(json.dumps({"run_id":result["run_id"],"summary":result["derived"][0]["value"],"validation":result["validation"]},ensure_ascii=False))
    return 0

if __name__ == "__main__":
    sys.exit(main())
