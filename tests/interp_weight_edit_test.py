# SPDX-License-Identifier: MIT
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import interp_model as im
import interp_weight_edit as we


class WeightEditTests(unittest.TestCase):
    def checkpoint(self):
        net = im.make_net((4, 4, 4, 4), 1)
        with torch.no_grad():
            net.head.bias.copy_(torch.linspace(-.5, .5, 24))
        return {"state": net.state_dict(), "widths": (4, 4, 4, 4), "dec_convs": 1}

    def test_constant_head_shortcut_is_exact_for_multiple_images(self):
        ck = self.checkpoint()
        net = im.make_net(ck["widths"], 1)
        net.load_state_dict(ck["state"])
        x = torch.rand(3, 6, 32, 48)
        with torch.inference_mode():
            torch.testing.assert_close(we.ConstantHead(ck)(x), net(x), rtol=0, atol=0)
        ck["state"]["head.weight"][0, 0, 0, 0] = .1
        with self.assertRaises(ValueError):
            we.ConstantHead(ck)

    def test_edit_only_touches_declared_head_rows_and_preserves_source(self):
        ck = self.checkpoint()
        original = {k: v.clone() for k, v in ck["state"].items()}
        result = we.edited(ck, "half_fill")
        for key, tensor in original.items():
            self.assertTrue(torch.equal(ck["state"][key], tensor))
            if key == "head.bias":
                torch.testing.assert_close(result["state"][key][:12], tensor[:12] / 2)
                self.assertTrue(torch.equal(result["state"][key][12:], tensor[12:]))
            else:
                self.assertTrue(torch.equal(result["state"][key], tensor))

    def test_phase_projection_removes_constant_checkerboard(self):
        ck = we.edited(self.checkpoint(), "phase_mean")
        x = torch.full((1, 6, 32, 48), .5)
        out = we.ConstantHead(ck)(x)
        for channel in range(6):
            self.assertEqual(float(out[0, channel].max() - out[0, channel].min()), 0)

    def test_trial_output_cannot_overwrite_the_source(self):
        with tempfile.TemporaryDirectory() as temp:
            source=Path(temp)/"phase_mean.pt"
            source.write_bytes(b"original checkpoint fixture")
            result=subprocess.run([sys.executable,str(Path(we.__file__)),"--checkpoint",str(source),
                                   "--data",temp,"--out",temp],capture_output=True)
            self.assertEqual(result.returncode,2)
            self.assertIn(b"must not replace",result.stderr)
            self.assertEqual(source.read_bytes(),b"original checkpoint fixture")


if __name__ == "__main__":
    unittest.main()
