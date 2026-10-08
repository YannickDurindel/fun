#!/usr/bin/env python3
"""Builds the Red Bull Ring terrain heightmaps from EU-DEM (pure Python, no dependencies).

Reads assets/tracks/red_bull_ring/track.json (run fetch_red_bull_ring.py first) for the
local frame and the centreline, then fetches two DEM grids from OpenTopoData (eudem25m,
100 locations per request, 1 request/s, raw responses cached in raw/terrain_*.json):

  * near grid: 20 m spacing over the circuit plus ~500 m margin, bicubically upsampled to a
    10 m mesh grid. Inside the track corridor the height is replaced by the road surface
    height minus CLEARANCE so road / verge meshes always cover it, then blended back to the
    DEM over BLEND m. The outer BORDER m blend to the bilinear far grid so both meshes meet.
  * far grid: 200 m spacing out to ~6 km for the low-poly valley hills.

Frame: x = east, z = -north, y = elevation - origin_elevation_m. The plan view (x, z) uses the
same uniform scale k = official length / OSM length as the centreline, so terrain lines up.

Outputs (little endian, row-major: row = z index, column = x index):
  terrain_height.bin   float32 near heights (final, corridor-conformed)
  terrain_dist.bin     uint16  distance to the centreline in decimetres (clamped to 6553.5 m)
  terrain_far.bin      float32 far heights
  terrain.json         grid metadata

Usage: python3 tools/track/fetch_terrain.py [--offline]
"""
import bisect, hashlib, json, math, os, struct, sys, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(ROOT, "assets", "tracks", "red_bull_ring")
RAW = os.path.join(OUT_DIR, "raw")
UA = {"User-Agent": "fun-racer/0.1 (terrain builder)"}
OSM_LENGTH = 4302.1          # unscaled OSM lap length (see fetch_red_bull_ring.py)

# Near grid (game metres). Edges are multiples of FAR_STEP relative to the far grid origin.
NEAR_X0, NEAR_X1 = -1600.0, 800.0
NEAR_Z0, NEAR_Z1 = -1200.0, 600.0
FETCH_STEP = 20.0
MESH_STEP = 10.0
# Far grid.
FAR_X0, FAR_X1 = -6400.0, 5600.0
FAR_Z0, FAR_Z1 = -6200.0, 5800.0
FAR_STEP = 200.0

CLEARANCE = 0.3     # m below the road / verge surface inside the corridor
VERGE_SLOPE = 0.0   # extra drop per metre beyond the road edge, up to VERGE m. 0: the CAD
                    # verge plane (road_profile.json) is modelled exactly, CLEARANCE suffices
VERGE = 30.0        # nominal grass verge beyond the road edge (CAD road_profile.json)
FLAT_MARGIN = 21.0  # flat zone = road edge + VERGE + FLAT_MARGIN, following the nearest
                    # cross-section's (extrapolated) verge plane
COVER_SLACK = 2.0   # m: along-track tolerance for "this cross-section covers the vertex"
CELL_REACH = 14.2   # m: a mesh cell diagonal. Vertices up to this far beyond a strip's real
                    # verge stay under it too, so no triangle straddling the verge edge rises
                    # through it (e.g. towards a higher leg of a hairpin).
BLEND = 40.0        # corridor -> raw DEM blend distance
BORDER = 160.0      # near-grid border band blended to the far grid


def fetch_dem(latlon):
    out = []
    for c in range(0, len(latlon), 100):
        chunk = latlon[c:c + 100]
        locs = "|".join(f"{la:.7f},{lo:.7f}" for la, lo in chunk)
        key = f"terrain_{hashlib.sha1(locs.encode()).hexdigest()[:12]}.json"
        path = os.path.join(RAW, key)
        if os.path.exists(path):
            body = open(path, "rb").read()
        else:
            if "--offline" in sys.argv:
                sys.exit(f"missing cached {key} and --offline given")
            url = f"https://api.opentopodata.org/v1/eudem25m?locations={locs}"
            for attempt in range(5):
                try:
                    body = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60).read()
                    break
                except Exception as e:  # rate limit / transient
                    print(f"  retry {attempt}: {e}")
                    time.sleep(3.0 * (attempt + 1))
            else:
                sys.exit("DEM fetch failed")
            res = json.loads(body)
            if res.get("status") != "OK":
                sys.exit(f"DEM error: {res}")
            # Store compactly: only the elevations, the request is identified by the hash.
            body = json.dumps({"locations": locs, "elevation": [r["elevation"] for r in res["results"]]}).encode()
            os.makedirs(RAW, exist_ok=True)
            open(path, "wb").write(body)
            time.sleep(1.1)
            print(f"  fetched {c + len(chunk)}/{len(latlon)}")
        out += json.loads(body)["elevation"]
    return out


