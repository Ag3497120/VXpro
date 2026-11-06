#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Audit and conservatively edit an existing VX interpolation checkpoint.

No optimizer, gradients or new model downloads. Choose among explicit repairs on
calibration bursts, freeze the edit, then score untouched held-out bursts. The
soft composite is a screening metric, not a headset/FPS result. Originals stay
read-only. Final acceptance requires the actual Metal warp and device timing.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path

import numpy as np
import torch
import interp_model as im


def edited(checkpoint, name):
    result = copy.deepcopy(checkpoint)
    weight, bias = result["state"]["head.weight"], result["state"]["head.bias"]
    if name in ("phase_mean", "phase_half"):
        # Four pixel-shuffle phases represent the same output channel. A
        # constant phase-dependent residual is a checkerboard, not detail.
        for c in range(6):
            rows = slice(c * 4, c * 4 + 4)
            weight[rows] = weight[rows].mean(0, keepdim=True)
            bias[rows] = bias[rows].mean()
    if name in ("half_fill", "phase_half", "no_fill"):
        scale = 0 if name == "no_fill" else .5
        weight[:12] *= scale
        bias[:12] *= scale
    if name == "conf_neutral":
        weight[20:] = 0
        bias[20:] = 0
    if name not in ("original", "phase_mean", "half_fill", "phase_half", "no_fill", "conf_neutral"):
        raise ValueError("unknown edit")
    return result


class ConstantHead(torch.nn.Module):
    """Exact shortcut only when every head weight is bitwise zero."""
    def __init__(self, checkpoint):
        super().__init__()
        if torch.count_nonzero(checkpoint["state"]["head.weight"]):
            raise ValueError("the head depends on image features")
        self.register_buffer("bias", checkpoint["state"]["head.bias"].reshape(6, 2, 2)[None])

    def forward(self, x):
        h, w = x.shape[-2:]
        if h % 2 or w % 2:
            raise ValueError("pixel-shuffle dimensions must be even")
        r = self.bias.repeat(1, 1, h // 2, w // 2)
        return torch.cat([(x[:, :3] + r[:, :3]).clamp(0, 1),
                          x[:, 4:6] + r[:, 3:5], torch.sigmoid(r[:, 5:6]).expand(x.shape[0], -1, -1, -1)], 1)


def net_for(checkpoint):
    if not torch.count_nonzero(checkpoint["state"]["head.weight"]):
        return ConstantHead(checkpoint)
    net = im.make_net(tuple(checkpoint["widths"]), checkpoint["dec_convs"])
    net.load_state_dict(checkpoint["state"])
    return net


def audit(checkpoint):
    w = checkpoint["state"]["head.weight"]
    b = checkpoint["state"]["head.bias"].reshape(6, 4)
    return {"head_nonzero_weights": int(torch.count_nonzero(w)),
            "head_bias_by_output_phase": b.tolist(),
            "fill_phase_spread": (b[:3].max(1).values - b[:3].min(1).values).tolist(),
            "parameters": sum(v.numel() for v in checkpoint["state"].values())}


def score(net, dataset, count):
    # The fixed held-out burst rule predates these edits. Report it explicitly;
    # this is not an independent recording and is not a fresh generalization set.
    return im.eval_h63(net, dataset, n=count, bs=4)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--checkpoint", required=True, type=Path)
    p.add_argument("--data", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--calibration-pairs", type=int, default=96)
    p.add_argument("--validation-pairs", type=int, default=192)
    args = p.parse_args()
    if args.calibration_pairs<1 or args.validation_pairs<1:
        p.error("pair counts must be positive")
    target = args.out / "candidate.pt"
    names = ["original", "phase_mean", "half_fill", "phase_half", "no_fill", "conf_neutral"]
    outputs=[target,args.out/"report.json"]+[args.out/(name+".pt") for name in names if name!="original"]
    if args.checkpoint.resolve() in [path.resolve() for path in outputs]:
        p.error("output must not replace the source checkpoint")
    args.out.mkdir(parents=True, exist_ok=True)
    source_hash = hashlib.sha256(args.checkpoint.read_bytes()).hexdigest()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    print(json.dumps(audit(checkpoint)), flush=True)
    # Reuse the original burst partition; no validation scores select the edit.
    calibration = im.WarpPairs(str(args.data), split="train")
    if not len(calibration):raise ValueError("no calibration pairs")
    scores = {}
    for name in names:
        trial = edited(checkpoint, name)
        if name != "original":
            trial.pop("heldout", None)
            trial["weight_edit"] = {"source_sha256": source_hash, "edit": name, "gradient_steps": 0}
            torch.save(trial, args.out / (name + ".pt"))
        scores[name] = score(net_for(trial), calibration, args.calibration_pairs)
        print("calibration", name, json.dumps(scores[name]), flush=True)
    winner = max(names, key=lambda n: scores[n]["model"]["all"])
    calibration_count = min(args.calibration_pairs, len(calibration))
    del calibration
    candidate = edited(checkpoint, winner)
    validation = im.WarpPairs(str(args.data), split="heldout")
    if not len(validation):raise ValueError("no held-out pairs")
    baseline = score(net_for(checkpoint), validation, args.validation_pairs)
    checked = score(net_for(candidate), validation, args.validation_pairs)
    changed = {k: int(torch.count_nonzero(checkpoint["state"][k] != v))
               for k, v in candidate["state"].items() if not torch.equal(checkpoint["state"][k], v)}
    report = {"source": str(args.checkpoint.resolve()), "source_sha256": source_hash,
              "method": "explicit weight edits selected by forward evaluation; no gradients or optimizer",
              "audit": audit(checkpoint), "calibration_scores": scores, "selected_edit": winner,
              "validation_original": baseline, "validation_candidate": checked,
              "calibration_pairs": calibration_count,
              "validation_pairs": min(args.validation_pairs, len(validation)),
              "changed_values": changed, "gradient_steps": 0,
              "limits": ["same recording used by prior training, partitioned by pre-existing burst rule",
                         "soft warp screening only; actual Metal warp and temporal artifacts not accepted",
                         "no device runtime, memory or FPS benefit established", "not activated in game"]}
    candidate["weight_edit"] = {"source_sha256": source_hash, "edit": winner, "gradient_steps": 0}
    candidate.pop("heldout", None)  # Old training scores do not describe an edited checkpoint.
    torch.save(candidate, target)
    assert hashlib.sha256(args.checkpoint.read_bytes()).hexdigest() == source_hash
    (args.out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Selected", winner, "changed", changed, "validation", json.dumps(checked), flush=True)


if __name__ == "__main__":
    main()
