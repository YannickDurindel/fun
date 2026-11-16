"""LiDAR HD ground model (lib/lidar.py) on a synthetic tile, and the lidar_hd dataset hook.

The synthetic tile: a 120 m straight of a small rectangular lap near Le Mans (so the
Lambert-93 maths is the real one), a tilted plane with a bump, 64 ground points per m^2 with
2 cm noise, scattered outliers, a misclassified 1 m patch, vegetation, a small hole, a big hole,
a footbridge over the road and a road bridge carrying the lap over a 5 m deep valley.
"""
import json
import math
import os
import tempfile
import unittest

import numpy as np

import helpers
from lib import lidar, net

try:
    import laspy  # noqa: F401
    import pyproj  # noqa: F401
    import scipy  # noqa: F401
    HAVE_DEPS = True
except ImportError:
    HAVE_DEPS = False

ORIGIN = (47.95, 0.2075)
BASE = 50.0
ROAD = dict(lidar.ROAD, reach=12.0)
TERRAIN = dict(lidar.TERRAIN, reach=30.0, tile=64)
OVER = (30.0, 34.0)          # x range of the footbridge (6 m above the road)
DECK = (80.0, 92.0)          # x range of the road bridge (valley 5 m below)
BIG_HOLE = (50.0, 58.0, -2.0, 6.0)    # x0, x1, z0, z1
SMALL_HOLE = (66.0, 1.0, 0.5)         # x, z, radius
CAR = (106.0, -3.0)                   # 1 m patch of class-2 points 0.4 m too high


def truth(x, z):
    """The ground surface (absolute m) of the synthetic tile, valley excluded."""
    return BASE + 0.02 * x + 0.01 * z + 0.15 * np.exp(-((x - 20.0) ** 2 + (z + 2.0) ** 2) / 18.0)


def synthetic_track():
    pts = []
    corners = [(0.0, 0.0), (120.0, 0.0), (120.0, -60.0), (0.0, -60.0)]
    s = 0.0
    for (ax, az), (bx, bz) in zip(corners, corners[1:] + corners[:1]):
        n = int(round(math.hypot(bx - ax, bz - az) / 2.0))
        for k in range(n):
            x, z = ax + (bx - ax) * k / n, az + (bz - az) * k / n
            pts.append({"s": s, "p": [x, 0.0, z]})
            s += 2.0
    return {"origin_latlon": list(ORIGIN), "origin_elevation_m": BASE, "points": pts,
            "frame": "test"}


def write_tile(path, frame, rng):
    import laspy
    dens = 64.0
    n = int(dens * 124 * 24)
    x = rng.uniform(-2.0, 122.0, n)
    z = rng.uniform(-12.0, 12.0, n)
    h = truth(x, z) + rng.normal(0.0, 0.02, n)
    cls = np.full(n, 2, np.uint8)
    keep = np.ones(n, bool)
    # holes
    bx0, bx1, bz0, bz1 = BIG_HOLE
    keep &= ~((x > bx0) & (x < bx1) & (z > bz0) & (z < bz1))
    sx, sz, sr = SMALL_HOLE
    keep &= np.hypot(x - sx, z - sz) > sr
    # footbridge: no ground seen right under it near the road; the deck 6 m up (class 17)
    under = (x > OVER[0]) & (x < OVER[1])
    keep &= ~(under & (np.abs(z) < 6.0))
    # road bridge: deck at road level (class 17) for |z| <= 5, valley 5 m down beside it
    on_br = (x > DECK[0]) & (x < DECK[1])
    deck = on_br & (np.abs(z) <= 5.0)
    cls[deck] = 17
    h[on_br & ~deck] -= 5.0
    x, z, h, cls = x[keep], z[keep], h[keep], cls[keep]
    # footbridge deck points
    m = int(dens * 4 * 24 * 0.5)
    fx = rng.uniform(*OVER, m)
    fz = rng.uniform(-12.0, 12.0, m)
    fh = truth(fx, fz) + 6.0 + rng.normal(0.0, 0.02, m)
    # scattered outliers (class 2, +/- 0.5 m), a misclassified car roof, vegetation
    k = len(x) // 50
    oi = rng.choice(len(x), k, replace=False)
    h = h.copy()
    h[oi] += rng.choice([-0.5, 0.5], k)
    c = int(dens * 1.0)
    cx = CAR[0] + rng.uniform(-0.5, 0.5, c)
    cz = CAR[1] + rng.uniform(-0.5, 0.5, c)
    ch = truth(cx, cz) + 0.4
    v = 3000
    vx = rng.uniform(0.0, 120.0, v)
    vz = rng.uniform(-12.0, 12.0, v)
    vh = truth(vx, vz) + rng.uniform(0.5, 8.0, v)
    X = np.concatenate([x, fx, cx, vx])
    Z = np.concatenate([z, fz, cz, vz])
    H = np.concatenate([h, fh, ch, vh])
    C = np.concatenate([cls, np.full(m, 17, np.uint8), np.full(c, 2, np.uint8), np.full(v, 5, np.uint8)])
    e, nn = frame.xz_to_l93(X, Z)
    hdr = laspy.LasHeader(point_format=6, version="1.4")
    hdr.scales = np.array([0.01, 0.01, 0.01])
    hdr.offsets = np.array([math.floor(e.min()), math.floor(nn.min()), 0.0])
    las = laspy.LasData(hdr)
    las.x, las.y, las.z = e, nn, H
    las.classification = C
    las.write(path)


