"""Trackside table of the survey Circuit de la Sarthe (wec_le_mans_survey), from data.

    .venv/bin/python tools/track/landmarks/wec_le_mans_survey_trackside.py      (from fun-racer/)

Run it AFTER tools/track/build_track.py wec_le_mans_survey and lib.ortho (it reads the built
track.json and ortho_edges.json) and writes scripts/track/trackside_layouts/wec_le_mans_survey.gd,
the TracksideLayout table (kerbs, run-off areas, barrier distances, concrete walls). The
dressing (trees, catch fences, boards, tyre walls) stays the one of wec_le_mans.json.

Where every entry comes from:

  * kerbs: the kerb segments traced on the BD ORTHO 20 cm (IGN) by lib.ortho
    (ortho_edges.json "kerbs"): pieces closer than 6 m are joined, pieces shorter than 8 m and
    "kerbs" lying more than 0.5 m inside the traced edge (worn paint, hatching) are dropped.
    Wide striped kerbs (>= 2.5 m, the flat red / white and blue / white ones of the Bugatti
    part) are "flat", the narrower ones "saw";
  * run-off: ortho_edges.json "runoff" polygons, tarmac and gravel (grass is the verge),
    not "capped" (a car park or a field), at least 15 m long and 2 m deep (tarmac starting
    more than 6 m out is a service road), on the permanent circuit or near a corner of the public roads (a tarmac "run-off" in the middle of the
    Mulsanne straight is a lay-by or a junction). Clipped so they end before the wall;
  * barrier distances: OpenStreetMap barrier=wall / guard_rail ways (ODbL) running parallel
    to the lap within 35 m: the circuit's armco and walls are mapped all round the lap (the
    armco of the D338 1 to 2 m from the white line, the walls of the Porsche curves 2 to 7 m),
    measured from the traced tarmac edge, median-filtered over 30 m and cut into constant
    stretches, with at least CORNER_ROOM outside the slow corners. Where OSM has nothing: DEFAULT_PUBLIC on the public roads, DEFAULT_CIRCUIT on
    the permanent circuit (the run-off areas push the wall out on their own);
  * concrete walls with catch fences: the Bugatti part shared with the permanent circuit (Ford
    chicanes, pits, Dunlop, the Esses, Tertre Rouge); armco everywhere else.

Positions are metres along the lap of track.json; the trackside table expresses kerbs and
run-off relative to the turn table (so a rebuilt centreline keeps them on their corners) and
the barrier stretches as absolute s scaled by the lap length (LAP_LENGTH).
"""

from __future__ import annotations

import hashlib
import json
import os
import sys

import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "track"))

from lib import geom, net  # noqa: E402

TRACK_ID = "wec_le_mans_survey"
TRACK_DIR = os.path.join(ROOT, "assets", "tracks", TRACK_ID)
TABLE_OUT = os.path.join(ROOT, "scripts", "track", "trackside_layouts", TRACK_ID + ".gd")

# Public roads (closed for the race): the Mulsanne (D338), the Route du Golf (D140) and the
# D139 towards the Porsche curves. The rest is permanent circuit.
PUBLIC = [(2250.0, 11450.0)]
# Concrete wall + catch fence: the Bugatti part, from the Ford chicanes to Tertre Rouge.
CONCRETE = [(12950.0, 2250.0)]
DEFAULT_PUBLIC = 2.0       # m from the edge to the armco where OSM has no barrier
DEFAULT_CIRCUIT = 5.0
MIN_GAP = 0.7              # m: closest wall to the tarmac edge (plus any kerb)
MAX_GAP = 25.0             # m: a mapped wall further out is not the barrier
STRETCH_TOL = 0.75         # m: one barrier stretch while the distance stays this close
STRETCH_MIN = 40.0         # m: shortest barrier stretch
BEHIND_RUNOFF = 1.0        # BARRIER_BEHIND_RUNOFF of the table
RUNOFF_ALLOWANCE = 2.5     # TracksideLayout.RUNOFF_KERB_ALLOWANCE
KERB_PROFILE_WIDTH = {"flat": 1.5, "saw": 1.8}
# Outside of the slow corners the wall keeps at least this much room (m from the edge), from
# CORNER_ROOM_BEFORE before the apex to CORNER_ROOM_AFTER after it: the nearest mapped wall
# there is often the inner wall of an escape road, and a car sliding wide on the exit (the
# simulation handling) must not be stopped dead by armco 2 m from the line.
CORNER_ROOM = 8.0
CORNER_ROOM_RADIUS = 150.0
CORNER_ROOM_BEFORE = 40.0
CORNER_ROOM_AFTER = 120.0
CORNER_RADIUS = 150.0      # public-road corners tighter than this keep their run-off ...
CORNER_REACH = 220.0       # ... within this many metres of the apex

