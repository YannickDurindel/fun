"""Surroundings step: projection, polygons, rasters, trees, the road cut and the recipe keys.

    .venv/bin/python -m unittest tools/track/tests/test_surroundings.py

Offline, on small made-up fixtures. The meshes are in test_surroundings_mesh.py.
"""
import importlib.util
import json
import math
import os
import tempfile
import unittest

import helpers
from lib import geom, net, recipe as recipe_mod
from lib.net import BuildError

HAVE_NUMPY = all(importlib.util.find_spec(m) is not None for m in ("numpy", "scipy", "PIL"))
if HAVE_NUMPY:
    import numpy as np
    from lib import surroundings as sur


def square(x0, z0, size):
    return np.array([[x0, z0], [x0 + size, z0], [x0 + size, z0 + size], [x0, z0 + size]], dtype=float)


def ring_track(radius=200.0, n=628, width=12.0, verge=30.0):
    """A circular lap driven clockwise on the map, as (track dict, profile dict)."""
    ang = np.arange(n) * 2.0 * np.pi / n
    pts = [{"p": [float(radius * math.sin(a)), 0.0, float(-radius * math.cos(a))]} for a in ang]
    track = {"points": pts, "step": 2.0 * math.pi * radius / n}
    profile = {"width": [width] * n, "bank": [0.0] * n, "verge_left": [verge] * n, "verge_right": [verge] * n}
    return track, profile


class FlatGround:
    near_rect = [-500.0, 500.0, -500.0, 500.0]

    def height(self, x, z):
        return np.zeros(np.shape(x)) + 0.0 * np.asarray(z)

    def track_distance(self, x, z):
        return np.abs(np.hypot(x, z) - 200.0)


class ProjectionTest(unittest.TestCase):
    def test_round_trip(self):
        pr = geom.Projection(43.7350269, 7.4212652, 1.0081266)
        for lat, lon in ((43.74, 7.43), (43.70, 7.39), (43.7350269, 7.4212652)):
            x, z = pr.to_xz(lat, lon)
            la, lo = pr.to_latlon(x, z)
            self.assertAlmostEqual(la, lat, places=12)
            self.assertAlmostEqual(lo, lon, places=12)
        self.assertEqual(pr.to_xz(43.7350269, 7.4212652), (0.0, 0.0))

    def test_axes_and_scale(self):
        pr = geom.Projection(50.0, 6.0, 2.0)
        x, z = pr.to_xz(50.001, 6.0)
        self.assertAlmostEqual(x, 0.0)
        self.assertAlmostEqual(z, -2.0 * 111.32)     # north is -z; k scales the plan
        x, _ = pr.to_xz(50.0, 6.001)
        self.assertAlmostEqual(x, 2.0 * 111.32 * math.cos(math.radians(50.0)))

    def test_same_bits_as_the_formulas_it_replaced(self):
        """The centreline step (k = 1) and the terrain step (k = plan scale) wrote these
        expressions inline; the committed tracks depend on their exact result."""
        lat0, lon0, k = 47.2202964, 14.7667292, 4318.0 / 4302.1
        kx = geom.EARTH_M_PER_DEG * math.cos(math.radians(lat0))
        ky = geom.EARTH_M_PER_DEG
        one, scaled = geom.Projection(lat0, lon0), geom.Projection(lat0, lon0, k)
        for lat, lon in ((47.2231, 14.7598), (47.2188, 14.7702)):
            self.assertEqual(one.to_xz(lat, lon), ((lon - lon0) * kx, -(lat - lat0) * ky))
        for x, z in ((-1600.0, 600.0), (812.5, -333.25)):
            self.assertEqual(scaled.to_latlon(x, z), (lat0 - (z / k) / ky, lon0 + (x / k) / kx))
            self.assertEqual(one.to_latlon(x, z), (lat0 - z / ky, lon0 + x / kx))


