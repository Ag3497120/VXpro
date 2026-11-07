#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Train/evaluate only the local rigid-geometry guide pilot. No app activation.

Source-asset and clip separation, hashes and units are validated before loading.
Report endpoint error against both constant velocity and analytic acceleration;
synthetic error reduction is never treated as in-game quality or FPS evidence.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch
from torch.nn import functional as F

from interp_guide import CONTRACT, ACCELERATION_CONTRACT, MotionGuide, AccelerationGuide, export_coreml, probe
from interp_teacher import MOTION_UNIT, TEACHER_CONTRACT, derived_directory


def read_manifest(root):
    manifest = json.loads((root / "manifest.json").read_text())
    if manifest["teacher_contract"] != TEACHER_CONTRACT or manifest["model_contract"] != CONTRACT:
        raise ValueError("incompatible teacher/model contracts")
    if manifest["motion_unit_pixels"] != MOTION_UNIT:
        raise ValueError("incompatible motion units")
    if manifest["time_unit_seconds"] != .1 or (manifest["near"], manifest["far"]) != (.1, 64.0):
        raise ValueError("incompatible depth/time units")
    owners, clips, paths = {}, {}, set()
    for row in manifest["samples"]:
        split, asset = row["split"], row["asset_sha256"]
        if split not in ("train", "validation", "test"):
            raise ValueError("unknown split")
        if asset in owners and owners[asset] != split:
            raise ValueError("source asset leaks across splits")
        if row["clip"] in clips and clips[row["clip"]] != split:
            raise ValueError("clip leaks across splits")
        owners[asset], clips[row["clip"]] = split, split
        path = (root / row["file"]).resolve()
        path.relative_to(root.resolve())
        if path in paths or path.parts[-2] != split:
            raise ValueError("duplicate path or split mismatch")
        paths.add(path)
        if hashlib.sha256(path.read_bytes()).hexdigest() != row["sha256"]:
            raise ValueError("teacher sample hash mismatch")
    if set(owners.values()) != {"train", "validation", "test"}:
        raise ValueError("all three asset-separated splits are required")
    return manifest


class Dataset:
    def __init__(self, root, manifest, split):
        self.rows = []
        self.entries = []
        for entry in manifest["samples"]:
            if entry["split"] != split:
                continue
            with np.load(root / entry["file"], allow_pickle=False) as sample:
                self.rows.append({key: sample[key].copy() for key in
                                  ("x", "flow", "residual", "visible", "learn_valid", "confidence", "current_id", "tau")})
                self.entries.append(entry)
        if not self.rows:
            raise ValueError(f"empty {split} split")
        for row in self.rows:
            if row["x"].shape[0] != 16 or not all(np.isfinite(v).all() for v in row.values()):
                raise ValueError("invalid teacher input")

    def batch(self, indices, device):
        return {key: torch.from_numpy(np.stack([self.rows[int(i)][key] for i in indices])).to(device=device, dtype=torch.float32)
                for key in self.rows[0]}


def evaluate(net, dataset, device, batch_size):
    totals = {group: {name: 0.0 for name in ("pixels", "constant_velocity", "analytic_acceleration", "guide", "confidence_gated_guide")}
              for group in ("all_visible_history", "moving_props", "owned_mesh")}
    confidence_error, confidence_count = 0.0, 0
    net.eval()
    with torch.inference_mode():
        for start in range(0, len(dataset.rows), batch_size):
            b = dataset.batch(range(start, min(start+batch_size, len(dataset.rows))), device)
            x, target = b["x"], b["flow"]
            output = net(x)
            tau = b["tau"][:, None, None, None]
            motion = x[:, 8:10]*MOTION_UNIT
            baseline = motion*tau
            # Equal past intervals within each clip; all quantities in the current reference camera.
            acceleration = .5*(motion-x[:, 10:12]*MOTION_UNIT)*tau*(tau+1)
            predictions = {"constant_velocity": baseline, "analytic_acceleration": baseline+acceleration.clamp(-2, 2),
                           "guide": baseline+output[:, :2],
                           "confidence_gated_guide": baseline+output[:, :2]*output[:, 2:3]}
            valid = (x[:, 12] > .5) & (b["visible"] > .5)
            for group, mask in (("all_visible_history", valid), ("moving_props", valid & (b["current_id"] >= 2)),
                                ("owned_mesh", valid & (b["current_id"] == 2))):
                totals[group]["pixels"] += int(mask.sum())
                for name, prediction in predictions.items():
                    error = torch.linalg.vector_norm(prediction-target, dim=1)
                    totals[group][name] += float(error[mask].sum())
            mask = x[:, 12] > .5
            confidence_error += float((output[:, 2]-b["confidence"]).square()[mask].sum())
            confidence_count += int(mask.sum())
    for group in totals.values():
        for key in list(group):
            if key != "pixels":
                group[key] /= max(group["pixels"], 1)
    return {"endpoint_error_model_pixels": totals,
            "confidence_brier": confidence_error/max(confidence_count, 1), "samples": len(dataset.rows)}