@unittest.skipUnless(HAVE_DEPS, "laspy / pyproj / scipy not installed")
class SyntheticTileTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.dir = cls.tmp.name
        cls.track = synthetic_track()
        cls.frame = lidar.Frame(ORIGIN, 1.0)
        tile = os.path.join(cls.dir, "synthetic.las")
        write_tile(tile, cls.frame, np.random.default_rng(7))
        cls.report = lidar.build(cls.track, 1.0, [tile], cls.dir, road=ROAD, terrain=TERRAIN,
                                 log=helpers.silent)
        cls.road = lidar.Grid.load(os.path.join(cls.dir, "lidar_road.json"))
        cls.ter = lidar.Grid.load(os.path.join(cls.dir, "lidar_terrain.json"))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()
        lidar._loaded.clear()

    def cells_where(self, x0, x1, z0, z1):
        c = self.road.cell
        ix = np.arange(int(math.floor(x0 / c)), int(math.ceil(x1 / c)))
        iz = np.arange(int(math.floor(z0 / c)), int(math.ceil(z1 / c)))
        IX, IZ = np.meshgrid(ix, iz)
        IX, IZ = IX.ravel(), IZ.ravel()
        return IX, IZ, (IX + 0.5) * c, (IZ + 0.5) * c

    def test_measured_cells_follow_the_surface(self):
        IX, IZ, X, Z = self.cells_where(2.0, 118.0, -10.0, 10.0)
        h = self.road.cells(IX, IZ)
        f = self.road.flags(IX, IZ)
        m = (f == lidar.FLAG_MEASURED) & ~((X > DECK[0] - 1) & (X < DECK[1] + 1))
        err = h[m] - truth(X[m], Z[m])
        self.assertGreater(m.sum(), 20000)
        self.assertLess(float(np.sqrt(np.mean(err ** 2))), 0.02)
        self.assertLess(float(np.abs(err).max()), 0.1)      # every +/- 0.5 m outlier is gone

    def test_misclassified_patch_is_rejected_and_filled(self):
        IX, IZ, X, Z = self.cells_where(CAR[0] - 0.4, CAR[0] + 0.4, CAR[1] - 0.4, CAR[1] + 0.4)
        h = self.road.cells(IX, IZ)
        self.assertTrue(np.isfinite(h).all())
        self.assertLess(float(np.abs(h - truth(X, Z)).max()), 0.08)
        self.assertIn(lidar.FLAG_FILLED, set(self.road.flags(IX, IZ).tolist()))

    def test_small_hole_filled_big_hole_left_empty(self):
        sx, sz, sr = SMALL_HOLE
        IX, IZ, X, Z = self.cells_where(sx - 0.2, sx + 0.2, sz - 0.2, sz + 0.2)
        self.assertTrue((self.road.flags(IX, IZ) == lidar.FLAG_FILLED).all())
        self.assertLess(float(np.abs(self.road.cells(IX, IZ) - truth(X, Z)).max()), 0.03)
        bx0, bx1, bz0, bz1 = BIG_HOLE
        IX, IZ, X, Z = self.cells_where(bx0 + 2.5, bx1 - 2.5, bz0 + 2.5, bz1 - 2.5)
        self.assertTrue(np.isnan(self.road.cells(IX, IZ)).all())
        self.assertTrue((self.road.flags(IX, IZ) == lidar.FLAG_NONE).all())

    def test_bridges(self):
        kinds = {b["kind"]: b for b in self.report["bridges"]}
        self.assertEqual(set(kinds), {"over", "deck"})
        self.assertAlmostEqual(kinds["over"]["deck_above_line_m"], 6.0, delta=0.3)
        s0, s1 = kinds["deck"]["s"]
        self.assertLess(abs(s0 - DECK[0]), 3.0)
        self.assertLess(abs(s1 - DECK[1]), 3.0)
        # under the footbridge: filled across from the road on both sides
        IX, IZ, X, Z = self.cells_where(OVER[0] + 0.5, OVER[1] - 0.5, -4.0, 4.0)
        self.assertTrue((self.road.flags(IX, IZ) == lidar.FLAG_UNDER).all())
        self.assertLess(float(np.abs(self.road.cells(IX, IZ) - truth(X, Z)).max()), 0.05)
        # on the road bridge: the deck, not the valley 5 m below
        IX, IZ, X, Z = self.cells_where(DECK[0] + 1.0, DECK[1] - 1.0, -4.0, 4.0)
        h = self.road.cells(IX, IZ)
        self.assertTrue(np.isfinite(h).all())
        self.assertLess(float(np.abs(h - truth(X, Z)).max()), 0.1)
        self.assertTrue((self.road.flags(IX, IZ) == lidar.FLAG_DECK).mean() > 0.9)

    def test_bilinear_sample_and_y(self):
        x = np.array([10.1, 44.7, 101.3])
        z = np.array([0.3, -3.2, 7.9])
        self.assertLess(float(np.abs(self.road.height(x, z) - truth(x, z)).max()), 0.03)
        self.assertLess(float(np.abs(self.road.y(x, z) - (truth(x, z) - BASE)).max()), 0.03)
        self.assertTrue(np.isnan(self.road.height(np.array([60.0]), np.array([-40.0]))[0]))

    def test_terrain_grid(self):
        x = np.array([5.0, 40.0, 112.0])
        z = np.array([-8.0, 9.0, 4.0])
        self.assertLess(float(np.abs(self.ter.height(x, z) - truth(x, z)).max()), 0.05)
        meta = self.ter.meta
        self.assertEqual(meta["format"], lidar.FORMAT)
        self.assertEqual(meta["cell"], 1.0)
        self.assertIn("IGN", meta["attribution"])

    def test_header(self):
        meta = self.road.meta
        self.assertEqual(meta["cell"], 0.25)
        self.assertEqual(meta["origin_latlon"], list(ORIGIN))
        self.assertEqual(meta["origin_elevation_m"], BASE)
        st = meta["stats"]
        self.assertGreater(st["points_per_m2"]["median"], 40.0)
        self.assertGreater(st["rejected_points"], 1000)
        for t in meta["tiles"]:
            self.assertEqual(len(t), 5)
        lidar.rebase(os.path.join(self.dir, "lidar_road.json"), 51.0)
        g = lidar.Grid.load(os.path.join(self.dir, "lidar_road.json"))
        x, z = np.array([10.0]), np.array([1.0])
        self.assertAlmostEqual(float(g.y(x, z)[0]), float(truth(x, z)[0]) - 51.0, delta=0.03)
        lidar.rebase(os.path.join(self.dir, "lidar_road.json"), BASE)

    def test_lidar_hd_dataset(self):
        # The grids sit next to track.json, i.e. in the parent of the raw/ cache.
        raw = os.path.join(self.dir, "raw")
        os.makedirs(raw, exist_ok=True)
        fetcher = net.Fetcher(raw, offline=True, log=helpers.silent)
        proj = self.frame.proj
        xs = np.array([12.0, 64.0, 86.0, 110.0])
        zs = np.array([0.0, 0.5, 0.0, -1.0])
        lat, lon = proj.to_latlon(xs, zs)
        latlon = list(zip(lat.tolist(), lon.tolist()))
        lidar._loaded.clear()
        h = net.fetch_elevations(fetcher, latlon, "lidar_hd", "dem")
        for got, want in zip(h, truth(xs, zs)):
            self.assertAlmostEqual(got, float(want), delta=0.05)
        t = net.fetch_elevations(fetcher, latlon[:2], "lidar_hd", "terrain")
        for got, want in zip(t, truth(xs[:2], zs[:2])):
            self.assertAlmostEqual(got, float(want), delta=0.15)
        # outside both grids: RGE ALTI, which an offline build does not have
        far = list(zip(*proj.to_latlon(np.array([60.0]), np.array([-400.0]))))
        with self.assertRaises(net.BuildError):
            net.fetch_elevations(fetcher, [(float(far[0][0]), float(far[0][1]))], "lidar_hd", "dem")
        self.assertIn("IGN", net.attribution("lidar_hd"))


