#!/usr/bin/env python3
# VX Mac's frame-prediction model for the Neural Engine ("method 3", ../AVP_MAC.md "NPU interpolation: method 3").
# Strength file (t7 only, never in the public tree). Our own network, trained from scratch: no third-party code or
# weights (PyTorch BSD-3 and coremltools BSD-3 are tools only).
#
# What it does. The Neural Engine cannot gather or scatter (no warp on it), and the presenter needs a picture at every
# 90 Hz display time while the model runs once per real game frame. So the model does not draw the predicted frame
# itself: once per real frame N it gives the warp what the warp lacks for long gaps (50-170 ms):
#   fill    (3)  the colour behind the frame's foreground edges (the background a moving object or a turn will
#                uncover), drawn where the warp finds a hole instead of stretching the edge;
#   motion  (2)  the game's velocity cleaned (particles, transparent surfaces, HUD remnants, its noise), per real-frame
#                interval, in the model's pixels / 16 (the same unit as its input);
#   conf    (1)  how far the warp should trust frame N's pixel (low on particles and smears): its weight in the warp.
# The GPU warp (vr/warp_core.m) then makes the frame at any t = (display time - frame time) / interval: frame N moved
# by motion * t, weighted by conf, holes filled from fill moved with the background's motion. Training renders that
# same composite differentiably (soft z-buffered forward splatting, written here) against the real frame N + gap.
#
# Input x (1, 6, H, W) fp16, planar (one IOSurface: OneComponent16Half, W x 6H; app/Sources/npu_model.m packs it on
# the GPU from the frames the host already copies):
#   0-2  colour of frame N (sRGB-encoded 0..1, as the game's 8-bit frame)
#   3    depth: log2(1 / d) / 12 clamped to 0..1 (d: the game's reversed depth, near / distance)
#   4-5  the game's velocity as scene motion over the interval before N, in model pixels / 16 (+x right, +y down)
# Output y (1, 6, H, W) fp16: fill (0..1), motion (input's unit), conf (0..1).
#
#   tools/interp_model.py smoke                       synthetic data: train, export, Core ML check (pipeline proof)
#   tools/interp_model.py train --data DIR --out build/interp [--steps N] [--resume ckpt]
#   tools/interp_model.py export --ckpt build/interp/vxinterp.pt --w 416 --h 240 --out build/interp
#   tools/interp_model.py info --data DIR             what a capture holds (frames, bursts, gaps)
#   tools/interp_model.py params [--widths 32,64,128,160]
import argparse, glob, math, os, struct, subprocess, sys, time, zlib
import numpy as np

CH_IN, CH_OUT = 6, 6
MOTION_UNIT = 16.0          # (model pixels per input unit of motion)
DEPTH_LOG_RANGE = 12.0      # (log2 of distance / near, 0..12: 0.2 m .. 820 m)
DEFAULT_W, DEFAULT_H = 416, 240
DEFAULT_WIDTHS = (32, 64, 96, 128)   # (0.91 M parameters: the paced M1 Max bench, AVP_MAC.md)
VEL_K_DEFAULT = (-1.05, -1.05)   # (vel_check's measured scale, h-AVP 2026-11-01: corr ~-0.78, k ~-1.05)


# ---------------------------------------------------------------------------------------------------------------
# The capture format (app/Sources/interp_capture.m writes it; ../AVP_MAC.md "Capture format")
# file:   "VXIC" u32 version u32 w u32 h u32 planes u32 reserved[3]                                  (32 bytes)
# record: "VXFR" u32 header_bytes u32 payload_bytes u32 raw_bytes u32 flags u32 burst u32 index
#         u32 src_w src_h depth_w depth_h vel_w vel_h  u64 seq u64 cam_seq  f64 t_present f64 t_prev
#         f32 vel_k[2] vel_corr tan[2] near sent_yaw sent_pitch  f32 cam[16]  f32 cam_vel[3]  f32 reserved
#         then payload: zlib (raw deflate) of planes r g b d vx vy, each h*w fp16, row-major, no padding
#         (raw: colour 0..1 sRGB-encoded, d the game's reversed depth, v the velocity target's own values)
FILE_HDR = struct.Struct("<4s7I")
REC_HDR = struct.Struct("<4s6I6I2Q2d8f16f3ff")
F_DEPTH, F_VEL, F_VEL_OK, F_VR, F_STICK, F_HUD_SPLIT, F_CAM, F_DEPTH16, F_ZLIB = (1 << i for i in range(9))


def read_capture(path):
    """Yields (meta dict, planes float32 (6, h, w)) for every record of one .vxic file."""
    with open(path, "rb") as f:
        hdr = f.read(FILE_HDR.size)
        magic, ver, w, h, planes, *_ = FILE_HDR.unpack(hdr)
        if magic != b"VXIC" or ver != 1: raise ValueError("%s: not a v1 capture" % path)
        while True:
            hb = f.read(REC_HDR.size)
            if len(hb) < REC_HDR.size: return
            v = REC_HDR.unpack(hb)
            if v[0] != b"VXFR" or v[1] != REC_HDR.size: raise ValueError("%s: bad record" % path)
            payload = f.read(v[2])
            if len(payload) < v[2]: return     # (the app stopped mid-write)
            flags = v[4]
            raw = zlib.decompress(payload, -15) if flags & F_ZLIB else payload
            if len(raw) != v[3] or v[3] != planes * w * h * 2: raise ValueError("%s: bad payload" % path)
            meta = dict(flags=flags, burst=v[5], index=v[6], src=(v[7], v[8]), depth_size=(v[9], v[10]), vel_size=(v[11], v[12]),
                        seq=v[13], cam_seq=v[14], t=v[15], t_prev=v[16], vel_k=(v[17], v[18]), vel_corr=v[19], tan=(v[20], v[21]),
                        near=v[22], sent=(v[23], v[24]), cam=np.array(v[25:41], np.float32), cam_vel=np.array(v[41:44], np.float32), w=w, h=h)
            yield meta, np.frombuffer(raw, np.float16).reshape(planes, h, w).astype(np.float32)


def encode_input(planes, meta, W, H, vel_k=None):
    """The model's input from one captured frame's raw planes (as app/Sources/npu_model.m's pack kernel does)."""
    rgb, d, v = planes[0:3], planes[3:4], planes[4:6]
    k = vel_k or (meta["vel_k"] if meta["flags"] & F_VEL_OK and abs(meta["vel_k"][0]) > 0.1 else VEL_K_DEFAULT)
    dep = np.clip(np.log2(1.0 / np.maximum(d, 1e-6)) / DEPTH_LOG_RANGE, 0, 1) if meta["flags"] & F_DEPTH else np.ones_like(d)
    # (scene motion over the interval before N: the target's value times vel_check's scale is the picture's shift in
    #  frame widths (+ right); in model pixels / MOTION_UNIT)
    mot = np.stack([v[0] * k[0] * W, v[1] * k[1] * H]) / MOTION_UNIT if meta["flags"] & F_VEL else np.zeros_like(v)
    x = np.concatenate([np.clip(rgb, 0, 1), dep, np.nan_to_num(mot)], 0).astype(np.float32)
    if x.shape[1:] != (H, W): x = resize_np(x, W, H)
    return x