def evaluate_reference_policy(net, dataset, batch_size):
    """One h4 inference per anchor, re-used at h1/h4 under a quadratic assumption.

    Offline endpoint-error check only. Confidence/fallbacks at occlusions and
    actual device scheduling still require separate runtime validation.
    """
    references = {entry["file"].rsplit("-h", 1)[0]: i for i, entry in enumerate(dataset.entries)
                  if entry["file"].endswith("-h4.npz")}
    cached = {}
    indices = list(references.values())
    with torch.inference_mode():
        for start in range(0, len(indices), batch_size):
            chunk = indices[start:start+batch_size]
            b = dataset.batch(chunk, torch.device("cpu"))
            outputs = net(b["x"]).numpy()
            for i, output in zip(chunk, outputs):
                cached[i] = output
    total, baseline_total, acceleration_total, count = 0.0, 0.0, 0.0, 0
    mesh_total, mesh_baseline, mesh_acceleration, mesh_count = 0.0, 0.0, 0.0, 0
    for entry, row in zip(dataset.entries, dataset.rows):
        reference = references[entry["file"].rsplit("-h", 1)[0]]
        ref_tau = float(dataset.rows[reference]["tau"])
        tau = float(row["tau"])
        factor = tau*(tau+1)/(ref_tau*(ref_tau+1))
        motion = row["x"][8:10].astype(np.float32)*MOTION_UNIT
        previous = row["x"][10:12].astype(np.float32)*MOTION_UNIT
        target = row["flow"].astype(np.float32)
        baseline = motion*tau
        prediction = baseline+cached[reference][:2]*factor
        acceleration = baseline+np.clip(.5*(motion-previous)*tau*(tau+1), -2, 2)
        valid = (row["x"][12] > .5) & row["visible"] & (row["current_id"] >= 2)
        total += float(np.linalg.norm(prediction-target, axis=0)[valid].sum())
        baseline_total += float(np.linalg.norm(baseline-target, axis=0)[valid].sum())
        acceleration_total += float(np.linalg.norm(acceleration-target, axis=0)[valid].sum())
        count += int(valid.sum())
        mesh_valid = valid & (row["current_id"] == 2)
        mesh_total += float(np.linalg.norm(prediction-target, axis=0)[mesh_valid].sum())
        mesh_baseline += float(np.linalg.norm(baseline-target, axis=0)[mesh_valid].sum())
        mesh_acceleration += float(np.linalg.norm(acceleration-target, axis=0)[mesh_valid].sum())
        mesh_count += int(mesh_valid.sum())
    return {"scope": "offline reuse of reference-horizon outputs, not device latency/FPS",
            "inferences": len(indices), "evaluated_horizons": len(dataset.rows), "pixels": count,
            "moving_props_epe": total/max(count, 1), "constant_velocity_epe": baseline_total/max(count, 1),
            "analytic_acceleration_epe": acceleration_total/max(count, 1),
            "owned_mesh": {"pixels": mesh_count, "guide_epe": mesh_total/max(mesh_count, 1),
                           "constant_velocity_epe": mesh_baseline/max(mesh_count, 1),
                           "analytic_acceleration_epe": mesh_acceleration/max(mesh_count, 1)}}