OVERPASS_QUERY = """[out:json][timeout:180][bbox:{s},{w},{n},{e}];
(way["barrier"~"^(wall|guard_rail|jersey_barrier|fence)$"];);
out geom;"""


# ---------------------------------------------------------------- lap frame
class Lap:
    def __init__(self, track, plan_scale):
        self.track = track
        self.L = float(track["length"])
        self.step = float(track["step"])
        self.P = np.array([[p["p"][0], p["p"][2]] for p in track["points"]], float)
        self.proj = geom.Projection(track["origin_latlon"][0], track["origin_latlon"][1], plan_scale)
        t = np.roll(self.P, -1, 0) - np.roll(self.P, 1, 0)
        self.tan = t / np.linalg.norm(t, axis=1)[:, None]
        # Godot's right = forward x up: (tx, tz) -> (-tz, tx)
        self.right = np.column_stack([-self.tan[:, 1], self.tan[:, 0]])
        from scipy.spatial import cKDTree
        self.tree = cKDTree(self.P)

    def locate(self, x, z):
        """(s, lateral offset (+ = right of the race direction), distance to the line, index)."""
        q = np.column_stack([np.atleast_1d(x), np.atleast_1d(z)])
        d, i = self.tree.query(q)
        v = q - self.P[i]
        s = (i * self.step + (v * self.tan[i]).sum(1)) % self.L
        return s, (v * self.right[i]).sum(1), d, i

    def latlon(self, lat, lon):
        return self.proj.to_xz(np.asarray(lat, float), np.asarray(lon, float))


def delta_s(a, b, L):
    """b - a wrapped into [-L/2, L/2)."""
    return (b - a + 0.5 * L) % L - 0.5 * L


def in_ranges(s, ranges, L):
    for a, b in ranges:
        if (s - a) % L <= (b - a) % L:
            return True
    return False


# ---------------------------------------------------------------- OSM
def osm_barriers(lap, offline=False, cache_dir=None):
    pts = np.array([lap.proj.to_latlon(x, z) for x, z in lap.P[::50]])
    s, w = pts.min(0) - 0.002
    n, e = pts.max(0) + 0.002
    q = OVERPASS_QUERY.format(s=f"{s:.4f}", w=f"{w:.4f}", n=f"{n:.4f}", e=f"{e:.4f}")
    name = "osm_trackside_%s.json" % hashlib.sha1(q.encode()).hexdigest()[:10]

    def reduce(res):
        keep = []
        for el in res["elements"]:
            g = el.get("geometry") or []
            if not g:
                continue
            x, z = lap.latlon([p["lat"] for p in g], [p["lon"] for p in g])
            _, _, d, _ = lap.locate(x, z)
            if d.min() < 40.0:
                keep.append({"id": el["id"], "tags": el.get("tags", {}),
                             "g": [[round(p["lat"], 7), round(p["lon"], 7)] for p in g]})
        return json.dumps({"attribution": "(c) OpenStreetMap contributors, ODbL", "query": q,
                           "elements": keep}, separators=(",", ":")).encode()
    fetcher = net.Fetcher(cache_dir or os.path.join(TRACK_DIR, "raw"), offline=offline)
    return json.loads(net.fetch_overpass(fetcher, q, name, reduce))["elements"]