def resize_np(x, W, H):
    import torch, torch.nn.functional as F
    return F.interpolate(torch.from_numpy(x)[None], size=(H, W), mode="bilinear", align_corners=False)[0].numpy()


class CaptureDataset:
    """Pairs (frame N, frame N + k) inside one burst, k = 1..max_k, gap at most max_gap_ms; only frames with depth and
    velocity. Returns (x, target rgb, gap in intervals of N's own velocity)."""
    def __init__(self, root, W=DEFAULT_W, H=DEFAULT_H, max_k=2, max_gap_ms=200, vr_only=False):
        self.W, self.H = W, H
        self.frames, self.pairs = [], []
        files = sorted(glob.glob(os.path.join(root, "**", "*.vxic"), recursive=True)) if os.path.isdir(root) else [root]
        for p in files:
            recs = list(read_capture(p))
            base = len(self.frames)
            for m, pl in recs: self.frames.append((m, pl.astype(np.float16)))
            for i, (m, _) in enumerate(recs):
                if not (m["flags"] & F_DEPTH and m["flags"] & F_VEL) or (vr_only and not m["flags"] & F_VR): continue
                interval = m["t"] - m["t_prev"]
                if not 0.005 < interval < 0.4: continue
                for k in range(1, max_k + 1):
                    if i + k >= len(recs): break
                    n = recs[i + k][0]
                    if n["burst"] != m["burst"] or n["index"] != m["index"] + k: break
                    gap = n["t"] - m["t"]
                    if gap * 1e3 > max_gap_ms: break
                    self.pairs.append((base + i, base + i + k, gap / interval))
    def __len__(self): return len(self.pairs)
    def __getitem__(self, i):
        a, b, tau = self.pairs[i]
        ma, pa = self.frames[a]; mb_, pb = self.frames[b]
        x = encode_input(pa.astype(np.float32), ma, self.W, self.H)
        y = pb[0:3].astype(np.float32)
        if y.shape[1:] != (self.H, self.W): y = resize_np(y, self.W, self.H)
        return x, np.clip(y, 0, 1), np.float32(tau)


def info(root):
    ds = CaptureDataset(root)
    gaps = np.array([p[2] for p in ds.pairs]) if ds.pairs else np.zeros(0)
    fl = np.array([m["flags"] for m, _ in ds.frames]) if ds.frames else np.zeros(0, int)
    ivs = np.array([(m["t"] - m["t_prev"]) * 1e3 for m, _ in ds.frames]) if ds.frames else np.zeros(0)
    print("frames %d, bursts %d, pairs %d" % (len(ds.frames), len({m["burst"] for m, _ in ds.frames}), len(ds.pairs)))
    if len(fl):
        for n, b in (("depth", F_DEPTH), ("velocity", F_VEL), ("velocity verified", F_VEL_OK), ("vr mode", F_VR), ("hud split", F_HUD_SPLIT), ("camera", F_CAM)):
            print("  %-18s %5.1f %%" % (n, 100 * np.mean((fl & b) > 0)))
        print("  interval ms: median %.0f, 10-90 %% %.0f-%.0f" % (np.median(ivs), np.percentile(ivs, 10), np.percentile(ivs, 90)))
    if len(gaps): print("  gap / interval: median %.2f, max %.2f" % (np.median(gaps), gaps.max()))


# ---------------------------------------------------------------------------------------------------------------
# The network: a U-Net at half resolution and below (a stride-2 stem, four levels, nearest upsampling, concatenated
# skips), a pixel shuffle back to full size, residual heads. Only conv / relu / upsample_nearest / concat / add /
# sigmoid / clip / pixel_shuffle: every one has a Neural Engine kernel.
def build_net(widths=DEFAULT_WIDTHS, dec_convs=1):
    import torch, torch.nn as nn

    def cbr(i, o, s=1):
        return nn.Sequential(nn.Conv2d(i, o, 3, s, 1), nn.ReLU(inplace=True))

    class Net(nn.Module):
        def __init__(self):
            super().__init__()
            w = widths
            self.stem = nn.Sequential(cbr(CH_IN, w[0], 2), cbr(w[0], w[0]))                      # 1/2
            self.enc = nn.ModuleList([nn.Sequential(cbr(w[i], w[i + 1], 2), cbr(w[i + 1], w[i + 1])) for i in range(len(w) - 1)])
            self.dec = nn.ModuleList([nn.Sequential(cbr(w[i + 1] + w[i], w[i]), *[cbr(w[i], w[i]) for _ in range(dec_convs)])
                                      for i in reversed(range(len(w) - 1))])
            self.head = nn.Conv2d(w[0], CH_OUT * 4, 3, 1, 1)                                         # -> full size
            self.up = nn.Upsample(scale_factor=2, mode="nearest")
            self.shuffle = nn.PixelShuffle(2)
            nn.init.zeros_(self.head.weight); nn.init.zeros_(self.head.bias)                        # (starts as: fill = frame, motion = game's, conf 0.5)

        def forward(self, x):
            skips = [self.stem(x)]
            for e in self.enc: skips.append(e(skips[-1]))
            h = skips[-1]
            for j, d in enumerate(self.dec):
                h = d(torch.cat([self.up(h), skips[-2 - j]], 1))
            r = self.shuffle(self.head(h))
            fill = torch.clamp(x[:, 0:3] + r[:, 0:3], 0, 1)
            motion = x[:, 4:6] + r[:, 3:5]
            conf = torch.sigmoid(r[:, 5:6])
            return torch.cat([fill, motion, conf], 1)
    return Net()


def count_params(net): return sum(p.numel() for p in net.parameters())


