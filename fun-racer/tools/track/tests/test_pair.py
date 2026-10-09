"""[[layout.shift]] and [[road.pair]]: moving the centreline sideways, and two stretches of the
lap built as the two carriageways of one road. Synthetic loops, then Baku rebuilt offline."""
import importlib.util
import json
import math
import os
import tempfile
import unittest

import helpers
from lib import geom, layout, recipe
from lib.net import BuildError

HAVE_NUMPY = importlib.util.find_spec("numpy") is not None
STEP = 2.0
BASE = {"osm": {"relation": 1}, "length_m": 2000}


def hairpin_loop(gap=10.0, straight=400.0, radius=60.0):
    """A closed loop whose first two stretches run side by side, ``gap`` apart, in opposite
    directions: out along z = 0, a tight U-turn, back along z = gap, and a wide way home.
    Evenly spaced; returns (points, step, [out stretch], [back stretch]) with the stretches as
    s ranges."""
    raw = [(x, 0.0) for x in range(0, int(straight) + 1, 2)]
    r = 0.5 * gap
    raw += [(straight + r * math.sin(a), r - r * math.cos(a)) for a in [math.pi * k / 12 for k in range(1, 12)]]
    raw += [(x, gap) for x in range(int(straight), -1, -2)]
    # Home: a big arc from (0, gap) round to (0, 0) on the far side.
    big = radius
    raw += [(-big * math.sin(a), gap + big - big * math.cos(a)) for a in [math.pi * k / 40 for k in range(1, 40)]]
    raw += [(-x, gap + 2 * big) for x in range(0, 200, 4)]
    raw += [(-200.0 - (big + 0.5 * gap) * math.sin(a), 0.5 * gap + big + (big + 0.5 * gap) * math.cos(a))
            for a in [math.pi * k / 40 for k in range(0, 41)]]
    raw += [(-x, 0.0) for x in range(196, 0, -4)]
    pts, step, _ = geom.respace(raw, STEP)
    back0 = straight + math.pi * r
    return pts, step, [40.0, straight - 40.0], [back0 + 40.0, back0 + straight - 40.0]


def separation(pts, step, a, b, inset=20.0):
    """Closest distance to stretch b of every point of stretch a (less ``inset`` at either end,
    where the nearest point of b is its end and not the point abeam)."""
    ia = range(int((a[0] + inset) / step), int((a[1] - inset) / step) + 1)
    ib = range(int(b[0] / step), int(b[1] / step))
    return [min(geom.seg_dist(pts[j], pts[j + 1], pts[i])[0] for j in ib) for i in ia]


