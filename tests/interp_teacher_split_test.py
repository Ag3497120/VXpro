# SPDX-License-Identifier: MIT
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from interp_guide import CONTRACT
from interp_guide_train import read_manifest
from interp_teacher import ROOT, TEACHER_CONTRACT


class SplitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT / "build")
        self.root = Path(self.tmp.name)
        self.manifest = {"teacher_contract": TEACHER_CONTRACT, "model_contract": CONTRACT,
                         "motion_unit_pixels": 16.0, "time_unit_seconds": .1, "near": .1, "far": 64.0, "samples": []}
        for i, split in enumerate(("train", "validation", "test")):
            directory = self.root / split
            directory.mkdir()
            file = directory / "sample.npz"
            file.write_bytes(bytes([i]))
            self.manifest["samples"].append({"file": f"{split}/sample.npz", "split": split,
                                             "asset_sha256": str(i), "clip": i,
                                             "sha256": hashlib.sha256(file.read_bytes()).hexdigest()})

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, data):
        (self.root / "manifest.json").write_text(json.dumps(data))
        return read_manifest(self.root)

    def test_complete_separated_manifest_is_accepted(self):
        self.assertEqual(len(self.read(self.manifest)["samples"]), 3)

    def test_shared_source_asset_is_refused(self):
        data = copy.deepcopy(self.manifest)
        data["samples"][2]["asset_sha256"] = data["samples"][0]["asset_sha256"]
        with self.assertRaisesRegex(ValueError, "source asset leaks"):
            self.read(data)

    def test_shared_clip_is_refused(self):
        data = copy.deepcopy(self.manifest)
        data["samples"][2]["clip"] = 0
        with self.assertRaisesRegex(ValueError, "clip leaks"):
            self.read(data)

    def test_changed_data_is_refused(self):
        (self.root / "test/sample.npz").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            self.read(self.manifest)

    def test_wrong_motion_units_are_refused(self):
        self.manifest["motion_unit_pixels"] = 1.0
        with self.assertRaisesRegex(ValueError, "motion units"):
            self.read(self.manifest)


if __name__ == "__main__":
    unittest.main()
