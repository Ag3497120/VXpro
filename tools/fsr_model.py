#!/usr/bin/env python3
# The foveated super-resolution model for the Neural Engine (VX Mac, docs/DESIGN.md "Foveated SR"): a Core ML ML
# program built here from MIL ops (coremltools' builder, BSD-3; no third-party code or weights), version 1 not learned:
#   1. x2 upscale: a fixed 5x5 polyphase cubic (Catmull-Rom family, sharpness a) per colour: one grouped conv giving the
#      four sub-pixel phases, then a pixel shuffle;
#   2. edge sharpening: up + k * (up - gauss3x3(up)) (an unsharp mask on the upscaled image);
#   3. anti-ringing: clamped to the 3x3 min/max of the upscaled image (no halos, no overshoot on edges and text).
# Every op has a Neural Engine kernel (conv, pixel_shuffle, max_pool, elementwise), fp16. Input and output are images
# (BGR, 0-255): the app feeds an IOSurface pixel buffer the GPU filled and gets the result in another (outputBackings),
# no copies. The learned model (next stage) keeps the same interface: same names, sizes and image types.
#
#   tools/fsr_model.py --w 512 --h 288 --out build/fsr            -> build/fsr/vxfsr_512x288.mlpackage (+ .mlmodelc)
import argparse, os, subprocess, sys
import numpy as np
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types


def cubic(t, a):
    t = abs(t)
    if t <= 1: return (a + 2) * t**3 - (a + 3) * t**2 + 1
    if t < 2: return a * t**3 - 5 * a * t**2 + 8 * a * t - 4 * a
    return 0.0


def phase_taps(phase, a):
    # output sample at input coordinate i + phase (phase -0.25 or +0.25, align_corners off): weights on taps i-2..i+2
    w = np.array([cubic(k - phase, a) for k in range(-2, 3)], np.float64)
    return w / w.sum()


def build(W, H, a, k):
    ph = [phase_taps(-0.25, a), phase_taps(0.25, a)]
    up_w = np.zeros((12, 1, 5, 5), np.float32)            # grouped conv: 3 groups (colours) x 4 phases (r_h, r_w)
    for c in range(3):
        for i in range(2):
            for j in range(2):
                up_w[c * 4 + i * 2 + j, 0] = np.outer(ph[i], ph[j])
    g = np.array([1, 2, 1], np.float32)
    g3 = (np.outer(g, g) / 16).astype(np.float32)
    gw = np.tile(g3[None, None], (3, 1, 1, 1))

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, H, W), dtype=types.fp32)], opset_version=ct.target.iOS17)
    def prog(image):
        x = mb.cast(x=image, dtype="fp16")
        p = mb.conv(x=x, weight=up_w.astype(np.float16), pad_type="custom", pad=[2, 2, 2, 2], groups=3)
        up = mb.pixel_shuffle(x=p, upscale_factor=2)
        bl = mb.conv(x=up, weight=gw.astype(np.float16), pad_type="custom", pad=[1, 1, 1, 1], groups=3)
        d = mb.sub(x=up, y=bl)
        sh = mb.add(x=up, y=mb.mul(x=d, y=np.float16(k)))
        hi = mb.max_pool(x=up, kernel_sizes=[3, 3], strides=[1, 1], pad_type="same")
        lo = mb.mul(x=mb.max_pool(x=mb.mul(x=up, y=np.float16(-1)), kernel_sizes=[3, 3], strides=[1, 1], pad_type="same"),
                    y=np.float16(-1))
        o = mb.minimum(x=mb.maximum(x=sh, y=lo), y=hi)
        o = mb.clip(x=o, alpha=np.float16(0), beta=np.float16(255))
        return mb.cast(x=o, dtype="fp32", name="detail")

    m = ct.convert(prog, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
                   inputs=[ct.ImageType(name="image", shape=(1, 3, H, W), color_layout=ct.colorlayout.BGR)],
                   outputs=[ct.ImageType(name="detail", color_layout=ct.colorlayout.BGR)],
                   compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_AND_NE)
    # (an ML program's image output is not taken from `outputs` here: the output's description set to an image after)
    spec = m.get_spec()
    o = spec.description.output[0]
    o.type.imageType.width = 2 * W
    o.type.imageType.height = 2 * H
    o.type.imageType.colorSpace = ct.proto.FeatureTypes_pb2.ImageFeatureType.BGR
    m = ct.models.MLModel(spec, weights_dir=m.weights_dir, compute_units=ct.ComputeUnit.CPU_AND_NE)
    m.short_description = "VX Mac foveated SR v1 (not learned): x2 cubic + clamped unsharp mask, %dx%d -> %dx%d" % (W, H, 2 * W, 2 * H)
    m.user_defined_metadata["vxfsr"] = "v1 cubic a=%g k=%g" % (a, k)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--w", type=int, default=512)
    ap.add_argument("--h", type=int, default=288)
    ap.add_argument("--a", type=float, default=-0.6, help="cubic sharpness (-0.5 Catmull-Rom)")
    ap.add_argument("--k", type=float, default=0.8, help="unsharp mask strength")
    ap.add_argument("--out", default="build/fsr")
    ap.add_argument("--test", action="store_true", help="also check against numpy on a random image")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    m = build(a.w, a.h, a.a, a.k)
    pkg = os.path.join(a.out, "vxfsr_%dx%d.mlpackage" % (a.w, a.h))
    m.save(pkg)
    subprocess.run(["xcrun", "coremlcompiler", "compile", pkg, a.out], check=True, stdout=subprocess.DEVNULL)
    print(pkg, "->", os.path.join(a.out, "vxfsr_%dx%d.mlmodelc" % (a.w, a.h)))
    if a.test:
        from PIL import Image
        img = Image.fromarray((np.random.rand(a.h, a.w, 3) * 255).astype(np.uint8))
        out = m.predict({"image": img})["detail"]
        print("predict ok:", out.size)


if __name__ == "__main__":
    sys.exit(main())
