"""Terrain step: DEM heightmaps around the circuit (pure Python, no dependencies).

Reads track.json (and road_profile.json when the road step has run) from the output folder,
then fetches two DEM grids from OpenTopoData (100 locations per request, 1 request/s, raw
answers cached in raw/terrain_*.json):

  * near grid: 20 m spacing over the circuit plus a margin, bicubically upsampled to a 10 m
    mesh grid. Inside the track corridor the height is replaced by the road surface height
    minus CLEARANCE so road / verge meshes always cover it, then blended back to the DEM over
    BLEND m. The outer BORDER m blend to the bilinear far grid so both meshes meet.
  * far grid: 200 m spacing out to ~6 km for the low-poly surrounding hills.

A track with declared banking (road_profile.json has "verge_slope_left", see
cad/track/banking.py) gets the exact banked section, and a second pass: a 10 m mesh triangle
cannot follow the apron of a banked corner (the slope changes by a third within 8 m) or the
twist into the banking, so every triangle near such a stretch is sampled every REFINE_STEP m
and its three vertices are lowered until it lies under the target everywhere. Other tracks
skip both, and build byte for byte as before.

Bounds come from the centreline: its bounding box plus NEAR_MARGIN, snapped outward to the far
grid's 200 m lattice; the far grid is a square of at least 12 km around it. A recipe can pin
them with [terrain] near / far = [x0, x1, z0, z1]. [terrain] smooth_sigma_m smooths both grids
(flat city circuits, where buildings in the surface model would become hills).

Frame: x = east, z = -north, y = elevation - origin_elevation_m. The plan view (x, z) uses
the same uniform scale k = official length / OSM length as the centreline, so terrain lines up.

Outputs (little endian, row-major: row = z index, column = x index):
  terrain_height.bin   float32 near heights (final, corridor-conformed)
  terrain_dist.bin     uint16  distance to the centreline in decimetres (clamped to 6553.5 m)
  terrain_far.bin      float32 far heights
  terrain.json         grid metadata
"""
import json
import math
import os
import struct

from . import geom, net
from .net import BuildError

FETCH_STEP = 20.0
MESH_STEP = 10.0
FAR_STEP = 200.0
NEAR_MARGIN = 450.0   # m of terrain around the centreline's bounding box, before snapping
FAR_HALF = 6000.0     # m: half side of the far square (grown for very large circuits)
FAR_MARGIN = 4000.0   # m: least distance from the near rectangle to the far edge

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
REFINE_STEP = 2.0   # m: sample spacing of the banked-corridor check, see refine_banked()
REFINE_BANK = 0.03  # rad: stretches banked steeper than the automatic camber are checked
REFINE_AROUND = 15  # centreline points either side of such a stretch that are checked too
BORDER = 160.0      # near-grid border band blended to the far grid


def default_bounds(points):
    """(near, far) rectangles [x0, x1, z0, z1] for a centreline given as [x, y, z] points."""
    xs = [p[0] for p in points]
    zs = [p[2] for p in points]
    near = [math.floor((min(xs) - NEAR_MARGIN) / FAR_STEP) * FAR_STEP,
            math.ceil((max(xs) + NEAR_MARGIN) / FAR_STEP) * FAR_STEP,
            math.floor((min(zs) - NEAR_MARGIN) / FAR_STEP) * FAR_STEP,
            math.ceil((max(zs) + NEAR_MARGIN) / FAR_STEP) * FAR_STEP]
    half = max(FAR_HALF, math.ceil((0.5 * max(near[1] - near[0], near[3] - near[2]) + FAR_MARGIN)
                                   / FAR_STEP) * FAR_STEP)
    # Far centre: the near centre snapped to the far lattice (halves round up).
    cx = math.floor(0.5 * (near[0] + near[1]) / FAR_STEP + 0.5) * FAR_STEP
    cz = math.floor(0.5 * (near[2] + near[3]) / FAR_STEP + 0.5) * FAR_STEP
    return near, [cx - half, cx + half, cz - half, cz + half]


