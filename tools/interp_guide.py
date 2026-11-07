#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Untrained, standalone motion/confidence candidate for NPU design review.

This is not the app's six-channel interpolation ABI and is never activated by
this tool. Export checks conversion only, not ANE placement, image quality or FPS.
All weights are newly initialized; no existing checkpoints are read or modified.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F


CHANNELS = (
    "current_r", "current_g", "current_b",
    "history_warped_r", "history_warped_g", "history_warped_b",
    "current_depth_encoded", "history_depth_encoded",
    "current_motion_x", "current_motion_y", "history_motion_x", "history_motion_y",
    "history_valid", "history_age_normalized", "reference_horizon_normalized", "foreground_mask",
)
CONTRACT = "vxpro-guide-proposal-v1"
ACCELERATION_CONTRACT = "vxpro-guide-acceleration-proposal-v2"


class MotionGuide(nn.Module):
    def __init__(self, max_residual_pixels=2.0):
        super().__init__()
        if not 0 < max_residual_pixels <= 8:
            raise ValueError("residual bound must be in (0, 8] model pixels")
        self.max_residual_pixels = float(max_residual_pixels)
        stages = []
        previous = len(CHANNELS)
        for width in (16, 24, 32):
            stages.extend([nn.Conv2d(previous, width, 3, stride=2, padding=1), nn.LeakyReLU(.1)])
            previous = width
        self.features = nn.Sequential(*stages)
        self.head = nn.Conv2d(previous, 3, 1)
        # Keep a real image-dependent head for conversion probes. A zero head
        # could make an untrained profiling artifact look misleadingly cheap.
        nn.init.normal_(self.head.weight, std=.01)
        nn.init.zeros_(self.head.bias)

    def forward(self, x):
        raw = F.interpolate(self.head(self.features(x)), size=x.shape[-2:], mode="nearest")
        valid = x[:, 12:13].clamp(0, 1) * (1 - x[:, 15:16].clamp(0, 1))
        residual = torch.tanh(raw[:, :2]) * self.max_residual_pixels * valid
        confidence = torch.sigmoid(raw[:, 2:3]) * valid
        return torch.cat([residual, confidence], dim=1)


class AccelerationGuide(MotionGuide):
    """Keep per-pixel analytical motion; learn only its bounded refinement.

    The coarse conv field alone cannot preserve motion discontinuities along
    thin silhouettes. The full-resolution skip does, and exactly static input
    motion cannot acquire a learned drift. Units are the teacher-v1 units.
    """
    def forward(self, x):
        raw = F.interpolate(self.head(self.features(x)), size=x.shape[-2:], mode="nearest")
        valid = x[:, 12:13].clamp(0, 1) * (1-x[:, 15:16].clamp(0, 1))
        tau = x[:, 14:15] / x[:, 13:14].clamp_min(.001)
        motion = x[:, 8:10]*16
        acceleration = .5*(motion-x[:, 10:12]*16)*tau*(tau+1)
        activity = (motion.abs().sum(dim=1, keepdim=True) + (x[:, 10:12]*16).abs().sum(dim=1, keepdim=True)).clamp(0, 1)
        residual = (acceleration + .25*torch.tanh(raw[:, :2])*activity).clamp(-self.max_residual_pixels, self.max_residual_pixels)*valid
        confidence = torch.sigmoid(raw[:, 2:3])*valid
        return torch.cat([residual, confidence], dim=1)


def validate_input(x):
    if x.ndim != 4 or x.shape[0] != 1 or x.shape[1] != len(CHANNELS):
        raise ValueError("expected one NCHW input with 16 channels")
    if x.shape[2] < 8 or x.shape[3] < 8 or not torch.isfinite(x).all():
        raise ValueError("input must be finite and at least 8 by 8")


def probe(net, x):
    validate_input(x)
    with torch.inference_mode():
        features = net.features(x)
        result = net(x)
    return {"parameters": sum(p.numel() for p in net.parameters()),
            "features_active": int(torch.count_nonzero(features)),
            "features_nonfinite": int((~torch.isfinite(features)).sum()),
            "output_nonfinite": int((~torch.isfinite(result)).sum()),
            "max_residual_pixels": float(result[:, :2].abs().max()),
            "confidence_range": [float(result[:, 2:3].min()), float(result[:, 2:3].max())]}


def export_coreml(net, x, destination, trained=False, contract=CONTRACT):
    import coremltools as ct
    with torch.inference_mode():
        traced = torch.jit.trace(net.eval(), x)
    model = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
                       inputs=[ct.TensorType(name="guide_x", shape=tuple(x.shape), dtype=np.float16)],
                       outputs=[ct.TensorType(name="guide_y", dtype=np.float16)],
                       compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_AND_NE)
    model.short_description = f"{'Pilot-trained' if trained else 'Untrained'} standalone VXpro motion guide; not app compatible"
    model.user_defined_metadata.update({"vxpro.contract": contract, "vxpro.trained": str(trained).lower(),
                                       "vxpro.runtime_compatible": "false"})
    model.save(str(destination))
    return {"path": str(destination), "scope": "conversion only; ANE execution and speed unmeasured"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20261106)
    parser.add_argument("--export", action="store_true")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    torch.manual_seed(args.seed)
    net = MotionGuide().eval()
    x = torch.rand(1, len(CHANNELS), 144, 256)
    x[:, 12] = 1
    x[:, 15] = 0
    report = {"contract": CONTRACT, "trained": False, "runtime_compatible": False,
              "seed": args.seed, "input_shape": list(x.shape), "channels": CHANNELS,
              "output_channels": ["residual_x_model_pixels", "residual_y_model_pixels", "confidence"],
              "probe": probe(net, x), "quality_evaluated": False, "device_performance_evaluated": False}
    assert report["probe"]["features_active"] and not report["probe"]["features_nonfinite"]
    assert not report["probe"]["output_nonfinite"]
    checkpoint = args.out / "untrained-guide.pt"
    torch.save({"contract": CONTRACT, "trained": False, "state": net.state_dict()}, checkpoint)
    report["checkpoint_sha256"] = hashlib.sha256(checkpoint.read_bytes()).hexdigest()
    if args.export:
        report["coreml"] = export_coreml(net, x, args.out / "untrained-guide.mlpackage")
    (args.out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
