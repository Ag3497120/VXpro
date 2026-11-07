# SPDX-License-Identifier: MIT
from pathlib import Path
import sys
import unittest

import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import interp_model as im
import interp_health as health


class HealthTests(unittest.TestCase):
    def setUp(self):
        torch.manual_seed(4)
        self.net = im.make_net((4, 4, 4, 4), 1)
        self.x = torch.rand(2, 6, 32, 48)

    def test_zero_head_with_live_features_can_start_training(self):
        result = health.require_training_features(self.net, [self.x])
        self.assertEqual(result["head_nonzero_weights"], 0)
        self.assertGreater(result["active_values"], 0)

    def test_dead_decoder_is_refused_before_training(self):
        with torch.no_grad():
            self.net.dec[-1][-1][0].weight.zero_()
            self.net.dec[-1][-1][0].bias.fill_(-1)
        with self.assertRaisesRegex(ValueError, "resetting only the head"):
            health.require_training_features(self.net, [self.x])

    def test_nonfinite_decoder_is_refused(self):
        with torch.no_grad():
            self.net.dec[-1][-1][0].bias.fill_(float("nan"))
        with self.assertRaises(ValueError):
            health.require_training_features(self.net, [self.x])

    def test_diagnostic_preserves_weights_mode_and_hooks(self):
        before = {key: value.clone() for key, value in self.net.state_dict().items()}
        self.net.train()
        health.feature_health(self.net, [self.x])
        self.assertTrue(self.net.training)
        self.assertFalse(self.net.dec[-1]._forward_hooks)
        for key, value in before.items():
            self.assertTrue(torch.equal(value, self.net.state_dict()[key]))


if __name__ == "__main__":
    unittest.main()