class LayoutTest(unittest.TestCase):
    def test_nothing_to_do(self):
        pts, step, _, _ = hairpin_loop()
        moved, most = layout.apply(pts, step, [], [], 1.0)
        self.assertIs(moved, pts)
        self.assertEqual(most, 0.0)

    def test_shift_moves_a_stretch_to_one_side(self):
        pts, step, a, _ = hairpin_loop()
        moved, most = layout.apply(pts, step, [{"s": [150.0, 250.0], "lateral_m": 3.0, "blend": 40.0}], [], 1.0)
        self.assertAlmostEqual(most, 3.0, delta=0.05)
        k = int(200.0 / step)
        # The stretch runs east (+x), so its right is +z (south in the Godot frame).
        self.assertAlmostEqual(moved[k][1] - pts[k][1], 3.0, delta=0.05)
        self.assertAlmostEqual(moved[k][0], pts[k][0], delta=0.05)
        far = int(60.0 / step)
        self.assertAlmostEqual(moved[far][1], pts[far][1], delta=1e-3)       # beyond the blend
        steps = [math.dist(p, q) for p, q in zip(moved, moved[1:])]
        self.assertLess(max(steps) / step, 1.01)                              # eased in, no kink

    def test_pair_separation_pushes_both_stretches_apart(self):
        pts, step, a, b = hairpin_loop(gap=10.0)
        self.assertAlmostEqual(min(separation(pts, step, a, b)), 10.0, delta=0.05)
        moved, most = layout.apply(pts, step, [], [{"a": a, "b": b, "separation": 14.0, "blend": 30.0}], 1.0)
        self.assertAlmostEqual(most, 2.0, delta=0.05)                         # each by half the missing 4 m
        sep = separation(moved, step, a, b)
        self.assertAlmostEqual(min(sep), 14.0, delta=0.05)
        self.assertAlmostEqual(max(sep), 14.0, delta=0.05)
        k = int(200.0 / step)
        self.assertAlmostEqual(moved[k][1], -2.0, delta=0.05)                 # away from the other one
        # Never pulled together: already further apart than asked.
        same, most = layout.apply(pts, step, [], [{"a": a, "b": b, "separation": 8.0, "blend": 20.0}], 1.0)
        self.assertIs(same, pts)

    def test_stretches_that_follow_each_other_closely(self):
        # The two legs right up to the U-turn: 26 m of lap between the stretches, far less than
        # the blend. No point may be measured against its own road (and thrown 7 m sideways).
        pts, step, a, b = hairpin_loop(gap=10.0)
        pair = {"a": [a[0], a[1] + 35.0], "b": [b[0] - 35.0, b[1]], "separation": 14.0, "blend": 60.0}
        lat = layout.pair_offsets(pts, step, [pair])
        self.assertLess(max(abs(v) for v in lat), 2.05)
        self.assertAlmostEqual(abs(lat[int(200.0 / step)]), 2.0, delta=0.05)

    def test_a_shift_across_the_finish_line_keeps_the_origin_on_it(self):
        # Baku with its start / finish straight moved 2 m to the right. (Baku, because its DEM
        # is cached as tiles: a moved centreline asks OpenTopoData for other points.)
        import build_track
        baku = os.path.join(helpers.ROOT, "assets", "tracks", "baku")
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(helpers.TRACK_TOOLS, "tracks", "baku.toml"), encoding="utf-8") as f:
                text = f.read() + "\n[[layout.shift]]\ns = [5900.0, 150.0]\nlateral_m = 2.0\nblend = 40.0\n"
            recipe_path = os.path.join(tmp, "shifted.toml")
            with open(recipe_path, "w", encoding="utf-8") as f:
                f.write(text)
            build_track.run(["baku", "--offline", "--recipe", recipe_path, "--out", tmp,
                             "--cache", os.path.join(baku, "raw"), "--steps", "centreline"],
                            log=helpers.silent)
            with open(os.path.join(tmp, "track.json"), encoding="utf-8") as f:
                moved = json.load(f)
        with open(os.path.join(baku, "track.json"), encoding="utf-8") as f:
            ref = json.load(f)
        # Point 0 is where it was in the frame (a few decimetres from the origin: the plan-view
        # smoothing), although the road under it moved 2 m.
        for was, now in zip(ref["points"][0]["p"], moved["points"][0]["p"]):
            self.assertAlmostEqual(was, now, delta=0.01)
        self.assertEqual(moved["length"], ref["length"])
        # The line (and the frame's origin with it) is 2 m from where it was ...
        k = geom.EARTH_M_PER_DEG
        dlat = (moved["origin_latlon"][0] - ref["origin_latlon"][0]) * k
        dlon = (moved["origin_latlon"][1] - ref["origin_latlon"][1]) * k * math.cos(math.radians(ref["origin_latlon"][0]))
        self.assertAlmostEqual(math.hypot(dlat, dlon), 2.0, delta=0.1)
        # ... and the far side of the lap has not moved on the ground: same position once the
        # two origins are accounted for.
        i = len(ref["points"]) // 2
        a, b = ref["points"][i]["p"], moved["points"][i]["p"]
        self.assertAlmostEqual(a[0] - (b[0] + dlon), 0.0, delta=0.5)
        self.assertAlmostEqual(a[2] - (b[2] - dlat), 0.0, delta=0.5)
        self.assertAlmostEqual(moved["start_s"], ref["start_s"], delta=2.5)

    def test_distances_are_final_lap_metres(self):
        pts, step, a, b = hairpin_loop(gap=10.0)
        k_scale = 1.25           # the lap is scaled up by this afterwards
        pair = {"a": [v * k_scale for v in a], "b": [v * k_scale for v in b], "separation": 14.0 * k_scale}
        moved, most = layout.apply(pts, step, [], [pair], k_scale)
        self.assertAlmostEqual(min(separation(moved, step, a, b)), 14.0, delta=0.05)
        self.assertAlmostEqual(most, 2.0 * k_scale, delta=0.07)

    def test_recipe_validation(self):
        def rec(lay=None, road=None):
            return recipe.from_dict("somewhere", {**BASE, "layout": lay or {}, "road": road or {}})
        ok = {"a": [100.0, 300.0], "b": [900.0, 1100.0]}
        self.assertEqual(rec(road={"pair": [{**ok, "separation": 14.0, "gap": 2.0}]}).road["pair"][0]["gap"], 2.0)
        self.assertEqual(rec(lay={"shift": [{"s": [100.0, 300.0], "lateral_m": -2.0}]}).shifts[0]["lateral_m"], -2.0)
        for bad in ({"a": [100.0, 300.0]}, {**ok, "b": [200.0, 400.0]}, {**ok, "b": [50.0, 400.0]},
                    {**ok, "a": [1900.0, 100.0], "b": [50.0, 400.0]}, {**ok, "separation": 3.0},
                    {**ok, "gap": 0.1}, {**ok, "width": 9.0}, {**ok, "blend": 0.0}):
            with self.assertRaises(BuildError, msg=str(bad)):
                rec(road={"pair": [bad]})
        for bad in ({"s": [100.0, 300.0]}, {"s": [100.0, 300.0], "lateral_m": 0.0},
                    {"s": [100.0, 300.0], "lateral_m": 40.0}, {"s": [100.0, 2000.0], "lateral_m": 1.0},
                    {"s": [100.0, 300.0], "lateral_m": 1.0, "blend": 0.0}):
            with self.assertRaises(BuildError, msg=str(bad)):
                rec(lay={"shift": [bad]})
        # A pair alone does not switch the built widths into track.json; a width does.
        self.assertFalse(recipe.track_json_widths({"pair": [ok]}))