def wall_offsets(lap, edges, elements):
    """Per ortho station and side, the lateral offset of the nearest mapped barrier beyond the
    tarmac edge (NaN where none), from ways running parallel to the lap."""
    ES = edges["s"]
    n = len(ES)
    wall = {1: np.full(n, np.nan), -1: np.full(n, np.nan)}
    for el in elements:
        kind = el["tags"].get("barrier")
        if kind not in ("wall", "guard_rail", "jersey_barrier", "fence"):
            continue
        g = np.array(el["g"], float)
        x, z = lap.latlon(g[:, 0], g[:, 1])
        xz = np.column_stack([x, z])
        pts, dirs = [], []
        for a, b in zip(xz[:-1], xz[1:]):
            ln = float(np.linalg.norm(b - a))
            if ln < 1e-6:
                continue
            k = max(1, int(ln))
            for f in np.arange(k) / k:
                pts.append(a + (b - a) * f)
                dirs.append((b - a) / ln)
        if not pts:
            continue
        pts = np.array(pts)
        dirs = np.array(dirs)
        s, lat, _, ti = lap.locate(pts[:, 0], pts[:, 1])
        i = np.clip(np.searchsorted(ES, s), 0, n - 1)
        par = np.abs((dirs * lap.tan[ti]).sum(1)) > 0.9
        for side in (1, -1):
            ed = edges["right"][i] if side > 0 else edges["left"][i]
            m = par & (lat * side > ed + 0.3) & (np.abs(lat) < 35.0)
            if kind == "fence":   # spectator fences stand far back: only one at the road counts
                m &= lat * side < ed + 6.0
            for ii, v in zip(i[m], np.abs(lat[m])):
                if not (wall[side][ii] <= v):
                    wall[side][ii] = v
    return wall


# ---------------------------------------------------------------- kerbs and run-off
def kerb_list(edges_json, L):
    by_side = {}
    for k in edges_json["kerbs"]:
        if float(k["gap"]) < -0.5:
            continue
        kind = "flat" if k["kind"] == "flat" or float(k["width"]) >= 2.5 else "saw"
        by_side.setdefault((k["side"], kind), []).append([float(k["s0"]), float(k["s1"])])
    out = []
    for (side, kind), segs in by_side.items():
        segs.sort()
        merged = [segs[0]]
        for a, b in segs[1:]:
            if a - merged[-1][1] < 6.0:
                merged[-1][1] = max(merged[-1][1], b)
            else:
                merged.append([a, b])
        for a, b in merged:
            if b - a >= 8.0:
                out.append({"side": 1 if side == "right" else -1, "kind": kind, "s0": a, "s1": b})
    out.sort(key=lambda k: k["s0"])
    return out


def kerb_at(kerbs, s, side):
    w = 0.0
    for k in kerbs:
        if k["side"] == side and k["s0"] - 2.0 <= s <= k["s1"] + 2.0:
            w = max(w, KERB_PROFILE_WIDTH[k["kind"]])
    return w


def near_corner(s, turns, L):
    for t in turns:
        if float(t.get("min_radius", 999)) < CORNER_RADIUS and abs(delta_s(float(t["s_apex"]), s, L)) < CORNER_REACH:
            return True
    return False


def runoff_list(edges_json, turns, gaps, ES, L):
    out = []
    for r in edges_json["runoff"]:
        if r["kind"] not in ("tarmac", "gravel") or r.get("capped"):
            continue
        s0, s1 = float(r["s0"]), float(r["s1"])
        u0, u1 = float(r["u0"]), float(r["u1"])
        if (s1 - s0) % L < 15.0 or u1 - u0 < 2.0 or (r["kind"] == "tarmac" and u0 > 6.0):
            continue   # a tarmac surface well beyond the verge is a service road or a car park
        mid = (s0 + 0.5 * ((s1 - s0) % L)) % L
        if in_ranges(mid, PUBLIC, L) and not near_corner(mid, turns, L):
            continue
        side = 1 if r["side"] == "right" else -1
        # Not through the wall: the run-off ends where the mapped barrier stands.
        m = (ES >= s0) & (ES <= s1) if s1 >= s0 else (ES >= s0) | (ES <= s1)
        g = gaps[side][m]
        g = g[np.isfinite(g)]
        if g.size:
            u1 = min(u1, float(np.percentile(g, 25)) - RUNOFF_ALLOWANCE - BEHIND_RUNOFF)
        if u1 - u0 < 2.0:
            continue
        out.append({"side": side, "kind": r["kind"], "s0": s0, "s1": s1, "u0": round(u0, 1),
                    "u1": round(u1, 1)})
    return out