def train(args):
    out = derived_directory(args.out)
    manifest = read_manifest(args.data)
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    rng = np.random.default_rng(args.seed)
    device = torch.device(args.device)
    datasets = {split: Dataset(args.data, manifest, split) for split in ("train", "validation", "test")}
    contract = ACCELERATION_CONTRACT if args.architecture == "acceleration" else CONTRACT
    net = (AccelerationGuide() if args.architecture == "acceleration" else MotionGuide()).to(device)
    optimizer = torch.optim.Adam(net.parameters(), lr=args.lr)
    initial = evaluate(net, datasets["validation"], device, args.batch)
    best_error, best_state, history = float("inf"), None, []
    started = time.perf_counter()
    for step in range(1, args.steps+1):
        net.train()
        b = datasets["train"].batch(rng.integers(len(datasets["train"].rows), size=args.batch), device)
        output = net(b["x"])
        valid = b["learn_valid"][:, None]
        weight = valid*(1+7*(b["current_id"][:, None] >= 2))
        residual_loss = (F.smooth_l1_loss(output[:, :2], b["residual"], reduction="none")*weight).sum() / (2*weight.sum().clamp_min(1))
        history_mask = b["x"][:, 12] > .5
        confidence_loss = F.binary_cross_entropy(output[:, 2].clamp(1e-5, 1-1e-5)[history_mask], b["confidence"][history_mask])
        loss = residual_loss+.05*confidence_loss
        if not torch.isfinite(loss):
            raise ValueError("nonfinite training loss")
        optimizer.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(net.parameters(), 1)
        optimizer.step()
        if step == 1 or step % args.eval_every == 0 or step == args.steps:
            result = evaluate(net, datasets["validation"], device, args.batch)
            error = result["endpoint_error_model_pixels"]["moving_props"]["guide"]
            if error < best_error:
                best_error = error
                best_state = copy.deepcopy({k: v.detach().cpu() for k, v in net.state_dict().items()})
            entry = {"step": step, "loss": float(loss.detach()), "validation": result}
            history.append(entry)
            print(json.dumps(entry), flush=True)
    net.cpu().load_state_dict(best_state)
    final = {split: evaluate(net, datasets[split], torch.device("cpu"), args.batch) for split in ("validation", "test")}
    reference_policy = {split: evaluate_reference_policy(net, datasets[split], args.batch) for split in ("validation", "test")}
    checkpoint = out / "pilot-guide.pt"
    torch.save({"contract": contract, "teacher_contract": TEACHER_CONTRACT, "trained": True,
                "scope": "rigid synthetic pilot only", "state": net.state_dict()}, checkpoint)
    example = datasets["validation"].batch([0], torch.device("cpu"))["x"]
    health = probe(net, example)
    if not health["features_active"] or health["features_nonfinite"] or health["output_nonfinite"]:
        raise ValueError("unhealthy trained model")
    coreml = export_coreml(net, example, out / "pilot-guide.mlpackage", trained=True, contract=contract) if args.export else None
    report = {"contract": contract, "architecture": args.architecture, "teacher_contract": TEACHER_CONTRACT,
              "scope": "asset-separated rigid procedural scenes; no game quality, ANE placement, latency or FPS measured",
              "runtime_compatible": False, "seed": args.seed, "steps": args.steps, "batch": args.batch,
              "device": args.device, "experiment_wall_seconds_including_export": time.perf_counter()-started,
              "manifest_sha256": hashlib.sha256((args.data / "manifest.json").read_bytes()).hexdigest(),
              "checkpoint_sha256": hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
              "initial_validation": initial, "history": history, "final": final, "reference_policy": reference_policy,
              "health": health, "coreml": coreml,
              "app_adoption_approved": False, "game_quality_evaluated": False, "device_performance_evaluated": False}
    (out / "report.json").write_text(json.dumps(report, indent=2)+"\n")
    print(json.dumps({"out": str(out), "final": final}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--steps", type=int, default=400)
    parser.add_argument("--batch", type=int, default=8)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--device", choices=("cpu", "mps"), default="cpu")
    parser.add_argument("--architecture", choices=("direct", "acceleration"), default="direct")
    parser.add_argument("--eval-every", type=int, default=100)
    parser.add_argument("--lr", type=float, default=.001)
    parser.add_argument("--seed", type=int, default=20261106)
    parser.add_argument("--export", action="store_true")
    args = parser.parse_args()
    if min(args.steps, args.batch, args.threads, args.eval_every) < 1:
        parser.error("steps, batch, threads and evaluation interval must be positive")
    train(args)


if __name__ == "__main__":
    main()