def _check_bounds(near, far, points):
    for name, b in (("near", near), ("far", far)):
        if any(abs(v / FAR_STEP - round(v / FAR_STEP)) > 1e-9 for v in b):
            raise BuildError(f"terrain {name} bounds must be multiples of {FAR_STEP:.0f} m")
    if not (far[0] <= near[0] - 5 * FAR_STEP and near[1] + 5 * FAR_STEP <= far[1]
            and far[2] <= near[2] - 5 * FAR_STEP and near[3] + 5 * FAR_STEP <= far[3]):
        raise BuildError("terrain far bounds must enclose the near bounds by at least 1 km")
    reach = BORDER + BLEND + VERGE + FLAT_MARGIN + 10.0
    xs, zs = [p[0] for p in points], [p[2] for p in points]
    if min(xs) - reach < near[0] or max(xs) + reach > near[1] or min(zs) - reach < near[2] or max(zs) + reach > near[3]:
        raise BuildError("terrain near bounds are too tight: the track corridor reaches the border band")


def grid_axis(a, b, step):
    n = int(round((b - a) / step)) + 1
    return [a + i * step for i in range(n)]


def fetch_grid(fetcher, dataset, xs, zs, to_latlon, base):
    latlon = [to_latlon(x, z) for z in zs for x in xs]
    e = net.fetch_elevations(fetcher, latlon, dataset, "terrain")
    h = [[0.0] * len(xs) for _ in zs]
    voids = 0
    for j in range(len(zs)):
        for i in range(len(xs)):
            v = e[j * len(xs) + i]
            h[j][i] = (v - base) if v is not None else None
            voids += v is None
    # Fill voids (sea, dataset edges) with the nearest valid value in the row.
    for row in h:
        for i, v in enumerate(row):
            if v is None:
                row[i] = next((row[k] for d in range(1, len(row)) for k in (i - d, i + d)
                               if 0 <= k < len(row) and row[k] is not None), 0.0)
    return h, voids


def smooth_grid(h, sigma):
    """Gaussian blur of a row-major grid; `sigma` in cells, edges repeat. Returns a new grid."""
    if sigma <= 0.0:
        return [row[:] for row in h]
    r = max(1, int(math.ceil(3.0 * sigma)))
    w = [math.exp(-0.5 * (k / sigma) ** 2) for k in range(-r, r + 1)]
    tot = sum(w)
    w = [x / tot for x in w]

    def blur(v):
        n = len(v)
        return [sum(w[k + r] * v[min(n - 1, max(0, i + k))] for k in range(-r, r + 1)) for i in range(n)]

    rows = [blur(row) for row in h]
    cols = [blur([row[i] for row in rows]) for i in range(len(rows[0]))]
    return [[cols[i][j] for i in range(len(cols))] for j in range(len(rows))]


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


def load_profile(track, out_dir):
    """CAD road cross-section profile (widths, bank, per-side verge widths), falling back to
    track.json's widths / banks with full verges if road_profile.json is missing."""
    n = len(track["points"])
    path = os.path.join(out_dir, "road_profile.json")
    if os.path.exists(path):
        with open(path) as f:
            pr = json.load(f)
        if len(pr["width"]) != n:
            raise BuildError("road_profile.json does not match track.json: run the 'road' step again")
        profile = {"width": pr["width"], "bank": pr["bank"], "verge_l": pr["verge_left"],
                   "verge_r": pr["verge_right"], "verge_width": pr.get("verge_width", VERGE),
                   "verge_drop": pr.get("verge_drop", 0.25)}
        if "verge_slope_left" in pr:
            # Declared banking (cad/track/road.py): the verge's extra slope on each side.
            profile.update(slope_l=pr["verge_slope_left"], slope_r=pr["verge_slope_right"],
                           shoulder=pr["verge_shoulder"], verge_blend=pr["verge_blend"])
        return profile, True
    pts = track["points"]
    return {"width": [p.get("width", 13.0) for p in pts], "bank": [p.get("bank", 0.0) for p in pts],
            "verge_l": [VERGE] * n, "verge_r": [VERGE] * n, "verge_width": VERGE, "verge_drop": 0.25}, False


