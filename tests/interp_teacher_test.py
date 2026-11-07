# SPDX-License-Identifier: MIT
import os
from pathlib import Path
import sys
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from interp_teacher import Raster, Scene, grid, quad, teacher_pair


class MovingPlane:
    def __init__(self, future_change=0, occluder=False):
        self.faces = [quad([[-1, -1, 0], [1, -1, 0], [1, 1, 0], [-1, 1, 0]])]
        self.colours = [np.array([.3, .7, .4], np.float32)]
        self.light = np.array([0, 0, -1], np.float32)
        self.future_change, self.occluder = future_change, occluder
        if occluder:
            self.faces.append(self.faces[0].copy())
            self.colours.append(np.array([.8, .2, .3], np.float32))

    def transforms(self, time):
        matrices = np.repeat(np.eye(4, dtype=np.float32)[None], len(self.faces), axis=0)
        matrices[0, :3, 3] = [.3*time + self.future_change*max(0, time-.2), 0, 3]
        if self.occluder:
            matrices[1, :3, 3] = [0 if time < .18 else 5, 0, 2]
        return matrices


class TeacherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        library = os.environ.get("VX_TEACHER_RASTER")
        if not library:
            raise RuntimeError("compile interp_teacher_raster.c and set VX_TEACHER_RASTER")
        cls.raster = Raster(Path(library), 96, 64)

    def test_perspective_surface_and_depth_roundtrip(self):
        scene = MovingPlane()
        # Different depths exercise perspective correction, not affine UVs.
        scene.faces[0][:, 2, 2] = .4
        frame = self.raster.render(scene, .2)
        uv, depth = self.raster.project(scene, frame, .2)
        valid = frame["id"] >= 0
        self.assertGreater(int(valid.sum()), 100)
        np.testing.assert_allclose(uv[valid], grid(96, 64)[valid], atol=1e-4)
        np.testing.assert_allclose(depth[valid], frame["depth"][valid], atol=1e-5)

    def test_linear_motion_matches_constant_velocity(self):
        pair, audit = teacher_pair(self.raster, MovingPlane(), .2, .06, .04)
        valid = pair["learn_valid"]
        self.assertGreater(int(valid.sum()), 100)
        self.assertLess(float(np.abs(pair["residual"][:, valid]).max()), .001)
        self.assertLess(audit["roundtrip_pixels"], .001)

    def test_newly_visible_surfaces_have_no_valid_history(self):
        pair, _ = teacher_pair(self.raster, MovingPlane(occluder=True), .2, .06, .04)
        centre = (32, 48)
        self.assertEqual(pair["current_id"][centre], 0)
        self.assertEqual(pair["x"][12][centre], 0)
        self.assertFalse(pair["learn_valid"][centre])

    def test_future_labels_do_not_leak_into_inputs(self):
        a, _ = teacher_pair(self.raster, MovingPlane(), .2, .06, .04)
        b, _ = teacher_pair(self.raster, MovingPlane(future_change=2), .2, .06, .04)
        np.testing.assert_array_equal(a["x"], b["x"])
        self.assertGreater(float(np.abs(a["flow"]-b["flow"]).max()), .1)

    def test_seed_reproduces_all_teacher_planes(self):
        mesh = MovingPlane().faces[0]
        a, audit_a = teacher_pair(self.raster, Scene(mesh, 19, "accelerating"), .2, .06, .04)
        b, audit_b = teacher_pair(self.raster, Scene(mesh, 19, "accelerating"), .2, .06, .04)
        self.assertEqual(audit_a, audit_b)
        for key in a:
            np.testing.assert_array_equal(a[key], b[key], err_msg=key)


if __name__ == "__main__":
    unittest.main()
