"""Orthophoto edges, kerbs and run-off (lib.ortho), offline, on a synthetic orthophoto block: a
ring road of known width drawn in the colours of the BD ORTHO of the Sarthe (blue-grey
asphalt, white lines, a red / white kerb, gravel, dry grass, a tree shadow)."""
import json
import math
import os
import tempfile
import unittest

import numpy as np

import helpers  # noqa: F401  (sys.path)
from lib import ortho

X0, Y0 = 400000, 6700000          # south-west corner of the synthetic 400 m block
CX, CY = X0 + 200.0, Y0 + 200.0   # ring centre (Lambert-93)
R = 80.0                          # centreline radius, m
LEFT, RIGHT = 4.5, 5.5            # true edge offsets: left = inside of the ring (anticlockwise)
ASPHALT = (88, 95, 108)
WHITE = (205, 210, 205)
RED = (190, 45, 40)
GRAVEL = (198, 185, 150)
GRASS = (130, 132, 118)
KERB_W = 1.2                      # m, left side, angles 0.6..1.2 rad
GRAVEL_W = 12.0                   # m, right side beyond the edge, angles 2.0..2.8 rad


def ring_image():
    """2000 x 2000 RGB block (row 0 north) of the synthetic scene."""
    n = ortho.BLOCK_PX
    e = X0 + (np.arange(n) + 0.5) * ortho.PIX
    nn = Y0 + ortho.BLOCK_M - (np.arange(n) + 0.5) * ortho.PIX
    E, N = np.meshgrid(e, nn)
    r = np.hypot(E - CX, N - CY)
    ang = np.mod(np.arctan2(N - CY, E - CX), 2 * np.pi)
    img = np.empty((n, n, 3), np.uint8)
    img[:] = GRASS
    # driving anticlockwise: left = towards the centre (r < R), right = outside (r > R)
    off_left = R - r                                # > 0 inside
    road = (off_left <= LEFT) & (-off_left <= RIGHT)
    img[road] = ASPHALT
    # white edge lines 0.2 m wide just inside both edges (the edge is their outer side)
    line = road & ((off_left > LEFT - 0.2) | (-off_left > RIGHT - 0.2))
    img[line] = WHITE
    # centre dashes
    dash = road & (np.abs(off_left) < 0.08) & (np.mod(ang * R, 6.0) < 3.0)
    img[dash] = WHITE
    # red / white kerb on the left (inside) between 0.6 and 1.2 rad, stripes 1 m along
    kz = (off_left > LEFT) & (off_left <= LEFT + KERB_W) & (ang > 0.6) & (ang < 1.2)
    stripe = np.mod(ang * R, 2.0) < 1.0
    img[kz & stripe] = RED
    img[kz & ~stripe] = WHITE
    # gravel trap on the right (outside) between 2.0 and 2.8 rad
    gz = (-off_left > RIGHT) & (-off_left <= RIGHT + GRAVEL_W) & (ang > 2.0) & (ang < 2.8)
    img[gz] = GRAVEL
    # a dark tree shadow over the right edge between 4.0 and 4.15 rad
    sh = (np.abs(-off_left - RIGHT) < 3.0) & (ang > 4.0) & (ang < 4.15)
    img[sh] = (30, 35, 30)
    return img


def ring_frame():
    """Frame of the ring, anticlockwise, stations every ~2 m; track frame = Lambert-93 shifted
    (x = E - CX, z = -(N - CY))."""
    n = int(round(2 * math.pi * R / 2.0))
    t = np.arange(n) / n * 2 * math.pi
    P = np.column_stack([R * np.cos(t), -R * np.sin(t)])
    s = t * R

    def to_l93(x, z):
        return np.asarray(x, float) + CX, -np.asarray(z, float) + CY
    return ortho.Frame(P, s, to_l93, length=2 * math.pi * R), t


class OrthoTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from PIL import Image
        cls.tmp = tempfile.TemporaryDirectory()
        Image.fromarray(ring_image()).save(os.path.join(cls.tmp.name, f"ortho_{X0}_{Y0}.tif"))
        cls.mosaic = ortho.Mosaic(cls.tmp.name)
        cls.frame, cls.t = ring_frame()
        cls.prof = ortho.build_profiles(cls.frame, cls.mosaic, half=12.0, log=None)
        cls.edges = ortho.trace_edges(cls.prof, log=None)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_frame_normals_and_jacobian(self):
        f = self.frame
        # anticlockwise in plan view: the left normal points to the centre
        c = np.column_stack([np.zeros(f.n), np.zeros(f.n)])
        to_c = (c - f.P) / np.linalg.norm(c - f.P, axis=1)[:, None]
        self.assertGreater(np.min(np.sum(to_c * f.L, axis=1)), 0.999)
        np.testing.assert_allclose(f.J[:, :, 0], np.tile([1.0, 0.0], (f.n, 1)), atol=1e-9)
        np.testing.assert_allclose(f.J[:, :, 1], np.tile([0.0, -1.0], (f.n, 1)), atol=1e-9)

    def test_mosaic_georeferencing(self):
        # the pixel whose centre is (X0 + 0.1, Y0 + 399.9) is the block's top-left one
        img = ring_image()
        rgb, ok = self.mosaic.sample(np.array([X0 + 0.1, X0 + 100.3]),
                                     np.array([Y0 + 399.9, Y0 + 250.1]))
        self.assertTrue(ok.all())
        np.testing.assert_allclose(rgb[0], img[0, 0], atol=1)
        np.testing.assert_allclose(rgb[1], img[int((400 - 250.1) / 0.2), int(100.3 / 0.2)],
                                   atol=1)
        # outside the cached blocks: not valid
        _, ok = self.mosaic.sample(np.array([X0 - 50.0]), np.array([Y0 + 10.0]))
        self.assertFalse(ok.any())

    def test_classes_of_the_sarthe_palette(self):
        px = np.array([[ASPHALT, WHITE, RED, GRAVEL, GRASS, (115, 192, 230), (240, 215, 60),
                        (30, 30, 30)]], np.uint8)
        c = ortho.classify(px)[0]
        self.assertEqual(list(c), [ortho.ASPHALT, ortho.WHITE, ortho.RED, ortho.GRAVEL,
                                   ortho.GRASS, ortho.BLUE, ortho.YELLOW, ortho.SHADOW])

    def test_edges_within_10_cm(self):
        e = self.edges
        ok = ~e["flag_left"] & ~e["flag_right"]
        self.assertGreater(ok.mean(), 0.9)
        self.assertLess(np.abs(e["left"][ok] - LEFT).max(), 0.15)
        self.assertLess(np.abs(e["right"][ok] - RIGHT).max(), 0.15)
        w = e["left"] + e["right"]
        self.assertLess(abs(np.median(w) - (LEFT + RIGHT)), 0.1)

    def test_shadow_lowers_confidence_and_is_interpolated(self):
        e = self.edges
        sel = (self.t > 4.02) & (self.t < 4.13)
        self.assertTrue(e["flag_right"][sel].any())
        self.assertLess(np.abs(e["right"][sel] - RIGHT).max(), 0.3)

    def test_kerb_found(self):
        ks = ortho.kerb_stations(self.prof, self.edges)
        segs = ortho.kerb_segments(self.frame.s, ks, self.frame.length)
        left = [g for g in segs if g["side"] == "left" and g["kind"] == "red_white"]
        self.assertEqual(len(left), 1, segs)
        g = left[0]
        self.assertAlmostEqual(g["s0"], 0.6 * R, delta=3.0)
        self.assertAlmostEqual(g["s1"], 1.2 * R, delta=3.0)
        self.assertAlmostEqual(g["width"], KERB_W, delta=0.3)
        self.assertEqual(g["colour"], "red")
        self.assertFalse([g for g in segs if g["side"] == "right" and g["kind"] != "sausage"])

    def test_gravel_runoff(self):
        ks = ortho.kerb_stations(self.prof, self.edges)
        surf, offs = ortho.runoff_surfaces(self.frame, self.mosaic, half=30.0, log=None)
        ro = ortho.runoff_stations(surf, offs, self.edges, ks)
        polys = ortho.runoff_polygons(self.frame, self.frame.s, self.edges, ks, ro)
        gravel = [p for p in polys if p["kind"] == "gravel"]
        self.assertEqual(len(gravel), 1, [(p["kind"], p["side"], p["s0"]) for p in polys])
        g = gravel[0]
        self.assertEqual(g["side"], "right")
        self.assertAlmostEqual(g["s0"], 2.0 * R, delta=4.0)
        self.assertAlmostEqual(g["s1"], 2.8 * R, delta=4.0)
        self.assertAlmostEqual(g["u1"], GRAVEL_W, delta=0.6)
        # the ring is outside the road: every outline point lies at r >= R + RIGHT - 0.3
        r = np.hypot(*np.array(g["ring"]).T)
        self.assertGreater(r.min(), R + RIGHT - 0.3)
        self.assertLess(r.max(), R + RIGHT + GRAVEL_W + 0.8)

    def test_product_is_json(self):
        ks = ortho.kerb_stations(self.prof, self.edges)
        segs = ortho.kerb_segments(self.frame.s, ks, self.frame.length)
        prod = ortho.product(self.frame, self.edges, ks, segs, [],
                             [[0.0, 10.0, "all"]])
        txt = json.dumps(prod)
        back = json.loads(txt)
        self.assertEqual(len(back["stations"]["left"]), self.frame.n)
        self.assertAlmostEqual(back["sections"][0]["traced_median"], LEFT + RIGHT, delta=0.1)