def relative(turns, s0, s1, side, L):
    """[turn id, "in" | "out", from, to] of an absolute stretch, on its nearest corner."""
    span = (s1 - s0) % L
    mid = (s0 + 0.5 * span) % L
    t = min(turns, key=lambda t: abs(delta_s(float(t["s_apex"]), mid, L)))
    sign = 1 if t["direction"] == "right" else -1
    a = delta_s(float(t["s_apex"]), s0, L)
    return [t["id"], "in" if side == sign else "out", round(a, 1), round(a + span, 1)]


# ---------------------------------------------------------------- barrier stretches
def barrier_stretches(gap, ES, L, default_fn, floor_fn):
    """Constant stretches [s0, s1, dist] of the wall distance along one side."""
    from scipy.ndimage import median_filter
    g = gap.copy()
    g[~(g < MAX_GAP)] = np.nan
    fill = np.array([default_fn(s) for s in ES])
    known = np.isfinite(g)
    g = np.where(known, g, fill)
    g = median_filter(g, size=15, mode="wrap")
    g = np.maximum(g, [floor_fn(s) for s in ES])
    out = []
    a = 0
    n = len(ES)
    while a < n:
        b = a + 1
        lo = hi = g[a]
        while b < n:
            lo2, hi2 = min(lo, g[b]), max(hi, g[b])
            if hi2 - lo2 > 2 * STRETCH_TOL and ES[b] - ES[a] >= STRETCH_MIN:
                break
            lo, hi = lo2, hi2
            b += 1
        end = ES[b] if b < n else L
        out.append([float(ES[a]), float(end), float(np.median(g[a:b]))])
        a = b
    # join neighbours that ended up within the tolerance
    joined = [out[0]]
    for s0, s1, d in out[1:]:
        if abs(d - joined[-1][2]) < STRETCH_TOL:
            w0 = joined[-1][1] - joined[-1][0]
            joined[-1][2] = (joined[-1][2] * w0 + d * (s1 - s0)) / (w0 + s1 - s0)
            joined[-1][1] = s1
        else:
            joined.append([s0, s1, d])
    return [[round(a, 1), round(b, 1), round(d * 2) / 2] for a, b, d in joined]


# ---------------------------------------------------------------- writers
def gd_rows(rows, fmt):
    return "\n".join("\t" + fmt(r) + "," for r in rows)


