#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mac-only conversion/parity/API-timing check, never an in-game FPS result.

CPU_AND_NE requests those compute units. Preferred devices in a compute plan
are planning information, not a trace proving where every operation ran.
No IOSurface packing, compositor, headset or gameplay is involved.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import platform
import time

import coremltools as ct
import numpy as np
import torch

from interp_guide import ACCELERATION_CONTRACT, AccelerationGuide
from interp_teacher import derived_directory


def compute_plan(model, units):
    try:
        plan = ct.models.compute_plan.MLComputePlan.load_from_path(model.get_compiled_model_path(), compute_units=units)
        devices, conv = Counter(), Counter()
        def visit(block):
            for op in block.operations:
                usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
                name = type(usage.preferred_compute_device).__name__ if usage else "unreported"
                devices[name] += 1
                if op.operator_name.rsplit(".", 1)[-1] == "conv":
                    conv[name] += 1
                for nested in op.blocks:
                    visit(nested)
        for function in plan.model_structure.program.functions.values():
            visit(function.block)
        return {"scope": "preferred devices in plan, not actual execution trace", "operations": dict(devices), "convolutions": dict(conv)}
    except (AttributeError, RuntimeError, ValueError, TypeError) as error:
        return {"unavailable": str(error)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--sample", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--iterations", type=int, default=25)
    args = parser.parse_args()
    if args.iterations < 10:
        parser.error("at least 10 iterations per block")
    out = derived_directory(args.out)
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    if checkpoint["contract"] != ACCELERATION_CONTRACT:
        raise ValueError("this bench expects the acceleration-v2 candidate")
    net = AccelerationGuide().eval()
    net.load_state_dict(checkpoint["state"])
    with np.load(args.sample, allow_pickle=False) as sample:
        original = sample["x"].copy()
    inputs = [original, original.copy()]
    inputs[1][15, :, :original.shape[-1]//2] = 1
    models, report = {}, {"scope": __doc__, "host": {"system": platform.system(), "version": platform.mac_ver()[0], "machine": platform.machine()},
                          "checkpoint_sha256": hashlib.sha256(args.checkpoint.read_bytes()).hexdigest(), "modes": {},
                          "game_quality_evaluated": False, "vision_pro_performance_evaluated": False}
    for name, units in (("CPU_ONLY", ct.ComputeUnit.CPU_ONLY), ("CPU_AND_NE", ct.ComputeUnit.CPU_AND_NE)):
        started = time.perf_counter()
        model = ct.models.MLModel(str(args.model), compute_units=units)
        if model.user_defined_metadata.get("vxpro.contract") != ACCELERATION_CONTRACT:
            raise ValueError("Core ML contract mismatch")
        load_ms = (time.perf_counter()-started)*1000
        errors = []
        for x in inputs:
            with torch.inference_mode():
                expected = net(torch.from_numpy(x.astype(np.float32))[None]).numpy()
            actual = model.predict({"guide_x": x[None]})["guide_y"].astype(np.float32)
            if actual.shape != expected.shape or not np.isfinite(actual).all():
                raise ValueError("invalid converted output")
            error = float(np.abs(actual-expected).max())
            if error > .02 or np.abs(actual[:, :2]).max() > 2.001:
                raise ValueError(f"conversion mismatch: {error}")
            excluded = (x[12] == 0) | (x[15] == 1)
            if np.count_nonzero(actual[0, :, excluded]):
                raise ValueError("excluded pixels acquired a correction")
            errors.append(error)
        for _ in range(10):
            model.predict({"guide_x": original[None]})
        models[name] = model
        report["modes"][name] = {"requested_compute_units": name, "load_ms": load_ms,
                                 "max_abs_parity_error": max(errors), "timings_ms": [], "compute_plan": compute_plan(model, units)}
    # Alternate blocks. These numbers include the Python Core ML predict API,
    # not GPU packing or compositor costs; a requested mode is not placement proof.
    schedule = ["CPU_ONLY", "CPU_AND_NE", "CPU_AND_NE", "CPU_ONLY"]*2
    for name in schedule:
        for i in range(args.iterations):
            x = inputs[i % len(inputs)]
            started = time.perf_counter()
            models[name].predict({"guide_x": x[None]})
            report["modes"][name]["timings_ms"].append((time.perf_counter()-started)*1000)
    for mode in report["modes"].values():
        samples = mode.pop("timings_ms")
        mode["predict_api_ms"] = {"samples": len(samples), "median": float(np.median(samples)),
                                   "p95": float(np.percentile(samples, 95)), "p99": float(np.percentile(samples, 99))}
    report["schedule"] = schedule
    (out / "report.json").write_text(json.dumps(report, indent=2)+"\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
