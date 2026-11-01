#!/usr/bin/env python3
# Method 3 ceilings (optional file): layers for tests/interp_warp_mac.m VXT_LAYERS made offline per pair
# (N, N + k) - "flow": the motion layer that lands each pixel of N where OpenCV's DIS optical flow (N -> N + k, a Mac tool
# only, Apache-2.0) says it went, through the h63 kernels' own geometry (the camera's turn from N-1 added back, the turn
# to N+k's camera taken out, / t); fill = the frame, conf = 1. What a perfect motion head could gain at most.
#   tools/interp_oracle.py flow --data CAPTURE --out DIR [--split heldout]
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import interp_model as im


def dirs(px, py, tan, W, H):
    return np.stack([(px / W * 2 - 1) * tan[0], (1 - py / H * 2) * tan[1], np.ones_like(px)], 0)


def proj(R, X, tan, W, H):
    Y = np.einsum("rc,chw->rhw", R, X); z = np.maximum(Y[2], 1e-5)
    return (Y[0] / z / tan[0] + 1) * 0.5 * W, (1 - Y[1] / z / tan[1]) * 0.5 * H


def flow_layers(ds, i, cv2, preset):
    ia, ib, ic = ds.pairs[i]
    mb, pb = ds.frames[ib]; mc, pc = ds.frames[ic]
    g = ds.geom(i); W, H = ds.W, ds.H
    gb = (np.clip(pb[0:3].astype(np.float32), 0, 1).mean(0) * 255).astype(np.uint8)
    gc = (np.clip(pc[0:3].astype(np.float32), 0, 1).mean(0) * 255).astype(np.uint8)
    dis = cv2.DISOpticalFlow_create(preset)
    fl = dis.calc(gb, gc, None)                          # (gb(x) ~ gc(x + flow))
    gy, gx = np.mgrid[0:H, 0:W].astype(np.float32) + 0.5
    tx, ty = gx + fl[..., 0], gy + fl[..., 1]
    qx, qy = proj(g["rot"].T, dirs(tx, ty, g["tan"], W, H), g["tan"], W, H)   # (back through the turn to N+k: in N's view)
    t = max(float(g["t"]), 0.02)
    mo = np.stack([qx - gx, qy - gy]) / t
    pax, pay = proj(g["camt"], dirs(gx, gy, g["tan"], W, H), g["tan"], W, H)
    m = mo + np.stack([gx - pax, gy - pay])
    y = np.concatenate([np.clip(pb[0:3].astype(np.float32), 0, 1), m / im.MOTION_UNIT, np.ones((1, H, W), np.float32)], 0)
    return mb["seq"], mc["seq"], y.astype(np.float16)


def past_layers(ds, i, cv2, preset):
    """'past': the motion over the interval before N from the picture itself (DIS N -> N-1, negated): what the game's
    velocity should be; no knowledge of N+k."""
    ia, ib, ic = ds.pairs[i]
    ma, pa = ds.frames[ia]; mb, pb = ds.frames[ib]; mc = ds.frames[ic][0]
    W, H = ds.W, ds.H
    ga = (np.clip(pa[0:3].astype(np.float32), 0, 1).mean(0) * 255).astype(np.uint8)
    gb = (np.clip(pb[0:3].astype(np.float32), 0, 1).mean(0) * 255).astype(np.uint8)
    fl = cv2.DISOpticalFlow_create(preset).calc(gb, ga, None)      # (gb(x) ~ ga(x + fl): it came from x + fl)
    scale = (mb["t"] - mb["t_prev"]) / max(mb["t"] - ma["t"], 1e-3)  # (per N's own interval)
    m = -np.moveaxis(fl, 2, 0) * scale
    y = np.concatenate([np.clip(pb[0:3].astype(np.float32), 0, 1), m / im.MOTION_UNIT, np.ones((1, H, W), np.float32)], 0)
    return mb["seq"], mc["seq"], y.astype(np.float16)


