#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline weighted-skin diagnostics using the owner's unpacked mesh and pose records.

Writes numeric summaries only. This is not a visibility, collision or headset
playtest. Matched draw counts and an explicitly selected bone list are required;
unsupported vertex layouts are refused rather than guessed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

import numpy as np

from weapon_asset_profile import CR2W, properties, unpacked_buffer


def layout_elements(reader, raw):
    count = struct.unpack_from("<I", raw)[0]
    if count > 64:
        raise ValueError("too many vertex elements")
    result, p = [], 4
    for _ in range(count):
        p += 1
        fields = {}
        while True:
            name = struct.unpack_from("<H", raw, p)[0]
            if not name:
                p += 2
                break
            name, kind, size = struct.unpack_from("<HHI", raw, p)
            if size < 4 or p + 4 + size > len(raw):
                raise ValueError("invalid vertex element size")
            value = raw[p + 8:p + 4 + size]
            key = reader.names[name]
            fields[key] = (reader.names[struct.unpack("<H", value)[0]]
                           if key in ("type", "usage", "streamType")
                           else int.from_bytes(value, "little"))
            p += 4 + size
        result.append(fields)
    return result


def read_mesh(path):
    data = path.read_bytes()
    reader = CR2W(data)
    names = next(properties(reader, "CMesh", {"boneNames"}))["boneNames"]
    resource = next(properties(reader, "rendRenderMeshBlob", {"header", "renderBuffer"}))
    header = resource["header"]
    buffer = unpacked_buffer(data, struct.unpack("<I", resource["renderBuffer"])[0] & 0x7fffffff)
    scale = np.array([header["quantizationScale"][k] for k in "XYZ"])
    offset = np.array([header["quantizationOffset"][k] for k in "XYZ"])
    chunks = {}
    for chunk in header["renderChunkInfos"]:
        stream = chunk["chunkVertices"]
        layout = stream["vertexLayout"]
        fields, position = {}, 0
        sizes = {"PT_Short4N": 8, "PT_UByte4": 4, "PT_UByte4N": 4, "PT_Float16_4": 8}
        for element in layout_elements(reader, layout["elements"]):
            if element.get("streamIndex", 0) != 0 or element["type"] == "PT_Invalid":
                continue
            kind = element["type"]
            if kind not in sizes:
                raise ValueError("unsupported skin stream type: " + kind)
            fields[(element["usage"], element.get("usageIndex", 0))] = (kind, position)
            position += sizes[kind]
        raw_strides = layout["slotStrides"]
        stride = raw_strides[4]
        if position != stride or fields[("PS_Position", 0)][0] != "PT_Short4N":
            raise ValueError("unsupported position/stride")
        start = struct.unpack_from("<I", stream["byteOffsets"], 4)[0]
        n = chunk["numVertices"]
        if start + n * stride > len(buffer):
            raise ValueError("vertex stream exceeds buffer")
        def values(usage, usage_index, dtype, width):
            field_kind, at = fields[(usage, usage_index)]
            required = {"PS_Position": "PT_Short4N", "PS_SkinIndices": "PT_UByte4", "PS_SkinWeights": "PT_UByte4N"}
            if field_kind != required[usage]:
                raise ValueError("unsupported attribute encoding")
            return np.ndarray((n, width), dtype=dtype, buffer=buffer, offset=start + at,
                              strides=(stride, np.dtype(dtype).itemsize)).copy()
        vertices = np.maximum(-1, values("PS_Position", 0, "<i2", 4)[:, :3] / 32767.) * scale + offset
        indices = np.concatenate([values("PS_SkinIndices", i, "u1", 4) for i in (0, 1)], axis=1)
        weights = np.concatenate([values("PS_SkinWeights", i, "u1", 4) for i in (0, 1)], axis=1) / 255.
        if indices.max() >= len(names) or np.any(weights.sum(axis=1) < .9):
            raise ValueError("invalid skin indices/weights")
        count = chunk["numIndices"]
        at = header["indexBufferOffset"] + chunk.get("chunkIndices", {}).get("teOffset", 0)
        triangles = np.frombuffer(buffer, dtype="<u2", count=count, offset=at).reshape(-1, 3)
        if triangles.max() >= n or count in chunks:
            raise ValueError("invalid or ambiguous draw count")
        edges = np.concatenate([triangles[:, [0, 1]], triangles[:, [1, 2]], triangles[:, [2, 0]]])
        chunks[count] = vertices, indices, weights, edges
    return names, chunks


def skin(vertices, indices, weights, palette):
    palette = np.asarray(palette, dtype=float).reshape(-1, 3, 4)
    if not np.isfinite(palette).all():
        raise ValueError("non-finite palette")
    points = np.concatenate([vertices, np.ones((len(vertices), 1))], axis=1)
    return (np.einsum("nkij,nj->nki", palette[indices], points) * weights[:, :, None]).sum(axis=1)


def measure(native, posed, edges):
    before = np.linalg.norm(native[edges[:, 0]] - native[edges[:, 1]], axis=1)
    after = np.linalg.norm(posed[edges[:, 0]] - posed[edges[:, 1]], axis=1)
    return {"native_max_edge_m": float(before.max()), "posed_max_edge_m": float(after.max()),
            "posed_edge_p99_m": float(np.quantile(after, .99)),
            "max_edge_growth_m": float((after - before).max()),
            "posed_extent_m": np.ptp(posed, axis=0).tolist()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mesh", required=True, type=Path)
    parser.add_argument("--list", required=True, type=int)
    parser.add_argument("--replays", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--max-edge", type=float)
    parser.add_argument("--max-growth", type=float)
    args = parser.parse_args()
    if args.output.resolve() == args.mesh.resolve() or args.output.resolve().parent == args.replays.resolve():
        parser.error("output must be separate from inputs")
    names, chunks = read_mesh(args.mesh)
    rows = []
    for file in sorted(args.replays.glob("*.json")):
        record = json.loads(file.read_text())
        for p in record["palettes"]:
            if p["list"] != args.list or p["indices"] not in chunks:
                continue
            if p["bones"] != len(names):
                raise ValueError("mesh and palette bone counts disagree")
            vertices, indices, weights, edges = chunks[p["indices"]]
            native = skin(vertices, indices, weights, p["original"])
            posed = skin(vertices, indices, weights, p["posed"])
            rows.append({"file": file.name, "indices": p["indices"], **measure(native, posed, edges)})
    if not rows:
        raise ValueError("no matching skin consumers")
    failed = [r for r in rows if (args.max_edge is not None and r["posed_max_edge_m"] > args.max_edge) or
              (args.max_growth is not None and r["max_edge_growth_m"] > args.max_growth)]
    report = {"schema": 1, "mesh_sha256": hashlib.sha256(args.mesh.read_bytes()).hexdigest(),
              "bone_list": args.list, "consumers": rows, "failed": len(failed)}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"consumers": len(rows), "failed": len(failed),
                      "max_edge_m": max(r["posed_max_edge_m"] for r in rows),
                      "max_growth_m": max(r["max_edge_growth_m"] for r in rows)}))
    return bool(failed)


if __name__ == "__main__":
    raise SystemExit(main())
