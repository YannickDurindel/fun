"""Turn detection and sectors, on the committed Red Bull Ring centreline and a synthetic lap."""
import math
import unittest

import helpers
from lib import geom, recipe, turns


def _curvature(track):
    return [p["curvature"] for p in track["points"]]


class RedBullRingTurnsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.track = helpers.rbr_track()
        cls.curv = _curvature(cls.track)
        cls.step = cls.track["step"]

    def test_pinned_table_reproduces_the_committed_turns(self):
        r = recipe.load("red_bull_ring")
        got = turns.pinned(self.curv, self.step, r.turn_table)
        want = self.track["turns"]
        key = ("id", "name", "direction")
        self.assertEqual([[t[k] for k in key] for t in got], [[t[k] for k in key] for t in want])
        # track.json stores the curvature rounded to 1e-5, so here an apex on a flat peak can
        # land one sample off and faint kinks' radii one digit off; the full rebuild
        # (test_rebuild_rbr) works on the unrounded curvature and compares the table exactly.
        for g, w in zip(got, want):
            self.assertAlmostEqual(g["s_apex"], w["s_apex"], delta=self.step + 0.05)
            self.assertAlmostEqual(g["min_radius"], w["min_radius"], delta=0.002 * w["min_radius"] + 0.05)

    def test_automatic_detection_finds_the_official_number_of_turns(self):
        auto = turns.detect(self.curv, self.step, official=10)
        self.assertEqual(len(auto["turns"]), 10)
        self.assertEqual(auto["warnings"], [])
        self.assertEqual([t["id"] for t in auto["turns"]], [f"T{i}" for i in range(1, 11)])
        apexes = [t["s_apex"] for t in auto["turns"]]
        self.assertEqual(apexes, sorted(apexes))

    def test_automatic_apexes_against_the_committed_table(self):
        """Every real corner of the committed table is found within 15 m (in fact exactly).

        The three remaining entries of the committed table are not corners by any geometric
        measure, so no automatic rule can pick them without also picking the bigger bends it
        leaves out: its T2 (s 749) and T10 (s 4077) turn 5 and 12 degrees at 240-290 m radius,
        and its T5 (s 2674) is the first of two curvature peaks of the Rauch left-hander (T6).
        Instead the detector numbers the three bends the table skips: the left kink on the
        climb (18 deg), and the long rights after Schlossgold (62 deg) and Wuerth (52 deg),
        which is how the circuit's official map counts its ten turns. The game keeps the
        committed table through the recipe (see test_pinned_table_...)."""
        auto = [t["s_apex"] for t in turns.detect(self.curv, self.step, official=10)["turns"]]
        committed = {t["id"]: t["s_apex"] for t in self.track["turns"]}
        corners = ["T1", "T3", "T4", "T6", "T7", "T8", "T9"]
        for tid in corners:
            nearest = min(auto, key=lambda s: abs(s - committed[tid]))
            self.assertLessEqual(abs(nearest - committed[tid]), 15.0, f"{tid} at s={committed[tid]}")
        unmatched = [tid for tid, s in committed.items() if min(abs(a - s) for a in auto) > 15.0]
        self.assertEqual(unmatched, ["T2", "T5", "T10"])
        # ... and the three turns found instead.
        extra = [a for a in auto if min(abs(a - s) for s in committed.values()) > 15.0]
        self.assertEqual(len(extra), 3)
        for s, expect in zip(extra, (1110.0, 2465.0, 3178.0)):
            self.assertAlmostEqual(s, expect, delta=15.0)

    def test_directions_and_radii(self):
        auto = turns.detect(self.curv, self.step, official=10)["turns"]
        by_s = {round(t["s_apex"]): t for t in auto}
        self.assertEqual(by_s[1395]["direction"], "right")     # Remus
        self.assertAlmostEqual(by_s[1395]["min_radius"], 12.8, delta=0.1)
        self.assertEqual(by_s[2814]["direction"], "left")      # Rauch
        self.assertEqual(by_s[3100]["direction"], "left")      # Wuerth

    def test_osm_way_names_are_attached(self):
        n = len(self.curv)
        names = [""] * n
        k = int(1395.2 / self.step)
        for i in range(k - 15, k + 15):
            names[i] = "Remus"
        auto = turns.detect(self.curv, self.step, names, official=10)["turns"]
        self.assertEqual(auto[2]["name"], "Remus")
        self.assertEqual(auto[0]["name"], "Turn 1")

    def test_count_mismatch_warns(self):
        auto = turns.detect(self.curv, self.step, official=25)
        self.assertLess(len(auto["turns"]), 25)
        self.assertTrue(any("official count is 25" in w for w in auto["warnings"]))
        fewer = turns.detect(self.curv, self.step, official=4)
        self.assertGreater(len(fewer["turns"]), 4)     # real corners are never dropped
        self.assertTrue(fewer["warnings"])

    def test_without_an_official_count(self):
        auto = turns.detect(self.curv, self.step)
        self.assertGreaterEqual(len(auto["turns"]), 10)
        self.assertEqual(auto["warnings"], [])

    def test_recipe_names_apply_to_detected_turns(self):
        auto = turns.detect(self.curv, self.step, official=10)["turns"]
        warnings = []
        named = turns.apply_names(auto, [{"id": "T3", "name": "Remus"}, {"id": "T40", "name": "x"}], warnings)
        self.assertEqual(named[2]["name"], "Remus")
        self.assertEqual(named[2]["s_apex"], auto[2]["s_apex"])
        self.assertEqual(len(warnings), 1)

    def test_default_sectors_split_the_lap_in_thirds_on_straights(self):
        s = turns.sectors(self.curv, self.step)
        length = self.track["length"]
        self.assertEqual(s[0], 0.0)
        self.assertAlmostEqual(s[1], length / 3, delta=length / 8)
        self.assertAlmostEqual(s[2], 2 * length / 3, delta=length / 8)
        for boundary in s[1:]:
            k = int(boundary / self.step)
            self.assertLess(max(abs(self.curv[(k + d) % len(self.curv)]) for d in range(-15, 16)), 0.002)

    def test_sector_override(self):
        self.assertEqual(turns.sectors(self.curv, self.step, [2352.2, 3219.5]), self.track["sectors"])