class RecipeTest(unittest.TestCase):
    BASE = {"length_m": 4000, "osm": {"relation": 1}}

    def load(self, section):
        return recipe_mod.from_dict("test_track", dict(self.BASE, surroundings=section), calendar_path="/nonexistent")

    def test_no_section_means_defaults(self):
        r = recipe_mod.from_dict("test_track", dict(self.BASE), calendar_path="/nonexistent")
        self.assertEqual(r.surroundings, {})

    def test_full_section_is_accepted(self):
        r = self.load({
            "margin_m": 300, "far_margin_m": 2000, "default_levels": 5, "level_height_m": 3.2,
            "tree_density": 80, "tree_species": "palm",
            "building": [{"osm": 123, "height": 40.0}, {"osm": "relation/9", "levels": 12, "type": "hotel"},
                         {"osm": 5, "remove": True, "note": "demolished"}],
            "exclude": [{"osm": 77}, {"polygon": [[43.0, 7.0], [43.1, 7.0], [43.1, 7.1]]}],
            "add": [{"polygon": [[43.0, 7.0], [43.1, 7.0], [43.1, 7.1]], "height": 12.0, "kind": "grandstand"}],
            "roof": [{"s": [1505.0, 1910.0], "clear_height": 6.0, "kind": "tunnel"}, {"s": [3900.0, 50.0]}]})
        self.assertEqual(r.surroundings["roof"][0]["s"], [1505.0, 1910.0])

    def test_unknown_keys_fail(self):
        for section in ({"margin": 300}, {"building": [{"osm": 1, "height": 9, "colour": "red"}]},
                        {"roof": [{"s": [0, 10], "height": 5}]}, {"add": [{"polygon": [[1, 1], [2, 2], [3, 1]], "tall": 1}]},
                        {"exclude": [{"way": 5}]}):
            with self.assertRaises(BuildError, msg=section) as cm:
                self.load(section)
            self.assertIn("unknown key", str(cm.exception))

    def test_bad_values_fail(self):
        for section in ({"tree_density": -1}, {"default_levels": "five"}, {"tree_species": "oak"},
                        {"building": [{"osm": 1}]}, {"building": [{"osm": "building/1", "height": 5}]},
                        {"exclude": [{"osm": 1, "polygon": [[1, 1], [2, 2], [3, 1]]}]},
                        {"add": [{"polygon": [[1, 1], [2, 2]]}]}, {"add": [{"polygon": [[1, 1], [2, 2], [3, 1]], "kind": "castle"}]},
                        {"roof": [{"s": [100.0, 5000.0]}]}, {"roof": [{"s": [10.0, 10.0]}]},
                        {"roof": [{"s": [0, 100], "kind": "cave"}]}, {"roof": {"s": [0, 100]}},
                        {"roof": [{"s": [0, 100], "clear_height": 1.0}]}, {"tree_species": ["palm"]},
                        {"add": [{"polygon": [[1, 1], [2, 2], [3, 1]], "kind": ["building"]}]},
                        {"add": [{"polygon": [[1, 1], [2, 2], [3, 1]], "height": 6.0, "min_height": 8.0}]}):
            with self.assertRaises(BuildError, msg=section):
                self.load(section)


class OverpassTest(unittest.TestCase):
    def test_offline_cache_miss_fails_and_a_hit_needs_no_network(self):
        with tempfile.TemporaryDirectory() as d:
            f = net.Fetcher(d, offline=True, log=helpers.silent)
            with self.assertRaises(BuildError):
                net.fetch_overpass(f, "[out:json];node(1);out;", "surroundings_near_x.json")
            f.write("surroundings_near_x.json", b'{"elements":[]}')
            self.assertEqual(net.fetch_overpass(f, "anything", "surroundings_near_x.json"), b'{"elements":[]}')
            self.assertEqual(f.requests, 0)

    def test_busy_servers_are_retried_and_a_bad_query_is_not(self):
        import urllib.error
        f = net.Fetcher("/nonexistent", log=helpers.silent)
        answers = [urllib.error.HTTPError("u", 429, "Too Many Requests", {}, None),
                   urllib.error.HTTPError("u", 504, "Gateway Timeout", {}, None),
                   b'{"elements": [], "remark": "runtime error: Query timed out"}',
                   b'{"elements": [{"type": "node", "id": 1}]}']
        urls, pauses = [], []

        def opener(req):
            urls.append(req.full_url)
            self.assertIn("fun-racer", req.get_header("User-agent"))
            a = answers.pop(0)
            if isinstance(a, Exception):
                raise a
            return a

        res = net._overpass_request(f, "query", opener, pauses.append)
        self.assertEqual(res["elements"], [{"type": "node", "id": 1}])
        self.assertEqual(f.requests, 4)
        self.assertEqual(pauses, sorted(pauses))            # the pause grows
        self.assertGreater(len(set(urls)), 1)               # and the mirrors take turns
        with self.assertRaises(BuildError):
            net._overpass_request(f, "bad", lambda req: (_ for _ in ()).throw(
                urllib.error.HTTPError("u", 400, "Bad Request", {}, None)), pauses.append)

    def test_two_seconds_between_requests(self):
        with tempfile.TemporaryDirectory() as d:
            lock = os.path.join(d, "overpass.lock")
            open(lock, "w").close()
            mtime = os.path.getmtime(lock)
            slept = []
            net._overpass_wait(lock, now=lambda: mtime + 0.5, sleep=slept.append)
            net._overpass_wait(lock, now=lambda: mtime + 5.0, sleep=slept.append)
            net._overpass_wait(os.path.join(d, "missing"), sleep=slept.append)
            self.assertEqual(len(slept), 1)
            self.assertAlmostEqual(slept[0], net.OVERPASS_PAUSE - 0.5, places=3)


