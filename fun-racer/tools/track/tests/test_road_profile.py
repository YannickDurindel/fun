"""Road cross-section: recipe tables reproduce the Red Bull Ring, defaults behave sensibly."""
import importlib.util
import json
import os
import unittest

import helpers
from lib import recipe

HAVE_NUMPY = importlib.util.find_spec("numpy") is not None


@unittest.skipUnless(HAVE_NUMPY, "cad/track/banking.py needs numpy (use the project venv)")
class RoadProfileTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import numpy as np
        import banking
        cls.np, cls.banking = np, banking
        cls.track = helpers.rbr_track()
        cls.n = len(cls.track["points"])
        cls.length = cls.track["length"]
        cls.s = np.arange(cls.n) * cls.track["step"]
        cls.curv = np.array([p["curvature"] for p in cls.track["points"]])
        cls.start_s = cls.track["start_s"]

    def test_recipe_tables_reproduce_the_committed_profile(self):
        with open(os.path.join(helpers.RBR, "road_profile.json")) as f:
            committed = json.load(f)
        cfg = recipe.load("red_bull_ring").road
        bank, width = self.banking.profile(self.s, self.length, self.curv, self.start_s, cfg)
        self.assertEqual(self.np.round(width, 4).tolist(), committed["width"])
        self.assertEqual(self.np.round(bank, 6).tolist(), committed["bank"])

    def test_default_bank(self):
        np = self.np
        bank, _ = self.banking.profile(self.s, self.length, self.curv, self.start_s, {})
        self.assertLessEqual(float(np.abs(bank).max()), self.banking.MAX_BANK + 1e-9)

        def at(s):
            return float(bank[int(s / self.track["step"])])
        # Right-handers lean left-edge-up (+), left-handers the other way; tight corners reach
        # the cap, and the grid drains left.
        self.assertAlmostEqual(at(1395.2), 0.03, delta=0.004)      # Remus hairpin, right
        self.assertAlmostEqual(at(2202.2), 0.03, delta=0.004)      # Schlossgold, right
        self.assertLess(at(2814.4), -0.02)                         # Rauch, left
        self.assertLess(at(3099.5), -0.02)                         # Wuerth, left
        self.assertAlmostEqual(at(self.start_s - 60.0), -0.015, delta=0.002)
        # Straights keep a drainage crossfall except where it changes side.
        flat = np.abs(bank) < 0.005
        self.assertLess(flat.mean(), 0.06)
        # Smooth: no steps between neighbouring points.
        self.assertLess(float(np.abs(np.diff(np.append(bank, bank[0]))).max()), 0.004)

    def test_default_width(self):
        _, width = self.banking.profile(self.s, self.length, self.curv, self.start_s, {})
        step = self.track["step"]
        self.assertAlmostEqual(float(width[int(self.start_s / step)]), 15.0, places=6)
        self.assertAlmostEqual(float(width[int(2000.0 / step)]), 13.0, places=6)
        self.assertGreaterEqual(float(width.min()), 13.0)
        _, wide = self.banking.profile(self.s, self.length, self.curv, self.start_s, {"base_width": 12.0})
        self.assertAlmostEqual(float(wide[int(2000.0 / step)]), 12.0, places=6)

    def test_overrides(self):
        step = self.track["step"]
        cfg = {"override": [{"s": [1900.0, 2100.0], "width": 16.0, "bank": 0.0, "blend": 30.0},
                            {"s": [4300.0, 20.0], "width": 14.0}]}       # wraps the finish line
        bank, width = self.banking.profile(self.s, self.length, self.curv, self.start_s, cfg)
        base_bank, base_width = self.banking.profile(self.s, self.length, self.curv, self.start_s, {})
        self.assertAlmostEqual(float(width[int(2000.0 / step)]), 16.0, places=6)
        self.assertAlmostEqual(float(bank[int(2000.0 / step)]), 0.0, places=6)
        self.assertAlmostEqual(float(width[int(1500.0 / step)]), float(base_width[int(1500.0 / step)]), places=6)
        self.assertAlmostEqual(float(bank[int(2400.0 / step)]), float(base_bank[int(2400.0 / step)]), places=6)
        self.assertAlmostEqual(float(width[0]), 14.0, places=6)
        self.assertAlmostEqual(float(width[int(4310.0 / step)]), 14.0, places=6)

    def test_bank_over_the_limit_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "hard limit"):
            self.banking.profile(self.s, self.length, self.curv, self.start_s,
                                 {"override": [{"s": [100.0, 300.0], "bank": 0.2}]})


if __name__ == "__main__":
    unittest.main()
