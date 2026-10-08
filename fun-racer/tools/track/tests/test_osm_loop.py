"""Automatic loop extraction: the Red Bull Ring relation (committed cache) and small synthetic
circuits for the failure modes."""
import unittest

import helpers
from lib import osm, recipe
from lib.net import BuildError


def _recipe(track_id="red_bull_ring", **osm_keys):
    data = {"osm": {"relation": 5309181, **osm_keys}, "length_m": 4318}
    return recipe.from_dict(track_id, data)


def _rotations(seq):
    return [seq[i:] + seq[:i] for i in range(len(seq))]


class RedBullRingLoopTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = osm.parse(helpers.rbr_osm_xml())

    def test_finds_the_grand_prix_loop_without_a_way_list(self):
        loop = osm.find_loop(self.data, _recipe(), helpers.silent)
        # Same ways, same driving order as the hand-written list (any starting way).
        self.assertIn(loop.way_ids, _rotations(helpers.RBR_LOOP_WAYS))
        self.assertNotIn(helpers.RBR_PIT_LANE, loop.way_ids)
        for wid in helpers.RBR_MOTOGP_WAYS:
            self.assertNotIn(wid, loop.way_ids)
        self.assertTrue(loop.directed)
        self.assertEqual(loop.warnings, [])
        self.assertAlmostEqual(loop.raw_length, 4305.0, delta=5.0)
        self.assertLess(abs(loop.raw_length / 4318.0 - 1.0), 0.02)

    def test_node_chain_matches_the_hand_written_chain(self):
        loop = osm.find_loop(self.data, _recipe(), helpers.silent)
        manual = osm.find_loop(self.data, _recipe(ways=helpers.RBR_LOOP_WAYS), helpers.silent)
        self.assertEqual(len(loop.node_ids), len(manual.node_ids))
        self.assertEqual(len(set(loop.node_ids)), len(loop.node_ids))
        self.assertIn(loop.node_ids, _rotations(manual.node_ids))
        self.assertEqual(len(loop.names), len(loop.node_ids))
        self.assertIn("Remus", loop.names)

    def test_other_layouts_are_candidates_but_lose(self):
        loop = osm.find_loop(self.data, _recipe(), helpers.silent)
        self.assertGreater(len(loop.candidates), 1)
        # The MotoGP chicane layout is closer to 4318 m than the GP loop is in OSM; only its
        # name keeps it out. This is the case exclude_ways / avoid_names exist for.
        motogp = [c for c in loop.candidates if 1077423714 in c[2]]
        self.assertTrue(motogp)
        self.assertLess(abs(motogp[0][1] - 4318.0), abs(loop.raw_length - 4318.0))

    def test_start_and_finish_come_from_relation_roles(self):
        loop = osm.find_loop(self.data, _recipe(), helpers.silent)
        finish, start, source = osm.start_finish_nodes(self.data, _recipe(), loop)
        self.assertEqual(finish, (47.2202964, 14.7667292))
        self.assertNotEqual(start, finish)
        self.assertIn("relation member role", source)

    def test_wrong_official_length_fails_with_candidates(self):
        r = recipe.from_dict("red_bull_ring", {"osm": {"relation": 5309181}, "length_m": 5200})
        with self.assertRaises(BuildError) as cm:
            osm.find_loop(self.data, r, helpers.silent)
        msg = str(cm.exception)
        self.assertIn("official lap length 5200", msg)
        self.assertIn("Closest loops", msg)
        self.assertIn("way 822592398", msg)       # every candidate way is listed ...
        self.assertIn("741.9 m", msg)              # ... with its length
        self.assertIn("exclude_ways", msg)

    def test_excluding_a_way_of_the_loop_breaks_it_helpfully(self):
        with self.assertRaises(BuildError) as cm:
            osm.find_loop(self.data, _recipe(exclude_ways=[822592398, 289111668]), helpers.silent)
        msg = str(cm.exception)
        # Only the short MotoGP penalty loops are left: none is anywhere near 4318 m.
        self.assertIn("no loop in relation 5309181 matches the official lap length 4318 m", msg)
        self.assertIn("dead end", msg)
        self.assertIn("ways = [id, id, ...]", msg)

    def test_explicit_way_list(self):
        loop = osm.find_loop(self.data, _recipe(ways=helpers.RBR_LOOP_WAYS), helpers.silent)
        self.assertEqual(loop.way_ids, helpers.RBR_LOOP_WAYS)
        with self.assertRaisesRegex(BuildError, "does not continue the chain"):
            osm.find_loop(self.data, _recipe(ways=helpers.RBR_LOOP_WAYS[:3] + helpers.RBR_LOOP_WAYS[5:]),
                          helpers.silent)
        with self.assertRaisesRegex(BuildError, "does not close"):
            osm.find_loop(self.data, _recipe(ways=helpers.RBR_LOOP_WAYS[:-1]), helpers.silent)


