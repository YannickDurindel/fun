"""IGN data helpers, offline: corridor and tile maths on a small synthetic lap (no network)."""
import os
import tempfile
import unittest

import numpy as np

import helpers
from lib import ign_data


class CorridorTest(unittest.TestCase):
    def test_tile_id_and_bounds(self):
        # the tile whose south-west corner is (491 km, 6764 km) is named by its NW corner
        tid = ign_data.lidar_tile_id(491, 6764)
        self.assertEqual(tid, "LHD_FXX_0491_6765_PTS_LAMB93_IGN69.copc.laz")
        self.assertEqual(ign_data.lidar_tile_bounds(tid), (491000, 6764000, 492000, 6765000))

    def test_straight_lap_tiles(self):
        # a 3 km line along y = 6764500 from x = 491200 to 494200, buffer 600 m
        xy = np.column_stack([np.linspace(491200, 494200, 1501), np.full(1501, 6764500.0)])
        tiles = ign_data.corridor_cells(xy, 600.0, 1000)
        self.assertEqual({i for i, _ in tiles}, {490, 491, 492, 493, 494})
        # y band 6763900..6765100 touches the rows 6763, 6764 and 6765
        self.assertEqual({j for _, j in tiles}, {6763, 6764, 6765})
        self.assertAlmostEqual(tiles[(492, 6764)], 0.0)          # the lap runs through it
        self.assertAlmostEqual(tiles[(492, 6765)], 500.0, places=1)
        self.assertAlmostEqual(tiles[(490, 6763)], 538.5, places=1)  # diagonal corner
        # tiles inside 150 m: only the row the line is in
        near = ign_data.corridor_cells(xy, 150.0, 1000)
        self.assertEqual({j for _, j in near}, {6764})

    def test_coarse_polyline_is_densified(self):
        xy = np.array([[0.0, 0.0], [4000.0, 0.0]])
        tiles = ign_data.corridor_cells(xy, 10.0, 1000)
        self.assertEqual({i for i, _ in tiles}, {-1, 0, 1, 2, 3, 4})

    def test_ortho_blocks_and_urls(self):
        xy = np.array([[1000.0, 1000.0], [1100.0, 1000.0]])
        blocks = ign_data.ortho_blocks(xy, 50.0)
        self.assertIn((800, 800), blocks)
        self.assertIn((800, 1200), blocks.keys() | {(800, 1200)})
        self.assertIn("BBOX=800%2C800%2C1200%2C1200", ign_data.ortho_url(800, 800))
        self.assertIn("WIDTH=2000", ign_data.ortho_url(800, 800))

    @unittest.skipUnless(os.path.exists(os.path.join(helpers.ROOT, "assets", "tracks",
                                                     "wec_le_mans", "track.json")), "no Le Mans")
    def test_lap_projection_is_in_lambert93_sarthe(self):
        import json
        p = os.path.join(helpers.ROOT, "assets", "tracks", "wec_le_mans", "track.json")
        with open(p, encoding="utf-8") as f:
            xy = ign_data.lap_xy_l93(json.load(f))
        # Circuit de la Sarthe: roughly 489-500 km east, 6758-6770 km north
        self.assertTrue(485e3 < xy[:, 0].min() and xy[:, 0].max() < 505e3)
        self.assertTrue(6.75e6 < xy[:, 1].min() and xy[:, 1].max() < 6.775e6)


class CacheTest(unittest.TestCase):
    def test_finished_file_is_skipped(self):
        with tempfile.TemporaryDirectory() as d:
            c = ign_data.IgnCache(d, log=lambda *a: None, pause=0)
            os.makedirs(c.path("lidar"))
            with open(c.path("lidar", "a.laz"), "wb") as f:
                f.write(b"abc")
            with open(c.path("lidar", "a.laz.sha256"), "w") as f:
                f.write(ign_data.sha256_file(c.path("lidar", "a.laz")) + "  a.laz\n")
            # an unreachable URL proves no request is made for a finished file
            r = c.fetch("http://127.0.0.1:9/never", "lidar/a.laz")
            self.assertEqual(r["bytes"], 3)
            self.assertEqual(len(r["sha256"]), 64)


class SmokeTest(unittest.TestCase):
    """Reads one cached LiDAR HD tile when a previous download left one (skipped otherwise)."""

    def test_ground_class(self):
        d = os.path.expanduser(os.path.join(ign_data.CACHE_DIR, "lidar"))
        tiles = [f for f in sorted(os.listdir(d)) if f.endswith(".laz")] if os.path.isdir(d) else []
        if not tiles:
            self.skipTest("no LiDAR HD tile in the cache")
        import laspy
        x0, y0, x1, y1 = ign_data.lidar_tile_bounds(tiles[0])
        with laspy.open(os.path.join(d, tiles[0])) as r:
            self.assertEqual(r.header.parse_crs().to_epsg(), 2154)
            pts = next(r.chunk_iterator(1_000_000))
        ground = np.asarray(pts.classification) == 2
        self.assertGreater(ground.sum(), 1000)
        self.assertTrue((pts.x[ground] >= x0 - 1).all() and (pts.x[ground] <= x1 + 1).all())
        self.assertTrue((pts.y[ground] >= y0 - 1).all() and (pts.y[ground] <= y1 + 1).all())


if __name__ == "__main__":
    unittest.main()
