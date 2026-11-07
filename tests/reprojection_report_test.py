# SPDX-License-Identifier: MIT
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("report",Path(__file__).resolve().parents[1]/"tools/reprojection_report.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReportTest(unittest.TestCase):
    def fixture(self, repeats=2, hz=90):
        rows = [{"event":"start","plan":"third","independent_app_reprojection":False,"frame_interpolation":False},
                {"event":"phase","key":"0-third","nominal_fps":30,"repeat_count":repeats}]
        for i in range(121):
            rows += [{"event":"frame","source_id":i,"key":"0-third","presentation_s":10+i*(repeats+1)/hz,
                      "presentation_index":1000+i*(repeats+1),"tracked":True,"capture_targets":0},
                     {"event":"gpu","source_id":i,"late":i%10==0,"failed":False}]
        rows.append({"event":"end","completed_test":True})
        return [{**r,"session":"one","unix_s":0} for r in rows]
    def analyze(self, rows):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/"test.jsonl";p.write_text("\n".join(json.dumps(r) for r in rows))
            return report.analyze(p)
    def test_repeats_are_not_new_frames(self):
        for repeat in [0,1,2]:
            r = self.analyze(self.fixture(repeat))
            phase = r["phases"][0]
            self.assertAlmostEqual(phase["source_submission_fps"],90/(repeat+1))
            self.assertAlmostEqual(phase["scheduled_display_hz"],90)
            self.assertIsNone(r["actual_panel_fps"])
            self.assertAlmostEqual(phase["mean_scheduled_slots_per_source"],repeat+1)
    def test_100hz_is_not_assumed_to_be_90(self):
        r = self.analyze(self.fixture(2,100))["phases"][0]
        self.assertAlmostEqual(r["source_submission_fps"],100/3)
        self.assertAlmostEqual(r["scheduled_display_hz"],100)
    def test_invalid_schedule_is_rejected(self):
        r = self.fixture();r[80]["presentation_s"] = r[78]["presentation_s"]
        with self.assertRaises(ValueError):self.analyze(r)
    def test_repeat_setting_transition_is_excluded_with_warmup(self):
        r = self.fixture();r[4]["presentation_s"] = r[2]["presentation_s"]-0.0000002
        result = self.analyze(r)["phases"][0]
        self.assertEqual(result["excluded_warmup_schedule_anomalies"],1)
        self.assertAlmostEqual(result["source_submission_fps"],30)
    def test_capture_contamination_and_missing_gpu_receipts(self):
        r = self.fixture()
        r = [x for x in r if x["event"] != "gpu"]
        for x in r:
            if x["event"] == "frame":x["capture_targets"] = 1
        p = self.analyze(r)["phases"][0]
        self.assertTrue(p["capture_target_seen"]);self.assertEqual(p["gpu_completion_records"],0)
    def test_mixed_sessions_are_rejected(self):
        r = self.fixture();r[-1]["session"] = "two"
        with self.assertRaises(ValueError):self.analyze(r)
    def test_early_exit_is_not_a_completed_comparison(self):
        r = self.fixture();r[-1]["completed_test"] = False
        self.assertFalse(self.analyze(r)["complete"])


if __name__ == "__main__":unittest.main()
