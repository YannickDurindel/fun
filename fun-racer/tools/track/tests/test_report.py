"""build_track.py --report / --report-json: the size report of a built track (lib/report.py),
on the committed Red Bull Ring and Baku."""
import json
import os
import unittest

import helpers
import build_track
from lib import report
from lib.net import BuildError

BAKU = os.path.join(helpers.ROOT, "assets", "tracks", "baku")


def _listing(folder):
    return sorted((name, os.path.getmtime(os.path.join(folder, name)), os.path.getsize(os.path.join(folder, name)))
                  for name in os.listdir(folder))


class ReportTest(unittest.TestCase):
    def test_rows_cover_the_lap(self):
        rep = report.build(helpers.RBR)
        track = helpers.rbr_track()
        turns = [r for r in rep["rows"] if r["kind"] == "turn"]
        self.assertEqual([r["id"] for r in turns], [t["id"] for t in track["turns"]])
        self.assertEqual(turns[2]["name"], "Remus")
        self.assertEqual(turns[2]["min_radius"], track["turns"][2]["min_radius"])
        self.assertTrue(any(r["kind"] == "straight" and r["name"] == "T10 to T1" for r in rep["rows"]))
        for r in rep["rows"]:
            self.assertGreater(r["length"], 0.0)
            self.assertLessEqual(r["width"][0], r["width"][1])
            self.assertLessEqual(r["grade_pct"][0], r["grade_pct"][1])
            self.assertEqual(len(r["y"]), 3)
        # The rows follow each other round the lap without overlapping.
        covered = sum(r["length"] for r in rep["rows"])
        self.assertLessEqual(covered, track["length"] + 1.0)
        self.assertGreater(covered, 0.9 * track["length"])
        # The climb to Remus: uphill all the way, 60 m and more above the finish line.
        climb = next(r for r in rep["rows"] if r["name"] == "T1 to T3" or r["name"] == "T2 to T3")
        self.assertGreater(climb["y"][2], climb["y"][0])
        self.assertGreater(climb["grade_pct"][1], 5.0)

    def test_totals(self):
        rep = report.build(helpers.RBR)
        track = helpers.rbr_track()
        t = rep["totals"]
        self.assertEqual(t["length"], track["length"])
        self.assertEqual(t["turns"], 10)
        self.assertAlmostEqual(t["elevation_range"], track["elevation_range"], places=2)
        self.assertAlmostEqual(t["highest"]["y"] - t["lowest"]["y"], t["elevation_range"], places=2)
        self.assertGreaterEqual(t["climb"], t["elevation_range"])
        grades = [p["grade"] for p in track["points"]]
        self.assertAlmostEqual(t["max_grade_pct"]["value"], 100 * max(grades), places=2)
        self.assertAlmostEqual(t["min_grade_pct"]["value"], 100 * min(grades), places=2)
        self.assertEqual(t["width_source"], "road_profile.json")
        self.assertEqual(t["width"], [12.5, 16.0])
        # The drivers still see a nominal 13 m here, and the report says so.
        self.assertEqual(t["track_json_width"], [13.0, 13.0])
        self.assertTrue(any("track.json says the road is 13 to 13 m wide" in w for w in rep["warnings"]))

    def test_text_table(self):
        text = report.format_text(report.build(helpers.RBR))
        lines = text.splitlines()
        self.assertTrue(lines[0].startswith("red_bull_ring: Red Bull Ring"))
        self.assertIn("total climb", text)
        self.assertIn("steepest climb", text)
        self.assertIn("OSM width tags: none", text)
        row = next(ln for ln in lines if ln.startswith("T3 "))
        self.assertIn("Remus", row)
        header = next(ln for ln in lines if "R min" in ln)
        self.assertEqual(len(row), len(header))             # fixed-width columns

    def test_pairs_are_listed(self):
        rep = report.build(BAKU)
        self.assertEqual(len(rep["pairs"]), 1)
        self.assertIn("pair: s = 2175..2530 beside s = 4725..", report.format_text(rep))
        self.assertEqual(rep["totals"]["width"], rep["totals"]["track_json_width"])
        self.assertFalse(any("track.json says" in w for w in rep["warnings"]))

    def test_command_line_writes_nothing(self):
        before = _listing(helpers.RBR)
        out = []
        self.assertEqual(build_track.run(["red_bull_ring", "--report"], log=out.append), 0)
        self.assertEqual(out[0], report.format_text(report.build(helpers.RBR)))
        out = []
        self.assertEqual(build_track.run(["red_bull_ring", "--report-json"], log=out.append), 0)
        self.assertEqual(json.loads(out[0]), json.loads(json.dumps(report.build(helpers.RBR))))
        self.assertEqual(_listing(helpers.RBR), before)

    def test_a_missing_track_is_an_error(self):
        with self.assertRaises(BuildError):
            build_track.run(["nowhere_at_all", "--report"], log=helpers.silent)


if __name__ == "__main__":
    unittest.main()
