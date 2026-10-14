#!/usr/bin/env python3
"""Generates the synthetic test track tests/fixtures/tracks/measured_oval/: the stadium oval of
make_banked_oval.py (1303 m, two 180 degree right-handers of 80 m radius) WITHOUT declared
banking, whose road surface comes from a synthetic lidar grid through the real pipeline with
``[road] sections = "lidar"`` (cad/track/road_sections.py):

    lidar_road.json / .bin     written here (a known surface, see surface()), deleted after use
    track.json                 written here (no bank)
    road_mesh.glb, road_profile.json   cad/track/road.py with ROAD, measured sections ("xsec")
    terrain.json, terrain_*.bin        tools/track/lib/terrain.py on make_banked_oval's plain

The known surface: the straights have a 2.5 % crown with a drainage break 4.5 m right of the
centre (3 % more beyond it); the turns lean 4 % into the corner (right edge lower), blended in
over 40 m. Tests: tests/test_measured_sections.gd, tools/track/tests/test_measured_sections.py.

Usage: .venv/bin/python tests/fixtures/tracks/make_measured_oval.py [OUT_DIR]
(then `tools/bin/godot --headless --path . --import` for the new road_mesh.glb)
"""
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
for p in (HERE, os.path.join(ROOT, "tools", "track"), os.path.join(ROOT, "cad", "track")):
    if p not in sys.path:
        sys.path.insert(0, p)

import make_banked_oval as oval  # noqa: E402

OUT_DIR = os.path.join(HERE, "measured_oval")
ROAD = {"sections": "lidar", "grid_width": 13.0}   # one width all round (the grid surface knows 13 m)
CROWN = 0.025          # slope of each half of the road on the straights (edges lower)
BREAK = 4.5            # m right of the centre: drainage break on the straights
BREAK_EXTRA = 0.03     # extra fall beyond it
CAMBER = 0.04          # slope into the turns (right edge lower)
BLEND = 40.0           # m over which the camber comes in
REACH = 30.0           # m around the centreline that the grid covers


def turn_weight(s: np.ndarray) -> np.ndarray:
    """0 on the straights, 1 in the turns, smoothstep over BLEND either side of each turn."""
    total = sum(seg[0] for seg in oval.SEGMENTS)
    w = np.zeros_like(s)
    for a, b in (oval.T1_S, oval.T2_S):
        d = np.maximum(a - s, s - b)
        d = np.minimum(d, np.maximum(a - (s - total), (s - total) - b))
        t = np.clip(1.0 - d / BLEND, 0.0, 1.0)
        w = np.maximum(w, t * t * (3.0 - 2.0 * t))
    return w


def surface(s: np.ndarray, lat: np.ndarray, hw: float) -> np.ndarray:
    """Known height of the road above its centreline at (s, lateral + right); beyond the edges
    the verge falls 2 % outward from the edge."""
    w = turn_weight(s)
    l = np.clip(lat, -hw, hw)
    straight = -CROWN * np.abs(l) - BREAK_EXTRA * np.maximum(l - BREAK, 0.0)
    h = (1.0 - w) * straight + w * (-CAMBER * l)
    return h - 0.02 * np.maximum(np.abs(lat) - hw, 0.0)