LE_MANS = os.path.join(helpers.ROOT, "assets", "tracks", "wec_le_mans_survey")


@unittest.skipUnless(os.path.exists(os.path.join(LE_MANS, "ortho_edges.json")), "no product")
class LeMansProductTest(unittest.TestCase):
    """The committed product of the survey Le Mans: shape, size and plausibility."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(LE_MANS, "ortho_edges.json"), encoding="utf-8") as f:
            cls.prod = json.load(f)
        with open(os.path.join(LE_MANS, "track.json"), encoding="utf-8") as f:
            cls.track = json.load(f)

    def test_one_station_per_track_point(self):
        st = self.prod["stations"]
        n = len(self.track["points"])
        for k in ("s", "left", "right", "conf_left", "conf_right", "flag_left", "flag_right"):
            self.assertEqual(len(st[k]), n, k)
        self.assertAlmostEqual(st["s"][100], self.track["points"][100]["s"], places=1)

    def test_widths_plausible(self):
        st = self.prod["stations"]
        w = np.array(st["left"]) + np.array(st["right"])
        self.assertTrue(np.all((w > 6.0) & (w < 30.0)), (w.min(), w.max()))
        self.assertTrue(8.0 < np.median(w) < 16.0)
        # the pit straight (first 300 m) is about 15 m between its lines
        self.assertAlmostEqual(float(np.median(w[:150])), 15.0, delta=0.6)

    def test_kerbs_and_runoff(self):
        kinds = {k["kind"] for k in self.prod["kerbs"]}
        self.assertLessEqual(kinds, {"red_white", "flat", "sausage"})
        self.assertGreater(len(self.prod["kerbs"]), 30)
        for k in self.prod["kerbs"]:
            self.assertLess(k["s0"], k["s1"])
            self.assertIn(k["side"], ("left", "right"))
        gravel = [r for r in self.prod["runoff"] if r["kind"] == "gravel"]
        self.assertGreater(len(gravel), 5)
        for r in self.prod["runoff"]:
            self.assertGreaterEqual(len(r["ring"]), 4)

    def test_small(self):
        self.assertLess(os.path.getsize(os.path.join(LE_MANS, "ortho_edges.json")), 2e6)


class HelpersTest(unittest.TestCase):
    def test_dp_follows_the_cheap_path_and_holds_through_noise(self):
        n, K = 60, 50
        cost = np.ones((n, K))
        cost[:, 20] = 0.0
        cost[30:34, 20] = 1.0          # the evidence vanishes for 4 rows ...
        cost[30:34, 40] = 0.0          # ... and a distractor appears far away
        path = ortho._dp(cost, 3, 0.2)
        self.assertTrue((path == 20).all())

    def test_interpolate_low_wraps(self):
        edge = np.array([5.0, 9.0, 9.0, 6.0, 6.0, 6.0, 6.0, 5.0])
        conf = np.array([1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0])
        out, flag = ortho.interpolate_low(edge, conf)
        np.testing.assert_allclose(out[1:3], [5 + 1 / 3, 5 + 2 / 3])
        self.assertEqual(list(flag), [False, True, True, False, False, False, False, False])

    def test_crossing(self):
        d = np.arange(0, 3, 0.5)
        x = np.array([0, 0, 0, 10, 10, 10.0])
        self.assertAlmostEqual(ortho._crossing(x, d, 5.0, 0.0, 3.0, 1.2), 1.25)


if __name__ == "__main__":
    unittest.main()
