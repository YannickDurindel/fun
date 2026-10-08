"""Options a street circuit on a hillside needs (Monaco): a relation with a gap, a junction
drawn twice, a terrain-model DEM with the sea as no-data, and retaining walls."""
import json
import os
import tempfile
import unittest

import numpy as np

import helpers
import road
from lib import net, osm, recipe
from lib.net import BuildError


class GapAndJunctionTest(unittest.TestCase):
    """A 4 km square, nodes 1..20 clockwise. The relation has ways 10 (nodes 1..16) and 11
    (18..20, 1): nodes 16 to 18 are missing. Way 12 is a longer road that covers them."""

    def setUp(self):
        self.nodes = helpers.square_nodes(1000.0)
        self.nodes[30] = (self.nodes[17][0] - 0.004, self.nodes[17][1])    # far end of way 12
        self.nodes[31] = (self.nodes[17][0] + 0.0002, self.nodes[17][1] + 0.0002)
        self.ways = {
            10: (list(range(1, 17)), {"highway": "secondary"}),
            11: ([18, 19, 20, 1], {"highway": "secondary"}),
            12: ([16, 17, 18, 30], {"highway": "residential"}),
        }
        self.relation = (7, [("way", 10, ""), ("way", 11, "")])

    def _find(self, ways=None, **osm_keys):
        data = osm.parse(helpers.osm_xml(self.nodes, ways or self.ways, self.relation))
        r = recipe.from_dict("test_square", {"osm": {"relation": 7, **osm_keys}, "length_m": 4000})
        return osm.find_loop(data, r, helpers.silent)

    def test_the_gap_stops_the_build(self):
        with self.assertRaises(BuildError) as cm:
            self._find()
        self.assertIn("do not form a closed loop", str(cm.exception))

    def test_extra_way_closes_the_gap_with_only_the_piece_it_shares(self):
        loop = self._find(extra_ways=[12])
        self.assertEqual(sorted(int(n) for n in loop.node_ids), list(range(1, 21)))
        self.assertNotIn("30", loop.node_ids)
        self.assertAlmostEqual(loop.raw_length, 4000.0, delta=4.0)

    def test_avoid_nodes_picks_one_of_two_ways_through_a_junction(self):
        # A second way from 16 to 18 over node 31: two loops of nearly the same length.
        ways = dict(self.ways)
        ways[13] = ([16, 31, 18], {"highway": "residential"})
        with self.assertRaises(BuildError) as cm:
            self._find(ways, extra_ways=[12, 13])
        self.assertIn("ambiguous", str(cm.exception))
        loop = self._find(ways, extra_ways=[12, 13], avoid_nodes=[31])
        self.assertIn("17", loop.node_ids)
        self.assertNotIn("31", loop.node_ids)
        loop = self._find(ways, extra_ways=[12, 13], avoid_nodes=[17])
        self.assertIn("31", loop.node_ids)
        self.assertNotIn("17", loop.node_ids)

    def test_recipe_checks_the_new_keys(self):
        with self.assertRaises(BuildError):
            recipe.from_dict("t", {"osm": {"relation": 7, "avoid_nodes": ["17"]}, "length_m": 4000})
        with self.assertRaises(BuildError):
            recipe.from_dict("t", {"osm": {"relation": 7, "extra_ways": [1.5]}, "length_m": 4000})
        # [[osm.round]] entries are validated against their key list.
        r = recipe.from_dict("t", {"osm": {"relation": 7, "round": [{"node": 5, "reach_m": 20.0, "note": "x"}]},
                                   "length_m": 4000})
        self.assertEqual(len(r.osm_round), 1)
        with self.assertRaises(BuildError):
            recipe.from_dict("t", {"osm": {"relation": 7, "round": [{"node": 5, "reach_m": 20.0, "radius": 3}]},
                                   "length_m": 4000})


