"""Measured road cross-sections ([road] sections = "lidar", cad/track/road_sections.py): the fit
recovers a known surface from a lidar grid, copes with noise, outliers and holes, the road mesh
is built from it with seamless chunks, and a track without the key builds exactly as before.
The fixture tests/fixtures/tracks/measured_oval (make_measured_oval.py) is rebuilt here into a
temporary folder and compared with the committed one."""
import importlib.util
import json
import os
import struct
import tempfile
import unittest

import helpers
from lib import recipe
from lib.net import BuildError

HAVE_NUMPY = importlib.util.find_spec("numpy") is not None
HAVE_SCIPY = importlib.util.find_spec("scipy") is not None
FIXTURES = os.path.join(helpers.ROOT, "tests", "fixtures", "tracks")


def _generator():
    spec = importlib.util.spec_from_file_location("make_measured_oval",
                                                  os.path.join(FIXTURES, "make_measured_oval.py"))
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    return gen


def _glb_nodes(path):
    """{node name: [(material, positions (n, 3))]} of a GLB written by cad/track/road_glb.py."""
    import numpy as np
    data = open(path, "rb").read()
    jlen = struct.unpack_from("<I", data, 12)[0]
    gj = json.loads(data[20:20 + jlen])
    bin0 = 20 + jlen + 8
    out = {}
    for node in gj["nodes"]:
        if "mesh" not in node:
            continue
        prims = []
        for p in gj["meshes"][node["mesh"]]["primitives"]:
            a = gj["accessors"][p["attributes"]["POSITION"]]
            bv = gj["bufferViews"][a["bufferView"]]
            off = bin0 + bv.get("byteOffset", 0) + a.get("byteOffset", 0)
            pos = np.frombuffer(data, "<f4", a["count"] * 3, off).reshape(-1, 3)
            prims.append((gj["materials"][p["material"]]["name"], pos))
        out[node["name"]] = prims
    return out


class SectionsRecipeTest(unittest.TestCase):
    def _recipe(self, road):
        return recipe.from_dict("red_bull_ring", {"osm": {"relation": 1}, "road": road})

    def test_sections_key(self):
        self.assertEqual(self._recipe({"sections": "lidar"}).road["sections"], "lidar")
        self._recipe({"sections": "analytic"})
        with self.assertRaisesRegex(BuildError, "road.sections"):
            self._recipe({"sections": "survey"})
        with self.assertRaisesRegex(BuildError, "max_bank"):
            self._recipe({"sections": "lidar", "max_bank": 0.3})