def scaled_layers(ds, i, cv2, preset):
    """'scaled': the game's velocity with one scalar per pair on its own motion (the camera's turn apart), the scalar
    that best matches the future flow (least squares over pixels with motion): is the gap a timing / scale error?"""
    ia, ib, ic = ds.pairs[i]
    mb, pb = ds.frames[ib]; mc = ds.frames[ic][0]
    g = ds.geom(i); W, H = ds.W, ds.H
    _, _, yo = flow_layers(ds, i, cv2, preset)
    x = im.encode_input(pb.astype(np.float32), mb, W, H)
    gy, gx = np.mgrid[0:H, 0:W].astype(np.float32) + 0.5
    pax, pay = proj(g["camt"], dirs(gx, gy, g["tan"], W, H), g["tan"], W, H)
    ct = np.stack([gx - pax, gy - pay])
    mv = np.nan_to_num(x[4:6]) * im.MOTION_UNIT - ct
    mo = yo[3:5].astype(np.float32) * im.MOTION_UNIT - ct
    ok = (np.abs(mv).sum(0) > 0.5) & np.isfinite(mo).all(0) & (np.abs(mo).sum(0) < 200)
    sc = float((mv[:, ok] * mo[:, ok]).sum() / max((mv[:, ok] ** 2).sum(), 1e-6)) if ok.sum() > 50 else 1.0
    sc = min(max(sc, -1.0), 4.0)
    y = np.concatenate([np.clip(pb[0:3].astype(np.float32), 0, 1), (ct + sc * mv) / im.MOTION_UNIT, np.ones((1, H, W), np.float32)], 0)
    scaled_layers.scs.append(sc)
    return mb["seq"], mc["seq"], y.astype(np.float16)
scaled_layers.scs = []


def affine_layers(ds, i, cv2, preset):
    """'affine': the game's velocity plus one affine field per pair (6 numbers) fitted robustly to the future flow's
    difference from it: is the gap global (the camera's translation, the pose or the FOV) or local (objects)?"""
    ia, ib, ic = ds.pairs[i]
    mb, pb = ds.frames[ib]; mc = ds.frames[ic][0]
    W, H = ds.W, ds.H
    _, _, yo = flow_layers(ds, i, cv2, preset)
    x = im.encode_input(pb.astype(np.float32), mb, W, H)
    mv = np.nan_to_num(x[4:6]) * im.MOTION_UNIT; mo = yo[3:5].astype(np.float32) * im.MOTION_UNIT
    r = mo - mv
    gy, gx = np.mgrid[0:H, 0:W].astype(np.float32) + 0.5
    A = np.stack([gx.ravel() / W, gy.ravel() / H, np.ones(W * H, np.float32)], 1)
    R = r.reshape(2, -1).T
    ok = np.isfinite(R).all(1) & (np.abs(R).sum(1) < 300)
    for _ in range(3):
        c, *_ = np.linalg.lstsq(A[ok], R[ok], rcond=None)
        e = np.abs(A @ c - R).sum(1); ok = ok & (e <= np.percentile(e[ok], 70))
    fit = (A @ c).T.reshape(2, H, W)
    y = np.concatenate([np.clip(pb[0:3].astype(np.float32), 0, 1), (mv + fit) / im.MOTION_UNIT, np.ones((1, H, W), np.float32)], 0)
    return mb["seq"], mc["seq"], y.astype(np.float16)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("cmd", choices=["flow", "past", "scaled", "affine"]); ap.add_argument("--data"); ap.add_argument("--out")
    ap.add_argument("--split", default="heldout"); ap.add_argument("--preset", type=int, default=2)
    a = ap.parse_args()
    import cv2
    ds = im.WarpPairs(a.data, a.split); os.makedirs(a.out, exist_ok=True)
    for i in range(len(ds)):
        sb, sc, y = {"flow": flow_layers, "past": past_layers, "scaled": scaled_layers, "affine": affine_layers}[a.cmd](ds, i, cv2, a.preset)
        y.tofile(os.path.join(a.out, "%d_%d.f16" % (sb, sc)))
    print("pairs", len(ds), "->", a.out)
    if scaled_layers.scs: q = np.array(scaled_layers.scs); print("scalar: median %.2f, 10-90 %% %.2f-%.2f" % (np.median(q), *np.percentile(q, [10, 90])))


if __name__ == "__main__":
    main()
