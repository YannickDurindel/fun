"""Far landscape (lib.landscape), offline: the orthophoto ratio encoding, the Lambert-93 mosaic
from cached 20 cm blocks, BD TOPO heights and the footprint index."""
import os
import tempfile
import unittest

import numpy as np

import helpers  # noqa: F401  (sys.path)
from lib import landscape


class RatioTest(unittest.TestCase):
    def test_class_mean_is_neutral(self):
        rng = np.random.default_rng(1)
        classes = np.zeros((64, 64), np.uint8)
        classes[:, 32:] = 1
        rgb = np.empty((64, 64, 3), np.float32)
        rgb[:, :32] = (150, 140, 110)          # dry grass
        rgb[:, 32:] = (40, 50, 35)             # forest
        rgb += rng.normal(0, 0.5, rgb.shape)     # sensor noise: a few codes at most
        ok = np.ones((64, 64), bool)
        old = landscape.MIN_CLASS_PIXELS
        landscape.MIN_CLASS_PIXELS = 100
        try:
            enc, means = landscape.class_ratios(rgb, ok, classes)
        finally:
            landscape.MIN_CLASS_PIXELS = old
        # Every pixel at its class average encodes log2(1) = 0, the middle of the range.
        mid = -landscape.LOG_MIN / (landscape.LOG_MAX - landscape.LOG_MIN) * 255
        self.assertLess(np.abs(enc.astype(float) - mid).mean(), 2.0)
        self.assertLess(np.abs(enc.astype(float) - mid).max(), 14.0)
        self.assertEqual(sorted(means), [0, 1])
        self.assertGreater(means[0][0], means[1][0])

    def test_brighter_than_average_and_no_data(self):
        classes = np.zeros((50, 50), np.uint8)
        rgb = np.full((50, 50, 3), 100.0, np.float32)
        rgb[0, 0] = 140.0
        ok = np.ones((50, 50), bool)
        ok[1, 1] = False
        old = landscape.MIN_CLASS_PIXELS
        landscape.MIN_CLASS_PIXELS = 10
        try:
            enc, _ = landscape.class_ratios(rgb, ok, classes)
        finally:
            landscape.MIN_CLASS_PIXELS = old
        span = landscape.LOG_MAX - landscape.LOG_MIN
        decoded = enc[0, 0].astype(float) / 255 * span + landscape.LOG_MIN
        lin = landscape.srgb_to_linear(np.array([140.0, 100.0]))
        self.assertAlmostEqual(decoded[0], np.log2(lin[0] / lin[1]), delta=0.03)
        self.assertEqual(int(enc[1, 1, 0]), 128)   # no data = neutral (log2 1)


class MosaicTest(unittest.TestCase):
    def test_blocks_averaged_in_place(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "ortho"))
            img = np.zeros((2000, 2000, 3), np.uint8)
            img[:] = (90, 120, 60)
            img[:1000, :1000] = (200, 30, 30)     # north-west quarter red
            Image.fromarray(img).save(os.path.join(root, "ortho", "ortho_400000_6700000.tif"))
            m = landscape.Mosaic(400000, 6700000, 400400, 6700400, 1.0, root, (2000.0, 1000), fetch=None)
            self.assertEqual(m.blocks, 1)
            self.assertTrue(m.valid.all())
            rgb, ok = m.sample(np.array([400100.0, 400300.0]), np.array([6700300.0, 6700100.0]), 2.5)
            self.assertTrue(ok.all())
            np.testing.assert_allclose(rgb[0], (200, 30, 30), atol=1.0)
            np.testing.assert_allclose(rgb[1], (90, 120, 60), atol=1.0)


class TopoTest(unittest.TestCase):
    def test_height_from_roof_and_ground(self):
        self.assertAlmostEqual(landscape.topo_height(
            {"altitude_maximale_toit": 55.0, "altitude_minimale_sol": 43.3, "hauteur": 6.0}), 11.7)
        # a chimney or mast sampled with the roof is capped
        self.assertAlmostEqual(landscape.topo_height(
            {"altitude_maximale_toit": 90.0, "altitude_minimale_sol": 40.0, "hauteur": 6.0}), 16.0)
        self.assertAlmostEqual(landscape.topo_height({"hauteur": 8.0}), 10.0)
        self.assertIsNone(landscape.topo_height({"hauteur": None}))
        self.assertIsNone(landscape.topo_height({"hauteur": 0.5}))

    def test_index_finds_footprints(self):
        a = np.array([[0.0, 0.0], [20.0, 0.0], [20.0, 10.0], [0.0, 10.0]])
        b = a + [500.0, 300.0]                       # another block of cells
        idx = landscape.TopoIndex([(a, 8.0, "", False), (b, 30.0, "", False)])
        got = idx.at(np.array([[5.0, 5.0], [505.0, 305.0], [50.0, 50.0], [-3.0, -3.0]]))
        self.assertEqual(got.tolist(), [0, 1, -1, -1])
        pts = landscape._sample_points(a)
        self.assertTrue(len(pts) > 50)
        self.assertTrue((idx.at(pts) == 0).all())


if __name__ == "__main__":
    unittest.main()
