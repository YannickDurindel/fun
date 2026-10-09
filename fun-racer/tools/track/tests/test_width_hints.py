"""OSM width tags as a hint: recorded per stretch of the lap, compared with the recipe's widths,
never applied. Synthetic data plus the committed Zandvoort cache (width = 10 on every way)."""
import importlib.util
import os
import unittest

import helpers
from lib import centreline, net, osm, recipe

HAVE_NUMPY = importlib.util.find_spec("numpy") is not None
STEP = 2.0


class Data:
    def __init__(self, widths):
        self.ways = {wid: osm.Way(wid, [], {"width": w} if w is not None else {}) for wid, w in widths.items()}


class WidthTagTest(unittest.TestCase):
    def test_parsing(self):
        for text, want in (("10", 10.0), ("10.5", 10.5), ("10,5", 10.5), (" 12 m", 12.0), ("9 metres", 9.0),
                           ("wide", None), ("30'", None), ("2 lanes", None), ("0", None), ("400", None), ("", None)):
            self.assertEqual(osm.width_tag({"width": text}), want, text)
        self.assertIsNone(osm.width_tag({}))

    def test_the_loop_remembers_the_way_of_every_node(self):
        nodes = helpers.square_nodes(per_side=5)
        ids = [str(i) for i in range(1, 21)]
        ways = {10: (ids[:11], {"highway": "raceway", "oneway": "yes", "width": "10"}),
                11: (ids[10:] + ids[:1], {"highway": "raceway", "oneway": "yes"})}
        data = osm.parse(helpers.osm_xml({str(k): v for k, v in nodes.items()}, ways,
                                         relation=(1, [("way", 10, ""), ("way", 11, "")])))
        rec = recipe.from_dict("somewhere", {"osm": {"relation": 1}, "length_m": 4000})
        loop = osm.find_loop(data, rec, helpers.silent)
        self.assertEqual(len(loop.node_ways), len(loop.node_ids))
        self.assertEqual(set(loop.node_ways), {10, 11})
        for node, way in zip(loop.node_ids, loop.node_ways):
            self.assertIn(node, data.ways[way].nodes)
        explicit = osm.chain_explicit(data.ways, [10, 11], osm._Proj(data, list(data.ways.values())))
        self.assertEqual(len(explicit.node_ways), len(explicit.node_ids))
        self.assertEqual(explicit.node_ways.count(10), 11)

    def test_stretches_along_the_lap(self):
        # 1000 samples: way 1 (10 m), way 2 (no tag), ways 3 and 4 (both 8 m), way 1 again.
        ways = [1] * 200 + [2] * 300 + [3] * 100 + [4] * 150 + [1] * 250
        tags = centreline.osm_width_tags(Data({1: "10", 2: None, 3: "8", 4: "8"}), ways, STEP)
        self.assertEqual(tags, [{"s": [1000.0, 1500.0], "width": 8.0, "ways": [3, 4]},
                                {"s": [1500.0, 400.0], "width": 10.0, "ways": [1]}])   # wraps the line
        self.assertEqual(centreline.osm_width_tags(Data({1: None, 2: None, 3: None, 4: None}), ways, STEP), [])
        whole = centreline.osm_width_tags(Data({1: "10", 2: "10", 3: "10", 4: "10"}), ways, STEP)
        self.assertEqual(whole, [{"s": [0.0, 2000.0], "width": 10.0, "ways": [1, 2, 3, 4]}])

    def test_warnings_beyond_the_tolerance(self):
        tags = [{"s": [1000.0, 1500.0], "width": 8.0, "ways": [3]}, {"s": [1500.0, 400.0], "width": 10.0, "ways": [1]}]
        built = [13.0] * 1000
        w = centreline.width_tag_warnings(tags, built, STEP)
        self.assertEqual(len(w), 2)
        self.assertIn("8 m wide from s = 1000 to 1500", w[0])
        self.assertIn("13.0 m", w[0])
        self.assertIn("not applied", w[0])
        # Within 1.5 m: nothing to say. A road that is right somewhere in the stretch is not
        # reported either (the tag is one number for a whole way).
        self.assertEqual(centreline.width_tag_warnings(tags[:1], [9.4] * 1000, STEP), [])
        mixed = [13.0] * 500 + [8.5] * 250 + [13.0] * 250
        self.assertEqual(centreline.width_tag_warnings(tags[:1], mixed, STEP), [])
        self.assertEqual(len(centreline.width_tag_warnings(tags[:1], [6.0] * 1000, STEP)), 1)

    @unittest.skipUnless(HAVE_NUMPY, "cad/track/banking.py needs numpy (use the project venv)")
    def test_zandvoort_reports_its_tags_and_does_not_apply_them(self):
        rec = recipe.load("zandvoort")
        raw = os.path.join(helpers.ROOT, "assets", "tracks", "zandvoort", "raw")
        track, info = centreline.build(rec, net.Fetcher(raw, True, helpers.silent), helpers.silent)
        tags = info["osm"]["width_tags"]
        self.assertEqual(len(tags), 1)
        self.assertEqual(tags[0]["width"], 10.0)
        self.assertEqual(tags[0]["s"], [0.0, round(track["length"], 1)])
        self.assertEqual(len(tags[0]["ways"]), 24)
        self.assertTrue(any("OSM tags the road as 10 m wide" in w for w in info["warnings"]))
        with open(os.path.join(helpers.ROOT, "assets", "tracks", "zandvoort", "track.json"), encoding="utf-8") as f:
            import json
            committed = json.load(f)
        self.assertEqual([p["width"] for p in track["points"]], [p["width"] for p in committed["points"]])

    def test_red_bull_ring_has_none(self):
        data = osm.parse(helpers.rbr_osm_xml())
        self.assertTrue(all(osm.width_tag(w.tags) is None for w in data.ways.values()))


if __name__ == "__main__":
    unittest.main()
