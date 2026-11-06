# SPDX-License-Identifier: MIT
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
import weapon_asset_profile as profile


class AssetProfileTests(unittest.TestCase):
    def test_buffer_slots_do_not_alias(self):
        data = bytearray(240)
        data[:4] = b"CR2W"
        struct.pack_into("<I", data, 24, 240)
        struct.pack_into("<III", data, 100, 160, 2, 0)
        struct.pack_into("<I", data, 160 + 16, 4)
        struct.pack_into("<I", data, 184 + 16, 6)
        data += b"left" + b"second"
        self.assertEqual(bytes(profile.unpacked_buffer(data, 1)), b"left")
        self.assertEqual(bytes(profile.unpacked_buffer(data, 2)), b"second")
        for truncated in [data[:240], data[:-1]]:
            with self.assertRaisesRegex(ValueError, "full unpacked"):
                profile.unpacked_buffer(truncated, 1)
        with self.assertRaises(ValueError):
            profile.unpacked_buffer(data, 0)
        with self.assertRaises(ValueError):
            profile.unpacked_buffer(data, 3)

    def test_chunk_boundaries_and_index_width(self):
        data = struct.pack("<6H", 2, 1, 0, 0, 1, 2)
        self.assertNotEqual(profile.index_fingerprint(data, 0, 3, 3),
                            profile.index_fingerprint(data, 6, 3, 3))
        self.assertEqual(profile.index_fingerprint(data, 6, 3, 3), "37f11cf1d36d7afe")
        for start, count, vertices in [(1, 3, 3), (8, 3, 3), (0, 3, 2), (0, 0, 3), (0, 3, 65537)]:
            with self.assertRaises(ValueError):
                profile.index_fingerprint(data, start, count, vertices)

    def test_cannot_overwrite_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "own-metadata.bin"
            source.write_bytes(b"own fixture")
            result = subprocess.run([sys.executable, str(TOOLS / "weapon_asset_profile.py"),
                                     str(source), "--output", str(source)], capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(source.read_bytes(), b"own fixture")


if __name__ == "__main__":
    unittest.main()
