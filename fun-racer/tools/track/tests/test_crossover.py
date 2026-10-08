"""Crossovers: elevation overrides, finding where a lap crosses itself, and the bridge.

All on a synthetic figure of eight (a lemniscate), offline.
"""
import importlib.util
import math
import unittest

import helpers  # noqa: F401  (sets sys.path)
from lib import centreline, geom, recipe
from lib.net import BuildError

HAVE_NUMPY = importlib.util.find_spec("numpy") is not None
STEP = 2.0


def figure_of_eight(a=400.0):
    """Evenly spaced (x, z) samples of a lemniscate of Bernoulli (crossing at the origin)."""
    raw = []
    for k in range(4000):
        t = 2.0 * math.pi * k / 4000 + 0.5
        d = 1.0 + math.sin(t) ** 2
        raw.append((a * math.cos(t) / d, a * math.sin(t) * math.cos(t) / d))
    pts, step, _ = geom.respace(raw, STEP)
    return pts, step


class ElevationOverrideTest(unittest.TestCase):
    def test_no_overrides_returns_the_profile_untouched(self):
        y = [1.0, 2.0, 3.0]
        self.assertIs(centreline.apply_elevation_overrides(y, STEP, []), y)

    def test_offset_lifts_the_stretch_and_fades_out(self):
        y = centreline.apply_elevation_overrides([0.0] * 1000, STEP, [{"s": [800.0, 900.0], "offset": 5.0, "blend": 100.0}])
        self.assertAlmostEqual(y[425], 5.0, places=2)          # s = 850, inside
        self.assertAlmostEqual(y[375], 2.5, delta=0.1)         # s = 750, half way down the ramp
        self.assertAlmostEqual(y[250], 0.0, places=6)          # s = 500, untouched
        self.assertLess(max(abs(b - a) for a, b in zip(y, y[1:])) / STEP, 0.09)   # ramp grade

    def test_straighten_removes_a_dip(self):
        y = [10.0 - 4.0 * math.exp(-((k * STEP - 600.0) / 30.0) ** 2) for k in range(1000)]
        out = centreline.apply_elevation_overrides(y, STEP, [{"s": [450.0, 750.0], "straighten": True}])
        self.assertAlmostEqual(out[300], 10.0, delta=0.05)
        self.assertAlmostEqual(out[100], y[100], places=6)

    def test_stretch_may_wrap_the_finish_line(self):
        y = centreline.apply_elevation_overrides([0.0] * 1000, STEP, [{"s": [1950.0, 50.0], "offset": 2.0, "blend": 20.0}])
        self.assertAlmostEqual(y[0], 2.0, places=2)
        self.assertAlmostEqual(y[500], 0.0, places=6)

    def test_recipe_validation(self):
        base = {"osm": {"relation": 1}, "length_m": 5000}
        r = recipe.from_dict("x", dict(base, elevation={"override": [{"s": [10, 60], "offset": 3.0}]}))
        self.assertEqual(r.elev_overrides, [{"s": [10, 60], "offset": 3.0}])
        for bad in ({"s": [10, 60]}, {"s": [10], "offset": 1.0}, {"s": [10, 6000], "offset": 1.0},
                    {"s": [10, 60], "offset": 1.0, "blend": -5}, {"s": [10, 60], "offset": 1.0, "height": 2}):
            with self.assertRaises(BuildError, msg=str(bad)):
                recipe.from_dict("x", dict(base, elevation={"override": [bad]}))


class FindCrossingsTest(unittest.TestCase):
    def test_a_simple_loop_has_none(self):
        circle = [(300.0 * math.cos(2 * math.pi * k / 942), 300.0 * math.sin(2 * math.pi * k / 942)) for k in range(942)]
        self.assertEqual(centreline.find_crossings(circle, [0.0] * 942, STEP), [])

    def test_figure_of_eight(self):
        pts, step = figure_of_eight()
        n = len(pts)
        i0 = min(range(n), key=lambda k: math.hypot(*pts[k]))
        # The first passage through the origin is 7 m higher than the second.
        y = [7.0 * max(0.0, 1.0 - abs(k - i0) * step / 200.0) for k in range(n)]
        found = centreline.find_crossings(pts, y, step)
        self.assertEqual(len(found), 1)
        c = found[0]
        self.assertAlmostEqual(c["s_upper"], i0 * step, delta=step)
        self.assertAlmostEqual(abs(c["s_upper"] - c["s_lower"]), n * step / 2.0, delta=4 * step)
        self.assertAlmostEqual(c["clearance"], 7.0, delta=0.2)
        self.assertAlmostEqual(c["angle_deg"], 90.0, delta=2.0)


