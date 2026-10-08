"""The AHN elevation source, offline on the tiles cached in assets/tracks/zandvoort/raw/."""
import os
import unittest

import helpers
from lib import net

RAW = os.path.join(helpers.ROOT, "assets", "tracks", "zandvoort", "raw")
FINISH = (52.3889948, 4.5408762)      # Zandvoort finish line


@unittest.skipUnless(os.path.isdir(RAW), "Zandvoort caches not present")
class AhnTest(unittest.TestCase):
    def setUp(self):
        self.fetcher = net.Fetcher(RAW, offline=True, log=helpers.silent)

    def test_fine_level_on_the_track(self):
        # 5.17 m NAP at the finish line and 10.7 m on the Hunserug crest, read from PDOK's
        # AHN viewer service at full resolution; the tiles are 9 x 11 m averages.
        h = net.fetch_elevations(self.fetcher, [FINISH, (52.38850, 4.54370)], "ahn", "dem")
        self.assertAlmostEqual(h[0], 5.17, delta=0.3)
        self.assertAlmostEqual(h[1], 10.7, delta=1.5)

    def test_wide_request_uses_the_coarse_level_and_voids_are_none(self):
        # A horizon-sized request: land at the finish line, no data 3 km out in the North Sea.
        pts = [FINISH, (52.36, 4.47), (52.42, 4.60)]
        h = net.fetch_elevations(self.fetcher, pts, "ahn", "terrain")
        self.assertAlmostEqual(h[0], 5.2, delta=2.0)
        self.assertIsNone(h[1])
        self.assertEqual(net.attribution("ahn"), "Elevation: " + net.DATASETS["ahn"] + ".")


if __name__ == "__main__":
    unittest.main()