def make_corridor(track, profile):
    """Returns corridor(x, z) -> (distance to centreline, (target height, blend weight) or None).

    The target follows the nearest cross-section of the CAD road: banked road plane, then the
    verge dropping verge_drop over verge_width (extrapolated beyond it), each continued along
    the track by its grade, minus CLEARANCE and VERGE_SLOPE per metre past the edge. Only
    where several cross-sections genuinely cover the same spot (the inside of corners, other
    legs of a hairpin) the lowest of them wins, so the terrain stays under all of them.

    corridor.probe(x, z) -> (distance, nearest point index or None, target, weight) is the same
    with the index of the nearest cross-section.
    """
    pts = [p["p"] for p in track["points"]]
    grades = [p.get("grade", 0.0) for p in track["points"]]
    widths = profile["width"]
    sin_banks = [math.sin(b) for b in profile["bank"]]
    verge_l, verge_r = profile["verge_l"], profile["verge_r"]
    vdrop = profile["verge_drop"] / profile["verge_width"]
    n = len(pts)
    banked = "slope_l" in profile
    if banked:
        cos_banks = [math.cos(b) for b in profile["bank"]]
        slope_l, slope_r = profile["slope_l"], profile["slope_r"]
        shoulder, vblend = profile["shoulder"], profile["verge_blend"]
        # The road normal leans along the track by the grade: its vertical part scales what
        # the bank lifts (cad/track/road.py: U0).
        up_y = [1.0 / math.sqrt(1.0 + g * g) for g in grades]
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

    def target_banked(i, along, lat_r):
        """The section as cad/track/road.py builds it: the road rolled about the centreline (so
        its edge is hw * cos(bank) out in plan view), then the banked verge."""
        hw = widths[i] * 0.5
        y = pts[i][1] + grades[i] * along
        rise = sin_banks[i] * up_y[i]
        out = abs(lat_r) - hw * cos_banks[i]
        if out <= 0.0:
            return y - lat_r * rise / cos_banks[i] - CLEARANCE
        side = 1.0 if lat_r > 0.0 else -1.0
        u = min(max(out - shoulder, 0.0), vblend)
        reach = min(out, shoulder) + u - u * u / (2.0 * vblend)      # road.py: verge_shape()
        y += (slope_r[i] if lat_r > 0.0 else slope_l[i]) * reach
        return y - side * hw * rise - vdrop * out - CLEARANCE - VERGE_SLOPE * min(out, VERGE)

    def target(i, along, lat_r):
        if banked:
            return target_banked(i, along, lat_r)
        hw = widths[i] * 0.5
        y = pts[i][1] + grades[i] * along
        out = abs(lat_r) - hw
        if out <= 0.0:
            y -= lat_r * sin_banks[i]
        else:
            side = 1.0 if lat_r > 0.0 else -1.0
            y -= side * hw * sin_banks[i] + vdrop * out
        return y - CLEARANCE - VERGE_SLOPE * min(max(0.0, out), VERGE)

    def probe(x, z):
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
            return best_d, None, 0.0, 1.0
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
        return best_d, i0, y, w

    def corridor(x, z):
        d, i0, y, w = probe(x, z)
        return d, (None if i0 is None else (y, w))

    corridor.probe = probe
    return corridor


