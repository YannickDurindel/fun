"""RLP data helpers, offline: listing parse, corridor and tile maths, DGM1 sampling."""
import os
import tempfile
import unittest
from unittest import mock

import numpy as np
from PIL import Image

import helpers
from lib import rlp_data


class RlpTest(unittest.TestCase):
    def test_parse_listing_and_sizes(self):
        html = ('<tr><td><a href="dgm1_32_330_5490_1_rp_2025.tif">x</a></td>'
                '<td align="right">2026-05-12 07:24  </td><td align="right">1.6M</td></tr>'
                '<tr><td><a href="LoD2_32_292_5548_2_RP.gml">x</a></td>'
                '<td align="right">2026-04-27 03:00  </td><td align="right">86K</td></tr>')
        got = rlp_data.parse_listing(html)
        self.assertEqual(got["LoD2_32_292_5548_2_RP.gml"], 86 * 1024)
        self.assertAlmostEqual(got["dgm1_32_330_5490_1_rp_2025.tif"], 1.6 * 2 ** 20, delta=1)

    def test_tile_bounds_and_names(self):
        n = rlp_data.tile_name("las", 330, 5490)
        self.assertEqual(n, "lpolpg_32_330_5490_1_rp.laz")
        self.assertEqual(rlp_data.tile_bounds(n), (330000, 5490000, 331000, 5491000))
        self.assertEqual(rlp_data.tile_bounds("LoD2_32_292_5548_2_RP.gml"), (292000, 5548000, 294000, 5550000))

    def test_corridor_cells(self):
        xy = np.column_stack([np.linspace(330200, 332800, 1301), np.full(1301, 5490500.0)])
        cells = rlp_data.corridor_cells(xy, 600.0, 1000)
        self.assertEqual({i for i, _ in cells}, {329, 330, 331, 332, 333})
        self.assertEqual({j for _, j in cells}, {5489, 5490, 5491})
        # a 150 m buffer only reaches the row of the line itself
        self.assertEqual({j for _, j in rlp_data.corridor_cells(xy, 150.0, 1000)}, {5490})

    def test_dgm1_bilinear(self):
        with tempfile.TemporaryDirectory() as d:
            a = np.zeros((1000, 1000), dtype=np.float32)
            a[:, :] = np.arange(1000, dtype=np.float32)[None, :]   # height = column index (east)
            Image.fromarray(a, mode="F").save(os.path.join(d, "dgm1_32_330_5490_1_rp_2025.tif"))
            with mock.patch.object(rlp_data, "cache_dir", return_value=d):
                # pixel centres at +0.5 m: east 330100.5 is the centre of column 100
                self.assertAlmostEqual(rlp_data.dgm1_height(330100.5, 5490500.5), 100.0, places=3)
                self.assertAlmostEqual(rlp_data.dgm1_height(330100.75, 5490500.5), 100.25, places=3)
                self.assertTrue(np.isnan(rlp_data.dgm1_height(340000.5, 5490500.5)))

    def test_net_dgm1_dataset(self):
        from lib import net
        from pyproj import Transformer
        self.assertIn("dgm1", net.DATASETS)
        self.assertEqual(net.attribution("dgm1"), "Elevation: " + net.DATASETS["dgm1"] + ".")
        with tempfile.TemporaryDirectory() as d:
            a = np.full((1000, 1000), 500.0, dtype=np.float32)
            Image.fromarray(a, mode="F").save(os.path.join(d, "dgm1_32_330_5490_1_rp_2025.tif"))
            lon, lat = Transformer.from_crs("EPSG:25832", "EPSG:4326", always_xy=True).transform(330500, 5490500)
            with mock.patch.object(rlp_data, "cache_dir", return_value=d):
                got = net.fetch_elevations(None, [(lat, lon)], "dgm1", "dem")
        self.assertAlmostEqual(got[0], 500.0, places=3)


if __name__ == "__main__":
    unittest.main()