@unittest.skipUnless(HAVE_NUMPY, "the surroundings step needs numpy, scipy and pillow")
class PolygonTest(unittest.TestCase):
    def test_multipolygon_is_assembled_from_split_ways_with_its_hole(self):
        # An outer square drawn as three ways (one of them backwards) and a closed inner way.
        outer = [[(0, 0), (10, 0)], [(10, 10), (10, 0)], [(10, 10), (0, 10), (0, 0)]]
        inner = [[(4, 4), (6, 4), (6, 6), (4, 6), (4, 4)]]
        rings = sur.assemble_rings(outer)
        self.assertEqual(len(rings), 1)
        self.assertEqual(len(rings[0]), 4)
        polys = sur.polygons_from_rings([np.array(rings[0], dtype=float)],
                                        [np.array(r, dtype=float) for r in sur.assemble_rings(inner)])
        self.assertEqual(len(polys), 1)
        outer_ring, holes = polys[0]
        self.assertAlmostEqual(abs(sur.sg.signed_area(outer_ring)), 100.0)
        self.assertEqual(len(holes), 1)
        self.assertAlmostEqual(abs(sur.sg.signed_area(holes[0])), 4.0)

    def test_an_open_chain_is_dropped_and_holes_go_to_the_right_outer(self):
        self.assertEqual(sur.assemble_rings([[(0, 0), (1, 0)], [(1, 0), (1, 1)]]), [])
        polys = sur.polygons_from_rings([square(0, 0, 10), square(20, 0, 10)], [square(23, 3, 2)])
        self.assertEqual([len(h) for _, h in polys], [0, 1])

    def test_points_in_rings_is_even_odd(self):
        rings = [square(0, 0, 10), square(4, 4, 2)]
        got = sur.points_in_rings([[1, 1], [5, 5], [11, 5], [9.5, 9.5]], rings)
        self.assertEqual(got.tolist(), [True, False, False, True])

    def test_simplify_keeps_corners_and_drops_points_on_a_straight_wall(self):
        ring = np.array([[0, 0], [5, 0.01], [10, 0], [10, 5], [10, 10], [5, 10], [0, 10], [0, 5]], dtype=float)
        out = sur.simplify(ring, 0.1, closed=True)
        self.assertEqual(len(out), 4)
        self.assertAlmostEqual(abs(sur.sg.signed_area(out)), 100.0)
        line = np.array([[0, 0], [1, 0.02], [2, 0], [3, 3]], dtype=float)
        self.assertEqual(sur.simplify(line, 0.1).tolist(), [[0, 0], [2, 0], [3, 3]])

    def test_clip_rect(self):
        clipped = sur.clip_rect(square(-5, -5, 10), 0.0, 20.0, 0.0, 20.0)
        self.assertAlmostEqual(abs(sur.sg.signed_area(clipped)), 25.0)
        self.assertEqual(len(sur.clip_rect(square(-5, -5, 2), 0.0, 20.0, 0.0, 20.0)), 0)

    def test_lengths_and_colours(self):
        self.assertEqual(sur.parse_length("12.5 m"), 12.5)
        self.assertEqual(sur.parse_length("12,5"), 12.5)
        self.assertAlmostEqual(sur.parse_length("40 ft"), 12.192)
        self.assertIsNone(sur.parse_length("tall"))
        self.assertEqual(sur.parse_colour("#fff"), (1.0, 1.0, 1.0))
        self.assertEqual(sur.parse_colour("Red"), (0xb2 / 255, 0x22 / 255, 0x22 / 255))
        self.assertIsNone(sur.parse_colour("sort of beige"))


