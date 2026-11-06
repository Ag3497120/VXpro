#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build numeric, private draw identities from the player's unpacked meshes.

No mesh geometry is written. The generated file belongs in ignored build output,
not in a source distribution. The renderer has an empty-catalog fallback.
"""
import argparse
from pathlib import Path
import re
import struct

from weapon_asset_profile import CR2W, inspect, properties, unpacked_buffer


def foregrip(reader, header, buffer_number, trigger):
    """A point on the lower surface of the receiver, forward of its trigger."""
    scale = header.get("quantizationScale", {})
    offset = header.get("quantizationOffset", {})
    forward_end = offset.get("Y", 0) + scale.get("Y", 0)
    y = trigger[1] + min(.16, max(.04, .55 * (forward_end - trigger[1])))
    candidates = []
    data = unpacked_buffer(reader.d, buffer_number)
    for chunk in header.get("renderChunkInfos", []):
        if chunk.get("lodMask", 0) != 1:
            continue
        vertex = chunk["chunkVertices"]
        layout = vertex["vertexLayout"]
        raw = layout["elements"]
        # Check the first attribute instead of interpreting arbitrary packed
        # vertex formats as positions. Other formats keep named contacts only.
        p = 5
        fields = {}
        while p + 8 <= len(raw):
            name, kind, size = struct.unpack_from("<HHI", raw, p)
            if not name:
                break
            fields[reader.names[name]] = raw[p + 8:p + 4 + size]
            p += 4 + size
        if not fields.get("type") or not fields.get("usage"):
            continue
        if reader.names[struct.unpack("<H", fields["type"])[0]] != "PT_Short4N" or \
                reader.names[struct.unpack("<H", fields["usage"])[0]] != "PS_Position":
            continue
        strides = layout["slotStrides"]
        stride = strides[4]
        start = struct.unpack_from("<I", vertex["byteOffsets"], 4)[0]
        count = chunk["numVertices"]
        if stride < 8 or start + stride * count > header["vertexBufferSize"]:
            continue
        for index in range(count):
            packed = struct.unpack_from("<4h", data, start + stride * index)
            point = [max(-1, packed[k] / 32767) * scale[axis] + offset[axis]
                     for k, axis in enumerate("XYZ")]
            if abs(point[1] - y) < .018:
                candidates.append(point)
    if len(candidates) < 4:
        return None
    # A lower quantile avoids isolated screws below the grasping surface.
    candidates.sort(key=lambda p: p[2])
    lower = candidates[len(candidates) // 10][2]
    return [0, y, lower]


def number(value):
    return f"{float(value):.8g}f" if float(value) != int(value) else f"{int(value)}.0f"


def vector(values):
    return "{" + ",".join(number(v) for v in values) + "}"


def build(paths, output):
    entries = {}
    ambiguous = set()
    for asset_id, path in enumerate(sorted(paths), 1):
        try:
            mesh = inspect(path)
            reader = CR2W(path.read_bytes())
            resource = next(properties(reader, "rendRenderMeshBlob", {"header", "renderBuffer"}))
            header = resource["header"]
        except (KeyError, IndexError, ValueError, struct.error):
            continue
        names = mesh["bones"]
        if not names or len(names) > 64:
            continue
        lower = [n.lower() for n in names]
        def bone(*choices):
            return next((lower.index(n) for n in choices if n in lower), -1)
        root = bone("barrel", "base", "body", "root")
        root = root if root >= 0 else 0
        trigger = bone("weapon_trigger", "trigger")
        slide = bone("slide", "slider", "cocking", "cocking_handle", "cocking_device")
        cylinder = bone("cylinder")
        hinge = bone("magazine_open")
        support = bone("left_grip", "front_left_handle", "foreend", "handle")
        tags = " ".join(reader.names).lower()
        pistol = "w_handgun" in tags
        revolver = "w_revolver" in tags
        ammo = [bool(re.fullmatch(r"(?:mag(?:azine)?(?:_std[r]?)?|bullet|shell|ammo)(?:_\d+)?", n)) or
                n == "reload_magazine_bullets" for n in lower]
        # A Nova's named magazine is its cylinder, not a disposable box.
        if revolver and "darra_nova" in tags and all(ammo):
            ammo = [False] * len(names)
            cylinder = root
        mask = sum(1 << i for i, flag in enumerate(ammo) if flag)
        whole_ammo = all(ammo)
        kind = (1 if trigger >= 0 else 0) | (2 if whole_ammo else 0) | (4 if revolver else 0) | (8 if pistol else 0)
        if not kind and cylinder < 0 and not mask:
            continue
        points = [j["at"] for j in mesh["joints"]]
        def point(index):
            return points[index] if index >= 0 else [0, 0, 0]
        center = [header.get("quantizationOffset", {}).get(k, 0) for k in "XYZ"]
        if mask and not whole_ammo:
            center = [sum(points[i][axis] for i, flag in enumerate(ammo) if flag) / sum(ammo)
                      for axis in range(3)]
        supported = point(support)
        if support < 0 and trigger >= 0 and not pistol and not revolver:
            number_ = struct.unpack("<I", resource["renderBuffer"])[0] & 0x7fffffff
            surface = foregrip(reader, header, number_, point(trigger))
            if surface is not None:
                supported = surface
                kind |= 16
        # Revolver cartridges share one cylinder-space pickup centre. Their
        # individual bind pivots stay separate in the skinning matrices.
        if whole_ammo and any(n.startswith("bullet_") or n == "reload_magazine_bullets" for n in lower):
            center = [0, 0, 0]
        values = [asset_id, len(names), root, trigger, slide, cylinder, hinge, support, kind,
                  f"UINT64_C(0x{mask:x})", vector(point(root)), vector(point(trigger)),
                  vector(point(slide)), vector(point(cylinder)), vector(point(hinge)),
                  vector(supported), vector(center)]
        for draw in mesh["draws"]:
            # Coincident LOD aliases are harmless only if they describe the
            # same skinning layout and interaction roles.
            key = draw["count"], draw["fnv64"]
            signature = tuple(str(v) for v in values[1:])
            if whole_ammo and all(n.startswith("bullet_") or n == "reload_magazine_bullets" for n in lower):
                signature = ("cartridges", len(names), mask)
            if key in ambiguous:
                continue
            if key in entries and entries[key][0] != signature:
                del entries[key]
                ambiguous.add(key)
                continue
            entries[key] = signature, values
    lines = ["// Private numeric asset metadata; generated from locally owned files.",
             "static const vrik_asset_profile vrik_assets[] = {"]
    for (count, fingerprint), (_, values) in sorted(entries.items()):
        lines.append("    {UINT64_C(0x" + fingerprint + ")," + str(count) + "," +
                     ",".join(str(value) for value in values) + "},")
    lines += ["};", "#define VRIK_ASSET_COUNT (sizeof vrik_assets / sizeof vrik_assets[0])", ""]
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines))
    print(f"{len(entries)} draw identities; {len(ambiguous)} ambiguous identities refused; no geometry exported")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("meshes", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.resolve() in [p.resolve() for p in args.meshes]:
        parser.error("output must not replace an input")
    build(args.meshes, args.output)