class SyntheticTurnsTest(unittest.TestCase):
    """A stadium: two 400 m straights joined by two 180-degree bends of 80 m radius, driven
    clockwise, with a 6-degree left kink in the middle of the first straight."""

    def setUp(self):
        self.step = 2.0
        radius, straight = 80.0, 400.0
        curv = []
        for _ in range(2):
            n_s = int(straight / self.step)
            for i in range(n_s):
                curv.append(0.0)
            for _ in range(int(round(math.pi * radius / self.step))):
                curv.append(-1.0 / radius)
        # kink: 6 degrees over 40 m, in the first straight
        k0 = 90
        for i in range(k0, k0 + 20):
            curv[i] = math.radians(6.0) / 40.0
        self.curv = geom.gauss_periodic(curv, 6.0 / self.step)

    def test_corners_and_kink(self):
        auto = turns.detect(self.curv, self.step)
        self.assertEqual([t["direction"] for t in auto["turns"]], ["right", "right"])   # kink < 10 deg
        with_kink = turns.detect(self.curv, self.step, official=3)["turns"]
        self.assertEqual([t["direction"] for t in with_kink], ["left", "right", "right"])
        self.assertEqual(with_kink[0]["name"], "Turn 1 (kink)")
        self.assertAlmostEqual(with_kink[0]["s_apex"], 200.0, delta=12.0)
        self.assertAlmostEqual(with_kink[1]["min_radius"], 80.0, delta=1.0)
        cands = turns.detect(self.curv, self.step)["candidates"]
        self.assertAlmostEqual(cands[0]["angle_deg"], 6.0, delta=1.5)
        self.assertAlmostEqual(cands[1]["angle_deg"], 180.0, delta=3.0)

    def test_pinned_snaps_to_the_curvature_peak(self):
        # The pin is 10 m off; the apex lands on the kink's peak.
        out = turns.pinned(self.curv, self.step, [{"id": "T1", "direction": "left", "s": 210.0}])
        self.assertAlmostEqual(out[0]["s_apex"], 200.0, delta=4.0)
        self.assertEqual(out[0]["name"], "Turn 1")


    def test_pinned_apex_stays_inside_the_lap(self):
        length = len(self.curv) * self.step
        out = turns.pinned(self.curv, self.step, [{"id": "T1", "direction": "left", "s": length - 0.01}])
        self.assertGreaterEqual(out[0]["s_apex"], 0.0)
        self.assertLess(out[0]["s_apex"], length)


if __name__ == "__main__":
    unittest.main()