@unittest.skipUnless(HAVE_NUMPY, "the surroundings step needs numpy, scipy and pillow")
class ReduceTest(unittest.TestCase):
    def answer(self):
        def geo(pts):
            return [{"lat": la, "lon": lo} for la, lo in pts]
        house = [(50.0010, 6.0010), (50.0010, 6.0012), (50.00105, 6.0012), (50.0011, 6.0012), (50.0011, 6.0010),
                 (50.0010, 6.0010)]
        return {"osm3s": {"timestamp_osm_base": "2026-10-01T00:00:00Z"}, "elements": [
            {"type": "way", "id": 1, "tags": {"building": "house", "building:levels": "2", "addr:street": "x"},
             "geometry": geo(house)},
            {"type": "way", "id": 2, "tags": {"highway": "residential", "maxspeed": "30"},
             "geometry": geo([(50.0, 5.9), (50.0005, 6.0005), (50.001, 6.001), (50.3, 6.3), (50.4, 6.4)])},
            {"type": "node", "id": 3, "lat": 50.0005, "lon": 6.0005, "tags": {"natural": "tree", "leaf_type": "needleleaved"}},
            {"type": "relation", "id": 4, "tags": {"type": "multipolygon", "natural": "wood"}, "members": [
                {"type": "way", "ref": 10, "role": "outer", "geometry": geo([(49.99, 5.99), (49.99, 6.01), (50.01, 6.01)])},
                {"type": "way", "ref": 11, "role": "outer", "geometry": geo([(50.01, 6.01), (50.01, 5.99), (49.99, 5.99)])},
                {"type": "way", "ref": 12, "role": "inner",
                 "geometry": geo([(50.0004, 6.0004), (50.0004, 6.0008), (50.0008, 6.0008), (50.0008, 6.0004), (50.0004, 6.0004)])}]},
            {"type": "relation", "id": 5, "tags": {"type": "route"}, "members": []}]}

    def test_reduce_keeps_used_tags_clips_and_assembles(self):
        body = sur.reduce_overpass(self.answer(), (50.0, 6.0, 50.002, 6.002), tol=0.4)
        data = json.loads(body)
        self.assertEqual(data["osm_base"], "2026-10-01T00:00:00Z")
        by_id = {e["id"]: e for e in data["elements"]}
        self.assertEqual(sorted(by_id), [1, 2, 3, 4])
        self.assertEqual(by_id[1]["tags"], {"building": "house", "building:levels": "2"})
        self.assertEqual(len(by_id[1]["g"]), 2 * 5)             # the point in the middle of a wall is gone
        self.assertEqual(by_id[2]["tags"], {"highway": "residential"})
        self.assertEqual(len(by_id[2]["g"]), 2 * 3)             # the far end is cut off, a straight thinned
        wood = by_id[4]
        self.assertEqual((len(wood["o"]), len(wood["i"])), (1, 1))
        lats = wood["o"][0][0::2]
        self.assertGreaterEqual(min(lats), 50.0)                # clipped to the box
        self.assertLessEqual(max(lats), 50.002)
        self.assertEqual(body.count(b"\n"), len(data["elements"]) + 2)   # one element per line

    def test_a_segment_crossing_a_corner_of_the_box_is_kept(self):
        res = {"elements": [{"type": "way", "id": 9, "tags": {"natural": "coastline"}, "geometry": [
            {"lat": 49.9, "lon": 6.0015}, {"lat": 50.0005, "lon": 5.9}, {"lat": 49.0, "lon": 5.0}]}]}
        data = json.loads(sur.reduce_overpass(res, (50.0, 6.0, 50.002, 6.002), tol=0.4))
        self.assertEqual(len(data["elements"]), 1)
        self.assertEqual(data["elements"][0]["g"][:4], [49.9, 6.0015, 50.0005, 5.9])

    def test_footpaths_are_not_cached_but_foot_bridges_are(self):
        self.assertTrue(sur.line_is_used({"highway": "service"}))
        self.assertTrue(sur.line_is_used({"waterway": "stream"}))
        self.assertFalse(sur.line_is_used({"highway": "footway"}))
        self.assertTrue(sur.line_is_used({"highway": "footway", "bridge": "yes"}))

    def test_features_come_back_in_game_metres(self):
        pr = geom.Projection(50.0, 6.0)
        feats, _ = sur.load_features(sur.reduce_overpass(self.answer(), (50.0, 6.0, 50.002, 6.002), tol=0.4), pr)
        by_ref = {f.ref: f for f in feats}
        house = by_ref["way/1"]
        self.assertEqual(len(house.outers[0]), 4)
        self.assertAlmostEqual(abs(sur.sg.signed_area(house.outers[0])), 11.132 * 0.0002 * pr.kx, delta=0.5)
        self.assertIsNotNone(by_ref["way/2"].line)
        self.assertEqual(by_ref["way/2"].outers, [])
        x, z = by_ref["node/3"].point
        self.assertAlmostEqual(z, -55.66, places=2)
        self.assertEqual(len(by_ref["relation/4"].inners), 1)
        self.assertEqual(sur.land_class(by_ref["relation/4"].tags), (sur.FOREST, sur.T_MIXED))

    def test_query_boxes_survive_a_small_change_of_scale(self):
        a = sur.queries(geom.Projection(47.22, 14.7667, 1.0037), [-1600, 800, -1200, 600], [-6400, 5600, -6200, 5800], 3000.0)
        b = sur.queries(geom.Projection(47.22, 14.7667, 1.0031), [-1600, 800, -1200, 600], [-6400, 5600, -6200, 5800], 3000.0)
        self.assertEqual(a, b)
        self.assertRegex(a["near"][2], r"^surroundings_near_[0-9a-f]{10}\.json$")
        self.assertNotEqual(a["near"][2].split("_")[2], a["far"][2].split("_")[2])
        self.assertIn("[bbox:", a["near"][0])
        self.assertIn('"natural"="coastline"', a["far"][0])


