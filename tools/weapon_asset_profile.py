#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Inspect the player's locally unpacked meshes without exporting geometry.

Input is an existing CR2W object followed by its unpacked external buffers in
buffer-table order. Original archives and game files are never changed. The
output contains exact index fingerprints and named joint positions; a vertex
count, weapon class or bone count alone is not an identification.
"""
import argparse
import json
from pathlib import Path
import struct

from cr2w import CR2W


def unpacked_buffer(data, number):
    if len(data) < 160 or data[:4] != b"CR2W":
        raise ValueError("not a CR2W object")
    end = struct.unpack_from("<I", data, 24)[0]
    table, count, _ = struct.unpack_from("<III", data, 100)
    if not 1 <= number <= count or count > 4096 or table + count * 24 > end or end > len(data):
        raise ValueError("invalid external buffer table")
    sizes = [struct.unpack_from("<I", data, table + i * 24 + 16)[0] for i in range(count)]
    if end + sum(sizes) != len(data):
        raise ValueError("full unpacked external buffers are required; metadata alone is insufficient")
    start = end + sum(sizes[:number - 1])
    return memoryview(data)[start:start + sizes[number - 1]]


def index_fingerprint(buffer, start, count, vertices):
    if count <= 0 or count > 2_000_000 or start < 0 or start % 2 or not 0 < vertices <= 65536:
        raise ValueError("unsupported index range or vertex count")
    end = start + 2 * count
    if end > len(buffer):
        raise ValueError("index range exceeds the render buffer")
    raw = buffer[start:end]
    if any(index[0] >= vertices for index in struct.iter_unpack("<H", raw)):
        raise ValueError("indices do not validate as the expected unsigned 16-bit format")
    value = 14695981039346656037
    for byte in raw:
        value = ((value ^ byte) * 1099511628211) & ((1 << 64) - 1)
    return f"{value:016x}"


def properties(reader, class_name, wanted):
    for name, start, size in reader.exports:
        if name == class_name:
            yield {key: reader.value(kind, a, b)
                   for key, kind, a, b in reader.props(start, start + size) if key in wanted}


def inspect(path):
    data = path.read_bytes()
    reader = CR2W(data)
    meshes = list(properties(reader, "CMesh", {"boneNames"}))
    if len(meshes) != 1:
        raise ValueError("expected one mesh")
    names = meshes[0].get("boneNames", [])
    result = {"asset": path.stem, "bones": names, "draws": []}
    for resource in properties(reader, "rendRenderMeshBlob", {"header", "renderBuffer"}):
        header = resource["header"]
        number = struct.unpack("<I", resource["renderBuffer"])[0] & 0x7fffffff
        buffer = unpacked_buffer(data, number)
        positions = header.get("bonePositions", [])
        if len(positions) != len(names):
            raise ValueError("named bones and bind positions have different lengths")
        result["joints"] = [{"name": name, "bone": i,
                             "at": [position[k] for k in "XYZ"]}
                            for i, (name, position) in enumerate(zip(names, positions))]
        index_start = header["indexBufferOffset"]
        index_size = header["indexBufferSize"]
        if index_start + index_size > len(buffer):
            raise ValueError("index buffer exceeds the render resource")
        for chunk in header["renderChunkInfos"]:
            offset = chunk.get("chunkIndices", {}).get("teOffset", 0)
            count = chunk["numIndices"]
            if offset + count * 2 > index_size:
                raise ValueError("chunk exceeds the declared index buffer")
            fingerprint = index_fingerprint(buffer, index_start + offset, count, chunk["numVertices"])
            result["draws"].append({"count": count, "fnv64": fingerprint,
                                    "lod": chunk.get("lodMask", 0)})
    if not result["draws"]:
        raise ValueError("mesh has no render draws")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("meshes", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.resolve() in [path.resolve() for path in args.meshes]:
        parser.error("output must not replace an input asset")
    results, refused = [], []
    for path in args.meshes:
        try:
            results.append(inspect(path))
        except (KeyError, IndexError, ValueError, struct.error) as error:
            refused.append({"path": str(path), "reason": str(error)})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"profiles": results, "refused": refused}, indent=2) + "\n")
    print(f"{len(results)} inspected, {len(refused)} refused; no geometry exported")


if __name__ == "__main__":
    main()