class IgnDatasetTest(unittest.TestCase):
    def test_sea_and_coast_interpolation_become_sea_level(self):
        latlon = [(43.735, 7.4213), (43.735, 7.44), (43.7352, 7.4301), (43.74, 7.43)]
        raw = [3.65, -99999.0, -6436.2, None]
        with tempfile.TemporaryDirectory() as tmp:
            f = net.Fetcher(tmp, offline=True, log=helpers.silent)
            # Offline and not cached: the request is refused, not sent.
            with self.assertRaises(BuildError):
                net.fetch_elevations(f, latlon, "ign", "dem")
            sent = {}

            def download(url, retries=5, data=None):
                sent["url"], sent["body"] = url, json.loads(data)
                return json.dumps({"elevations": raw}).encode()

            f.offline, f.download = False, download
            orig, net.time.sleep = net.time.sleep, lambda _s: None
            try:
                vals = net.fetch_elevations(f, latlon, "ign", "dem")
            finally:
                net.time.sleep = orig
            self.assertEqual(vals, [3.65, 0.0, 0.0, 0.0])
            # Nothing but voids is no coverage, not sea; and a bad answer is not cached.
            raw[:] = [-99999.0] * 4
            self.assertEqual(net.fetch_elevations(f, [(la + 1.0, lo) for la, lo in latlon], "ign", "dem"), [None] * 4)
            raw[:] = [1.0, 2.0]
            with self.assertRaises(BuildError):
                net.fetch_elevations(f, [(la + 2.0, lo) for la, lo in latlon], "ign", "dem")
            self.assertEqual(len([n for n in os.listdir(tmp) if n.startswith("dem_ign_")]), 2)
            raw[:] = [3.65, -99999.0, -6436.2, None]
            self.assertEqual(sent["url"], net.IGN_URL)
            self.assertEqual(sent["body"]["lon"].split("|")[1], "7.440000")
            self.assertEqual(sent["body"]["lat"].count("|"), 3)
            # The answer is cached, so the same request works offline.
            f.offline, f.download = True, None
            self.assertEqual(net.fetch_elevations(f, latlon, "ign", "dem"), [3.65, 0.0, 0.0, 0.0])
        self.assertIn("IGN", net.attribution("ign"))


class RetainingWallTest(unittest.TestCase):
    """Two parallel roads 40 m apart, one 10 m above the other."""

    def setUp(self):
        x = np.arange(0.0, 200.0, 2.0)
        upper = np.stack([x, np.full_like(x, 10.0), np.zeros_like(x)], 1)
        lower = np.stack([x[::-1], np.zeros_like(x), np.full_like(x, 40.0)], 1)
        self.P = np.concatenate([upper, lower])
        self.n = len(x)
        # Outer edge of the upper road's verge on the side of the lower road, and on the far side.
        self.near = upper + np.array([0.0, -0.1, 18.0])
        self.far = upper + np.array([0.0, -0.1, -35.0])
        self.s = np.arange(len(self.P)) * 2.0

    def test_feet_reach_the_lower_road_only_where_it_is_near(self):
        self.assertTrue(np.allclose(road.wall_feet(self.P, self.near)[15:self.n - 15], 0.0))
        self.assertTrue(np.allclose(road.wall_feet(self.P, self.far)[15:self.n - 15], 9.9))

    def test_wall_goes_down_below_the_lower_road_and_faces_it(self):
        out = np.tile(np.array([0.0, 0.0, 1.0]), (self.n, 1))
        low = road.wall_feet(self.P, self.near)
        w = road.wall_primitive(self.near, low, out, self.s, 10, 20)
        self.assertIsNotNone(w)
        self.assertEqual(w.material, "concrete")
        self.assertEqual(len(w.indices), 20)                        # 10 segments, 2 triangles each
        self.assertAlmostEqual(float(w.positions[:, 1].max()), 9.9)
        self.assertAlmostEqual(float(w.positions[:, 1].min()), -road.WALL_FOOT)
        self.assertTrue(np.allclose(w.normals, [0.0, 0.0, 1.0]))
        # Triangles are wound to face the lower road (counter-clockwise seen from it).
        a, b, c = (w.positions[i] for i in w.indices[0])
        self.assertGreater(float(np.cross(b - a, c - a)[2]), 0.0)

    def test_a_gradient_alone_makes_no_wall(self):
        x = np.arange(0.0, 400.0, 2.0)
        hill = np.stack([x, 0.1 * x, np.zeros_like(x)], 1)        # one road climbing at 10 %
        edge = hill + np.array([0.0, -0.1, 18.0])
        low = road.wall_feet(hill, edge)
        self.assertTrue(np.allclose(low[20:-20], edge[20:-20, 1]))
        out = np.tile(np.array([0.0, 0.0, 1.0]), (len(x), 1))
        self.assertIsNone(road.wall_primitive(edge, low, out, np.arange(len(x)) * 2.0, 30, 60))

    def test_recipe_wants_a_boolean(self):
        with self.assertRaises(BuildError):
            recipe.from_dict("t", {"osm": {"relation": 7}, "length_m": 4000, "road": {"retaining_walls": "false"}})
        with self.assertRaises(BuildError):
            recipe.from_dict("t", {"osm": {"ways": [1], "avoid_nodes": [2]}, "length_m": 4000})

    def test_no_wall_where_no_road_is_lower(self):
        out = np.tile(np.array([0.0, 0.0, -1.0]), (self.n, 1))
        low = road.wall_feet(self.P, self.far)
        self.assertIsNone(road.wall_primitive(self.far, low, out, self.s, 10, 20))


if __name__ == "__main__":
    unittest.main()