@unittest.skipUnless(HAVE_NUMPY, "the surroundings step needs numpy, scipy and pillow")
class RasterTest(unittest.TestCase):
    def test_cells_are_filled_by_their_centre_and_holes_stay_open(self):
        r = sur.Raster(0.0, 0.0, 2.5, 40, 40)
        r.paint([square(10, 20, 50), square(30, 40, 10)], sur.FOREST, sur.T_NEEDLE)
        self.assertEqual(int(np.sum(r.cls == sur.FOREST)), (50 * 50 - 10 * 10) // int(2.5 * 2.5 * 4) * 4)
        self.assertEqual(r.cls[8, 4], sur.FOREST)      # row = z (20 m), column = x (10 m)
        self.assertEqual(r.cls[7, 4], sur.GRASS)
        self.assertEqual(r.cls[8, 3], sur.GRASS)
        self.assertEqual(r.cls[18, 14], sur.GRASS)     # inside the hole
        self.assertEqual(r.trees[10, 10], sur.T_NEEDLE)
        self.assertEqual(r.at(r.cls, 11.0, 21.0), sur.FOREST)

    def test_later_shapes_paint_over_earlier_ones_and_clip_to_the_grid(self):
        r = sur.Raster(100.0, -50.0, 50.0, 10, 10)
        r.paint([square(-1000, -1000, 5000)], sur.FARMLAND)
        self.assertTrue((r.cls == sur.FARMLAND).all())
        r.paint([square(150, 0, 100)], sur.WATER)
        self.assertEqual(int(np.sum(r.cls == sur.WATER)), 4)
        self.assertEqual(r.cls[1, 1], sur.WATER)
        r.paint([square(9000, 9000, 10)], sur.ROCK)    # outside: nothing happens
        self.assertFalse((r.cls == sur.ROCK).any())

    def test_roads_are_strips_and_tunnels_leave_no_trace(self):
        r = sur.Raster(0.0, 0.0, 2.5, 40, 40)
        road = sur.line_strip({"highway": "primary"})
        self.assertEqual(road, (sur.PAVED, 8.0))
        r.paint_lines([(np.array([[0.0, 51.25], [100.0, 51.25]]), road[1])], road[0])     # centre of row 20
        col = r.cls[:, 20]
        self.assertEqual(int(np.sum(col == sur.PAVED)), 3)
        self.assertEqual(np.flatnonzero(col == sur.PAVED).tolist(), [19, 20, 21])
        self.assertIsNone(sur.line_strip({"highway": "primary", "tunnel": "yes"}))
        self.assertIsNone(sur.line_strip({"highway": "secondary", "bridge": "yes"}))
        self.assertEqual(sur.line_strip({"highway": "track"})[0], sur.GRAVEL)
        self.assertEqual(sur.line_strip({"waterway": "river", "width": "22"}), (sur.WATER, 22.0))

    def test_tags_map_to_the_ten_classes(self):
        cases = [({"natural": "wood", "leaf_type": "broadleaved"}, (sur.FOREST, sur.T_BROAD)),
                 ({"landuse": "forest"}, (sur.FOREST, sur.T_MIXED)), ({"natural": "water"}, (sur.WATER, sur.T_NONE)),
                 ({"natural": "sand"}, (sur.SAND, sur.T_NONE)), ({"natural": "beach"}, (sur.BEACH, sur.T_NONE)),
                 ({"landuse": "residential"}, (sur.PAVED, sur.T_NONE)), ({"amenity": "parking"}, (sur.PAVED, sur.T_NONE)),
                 ({"landuse": "farmland"}, (sur.FARMLAND, sur.T_NONE)), ({"natural": "bare_rock"}, (sur.ROCK, sur.T_NONE)),
                 ({"natural": "scrub"}, (sur.SCRUB, sur.T_SCRUB)), ({"leisure": "park"}, (sur.GRASS, sur.T_PARK)),
                 ({"golf": "bunker"}, (sur.SAND, sur.T_NONE)), ({"landuse": "railway"}, (sur.GRAVEL, sur.T_NONE))]
        for tags, want in cases:
            self.assertEqual(sur.land_class(tags), want, tags)
        self.assertIsNone(sur.land_class({"landuse": "military"}))
        self.assertIsNone(sur.land_class({"amenity": "parking", "parking": "underground"}))
        self.assertEqual(len(sur.CLASSES), 10)
        self.assertEqual(sur.CLASSES.index("beach"), 9)

    def test_png_round_trip(self):
        from PIL import Image
        r = sur.Raster(0.0, 0.0, 2.5, 8, 6)
        r.paint([square(0, 0, 10)], sur.BEACH)
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "landcover.png")
            r.save(path)
            img = Image.open(path)
            self.assertEqual((img.mode, img.size), ("L", (8, 6)))
            self.assertTrue((np.asarray(img) == r.cls).all())


