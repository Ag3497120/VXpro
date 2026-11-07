#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Join sampled compute dispatch bindings with Metal reflection; never infer effect names."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re


ACCESS = {0: "read", 1: "read_write", 2: "write"}  # MTLBindingAccess (Metal SDK)


def analyze(text, libraries=()):
    pipes, bindings, textures, states, dispatches = {}, defaultdict(list), {}, defaultdict(dict), []
    begins, ends = set(), set()
    for line in text.splitlines():
        m = re.match(r"FRAME (begin|end) (\d+)", line)
        if m:
            (begins if m[1] == "begin" else ends).add(int(m[2]))
        m = re.match(r"CPIPE p(\d+) .* k=(\S+)", line)
        if m:
            fn = m[2].split("[")[0]
            name, _, lib = fn.partition("#")
            pipes[int(m[1])] = dict(entry=name, library=lib or None)
        m = re.match(r"BIND p(\d+) kern (.*?) type (-?\d+) index (\d+) used (\d+)(.*)", line)
        if m:
            access = re.search(r"\bbinding_access (\d+)", m[6])
            b = dict(name=m[2], type=int(m[3]), index=int(m[4]), used=bool(int(m[5])),
                     access=ACCESS.get(int(access[1]), "unknown") if access else "unknown",
                     layout=m[6].strip(), opaque_struct_layout=bool(re.search(r"\bsize 0\b.*\bdata struct\b", m[6])))
            bindings[int(m[1])].append(b)
        m = re.match(r"TEX t(\d+) (.*)", line)
        if m:
            textures[int(m[1])] = m[2]
        m = re.match(r"CSET #(\d+) f(\d+) (texture|buffer|bytes|offset) (\d+) (.*)", line)
        if m:
            state = states[(int(m[1]), int(m[2]))]
            kind, index, value = m[3], int(m[4]), m[5]
            if kind == "offset":
                previous = state.get(("buffer", index))
                if previous and previous.startswith("b"):
                    state[("buffer", index)] = re.sub(r"offset \d+", "offset " + value, previous)
                else:
                    state[("buffer", index)] = "unknown buffer; offset " + value
            else:
                state[("buffer" if kind == "bytes" else kind, index)] = ("inline " if kind == "bytes" else "") + value
        m = re.match(r"CDISPATCH #(\d+) f(\d+) p(\d+) (groups|threads|indirect) (\S+) tg (\S+)", line)
        if m:
            key = (int(m[1]), int(m[2]))
            dispatches.append(dict(frame=key[1], pass_id=key[0], pipeline=int(m[3]), kind=m[4],
                                   dimensions=m[5], threadgroup=m[6], state=dict(states[key])))
    complete = begins & ends
    if not complete:
        raise ValueError("no complete sampled frames")
    groups = {}
    missing, unresolved = Counter(), Counter()
    for d in dispatches:
        if d["frame"] not in complete:
            continue
        pid = d["pipeline"]
        p = pipes.get(pid, dict(entry="unknown", library=None))
        if libraries and p["library"] not in libraries:
            continue
        key = (p["library"], p["entry"])
        g = groups.setdefault(key, dict(**p, dispatches=0, indirect_dispatches=0, frames=set(),
                                        shapes=Counter(), contracts={}))
        g["dispatches"] += 1
        g["frames"].add(d["frame"])
        g["indirect_dispatches"] += d["kind"] == "indirect"
        g["shapes"][f'{d["kind"]} {d["dimensions"]} tg {d["threadgroup"]}'] += 1
        if not bindings[pid]:
            missing["no reflected bindings observed"] += 1
        for b in bindings[pid]:
            if not b["used"] or b["type"] not in (0, 2):
                continue
            kind = "texture" if b["type"] == 2 else "buffer"
            if b["opaque_struct_layout"]:
                unresolved["empty reflected struct binding"] += 1
            resource = d["state"].get((kind, b["index"]), "not observed")
            shape = resource
            if kind == "texture" and re.fullmatch(r"t\d+", resource):
                tid = int(resource[1:])
                shape = "nil" if tid == 0 else textures.get(tid, "texture metadata missing")
            elif kind == "buffer":
                shape = re.sub(r"b(?:0x[0-9a-fA-F]+|\(nil\))", "buffer", resource)
            if resource == "not observed":
                missing["binding not observed"] += 1
            contract = dict(**b, resource_shape=shape)
            signature = json.dumps(contract, sort_keys=True)
            g["contracts"][signature] = contract
    output = []
    for g in groups.values():
        g["frames"] = sorted(g["frames"])
        g["shapes"] = dict(g["shapes"])
        g["contracts"] = list(g["contracts"].values())
        output.append(g)
    found = {g["library"] for g in output}
    return dict(complete_frames=sorted(complete), incomplete_frames=sorted(begins - ends),
                groups=sorted(output, key=lambda g: (-g["dispatches"], str(g["library"]), g["entry"])),
                requested_libraries_not_observed=sorted(set(libraries) - found), missing=dict(missing),
                unresolved=dict(unresolved), binding_scope="top-level Metal bindings only",
                limits=["dispatch counts are not GPU costs or effect names",
                        "argument-buffer contents and indirect dispatch counts are not read",
                        "top-level buffer read access does not establish nested resource read/write access",
                        "resource addresses are process-local and may be reused",
                        "metadata diagnostics do not measure normal gameplay FPS"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump", type=Path)
    ap.add_argument("--library", action="append", default=[])
    args = ap.parse_args()
    try:
        result = analyze(args.dump.read_text(), args.library)
    except ValueError as e:
        ap.exit(1, str(e) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