def write_table(kerb_rows, runoff_rows, zones, L):
    def q(v):
        return f'"{v}"' if isinstance(v, str) else (f"{v:.1f}" if isinstance(v, float) else str(v))
    text = f'''extends RefCounted
## Trackside table of the survey Circuit de la Sarthe, loaded by track id by TracksideLayout
## (scripts/track/trackside_layout.gd). Format: see red_bull_ring.gd, plus BARRIER_ZONES.
## GENERATED by tools/track/landmarks/wec_le_mans_survey_trackside.py from ortho_edges.json
## (BD ORTHO 20 cm, IGN, Licence Ouverte 2.0) and OpenStreetMap barriers (ODbL): edit that
## script, not this file. Sources and rules: see its docstring. In short:
##   * kerbs and run-off as traced on the orthophoto (lib.ortho);
##   * the armco of the public roads 1 to 2 m from the white line, where OSM maps it;
##   * concrete walls and catch fences on the Bugatti part (Ford chicanes to Tertre Rouge),
##     armco elsewhere (TrackDressing adds the catch fences behind it, except in the woods).
##
## Kerbs and run-off are RELATIVE to the turn table in track.json (turns[i].s_apex,
## direction): "in" = inside of the corner, "out" = outside; offsets are metres along the lap
## from the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
{gd_rows(kerb_rows, lambda r: "[" + ", ".join(q(v) for v in r) + "]")}
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
const RUNOFF: Array = [
{gd_rows(runoff_rows, lambda r: "[" + ", ".join(q(v) for v in r) + "]")}
]

## The lap length these absolute positions were measured on (BARRIER_ZONES and
## CONCRETE_RANGES are scaled to the built lap).
const LAP_LENGTH: float = {L:.1f}
## Barrier distance from the road edge (m): the closest any stretch gets; BARRIER_ZONES set
## the rest. No extra distance outside the corners: the zones already are the real wall.
const BARRIER_STRAIGHT: float = {MIN_GAP:.1f}
const BARRIER_CORNER_OUTSIDE: float = 0.0
## Space kept between the outer edge of a run-off area and the barrier line.
const BARRIER_BEHIND_RUNOFF: float = {BEHIND_RUNOFF:.1f}
## Ramp (m) between two barrier stretches.
const BARRIER_ZONE_RAMP: float = 8.0
## [from_s, to_s, side (+1 right / -1 left), distance from the road edge m], absolute s.
const BARRIER_ZONES: Array = [
{gd_rows(zones, lambda r: "[%.1f, %.1f, %d, %.1f]" % tuple(r))}
]

## Concrete wall + catch fence: [from_s, to_s] absolute, wrapping through the finish line.
## Armco everywhere else.
const CONCRETE_RANGES: Array = {json.dumps([[a, b] for a, b in CONCRETE])}
'''
    with open(TABLE_OUT, "w", encoding="utf-8") as f:
        f.write(text)


# ---------------------------------------------------------------- main
def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--offline", action="store_true", help="only cached OSM data")
    ap.add_argument("--osm-cache", help="folder of the OSM answer (default: the track's raw/)")
    a = ap.parse_args(argv)
    track = json.load(open(os.path.join(TRACK_DIR, "track.json")))
    plan_scale = json.load(open(os.path.join(TRACK_DIR, "terrain.json"))).get("plan_scale", 1.0)
    ej = json.load(open(os.path.join(TRACK_DIR, "ortho_edges.json")))
    lap = Lap(track, plan_scale)
    L = lap.L
    turns = track["turns"]
    st = ej["stations"]
    edges = {"s": np.array(st["s"]), "left": np.array(st["left"]), "right": np.array(st["right"])}
    ES = edges["s"]

    elements = osm_barriers(lap, a.offline, a.osm_cache)
    wall = wall_offsets(lap, edges, elements)
    gaps = {1: wall[1] - edges["right"], -1: wall[-1] - edges["left"]}

    kerbs = kerb_list(ej, L)
    kerb_rows = [relative(turns, k["s0"], k["s1"], k["side"], L) + [k["kind"]] for k in kerbs]
    runoff = runoff_list(ej, turns, gaps, ES, L)
    runoff_rows = [relative(turns, r["s0"], r["s1"], r["side"], L) + [r["kind"], r["u0"], r["u1"]]
                   for r in runoff]

    zones = []
    for side in (-1, 1):
        def default(s):
            return DEFAULT_PUBLIC if in_ranges(s, PUBLIC, L) else DEFAULT_CIRCUIT

        def floor(s, side=side):
            room = MIN_GAP + kerb_at(kerbs, s, side)
            for t in turns:
                if float(t.get("min_radius", 999.0)) < CORNER_ROOM_RADIUS and \
                        side == (-1 if t["direction"] == "right" else 1) and \
                        -CORNER_ROOM_BEFORE <= delta_s(float(t["s_apex"]), s, L) <= CORNER_ROOM_AFTER:
                    room = max(room, CORNER_ROOM)
            return room
        for s0, s1, d in barrier_stretches(gaps[side], ES, L, default, floor):
            if d > MIN_GAP + 0.2:
                zones.append([s0, s1, side, d])
    zones.sort()
    write_table(kerb_rows, runoff_rows, zones, L)
    print(f"{TABLE_OUT}: {len(kerb_rows)} kerbs, {len(runoff_rows)} run-off areas, "
          f"{len(zones)} barrier stretches")


if __name__ == "__main__":
    main()