@unittest.skipUnless(HAVE_NUMPY, "the surroundings step needs numpy, scipy and pillow")
class SeaTest(unittest.TestCase):
    RECT = [0.0, 100.0, 0.0, 100.0]

    def test_water_is_on_the_right_of_the_coastline(self):
        # Heading east on a north-up map, the right-hand side is the south: larger z.
        seas = sur.sea_polygons([np.array([[-20.0, 40.0], [50.0, 40.0], [120.0, 40.0]])], self.RECT, helpers.silent)
        self.assertEqual(len(seas), 1)
        self.assertAlmostEqual(abs(sur.sg.signed_area(seas[0][0])), 6000.0)
        self.assertTrue(sur.points_in_rings([[50.0, 90.0]], [seas[0][0]])[0])
        self.assertFalse(sur.points_in_rings([[50.0, 10.0]], [seas[0][0]])[0])
        # The same line drawn the other way puts the water in the north.
        seas = sur.sea_polygons([np.array([[120.0, 40.0], [-20.0, 40.0]])], self.RECT, helpers.silent)
        self.assertAlmostEqual(abs(sur.sg.signed_area(seas[0][0])), 4000.0)

    def test_ways_are_joined_and_an_island_becomes_a_hole(self):
        coast = [np.array([[50.0, 40.0], [120.0, 40.0]]), np.array([[-20.0, 40.0], [50.0, 40.0]])]
        # Land on the left of the way: an island runs anticlockwise on the map (y = -z up).
        island = np.array([[40.0, 80.0], [60.0, 80.0], [60.0, 60.0], [40.0, 60.0], [40.0, 80.0]])
        seas = sur.sea_polygons(coast + [island], self.RECT, helpers.silent)
        self.assertEqual(len(seas), 1)
        self.assertEqual(len(seas[0][1]), 1)
        ring = sur.sg.merge_holes(*seas[0])
        self.assertAlmostEqual(abs(sur.sg.signed_area(ring)), 6000.0 - 400.0)

    def test_a_bay_between_two_headlands(self):
        # The coast comes in from the west, runs round a bay and leaves to the north.
        coast = np.array([[-10.0, 70.0], [30.0, 70.0], [30.0, 30.0], [70.0, 30.0], [70.0, -10.0]])
        seas = sur.sea_polygons([coast], self.RECT, helpers.silent)
        area = sum(abs(sur.sg.signed_area(o)) for o, _ in seas)
        self.assertAlmostEqual(area, 10000.0 - 70.0 * 70.0 + 40.0 * 40.0)
        self.assertTrue(sur.points_in_rings([[90.0, 90.0]], [seas[0][0]])[0])

    def test_no_coast_no_sea(self):
        self.assertEqual(sur.sea_polygons([np.array([[500.0, 500.0], [600.0, 600.0]])], self.RECT, helpers.silent), [])


