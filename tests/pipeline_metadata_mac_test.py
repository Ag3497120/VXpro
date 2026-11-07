#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise the production shim before/after host-style environment parsing on Mac."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("executable", type=Path)
    ap.add_argument("shim", type=Path)
    ap.add_argument("metallib", type=Path)
    ap.add_argument("output", type=Path)
    args = ap.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    cases = [("off", None, None, 0), ("late-off", None, "0", 0),
             ("early-all", 1, None, 1), ("late-all", 1, "file", 1),
             ("early-compute", 2, None, 1), ("late-compute", 2, "file", 1),
             ("metadata-no-reflection", 0, "file", 1), ("metadata-only", 2, "file", 0)]
    results = []
    for name, mode, late, contract in cases:
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("VXMAC_PIPE", "VXMAC_PASS_PROFILE", "PP_"))}
        dump = out / (name + ".txt")
        dump.unlink(missing_ok=True)
        env.update(VXMAC_MAC_TEST="1", VXMAC_GPU_CAP="0", VXMAC_PIPE_REFLECT=str(mode or 0),
                   VXMAC_PIPE_FRAMES="3", VXMAC_PIPE_EVERY="0", VXMAC_PIPE_START="engage",
                   VXMAC_PIPE_CONTRACT=str(contract), VXMAC_UI_DRAWS="0", PP_DRIVING_AFTER="6",
                   PP_THREADS="1", PP_CONFIGURE_PIPE="1", PP_PIPE_APIS="1",
                   DYLD_INSERT_LIBRARIES=str(args.shim.resolve()))
        if mode is not None and late is None:
            env["VXMAC_PIPE_DUMP"] = str(dump)
        if late is not None:
            env["PP_LATE_PIPE_DUMP"] = str(dump) if late == "file" else late
        log_path = out / (name + ".log")
        with log_path.open("w") as log:
            subprocess.run([str(args.executable.resolve()), str(args.metallib.resolve()), "40"],
                           env=env, stdout=log, stderr=subprocess.STDOUT, timeout=60, check=True)
        match = re.search(r"checksum (\w+) frames (\d+)", log_path.read_text())
        assert match and match.group(1) == "17a96f390aa5a620", name
        result = dict(case=name, checksum=match.group(1), frames=40, caller_reflection="passed")
        if mode is None:
            assert not dump.exists(), name
            result["dump"] = False
        else:
            text = dump.read_text()
            begins = re.findall(r"^FRAME begin (\d+)", text, re.M)
            ends = re.findall(r"^FRAME end (\d+)", text, re.M)
            assert len(begins) == 3 and begins == ends and int(begins[0]) >= 7, (name, begins, ends)
            assert text.count("DUMP start ") == 1, name  # configure() called twice
            assert "CPASS " in text and "RPASS " in text, name
            assert f"reflect={mode} render_reflect={int(mode == 1)}" in text, name
            assert re.search(r"^BIND p\d+ kern .*binding_access \d", text, re.M), name
            render = re.findall(r"^RPIPE p\d+ (\S+)", text, re.M)
            compute = re.findall(r"^CPIPE p\d+ (\S+)", text, re.M)
            assert ("sync+r" in render) == (mode == 1), name
            assert ("async+r" in render) == (mode == 1), name
            assert ("sync+r" in compute) == bool(mode), name
            assert ("async+r" in compute) == bool(mode), name
            if contract:
                assert all(x in text for x in ("CDISPATCH ", "buffer 0 ", "texture 0 ",
                           "bytes 2 length 4", "offset 3 4", "texture 3 t0")), name
            else:
                assert "CSET " not in text and "CDISPATCH " not in text, name
            result.update(sampled_frames=begins, contract_dispatches=text.count("CDISPATCH "),
                          bytes=dump.stat().st_size)
        results.append(result)
    (out / "mac-results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
