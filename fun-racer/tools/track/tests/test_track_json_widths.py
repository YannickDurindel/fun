"""[road] track_json_widths: track.json carries the built road widths instead of a nominal 13 m."""
import importlib.util
import unittest

import helpers  # noqa: F401  (sets sys.path)
from lib import info, recipe
from lib.net import BuildError

HAVE_NUMPY = importlib.util.find_spec("numpy") is not None
BASE = {"osm": {"relation": 1}, "length_m": 2000}
N, STEP, LENGTH, START_S = 1000, 2.0, 2000.0, 100.0
NARROW = {"base_width": 11.0, "grid_width": 13.0, "track_json_widths": True,
          "override": [{"s": [900.0, 1100.0], "width": 7.6, "blend": 20.0}]}


def _recipe(road):
    return recipe.from_dict("somewhere", {**BASE, "road": road})


def _track(widths):
    return {"step": STEP, "length": LENGTH, "start_s": START_S,
            "points": [{"s": k * STEP, "width": w, "curvature": 0.0} for k, w in enumerate(widths)]}


class TrackJsonWidthsTest(unittest.TestCase):
    def test_recipe_key(self):
        self.assertTrue(_recipe({"track_json_widths": True}).road["track_json_widths"])
        with self.assertRaises(BuildError):
            _recipe({"track_json_widths": "yes"})

    def test_nominal_width_without_the_key(self):
        # No numpy needed, and whatever the [road] table says: this is what every track built
        # before the key existed has in its track.json.
        road = {k: v for k, v in NARROW.items() if k != "track_json_widths"}
        self.assertEqual(info.track_json_widths(_recipe(road), 5, STEP, 10.0, 0.0, [0.0] * 5), [13.0] * 5)
        self.assertEqual(info.track_json_widths(_recipe({}), 3, STEP, 6.0, 0.0, [0.0] * 3), [13.0] * 3)

    @unittest.skipUnless(HAVE_NUMPY, "cad/track/banking.py needs numpy (use the project venv)")
    def test_built_widths_with_the_key(self):
        w = info.track_json_widths(_recipe(NARROW), N, STEP, LENGTH, START_S, [0.0] * N)
        self.assertEqual(len(w), N)
        self.assertEqual(w[int(START_S / STEP)], 13.0)      # the grid
        self.assertEqual(w[int(1000.0 / STEP)], 7.6)        # inside the override
        self.assertEqual(w[int(1500.0 / STEP)], 11.0)       # base width
        self.assertEqual(w, info.road_widths(_recipe(NARROW), N, STEP, LENGTH, START_S, [0.0] * N))

    @unittest.skipUnless(HAVE_NUMPY, "cad/track/banking.py needs numpy (use the project venv)")
    def test_road_step_refuses_a_stale_track_json(self):
        rec = _recipe(NARROW)
        built = info.track_json_widths(rec, N, STEP, LENGTH, START_S, [0.0] * N)
        info._check_track_widths(rec, _track(built))                       # in step: fine
        with self.assertRaises(BuildError):                                # centreline ran without the key
            info._check_track_widths(rec, _track([13.0] * N))
        off = _recipe({k: v for k, v in NARROW.items() if k != "track_json_widths"})
        info._check_track_widths(off, _track([13.0] * N))
        with self.assertRaises(BuildError):                                # the key was removed since
            info._check_track_widths(off, _track(built))

    def test_committed_tracks_pass_the_check(self):
        # The reference track has no key and a nominal track.json.
        info._check_track_widths(recipe.load("red_bull_ring"), helpers.rbr_track())


if __name__ == "__main__":
    unittest.main()
