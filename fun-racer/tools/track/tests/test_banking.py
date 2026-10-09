"""Declared banking: the limit and the roll-rate rule of cad/track/banking.py, the banked verge
of cad/track/road.py, the bank in track.json and the terrain under a banked road. The geometry
is checked on the banked oval fixture (tests/fixtures/tracks/make_banked_oval.py), rebuilt
here into a temporary folder and compared with the committed one."""
import importlib.util
import json
import math
import os
import struct
import tempfile
import unittest

import helpers
from lib import recipe, terrain
from lib.net import BuildError

HAVE_NUMPY = importlib.util.find_spec("numpy") is not None
FIXTURES = os.path.join(helpers.ROOT, "tests", "fixtures", "tracks")


def _recipe(road):
    return recipe.from_dict("red_bull_ring", {"osm": {"relation": 1}, "road": road})


class BankRecipeTest(unittest.TestCase):
    def test_steep_bank_must_be_declared(self):
        with self.assertRaisesRegex(BuildError, "road.max_bank"):
            _recipe({"override": [{"s": [100.0, 300.0], "bank": 0.2}]})
        with self.assertRaisesRegex(BuildError, "road.max_bank"):
            _recipe({"bank_keys": [[0.0, 0.0], [500.0, -0.31]]})
        with self.assertRaisesRegex(BuildError, "exceeds the track's limit"):
            _recipe({"max_bank": 0.25, "override": [{"s": [100.0, 300.0], "bank": 0.3}]})
        r = _recipe({"max_bank": 0.34, "shoulder": 4.0, "override": [{"s": [100.0, 300.0], "bank": -0.33}]})
        self.assertEqual(r.road["max_bank"], 0.34)
        # The automatic limit needs no declaration.
        _recipe({"override": [{"s": [100.0, 300.0], "bank": 0.03}]})

    def test_max_bank_and_shoulder_ranges(self):
        for road in ({"max_bank": 0.41}, {"max_bank": 0.02}, {"max_bank": True}, {"shoulder": -1.0},
                     {"shoulder": 11.0}):
            with self.assertRaises(BuildError, msg=str(road)):
                _recipe(road)


@unittest.skipUnless(HAVE_NUMPY, "cad/track/banking.py needs numpy (use the project venv)")
class BankProfileTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import numpy as np
        import banking
        cls.np, cls.banking = np, banking
        cls.track = helpers.rbr_track()
        cls.n = len(cls.track["points"])
        cls.length = cls.track["length"]
        cls.step = cls.track["step"]
        cls.s = np.arange(cls.n) * cls.step
        cls.curv = np.array([p["curvature"] for p in cls.track["points"]])
        cls.start_s = cls.track["start_s"]

    def _profile(self, cfg, notes=None):
        return self.banking.profile(self.s, self.length, self.curv, self.start_s, cfg, notes)[0]

    def _roll(self, bank):
        return float(self.np.abs(self.np.roll(bank, -1) - bank).max() / self.step)

    def test_declared_bank_is_built(self):
        cfg = {"max_bank": 0.34, "override": [{"s": [1300.0, 1500.0], "bank": 0.33, "blend": 60.0}]}
        notes = []
        bank = self._profile(cfg, notes)
        self.assertAlmostEqual(float(bank[int(1400.0 / self.step)]), 0.33, places=6)
        self.assertEqual(notes, [])
        self.assertTrue(self.banking.declared(cfg))
        # Everywhere else the automatic camber, still within its own limit.
        auto = self._profile({})
        far = self.np.abs(self.s - 1400.0) > 200.0
        self.assertTrue(self.np.array_equal(bank[far], auto[far]))
        self.assertLessEqual(float(self.np.abs(auto).max()), self.banking.MAX_BANK + 1e-9)
        self.assertFalse(self.banking.declared({}))

    def test_undeclared_or_over_the_ceiling_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "max_bank"):
            self._profile({"override": [{"s": [1300.0, 1500.0], "bank": 0.2}]})
        with self.assertRaisesRegex(ValueError, "max_bank"):
            self._profile({"max_bank": 0.5})
        # A declared limit does not loosen the automatic camber.
        loose = self._profile({"max_bank": 0.4, "camber_gain": 10.0})
        self.assertLessEqual(float(self.np.abs(loose).max()), self.banking.MAX_BANK + 1e-9)

    def test_short_blend_is_lengthened_to_the_roll_rate(self):
        cfg = {"max_bank": 0.34, "override": [{"s": [1300.0, 1500.0], "bank": 0.33, "blend": 10.0}]}
        notes = []
        bank = self._profile(cfg, notes)
        self.assertEqual(len(notes), 1)
        self.assertIn("blend lengthened from 10", notes[0])
        self.assertLessEqual(self._roll(bank), self.banking.MAX_ROLL_RATE * (1.0 + 1e-6))
        # It uses the rate it is allowed: the ramp is not longer than it has to be.
        self.assertGreater(self._roll(bank), 0.8 * self.banking.MAX_ROLL_RATE)
        self.assertAlmostEqual(float(bank[int(1400.0 / self.step)]), 0.33, places=6)
        # A blend that is long enough is left alone, to the bit.
        same = dict(cfg, override=[dict(cfg["override"][0], blend=80.0)])
        notes = []
        self._profile(same, notes)
        self.assertEqual(notes, [])

    def test_keys_that_twist_too_fast_are_rejected(self):
        keys = [[0.0, 0.0], [1000.0, 0.0], [1010.0, 0.3], [1200.0, 0.3], [1400.0, 0.0]]
        with self.assertRaisesRegex(ValueError, "twist faster"):
            self._profile({"max_bank": 0.34, "bank_keys": keys})
        keys[2][0] = 1060.0
        bank = self._profile({"max_bank": 0.34, "bank_keys": keys})
        self.assertLessEqual(self._roll(bank), self.banking.MAX_ROLL_RATE)

    def test_verge_shape_is_smooth(self):
        import road
        np = self.np
        d = np.linspace(0.0, 30.0, 30001)
        g = road.verge_shape(d, 3.0)
        slope = np.diff(g) / np.diff(d)
        # In the road's plane on the shoulder, level (no extra slope) beyond the blend, and in
        # between the slope only ever falls, without a step: no shelf, cliff or trough.
        self.assertTrue(np.allclose(slope[d[1:] <= 3.0], 1.0))
        self.assertTrue(np.allclose(slope[d[:-1] >= 3.0 + road.VERGE_BLEND], 0.0))
        self.assertLessEqual(float(np.diff(slope).max()), 1e-9)
        self.assertLess(float(np.abs(np.diff(slope)).max()), 2.0 * 1e-3 / road.VERGE_BLEND)
        self.assertAlmostEqual(float(g[-1]), 3.0 + 0.5 * road.VERGE_BLEND, places=9)


