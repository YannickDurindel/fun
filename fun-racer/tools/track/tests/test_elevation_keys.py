"""[[elevation.key]] and [[elevation.smooth]]: pinning the height profile, on synthetic laps."""
import math
import unittest

import helpers  # noqa: F401  (sets sys.path)
from lib import centreline, geom, recipe
from lib.net import BuildError

STEP = 2.0
N = 2000                      # a 4000 m lap
LENGTH = N * STEP
BASE = {"osm": {"relation": 1}, "length_m": LENGTH}


def keys(*entries, join_m=recipe.KEY_JOIN):
    """Validated, sorted key list (as the build gets it) and the join limit."""
    r = recipe.from_dict("somewhere", {**BASE, "elevation": {"key": list(entries), "key_join_m": join_m}})
    return r.elev_keys, float(r.elev_key_join_m)


def apply(y, *entries, join_m=recipe.KEY_JOIN):
    """The profile as track.json gets it: keys applied, then re-zeroed on the finish line."""
    out = centreline.apply_elevation_keys(y, STEP, *keys(*entries, join_m=join_m))
    return [v - out[0] for v in out], out


def grades(y):
    return [(y[(k + 1) % len(y)] - y[k - 1]) / (2 * STEP) for k in range(len(y))]


def hills(amplitude=6.0, base=400.0):
    return [base + amplitude * math.sin(2 * math.pi * k / N) + 2.0 * math.sin(14 * math.pi * k / N) for k in range(N)]


