"""Regression: rebuilding the Red Bull Ring with its recipe reproduces the committed assets.

    .venv/bin/python -m unittest tools/track/tests/test_rebuild_rbr.py

The whole pipeline runs offline (committed OSM / DEM caches) into a temporary folder and is
compared with assets/tracks/red_bull_ring/: positions within 1 cm, identical turn and sector
tables, identical metadata. In practice the files come out byte-identical; that is asserted
for the pure-Python outputs and reported for the numpy ones (road mesh / profile), which may
differ in the last float bit on another numpy build.
"""
import importlib.util
import os
import shutil
import tempfile
import unittest

import helpers
import build_track
from lib import compare, terrain

HAVE_NUMPY = importlib.util.find_spec("numpy") is not None


class RebuildRedBullRingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="m8_rbr_rebuild_")
        # The kerb / barrier profiles are track-independent and need build123d (slow import):
        # the road step only generates them when the file is missing.
        shutil.copyfile(os.path.join(helpers.RBR, "trackside_profiles.json"),
                        os.path.join(cls.tmp, "trackside_profiles.json"))
        steps = "centreline,road,terrain,info" if HAVE_NUMPY else "centreline"
        cls.log = []
        cls.status = build_track.run(["red_bull_ring", "--offline", "--out", cls.tmp, "--steps", steps],
                                     log=cls.log.append)
        cls.report = compare.compare_dirs(cls.tmp, helpers.RBR)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def _checks(self, prefix):
        found = [(name, ok, detail) for name, ok, detail in self.report["checks"] if name.startswith(prefix)]
        self.assertTrue(found, f"no comparison ran for {prefix}")
        for name, ok, detail in found:
            self.assertTrue(ok, f"{name}: {detail}")
        return found

    def test_build_ran_offline_without_warnings(self):
        self.assertEqual(self.status, 0)
        self.assertFalse([line for line in self.log if line.startswith("WARNING")], self.log)

    def test_track_json_matches(self):
        checks = dict((n, d) for n, _, d in self._checks("track.json"))
        self.assertIn("track.json positions", checks)
        self.assertIn("track.json turns", checks)
        self.assertIn("track.json sectors", checks)
        self.assertIn("track.json", self.report["identical"], "track.json should be byte-identical")

    @unittest.skipUnless(HAVE_NUMPY, "the road step needs numpy (use the project venv)")
    def test_road_matches(self):
        self._checks("road_profile.json")
        self._checks("road_mesh.glb")
        self._checks("road_tarmac_albedo.png")

    @unittest.skipUnless(HAVE_NUMPY, "the terrain is compared on top of the rebuilt road profile")
    def test_terrain_matches(self):
        self._checks("terrain.json")
        self._checks("terrain_height.bin")
        self._checks("terrain_far.bin")
        self._checks("terrain_dist.bin")
        self.assertIn("terrain.json", self.report["identical"])

    @unittest.skipUnless(HAVE_NUMPY, "track_info.json says 'available' only with road and terrain")
    def test_track_info_matches_and_whole_report_is_clean(self):
        self._checks("track_info.json")
        self.assertEqual(self.report["missing"], [])
        self.assertTrue(self.report["ok"], compare.format_report(self.report))

    def test_build_info_matches_the_committed_one(self):
        import json
        with open(os.path.join(self.tmp, "build_info.json"), encoding="utf-8") as f:
            new = json.load(f)
        with open(os.path.join(helpers.RBR, "build_info.json"), encoding="utf-8") as f:
            old = json.load(f)
        self.assertEqual(new, old)
        self.assertEqual(new["osm"]["length_m"], 4302.1)
        self.assertEqual(new["dem_dataset"], "eudem25m")
        self.assertIn(new["osm"]["loop_ways"],
                      [helpers.RBR_LOOP_WAYS[i:] + helpers.RBR_LOOP_WAYS[:i] for i in range(14)])

    def test_automatic_terrain_bounds_equal_the_recipe_ones(self):
        pts = [p["p"] for p in helpers.rbr_track()["points"]]
        near, far = terrain.default_bounds(pts)
        self.assertEqual(near, [-1600.0, 800.0, -1200.0, 600.0])
        self.assertEqual(far, [-6400.0, 5600.0, -6200.0, 5800.0])

    def test_scene_template_is_written_next_to_a_scratch_build(self):
        scene = os.path.join(self.tmp, "red_bull_ring.tscn")
        if not HAVE_NUMPY:
            self.skipTest("info step not run")
        with open(scene, encoding="utf-8") as f:
            text = f.read()
        self.assertIn('track_id = "red_bull_ring"', text)
        self.assertIn('track_json = "res://assets/tracks/red_bull_ring/track.json"', text)
        for node in ('name="Road"', 'name="Trackside"', 'name="Terrain"', 'name="Race"'):
            self.assertIn(node, text)

    def test_compare_detects_a_one_centimetre_shift(self):
        import json
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(self.tmp, "track.json"), encoding="utf-8") as f:
                t = json.load(f)
            t["points"][100]["p"][0] += 0.02
            with open(os.path.join(d, "track.json"), "w", encoding="utf-8") as f:
                json.dump(t, f)
            rep = compare.compare_dirs(d, helpers.RBR, files=("track.json",))
            self.assertFalse(rep["ok"])
            self.assertTrue(any(n == "track.json positions" and not ok for n, ok, _ in rep["checks"]))


if __name__ == "__main__":
    unittest.main()
