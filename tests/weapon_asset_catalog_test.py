# SPDX-License-Identifier: MIT
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
import weapon_asset_catalog as catalog


class CatalogTests(unittest.TestCase):
    def build_fixtures(self, fixtures):
        with tempfile.TemporaryDirectory() as temporary:
            paths = []
            records = {}
            for i, (bones, tags) in enumerate(fixtures):
                path = Path(temporary) / f"{i}.bin"
                path.write_bytes(bytes([i]))
                paths.append(path)
                records[path] = {"bones": bones, "joints": [{"at": [0, i*.01, 0]} for _ in bones],
                                 "draws": [{"count": 426, "fnv64": "123456789abcdef0"}]}
            output = Path(temporary) / "catalog.h"
            with patch.object(catalog, "inspect", side_effect=lambda p: records[p]), \
                    patch.object(catalog, "CR2W", side_effect=lambda b: SimpleNamespace(names=fixtures[b[0]][1])), \
                    patch.object(catalog, "properties", return_value=iter([])):
                # Each reader needs an independent resource iterator.
                with patch.object(catalog, "properties", side_effect=lambda *a: iter([{"header": {}}])), \
                        redirect_stdout(StringIO()) as status:
                    catalog.build(paths, output)
            return output.read_text(), status.getvalue()

    def test_same_indices_with_different_joint_roles_are_refused(self):
        text, status = self.build_fixtures([(["mag_std"], []), (["cylinder"], ["w_revolver"])])
        self.assertNotIn("0x123456789abcdef0", text)
        self.assertIn("1 ambiguous identities refused", status)

    def test_cartridge_aliases_keep_one_identity(self):
        text, status = self.build_fixtures([(["bullet_01"], []), (["bullet_06"], [])])
        self.assertEqual(text.count("0x123456789abcdef0"), 1)
        self.assertIn("0 ambiguous identities", status)

    def test_nova_cylinder_is_not_a_disposable_magazine(self):
        text, _ = self.build_fixtures([(["mag_std"], ["w_revolver", "darra_nova"])])
        row = next(line for line in text.splitlines() if "0x123456789abcdef0" in line)
        fields = row.split(",")
        self.assertEqual(fields[7], "0")  # Cylinder bone.
        self.assertEqual(fields[10], "4")  # Revolver, not loose ammunition.
        self.assertEqual(fields[11], "UINT64_C(0x0)")

    def test_unknown_position_format_never_produces_a_support_point(self):
        reader = SimpleNamespace(names=["", "type", "usage", "PT_Unknown", "PS_Position"], d=b"")
        def field(name, value):
            return struct.pack("<HHI", name, 0, 6) + struct.pack("<H", value)
        raw = bytes(5) + field(1, 3) + field(2, 4) + bytes(8)
        header = {"renderChunkInfos": [{"lodMask": 1, "chunkVertices": {
            "vertexLayout": {"elements": raw}}}]}
        with patch.object(catalog, "unpacked_buffer", return_value=b""):
            self.assertIsNone(catalog.foregrip(reader, header, 1, [0, 0, 0]))

    def test_crowbar_and_rigid_melee_are_not_discarded(self):
        for bones in (["base"], []):
            text, _ = self.build_fixtures([(bones, ["ml_w_club_1h__crowbar__grip1_01_masksset"])])
            row = next(line for line in text.splitlines() if "0x123456789abcdef0" in line)
            self.assertEqual(row.split(",")[10], "64")

    def test_scope_without_trigger_is_a_mounted_part(self):
        text, _ = self.build_fixtures([(["scope"], [])])
        row = next(line for line in text.splitlines() if "0x123456789abcdef0" in line)
        self.assertEqual(row.split(",")[10], "32")

    def test_five_nail_bones_keep_their_exact_order(self):
        bones=["RightHandThumb2", "RightHandIndex3", "RightHandMiddle3", "RightHandRing3", "RightHandPinky3"]
        text, _ = self.build_fixtures([(bones, [])])
        row = next(line for line in text.splitlines() if "0x123456789abcdef0" in line)
        self.assertEqual(row.split(",")[10], "128")
        self.assertIn("vrik_body_1[]", text)

    def test_clothing_triangle_aliases_retain_both_skin_layouts(self):
        text, status = self.build_fixtures([
            (["LeftForeArm", "RightForeArm"], []),
            (["LeftArm", "LeftForeArm", "RightArm", "RightForeArm"], [])])
        self.assertEqual(text.count("0x123456789abcdef0"), 2)
        self.assertIn("0 ambiguous identities refused", status)

    def test_setup_nails_resolve_to_the_same_anatomy(self):
        bones=["LeftHandThumb1", "LeftHandThumb2", "LeftHandIndex2", "LeftHandIndex3"]
        text, status = self.build_fixtures([(bones, []), ([n+"_setup" for n in bones], [])])
        self.assertEqual(text.count("0x123456789abcdef0"), 1)
        self.assertIn("0 ambiguous identities refused", status)


if __name__ == "__main__":
    unittest.main()
