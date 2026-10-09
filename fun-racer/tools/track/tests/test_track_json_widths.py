"""track.json widths: the built road widths as soon as the recipe sets a width (or with
[road] track_json_widths = true), a nominal 13 m otherwise (or with = false)."""
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

    def test_nominal_width_when_switched_off(self):
        # No numpy needed. With the key false the width is nominal: 13 m, or the recipe's base
        # width when that is narrower (the drivers must not plan outside the road). That is how
        # Red Bull Ring and Monaco were built, and their recipes say so.
        road = {**NARROW, "track_json_widths": False}
        self.assertEqual(info.track_json_widths(_recipe(road), 5, STEP, 10.0, 0.0, [0.0] * 5), [11.0] * 5)
        off = {"base_width": 14.0, "track_json_widths": False}
        self.assertEqual(info.track_json_widths(_recipe(off), 2, STEP, 4.0, 0.0, [0.0] * 2), [13.0] * 2)
        # A recipe that sets no width at all: the nominal 13 m of the tracks built so far.
        self.assertEqual(info.track_json_widths(_recipe({}), 3, STEP, 6.0, 0.0, [0.0] * 3), [13.0] * 3)
        self.assertEqual(info.track_json_widths(_recipe({"crossfall": 0.02}), 3, STEP, 6.0, 0.0, [0.0] * 3), [13.0] * 3)

    def test_the_default_follows_the_recipe(self):
        # On as soon as the [road] table states a width, whichever way; never by anything else.
        self.assertFalse(recipe.track_json_widths({}))
        self.assertFalse(recipe.track_json_widths({"crossfall": 0.02, "retaining_walls": True,
                                                   "override": [{"s": [0.0, 10.0], "bank": 0.01}]}))
        for road in ({"base_width": 16.0}, {"grid_width": 14.0}, {"width_keys": [[0.0, 12.0], [500.0, 14.0]]},
                     {"override": [{"s": [0.0, 10.0], "width": 9.0}]}):
            self.assertTrue(recipe.track_json_widths(road), road)
            self.assertFalse(recipe.track_json_widths({**road, "track_json_widths": False}), road)
        self.assertTrue(recipe.track_json_widths({"track_json_widths": True}))

    @unittest.skipUnless(HAVE_NUMPY, "cad/track/banking.py needs numpy (use the project venv)")
    def test_wide_and_narrow_roads_reach_track_json_by_default(self):
        # 20 m wide somewhere, 9 m somewhere else, no key: the drivers get both.
        road = {"base_width": 12.0, "override": [{"s": [400.0, 600.0], "width": 20.0, "blend": 30.0},
                                                 {"s": [1400.0, 1600.0], "width": 9.0, "blend": 30.0}]}
        w = info.track_json_widths(_recipe(road), N, STEP, LENGTH, START_S, [0.0] * N)
        self.assertEqual(w[int(500.0 / STEP)], 20.0)
        self.assertEqual(w[int(1500.0 / STEP)], 9.0)
        self.assertEqual(w[int(1000.0 / STEP)], 12.0)
        self.assertEqual(w, info.road_widths(_recipe(road), N, STEP, LENGTH, START_S, [0.0] * N))
        # The roll-in is the override's blend: no step in the width from one point to the next.
        self.assertLess(max(abs(b - a) for a, b in zip(w, w[1:])), 1.0)

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
        off = _recipe({**NARROW, "track_json_widths": False})
        info._check_track_widths(off, _track([11.0] * N))                  # nominal = base width
        with self.assertRaises(BuildError):                                # the key was switched off since
            info._check_track_widths(off, _track(built))
        default = _recipe({k: v for k, v in NARROW.items() if k != "track_json_widths"})
        info._check_track_widths(default, _track(built))                   # no key: the built widths

    def test_committed_tracks_pass_the_check(self):
        # The reference track switches the key off and has a nominal track.json; so does Monaco.
        info._check_track_widths(recipe.load("red_bull_ring"), helpers.rbr_track())
        self.assertFalse(recipe.track_json_widths(recipe.load("monaco").road))
        self.assertFalse(recipe.track_json_widths(recipe.load("red_bull_ring").road))


if __name__ == "__main__":
    unittest.main()
