#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Local rigid-geometry teacher pilot, not a Cyberpunk material/scene renderer.

Uses already unpacked, owned CR2W meshes read-only. All derived output must be
under ignored VXMac/build. Compile interp_teacher_raster.c ahead of time.
Camera is fixed within each clip: future head motion is never a model input.
"""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import struct

import numpy as np

from interp_guide import CONTRACT
from weapon_asset_profile import CR2W, properties, unpacked_buffer

ROOT = Path(__file__).resolve().parents[1]
MOTION_UNIT = 16.0
TIME_UNIT = .1
NEAR, FAR = .1, 64.0
TEACHER_CONTRACT = "vxpro-rigid-teacher-v1"


def derived_directory(path):
    path = path.resolve()
    path.relative_to((ROOT / "build").resolve())
    path.mkdir(parents=True, exist_ok=False)
    return path


def mesh_triangles(path):
    """Refuse unknown vertex layouts instead of guessing geometry."""
    data = path.read_bytes()
    reader = CR2W(data)
    resource = next(properties(reader, "rendRenderMeshBlob", {"header", "renderBuffer"}))
    header = resource["header"]
    number = struct.unpack("<I", resource["renderBuffer"])[0] & 0x7fffffff
    buffer = unpacked_buffer(data, number)
    scale = np.array([header["quantizationScale"][k] for k in "XYZ"])
    offset = np.array([header["quantizationOffset"][k] for k in "XYZ"])
    triangles = []
    for chunk in header["renderChunkInfos"]:
        if chunk.get("lodMask") != 1:
            continue
        vertex = chunk["chunkVertices"]
        layout = vertex["vertexLayout"]
        raw = layout["elements"]
        fields, pos = {}, 5
        while pos + 8 <= len(raw):
            name, kind, size = struct.unpack_from("<HHI", raw, pos)
            if not name or reader.names[name] in fields:
                break
            if size < 4 or pos + 4 + size > len(raw):
                raise ValueError("bad vertex element")
            fields[reader.names[name]] = raw[pos+8:pos+4+size]
            pos += 4 + size
        typ = reader.names[struct.unpack("<H", fields["type"])[0]]
        usage = reader.names[struct.unpack("<H", fields["usage"])[0]]
        if (typ, usage) != ("PT_Short4N", "PS_Position"):
            raise ValueError(f"unsupported position layout: {typ}/{usage}")
        stride = layout["slotStrides"][4]
        start = struct.unpack_from("<I", vertex["byteOffsets"], 4)[0]
        count = chunk["numVertices"]
        if stride < 8 or start + stride*count > header["vertexBufferSize"]:
            raise ValueError("vertex range exceeds buffer")
        packed = np.ndarray((count, 4), dtype="<i2", buffer=buffer, offset=start, strides=(stride, 2))
        points = np.maximum(-1, packed[:, :3].astype(np.float32)/32767)*scale + offset
        index_offset = chunk.get("chunkIndices", {}).get("teOffset", 0)
        index_count = chunk["numIndices"]
        if index_count % 3 or index_offset + index_count*2 > header["indexBufferSize"]:
            raise ValueError("invalid triangle index range")
        indices = np.frombuffer(buffer, dtype="<u2", count=index_count,
                                offset=header["indexBufferOffset"]+index_offset)
        if not len(indices) or indices.max() >= count:
            raise ValueError("invalid triangle indices")
        triangles.append(points[indices.reshape(-1, 3)])
    if not triangles:
        raise ValueError("no supported LOD1 triangles")
    faces = np.concatenate(triangles).astype(np.float32)
    low, high = faces.min(axis=(0, 1)), faces.max(axis=(0, 1))
    extent = float((high-low).max())
    if not np.isfinite(faces).all() or extent < 1e-5:
        raise ValueError("invalid mesh bounds")
    # Shapes are scene props, not a new in-game weapon or an articulated rig.
    faces = (faces-(low+high)*.5)*(1.5/extent)
    # Native weapon Y is its long axis. Use a proper rotation to show that
    # axis across the image, rather than train mostly on edge-on silhouettes.
    faces = faces[..., [1, 2, 0]] * np.array([1, -1, -1], np.float32)
    return faces, {"asset": path.stem, "source_sha256": hashlib.sha256(data).hexdigest(),
                   "triangles": len(faces), "materials": "original procedural checker; game materials not read",
                   "rig": "rigid bind-space geometry; no bone animation",
                   "normalization": "centred, longest extent 1.5; proper native Y to camera X rotation"}


def quad(vertices):
    return np.asarray(vertices, np.float32)[[[0, 1, 2], [0, 2, 3]]]


class Scene:
    def __init__(self, mesh, seed, trajectory):
        rng = np.random.default_rng(seed)
        self.faces = [quad([[-8, 1.2, 1], [8, 1.2, 1], [8, 1.2, 12], [-8, 1.2, 12]]),
                      quad([[-9, -8, 0], [9, -8, 0], [9, 8, 0], [-9, 8, 0]]), mesh,
                      quad([[-.25, -.8, 0], [.25, -.8, 0], [.25, .8, 0], [-.25, .8, 0]])]
        self.colours = rng.uniform(.25, .9, (4, 3)).astype(np.float32)
        self.phase = rng.uniform(-2, 2, 3)
        self.speed = rng.uniform(.3, .7)
        self.angle = rng.uniform(-.7, .7)
        self.trajectory = trajectory
        self.light = np.asarray([[.2, -.5, -.84], [-.7, -.4, -.59], [.7, .1, -.7]][seed % 3], np.float32)
        self.light /= np.linalg.norm(self.light)

    def transforms(self, time):
        matrices = np.repeat(np.eye(4, dtype=np.float32)[None], 4, axis=0)
        matrices[1, 2, 3] = 7
        if self.trajectory == "linear":
            x, rotation = self.speed*(time-.4), self.angle
        else:
            x = .55*np.sin(self.speed*3*time+self.phase[0])
            rotation = self.angle+.35*np.sin(1.8*time+self.phase[1])
        c, s = np.cos(rotation), np.sin(rotation)
        matrices[2, :3, :3] = [[c, 0, s], [0, 1, 0], [-s, 0, c]]
        matrices[2, :3, 3] = [x, -.1, 3.7+.2*np.sin(time+self.phase[2])]
        matrices[3, :3, 3] = [.8*np.sin(time*1.5+self.phase[1]), .05, 2.8]
        return matrices


class Raster:
    def __init__(self, library, width, height):
        self.w, self.h = width, height
        self.focal = width*.82
        self.library = ctypes.CDLL(str(library.resolve()))
        fptr = np.ctypeslib.ndpointer(dtype=np.float32, flags="C_CONTIGUOUS")
        iptr = np.ctypeslib.ndpointer(dtype=np.int32, flags="C_CONTIGUOUS")
        self.library.teacher_render.argtypes = [ctypes.c_int]*3 + [ctypes.c_float] + [fptr, fptr, iptr, fptr, fptr, fptr, fptr, fptr, iptr]
        self.library.teacher_render.restype = None

    def project(self, scene, frame, time):
        out = np.zeros_like(frame["points"])
        for obj, transform in enumerate(scene.transforms(time)):
            mask = frame["id"] == obj
            out[mask] = frame["points"][mask] @ transform[:3, :3].T + transform[:3, 3]
        z = np.maximum(out[:, :, 2], NEAR)
        uv = self.focal*out[:, :, :2]/z[:, :, None] + [self.w*.5, self.h*.5]
        return uv.astype(np.float32), out[:, :, 2]

    def render(self, scene, time):
        camera, ids, colours = [], [], []
        for obj, (faces, transform) in enumerate(zip(scene.faces, scene.transforms(time))):
            camera.append(faces @ transform[:3, :3].T + transform[:3, 3])
            ids.extend([obj]*len(faces))
            colours.extend([scene.colours[obj]]*len(faces))
        shape = (self.h, self.w)
        frame = {"rgb": np.zeros((*shape, 3), np.float32), "depth": np.zeros(shape, np.float32),
                 "points": np.zeros((*shape, 3), np.float32), "id": np.zeros(shape, np.int32)}
        args = [np.concatenate(camera).astype(np.float32), np.concatenate(scene.faces).astype(np.float32),
                np.asarray(ids, np.int32), np.asarray(colours, np.float32), scene.light,
                frame["rgb"], frame["depth"], frame["points"], frame["id"]]
        self.library.teacher_render(self.w, self.h, len(ids), self.focal, *args)
        return frame


def sample(array, uv):
    h, w = array.shape[:2]
    # Pixel centres are (integer + .5), and nearest sampling is floor(uv).
    valid = np.isfinite(uv).all(axis=-1) & (uv[..., 0] >= 0) & (uv[..., 0] < w) & (uv[..., 1] >= 0) & (uv[..., 1] < h)
    xy = np.floor(uv).astype(np.int32)
    return array[np.clip(xy[..., 1], 0, h-1), np.clip(xy[..., 0], 0, w-1)], valid


def visible(frame, uv, depth, ids):
    other_id, inside = sample(frame["id"], uv)
    other_depth, _ = sample(frame["depth"], uv)
    return inside & (ids >= 0) & (other_id == ids) & (np.abs(other_depth-depth) < .015*np.maximum(depth, 1))


def grid(width, height):
    y, x = np.mgrid[:height, :width]
    return np.stack([x+.5, y+.5], -1).astype(np.float32)


def encoded_depth(depth):
    return np.clip(np.log2(np.maximum(depth, NEAR)/NEAR)/np.log2(FAR/NEAR), 0, 1)


def teacher_pair(raster, scene, time, interval, horizon):
    previous = raster.render(scene, time-interval)
    current = raster.render(scene, time)
    future = raster.render(scene, time+horizon)
    pixel = grid(raster.w, raster.h)
    past_uv, past_depth = raster.project(scene, current, time-interval)
    history_valid = visible(previous, past_uv, past_depth, current["id"])
    old_uv, _ = raster.project(scene, previous, time-2*interval)
    history_motion = pixel-old_uv
    warped_motion, _ = sample(history_motion, past_uv)
    history_rgb, _ = sample(previous["rgb"], past_uv)
    history_depth, _ = sample(previous["depth"], past_uv)
    motion = pixel-past_uv
    future_uv, future_depth = raster.project(scene, current, time+horizon)
    future_visible = visible(future, future_uv, future_depth, current["id"])
    flow = future_uv-pixel
    tau = horizon/interval
    residual = flow-motion*tau
    bounded = (np.abs(residual).max(axis=-1) <= 2)
    x = np.concatenate([current["rgb"], history_rgb, encoded_depth(current["depth"])[..., None],
                        encoded_depth(history_depth)[..., None], motion/MOTION_UNIT, warped_motion/MOTION_UNIT,
                        history_valid[..., None], np.full((*pixel.shape[:2], 1), interval/TIME_UNIT),
                        np.full((*pixel.shape[:2], 1), horizon/TIME_UNIT), np.zeros((*pixel.shape[:2], 1))], axis=-1)
    same_uv, same_depth = raster.project(scene, current, time)
    surface = current["id"] >= 0
    roundtrip = float(np.abs(same_uv[surface]-pixel[surface]).max())
    depth_error = float(np.abs(same_depth[surface]-current["depth"][surface]).max())
    if roundtrip > .002 or depth_error > .002 or not np.isfinite(x).all():
        raise ValueError(f"inconsistent surface correspondence: {roundtrip}/{depth_error}")
    return {"x": x.transpose(2, 0, 1).astype(np.float16), "flow": flow.transpose(2, 0, 1).astype(np.float16),
            "residual": residual.transpose(2, 0, 1).astype(np.float16),
            "visible": future_visible, "learn_valid": history_valid & future_visible & bounded,
            "confidence": (future_visible & bounded).astype(np.float16),
            "future_rgb": future["rgb"].transpose(2, 0, 1).astype(np.float16),
            "current_depth": current["depth"].astype(np.float16), "future_depth": future["depth"].astype(np.float16),
            "current_id": current["id"].astype(np.int16), "future_id": future["id"].astype(np.int16),
            "tau": np.float32(tau), "times": np.asarray([time-interval, time, time+horizon], np.float64)}, {
                "roundtrip_pixels": roundtrip, "roundtrip_depth": depth_error,
                "history_valid_fraction": float(history_valid.mean()), "visible_fraction": float(future_visible.mean()),
                "learn_valid_fraction": float((history_valid & future_visible & bounded).mean())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("meshes", nargs="+", type=Path)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--clips-per-asset", type=int, default=8)
    parser.add_argument("--anchors", type=int, default=4)
    parser.add_argument("--width", type=int, default=256)
    parser.add_argument("--height", type=int, default=144)
    parser.add_argument("--seed", type=int, default=20261106)
    parser.add_argument("--horizons", type=int, nargs="+", choices=(1, 2, 3, 4), default=(1, 4))
    parser.add_argument("--heldout-only", action="store_true")
    parser.add_argument("--exclude-manifest", type=Path)
    parser.add_argument("--candidate", type=Path)
    args = parser.parse_args()
    if (not args.heldout_only and len(args.meshes) < 3) or min(args.clips_per_asset, args.anchors) < 1:
        parser.error("need at least three unique assets and positive clip/anchor counts")
    if min(args.width, args.height) < 8 or len(set(args.horizons)) != len(args.horizons):
        parser.error("size must be at least 8; horizons must be unique")
    excluded, frozen_candidate = set(), None
    if args.heldout_only:
        if not args.exclude_manifest or not args.candidate:
            parser.error("held-out generation requires the previous manifest and frozen checkpoint")
        excluded = {a["source_sha256"] for a in json.loads(args.exclude_manifest.read_text())["assets"]}
        frozen_candidate = hashlib.sha256(args.candidate.read_bytes()).hexdigest()
    out = derived_directory(args.out)
    raster = Raster(args.library, args.width, args.height)
    entries, assets, checks = [], [], []
    hashes = set()
    for asset_index, path in enumerate(sorted(args.meshes)):
        mesh, info = mesh_triangles(path)
        if info["source_sha256"] in excluded:
            raise ValueError("held-out asset already occurred in the development corpus")
        if info["source_sha256"] in hashes:
            raise ValueError("duplicate asset cannot form a held-out split")
        hashes.add(info["source_sha256"])
        split = "test" if args.heldout_only or asset_index == len(args.meshes)-1 else "validation" if asset_index == len(args.meshes)-2 else "train"
        info["split"] = split
        assets.append(info)
        directory = out / split
        directory.mkdir(exist_ok=True)
        for clip in range(args.clips_per_asset):
            seed = args.seed + asset_index*10000 + clip
            scene = Scene(mesh, seed, "linear" if clip % 3 == 0 else "accelerating")
            interval = float(np.random.default_rng(seed).uniform(.05, .08))
            for anchor in range(args.anchors):
                time = (anchor+2)*interval
                for horizon_index in args.horizons:
                    pair, audit = teacher_pair(raster, scene, time, interval, horizon_index/70)
                    name = f"a{asset_index:02}-c{clip:03}-t{anchor:03}-h{horizon_index}.npz"
                    file = directory / name
                    np.savez_compressed(file, **pair)
                    entries.append({"file": f"{split}/{name}", "split": split, "asset_sha256": info["source_sha256"],
                                    "clip": seed, "trajectory": scene.trajectory,
                                    "sha256": hashlib.sha256(file.read_bytes()).hexdigest()})
                    checks.append(audit)
            print(f"asset {asset_index+1}/{len(args.meshes)} clip {clip+1}/{args.clips_per_asset}", flush=True)
    manifest = {"teacher_contract": TEACHER_CONTRACT, "model_contract": CONTRACT,
                "seed": args.seed, "size": [args.width, args.height], "motion_unit_pixels": MOTION_UNIT,
                "time_unit_seconds": TIME_UNIT, "near": NEAR, "far": FAR,
                "future_camera": "fixed current reference; no future input",
                "heldout_only": args.heldout_only, "frozen_candidate_sha256": frozen_candidate,
                "scope": "rigid geometry, procedural materials, fixed camera; not game-image quality evidence",
                "assets": assets, "samples": entries,
                "audit": {k: {"min": min(c[k] for c in checks), "max": max(c[k] for c in checks)} for k in checks[0]},
                "generator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "raster_sha256": hashlib.sha256(args.library.read_bytes()).hexdigest()}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
    print(json.dumps({"out": str(out), "samples": len(entries), "audit": manifest["audit"]}, indent=2))


if __name__ == "__main__":
    main()
