"""Centreline step: OSM loop + DEM -> track.json.

Output frame (Godot): x = east, y = elevation above the finish line, z = -north, metres, in a
local tangent plane centred on the finish line. The lap runs in the race direction and
s = distance along the centreline from the finish line.

The plan view is resampled every 2 m (Catmull-Rom), lightly smoothed (sigma 4 m) to remove
the vertex kinks of the sparse OSM polyline, and scaled uniformly so the lap has exactly the
official length. Elevation is sampled from the DEM every ~10 m at the true (unscaled)
positions and smoothed along the lap (sigma 45 m) to remove embankment / tree noise.
"""
import json
import math
import os

from . import geom, net, osm, turns as turns_mod
from .net import BuildError

STEP = 2.0            # resample spacing, m
DEM_STEP = 10.0       # DEM sampling spacing, m
PLAN_SIGMA = 4.0      # m, plan-view smoothing
CURV_SIGMA = 6.0      # m, curvature smoothing
DEFAULT_WIDTH = 13.0  # nominal width stored per point; road_profile.json has the real one
FRAME = "Godot metres: x=east, y=up (relative to finish line), z=-north; origin at finish line"


def _longest_straight_mid(pts):
    """Index into ``pts`` (a rough resampled loop) of the middle of the longest straight."""
    samples, _, step, _ = geom.catmull_resample(pts, [""] * len(pts), 4.0)
    curv = geom.gauss_periodic(geom.curvature(samples, step), 10.0 / step)
    n = len(samples)
    straight = [abs(c) < 1.0 / 800.0 for c in curv]
    if all(straight) or not any(straight):
        return samples[0]
    start = straight.index(False)
    best, run, best_mid = 0, 0, start
    for i in range(1, n + 1):
        k = (start + i) % n
        if straight[k]:
            run += 1
            if run > best:
                best, best_mid = run, (start + i - run // 2) % n
        else:
            run = 0
    return samples[best_mid]


def _elevations(fetcher, latlon, recipe, log, warnings):
    """DEM heights for the centreline; picks the dataset by coverage. Returns (values, dataset)."""
    lat, lon = latlon[0]
    dataset = recipe.dem_dataset or net.choose_dataset(lat, lon)
    while True:
        vals = net.fetch_elevations(fetcher, latlon, dataset, "dem")
        missing = sum(v is None for v in vals)
        if missing <= 0.2 * len(vals):
            break
        nxt = None if recipe.dem_dataset else net.fallback_dataset(dataset, lat)
        if nxt is None:
            raise net.CoverageError(f"DEM dataset {dataset} has no data for {missing} of {len(vals)} "
                                    "centreline points; set [elevation] dataset in the recipe")
        log(f"  {dataset} does not cover this circuit ({missing}/{len(vals)} voids); trying {nxt}")
        dataset = nxt
    if missing:
        warnings.append(f"{missing} DEM voids on the centreline were filled from their neighbours")
        m = len(vals)
        for i in range(m):
            if vals[i] is None:
                near = next((vals[(i + d * sgn) % m] for d in range(1, m) for sgn in (-1, 1)
                             if vals[(i + d * sgn) % m] is not None))
                vals[i] = near
    return vals, dataset


def build(recipe, fetcher, log=print):
    """Returns (track dict for track.json, build info dict)."""
    warnings = []
    data = osm.fetch(recipe, fetcher)
    loop = osm.find_loop(data, recipe, log)
    warnings += loop.warnings
    chain, names = loop.node_ids, loop.names

    # ---- start / finish ------------------------------------------------------------------
    finish, start, sf_source = osm.start_finish_nodes(data, recipe, loop)
    if recipe.finish:
        finish, sf_source = tuple(recipe.finish), "recipe"
    if recipe.start:
        start = tuple(recipe.start)
    if finish is None and start is not None:
        finish = start
        sf_source += " (finish line = start line)"
    fallback_finish = finish is None
    if fallback_finish:
        # Provisional frame on the first node; re-centred on the chosen point below.
        finish = data.nodes[chain[0]]

    def project(lat0, lon0):
        kx = geom.EARTH_M_PER_DEG * math.cos(math.radians(lat0))
        ky = geom.EARTH_M_PER_DEG
        return kx, ky, (lambda lat, lon: ((lon - lon0) * kx, -(lat - lat0) * ky))

    lat0, lon0 = finish
    kx, ky, to_xz = project(lat0, lon0)
    if fallback_finish:
        mid = _longest_straight_mid([to_xz(*data.nodes[i]) for i in chain])
        lat0, lon0 = lat0 - mid[1] / ky, lon0 + mid[0] / kx
        kx, ky, to_xz = project(lat0, lon0)
        sf_source = "middle of the longest straight"
        warnings.append("no start / finish line in the OSM data: the finish line was put in the "
                        f"middle of the longest straight ({lat0:.6f}, {lon0:.6f}). Check it and set "
                        "[layout] finish = [lat, lon] in the recipe")

    pts = [to_xz(*data.nodes[i]) for i in chain]

    # ---- driving direction ---------------------------------------------------------------
    clockwise = geom.signed_area(pts) > 0.0
    want = recipe.direction
    if want is not None and (want == "clockwise") != clockwise:
        if loop.directed and not recipe.osm_ways:
            warnings.append(f"the OSM oneway tags run {'clockwise' if clockwise else 'anticlockwise'} "
                            f"but the recipe says {want}; following the recipe")
        pts.reverse()
        names = names[::-1]
        clockwise = not clockwise

    # Rotate the loop so it starts at the vertex nearest the finish line, then insert the
    # exact projection of the finish point as s = 0.
    origin = (0.0, 0.0)
    best = min(range(len(pts)), key=lambda i: geom.seg_dist(pts[i], pts[(i + 1) % len(pts)], origin)[0])
    off, proj = geom.seg_dist(pts[best], pts[(best + 1) % len(pts)], origin)
    if off > 30.0:
        warnings.append(f"the finish line point is {off:.0f} m away from the loop; check [layout] finish")
    pts = [proj] + pts[best + 1:] + pts[:best + 1]
    names = [names[best]] + names[best + 1:] + names[:best + 1]

    # ---- plan view -----------------------------------------------------------------------
    samples, sample_names, step, raw_length = geom.catmull_resample(pts, names, STEP, recipe.spline)
    samples = geom.smooth_loop_xy(samples, sigma=PLAN_SIGMA / step)
    samples, step, osm_length = geom.respace(samples, STEP)
    # OSM ways are rarely drawn to the official length; scale the plan view uniformly so the
    # lap is exactly the official one.
    official = float(recipe.length_m)
    k_scale = official / osm_length
    scale_err = osm_length / official - 1.0
    if abs(scale_err) > 0.02:
        warnings.append(f"the OSM loop is {100 * scale_err:+.1f} % off the official length "
                        f"({osm_length:.0f} m vs {official:.0f} m): check that it is the right layout")
    true_samples = samples  # unscaled, used for DEM lookups at real lat / lon
    samples = [(x * k_scale, z * k_scale) for x, z in samples]
    step *= k_scale
    length = official
    n = len(samples)
    sample_names = [sample_names[min(len(sample_names) - 1, int(k * len(sample_names) / n))] for k in range(n)]

    if start is not None:
        sx, sz = to_xz(*start)
        sx, sz = sx * k_scale, sz * k_scale     # same plan-view scale as the samples
        k_start = geom.closest_index(samples, (sx, sz))
        if math.dist(samples[k_start], (sx, sz)) > 30.0:
            warnings.append("the start line point is more than 30 m from the loop; ignoring it")
            k_start = 0
        start_s = k_start * step
    else:
        start_s = 0.0
    if recipe.start_offset_m is not None:
        start_s = float(recipe.start_offset_m) % length

    # ---- elevation -----------------------------------------------------------------------
    dem_idx = list(range(0, n, int(DEM_STEP / step)))
    latlon = [(lat0 - true_samples[i][1] / ky, lon0 + true_samples[i][0] / kx) for i in dem_idx]
    elev, dataset = _elevations(fetcher, latlon, recipe, log, warnings)
    dem_s = [i * step for i in dem_idx]
    y = geom.periodic_interp(dem_s, elev, [k * step for k in range(n)], length)
    y = geom.gauss_periodic(y, sigma=recipe.elev_sigma_m / step)
    base = y[0]
    y = [v - base for v in y]

    # ---- curvature, turns, sectors -------------------------------------------------------
    curv_s = geom.gauss_periodic(geom.curvature(samples, step), sigma=CURV_SIGMA / step)
    auto = turns_mod.detect(curv_s, step, sample_names, recipe.turns)
    if recipe.turns_pinned:
        turn_list = turns_mod.pinned(curv_s, step, recipe.turn_table)
    else:
        turn_list = turns_mod.apply_names(auto["turns"], recipe.turn_table, warnings)
        warnings += auto["warnings"]
    sectors = turns_mod.sectors(curv_s, step, recipe.sectors)

    pts_out = []
    for k in range(n):
        g = (y[(k + 1) % n] - y[k - 1]) / (2 * step)
        pts_out.append({
            "s": round(k * step, 3),
            "p": [round(samples[k][0], 3), round(y[k], 3), round(samples[k][1], 3)],
            "width": DEFAULT_WIDTH,
            "bank": 0.0,
            "grade": round(g, 4),
            "curvature": round(curv_s[k], 5),
        })

    if recipe.osm_relation:
        src = f"relation {recipe.osm_relation}"
    else:
        src = "ways " + ", ".join(str(w) for w in loop.way_ids[:4]) + (" ..." if len(loop.way_ids) > 4 else "")
    track = {
        "name": recipe.full_name,
        "length": round(length, 3),
        "official_length": official,
        "closed": True,
        "direction": "clockwise" if clockwise else "anticlockwise",
        "frame": FRAME,
        "origin_latlon": [lat0, lon0],
        "origin_elevation_m": round(base, 2),
        "step": step,
        "start_s": round(start_s, 3),
        "finish_s": 0.0,
        "sectors": sectors,
        "turns": turn_list,
        "elevation_range": round(max(y) - min(y), 2),
        "points": pts_out,
        "attribution": f"Centreline (c) OpenStreetMap contributors (ODbL 1.0), {src}. "
                       + net.attribution(dataset),
    }
    grades = [p["grade"] for p in pts_out]
    info = {
        "id": recipe.id,
        "recipe": recipe.source or None,
        "osm": {"relation": recipe.osm_relation, "loop_ways": loop.way_ids,
                "raw_length_m": round(raw_length, 1), "length_m": round(osm_length, 1),
                "official_length_m": official, "length_error": round(scale_err, 5),
                "candidates": [{"length_m": round(c[1], 1), "ways": c[2]} for c in loop.candidates]},
        "start_finish_source": sf_source,
        "dem_dataset": dataset,
        "elevation": {"range_m": track["elevation_range"], "max_grade": max(grades),
                      "min_grade": min(grades), "origin_m": track["origin_elevation_m"]},
        "turns": {"official": recipe.turns, "mode": "recipe" if recipe.turns_pinned else "auto",
                  "auto": auto["turns"], "auto_candidates": auto["candidates"]},
        "warnings": warnings,
    }
    log(f"centreline: {length:.1f} m (OSM {osm_length:.1f} m, {100 * scale_err:+.2f} %), {n} points, "
        f"{track['direction']}, start_s {start_s:.1f}, finish from {sf_source}")
    log(f"elevation ({dataset}): range {track['elevation_range']} m, max climb {100 * max(grades):.1f} %, "
        f"max descent {100 * min(grades):.1f} %")
    for t in turn_list:
        log(f"  {t['id']:>3} {t['name']:<24} s={t['s_apex']:7.1f}  {t['direction']:<5}  "
            f"min radius {t['min_radius']:.0f} m  elev {y[int(t['s_apex'] / step) % n]:+.1f} m")
    return track, info


def write(track, info, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "track.json"), "w", encoding="utf-8") as f:
        json.dump(track, f, separators=(",", ":"), ensure_ascii=False)
    write_info(info, out_dir)


def write_info(info, out_dir):
    with open(os.path.join(out_dir, "build_info.json"), "w", encoding="utf-8") as f:
        json.dump(info, f, indent=1, ensure_ascii=False)
        f.write("\n")


def read_info(out_dir):
    try:
        with open(os.path.join(out_dir, "build_info.json"), encoding="utf-8") as f:
            return json.load(f)
    except OSError:
        return {}