class ElevationKeyTest(unittest.TestCase):
    def test_no_keys_returns_the_profile_untouched(self):
        y = hills()
        self.assertIs(centreline.apply_elevation_keys(y, STEP, [], 250.0), y)

    def test_a_single_key_pins_the_height_and_fades_out(self):
        y = hills()
        rel, out = apply(y, {"s": 1000.0, "y": 20.0, "blend": 100.0})
        self.assertAlmostEqual(rel[500], 20.0, places=6)
        delta = out[500] - y[500]
        self.assertAlmostEqual(out[475] - y[475], 0.5 * delta, delta=0.01)    # half way down the blend
        for k in (0, 449, 551, 1500):                                        # outside: the DEM profile
            self.assertEqual(out[k], y[k])
        self.assertLess(max(abs(g) for g in grades(out)[440:560]), abs(delta) * math.pi / 200.0 + 0.2)

    def test_a_key_off_the_sample_grid_is_met_between_samples(self):
        y = [400.0] * N
        rel, _ = apply(y, {"s": 1001.0, "y": 10.0})
        self.assertAlmostEqual(0.5 * (rel[500] + rel[501]), 10.0, delta=0.01)

    def test_abs_key(self):
        y = hills()
        _, out = apply(y, {"s": 3000.0, "abs": 380.0})
        self.assertAlmostEqual(out[1500], 380.0, places=6)

    def test_joined_keys_make_the_declared_ramp(self):
        # A flat DEM (the smoothing took the hill out); three keys 80 m apart declare a ramp of
        # 12 m in 80 m. It must come out that steep: nothing smooths the profile after the keys.
        y = [400.0] * N
        rel, _ = apply(y, {"s": 920.0, "y": 0.0}, {"s": 1000.0, "y": 0.0}, {"s": 1080.0, "y": 12.0},
                       {"s": 1160.0, "y": 12.0})
        g = grades(rel)
        self.assertAlmostEqual(rel[500], 0.0, places=6)
        self.assertAlmostEqual(rel[540], 12.0, places=6)
        self.assertGreater(max(g), 0.20)                    # 15 % average, steeper in the middle
        self.assertLess(max(g), 0.23)                       # ... by the cubic's 3/2 at most
        # Monotone: no dip before the ramp, no overshoot above the crest key.
        self.assertGreaterEqual(min(rel[460:581]), -1e-9)
        self.assertLessEqual(max(rel[460:581]), 12.0 + 1e-9)
        self.assertGreaterEqual(min(g[461:580]), -1e-9)

    def test_keys_further_apart_than_the_limit_are_not_joined(self):
        y = hills()
        entries = [{"s": 1000.0, "y": 5.0, "blend": 50.0}, {"s": 1400.0, "y": 9.0, "blend": 50.0}]
        _, apart = apply(y, *entries)
        self.assertEqual(apart[600], y[600])                # between them: the DEM, untouched
        _, joined = apply(y, entries[0], {**entries[1], "join": True})
        self.assertNotEqual(joined[600], y[600])            # one curve from key to key
        lo, hi = sorted((joined[500], joined[700]))
        self.assertTrue(all(lo - 1e-9 <= v <= hi + 1e-9 for v in joined[500:701]))
        _, limit = apply(y, *entries, join_m=500.0)         # the stated limit does the same
        self.assertEqual(limit, joined)
        _, never = apply(y, entries[0], {**entries[1], "join": False}, join_m=500.0)
        self.assertEqual(never, apart)

    def test_every_key_is_met_when_blends_overlap(self):
        y = hills()
        rel, _ = apply(y, {"s": 1000.0, "y": 3.0, "blend": 400.0}, {"s": 1300.0, "y": -4.0, "blend": 400.0},
                       join_m=0.0)
        self.assertAlmostEqual(rel[500], 3.0, places=6)
        self.assertAlmostEqual(rel[650], -4.0, places=6)

    def test_keys_around_the_finish_line(self):
        # A ramp across the line: keys before it, on it and after it. y is relative to the line
        # as it ends up, so the key on it is 0 and the others come out as written.
        y = hills()
        rel, out = apply(y, {"s": 3900.0, "y": -6.0}, {"s": 0.0, "y": 0.0}, {"s": 100.0, "y": 6.0})
        self.assertAlmostEqual(rel[1950], -6.0, places=6)
        self.assertAlmostEqual(rel[0], 0.0, places=9)
        self.assertAlmostEqual(rel[50], 6.0, places=6)
        self.assertAlmostEqual(out[0], y[0], places=6)      # the line itself did not move
        g = grades(rel)
        self.assertTrue(all(v > 0.0 for v in g[1951:] + g[:50]))    # one climb through s = 0

    def test_a_key_near_the_finish_line_moves_the_origin(self):
        # An absolute key 20 m after the line lifts the line too (its blend reaches it); the
        # relative key elsewhere must still be 15 m above the finish line of the result.
        y = [400.0] * N
        rel, out = apply(y, {"s": 20.0, "abs": 404.0, "blend": 60.0}, {"s": 2000.0, "y": 15.0})
        self.assertAlmostEqual(out[10], 404.0, places=6)
        self.assertGreater(out[0], 402.0)
        self.assertAlmostEqual(rel[1000], 15.0, places=5)
        self.assertAlmostEqual(out[1000] - out[0], 15.0, places=5)

    def test_relative_keys_that_span_the_line_need_one_on_it(self):
        y = [400.0] * N
        with self.assertRaises(BuildError) as e:
            apply(y, {"s": 3900.0, "y": 2.0}, {"s": 100.0, "y": 4.0})
        self.assertIn("s = 0", str(e.exception))
        rel, _ = apply(y, {"s": 3900.0, "y": -2.0}, {"s": 100.0, "y": 2.0})    # symmetric: consistent
        self.assertAlmostEqual(rel[0], 0.0, places=9)

    def test_recipe_validation(self):
        ok = {"s": 100.0, "y": 1.0}
        self.assertEqual(keys({"s": 300.0, "abs": 5.0}, ok)[0][0]["s"], 100.0)      # sorted by s
        for bad in ({"s": 100.0}, {"s": 100.0, "y": 1.0, "abs": 2.0}, {"s": -1.0, "y": 1.0},
                    {"s": LENGTH, "y": 1.0}, {"s": 100.0, "y": 1.0, "blend": 0.0},
                    {"s": 100.0, "y": 1.0, "join": "yes"}, {"s": 100.0, "y": 1.0, "offset": 2.0},
                    {"s": 0.0, "y": 1.0}):
            with self.assertRaises(BuildError, msg=str(bad)):
                keys(bad)
        with self.assertRaises(BuildError):
            keys(ok, dict(ok))                                                    # the same s twice
        with self.assertRaises(BuildError):
            recipe.from_dict("somewhere", {**BASE, "elevation": {"key_join_m": -1.0}})