def grid_axis(a, b, step):
    n = int(round((b - a) / step)) + 1
    return [a + i * step for i in range(n)]


def fetch_grid(xs, zs, to_latlon, base):
    latlon = [to_latlon(x, z) for z in zs for x in xs]
    e = fetch_dem(latlon)
    h = [[0.0] * len(xs) for _ in zs]
    for j in range(len(zs)):
        for i in range(len(xs)):
            v = e[j * len(xs) + i]
            h[j][i] = (v - base) if v is not None else None
    # Fill rare voids with the nearest valid value in the row.
    for row in h:
        for i, v in enumerate(row):
            if v is None:
                row[i] = next((row[k] for d in range(1, len(row)) for k in (i - d, i + d)
                               if 0 <= k < len(row) and row[k] is not None), 0.0)
    return h


def cubic(p0, p1, p2, p3, t):
    return p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))


def bicubic(h, u, v):
    """Catmull-Rom sample of grid h at fractional (column u, row v)."""
    nz, nx = len(h), len(h[0])
    i, j = int(math.floor(u)), int(math.floor(v))
    tu, tv = u - i, v - j
    rows = []
    for dj in (-1, 0, 1, 2):
        r = h[min(max(j + dj, 0), nz - 1)]
        c = [r[min(max(i + di, 0), nx - 1)] for di in (-1, 0, 1, 2)]
        rows.append(cubic(*c, tu))
    return cubic(*rows, tv)


def bilinear(h, u, v):
    nz, nx = len(h), len(h[0])
    i, j = min(int(u), nx - 2), min(int(v), nz - 2)
    tu, tv = u - i, v - j
    a = h[j][i] + (h[j][i + 1] - h[j][i]) * tu
    b = h[j + 1][i] + (h[j + 1][i + 1] - h[j + 1][i]) * tu
    return a + (b - a) * tv


