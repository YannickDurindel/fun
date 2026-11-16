"""Trackside table generator of the survey Le Mans (landmarks/wec_le_mans_survey_trackside.py),
offline, on synthetic inputs: kerb joining / filtering, run-off filtering against the mapped wall,
barrier stretches and turn-relative rows."""
import os
import sys
import unittest

import numpy as np

import helpers  # noqa: F401  (sys.path)

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "landmarks"))
import wec_le_mans_survey_trackside as t  # noqa: E402

L = 13626.0
TURNS = [{"id": "T1", "direction": "right", "s_apex": 1000.0, "min_radius": 40.0},
         {"id": "T2", "direction": "left", "s_apex": 5000.0, "min_radius": 300.0}]


class KerbsTest(unittest.TestCase):
    def test_join_drop_and_kind(self):
        ej = {"kerbs": [
            {"s0": 100, "s1": 110, "side": "left", "kind": "red_white", "width": 1.2, "gap": 0.1},
            {"s0": 114, "s1": 120, "side": "left", "kind": "red_white", "width": 1.2, "gap": 0.0},
            {"s0": 300, "s1": 304, "side": "right", "kind": "red_white", "width": 1.0, "gap": 0.0},
            {"s0": 400, "s1": 440, "side": "right", "kind": "red_white", "width": 0.8, "gap": -1.9},
            {"s0": 500, "s1": 530, "side": "right", "kind": "red_white", "width": 3.0, "gap": 0.0}]}
        k = t.kerb_list(ej, L)
        self.assertEqual([(x["s0"], x["s1"], x["side"], x["kind"]) for x in k],
                         [(100, 120, -1, "saw"), (500, 530, 1, "flat")])

    def test_relative_rows(self):
        # right-hand T1: its inside is the right (+1)
        self.assertEqual(t.relative(TURNS, 980.0, 1020.0, 1, L), ["T1", "in", -20.0, 20.0])
        self.assertEqual(t.relative(TURNS, 4990.0, 5010.0, 1, L), ["T2", "out", -10.0, 10.0])
        # wraps through the finish line onto the nearest corner
        row = t.relative(TURNS, L - 10.0, 30.0, -1, L)
        self.assertEqual(row[0], "T1")
        self.assertAlmostEqual(row[3] - row[2], 40.0)


class BarrierTest(unittest.TestCase):
    def test_stretches(self):
        ES = np.arange(0.0, 1000.0, 2.0)
        gap = np.where(ES < 500, 1.5, 8.0)
        gap[100:110] = np.nan          # a hole in the map gets the default
        out = t.barrier_stretches(gap, ES, 1000.0, lambda s: 2.0, lambda s: 0.7)
        self.assertLessEqual(len(out), 3)
        self.assertAlmostEqual(out[0][2], 1.5)
        self.assertAlmostEqual(out[-1][2], 8.0)
        self.assertAlmostEqual(out[-1][1], 1000.0)

    def test_runoff_clipped_and_filtered(self):
        ES = np.arange(0.0, L, 2.0)
        gaps = {1: np.full(len(ES), 10.0), -1: np.full(len(ES), np.nan)}
        ej = {"runoff": [
            {"kind": "gravel", "side": "right", "s0": 950, "s1": 1050, "u0": 1.0, "u1": 20.0},
            {"kind": "tarmac", "side": "right", "s0": 4000, "s1": 4100, "u0": 0.0, "u1": 9.0},
            {"kind": "tarmac", "side": "left", "s0": 900, "s1": 1000, "u0": 30.0, "u1": 40.0},
            {"kind": "grass", "side": "left", "s0": 900, "s1": 1000, "u0": 0.0, "u1": 9.0}]}
        r = t.runoff_list(ej, TURNS, gaps, ES, L)
        self.assertEqual(len(r), 1)           # public straight, service road, grass: dropped
        self.assertAlmostEqual(r[0]["u1"], 10.0 - t.RUNOFF_ALLOWANCE - t.BEHIND_RUNOFF)


if __name__ == "__main__":
    unittest.main()
