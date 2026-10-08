"""[terrain] smooth_sigma_m: the Gaussian blur applied to the DEM grids of flat sites."""
import unittest

import helpers  # noqa: F401  (sets sys.path)
from lib import terrain


class SmoothGridTest(unittest.TestCase):
    def test_constant_grid_is_unchanged(self):
        out = terrain.smooth_grid([[2.5] * 7 for _ in range(5)], 3.0)
        self.assertEqual((len(out), len(out[0])), (5, 7))
        for row in out:
            for v in row:
                self.assertAlmostEqual(v, 2.5, places=9)

    def test_spike_is_spread_and_its_sum_kept(self):
        h = [[0.0] * 21 for _ in range(21)]
        h[10][10] = 9.0
        out = terrain.smooth_grid(h, 2.0)
        self.assertLess(out[10][10], 0.5)
        self.assertAlmostEqual(out[10][8], out[12][10], places=9)   # same in x and z
        self.assertAlmostEqual(out[10][7], out[10][13], places=9)   # symmetric
        self.assertAlmostEqual(sum(map(sum, out)), 9.0, places=6)
        self.assertEqual(h[10][10], 9.0)                            # input untouched

    def test_zero_sigma_copies(self):
        h = [[1.0, 2.0], [3.0, 4.0]]
        out = terrain.smooth_grid(h, 0.0)
        self.assertEqual(out, h)
        self.assertIsNot(out[0], h[0])


if __name__ == "__main__":
    unittest.main()
