#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("contracts", Path(__file__).parents[1] / "tools/compute_contract_report.py")
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)

FIXTURE = """CPIPE p1 sync+r label=- k=fixture#0123456789abcdef tg=1024 simd=32
BIND p1 kern input type 2 index 0 used 1 binding_access 0
BIND p1 kern output type 2 index 1 used 1 binding_access 2
BIND p1 kern state type 0 index 0 used 1 size 16 align 4 binding_access 1
TEX t1 320x180x1 type 2 fmt 80 mips 1 usage 1 storage 2 label=-
TEX t2 320x180x1 type 2 fmt 80 mips 1 usage 2 storage 2 label=-
FRAME begin 10 t=1.0
CSET #1 f10 texture 0 t1
CSET #1 f10 texture 1 t2
CSET #1 f10 buffer 0 b0x123 offset 0 length 1024 storage 0
CSET #1 f10 offset 0 64
CDISPATCH #1 f10 p1 threads 320,180,1 tg 8,8,1
FRAME end 10
"""


class Contracts(unittest.TestCase):
    def test_access_and_shapes(self):
        r = contracts.analyze(FIXTURE)
        self.assertEqual(r["missing"], {})
        g = r["groups"][0]
        by_name = {b["name"]: b for b in g["contracts"]}
        self.assertEqual({k: b["access"] for k, b in by_name.items()},
                         {"input": "read", "output": "write", "state": "read_write"})
        self.assertIn("320x180", by_name["input"]["resource_shape"])
        self.assertEqual(by_name["state"]["resource_shape"], "buffer offset 64 length 1024 storage 0")

    def test_incomplete_frame_excluded(self):
        r = contracts.analyze(FIXTURE + "FRAME begin 11 t=2.0\nCDISPATCH #2 f11 p1 threads 1,1,1 tg 1,1,1\n")
        self.assertEqual(r["incomplete_frames"], [11])
        self.assertEqual(r["groups"][0]["dispatches"], 1)

    def test_no_complete_frame_rejected(self):
        with self.assertRaises(ValueError):
            contracts.analyze("FRAME begin 1 t=1.0\n")

    def test_library_filter_missing_explicit(self):
        r = contracts.analyze(FIXTURE, ["ffffffffffffffff"])
        self.assertEqual(r["groups"], [])
        self.assertEqual(r["requested_libraries_not_observed"], ["ffffffffffffffff"])

    def test_missing_binding_and_indirect_not_invented(self):
        r = contracts.analyze(FIXTURE.replace("CSET #1 f10 texture 1 t2\n", "").replace(
            "threads 320,180,1", "indirect 0,0,0"))
        self.assertEqual(r["missing"]["binding not observed"], 1)
        self.assertEqual(r["groups"][0]["indirect_dispatches"], 1)
        self.assertTrue(any(b["resource_shape"] == "not observed" for b in r["groups"][0]["contracts"]))

    def test_empty_argument_struct_is_unresolved(self):
        r = contracts.analyze(FIXTURE.replace("size 16 align 4", "size 0 align 4 data struct s9 *(size 0)s9"))
        self.assertEqual(r["unresolved"], {"empty reflected struct binding": 1})
        self.assertEqual(r["binding_scope"], "top-level Metal bindings only")


if __name__ == "__main__":
    unittest.main()