def refine_banked(heights, nearest, mx, mz, corridor, profile, log=print):
    """Lowers the near grid ``heights`` (row-major, in place) wherever one of its triangles
    would rise above the corridor target beside a banked stretch of the road. ``nearest`` is
    the nearest centreline point of every vertex within the verge's reach, else None.

    The grid is a 10 m mesh, split as scripts/track/terrain.gd splits it (each cell along the
    diagonal from (i + 1, j) to (i, j + 1)); the target is curved across a banked verge and
    twisted along the transition into the banking, so a flat triangle through three correct
    vertices can still cut through the road. Each triangle near such a stretch is sampled every
    REFINE_STEP m; where it is above the target, its vertices go down, each in proportion to
    its weight at the worst sample (so the vertex beside the trouble moves, not the one at the
    far end of the verge, where the terrain shows), until no sample is above. Lowering can
    only help the neighbouring triangles. Returns the number of triangles lowered and the
    largest excess (m)."""
    banks = profile["bank"]
    n = len(banks)
    steep = [False] * n
    for i, b in enumerate(banks):
        if abs(b) > REFINE_BANK:
            for k in range(-REFINE_AROUND, REFINE_AROUND + 1):
                steep[(i + k) % n] = True
    if not any(steep):
        return 0, 0.0
    nx, nz = len(mx), len(mz)
    step = mx[1] - mx[0]
    m = max(2, int(round(step / REFINE_STEP)))
    # Only cells with a vertex beside a steep stretch are sampled.
    near = [i0 is not None and steep[i0] for i0 in nearest]
    lowered, worst = 0, 0.0
    for j in range(nz - 1):
        for i in range(nx - 1):
            a = j * nx + i
            quad = (a, a + 1, a + nx, a + nx + 1)
            if not any(near[q] for q in quad):
                continue
            corner = {a: (mx[i], mz[j]), a + 1: (mx[i + 1], mz[j]),
                      a + nx: (mx[i], mz[j + 1]), a + nx + 1: (mx[i + 1], mz[j + 1])}
            for tri in ((a, a + 1, a + nx), (a + 1, a + nx + 1, a + nx)):
                p0, p1, p2 = (corner[q] for q in tri)
                samples = []                # (weights of the three vertices, target)
                for u in range(m + 1):
                    for v in range(m + 1 - u):
                        if (u, v) in ((0, 0), (m, 0), (0, m)):
                            continue        # the vertices are on the target already
                        b1, b2 = u / m, v / m
                        b0 = 1.0 - b1 - b2
                        d, i0, y, w = corridor.probe(b0 * p0[0] + b1 * p1[0] + b2 * p2[0],
                                                     b0 * p0[1] + b1 * p1[1] + b2 * p2[1])
                        if i0 is not None and w <= 0.0:   # beyond the flat zone the terrain is the DEM's
                            samples.append(((b0, b1, b2), y))
                first = 0.0
                for attempt in range(12):
                    excess, at = 0.0, None
                    for b, y in samples:
                        e = sum(bq * heights[q] for bq, q in zip(b, tri)) - y
                        if e > excess:
                            excess, at = e, b
                    if excess <= 1e-6:
                        break
                    first = first or excess
                    # Lowers the triangle by exactly the excess at the worst sample; the last
                    # attempt lowers all of it, which settles every sample.
                    norm = sum(bq * bq for bq in at) if attempt < 11 else 1.0
                    for bq, q in zip(at, tri):
                        heights[q] -= excess * (bq / norm if attempt < 11 else 1.0)
                if first > 0.0:
                    lowered += 1
                    worst = max(worst, first)
    log(f"  banked corridor: {lowered} mesh triangles lowered by up to {worst:.2f} m to stay under "
        "the road and its verge")
    return lowered, worst


def plan_scale(track, out_dir):
    """k = game metres per real metre in the plan view (official / OSM lap length)."""
    from . import centreline
    info = centreline.read_info(out_dir)
    osm_length = (info.get("osm") or {}).get("length_m")
    if not osm_length:
        raise BuildError(f"build_info.json in {out_dir} is missing or has no OSM lap length: "
                         "run the 'centreline' step first")
    return track["length"] / float(osm_length), info