def smoothstep(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


def load_profile(track):
    """CAD road cross-section profile (widths, bank, per-side verge widths), falling back to
    track.json's widths / banks with full verges if road_profile.json is missing."""
    n = len(track["points"])
    path = os.path.join(OUT_DIR, "road_profile.json")
    if os.path.exists(path):
        pr = json.load(open(path))
        assert len(pr["width"]) == n, "road_profile.json does not match track.json"
        return {"width": pr["width"], "bank": pr["bank"], "verge_l": pr["verge_left"],
                "verge_r": pr["verge_right"], "verge_width": pr.get("verge_width", VERGE),
                "verge_drop": pr.get("verge_drop", 0.25)}
    pts = track["points"]
    return {"width": [p.get("width", 13.0) for p in pts], "bank": [p.get("bank", 0.0) for p in pts],
            "verge_l": [VERGE] * n, "verge_r": [VERGE] * n, "verge_width": VERGE, "verge_drop": 0.25}


def make_corridor(track, profile):
    """Returns corridor(x, z) -> (distance to centreline, (target height, blend weight) or None).

    The target follows the nearest cross-section of the CAD road: banked road plane, then the
    verge dropping verge_drop over verge_width (extrapolated beyond it), each continued along
    the track by its grade, minus CLEARANCE and VERGE_SLOPE per metre past the edge. Only
    where several cross-sections genuinely cover the same spot (the inside of corners, other
    legs of a hairpin) the lowest of them wins, so the terrain stays under all of them.
    """
    pts = [p["p"] for p in track["points"]]
    grades = [p.get("grade", 0.0) for p in track["points"]]
    widths = profile["width"]
    sin_banks = [math.sin(b) for b in profile["bank"]]
    verge_l, verge_r = profile["verge_l"], profile["verge_r"]
    vdrop = profile["verge_drop"] / profile["verge_width"]
    n = len(pts)
    tangents = []
    for i in range(n):
        a, b = pts[i - 1], pts[(i + 1) % n]
        dx, dz = b[0] - a[0], b[2] - a[2]
        l = math.hypot(dx, dz)
        tangents.append((dx / l, dz / l))
    CELL = 50.0
    buckets = {}
    for i, p in enumerate(pts):
        buckets.setdefault((int(math.floor(p[0] / CELL)), int(math.floor(p[2] / CELL))), []).append(i)
    reach = max(widths) * 0.5 + VERGE + FLAT_MARGIN + BLEND
    rc = int(math.ceil(reach / CELL))

    def target(i, along, lat_r):
        hw = widths[i] * 0.5
        y = pts[i][1] + grades[i] * along
        out = abs(lat_r) - hw
        if out <= 0.0:
            y -= lat_r * sin_banks[i]
        else:
            side = 1.0 if lat_r > 0.0 else -1.0
            y -= side * hw * sin_banks[i] + vdrop * out
        return y - CLEARANCE - VERGE_SLOPE * min(max(0.0, out), VERGE)

    def corridor(x, z):
        cx, cz = int(math.floor(x / CELL)), int(math.floor(z / CELL))
        best_d, best = 1e9, None
        cand = []
        for bx in range(cx - rc, cx + rc + 1):
            for bz in range(cz - rc, cz + rc + 1):
                for i in buckets.get((bx, bz), ()):
                    p = pts[i]
                    dx, dz = x - p[0], z - p[2]
                    d = math.hypot(dx, dz)
                    if d >= reach:
                        continue
                    tx, tz = tangents[i]
                    along = dx * tx + dz * tz
                    lat_r = dz * tx - dx * tz          # signed, + = right of the race direction
                    cand.append((i, along, lat_r))
                    if d < best_d:
                        best_d, best = d, (i, along, lat_r)
        if best is None:
            return best_d, None
        i0 = best[0]
        y = target(*best)
        for i, along, lat_r in cand:
            if abs(along) > COVER_SLACK:
                continue
            verge = verge_r[i] if lat_r > 0.0 else verge_l[i]
            if abs(lat_r) <= widths[i] * 0.5 + verge + CELL_REACH:
                y = min(y, target(i, along, lat_r))
        hw = widths[i0] * 0.5
        w = smoothstep(hw + VERGE + FLAT_MARGIN, hw + VERGE + FLAT_MARGIN + BLEND, best_d)
        return best_d, (y, w)

    return corridor


def main():
    track = json.load(open(os.path.join(OUT_DIR, "track.json")))
    lat0, lon0 = track["origin_latlon"]
    base = track["origin_elevation_m"]
    k = track["length"] / OSM_LENGTH
    kx = 111320.0 * math.cos(math.radians(lat0))
    ky = 111320.0

    def to_latlon(x, z):
        return (lat0 - (z / k) / ky, lon0 + (x / k) / kx)

    # ---- fetch -------------------------------------------------------------------------
    fx, fz = grid_axis(NEAR_X0, NEAR_X1, FETCH_STEP), grid_axis(NEAR_Z0, NEAR_Z1, FETCH_STEP)
    print(f"near grid {len(fx)}x{len(fz)} = {len(fx) * len(fz)} points")
    near_raw = fetch_grid(fx, fz, to_latlon, base)
    gx, gz = grid_axis(FAR_X0, FAR_X1, FAR_STEP), grid_axis(FAR_Z0, FAR_Z1, FAR_STEP)
    print(f"far grid {len(gx)}x{len(gz)} = {len(gx) * len(gz)} points")
    far = fetch_grid(gx, gz, to_latlon, base)

    corridor = make_corridor(track, load_profile(track))

    # ---- near mesh grid ----------------------------------------------------------------
    mx, mz = grid_axis(NEAR_X0, NEAR_X1, MESH_STEP), grid_axis(NEAR_Z0, NEAR_Z1, MESH_STEP)
    heights, dists = [], []
    for z in mz:
        for x in mx:
            u, v = (x - NEAR_X0) / FETCH_STEP, (z - NEAR_Z0) / FETCH_STEP
            h = bicubic(near_raw, u, v)
            # Border band: blend to the far grid's bilinear surface (exact match at the edge).
            edge = min(x - NEAR_X0, NEAR_X1 - x, z - NEAR_Z0, NEAR_Z1 - z)
            if edge < BORDER:
                hf = bilinear(far, (x - FAR_X0) / FAR_STEP, (z - FAR_Z0) / FAR_STEP)
                h = hf + (h - hf) * smoothstep(0.0, BORDER, edge)
            d, c = corridor(x, z)
            if c is not None:
                target, w = c
                h = target + (h - target) * w
            heights.append(h)
            dists.append(min(65535, int(round(d * 10.0))))
    # Far grid: vertices inside / on the near rectangle take the near surface (they are
    # skipped by the far mesh except on the boundary, where they must match exactly).
    nmx = len(mx)
    for j, z in enumerate(gz):
        for i, x in enumerate(gx):
            if NEAR_X0 <= x <= NEAR_X1 and NEAR_Z0 <= z <= NEAR_Z1:
                ii, jj = int(round((x - NEAR_X0) / MESH_STEP)), int(round((z - NEAR_Z0) / MESH_STEP))
                far[j][i] = heights[jj * nmx + ii]

    with open(os.path.join(OUT_DIR, "terrain_height.bin"), "wb") as f:
        f.write(struct.pack(f"<{len(heights)}f", *heights))
    with open(os.path.join(OUT_DIR, "terrain_dist.bin"), "wb") as f:
        f.write(struct.pack(f"<{len(dists)}H", *dists))
    flat_far = [v for row in far for v in row]
    with open(os.path.join(OUT_DIR, "terrain_far.bin"), "wb") as f:
        f.write(struct.pack(f"<{len(flat_far)}f", *flat_far))
    meta = {
        "frame": track["frame"],
        "origin_latlon": track["origin_latlon"],
        "origin_elevation_m": base,
        "plan_scale": k,
        "near": {"file": "terrain_height.bin", "dist_file": "terrain_dist.bin",
                 "x0": NEAR_X0, "z0": NEAR_Z0, "step": MESH_STEP, "nx": len(mx), "nz": len(mz)},
        "far": {"file": "terrain_far.bin", "x0": FAR_X0, "z0": FAR_Z0, "step": FAR_STEP,
                "nx": len(gx), "nz": len(gz)},
        "corridor": {"clearance": CLEARANCE, "verge_slope": VERGE_SLOPE, "verge": VERGE,
                     "flat_margin": FLAT_MARGIN, "blend": BLEND, "road_profile": "road_profile.json"},
        "attribution": "Elevation: EU-DEM v1.1 25 m (Copernicus, (c) European Union) via OpenTopoData.",
    }
    with open(os.path.join(OUT_DIR, "terrain.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print(f"near {len(mx)}x{len(mz)} y [{min(heights):.1f}, {max(heights):.1f}]  "
          f"far {len(gx)}x{len(gz)} y [{min(flat_far):.1f}, {max(flat_far):.1f}]")
    # Raw DEM reference values for tests (points well away from the corridor).
    for name, (x, z) in {"north_of_remus": (150.0, -950.0), "west_field": (-1300.0, -200.0),
                         "south_east": (600.0, 400.0)}.items():
        raw = bicubic(near_raw, (x - NEAR_X0) / FETCH_STEP, (z - NEAR_Z0) / FETCH_STEP)
        print(f"  {name} ({x:.0f}, {z:.0f}): raw DEM y = {raw:.2f}, dist to track {corridor(x, z)[0]:.0f} m")


if __name__ == "__main__":
    main()