# ---------------------------------------------------------------------------------------------------------------
# The warp's composite, differentiable (training only; the runtime's is vr/warp_core.m on the GPU)
def splat(src, flow, imp, cov_w):
    """Forward splatting with bilinear footprints: each source pixel to (x + flow), weighted by imp (soft z-buffer,
    exp(alpha * nearness)) and cov_w; returns the normalised image and the coverage (sum of bilinear * cov_w)."""
    import torch
    B, C, H, W = src.shape
    gy, gx = torch.meshgrid(torch.arange(H, device=src.device, dtype=src.dtype), torch.arange(W, device=src.device, dtype=src.dtype), indexing="ij")
    x = gx[None] + flow[:, 0]; y = gy[None] + flow[:, 1]
    x0 = torch.floor(x); y0 = torch.floor(y)
    num = src.new_zeros(B, C, H * W); den = src.new_zeros(B, 1, H * W); cov = src.new_zeros(B, 1, H * W)
    w_imp = (imp * cov_w).reshape(B, 1, -1); cw = cov_w.reshape(B, 1, -1)
    s = src.reshape(B, C, -1)
    for dx in (0, 1):
        for dy in (0, 1):
            xi = x0 + dx; yi = y0 + dy
            wb = (1 - (x - xi).abs()) * (1 - (y - yi).abs())
            ok = (xi >= 0) & (xi < W) & (yi >= 0) & (yi < H)
            wb = (wb * ok).reshape(B, 1, -1)
            idx = (yi.clamp(0, H - 1) * W + xi.clamp(0, W - 1)).long().reshape(B, 1, -1)
            num.scatter_add_(2, idx.expand(B, C, -1), s * wb * w_imp)
            den.scatter_add_(2, idx, wb * w_imp)
            cov.scatter_add_(2, idx, wb * cw)
    out = num / den.clamp_min(1e-6)
    return out.reshape(B, C, H, W), cov.reshape(B, 1, H, W)


def bwarp(img, flow):
    """Backward bilinear warp: out(p) = img(p + flow(p)), clamped at the border (gathers: MPS has no grid_sample
    backward)."""
    import torch
    B, C, H, W = img.shape
    gy, gx = torch.meshgrid(torch.arange(H, device=img.device, dtype=img.dtype), torch.arange(W, device=img.device, dtype=img.dtype), indexing="ij")
    x = (gx[None] + flow[:, 0]).clamp(0, W - 1); y = (gy[None] + flow[:, 1]).clamp(0, H - 1)
    x0 = torch.floor(x).clamp(0, W - 2); y0 = torch.floor(y).clamp(0, H - 2)
    fx = (x - x0)[:, None]; fy = (y - y0)[:, None]
    flat = img.reshape(B, C, -1)
    def at(xx, yy): return torch.gather(flat, 2, (yy * W + xx).long().reshape(B, 1, -1).expand(B, C, -1)).reshape(B, C, H, W)
    return (at(x0, y0) * (1 - fx) * (1 - fy) + at(x0 + 1, y0) * fx * (1 - fy) + at(x0, y0 + 1) * (1 - fx) * fy + at(x0 + 1, y0 + 1) * fx * fy)