@unittest.skipUnless(HAVE_NUMPY, "the surroundings step needs numpy, scipy and pillow")
class CorridorTest(unittest.TestCase):
    def setUp(self):
        self.corridor = sur.Corridor(*ring_track())

    def clear(self, ring, margin=sur.ROAD_CLEAR):
        r = np.hypot(ring[:, 0], ring[:, 1])
        return float(np.min(np.abs(r - 200.0))) - (6.0 + margin)

    def test_right_is_the_inside_of_a_clockwise_lap(self):
        idx, lat, dist = self.corridor.nearest([[0.0, -190.0], [0.0, -215.0]])
        self.assertEqual(idx[0], idx[1])
        self.assertAlmostEqual(lat[0], 10.0, places=3)
        self.assertAlmostEqual(lat[1], -15.0, places=3)
        self.assertGreater(self.corridor.turn[idx[0]], 0.0)
        self.assertAlmostEqual(abs(self.corridor.turn[idx[0]]), 1.0 / 200.0, places=5)

    def test_a_building_away_from_the_road_is_untouched(self):
        ring = square(300.0, 300.0, 20.0)
        self.assertEqual(len(self.corridor.cut(ring)), 1)
        self.assertTrue(np.array_equal(self.corridor.cut(ring)[0], ring))

    def test_a_building_on_the_road_is_gone(self):
        self.assertEqual(self.corridor.cut(square(-2.0, -202.0, 4.0)), [])

    def test_a_building_overlapping_the_edge_is_cut_back(self):
        ring = np.array([[-10.0, -215.0], [10.0, -215.0], [10.0, -203.0], [-10.0, -203.0]])   # 3 m into the road
        pieces = self.corridor.cut(ring)
        self.assertEqual(len(pieces), 1)
        self.assertGreaterEqual(self.clear(pieces[0]), -0.05)
        area = abs(sur.sg.signed_area(pieces[0]))
        self.assertAlmostEqual(area, 20.0 * (215.0 - 207.5), delta=3.0)

    def test_a_building_over_the_road_becomes_one_piece_per_side(self):
        ring = np.array([[-10.0, -230.0], [10.0, -230.0], [10.0, -170.0], [-10.0, -170.0]])
        pieces = self.corridor.cut(ring)
        self.assertEqual(len(pieces), 2)
        for p in pieces:
            self.assertGreaterEqual(self.clear(p), -0.05)
            self.assertFalse(self.corridor.on_road(p, sur.ROAD_CLEAR - 0.1).any())
        sides = sorted(float(np.hypot(*p.mean(axis=0))) for p in pieces)
        self.assertLess(sides[0], 200.0)
        self.assertGreater(sides[1], 200.0)
        total = sum(abs(sur.sg.signed_area(p)) for p in pieces)
        self.assertAlmostEqual(total, 20.0 * 60.0 - 20.0 * 15.0, delta=6.0)

    def test_trees_keep_off_the_road_the_verges_and_the_run_off(self):
        raster = sur.Raster(-500.0, -500.0, 2.5, 400, 400)
        raster.paint([square(-500.0, -500.0, 1000.0)], sur.FOREST, sur.T_MIXED)
        raster.paint([square(300.0, 300.0, 40.0)], sur.PAVED, sur.T_NONE, built=True)
        mapped = [(0.0, -200.0, 0.0, -1), (0.0, -170.0, 9.0, sur.PALM), (400.0, 400.0, 0.0, -1), (310.0, 310.0, 0.0, -1)]
        trees = sur.scatter_trees(raster, FlatGround(), self.corridor, 120.0, "mixed", 7, mapped)
        self.assertGreater(len(trees), 5000)
        r = np.hypot(trees[:, 0], trees[:, 2])
        inside, outside = r < 200.0, r > 200.0
        # Inside the lap: road half-width + 30 m verge + the gap. Outside (the outside of
        # one long corner): never closer than that, and no closer than the run-off.
        self.assertGreaterEqual(float(np.min(200.0 - r[inside])), 6.0 + 30.0 + sur.TREE_VERGE_GAP - 0.1)
        self.assertGreaterEqual(float(np.min(r[outside] - 200.0)), 6.0 + sur.RUNOFF - 0.1)
        self.assertFalse(((trees[:, 0] > 300) & (trees[:, 0] < 340) & (trees[:, 2] > 300) & (trees[:, 2] < 340)).any())
        self.assertTrue(((trees[:, 0] == 400.0) & (trees[:, 2] == 400.0)).any())      # a mapped tree in the open
        self.assertFalse(((trees[:, 0] == 0.0) & (trees[:, 2] == -170.0)).any())      # one on the verge
        self.assertTrue(set(np.unique(trees[:, 4])) <= {0.0, 1.0})
        self.assertTrue(((trees[:, 3] >= 5.0) & (trees[:, 3] <= 32.0)).all())

    def test_scatter_is_deterministic_and_thins_out_away_from_the_track(self):
        raster = sur.Raster(-500.0, -500.0, 2.5, 400, 400)
        raster.paint([square(-500.0, -500.0, 1000.0)], sur.FOREST, sur.T_NEEDLE)
        a = sur.scatter_trees(raster, FlatGround(), self.corridor, 120.0, "mixed", 7, [])
        b = sur.scatter_trees(raster, FlatGround(), self.corridor, 120.0, "mixed", 7, [])
        c = sur.scatter_trees(raster, FlatGround(), self.corridor, 120.0, "mixed", 8, [])
        self.assertTrue(np.array_equal(a, b))
        self.assertFalse(np.array_equal(a, c))
        self.assertTrue((a[:, 4] == sur.NEEDLELEAVED).all())
        r = np.hypot(a[:, 0], a[:, 2])
        near = np.sum((r > 250.0) & (r < 300.0)) / (math.pi * (300.0 ** 2 - 250.0 ** 2))
        centre = np.sum(r < 60.0) / (math.pi * 60.0 ** 2)       # 140 m and more from the track
        self.assertAlmostEqual(near * 10000.0, 120.0, delta=15.0)
        self.assertLess(centre, 0.95 * near)


