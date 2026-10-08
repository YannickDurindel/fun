#!/usr/bin/env python3
"""Builds a track's terrain heightmaps from a DEM (see tools/track/lib/terrain.py).

Kept for the old command line; it now just runs the terrain step of the generic pipeline:

    python3 tools/track/build_track.py <id> --steps terrain [--offline]

Usage: python3 tools/track/fetch_terrain.py [track id, default red_bull_ring] [--offline]
"""
import sys

import build_track

if __name__ == "__main__":
    args = sys.argv[1:]
    track_id = args.pop(0) if args and not args[0].startswith("-") else "red_bull_ring"
    sys.exit(build_track.main([track_id, "--steps", "terrain"] + args))