def build(recipe, out_dir, fetcher, log=print):
    with open(os.path.join(out_dir, "track.json"), encoding="utf-8") as f:
        track = json.load(f)
    lat0, lon0 = track["origin_latlon"]
    base = track["origin_elevation_m"]
    k, info = plan_scale(track, out_dir)
    dataset = recipe.dem_dataset or info.get("dem_dataset") or net.choose_dataset(lat0, lon0)
    kx = geom.EARTH_M_PER_DEG * math.cos(math.radians(lat0))
    ky = geom.EARTH_M_PER_DEG

    def to_latlon(x, z):
        return (lat0 - (z / k) / ky, lon0 + (x / k) / kx)

    pts = [p["p"] for p in track["points"]]
    near, far_b = default_bounds(pts)
    near = [float(v) for v in recipe.terrain.get("near", near)]
    far_b = [float(v) for v in recipe.terrain.get("far", far_b)]
    _check_bounds(near, far_b, pts)
    NEAR_X0, NEAR_X1, NEAR_Z0, NEAR_Z1 = near
    FAR_X0, FAR_X1, FAR_Z0, FAR_Z1 = far_b

    # ---- fetch -------------------------------------------------------------------------
    fx, fz = grid_axis(NEAR_X0, NEAR_X1, FETCH_STEP), grid_axis(NEAR_Z0, NEAR_Z1, FETCH_STEP)
    gx, gz = grid_axis(FAR_X0, FAR_X1, FAR_STEP), grid_axis(FAR_Z0, FAR_Z1, FAR_STEP)
    total = len(fx) * len(fz) + len(gx) * len(gz)
    log(f"terrain ({dataset}): near grid {len(fx)}x{len(fz)} + far grid {len(gx)}x{len(gz)} = {total} "
        f"points, {math.ceil(len(fx) * len(fz) / 100) + math.ceil(len(gx) * len(gz) / 100)} requests "
        "when nothing is cached")
    near_raw, v1 = fetch_grid(fetcher, dataset, fx, fz, to_latlon, base)
    far, v2 = fetch_grid(fetcher, dataset, gx, gz, to_latlon, base)
    if v1 + v2:
        log(f"  {v1 + v2} DEM voids (sea / dataset edge) filled from the nearest valid point in their row")

    sigma = float(recipe.terrain.get("smooth_sigma_m", 0.0))
    if sigma > 0.0:
        # Flat sites: the DEM's noise (a few metres) would otherwise show as rolling hills.
        near_raw = smooth_grid(near_raw, sigma / FETCH_STEP)
        far = smooth_grid(far, sigma / FAR_STEP)
        log(f"  DEM smoothed with a {sigma:.0f} m Gaussian ([terrain] smooth_sigma_m)")

    profile, has_profile = load_profile(track, out_dir)
    if not has_profile:
        log("  road_profile.json not found: using nominal widths (run the 'road' step before 'terrain')")
    corridor = make_corridor(track, profile)

    # ---- near mesh grid ----------------------------------------------------------------
    mx, mz = grid_axis(NEAR_X0, NEAR_X1, MESH_STEP), grid_axis(NEAR_Z0, NEAR_Z1, MESH_STEP)
    heights, dists, nearest = [], [], []
    verge_reach = max(profile["width"]) * 0.5 + VERGE + CELL_REACH
    for z in mz:
        for x in mx:
            u, v = (x - NEAR_X0) / FETCH_STEP, (z - NEAR_Z0) / FETCH_STEP
            h = bicubic(near_raw, u, v)
            # Border band: blend to the far grid's bilinear surface (exact match at the edge).
            edge = min(x - NEAR_X0, NEAR_X1 - x, z - NEAR_Z0, NEAR_Z1 - z)
            if edge < BORDER:
                hf = bilinear(far, (x - FAR_X0) / FAR_STEP, (z - FAR_Z0) / FAR_STEP)
                h = hf + (h - hf) * smoothstep(0.0, BORDER, edge)
            d, i0, target, w = corridor.probe(x, z)
            if i0 is not None:
                h = target + (h - target) * w
            heights.append(h)
            dists.append(min(65535, int(round(d * 10.0))))
            nearest.append(i0 if d <= verge_reach else None)
    if "slope_l" in profile:
        refine_banked(heights, nearest, mx, mz, corridor, profile, log)
    # Far grid: vertices inside / on the near rectangle take the near surface (they are
    # skipped by the far mesh except on the boundary, where they must match exactly).
    nmx = len(mx)
    for j, z in enumerate(gz):
        for i, x in enumerate(gx):
            if NEAR_X0 <= x <= NEAR_X1 and NEAR_Z0 <= z <= NEAR_Z1:
                ii, jj = int(round((x - NEAR_X0) / MESH_STEP)), int(round((z - NEAR_Z0) / MESH_STEP))
                far[j][i] = heights[jj * nmx + ii]

    with open(os.path.join(out_dir, "terrain_height.bin"), "wb") as f:
        f.write(struct.pack(f"<{len(heights)}f", *heights))
    with open(os.path.join(out_dir, "terrain_dist.bin"), "wb") as f:
        f.write(struct.pack(f"<{len(dists)}H", *dists))
    flat_far = [v for row in far for v in row]
    with open(os.path.join(out_dir, "terrain_far.bin"), "wb") as f:
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
        "attribution": net.attribution(dataset),
    }
    with open(os.path.join(out_dir, "terrain.json"), "w") as f:
        json.dump(meta, f, indent=1)
    log(f"terrain: near {len(mx)}x{len(mz)} y [{min(heights):.1f}, {max(heights):.1f}]  "
        f"far {len(gx)}x{len(gz)} y [{min(flat_far):.1f}, {max(flat_far):.1f}]")
    return meta