class LocalSmoothingTest(unittest.TestCase):
    def setUp(self):
        # A sharp crest at s = 2000 on a noisy lap.
        self.raw = [30.0 - 0.15 * abs(k * STEP - 2000.0) if abs(k * STEP - 2000.0) < 200.0 else 0.0 for k in range(N)]
        self.raw = [v + (0.8 if k % 7 == 0 else 0.0) for k, v in enumerate(self.raw)]
        self.lap = geom.gauss_periodic(self.raw, sigma=45.0 / STEP)

    def test_no_stretch_returns_the_profile_untouched(self):
        self.assertIs(centreline.apply_local_smoothing(self.lap, self.raw, self.lap, STEP, []), self.lap)

    def test_a_stretch_keeps_the_crest_sharp(self):
        y = centreline.apply_local_smoothing(self.lap, self.raw, self.lap, STEP,
                                             [{"s": [1900.0, 2100.0], "sigma_m": 8.0, "blend": 50.0}])
        self.assertLess(self.lap[1000], 25.5)               # the lap's 45 m blurs the crest away
        self.assertGreater(y[1000], 28.5)                   # 8 m keeps it
        for k in (0, 500, 920, 1080, 1500):                 # beyond the blend: the lap's smoothing
            self.assertEqual(y[k], self.lap[k])
        local = geom.gauss_periodic(self.raw, sigma=8.0 / STEP)
        self.assertAlmostEqual(y[1010], local[1010], places=9)      # inside: the local smoothing
        self.assertTrue(min(self.lap[940], local[940]) <= y[940] <= max(self.lap[940], local[940]))

    def test_sigma_zero_is_the_raw_profile_and_the_stretch_may_wrap(self):
        y = centreline.apply_local_smoothing(self.lap, self.raw, self.lap, STEP,
                                             [{"s": [3950.0, 50.0], "sigma_m": 0.0, "blend": 20.0}])
        self.assertAlmostEqual(y[0], self.raw[0], places=9)
        self.assertAlmostEqual(y[1990], self.raw[1990], places=9)
        self.assertEqual(y[1000], self.lap[1000])

    def test_the_smoothing_after_an_override_does_not_blur_the_stretch(self):
        # An override anywhere smooths the whole lap again (10 m); the stretch is added after it.
        over = centreline.apply_elevation_overrides(self.lap, STEP, [{"s": [3000.0, 3200.0], "offset": 2.0}])
        y = centreline.apply_local_smoothing(over, self.raw, self.lap, STEP,
                                             [{"s": [1900.0, 2100.0], "sigma_m": 8.0, "blend": 50.0}])
        plain = centreline.apply_local_smoothing(self.lap, self.raw, self.lap, STEP,
                                                 [{"s": [1900.0, 2100.0], "sigma_m": 8.0, "blend": 50.0}])
        self.assertGreater(y[1000], 28.5)
        self.assertAlmostEqual(y[1000] - over[1000], plain[1000] - self.lap[1000], places=9)
        self.assertAlmostEqual(y[1550], over[1550], places=9)               # the override is still there
        self.assertAlmostEqual(over[1550], self.lap[1550] + 2.0, delta=0.05)

    def test_recipe_validation(self):
        def rec(o):
            return recipe.from_dict("somewhere", {**BASE, "elevation": {"smooth": [o]}})
        self.assertEqual(rec({"s": [100.0, 300.0], "sigma_m": 10.0}).elev_smooth[0]["sigma_m"], 10.0)
        for bad in ({"s": [100.0, 300.0]}, {"s": [100.0], "sigma_m": 5.0}, {"s": [100.0, 300.0], "sigma_m": -1.0},
                    {"s": [100.0, LENGTH], "sigma_m": 5.0}, {"s": [100.0, 300.0], "sigma_m": 5.0, "width": 3}):
            with self.assertRaises(BuildError, msg=str(bad)):
                rec(bad)


if __name__ == "__main__":
    unittest.main()