@unittest.skipUnless(HAVE_DEPS, "laspy / pyproj / scipy not installed")
class PiecesTest(unittest.TestCase):
    def test_tile_round_trip(self):
        rng = np.random.default_rng(1)
        h = (40.0 + np.cumsum(rng.normal(0, 0.01, (64, 64)), axis=1)).astype(np.float32)
        h[rng.random((64, 64)) < 0.2] = np.nan
        h[5] = np.nan
        f = np.where(np.isfinite(h), 1, 0).astype(np.uint8)
        base, _ = lidar._tile_base(h)
        h2, f2 = lidar._decode(lidar._encode(h, f, base, 0.001), 64, base, 0.001)
        ok = np.isfinite(h)
        self.assertTrue((np.isfinite(h2) == ok).all())
        self.assertLess(float(np.abs(h2[ok] - h[ok]).max()), 0.0006)
        self.assertTrue((f2 == f).all())

    def test_group_and_masked_median(self):
        idx = np.array([3, 1, 3, 3, 1, 7])
        z = np.array([5.0, 2.0, 1.0, 9.0, 4.0, 0.5], np.float32)
        u, med, cnt, order, start = lidar.group_median(idx, z)
        self.assertEqual(u.tolist(), [1, 3, 7])
        self.assertEqual(med.tolist(), [3.0, 5.0, 0.5])
        keep = np.ones(len(z), bool)
        keep[np.where(z[order] == 9.0)[0]] = False       # cell 3 keeps 1 and 5
        keep[np.where(z[order] == 0.5)[0]] = False       # cell 7 keeps nothing
        m2, kc = lidar.masked_median(z[order], start, cnt, keep)
        self.assertEqual(kc.tolist(), [2, 2, 0])
        self.assertEqual(m2[:2].tolist(), [3.0, 3.0])
        self.assertTrue(np.isnan(m2[2]))

    def test_plane_fit_is_exact_on_a_plane_and_robust(self):
        zz, xx = np.mgrid[0:30, 0:30].astype(float)
        h = 2.0 + 0.1 * xx - 0.05 * zz
        h[10, 10] += 1.0
        h[20, 5] = np.nan
        p = lidar.plane_fit(h)
        ok = np.isfinite(p)
        ref = 2.0 + 0.1 * xx - 0.05 * zz
        self.assertLess(float(np.abs(p[ok] - ref[ok]).max()), 1e-6)

    def test_tile_fit_matches_pyproj(self):
        fr = lidar.Frame(ORIGIN, 1.0003)
        fit = fr.tile_fit(491000.0, 6762000.0, 492000.0, 6763000.0)
        e = np.array([491000.0, 491517.3, 491999.0])
        n = np.array([6762000.0, 6762480.1, 6762999.0])
        x0, z0 = fr.l93_to_xz(e, n)
        x1, z1 = fit(e, n)
        self.assertLess(float(np.abs(x1 - x0).max()), 1e-3)
        self.assertLess(float(np.abs(z1 - z0).max()), 1e-3)


LE_MANS = os.path.join(helpers.ROOT, "assets", "tracks", "wec_le_mans_survey")


@unittest.skipUnless(os.path.exists(os.path.join(LE_MANS, "lidar_road.json")), "no Le Mans grids")
class LeMansGridsTest(unittest.TestCase):
    def test_grids_match_the_track(self):
        road = lidar.Grid.load(os.path.join(LE_MANS, "lidar_road.json"))
        with open(os.path.join(LE_MANS, "track.json"), encoding="utf-8") as f:
            track = json.load(f)
        self.assertEqual(road.meta["format"], lidar.FORMAT)
        pts = np.array([p["p"] for p in track["points"]])[::25]
        y = road.y(pts[:, 0], pts[:, 2])
        ok = np.isfinite(y)
        self.assertGreater(ok.mean(), 0.97)
        # the built centreline is the grid (smoothed): within a few cm almost everywhere
        self.assertLess(float(np.median(np.abs(y[ok] - pts[ok, 1]))), 0.1)
        for name in ("lidar_road.bin", "lidar_terrain.bin"):
            self.assertLess(os.path.getsize(os.path.join(LE_MANS, name)), 20e6)


if __name__ == "__main__":
    unittest.main()