@unittest.skipUnless(HAVE_NUMPY, "the surroundings step needs numpy, scipy and pillow")
class HeightTest(unittest.TestCase):
    CFG = dict(sur.DEFAULTS) if HAVE_NUMPY else {}

    def solid(self, tags, x=0.0, size=10.0):
        s = sur.Solid("way/1", tags, square(x, 0.0, size), [])
        sur.classify_solid(s)
        return s

    def test_height_comes_from_tags_then_levels_then_the_type(self):
        a = self.solid({"building": "yes", "height": "21 m", "building:levels": "3"})
        b = self.solid({"building": "apartments", "building:levels": "4", "roof:levels": "1"})
        c = self.solid({"building": "garage"})
        d = self.solid({"building": "yes"})
        sur.resolve_heights([a, b, c, d], self.CFG)
        self.assertEqual((a.height, a.source), (21.0, "tags"))
        self.assertAlmostEqual(b.height, 4.6 * 3.0)
        self.assertEqual((c.height, c.source), (3.0, "type default"))
        self.assertEqual((d.height, d.source), (6.0, "type default"))

    def test_an_untagged_town_building_takes_the_median_of_its_neighbours(self):
        known = [self.solid({"building": "yes", "height": str(h)}, x=20.0 * i) for i, h in enumerate((18, 24, 30))]
        plain = self.solid({"building": "yes"}, x=80.0)
        shed = self.solid({"building": "shed"}, x=100.0)
        far = self.solid({"building": "yes"}, x=1000.0)
        sur.resolve_heights(known + [plain, shed, far], self.CFG)
        self.assertEqual((plain.height, plain.source), (24.0, "neighbours"))
        self.assertEqual(shed.source, "type default")
        self.assertEqual((far.height, far.source), (6.0, "type default"))

    def test_grandstands_and_parts_are_recognised(self):
        self.assertEqual(self.solid({"building": "grandstand"}).kind, "stand")
        self.assertEqual(self.solid({"leisure": "bleachers"}).kind, "stand")
        self.assertEqual(self.solid({"building": "yes", "name": "Tribüne Start-Ziel"}).kind, "stand")
        self.assertEqual(self.solid({"building": "roof"}).kind, "canopy")
        self.assertEqual(self.solid({"building:part": "yes"}).kind, "part")
        self.assertEqual(self.solid({"building": "hotel", "name": "Tribune Hotel"}).kind, "building")

    def test_an_outline_covered_by_its_parts_is_dropped(self):
        outline = self.solid({"building": "yes"}, size=20.0)
        parts = [self.solid({"building:part": "yes"}, x=0.0, size=10.0)]
        for p in parts:
            p.kind = "part"
        self.assertEqual(len(sur.drop_outlines_with_parts([outline] + parts)), 2)     # a quarter: both stay
        big = sur.Solid("way/3", {"building:part": "yes"}, square(1.0, 1.0, 18.0), [])
        big.kind = "part"
        self.assertEqual(sur.drop_outlines_with_parts([outline, big]), [big])


@unittest.skipUnless(HAVE_NUMPY, "the surroundings step needs numpy, scipy and pillow")
class RebuildTest(unittest.TestCase):
    """The committed Red Bull Ring surroundings come out of its committed caches again."""

    def test_offline_rebuild_matches_the_committed_files(self):
        import shutil
        import build_track
        from lib import compare
        if not os.path.exists(os.path.join(helpers.RBR, "scenery.json")):
            self.skipTest("the surroundings of the Red Bull Ring are not built")
        with tempfile.TemporaryDirectory(prefix="scenery_rbr_") as tmp:
            for name in ("track.json", "build_info.json", "road_profile.json", "terrain.json", "terrain_height.bin",
                         "terrain_far.bin", "terrain_dist.bin"):
                shutil.copyfile(os.path.join(helpers.RBR, name), os.path.join(tmp, name))
            log = []
            status = build_track.run(["red_bull_ring", "--offline", "--out", tmp, "--steps", "surroundings"],
                                     log=log.append)
            self.assertEqual(status, 0)
            with open(os.path.join(tmp, "scenery.json"), encoding="utf-8") as f:
                meta = json.load(f)
            report = compare.compare_dirs(tmp, helpers.RBR)
            for name in compare.OPTIONAL_FILES:
                self.assertIn(name, report["identical"], f"{name} differs from the committed file")
            for name in ("scenery.glb.import", "landcover.png.import", "landcover_far.png.import"):
                self.assertTrue(os.path.exists(os.path.join(tmp, name)), name)
        # Meadows, the forest on the hill and the grandstands of the main straight.
        share = meta["landcover"]["near_share"]
        self.assertGreater(share["grass"], 0.4)
        self.assertGreater(share["forest"], 0.15)
        self.assertGreaterEqual(meta["counts"]["grandstands"], 5)
        self.assertEqual(meta["trees"]["record"], ["x", "y", "z", "height", "species"])
        self.assertEqual(meta["trees"]["count"] * 20, os.path.getsize(os.path.join(helpers.RBR, "scenery_points.bin")))
        self.assertEqual(sum(c[3] for c in meta["trees"]["chunks"]), meta["trees"]["count"])
        near = meta["landcover"]["near"]
        self.assertEqual((near["x0"], near["z0"], near["step"], near["nx"], near["nz"]), (-1600.0, -1200.0, 2.5, 960, 720))
        self.assertEqual(sum(meta["mesh"]["triangles"].values()) > 1000, True)
        self.assertIn("OpenStreetMap", meta["attribution"])

    def test_an_offline_build_of_all_steps_skips_uncached_surroundings(self):
        import build_track
        from lib import surroundings
        with tempfile.TemporaryDirectory() as tmp:
            rec = recipe_mod.load("red_bull_ring")
            fetcher = net.Fetcher(os.path.join(tmp, "raw"), offline=True, log=helpers.silent)
            self.assertFalse(surroundings.have_cache(rec, helpers.RBR, fetcher))
            self.assertIn("surroundings", build_track.STEPS)
            self.assertLess(build_track.STEPS.index("terrain"), build_track.STEPS.index("surroundings"))
            self.assertLess(build_track.STEPS.index("surroundings"), build_track.STEPS.index("info"))


if __name__ == "__main__":
    unittest.main()
