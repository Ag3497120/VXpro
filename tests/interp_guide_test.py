# SPDX-License-Identifier: MIT
import sys
import unittest
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from interp_guide import MotionGuide, AccelerationGuide, probe, validate_input


class GuideTests(unittest.TestCase):
    def setUp(self):
        torch.manual_seed(7)
        self.net = MotionGuide()
        self.x = torch.rand(1, 16, 24, 40)
        self.x[:, 12] = 1
        self.x[:, 15] = 0

    def test_features_and_gradient_reach_image_dependent_layers(self):
        report = probe(self.net, self.x)
        self.assertGreater(report["features_active"], 0)
        self.assertEqual(report["features_nonfinite"], 0)
        self.net(self.x).square().mean().backward()
        self.assertGreater(float(self.net.features[0].weight.grad.abs().sum()), 0)
        changed = self.x.clone()
        changed[:, :3] = 1 - changed[:, :3]
        self.assertGreater(float((self.net(self.x) - self.net(changed)).abs().max().detach()), 1e-6)

    def test_large_head_cannot_escape_residual_and_confidence_bounds(self):
        with torch.no_grad():
            self.net.head.weight.fill_(100)
        y = self.net(self.x)
        self.assertEqual(tuple(y.shape), (1, 3, 24, 40))
        self.assertTrue(torch.isfinite(y).all())
        self.assertLessEqual(float(y[:, :2].abs().max().detach()), 2)
        self.assertTrue(((y[:, 2] >= 0) & (y[:, 2] <= 1)).all())

    def test_foreground_and_invalid_history_produce_no_correction(self):
        self.x[:, 15, :, :20] = 1
        self.x[:, 12, :, 20:] = 0
        self.assertEqual(int(torch.count_nonzero(self.net(self.x))), 0)

    def test_wrong_abi_and_nonfinite_inputs_are_refused(self):
        with self.assertRaises(ValueError):
            validate_input(torch.rand(1, 6, 24, 40))
        self.x[0, 0, 0, 0] = float("nan")
        with self.assertRaises(ValueError):
            validate_input(self.x)

    def test_acceleration_guide_keeps_static_surfaces_static(self):
        net = AccelerationGuide()
        self.x[:, 8:12] = 0
        self.x[:, 13] = .6
        self.assertEqual(int(torch.count_nonzero(net(self.x)[:, :2])), 0)

    def test_acceleration_guide_matches_known_quadratic_trajectory(self):
        net = AccelerationGuide()
        with torch.no_grad():
            net.head.weight[:2].zero_()
            net.head.bias[:2].zero_()
        # x(t) = t^2 / 2, samples at -2, -1, 0, future t=1.
        # Past displacements -1.5, -0.5; future displacement +0.5.
        self.x[:, 8:12] = 0
        self.x[:, 8] = -.5/16
        self.x[:, 10] = -1.5/16
        self.x[:, 13:15] = .6
        residual = net(self.x)[:, :2]
        self.assertTrue(torch.allclose(residual[:, 0], torch.ones_like(residual[:, 0]), atol=1e-6))
        self.assertEqual(int(torch.count_nonzero(residual[:, 1])), 0)


if __name__ == "__main__":
    unittest.main()