@unittest.skipUnless(HAVE_NUMPY, "the road step needs numpy (use the project venv)")
class BankedOvalTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("make_banked_oval",
                                                      os.path.join(FIXTURES, "make_banked_oval.py"))
        cls.gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.gen)
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = cls.tmp.name
        cls.logs = []
        cls.built = cls.gen.build(cls.out, log=cls.logs.append)
        with open(os.path.join(cls.out, "road_profile.json")) as f:
            cls.profile = json.load(f)
        cls.track = cls.built["track"]

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_fixture_is_current(self):
        for name in ("track.json", "road_profile.json", "road_mesh.glb", "terrain.json",
                     "terrain_height.bin", "terrain_dist.bin", "terrain_far.bin", "track_info.json"):
            with open(os.path.join(self.out, name), "rb") as a, \
                    open(os.path.join(FIXTURES, "banked_oval", name), "rb") as b:
                self.assertEqual(a.read(), b.read(), f"{name}: run tests/fixtures/tracks/make_banked_oval.py")

    def test_track_json_carries_the_built_bank(self):
        bank = [p["bank"] for p in self.track["points"]]
        self.assertEqual(bank, self.profile["bank"])
        self.assertAlmostEqual(max(bank), self.gen.BANK, places=6)
        # The road step refuses a track.json whose bank is not the recipe's.
        import road
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            stale = json.loads(json.dumps(self.track))
            for p in stale["points"]:
                p["bank"] = 0.0
            with open(os.path.join(tmp, "track.json"), "w") as f:
                json.dump(stale, f)
            with self.assertRaisesRegex(ValueError, "centreline"):
                road.build(Path(tmp) / "track.json", Path(tmp), self.gen.ROAD, "banked_oval")

    def test_undeclared_tracks_keep_bank_zero_and_the_plain_profile(self):
        from lib import centreline
        rec = recipe.load("red_bull_ring")
        track = helpers.rbr_track()
        n = len(track["points"])
        banks = centreline.track_json_banks(rec, n, track["step"], track["length"], track["start_s"],
                                            [p["curvature"] for p in track["points"]])
        self.assertEqual(banks, [0.0] * n)
        self.assertTrue(all(p["bank"] == 0.0 for p in track["points"]))
        with open(os.path.join(helpers.RBR, "road_profile.json")) as f:
            committed = json.load(f)
        self.assertFalse(any(k.startswith("verge_slope") or k in ("verge_shoulder", "verge_blend")
                             for k in committed))

    def test_verge_continues_the_banking(self):
        pr = self.profile
        i = int(self.gen.T1_S[0] + 0.5 * self.gen.TURN) // 2      # middle of the east banking
        fall = pr["verge_drop"] / pr["verge_width"]
        # Left = outside of the right-hander: the verge rises at the road's own slope.
        self.assertAlmostEqual(pr["verge_slope_left"][i] - fall, math.tan(self.gen.BANK), delta=2e-3)
        self.assertAlmostEqual(pr["verge_slope_right"][i] - fall, -math.tan(self.gen.BANK), delta=2e-3)
        self.assertEqual(pr["verge_shoulder"], 3.0)
        # On the straight between the bankings it is the plain verge, give or take the crossfall.
        j = int(self.gen.T1_S[1] + 0.5 * self.gen.STRAIGHT) // 2
        self.assertLess(abs(pr["verge_slope_left"][j] - fall), 0.02)

    def test_terrain_stays_below_road_and_verge(self):
        meta = self.built["terrain"]["near"]
        nx, nz, step, x0, z0 = meta["nx"], meta["nz"], meta["step"], meta["x0"], meta["z0"]
        with open(os.path.join(self.out, "terrain_height.bin"), "rb") as f:
            h = struct.unpack(f"<{nx * nz}f", f.read())
        prof, has_profile = terrain.load_profile(self.track, self.out)
        self.assertTrue(has_profile and "slope_l" in prof)
        corridor = terrain.make_corridor(self.track, prof)

        def mesh_height(x, z):
            """The near mesh as scripts/track/terrain.gd builds it (cells split b-c)."""
            u, v = (x - x0) / step, (z - z0) / step
            i, j = int(u), int(v)
            fu, fv = u - i, v - j
            a, b, c, d = h[j * nx + i], h[j * nx + i + 1], h[(j + 1) * nx + i], h[(j + 1) * nx + i + 1]
            if fu + fv <= 1.0:
                return a + (b - a) * fu + (c - a) * fv
            return d + (c - d) * (1.0 - fu) + (b - d) * (1.0 - fv)

        pts = self.track["points"]
        n = len(pts)
        worst, deepest, probes = math.inf, 0.0, 0
        for i in range(0, n, 2):
            a, b = pts[i - 1]["p"], pts[(i + 1) % n]["p"]
            tx, tz = b[0] - a[0], b[2] - a[2]
            l = math.hypot(tx, tz)
            rx, rz = -tz / l, tx / l                   # right of the race direction, plan view
            hw = 0.5 * prof["width"][i] * math.cos(prof["bank"][i])
            lat = -(hw + 29.0)
            while lat <= hw + 29.0:
                x, z = pts[i]["p"][0] + rx * lat, pts[i]["p"][2] + rz * lat
                dist, i0, target, w = corridor.probe(x, z)
                self.assertEqual(w, 0.0)
                gap = target + terrain.CLEARANCE - mesh_height(x, z)   # surface above the terrain
                worst, deepest, probes = min(worst, gap), max(deepest, gap), probes + 1
                lat += 0.7
        self.assertGreater(probes, 25000)
        # Sampled between the refinement's own samples: within a few cm of the full clearance.
        self.assertGreater(worst, terrain.CLEARANCE - 0.06, "terrain reaches the road / verge surface")
        self.assertLess(deepest, 3.0, "terrain far below the road")
        self.assertTrue(any("banked corridor" in line for line in self.logs))

    def test_unrefined_terrain_would_poke_through(self):
        """What the second pass is for: the same grid from vertex targets alone cuts the apron."""
        prof, _ = terrain.load_profile(self.track, self.out)
        corridor = terrain.make_corridor(self.track, prof)
        i = int(self.gen.T1_S[0] + 0.5 * self.gen.TURN) // 2
        p = self.track["points"][i]["p"]
        mx = [math.floor(p[0] / 10.0) * 10.0 + 10.0 * k for k in range(-6, 7)]
        mz = [math.floor(p[2] / 10.0) * 10.0 + 10.0 * k for k in range(-6, 7)]
        heights, nearest = [], []
        for z in mz:
            for x in mx:
                d, i0, y, w = corridor.probe(x, z)
                heights.append(y)
                nearest.append(i0)
        lowered, worst = terrain.refine_banked(heights, nearest, mx, mz, corridor, prof, helpers.silent)
        self.assertGreater(lowered, 10)
        self.assertGreater(worst, terrain.CLEARANCE, "a triangle rose through the surface before the pass")
        again, worst = terrain.refine_banked(heights, nearest, mx, mz, corridor, prof, helpers.silent)
        self.assertEqual(again, 0)


if __name__ == "__main__":
    unittest.main()
