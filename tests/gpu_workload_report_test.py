# SPDX-License-Identifier: MIT
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("report", Path(__file__).resolve().parents[1]/"tools/gpu_workload_report.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def fixture():
    lines = ["PPROF v3 timing_bounds=1 mode=overlap frames=3 max_windows=12 mono_s=100 unix_s=1000"]
    for i in range(3):
        lines.append(f"PENC w1.{i} i0 k=C q0 cb0 start_ms=0 span_ms=2 vtx_ms=0 frag_ms=0 share_ms=2 timing_valid=1 timing_omitted=0 timing_bad=0 sets=1 disp=1 ind=0 mthreads=.25 att=dispatch:serial pipes=1:k1234567890123456")
        lines.append(f"PENC w1.{i} i1 k=R ours=1 q1 cb1 start_ms=2 span_ms=1 vtx_ms=0 frag_ms=1 share_ms=1 timing_valid=3 timing_omitted=0 timing_bad=0 sets=1 disp=0 ind=0 mthreads=0 att=c0:640x360 pipes=1:f1234567890123456")
        lines.append(f"PFRAME w1.{i} mode=overlap lead={int(i==0)} driving=1 encoders=2 t={101+i} busy_ms=3 game_ms=2 ours_ms=1 render_ms=0 compute_ms=2 blit_ms=0 accel_ms=0 cb_busy_ms=3")
    lines.append("PWIN w1 mode=overlap frames=2 busy_ms=3")
    return "\n".join(lines)+"\n"


class TestReport(unittest.TestCase):
    def analyze(self, text, host=None):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/"profile.txt";p.write_text(text)
            h=None
            if host is not None:
                h=Path(directory)/"host.jsonl";h.write_text("\n".join(json.dumps(r) for r in host))
            return report.analyze(p,h,"synthetic")

    def test_complete_and_thermal(self):
        r=self.analyze(fixture(),[{"t":1000,"event":"thermal","state":0},{"t":1002.5,"event":"thermal","state":2},{"t":1010,"event":"stats"}])
        self.assertEqual(r["used_frames"],2)
        self.assertEqual(r["mean_assigned_intervals_ms"]["game_ms"],2)
        self.assertEqual([x["state"] for x in r["thermal_at_frames"]],[0,2])
        self.assertEqual(r["heaviest_groups"][0]["assigned_share_ms_per_frame"],2)

    def test_refuses_invalid_windows(self):
        variants=[fixture().replace("PWIN w1", "IGNORED w1"),fixture()+"PWIN w1 mode=overlap frames=2\n",
                  fixture().replace("driving=1","driving=0"),fixture().replace("mode=overlap","mode=serial"),
                  fixture().replace("share_ms=2","share_ms=9"),fixture().replace("start_ms=0","start_ms=-1"),
                  fixture()+"PWARN w1 duplicate_frame=2\n",fixture().replace("PFRAME w1.2","IGNORED w1.2"),
                  fixture()+fixture().splitlines()[1]+"\n"]
        for text in variants:
            with self.subTest(text=text[-80:]),self.assertRaises(ValueError):self.analyze(text)

    def test_refuses_wrong_session_or_nonfinite(self):
        with self.assertRaises(ValueError):self.analyze(fixture(),[{"t":2000,"event":"stats"}])
        with self.assertRaises(ValueError):self.analyze(fixture(),[{"t":1000,"event":"stats","pp_dropped":1},{"t":1010,"event":"stats"}])
        with self.assertRaises(ValueError):self.analyze(fixture().replace("share_ms=2","share_ms=nan"))
        with self.assertRaises(ValueError):self.analyze(fixture()+fixture().splitlines()[0]+"\n")

    def test_refuses_stale_or_unbounded_timestamps(self):
        for text in [fixture().replace("timing_bounds=1", "timing_bounds=0"),
                     fixture().replace("span_ms=1", "span_ms=6000"),
                     fixture().replace("timing_bad=0", "timing_bad=1"),
                     fixture().replace(" timing_valid=1", "")]:
            with self.subTest(text=text[:80]), self.assertRaises(ValueError): self.analyze(text)

    def test_source_function_metadata(self):
        key="K1234567890123456"
        text=fixture().replace("k1234567890123456",key)+f"PNAME key={key} name=velocity%20mean source=function_name\n"
        r=self.analyze(text)
        self.assertEqual(r["heaviest_groups"][0]["pipeline_functions"],[{"key":key,"name":"velocity mean","identity":"function_name"}])
        with self.assertRaises(ValueError):self.analyze(fixture().replace("k1234567890123456",key))
        with self.assertRaises(ValueError):self.analyze(text+f"PNAME key={key} name=other source=function_name\n")


if __name__=="__main__":unittest.main()
