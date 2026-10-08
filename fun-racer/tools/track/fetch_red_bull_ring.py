#!/usr/bin/env python3
"""Builds assets/tracks/red_bull_ring/track.json from open data.

Kept for the old command line; it now just runs the centreline step of the generic pipeline
with the Red Bull Ring recipe (tools/track/tracks/red_bull_ring.toml):

    python3 tools/track/build_track.py red_bull_ring --steps centreline [--offline]

Usage: python3 tools/track/fetch_red_bull_ring.py [--offline]
"""
import sys

import build_track

if __name__ == "__main__":
    sys.exit(build_track.main(["red_bull_ring", "--steps", "centreline"] + sys.argv[1:]))
