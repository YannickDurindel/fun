#!/usr/bin/env python3
"""Builds everything the game needs for one circuit, from open map data.

    .venv/bin/python tools/track/build_track.py <id> [--recipe tools/track/tracks/<id>.toml]
        [--osm-relation N] [--name "..."] [--length M] [--turns N] [--direction clockwise]
        [--offline] [--out DIR] [--cache DIR] [--steps centreline,road,terrain,surroundings,info]
        [--plot [FILE]] [--compare DIR]

Steps (each reads the files of the ones before it from the output folder):
    centreline  OSM loop + DEM elevation -> track.json, build_info.json
    road        cad/track/road.py        -> road_mesh.glb, road_profile.json, textures,
                                            materials, trackside_profiles.json
    terrain     DEM grids                -> terrain.json, terrain_*.bin
    surroundings  OSM map features        -> landcover*.png, scenery.glb, scenery_points.bin,
                                            scenery.json (optional for the game; needs numpy)
    info        track_info.json and, for a new track, scenes/tracks/<id>.tscn

Output goes to assets/tracks/<id>/ unless --out is given; downloads are cached in
<assets/tracks/<id> or out>/raw/. See tools/track/README.md for the full guide.
"""
import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

from lib import centreline, info as info_mod, net, recipe as recipe_mod, terrain  # noqa: E402
from lib.net import BuildError  # noqa: E402

STEPS = ("centreline", "road", "terrain", "surroundings", "info")


def _parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 epilog="Full guide: tools/track/README.md")
    ap.add_argument("id", help="track id (folder name), e.g. red_bull_ring; ids of "
                               "assets/tracks/calendar.json get their name, length and turn count from it")
    ap.add_argument("--recipe", help="recipe file (default: tools/track/tracks/<id>.toml if it exists)")
    ap.add_argument("--osm-relation", type=int, help="OSM relation id of the circuit (type=circuit)")
    ap.add_argument("--osm-bbox", help="west,south,east,north: use every highway=raceway way in this box")
    ap.add_argument("--name", help="circuit name")
    ap.add_argument("--length", type=float, help="official lap length in metres")
    ap.add_argument("--turns", type=int, help="official number of turns")
    ap.add_argument("--direction", choices=sorted(recipe_mod.DIRECTIONS), help="race direction")
    ap.add_argument("--offline", action="store_true", help="never touch the network; fail on a cache miss")
    ap.add_argument("--out", help="output folder (default: assets/tracks/<id>)")
    ap.add_argument("--cache", help="download cache folder (default: assets/tracks/<id>/raw if it "
                                    "exists, else <out>/raw)")
    ap.add_argument("--steps", default=",".join(STEPS), help="comma-separated subset of: " + ", ".join(STEPS))
    ap.add_argument("--plot", nargs="?", const="", metavar="FILE",
                    help="write a top-down plot (PNG with matplotlib, else SVG); default <out>/plot.png. "
                         "With the surroundings step also <plot>_surroundings.png")
    ap.add_argument("--compare", metavar="DIR", help="compare the result with another build of the "
                                                     "track (e.g. the committed assets) and fail on a difference")
    return ap.parse_args(argv)


def run(argv=None, log=print):
    args = _parse_args(argv)
    steps = [s.strip() for s in args.steps.split(",") if s.strip()]
    bad = [s for s in steps if s not in STEPS]
    if bad:
        raise BuildError(f"unknown step(s) {', '.join(bad)}; choose from {', '.join(STEPS)}")
    bbox = None
    if args.osm_bbox:
        try:
            bbox = [float(x) for x in args.osm_bbox.split(",")]
        except ValueError:
            raise BuildError("--osm-bbox must be west,south,east,north") from None
    rec = recipe_mod.load(args.id, args.recipe, {
        "osm_relation": args.osm_relation, "osm_bbox": bbox, "name": args.name,
        "length_m": args.length, "turns": args.turns, "direction": args.direction})
    assets_dir = os.path.join(ROOT, "assets", "tracks", rec.id)
    out_dir = os.path.abspath(args.out) if args.out else assets_dir
    in_repo = os.path.abspath(out_dir) == os.path.abspath(assets_dir)
    cache_dir = args.cache or (os.path.join(assets_dir, "raw") if os.path.isdir(os.path.join(assets_dir, "raw"))
                               else os.path.join(out_dir, "raw"))
    fetcher = net.Fetcher(cache_dir, args.offline, log)
    os.makedirs(out_dir, exist_ok=True)
    log(f"building '{rec.id}' ({rec.name}, official {rec.length_m:.0f} m) -> {out_dir}"
        + (f"  [recipe {rec.source}]" if rec.source else "  [no recipe: all automatic]"))
    t0 = time.time()
    timings = {}

    def timed(name, fn):
        t = time.time()
        result = fn()
        timings[name] = round(time.time() - t, 1)
        return result

    def need(name, step):
        if not os.path.exists(os.path.join(out_dir, name)):
            raise BuildError(f"{name} is missing in {out_dir}: run the '{step}' step first")

    if "centreline" in steps:
        track, binfo = timed("centreline", lambda: centreline.build(rec, fetcher, log))
        centreline.write(track, binfo, out_dir)
    if "road" in steps:
        need("track.json", "centreline")
        timed("road", lambda: info_mod.build_road(rec, out_dir, log))
    if "terrain" in steps:
        need("track.json", "centreline")
        timed("terrain", lambda: terrain.build(rec, out_dir, fetcher, log))
    surround = None
    if "surroundings" in steps:
        need("terrain.json", "terrain")
        need("road_profile.json", "road")
        try:
            from lib import surroundings
        except ImportError as e:
            raise BuildError(f"the surroundings step needs numpy, scipy and pillow ({e}): run it "
                             "with the project venv") from e
        # An offline run of every step still builds the track when the map features were
        # never fetched; asking for the step by name fails on the cache miss like any other.
        if args.offline and args.steps == ",".join(STEPS) and not surroundings.have_cache(rec, out_dir, fetcher):
            log("surroundings: skipped, the map features are not in the cache (run the step once online)")
            if os.path.exists(os.path.join(out_dir, "scenery.json")):
                log("WARNING: the scenery and land cover files in the output folder are from an earlier "
                    "build and may no longer match the road and the terrain")
        else:
            surround = timed("surroundings", lambda: surroundings.build(rec, out_dir, fetcher, log))
    if "info" in steps:
        need("track.json", "centreline")
        scene_dir = os.path.join(ROOT, "scenes", "tracks") if in_repo else out_dir
        timed("info", lambda: info_mod.write_track_info(rec, out_dir, scene_dir, log))

    binfo = centreline.read_info(out_dir)
    if args.plot is not None:
        from lib import plot
        path = plot.render(out_dir, args.plot or os.path.join(out_dir, "plot.png"))
        log(f"plot: {path}")
        if surround is not None:
            base, ext = os.path.splitext(path)
            try:
                log(f"plot: {surroundings.plot(surround, base + '_surroundings.png')}")
            except ImportError:
                log("plot: the surroundings picture needs matplotlib, skipped")
    for w in binfo.get("warnings", []):
        log(f"WARNING: {w}")
    log(f"done in {time.time() - t0:.1f} s ({fetcher.requests} network requests): "
        + ", ".join(f"{k} {v} s" for k, v in timings.items()))
    if args.compare:
        from lib import compare
        report = compare.compare_dirs(out_dir, args.compare)
        log(compare.format_report(report))
        if not report["ok"]:
            raise BuildError(f"the build differs from {args.compare}")
    return 0


def main(argv=None):
    try:
        return run(argv)
    except BuildError as e:
        print(f"\nERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