@unittest.skipUnless(HAVE_NUMPY and HAVE_SCIPY, "the measured sections need numpy and scipy (use the project venv)")
class FitTest(unittest.TestCase):
    """road_sections.fit() on the fixture oval's grid with a surface chosen per test."""

    @classmethod
    def setUpClass(cls):
        import numpy as np
        import road_sections
        cls.np, cls.rs, cls.gen = np, road_sections, _generator()
        saved = cls.gen.oval.ROAD
        cls.gen.oval.ROAD = {}
        try:
            cls.track = cls.gen.oval.build_track()
        finally:
            cls.gen.oval.ROAD = saved
        P = np.array([p["p"] for p in cls.track["points"]])
        T = np.roll(P, -1, 0) - np.roll(P, 1, 0)
        T /= np.linalg.norm(T, axis=1, keepdims=True)
        Rh = np.cross(T, [0.0, 1.0, 0.0])
        Rh /= np.linalg.norm(Rh, axis=1, keepdims=True)
        cls.P, cls.T, cls.Rh = P, T, Rh
        cls.hw = np.full(len(P), 6.5)
        cls.s = np.arange(len(P)) * cls.track["step"]
        cls.lat = cls.hw[:, None] * road_sections.columns(cls.hw)[None, :]

    def _fit(self, height, bank=None):
        with tempfile.TemporaryDirectory() as tmp:
            self.gen.write_grid(self.track, tmp, height)
            grid = self.rs.RoadGrid.load(tmp)
            bank = self.np.zeros(len(self.P)) if bank is None else bank
            return self.rs.fit(grid, self.P, self.T, self.Rh, self.hw, bank)

    def _truth(self, fn):
        np = self.np
        return fn(np.repeat(self.s[:, None], self.lat.shape[1], 1), self.lat)

    def test_sampled_every_half_metre_meshed_every_metre(self):
        np = self.np
        hw = np.array([4.0, 7.5])
        u = self.rs.columns(hw)
        f = self.rs.sample_columns(hw)
        self.assertEqual(len(u) % 2, 1)
        self.assertEqual(u[len(u) // 2], 0.0)
        self.assertLessEqual(7.5 * (u[1] - u[0]), self.rs.MESH_SPACING + 1e-9)
        self.assertLessEqual(7.5 * (f[1] - f[0]), self.rs.COLUMN_SPACING + 1e-9)
        self.assertTrue(np.allclose(f[::self.rs.MESH_EVERY], u))

    def test_recovers_crown_and_camber(self):
        def surface(s, lat):
            return self.gen.surface(s, lat, 6.5)
        r = self._fit(surface)
        err = self.np.abs(r["xsec"] - self._truth(surface))
        self.assertLess(float(err.max()), 0.012, "largest error against the known surface (m)")
        self.assertLess(float(self.np.sqrt((err ** 2).mean())), 0.003)
        self.assertEqual(r["stats"]["fallback_points"], 0)
        # The bank is the mean cross slope: 4 % into the right-handers (left edge higher).
        i = int(round(325.7 / self.track["step"]))
        self.assertAlmostEqual(float(r["bank"][i]), self.np.arctan(0.04), delta=0.002)

    def test_noise_and_outliers_are_rejected(self):
        np = self.np
        rng = np.random.default_rng(3)

        def surface(s, lat):
            h = self.gen.surface(s, lat, 6.5) + rng.normal(0.0, 0.005, s.size)
            car = rng.random(s.size) < 0.004
            h[car] += rng.uniform(0.3, 1.2, car.sum())        # parked cars, kerb artefacts
            return h
        r = self._fit(surface)
        err = np.abs(r["xsec"] - self._truth(lambda s, l: self.gen.surface(s, l, 6.5)))
        self.assertLess(float(np.percentile(err, 99)), 0.01)
        self.assertLess(float(err.max()), 0.02)

    def test_short_gaps_are_interpolated(self):
        np = self.np

        def surface(s, lat):
            h = self.gen.surface(s, lat, 6.5)
            h[(s > 600.0) & (s < 640.0)] = np.nan              # no ground: a bridge deck, a tunnel
            return h
        r = self._fit(surface)
        inside = (self.s > 605.0) & (self.s < 635.0)
        self.assertTrue(np.all(r["measured"][inside] == 0.0))
        self.assertGreater(r["stats"]["interpolated_points"], 10)
        self.assertEqual(r["stats"]["fallback_points"], 0)
        # The straight's crown carries on across the gap.
        err = np.abs(r["xsec"] - self._truth(lambda s, l: self.gen.surface(s, l, 6.5)))
        self.assertLess(float(err[inside].max()), 0.01)

    def test_long_gaps_fall_back_to_the_analytic_section_without_a_step(self):
        np = self.np
        bank = np.full(len(self.P), 0.015)

        def surface(s, lat):
            h = self.gen.surface(s, lat, 6.5)
            h[(s > 500.0) & (s < 800.0)] = np.nan              # no lidar over 300 m
            return h
        r = self._fit(surface, bank)
        x = r["xsec"]
        inside = (self.s > 530.0) & (self.s < 770.0)
        analytic = -self.lat * np.sin(bank)[:, None]
        self.assertLess(float(np.abs(x[inside] - analytic[inside]).max()), 0.0011)
        self.assertGreater(r["stats"]["fallback_points"], 100)
        # Blended in over BLEND_POINTS: no jump between neighbouring sections around the gap
        # (a ramp of a few cm per section, no more than the fixture's own camber transitions).
        jump = np.abs(np.diff(x, axis=0)).max(1)
        near = (self.s[:-1] > 440.0) & (self.s[:-1] < 860.0)
        self.assertLess(float(jump[near].max()), 0.03)

    def test_implausible_slopes_are_clamped(self):
        np = self.np

        def surface(s, lat):
            # A 1 m wall across the right half of the road (a mis-classified barrier).
            return self.gen.surface(s, lat, 6.5) + np.where((s > 300.0) & (s < 310.0) & (lat > 3.0), 1.0, 0.0)
        r = self._fit(surface)
        dl = np.diff(self.lat, axis=1)
        slope = np.abs(np.diff(r["xsec"], axis=1)) / dl
        self.assertLessEqual(float(slope.max()), self.rs.MAX_SLOPE + 0.003)

    def test_centre_far_from_the_centreline_is_not_this_road(self):
        np = self.np

        def surface(s, lat):
            # The grid sees the ground 3 m under the lap: a bridge whose deck the lidar missed.
            return self.gen.surface(s, lat, 6.5) - np.where((s > 900.0) & (s < 960.0), 3.0, 0.0)
        r = self._fit(surface)
        inside = (self.s > 905.0) & (self.s < 955.0)
        self.assertTrue(np.all(r["measured"][inside] == 0.0))
        self.assertLess(float(np.abs(r["xsec"]).max()), 0.4)


@unittest.skipUnless(HAVE_NUMPY and HAVE_SCIPY, "the road step needs numpy and scipy (use the project venv)")
class MeasuredOvalTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gen = _generator()
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = cls.tmp.name
        cls.logs = []
        cls.built = cls.gen.build(cls.out, log=cls.logs.append)
        with open(os.path.join(cls.out, "road_profile.json")) as f:
            cls.profile = json.load(f)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_fixture_is_current(self):
        for name in ("track.json", "road_profile.json", "road_mesh.glb", "terrain.json",
                     "terrain_height.bin", "terrain_dist.bin", "terrain_far.bin", "track_info.json"):
            with open(os.path.join(self.out, name), "rb") as a, \
                    open(os.path.join(FIXTURES, "measured_oval", name), "rb") as b:
                self.assertEqual(a.read(), b.read(), f"{name}: run tests/fixtures/tracks/make_measured_oval.py")

    def test_profile_keys(self):
        pr = self.profile
        n = len(pr["width"])
        k = pr["xsec_columns"]
        self.assertEqual(len(pr["xsec"]), n)
        self.assertTrue(all(len(row) == k for row in pr["xsec"]))
        self.assertEqual(len(pr["xsec_measured"]), n)
        self.assertIn("xsec", pr["convention"])

    def test_mesh_is_the_profile_and_chunks_share_their_sections(self):
        import numpy as np
        pr = self.profile
        with open(os.path.join(self.out, "track.json")) as f:
            P = np.array([p["p"] for p in json.load(f)["points"]])
        n, k = len(P), pr["xsec_columns"]
        T = np.roll(P, -1, 0) - np.roll(P, 1, 0)
        T /= np.linalg.norm(T, axis=1, keepdims=True)
        Rh = np.cross(T, [0.0, 1.0, 0.0])
        Rh /= np.linalg.norm(Rh, axis=1, keepdims=True)
        lat = 0.5 * np.array(pr["width"])[:, None] * np.linspace(-1.0, 1.0, k)[None, :]
        V = P[:, None, :] + Rh[:, None, :] * lat[..., None]
        V[..., 1] += np.array(pr["xsec"])
        nodes = _glb_nodes(os.path.join(self.out, "road_mesh.glb"))
        chunks = pr["chunks"]
        for c, (a, b) in enumerate(chunks):
            mat, pos = nodes[f"road_{c:02d}"][0]
            self.assertEqual(mat, "tarmac")
            pos = pos.reshape(-1, k, 3)
            self.assertLess(float(np.abs(pos - V[np.arange(a, b + 1) % n]).max()), 1e-4)
            nxt = nodes[f"road_{(c + 1) % len(chunks):02d}"][0][1].reshape(-1, k, 3)
            # The last section of a chunk is the first of the next one, bit for bit (the lap
            # closes on the same heights at s = length).
            if c + 1 < len(chunks):
                self.assertTrue(np.array_equal(pos[-1], nxt[0]), f"step at the join of chunks {c} and {c + 1}")
            else:
                self.assertTrue(np.array_equal(pos[-1][:, 1], nxt[0][:, 1]), "step where the lap closes")
        # The verges start at the measured edges.
        for c in range(len(chunks)):
            grass = nodes[f"road_{c:02d}"][1][1]
            edge = V[chunks[c][0], 0]
            self.assertLess(float(np.linalg.norm(grass - edge, axis=1).min()), 1e-4)

    def test_terrain_stays_below_the_measured_road(self):
        import numpy as np
        meta = self.built["road"]
        self.assertIsNotNone(meta["sections"])
        tj = json.load(open(os.path.join(self.out, "terrain.json")))["near"]
        h = np.fromfile(os.path.join(self.out, "terrain_height.bin"), "<f4").reshape(tj["nz"], tj["nx"])
        pr = self.profile
        with open(os.path.join(self.out, "track.json")) as f:
            P = np.array([p["p"] for p in json.load(f)["points"]])
        x = np.array(pr["xsec"])
        lat = 0.5 * np.array(pr["width"])[:, None] * np.linspace(-1.0, 1.0, x.shape[1])[None, :]
        T = np.roll(P, -1, 0) - np.roll(P, 1, 0)
        Rh = np.cross(T, [0.0, 1.0, 0.0])
        Rh /= np.linalg.norm(Rh, axis=1, keepdims=True)
        V = P[:, None, :] + Rh[:, None, :] * lat[..., None]
        gx = (V[..., 0] - tj["x0"]) / tj["step"]
        gz = (V[..., 2] - tj["z0"]) / tj["step"]
        i, j = np.floor(gx).astype(int), np.floor(gz).astype(int)
        fx, fz = gx - i, gz - j
        ground = ((h[j, i] * (1 - fx) + h[j, i + 1] * fx) * (1 - fz)
                  + (h[j + 1, i] * (1 - fx) + h[j + 1, i + 1] * fx) * fz)
        self.assertGreater(float((P[:, None, 1] + x - ground).min()), 0.05)


@unittest.skipUnless(HAVE_NUMPY, "the road step needs numpy (use the project venv)")
class AnalyticUnchangedTest(unittest.TestCase):
    def test_without_the_key_the_module_is_not_used(self):
        import road
        self.assertIsNone(road.measured_sections({}, None, "x", None, None, None, None, None))
        self.assertIsNone(road.measured_sections(None, None, "x", None, None, None, None, None))
        self.assertIsNone(road.measured_sections({"sections": "analytic"}, None, "x", None, None, None, None, None))
        with self.assertRaisesRegex(ValueError, "sections"):
            road.measured_sections({"sections": "laser"}, None, "x", None, None, None, None, None)

    def test_only_recipes_with_the_key_have_sections(self):
        tracks = os.path.join(helpers.ROOT, "assets", "tracks")
        for name in sorted(os.listdir(tracks)):
            path = os.path.join(tracks, name, "road_profile.json")
            if not os.path.exists(path):
                continue
            src = os.path.join(recipe.RECIPE_DIR, name + ".toml")
            want = os.path.exists(src) and recipe.load(name).road.get("sections") == "lidar"
            with open(path) as f:
                self.assertEqual("xsec" in json.load(f), want, name)

if __name__ == "__main__":
    unittest.main()