class SyntheticLoopTest(unittest.TestCase):
    """A 4 km square: nodes 1..20 clockwise, 5 per side."""

    def setUp(self):
        self.nodes = helpers.square_nodes(1000.0)
        self.ring = list(range(1, 21))

    def _find(self, ways, length=4000, relation=None, **osm_keys):
        data = osm.parse(helpers.osm_xml(self.nodes, ways, relation))
        src = {"relation": relation[0]} if relation else {"bbox": [13.9, 46.9, 14.1, 47.1]}
        r = recipe.from_dict("test_square", {"osm": {**src, **osm_keys}, "length_m": length})
        return osm.find_loop(data, r, helpers.silent), data, r

    def test_single_closed_way(self):
        ways = {10: (self.ring + [1], {"highway": "raceway", "oneway": "yes"})}
        loop, _, _ = self._find(ways)
        self.assertEqual(loop.way_ids, [10])
        self.assertEqual(sorted(int(n) for n in loop.node_ids), self.ring)
        self.assertAlmostEqual(loop.raw_length, 4000.0, delta=4.0)
        self.assertTrue(loop.directed)

    def test_oneway_gives_the_driving_direction(self):
        # The second way is drawn against the driving direction and tagged oneway=-1, so the
        # lap runs 1 -> 2 -> ... -> 11 -> 12 -> ... -> 20 -> 1 (clockwise).
        ways = {10: ([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], {"highway": "raceway", "oneway": "yes"}),
                11: ([1, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11], {"highway": "raceway", "oneway": "-1"})}
        loop, _, _ = self._find(ways)
        i = loop.node_ids.index("1")
        self.assertEqual(loop.node_ids[(i + 1) % 20], "2")
        self.assertEqual(loop.node_ids[(i + 11) % 20], "12")
        self.assertEqual(loop.way_ids, [10, 11])
        self.assertTrue(loop.directed)

    def test_untagged_direction_is_flagged(self):
        ways = {10: (self.ring + [1], {"highway": "raceway"})}
        loop, _, _ = self._find(ways)
        self.assertFalse(loop.directed)
        self.assertTrue(any("direction" in w for w in loop.warnings))

    def test_pit_lane_is_not_chosen_even_when_its_lap_fits_better(self):
        # A pit lane 4 -> 8 cuts the north-east corner: that lap is 3766 m. With an official
        # length of 3700 m the pit lap is the better match by length alone.
        ways = {10: (self.ring + [1], {"highway": "raceway", "oneway": "yes"}),
                12: ([4, 8], {"highway": "raceway", "oneway": "yes", "name": "Pit Lane"})}
        loop, _, _ = self._find(ways, length=3700, length_tolerance=0.2)
        self.assertEqual(loop.way_ids, [10])
        self.assertEqual(len(loop.candidates), 2)

    def test_pit_straight_is_part_of_the_lap(self):
        # The main loop is in two ways, one named "Pit Straight"; the unnamed short cut 4 -> 8
        # must not win just because of the word "pit".
        ways = {10: ([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], {"highway": "raceway", "oneway": "yes",
                                                             "name": "Pit Straight"}),
                11: ([11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 1], {"highway": "raceway", "oneway": "yes"}),
                12: ([4, 8], {"highway": "raceway", "oneway": "yes"})}
        loop, _, _ = self._find(ways, length=4000, length_tolerance=0.1)
        self.assertEqual(sorted(loop.way_ids), [10, 11])

    def test_recipe_direction_silences_the_direction_warning(self):
        ways = {10: (self.ring + [1], {"highway": "raceway"})}
        data = osm.parse(helpers.osm_xml(self.nodes, ways))
        r = recipe.from_dict("test_square", {"osm": {"bbox": [13.9, 46.9, 14.1, 47.1]}, "length_m": 4000,
                                             "layout": {"direction": "anticlockwise"}})
        self.assertEqual(osm.find_loop(data, r, helpers.silent).warnings, [])

    def test_member_with_pit_role_is_dropped(self):
        ways = {10: (self.ring + [1], {"highway": "raceway", "oneway": "yes"}),
                12: ([4, 8], {"highway": "raceway", "oneway": "yes"})}
        rel = (77, [("way", 10, ""), ("way", 12, "pit_lane")])
        loop, _, _ = self._find(ways, relation=rel)
        self.assertEqual(len(loop.candidates), 1)

    def test_two_equally_good_layouts_are_ambiguous(self):
        # An unnamed alternative for one side, 2 m longer than the direct way.
        nodes = dict(self.nodes)
        mid = ((nodes[1][0] + nodes[6][0]) / 2 + 0.0002, (nodes[1][1] + nodes[6][1]) / 2)
        nodes[21] = mid
        self.nodes = nodes
        ways = {10: (self.ring + [1], {"highway": "raceway", "oneway": "yes"}),
                12: ([1, 21, 6], {"highway": "raceway", "oneway": "yes"})}
        with self.assertRaises(BuildError) as cm:
            self._find(ways)
        self.assertIn("ambiguous", str(cm.exception))
        self.assertIn("way 12", str(cm.exception))
        loop, _, _ = self._find(ways, exclude_ways=[12])
        self.assertEqual(loop.way_ids, [10])

    def test_gap_in_the_data_is_reported(self):
        ways = {10: ([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], {"highway": "raceway"}),
                11: ([11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 1], {"highway": "raceway"})}
        with self.assertRaises(BuildError) as cm:
            self._find(ways)
        msg = str(cm.exception)
        self.assertIn("do not form a closed loop", msg)
        self.assertIn("way 10", msg)
        self.assertIn("dead end", msg)
        self.assertIn("200.0 m away", msg)

    def test_start_finish_from_tagged_node(self):
        ways = {10: (self.ring + [1], {"highway": "raceway", "oneway": "yes"})}
        nodes = dict(self.nodes)
        nodes[903] = (46.0, 14.0)              # a finish line of some other track, far away
        xml = helpers.osm_xml(nodes, ways, node_tags={3: {"raceway": "finish"}, 903: {"raceway": "finish"}})
        data = osm.parse(xml)
        self.assertIn("3", data.node_tags)
        r = recipe.from_dict("test_square", {"osm": {"bbox": [13.9, 46.9, 14.1, 47.1]}, "length_m": 4000})
        loop = osm.find_loop(data, r, helpers.silent)
        finish, start, source = osm.start_finish_nodes(data, r, loop)
        self.assertEqual(finish, data.nodes["3"])      # the far-away tagged node 903 is ignored
        self.assertIsNone(start)
        self.assertIn("raceway=finish", source)

    def test_bbox_extract_is_reduced_to_raceways(self):
        ways = {10: (self.ring + [1], {"highway": "raceway"}),
                50: ([1, 2], {"highway": "residential"})}
        nodes = dict(self.nodes)
        nodes[99] = (47.01, 14.01)
        small = osm._reduce_bbox_extract(helpers.osm_xml(nodes, ways))
        data = osm.parse(small)
        self.assertEqual(list(data.ways), [10])
        self.assertNotIn("99", data.nodes)
        self.assertEqual(len(data.nodes), 20)


if __name__ == "__main__":
    unittest.main()
