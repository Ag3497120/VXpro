#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check that an existing interpolation decoder can supply image features.

No training, checkpoint writes or model activation. A zero output head is a
valid baseline initialization only if its input features can become nonzero.
"""
import argparse
import hashlib
import json
from pathlib import Path

import torch


def feature_health(net, probes):
    report = {"samples": 0, "feature_values": 0, "active_values": 0,
              "nonfinite_values": 0, "feature_abs_max": 0.0,
              "head_nonzero_weights": int(torch.count_nonzero(net.head.weight))}
    def capture(_module, _inputs, output):
        values = output.detach()
        finite = torch.isfinite(values)
        report["feature_values"] += values.numel()
        report["active_values"] += int(torch.count_nonzero(values[finite]))
        report["nonfinite_values"] += int((~finite).sum())
        if finite.any():
            report["feature_abs_max"] = max(report["feature_abs_max"], float(values[finite].abs().max()))
    was_training = net.training
    handle = net.dec[-1].register_forward_hook(capture)
    try:
        net.eval()
        with torch.inference_mode():
            for x in probes:
                net(x)
                report["samples"] += x.shape[0]
    finally:
        handle.remove()
        net.train(was_training)
    report["usable_for_training"] = bool(report["active_values"] and not report["nonfinite_values"])
    report["scope"] = "decoder liveness on supplied probes, not prediction quality or device performance"
    return report


def require_training_features(net, probes):
    report = feature_health(net, probes)
    if not report["usable_for_training"]:
        raise ValueError("inactive or nonfinite interpolation decoder: resetting only the head cannot "
                         "restore image-dependent learning; use a healthy initialization or explicitly repair the body")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--capture", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--frames", type=int, default=4)
    args = parser.parse_args()
    if args.frames < 1 or args.frames > 32:
        parser.error("frames must be between 1 and 32")
    if args.report.resolve() in {args.checkpoint.resolve(), args.capture.resolve()}:
        parser.error("report must not replace an input")
    import interp_model as im
    source_hash = hashlib.sha256(args.checkpoint.read_bytes()).hexdigest()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    net = im.make_net(tuple(checkpoint["widths"]), checkpoint["dec_convs"])
    net.load_state_dict(checkpoint["state"])
    def probes():
        for number, (meta, planes) in enumerate(im.read_capture(args.capture)):
            if number >= args.frames:
                break
            yield torch.from_numpy(im.encode_input(planes, meta, im.DEFAULT_W, im.DEFAULT_H))[None]
    report = feature_health(net, probes())
    report["checkpoint_sha256"] = source_hash
    report["checkpoint"] = str(args.checkpoint.resolve())
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    assert hashlib.sha256(args.checkpoint.read_bytes()).hexdigest() == source_hash
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