def write_grid(track: dict, out_dir: str, height=None, reach: float = REACH) -> None:
    """A synthetic lidar road grid (tools/track/lib/lidar.py format) around the lap of
    ``track``: every cell within ``reach`` of the centreline gets the centreline height (linear
    between the points, as the road mesh) plus ``height(s, lateral)`` (default: surface() of
    this fixture with its 6.5 m half width)."""
    from scipy.spatial import cKDTree
    from lib import lidar
    if height is None:
        def height(s, lat):
            return surface(s, lat, 6.5)
    spec = lidar.ROAD
    cell, tile = spec["cell"], spec["tile"]
    P = np.array([p["p"] for p in track["points"]])
    n, step, total = len(P), track["step"], track["length"]
    m = int(round(total / 0.25))
    sd = np.arange(m) * total / m
    i0 = np.floor(sd / step).astype(int) % n
    f = sd / step - np.floor(sd / step)
    Q = P[i0] * (1 - f)[:, None] + P[(i0 + 1) % n] * f[:, None]
    t = np.roll(Q, -1, 0) - np.roll(Q, 1, 0)
    t[:, 1] = 0.0
    t /= np.linalg.norm(t, axis=1, keepdims=True)
    rh = np.stack([-t[:, 2], np.zeros(m), t[:, 0]], 1)
    tree = cKDTree(Q[:, [0, 2]])
    tw = tile * cell
    keys = set()
    for x, z in Q[::8, [0, 2]]:
        for dx in (-reach, 0.0, reach):
            for dz in (-reach, 0.0, reach):
                keys.add((int(math.floor((x + dx) / tw)), int(math.floor((z + dz) / tw))))
    centres = (np.arange(tile) + 0.5) * cell
    tiles = {}
    for ti, tj in sorted(keys):
        X, Z = np.meshgrid(ti * tw + centres, tj * tw + centres)
        dist, k = tree.query(np.stack([X.ravel(), Z.ravel()], 1), distance_upper_bound=reach)
        ok = np.isfinite(dist)
        if not ok.any():
            continue
        kk = k[ok]
        dx = np.stack([X.ravel()[ok] - Q[kk, 0], Z.ravel()[ok] - Q[kk, 2]], 1)
        lat = (dx * rh[kk][:, [0, 2]]).sum(1)
        s = np.mod(sd[kk] + (dx * t[kk][:, [0, 2]]).sum(1), total)
        u = s / step
        j = np.floor(u).astype(int) % n
        fr = u - np.floor(u)
        y = P[j, 1] * (1 - fr) + P[(j + 1) % n, 1] * fr
        h = np.full(X.size, np.nan, np.float32)
        h[np.flatnonzero(ok)] = y + height(s, lat)
        fl = np.where(np.isfinite(h), lidar.FLAG_MEASURED, lidar.FLAG_NONE).astype(np.uint8)
        tiles[(ti, tj)] = (h.reshape(tile, tile), fl.reshape(tile, tile))
    lidar.write_grid(out_dir, spec, tiles, {"origin_elevation_m": 0.0,
                                            "attribution": "Synthetic: " + os.path.basename(__file__)})


def build(out_dir: str = OUT_DIR, log=print, keep_grid: bool = False) -> dict:
    """Writes the whole fixture into ``out_dir`` and returns {track, road}."""
    from pathlib import Path
    from lib import centreline, recipe as recipe_mod, terrain
    import road
    os.makedirs(out_dir, exist_ok=True)
    saved = oval.ROAD
    oval.ROAD = {}                       # the oval without declared banking
    try:
        track = oval.build_track()
    finally:
        oval.ROAD = saved
    track["name"] = "Measured Oval (synthetic fixture)"
    track["attribution"] = "Synthetic: tests/fixtures/tracks/make_measured_oval.py"
    with open(os.path.join(out_dir, "track.json"), "w") as f:
        json.dump(track, f, separators=(",", ":"))
        f.write("\n")
    write_grid(track, out_dir)
    try:
        res = road.build(Path(out_dir) / "track.json", Path(out_dir), ROAD, "measured_oval")
    finally:
        if not keep_grid:
            for name in ("lidar_road.json", "lidar_road.bin"):
                os.remove(os.path.join(out_dir, name))
    for name in ("road_tarmac_albedo.png", "road_grass_albedo.png"):
        os.remove(os.path.join(out_dir, name))     # the GLB's plain colours do for a fixture

    centreline.write_info({"id": "measured_oval", "osm": {"length_m": track["length"]}}, out_dir)
    xs = [p["p"][0] for p in track["points"]]
    zs = [p["p"][2] for p in track["points"]]
    near = [math.floor((min(xs) - 265.0) / 200.0) * 200.0, math.ceil((max(xs) + 265.0) / 200.0) * 200.0,
            math.floor((min(zs) - 265.0) / 200.0) * 200.0, math.ceil((max(zs) + 265.0) / 200.0) * 200.0]
    rec = recipe_mod.Recipe(id="measured_oval", road=ROAD, terrain={"near": near}, dem_dataset="srtm30m")
    fetch = terrain.fetch_grid
    terrain.fetch_grid = lambda _f, _d, gx, gz, _ll, _b: ([[oval.height(x, z) for x in gx] for z in gz], 0)
    try:
        meta = terrain.build(rec, out_dir, None, log)
    finally:
        terrain.fetch_grid = fetch
    meta["attribution"] = "Synthetic: tests/fixtures/tracks/make_measured_oval.py"
    with open(os.path.join(out_dir, "terrain.json"), "w") as f:
        json.dump(meta, f, indent=1)
    os.remove(os.path.join(out_dir, "build_info.json"))
    info = {
        "id": "measured_oval",
        "name": "Measured Oval",
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
    st = res["sections"]
    log("measured_oval: %.1f m, %d points, %d columns, bank %+.3f..%+.3f rad, %d road triangles"
        % (track["length"], len(track["points"]), st["columns"], res["bank"][0], res["bank"][1], res["triangles"]))
    return {"track": track, "road": res}


if __name__ == "__main__":
    build(sys.argv[1] if len(sys.argv) > 1 else OUT_DIR)