def far_motion(depth_enc, motion, k=7):
    """Each pixel's motion of the farthest surface within k x k (the background a hole there shows)."""
    import torch, torch.nn.functional as F
    B, _, H, W = depth_enc.shape
    pd = F.unfold(depth_enc, k, padding=k // 2)                     # (B, k*k, HW)
    i = pd.argmax(1, keepdim=True)                                  # (larger encoded depth = farther)
    pm = F.unfold(motion, k, padding=k // 2).reshape(B, 2, k * k, H * W)
    return torch.gather(pm, 2, i[:, None].expand(B, 2, 1, H * W)).reshape(B, 2, H, W)


def composite(x, y, tau, alpha=20.0):
    """The frame at gap tau (intervals) from the model's output y: frame N splatted by motion * tau, weighted by conf,
    holes from fill moved with the background's motion. Returns (picture, hole weight)."""
    import torch, torch.nn.functional as F
    B, _, H, W = x.shape
    t = tau.reshape(B, 1, 1, 1)
    flow = y[:, 3:5] * MOTION_UNIT * t
    near = 1 - x[:, 3:4]                                            # (nearer wins the soft z-buffer)
    fg, cov = splat(x[:, 0:3], flow, torch.exp(alpha * (near - 1)), y[:, 5:6] * 2)
    fm = far_motion(x[:, 3:4], y[:, 3:5].detach()) * MOTION_UNIT * t   # (fill learns colour; motion from the splat)
    bg = bwarp(y[:, 0:3], -fm)
    a = cov.clamp(0, 1)
    return fg * a + bg * (1 - a), 1 - a


def grad_l1(a, b):
    return (a[..., 1:, :] - a[..., :-1, :] - (b[..., 1:, :] - b[..., :-1, :])).abs().mean() + \
           (a[..., :, 1:] - a[..., :, :-1] - (b[..., :, 1:] - b[..., :, :-1])).abs().mean()


def loss_fn(x, y, tgt, tau):
    pred, hole = composite(x, y, tau)
    l1 = (pred - tgt).abs().mean()
    edge = grad_l1(pred, tgt)                                       # (edges: sharpness, the warp's block edges)
    holes = ((pred - tgt).abs() * hole).sum() / hole.sum().clamp_min(1.0)   # (hole-aware: the fill where it is used)
    reg = (y[:, 3:5] - x[:, 4:6]).abs().mean() * 0.02               # (motion near the game's unless the picture says otherwise)
    return l1 + 0.5 * edge + 0.5 * holes + reg, dict(l1=float(l1), edge=float(edge), holes=float(holes))


# ---------------------------------------------------------------------------------------------------------------
# Synthetic scenes (the pipeline's proof before real data): a textured background panned by the camera, 2-5 textured
# objects nearer, each with its own motion; frame N, its velocity (over the interval before), depth, and the frame
# at N + tau with the same motions carried on.
def synth_batch(B, W, H, device, seed=None):
    import torch
    g = torch.Generator(device="cpu")
    def r(*s, lo=0.0, hi=1.0): return (torch.rand(*s, generator=g) * (hi - lo) + lo).to(device)
    if seed is None: g.seed()
    else: g.manual_seed(seed)
    gy, gx = torch.meshgrid(torch.arange(H, device=device, dtype=torch.float32), torch.arange(W, device=device, dtype=torch.float32), indexing="ij")
    tau = r(B, lo=0.3, hi=2.2)
    cam = r(B, 2, lo=-12, hi=12)                                   # (background motion, px / interval)
    def tex(u, v, f, ph, base):                                    # (a texture as a function of surface coordinates)
        return (base[:, :, None, None] + 0.25 * torch.sin(u[:, None] * f[:, 0, None, None, None] + ph[:, 0, None, None, None])
                * torch.cos(v[:, None] * f[:, 1, None, None, None] + ph[:, 1, None, None, None]) + 0.15 * torch.sign(torch.sin(u[:, None] * f[:, 2, None, None, None]))).clamp(0, 1)
    bf, bp, bb = r(B, 3, lo=0.03, hi=0.4), r(B, 2, hi=6.28), r(B, 3, lo=0.2, hi=0.8)
    bdep = r(B, lo=0.55, hi=0.9)
    nobj = 4
    oc, osz, ov = r(B, nobj, 2), r(B, nobj, 2, lo=0.06, hi=0.3), r(B, nobj, 2, lo=-18, hi=18)
    of, op, ob, od = r(B, nobj, 3, lo=0.05, hi=0.6), r(B, nobj, 2, hi=6.28), r(B, nobj, 3, lo=0.1, hi=0.95), r(B, nobj, lo=0.05, hi=0.5)
    on = (r(B, nobj) < 0.8).float()
    def render(t):
        u = gx[None] + cam[:, 0, None, None] * t[:, None, None]; v = gy[None] + cam[:, 1, None, None] * t[:, None, None]
        img = tex(u, v, bf, bp, bb)
        dep = bdep[:, None, None, None] + 0.05 * torch.sin(v[:, None] * 0.02)
        mot = cam[:, :, None, None].expand(B, 2, H, W).clone()
        for k in range(nobj):                                      # (only a nearer surface covers: order-free)
            cx = oc[:, k, 0, None, None] * W + ov[:, k, 0, None, None] * t[:, None, None]
            cy = oc[:, k, 1, None, None] * H + ov[:, k, 1, None, None] * t[:, None, None]
            lx, ly = gx[None] - cx, gy[None] - cy
            m = ((lx / (osz[:, k, 0, None, None] * W)) ** 2 + (ly / (osz[:, k, 1, None, None] * H)) ** 2 < 1).float() * on[:, k, None, None]
            m = m[:, None] * (od[:, k, None, None, None] < dep).float()
            img = img * (1 - m) + tex(lx, ly, of[:, k], op[:, k], ob[:, k]) * m
            dep = dep * (1 - m) + od[:, k, None, None, None] * m
            mot = mot * (1 - m) + ov[:, k, :, None, None] * m
        return img, dep, mot
    z = torch.zeros(B, device=device)
    img0, dep0, mot0 = render(z)
    img1, _, _ = render(tau)
    x = torch.cat([img0, dep0, mot0 / MOTION_UNIT], 1)
    return x, img1, tau


# ---------------------------------------------------------------------------------------------------------------
def device_pick():
    import torch
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def train(net, batches, steps, lr, log_every=50, ckpt=None):
    import torch
    dev = device_pick(); net.to(dev).train()
    opt = torch.optim.AdamW(net.parameters(), lr=lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=lr, total_steps=steps, pct_start=0.1)
    hist = []
    t0 = time.time()
    for s in range(steps):
        x, tgt, tau = next(batches)
        x, tgt, tau = x.to(dev), tgt.to(dev), tau.to(dev)
        y = net(x)
        loss, parts = loss_fn(x, y, tgt, tau)
        opt.zero_grad(); loss.backward(); opt.step(); sched.step()
        hist.append(float(loss))
        if s % log_every == 0 or s == steps - 1:
            print("step %5d loss %.4f l1 %.4f edge %.4f holes %.4f  (%.1f s)" % (s, float(loss), parts["l1"], parts["edge"], parts["holes"], time.time() - t0), flush=True)
    if ckpt:
        torch.save({"state": net.state_dict(), "widths": getattr(net, "_widths", DEFAULT_WIDTHS), "dec_convs": getattr(net, "_dec_convs", 1)}, ckpt)
    return hist


def eval_loss(net, batches):
    """Mean loss and picture L1 over fixed batches; net None: the same composite with no model (fill = frame, motion =
    the game's, conf 0.5), what training must beat."""
    import torch
    dev = device_pick(); tot = l1 = 0
    if net is not None: net.to(dev).eval()
    with torch.no_grad():
        for x, tgt, tau in batches:
            x, tgt, tau = x.to(dev), tgt.to(dev), tau.to(dev)
            y = net(x) if net is not None else torch.cat([x[:, 0:3], x[:, 4:6], torch.full_like(x[:, 0:1], 0.5)], 1)
            lo, parts = loss_fn(x, y, tgt, tau); tot += float(lo); l1 += parts["l1"]
    return tot / len(batches), l1 / len(batches)


def export(net, W, H, out, name=None):
    import torch, coremltools as ct
    net = net.cpu().eval().float()
    ex = torch.rand(1, CH_IN, H, W)
    with torch.no_grad(): tr = torch.jit.trace(net, ex)
    m = ct.convert(tr, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
                   inputs=[ct.TensorType(name="x", shape=(1, CH_IN, H, W), dtype=np.float16)],
                   outputs=[ct.TensorType(name="y", dtype=np.float16)],
                   compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_AND_NE)
    m.short_description = "VX Mac frame prediction (method 3): fill, motion, conf from colour, depth, velocity; %dx%d" % (W, H)
    m.user_defined_metadata["vxinterp"] = "v1 widths=%s params=%d motion_unit=%g depth_log=%g" % (
        ",".join(map(str, getattr(net, "_widths", DEFAULT_WIDTHS))), count_params(net), MOTION_UNIT, DEPTH_LOG_RANGE)
    os.makedirs(out, exist_ok=True)
    name = name or "vxinterp_%dx%d" % (W, H)
    pkg = os.path.join(out, name + ".mlpackage")
    m.save(pkg)
    subprocess.run(["xcrun", "coremlcompiler", "compile", pkg, out], check=True, stdout=subprocess.DEVNULL)
    print(pkg, "->", os.path.join(out, name + ".mlmodelc"))
    return m, pkg


def make_net(widths, dec_convs):
    net = build_net(widths, dec_convs); net._widths = widths; net._dec_convs = dec_convs
    return net


# ---------------------------------------------------------------------------------------------------------------
# Run 2 (h63b): training against the h63 warp path (vr/xros_vr.m draw_eye_inner + vr/warp_core.m with vxw_set_interp),
# differentiable, and a real held-out split. run1 collapsed: its composite let conf scale the splat's own weights, so
# conf -> 0 switched the forward splat off (the fill warped backwards won) and the motion / fill heads never moved.
# Here, as in the warp, conf cannot remove anything: the splat's coverage comes from its bilinear footprints alone;
# conf only blends frame N's colour against the fill where a pixel landed (ca = 1 - (1 - min(2 conf, 1)) x min(t, 1)),
# holes show the fill at the background's displacement; plus a small pull of conf towards 1.
# The geometry is the warp's: frame N's pixel moved by t x (the model's motion less the camera's turn over the interval
# before N, from N-1's camera), then turned to N+k's camera (the head's pose at display time: the captured game camera;
# centre eye, no translation: h63 has no h60 move with the model); t = min(age, 150 ms) / N's own interval, at most 1.5;
# from 100 ms of age low-conf motion scaled towards conf; z-order by depth (soft, alpha 40, where the warp's is hard).
# Loss and PSNR only where N+k's view lies inside N's frame. The authoritative numbers are the real kernels':
# tests/interp_warp_mac.m with VXT_SPLIT=heldout (the same burst rule, heldout_burst below).
HELD_CHUNK, HELD_EVERY = 20, 5          # (bursts in chunks of 20 (~40 s); every 5th chunk held out)
T_CAP, AGE_CAP, FADE0 = 1.5, 0.150, 0.100


def heldout_burst(b):
    return ((b - 1) // HELD_CHUNK) % HELD_EVERY == HELD_EVERY - 1


def cam_rows(m):
    return m["cam"].reshape(4, 4)[:3, :3].astype(np.float32)


class WarpPairs:
    """Pairs (N, N + k), k 1..2, in one burst with N - 1 there too (its camera), age <= 200 ms, N's own interval 5-400 ms,
    all three with the game camera, N with depth and velocity. split: 'train' | 'heldout' | 'all'."""
    def __init__(self, root, split="train", W=DEFAULT_W, H=DEFAULT_H, max_age=0.2):
        self.W, self.H = W, H
        self.frames, self.pairs = [], []
        files = sorted(glob.glob(os.path.join(root, "**", "*.vxic"), recursive=True)) if os.path.isdir(root) else [root]
        for p in files:
            base = len(self.frames); recs = []
            for m, pl in read_capture(p):
                if split != "all" and heldout_burst(m["burst"]) != (split == "heldout"): continue
                recs.append(m); self.frames.append((m, pl.astype(np.float16)))
            for i in range(1, len(recs)):
                a, b = recs[i - 1], recs[i]
                if a["burst"] != b["burst"] or a["index"] + 1 != b["index"]: continue
                if not (a["flags"] & F_CAM) or (b["flags"] & (F_DEPTH | F_VEL | F_CAM)) != (F_DEPTH | F_VEL | F_CAM): continue
                gap = b["t"] - b["t_prev"]
                if not 0.005 < gap < 0.4: continue
                for k in (1, 2):
                    if i + k >= len(recs): break
                    c = recs[i + k]
                    if c["burst"] != b["burst"] or c["index"] != b["index"] + k: break
                    age = c["t"] - b["t"]
                    if age > max_age or not c["flags"] & F_CAM: break
                    self.pairs.append((base + i - 1, base + i, base + i + k))
    def __len__(self): return len(self.pairs)
    def geom(self, i):
        ia, ib, ic = self.pairs[i]
        a, b, c = self.frames[ia][0], self.frames[ib][0], self.frames[ic][0]
        Ra, Rb, Rc = cam_rows(a), cam_rows(b), cam_rows(c)
        gap, age = b["t"] - b["t_prev"], c["t"] - b["t"]
        t = min(min(age, AGE_CAP) / gap, T_CAP)
        cf = min(max((age - FADE0) / (AGE_CAP - FADE0), 0), 1); cf = cf * cf * (3 - 2 * cf)
        return dict(rot=Rc @ Rb.T, camt=Ra @ Rb.T, tan=np.array(b["tan"], np.float32), t=np.float32(t), ct=np.float32(min(t, 1)),
                    cf=np.float32(cf), age=np.float32(age))
    mtarget_dir = None   # (run4: tools/interp_oracle.py flow layers per pair - the motion that lands each pixel where it went)
    def __getitem__(self, i):
        ia, ib, ic = self.pairs[i]
        mb, pb = self.frames[ib]; mc, pc = self.frames[ic]
        x = encode_input(pb.astype(np.float32), mb, self.W, self.H)
        g = self.geom(i)
        if self.mtarget_dir:
            f = os.path.join(self.mtarget_dir, "%d_%d.f16" % (mb["seq"], mc["seq"]))
            g["mt"] = np.fromfile(f, np.float16).reshape(6, self.H, self.W)[3:5].astype(np.float32) if os.path.exists(f) else np.full((2, self.H, self.W), np.nan, np.float32)
        return x, np.clip(pc[0:3].astype(np.float32), 0, 1), g


def batch_of(ds, idx):
    import torch
    xs, ys, gs = zip(*[ds[int(i)] for i in idx])
    g = {k: torch.from_numpy(np.stack([d[k] for d in gs])) for k in gs[0]}
    return torch.from_numpy(np.stack(xs)), torch.from_numpy(np.stack(ys)), g


def sample_at(img, sx, sy):
    """img sampled bilinearly at absolute pixel-centre coordinates (sx, sy) (B, H, W), clamped at the border."""
    import torch
    B, C, H, W = img.shape
    x = (sx - 0.5).clamp(0, W - 1); y = (sy - 0.5).clamp(0, H - 1)
    x0 = torch.floor(x).clamp(0, W - 2); y0 = torch.floor(y).clamp(0, H - 2)
    fx = (x - x0)[:, None]; fy = (y - y0)[:, None]
    flat = img.reshape(B, C, -1)
    def at(xx, yy): return torch.gather(flat, 2, (yy * W + xx).long().reshape(B, 1, -1).expand(B, C, -1)).reshape(B, C, H, W)
    return at(x0, y0) * (1 - fx) * (1 - fy) + at(x0 + 1, y0) * fx * (1 - fy) + at(x0, y0 + 1) * (1 - fx) * fy + at(x0 + 1, y0 + 1) * fx * fy


def splat_to(src, qx, qy, imp, ok):
    """Forward splatting of src's pixels to absolute pixel-centre positions (qx, qy), bilinear footprints weighted by imp
    (the soft z-buffer); returns the normalised image and the coverage (footprints alone: nothing scales it away)."""
    B, C, H, W = src.shape
    x = qx - 0.5; y = qy - 0.5
    import torch
    x0 = torch.floor(x); y0 = torch.floor(y)
    num = src.new_zeros(B, C, H * W); den = src.new_zeros(B, 1, H * W); cov = src.new_zeros(B, 1, H * W)
    w_imp = (imp * ok).reshape(B, 1, -1); okf = ok.reshape(B, 1, -1)
    s = src.reshape(B, C, -1)
    for dx in (0, 1):
        for dy in (0, 1):
            xi = x0 + dx; yi = y0 + dy
            wb = (1 - (x - xi).abs()) * (1 - (y - yi).abs())
            inside = (xi >= 0) & (xi < W) & (yi >= 0) & (yi < H)
            wb = (wb * inside).reshape(B, 1, -1)
            idx = (yi.clamp(0, H - 1) * W + xi.clamp(0, W - 1)).long().reshape(B, 1, -1)
            num.scatter_add_(2, idx.expand(B, C, -1), s * wb * w_imp)
            den.scatter_add_(2, idx, wb * w_imp)
            cov.scatter_add_(2, idx, wb * okf)
    # (den holds exp(alpha (near - 1)) ~ 4e-18 for the sky at alpha 40: a clamp at 1e-8 blacked the far scene out - run1's
    #  splat (alpha 20, clamp 1e-6) had the same flaw for everything beyond ~exp(-14): a likely part of its collapse)
    return (num / den.clamp_min(1e-30)).reshape(B, C, H, W), cov.reshape(B, 1, H, W)


def project(R, X, tan, W, H):
    """Rows of R (B, 3, 3) applied to directions X (B, 3, H, W); their pixel-centre positions in a frame of tangents tan."""
    import torch
    Y = torch.einsum("brc,bchw->brhw", R, X)
    z = Y[:, 2]
    zs = torch.where(z > 1e-5, z, torch.full_like(z, 1e-5))
    tx = tan[:, 0, None, None]; ty = tan[:, 1, None, None]
    return (Y[:, 0] / zs / tx + 1) * 0.5 * W, (1 - Y[:, 1] / zs / ty) * 0.5 * H, z > 1e-5


def composite_h63(x, y, g, alpha=40.0):
    """The h63 warp of frame N to N + k with the model's layers y; returns (picture, hole weight, mask of N+k's view inside N)."""
    import torch
    B, _, H, W = x.shape
    dev = x.device
    gy, gx = torch.meshgrid(torch.arange(H, device=dev, dtype=x.dtype) + 0.5, torch.arange(W, device=dev, dtype=x.dtype) + 0.5, indexing="ij")
    gx = gx[None].expand(B, H, W); gy = gy[None].expand(B, H, W)
    tan = g["tan"].to(dev); tx = tan[:, 0, None, None]; ty = tan[:, 1, None, None]
    def dirs(px, py): return torch.stack([(px / W * 2 - 1) * tx, (1 - py / H * 2) * ty, torch.ones_like(px)], 1)
    t = g["t"].to(dev)[:, None, None]; ct = g["ct"].to(dev)[:, None, None, None]; cf = g["cf"].to(dev)[:, None, None, None]
    rot = g["rot"].to(dev); camt = g["camt"].to(dev)
    conf = y[:, 5:6]; a2 = (2 * conf).clamp(0, 1)
    # (the model's motion, the camera's turn over the interval before N out (VXW_CAM_MV), the long-gap fade)
    pax, pay, _ = project(camt, dirs(gx, gy), tan, W, H)
    m = y[:, 3:5] * MOTION_UNIT - torch.stack([gx - pax, gy - pay], 1)
    big = (m.norm(dim=1, keepdim=True) > 0.25 * max(W, H)) | ~torch.isfinite(m).all(1, keepdim=True)
    m = torch.where(big, torch.zeros_like(m), m)
    m = m * (1 - cf + cf * a2)
    # (moved by t, turned to N+k's camera)
    qx, qy, ok = project(rot, dirs(gx + t * m[:, 0], gy + t * m[:, 1]), tan, W, H)
    near = 1 - x[:, 3:4]
    src = torch.cat([x[:, 0:3], y[:, 0:3], conf], 1)
    sp, cov = splat_to(src, qx, qy, torch.exp(alpha * (near - 1)), ok[:, None].to(x.dtype))
    c_s, f_s, k_s = sp[:, 0:3], sp[:, 3:6], sp[:, 6:7]
    ca = 1 - (1 - (2 * k_s).clamp(0, 1)) * ct
    cc = f_s + (c_s - f_s) * ca
    # (holes: the fill at the background's displacement - N+k's ray back into N (rotation only) less the farthest
    #  neighbour's own motion x t)
    rot_t = rot.transpose(1, 2)
    rx, ry, rok = project(rot_t, dirs(gx, gy), tan, W, H)
    fm = far_motion(x[:, 3:4], m.detach())
    fmr = sample_at(fm, rx, ry)
    bg = sample_at(y[:, 0:3], rx - t * fmr[:, 0], ry - t * fmr[:, 1])
    a = cov.clamp(0, 1)
    mask = (rok & (rx > 2) & (rx < W - 2) & (ry > 2) & (ry < H - 2))[:, None].to(x.dtype)
    return cc * a + bg * (1 - a), 1 - a, mask


def loss_h63(x, y, tgt, g):
    pred, hole, mask = composite_h63(x, y, g)
    ms = mask.sum().clamp_min(1.0)
    l1 = ((pred - tgt).abs() * mask).sum() / (ms * 3)
    edge = grad_l1(pred * mask, tgt * mask)
    hw = hole * mask
    holes = ((pred - tgt).abs() * hw).sum() / (hw.sum() * 3).clamp_min(1.0)
    reg = (y[:, 3:5] - x[:, 4:6]).abs().mean() * 0.02
    conf_pull = (1 - y[:, 5:6]).mean() * 0.01
    return l1 + 0.5 * edge + 0.5 * holes + reg + conf_pull, dict(l1=float(l1), holes=float(holes), conf=float(y[:, 5].mean()))


def loss_h63_v2(x, y, tgt, g):
    """run3: aligned with the picture metric - Charbonnier over N+k's view inside N at full size and 1/2, 1/4, 1/8
    (the coarse scales give the motion a gradient beyond the splat's one-pixel footprints), the holes' error over the
    whole view (not over the hole area: run2 traded the picture for a few hole pixels), a weak pull of motion towards
    the game's, and a penalty only against conf collapsing (mean under 0.3)."""
    import torch, torch.nn.functional as F
    pred, hole, mask = composite_h63(x, y, g)
    def ch(a, b, m): return ((((a - b) ** 2 + 1e-6).sqrt()) * m).sum() / (m.sum() * 3).clamp_min(1.0)
    l = ch(pred, tgt, mask); tot = l
    p_, t_, m_ = pred * mask, tgt * mask, mask
    for k in (2, 4, 8):
        mp = F.avg_pool2d(m_, k); ok = (mp > 0.99).to(mp.dtype)
        tot = tot + 0.5 * ch(F.avg_pool2d(p_, k) / mp.clamp_min(1e-3), F.avg_pool2d(t_, k) / mp.clamp_min(1e-3), ok)
    hw = hole * mask
    holes = ((pred - tgt).abs() * hw).sum() / (mask.sum() * 3).clamp_min(1.0)
    reg = (y[:, 3:5] - x[:, 4:6]).abs().mean() * 0.005
    collapse = F.relu(0.3 - y[:, 5].mean()) * 0.1
    return tot + 2.0 * holes + reg + collapse, dict(l1=float(l), holes=float(holes), conf=float(y[:, 5].mean()))


def loss_h63_v3(x, y, tgt, g):
    """run4: v2 plus the motion supervised directly by the future flow (its own signal: the picture loss reaches the
    motion only through one-pixel footprints), Huber in model units, where the flow is plausible."""
    import torch, torch.nn.functional as F
    l, parts = loss_h63_v2(x, y, tgt, g)
    mt = g["mt"].to(x.device)
    ok = torch.isfinite(mt).all(1, keepdim=True) & (mt.abs().amax(1, keepdim=True) < 12)
    d = F.smooth_l1_loss(torch.where(ok, y[:, 3:5], torch.zeros_like(mt)), torch.where(ok, mt, torch.zeros_like(mt)), reduction="sum", beta=0.1)
    mloss = d / ok.sum().clamp_min(1) / 2
    parts["mot"] = float(mloss)
    return l + 0.2 * mloss, parts


def eval_h63(net, ds, n=None, bs=8, seed=0):
    """Mean squared error -> PSNR (8-bit, inside the mask) per age bucket, the model against fill = frame, the game's
    motion, conf 1 (= the raw velocity through the h63 path) and holding N. Fixed pairs (every one, or n spread)."""
    import torch
    dev = device_pick()
    if net is not None: net.to(dev).eval()
    idx = np.arange(len(ds)) if n is None or n >= len(ds) else np.linspace(0, len(ds) - 1, n).astype(int)
    edges = [0, 0.055, 0.100, 0.150, 0.2001]
    acc = {k: np.zeros((4, 2)) for k in ("model", "vel", "hold")}
    with torch.no_grad():
        for j in range(0, len(idx), bs):
            x, tgt, g = batch_of(ds, idx[j:j + bs])
            x, tgt = x.to(dev), tgt.to(dev)
            y0 = torch.cat([x[:, 0:3], x[:, 4:6], torch.ones_like(x[:, 0:1])], 1)
            outs = {"vel": composite_h63(x, y0, g)}
            if net is not None: outs["model"] = composite_h63(x, net(x), g)
            mask = outs["vel"][2]
            outs["hold"] = (x[:, 0:3], None, mask)
            for k, (pred, _, _) in outs.items():
                se = (((torch.round(pred.clamp(0, 1) * 255) - tgt * 255) ** 2) * mask).sum((1, 2, 3)).cpu().numpy()
                cnt = (mask.sum((1, 2, 3)) * 3).cpu().numpy()
                for b_, age in enumerate(g["age"].numpy()):
                    bi = int(np.searchsorted(edges, age, side="right") - 1); bi = min(max(bi, 0), 3)
                    acc[k][bi] += (se[b_], cnt[b_])
    def ps(a): return 10 * np.log10(255 ** 2 / (a[0] / a[1])) if a[1] else float("nan")
    out = {}
    for k, a in acc.items():
        if k == "model" and net is None: continue
        out[k] = dict(all=ps(a.sum(0)), b55_200=ps(a[1:].sum(0)), buckets=[ps(r) for r in a])
    return out


def layer_stats(net, ds, n=64):
    """What the layers hold on n pairs: conf mean / std / share under 0.25, |fill - frame| overall and in the h63
    composite's holes, |motion - the game's| (model px)."""
    import torch
    dev = device_pick(); net.to(dev).eval()
    idx = np.linspace(0, len(ds) - 1, min(n, len(ds))).astype(int)
    cs, fd, fh, md, hw = [], [], 0.0, [], 0.0
    with torch.no_grad():
        for j in range(0, len(idx), 8):
            x, tgt, g = batch_of(ds, idx[j:j + 8]); x = x.to(dev)
            y = net(x)
            cs.append(y[:, 5].flatten().cpu().numpy()); fd.append((y[:, 0:3] - x[:, 0:3]).abs().mean().item())
            md.append(((y[:, 3:5] - x[:, 4:6]) * MOTION_UNIT).norm(dim=1).mean().item())
            # (the fill against the frame where the warp shows it: holes of the composite, back in N's pixels ~ the same
            #  places around the moved edges; measured as |fill - frame| weighted by the far-motion edges' presence)
            _, hole, mask = composite_h63(x, y, g)
            d = (y[:, 0:3] - x[:, 0:3]).abs().mean(1, keepdim=True)
            # (holes are in N+k's pixels; the fill is read at the background's displacement - approximately the same
            #  neighbourhood: a 9x9 max of the hole weight brought back)
            import torch.nn.functional as F
            hn = F.max_pool2d(hole * mask, 9, 1, 4)
            fh += (d * hn).sum().item(); hw += hn.sum().item()
    c = np.concatenate(cs)
    return dict(conf_mean=float(c.mean()), conf_std=float(c.std()), conf_low=float((c < 0.25).mean()), fill_dev=float(np.mean(fd)),
                fill_dev_holes=fh / max(hw, 1.0), motion_dev_px=float(np.mean(md)))


def train2(a):
    import torch
    dev = device_pick()
    tr = WarpPairs(a.data, "train"); he = WarpPairs(a.data, "heldout")
    if a.loss == "v3": tr.mtarget_dir = a.mtarget
    print("pairs: train %d (bursts %d), held-out %d (bursts %d)" % (len(tr), len({tr.frames[p[1]][0]["burst"] for p in tr.pairs}),
          len(he), len({he.frames[p[1]][0]["burst"] for p in he.pairs})), flush=True)
    widths = tuple(int(v) for v in a.widths.split(","))
    net = make_net(widths, a.dec_convs)
    if a.init:
        ck = torch.load(a.init, map_location="cpu"); net.load_state_dict(ck["state"])
        torch.nn.init.zeros_(net.head.weight); torch.nn.init.zeros_(net.head.bias)    # (the collapsed heads reset: starts as the raw velocity)
    net.to(dev)
    from interp_health import require_training_features
    if not len(tr):
        raise ValueError("no training pairs")
    probe, _, _ = batch_of(tr, np.linspace(0, len(tr)-1, min(4,len(tr))).astype(int))
    print("decoder health:", require_training_features(net, [probe.to(dev)]), flush=True)
    base = eval_h63(None, he, n=a.eval_n)
    print("held-out (h63 composite), no model:", {k: round(v["all"], 2) for k, v in base.items()}, flush=True)
    opt = torch.optim.AdamW(net.parameters(), lr=a.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=a.lr, total_steps=a.steps, pct_start=0.1)
    rng = np.random.default_rng(1); t0 = time.time(); best = None
    for s in range(a.steps):
        net.train()
        x, tgt, g = batch_of(tr, rng.integers(0, len(tr), a.batch))
        x, tgt = x.to(dev), tgt.to(dev)
        y = net(x)
        loss, parts = {"v1": loss_h63, "v2": loss_h63_v2, "v3": loss_h63_v3}[a.loss](x, y, tgt, g)
        opt.zero_grad(); loss.backward(); torch.nn.utils.clip_grad_norm_(net.parameters(), 1.0); opt.step(); sched.step()
        if s % 200 == 0 or s == a.steps - 1:
            print("step %5d loss %.4f l1 %.4f holes %.4f conf %.3f (%.0f s)" % (s, float(loss), parts["l1"], parts["holes"], parts["conf"], time.time() - t0), flush=True)
        if (s + 1) % a.eval_every == 0 or s == a.steps - 1:
            ev = eval_h63(net, he, n=a.eval_n)
            print("  held-out: model %.2f vel %.2f (55-200 ms: model %.2f vel %.2f)" % (ev["model"]["all"], ev["vel"]["all"], ev["model"]["b55_200"], ev["vel"]["b55_200"]), flush=True)
            torch.save({"state": net.state_dict(), "widths": widths, "dec_convs": a.dec_convs, "step": s + 1, "heldout": {k: {kk: (float(vv) if not isinstance(vv, list) else [float(q) for q in vv]) for kk, vv in v.items()} for k, v in ev.items()}}, os.path.join(a.out, "vxinterp_step%d.pt" % (s + 1)))
            if best is None or ev["model"]["b55_200"] > best[0]:
                best = (ev["model"]["b55_200"], s + 1)
                torch.save({"state": net.state_dict(), "widths": widths, "dec_convs": a.dec_convs, "step": s + 1, "heldout": {k: {kk: (float(vv) if not isinstance(vv, list) else [float(q) for q in vv]) for kk, vv in v.items()} for k, v in ev.items()}}, os.path.join(a.out, "vxinterp.pt"))
    print("best held-out 55-200 ms: %.2f dB at step %d" % best, flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["smoke", "train", "train2", "eval2", "export", "info", "params"])
    ap.add_argument("--init", help="train2: start from this checkpoint's body (its heads reset)")
    ap.add_argument("--mtarget", help="train2 --loss v3: the per-pair flow layers (tools/interp_oracle.py flow --split train)")
    ap.add_argument("--loss", default="v2", choices=["v1", "v2", "v3"], help="train2: v1 run2's (L1 + edge + hole-area L1 + conf pull), v2 run3's")
    ap.add_argument("--eval-every", type=int, default=1000); ap.add_argument("--eval-n", type=int, default=600)
    ap.add_argument("--data"); ap.add_argument("--out", default="build/interp"); ap.add_argument("--ckpt"); ap.add_argument("--resume")
    ap.add_argument("--w", type=int, default=DEFAULT_W); ap.add_argument("--h", type=int, default=DEFAULT_H)
    ap.add_argument("--widths", default=",".join(map(str, DEFAULT_WIDTHS))); ap.add_argument("--dec-convs", type=int, default=1)
    ap.add_argument("--steps", type=int, default=0); ap.add_argument("--batch", type=int, default=8); ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--crop", default="256x160", help="training crop WxH (the net is fully convolutional)")
    a = ap.parse_args()
    widths = tuple(int(v) for v in a.widths.split(","))
    if a.cmd == "info": return info(a.data)
    if a.cmd == "train2":
        os.makedirs(a.out, exist_ok=True); return train2(a)
    if a.cmd == "eval2":   # (a checkpoint on the held-out bursts through the h63 composite, and its layers' statistics)
        import torch
        ck = torch.load(a.ckpt, map_location="cpu", weights_only=False); net = make_net(tuple(ck["widths"]), ck["dec_convs"]); net.load_state_dict(ck["state"])
        he = WarpPairs(a.data, "heldout"); ev = eval_h63(net, he, n=a.eval_n)
        for k, v in ev.items(): print("%-6s all %.2f  55-200 %.2f  buckets %s" % (k, v["all"], v["b55_200"], " ".join("%.2f" % b for b in v["buckets"])))
        print(layer_stats(net, he)); return 0
    import torch
    net = make_net(widths, a.dec_convs)
    if a.cmd == "params":
        print("widths %s dec_convs %d: %d parameters (%.1f MB fp16)" % (widths, a.dec_convs, count_params(net), count_params(net) * 2 / 1e6)); return
    if a.resume or (a.cmd == "export" and a.ckpt):
        ck = torch.load(a.resume or a.ckpt, map_location="cpu", weights_only=False)
        net = make_net(tuple(ck["widths"]), ck["dec_convs"]); net.load_state_dict(ck["state"])
    cw, ch = (int(v) for v in a.crop.split("x"))
    os.makedirs(a.out, exist_ok=True)
    if a.cmd == "smoke":
        dev = device_pick()
        def gen():
            while True: yield synth_batch(a.batch, cw, ch, dev)
        g = gen()
        ev = [synth_batch(a.batch, cw, ch, dev, seed=1000 + i) for i in range(6)]
        base = eval_loss(None, ev)
        print("params %d; held-out synthetic, no model: loss %.4f, picture L1 %.4f" % (count_params(net), *base))
        train(net, g, a.steps or 300, a.lr, ckpt=os.path.join(a.out, "vxinterp_smoke.pt"))
        end = eval_loss(net, ev)
        print("held-out synthetic, trained: loss %.4f, picture L1 %.4f -> %s" % (*end, "better" if end[0] < base[0] else "NOT better"))
        m, pkg = export(net, a.w, a.h, a.out, "vxinterp_smoke_%dx%d" % (a.w, a.h))
        # (Core ML on this Mac against PyTorch on the same input: the export is the same function)
        x, _, _ = synth_batch(1, a.w, a.h, torch.device("cpu"))
        with torch.no_grad(): ref = net.cpu().eval()(x).numpy()
        got = m.predict({"x": x.numpy().astype(np.float16)})["y"].astype(np.float32)
        err = np.abs(got - ref)
        print("Core ML vs PyTorch: mean |diff| %.4f, max %.4f (fp16)" % (err.mean(), err.max()))
        return 0 if end[0] < base[0] else 1
    if a.cmd == "train":
        if not a.data: sys.exit("--data DIR (the pulled Documents/vxinterp_capture)")
        ds = CaptureDataset(a.data)
        print("pairs:", len(ds))
        if not len(ds): sys.exit("no usable pairs (frames with depth and velocity, consecutive in a burst)")
        dev = device_pick()
        def gen():
            rng = np.random.default_rng()
            while True:
                xs, ys, ts = [], [], []
                for i in rng.integers(0, len(ds), a.batch):
                    x, y, t = ds[int(i)]
                    ox, oy = rng.integers(0, a.w - cw + 1), rng.integers(0, a.h - ch + 1)
                    xs.append(x[:, oy:oy + ch, ox:ox + cw]); ys.append(y[:, oy:oy + ch, ox:ox + cw]); ts.append(t)
                yield torch.from_numpy(np.stack(xs)), torch.from_numpy(np.stack(ys)), torch.from_numpy(np.array(ts, np.float32))
        g = gen()
        ev = [next(g) for _ in range(8)]
        print("held-out pairs, no model: loss %.4f, picture L1 %.4f" % eval_loss(None, ev))
        train(net, g, a.steps or 20000, a.lr, log_every=200, ckpt=os.path.join(a.out, "vxinterp.pt"))
        print("held-out pairs, trained: loss %.4f, picture L1 %.4f" % eval_loss(net, ev))
        export(net, a.w, a.h, a.out)
    if a.cmd == "export":
        export(net, a.w, a.h, a.out)


if __name__ == "__main__":
    sys.exit(main())
