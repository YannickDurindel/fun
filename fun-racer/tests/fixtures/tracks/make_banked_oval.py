#!/usr/bin/env python3
"""Generates the synthetic test track tests/fixtures/tracks/banked_oval/: a 1303 m clockwise
stadium oval on a gently tilted plain whose two 180 degree turns (80 m radius) are banked at
18 degrees (0.314 rad), like Zandvoort's Arie Luyendykbocht.

Unlike test_oval (track.json only, every runtime fallback), this one goes through the real
pipeline with declared banking, on a synthetic height model instead of downloads:

    track.json                           written here, with the bank the road step builds
    road_mesh.glb, road_profile.json     cad/track/road.py with ROAD ([road] of a recipe)
    terrain.json, terrain_*.bin          tools/track/lib/terrain.py

so the tests see what a real banked circuit gets: the banked verge, the terrain under it and
track.json's bank. See tests/test_banking.gd and tools/track/tests/test_banking.py.

Usage: .venv/bin/python tests/fixtures/tracks/make_banked_oval.py [OUT_DIR]
(then `tools/bin/godot --headless --path . --import` for the new road_mesh.glb)
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
for p in (os.path.join(ROOT, "tools", "track"), os.path.join(ROOT, "cad", "track")):
    if p not in sys.path:
        sys.path.insert(0, p)

OUT_DIR = os.path.join(HERE, "banked_oval")
STRAIGHT = 400.0
RADIUS = 80.0
BANK = 0.314           # rad = 18 degrees; + = left edge higher: the outside of a right-hander
BLEND = 100.0          # m of straight over which the banking comes in and goes out (a fast corner:
                       # at 280 km/h a shorter ramp throws the car about, see tools/track/README.md)
START_S = 60.0         # the grid: on the top straight, before the banking comes in at s = 100
TURN = math.pi * RADIUS

# (length m, signed curvature 1/m: + = right turn, turn name or None). The lap starts in the
# middle of the top straight, heading east.
SEGMENTS = [
    (0.5 * STRAIGHT, 0.0, None),
    (TURN, 1.0 / RADIUS, "East Banking"),
    (STRAIGHT, 0.0, None),
    (TURN, 1.0 / RADIUS, "West Banking"),
    (0.5 * STRAIGHT, 0.0, None),
]
T1_S = (0.5 * STRAIGHT, 0.5 * STRAIGHT + TURN)
T2_S = (1.5 * STRAIGHT + TURN, 1.5 * STRAIGHT + 2.0 * TURN)

# The recipe's [road] table: what a per-track recipe would say for two banked turns.
ROAD = {
    "max_bank": 0.32,
    "override": [
        {"s": [round(T1_S[0], 1), round(T1_S[1], 1)], "bank": BANK, "blend": BLEND, "note": "East Banking"},
        {"s": [round(T2_S[0], 1), round(T2_S[1], 1)], "bank": BANK, "blend": BLEND, "note": "West Banking"},
    ],
}


def height(x: float, z: float) -> float:
    """A plain tilted by 2 % and 1 %; 0 at the finish line (origin)."""
    return 0.02 * x - 0.01 * z


def plan_at(s: float):
    """(x, z, heading, curvature) at distance s; heading 0 = east, + = turning right."""
    x = z = h = 0.0
    for length, k, _name in SEGMENTS:
        d = min(s, length)
        if abs(k) < 1e-12:
            x += d * math.cos(h)
            z += d * math.sin(h)
        else:
            x += (math.sin(h + k * d) - math.sin(h)) / k
            z += (math.cos(h) - math.cos(h + k * d)) / k
            h += k * d
        if s <= length:
            return x, z, h, k
        s -= length
    return x, z, h, 0.0


def build_track() -> dict:
    from lib import centreline, recipe as recipe_mod
    total = sum(seg[0] for seg in SEGMENTS)
    ex, ez, eh, _ = plan_at(total)
    assert math.hypot(ex, ez) < 1e-6 and abs(eh - 2.0 * math.pi) < 1e-9, "the lap does not close"
    n = round(total / 2.0)
    step = total / n
    xz = [plan_at(i * step) for i in range(n)]
    # track.json's curvature is + = left (tools/track/lib/geom.py); the segments are + = right.
    curvature = [round(-p[3], 5) for p in xz]
    rec = recipe_mod.Recipe(id="banked_oval", road=ROAD)
    banks = centreline.track_json_banks(rec, n, step, round(total, 3), START_S, curvature)
    points = []
    for i, (x, z, _h, _k) in enumerate(xz):
        s = i * step
        x2, z2, _, _ = plan_at((s + 0.5) % total)
        x1, z1, _, _ = plan_at((s - 0.5) % total)
        points.append({
            "s": round(s, 3),
            "p": [round(x, 3), round(height(x, z), 3), round(z, 3)],
            "width": 13.0,
            "bank": banks[i],
            "grade": round(height(x2, z2) - height(x1, z1), 4),
            "curvature": curvature[i],
        })
    turns = []
    s0 = 0.0
    for length, k, name in SEGMENTS:
        if name is not None:
            turns.append({"id": "T%d" % (len(turns) + 1), "name": name,
                          "direction": "right" if k > 0.0 else "left",
                          "s_apex": round(s0 + 0.5 * length, 1), "min_radius": round(1.0 / abs(k), 1)})
        s0 += length
    ys = [p["p"][1] for p in points]
    return {
        "name": "Banked Oval (synthetic fixture)",
        "length": round(total, 3),
        "closed": True,
        "direction": "clockwise",
        "frame": "Godot metres: x=east, y=up (relative to finish line), z=-north; origin at finish line",
        "origin_latlon": [0.0, 0.0],
        "origin_elevation_m": 0.0,
        "step": step,
        "start_s": START_S,
        "finish_s": 0.0,
        "sectors": [0.0, round(total / 3.0, 1), round(2.0 * total / 3.0, 1)],
        "turns": turns,
        "elevation_range": round(max(ys) - min(ys), 2),
        "points": points,
        "attribution": "Synthetic: tests/fixtures/tracks/make_banked_oval.py",
    }


def build(out_dir: str = OUT_DIR, log=print) -> dict:
    """Writes the whole fixture into ``out_dir`` and returns {track, road, terrain}."""
    from pathlib import Path
    from lib import centreline, recipe as recipe_mod, terrain
    import road
    os.makedirs(out_dir, exist_ok=True)
    track = build_track()
    with open(os.path.join(out_dir, "track.json"), "w") as f:
        json.dump(track, f, separators=(",", ":"))
        f.write("\n")
    res = road.build(Path(out_dir) / "track.json", Path(out_dir), ROAD, "banked_oval")
    for name in ("road_tarmac_albedo.png", "road_grass_albedo.png"):
        os.remove(os.path.join(out_dir, name))     # the GLB's plain colours do for a fixture

    # Terrain: the real step on a synthetic height model. The plan scale is 1 (the "OSM
    # length" is the lap's own), the near grid is as small as the corridor allows.
    centreline.write_info({"id": "banked_oval", "osm": {"length_m": track["length"]}}, out_dir)
    xs = [p["p"][0] for p in track["points"]]
    zs = [p["p"][2] for p in track["points"]]
    near = [math.floor((min(xs) - 265.0) / 200.0) * 200.0, math.ceil((max(xs) + 265.0) / 200.0) * 200.0,
            math.floor((min(zs) - 265.0) / 200.0) * 200.0, math.ceil((max(zs) + 265.0) / 200.0) * 200.0]
    rec = recipe_mod.Recipe(id="banked_oval", road=ROAD, terrain={"near": near}, dem_dataset="srtm30m")
    fetch = terrain.fetch_grid
    terrain.fetch_grid = lambda _f, _d, gx, gz, _ll, _b: ([[height(x, z) for x in gx] for z in gz], 0)
    try:
        meta = terrain.build(rec, out_dir, None, log)
    finally:
        terrain.fetch_grid = fetch
    meta["attribution"] = "Synthetic: tests/fixtures/tracks/make_banked_oval.py"
    with open(os.path.join(out_dir, "terrain.json"), "w") as f:
        json.dump(meta, f, indent=1)
    os.remove(os.path.join(out_dir, "build_info.json"))
    info = {
        "id": "banked_oval",
        "name": "Banked Oval",
        "grand_prix": "Fixture Grand Prix",
        "country": "Nowhere",
        "country_code": "",
        "city": "",
        "length_m": round(track["length"]),
        "turns": len(track["turns"]),
        "available": True,
    }
    with open(os.path.join(out_dir, "track_info.json"), "w") as f:
        json.dump(info, f, indent=2)
        f.write("\n")
    log("banked_oval: %.1f m, %d points, bank %+.3f..%+.3f rad, %d road triangles"
        % (track["length"], len(track["points"]), res["bank"][0], res["bank"][1], res["triangles"]))
    return {"track": track, "road": res, "terrain": meta}


if __name__ == "__main__":
    build(sys.argv[1] if len(sys.argv) > 1 else OUT_DIR)