@unittest.skipUnless(HAVE_NUMPY, "cad/track/bridge.py needs numpy (use the project venv)")
class BridgeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import numpy as np
        import bridge
        cls.np, cls.bridge = np, bridge
        pts, cls.step = figure_of_eight()
        n = cls.n = len(pts)
        i0 = min(range(n), key=lambda k: math.hypot(*pts[k]))
        y = [7.0 * max(0.0, 1.0 - abs(k - i0) * cls.step / 200.0) for k in range(n)]
        cls.crossings = centreline.find_crossings(pts, y, cls.step)
        cls.P = np.array([[p[0], h, p[1]] for p, h in zip(pts, y)])
        T = np.roll(cls.P, -1, 0) - np.roll(cls.P, 1, 0)
        cls.T = T / np.linalg.norm(T, axis=1, keepdims=True)
        Rh = np.cross(cls.T, np.array([0.0, 1.0, 0.0]))
        cls.Rh = Rh / np.linalg.norm(Rh, axis=1, keepdims=True)
        cls.hw = np.full(n, 6.5)
        cls.ext_l, cls.ext_r = np.full(n, 30.0), np.full(n, 30.0)
        # What verge_extent() leaves at a crossing: no verge where the other road is.
        for ext in (cls.ext_l, cls.ext_r):
            for k in (i0, (i0 + n // 2) % n):
                for d in range(-20, 21):
                    ext[(k + d) % n] = min(ext[(k + d) % n], max(0.0, abs(d) * cls.step * 0.8 - 6.0))
        cls.bridges = bridge.bridge_spans(cls.crossings, cls.P, cls.Rh, cls.hw, cls.ext_l, cls.ext_r, cls.step, 30.0)

    def test_one_bridge_on_the_upper_road(self):
        self.assertEqual(len(self.bridges), 1)
        b = self.bridges[0]
        self.assertLess(b["deck"][0], b["span"][0])
        self.assertLess(b["span"][0], b["s_upper"])
        self.assertLess(b["s_upper"], b["span"][1])
        self.assertLess(b["span"][1], b["deck"][1])
        self.assertLess(b["deck"][1] - b["deck"][0], 2 * self.bridge.CROSS_WINDOW)

    def test_no_verge_on_the_span(self):
        b = self.bridges[0]
        i0, i1 = round(b["span"][0] / self.step), round(b["span"][1] / self.step)
        self.assertEqual(float(self.ext_l[i0:i1 + 1].max()), 0.0)
        self.assertEqual(float(self.ext_r[i0:i1 + 1].max()), 0.0)
        # Far from the crossing nothing changed.
        far = (i0 + self.n // 4) % self.n
        self.assertEqual(float(self.ext_l[far]), 30.0)

    def test_deck_mesh(self):
        np = self.np
        b = self.bridges[0]
        R = self.Rh.copy()
        prim = self.bridge.deck_primitive(b, self.P, self.T, R, self.Rh, self.hw, self.step)
        self.assertTrue(np.isfinite(prim.positions).all() and np.isfinite(prim.normals).all())
        self.assertGreater(len(prim.indices), 100)
        # The underpass is open: no concrete within the lower road's width near the crossing,
        # between the lower road's surface and the underside of the slab.
        il = round(b["s_lower"] / self.step) % self.n
        d = prim.positions - self.P[il]
        along = d @ self.T[il]
        lat = d @ self.Rh[il]
        inside = (np.abs(along) < 8.0) & (np.abs(lat) < 6.5) & (d[:, 1] > 0.1) & (d[:, 1] < 7.0 - b["thickness"] - 0.6)
        self.assertFalse(bool(inside.any()))
        # ... and has a wall on both sides, from below the road up to the slab.
        for side in (-1.0, 1.0):
            wall = (np.abs(along) < 4.0) & (np.abs(lat * side - (6.5 + b["underpass_margin"])) < 0.2)
            self.assertTrue(bool(wall.any()), f"no underpass wall on side {side}")
            self.assertLess(float(d[wall][:, 1].min()), 0.0)
            self.assertGreater(float(d[wall][:, 1].max()), 5.0)


if __name__ == "__main__":
    unittest.main()
