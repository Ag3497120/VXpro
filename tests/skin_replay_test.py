# SPDX-License-Identifier: MIT
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from skin_replay_check import measure, skin


class WeightedSkinTests(unittest.TestCase):
    def test_joint_contact_alone_does_not_exclude_stretched_surface(self):
        vertices = np.array([[1., 0, 0], [1., .01, 0]])
        indices = np.array([[0], [1]])
        weights = np.ones((2, 1))
        identity = np.eye(4)[:3]
        native = np.array([identity, identity])
        posed = native.copy()
        posed[1, 0, 0] = posed[1, 1, 1] = -1
        # Both joint origins still coincide exactly.
        np.testing.assert_array_equal(native[:, :, 3], posed[:, :, 3])
        result = measure(skin(vertices, indices, weights, native),
                         skin(vertices, indices, weights, posed), np.array([[0, 1]]))
        self.assertAlmostEqual(result["native_max_edge_m"], .01)
        self.assertGreater(result["max_edge_growth_m"], 1.9)

    def test_common_rigid_motion_preserves_surface_edges(self):
        vertices = np.array([[0., 0, 0], [.01, 0, 0], [0, .02, 0]])
        indices = np.zeros((3, 1), dtype=int)
        weights = np.ones((3, 1))
        native = np.eye(4)[:3][None]
        moved = native.copy()
        moved[0, :, :3] = [[0, -1, 0], [1, 0, 0], [0, 0, 1]]
        moved[0, :, 3] = [1, 2, 3]
        result = measure(skin(vertices, indices, weights, native),
                         skin(vertices, indices, weights, moved), np.array([[0, 1], [1, 2], [2, 0]]))
        self.assertLess(result["max_edge_growth_m"], 1e-12)

    def test_all_eight_weights_contribute_without_renormalizing(self):
        palette = np.repeat(np.eye(4)[None, :3], 8, axis=0)
        palette[:, 0, 3] = np.arange(8)
        points = skin(np.array([[2., 0, 0]]), np.arange(8)[None],
                      np.full((1, 8), .12), palette)
        self.assertAlmostEqual(points[0, 0], .12 * sum(2 + i for i in range(8)))

    def test_nonfinite_palette_is_refused(self):
        palette = np.eye(4)[:3][None]
        palette[0, 0, 0] = np.nan
        with self.assertRaises(ValueError):
            skin(np.zeros((1, 3)), np.zeros((1, 1), dtype=int), np.ones((1, 1)), palette)


if __name__ == "__main__":
    unittest.main()
