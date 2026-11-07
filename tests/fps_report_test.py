# SPDX-License-Identifier: MIT
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location("fps",Path(__file__).resolve().parents[1]/"tools/fps_report.py")
fps=importlib.util.module_from_spec(spec);spec.loader.exec_module(fps)

def fixture():
    rows=[{"event":"host_init","since_start":0},{"event":"scene_phase","since_start":0,"phase":"inactive"},{"event":"scene_phase","since_start":0,"phase":"active"}]
    for t,rate in zip([0,.5,2,3,4],[0,10,20,10,20]):
        rows.append({"event":"stats","since_start":t,"t":1000+t,"mode":"vr","game_fps":rate,"compositor_hz":90,"frames":int(t*30)})
    return rows

class TestFPS(unittest.TestCase):
    def analyze(self,rows,seconds=4,end_at=None):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/"host";p.write_text("\n".join(json.dumps(r) for r in rows))
            return fps.analyze(p,seconds,end_at)
    def test_nonuniform_reset_intervals(self):
        s=self.analyze(fixture())
        self.assertEqual(s["received_game_image_fps"],16.25)
        self.assertEqual(s["game_submit_fps"],30)
        self.assertEqual(s["compositor_updates_hz"],90)
    def test_refuses_menu_background_reset_and_bad_rate(self):
        cases=[]
        for value in ["screen","head"]:
            rows=fixture();rows[-2]["mode"]=value;cases.append(rows)
        rows=fixture();rows.insert(-1,{"event":"scene_phase","since_start":2.5,"phase":"background"});cases.append(rows)
        rows=fixture();rows[-1]["frames"]=1;cases.append(rows)
        rows=fixture();rows[-1]["game_fps"]=float("nan");cases.append(rows)
        rows=fixture();rows[-1]["since_start"]=3;cases.append(rows)
        for rows in cases:
            with self.subTest(rows=rows),self.assertRaises(ValueError):self.analyze(rows)
    def test_earlier_rounded_zero_interval_does_not_change_later_window(self):
        rows=fixture();rows.insert(5,dict(rows[4]))
        self.assertEqual(self.analyze(rows,2)["received_game_image_fps"],15)
    def test_explicit_window_before_inactive_phase(self):
        rows=fixture()+[{"event":"scene_phase","since_start":4.1,"phase":"inactive"},
            {"event":"vr","since_start":5,"t":1005,"mode":"vr","game_fps":100,"compositor_hz":100}]
        self.assertEqual(self.analyze(rows,4,4)["received_game_image_fps"],16.25)
        with self.assertRaises(ValueError):self.analyze(rows)

if __name__=="__main__":unittest.main()