@unittest.skipUnless(HAVE_NUMPY, "cad/track/road.py needs numpy (use the project venv)")
class PairGeometryTest(unittest.TestCase):
    def _frame(self, gap=14.0):
        import numpy as np
        pts, step, a, b = hairpin_loop(gap=gap)
        P = np.array([(x, 0.0, z) for x, z in pts])
        T = np.roll(P, -1, 0) - np.roll(P, 1, 0)
        T /= np.linalg.norm(T, axis=1, keepdims=True)
        Rh = np.cross(T, np.array([0.0, 1.0, 0.0]))
        return P, Rh, step, a, b

    def test_spans(self):
        import numpy as np
        import road
        P, Rh, step, a, b = self._frame(14.0)
        hw = np.full(len(P), 5.5)
        hw[road._stretch_points(b, step, len(P))] = 6.0
        spans = road.pair_spans([{"a": a, "b": b, "gap": 2.0}], P, Rh, hw, step)
        self.assertEqual(len(spans), 1)
        sp = spans[0]
        # The lap turns right into the U-turn (z grows): each stretch has the other on its right.
        self.assertEqual((sp["side_a"], sp["side_b"]), (1, 1))
        self.assertAlmostEqual(sp["separation"][0], 14.0, delta=0.05)
        self.assertAlmostEqual(sp["gap"][0], 2.5, delta=0.05)
        self.assertAlmostEqual(sp["a"][0], a[0], delta=3 * step)
        self.assertAlmostEqual(sp["b"][1], b[1], delta=3 * step)
        # The verges of both meet half way between the tarmac edges.
        ext_l, ext_r = np.full(len(P), 0.3), np.full(len(P), 0.3)
        road.pair_verges(spans, ext_l, ext_r)
        ia = int(200.0 / step)
        self.assertAlmostEqual(ext_r[ia], 1.25, delta=0.03)
        self.assertEqual(ext_l[ia], 0.3)                    # the other side is not the pair's business
        ib = road._stretch_points(b, step, len(P))[len(road._stretch_points(b, step, len(P))) // 2]
        self.assertAlmostEqual(ext_r[ib], 1.25, delta=0.03)
        self.assertAlmostEqual(hw[ia] + ext_r[ia] + ext_r[ib] + hw[ib], 14.0, delta=0.06)
        self.assertEqual(ext_r[int(len(P) * 0.75)], 0.3)    # the rest of the lap is untouched

    def test_roads_too_wide_for_their_separation_stop_the_build(self):
        import numpy as np
        import road
        P, Rh, step, a, b = self._frame(10.0)
        with self.assertRaises(ValueError) as e:
            road.pair_spans([{"a": a, "b": b}], P, Rh, np.full(len(P), 5.5), step)
        self.assertIn("leaves -1.0 m between the tarmac edges", str(e.exception))
        self.assertIn("12.5 m apart", str(e.exception))     # what it takes: 5.5 + 5.5 + 1.5
        road.pair_spans([{"a": a, "b": b}], P, Rh, np.full(len(P), 4.0), step)      # 8 m roads fit

    def test_stretches_that_are_not_side_by_side(self):
        import numpy as np
        import road
        P, Rh, step, a, _ = self._frame(14.0)
        with self.assertRaises(ValueError):
            road.pair_spans([{"a": [100.0, 110.0], "b": [300.0, 310.0]}], P, Rh, np.full(len(P), 4.0), step)


@unittest.skipUnless(HAVE_NUMPY, "the road step needs numpy (use the project venv)")
class BakuPairTest(unittest.TestCase):
    """The committed Baku recipe: Turn 6 to Turn 7 beside the main straight."""

    @classmethod
    def setUpClass(cls):
        import build_track
        cls.tmp = tempfile.TemporaryDirectory()
        build_track.run(["baku", "--offline", "--out", cls.tmp.name, "--steps", "centreline,road"],
                        log=helpers.silent)
        with open(os.path.join(cls.tmp.name, "track.json"), encoding="utf-8") as f:
            cls.track = json.load(f)
        with open(os.path.join(cls.tmp.name, "road_profile.json"), encoding="utf-8") as f:
            cls.profile = json.load(f)
        cls.pair = recipe.load("baku").road["pair"][0]

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def _arrays(self):
        import numpy as np
        import road
        P = np.array([p["p"] for p in self.track["points"]])
        n, step = len(P), self.track["step"]
        T = np.roll(P, -1, 0) - np.roll(P, 1, 0)
        Rh = np.cross(T, np.array([0.0, 1.0, 0.0]))
        Rh /= np.linalg.norm(Rh, axis=1, keepdims=True)
        hw = 0.5 * np.array(self.profile["width"])
        ia, ib = (road._stretch_points(self.pair[k], step, n) for k in ("a", "b"))
        return P, Rh, hw, ia, ib

    def test_the_rebuild_is_the_committed_track(self):
        with open(os.path.join(helpers.ROOT, "assets", "tracks", "baku", "track.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f), self.track)

    def test_centrelines_are_moved_to_their_separation(self):
        import numpy as np
        P, _, _, ia, ib = self._arrays()
        d = np.linalg.norm(P[ia][:, None, [0, 2]] - P[ib][None, :, [0, 2]], axis=-1).min(1)
        self.assertGreater(d.min(), self.pair["separation"] - 0.1)
        self.assertEqual(self.profile["pairs"][0]["side_a"], -1)       # anticlockwise: on the left
        self.assertEqual(self.profile["pairs"][0]["side_b"], -1)
        self.assertGreaterEqual(self.profile["pairs"][0]["gap"][0], self.pair["gap"])

    def test_no_tarmac_of_one_road_lies_on_the_other(self):
        # The tarmac is ruled between its cross-sections (left edge, centre, right edge), so it
        # is enough that no cross-section point of one stretch is within the other road, with
        # the pair's gap to spare along the facing edges.
        import numpy as np
        P, Rh, hw, ia, ib = self._arrays()
        for own, other in ((ia, ib), (ib, ia)):
            for lat in (-1.0, 0.0, 1.0):
                q = P[own] + Rh[own] * (lat * hw[own])[:, None]
                d = np.linalg.norm(q[:, None, [0, 2]] - P[other][None, :, [0, 2]], axis=-1)
                j = d.argmin(1)
                clear = d[np.arange(len(own)), j] - hw[other][j]
                self.assertGreater(clear.min(), self.pair["gap"] - 0.15, f"lateral {lat:+.0f}")

    def test_verges_meet_between_the_roads(self):
        import numpy as np
        P, Rh, hw, ia, ib = self._arrays()
        verge = np.array(self.profile["verge_left"])
        mid = ia[len(ia) // 2]
        d = np.linalg.norm(P[mid][[0, 2]] - P[ib][:, [0, 2]], axis=-1)
        other = ib[d.argmin()]
        self.assertAlmostEqual(hw[mid] + verge[mid] + verge[other] + hw[other], d.min(), delta=0.1)
        self.assertGreater(verge[ia[5:-5]].min(), 0.5 * self.pair["gap"] - 0.01)
        # No hole between the two verges and no overlap either, all along the stretch.
        edge = P[ia] - Rh[ia] * (hw[ia] + verge[ia])[:, None]
        far = P[ib] - Rh[ib] * (hw[ib] + verge[ib])[:, None]
        seam = np.linalg.norm(edge[:, None, [0, 2]] - far[None, :, [0, 2]], axis=-1).min(1)
        self.assertLess(seam[5:-5].max(), 1.1)              # within a point's spacing of each other


if __name__ == "__main__":
    unittest.main()
