"""[[osm.round]]: a junction vertex becomes a corner, a two-vertex dogleg (to_node) an S-bend."""
import math
import unittest

import helpers  # noqa: F401  (sets sys.path)
from lib import osm, recipe
from lib.net import BuildError

M = 1.0 / osm.EARTH_M_PER_DEG      # degrees per metre (at the equator, where kx = ky)


def loop_of(points):
    """(OsmData, Loop) of a closed chain of (x, y) metres; node ids are "1", "2", ..."""
    data = osm.OsmData()
    ids = [str(i + 1) for i in range(len(points))]
    for i, (x, y) in zip(ids, points):
        data.nodes[i] = (y * M, x * M)
    return data, osm.Loop(ids, [""] * len(ids), [], 0.0, True, [])


def xy(data, loop):
    return [(data.nodes[i][1] / M, data.nodes[i][0] / M) for i in loop.node_ids]


def turn_angles(pts):
    """Direction change (degrees) at every vertex of the closed polyline."""
    out = []
    for i in range(len(pts)):
        a, b, c = pts[i - 1], pts[i], pts[(i + 1) % len(pts)]
        h1 = math.atan2(b[1] - a[1], b[0] - a[0])
        h2 = math.atan2(c[1] - b[1], c[0] - b[0])
        out.append(abs(math.degrees((h2 - h1 + math.pi) % (2 * math.pi) - math.pi)))
    return out


# A 600 x 400 m rectangle whose bottom side steps 20 m sideways on a short diagonal at
# x = 300 (nodes 3 and 4): a carriageway crossover.
DOGLEG = [(0, 0), (150, 0), (300, 0), (312, 20), (450, 20), (600, 20), (600, 400), (0, 400)]


class RoundTest(unittest.TestCase):
    def test_single_vertex_becomes_a_corner(self):
        data, loop = loop_of([(0, 0), (300, 0), (600, 0), (600, 400), (0, 400)])
        osm.round_corners(data, loop, [{"node": 3, "reach_m": 40.0}], helpers.silent)
        self.assertNotIn("3", loop.node_ids)
        pts = xy(data, loop)
        # The 90 degree vertex is gone: no vertex of the new corner turns more than 20 degrees,
        # and the curve stays inside the old corner.
        near = [a for a, p in zip(turn_angles(pts), pts) if math.dist(p, (600, 0)) < 60.0]
        self.assertGreater(len(near), 8)
        self.assertLess(max(near), 20.0)
        self.assertTrue(all(p[0] <= 600.01 and p[1] >= -0.01 for p in pts))

    def test_dogleg_becomes_an_s_bend(self):
        for spec in ({"node": 3, "to_node": 4}, {"node": 4, "to_node": 3}):   # either order
            data, loop = loop_of(DOGLEG)
            before = max(turn_angles(xy(data, loop))[2:4])
            self.assertGreater(before, 55.0)
            osm.round_corners(data, loop, [dict(spec, reach_m=60.0)], helpers.silent)
            self.assertNotIn("3", loop.node_ids)
            self.assertNotIn("4", loop.node_ids)
            pts = xy(data, loop)
            bend = [(a, p) for a, p in zip(turn_angles(pts), pts) if 230 < p[0] < 380 and p[1] < 30]
            self.assertGreater(len(bend), 10)
            self.assertLess(max(a for a, _ in bend), 6.0)
            # Tangent to the old loop at both ends, and monotonic across: an S, not a loop.
            ys = [p[1] for _, p in sorted(bend, key=lambda b: b[1][0])]
            self.assertTrue(all(b >= a - 1e-6 for a, b in zip(ys, ys[1:])))
            self.assertAlmostEqual(ys[0], 0.0, delta=0.3)
            self.assertAlmostEqual(ys[-1], 20.0, delta=0.3)
            # The kept nodes are still there, in order.
            kept = [i for i in loop.node_ids if not i.startswith("round")]
            self.assertEqual(kept, ["5", "6", "7", "8", "1", "2"])

    def test_to_node_must_be_another_loop_node(self):
        for other in (3, 5, 99):     # itself, not a neighbour, not on the loop
            data, loop = loop_of(DOGLEG)
            with self.assertRaises(BuildError):
                osm.round_corners(data, loop, [{"node": 3, "to_node": other, "reach_m": 30.0}],
                                  helpers.silent)

    def test_recipe_accepts_round_entries(self):
        r = recipe.from_dict("red_bull_ring", {"id": "red_bull_ring", "osm": {
            "relation": 1, "round": [{"node": 5, "to_node": 6, "reach_m": 30.0, "note": "x"}]}})
        self.assertEqual(r.osm_round[0]["to_node"], 6)
        for bad in ({"node": 5, "reach_m": 30.0, "to_node": "6"}, {"node": 5, "reach_m": 30.0, "typo": 1}):
            with self.assertRaises(BuildError):
                recipe.from_dict("red_bull_ring", {"id": "red_bull_ring",
                                                   "osm": {"relation": 1, "round": [bad]}})

    def test_committed_recipes_with_round_entries_load(self):
        for track_id in ("albert_park", "las_vegas"):
            self.assertTrue(recipe.load(track_id).osm_round, track_id)


if __name__ == "__main__":
    unittest.main()
