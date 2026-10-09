#!/usr/bin/env python3
"""Road surface of a track: code-CAD from track.json -> chunked GLB + profile.

    .venv/bin/python cad/track/road.py [track_id] [--out DIR]

Normally run as the "road" step of tools/track/build_track.py. Widths and banking come from
cad/track/banking.py: automatic defaults, or the tables / overrides of the track's recipe
(tools/track/tracks/<id>.toml, section [road]).

Outputs (assets/tracks/<id>/, or DIR):
    road_mesh.glb          chunks road_00..road_NN, each with two primitives:
                           "tarmac" (the racing surface) and "grass" (the verges)
    road_profile.json      per-centreline-point width, bank, verge extents and racing line,
                           read by scripts/track/road.gd (surface queries, tests)
    road_*_albedo.png      seamless textures (cad/track/road_textures.py)

Geometry
--------
A parametric mesh builder rather than an OCC sweep: a 4.3 km sweep with varying width and
roll is slow and fragile in OpenCascade, and the result would be re-tessellated anyway.
The road is a ruled surface defined exactly by its cross-sections, so we build those
cross-sections directly at every track.json point (about 2 m apart), the same frame
TrackData.sample() uses:

    T  = normalize(p[i+1] - p[i-1])                 forward
    Rh = normalize(T x up)                           right, horizontal
    U0 = Rh x T                                      unbanked road normal
    R  = Rh cos(bank) - U0 sin(bank)                 banked right (+bank: left edge higher)
    road vertex(l) = p[i] + R * l,  l in {-w/2, 0, +w/2}

Verge (grass) each side: continues from the road edge E horizontally outward along Rh
for up to VERGE_WIDTH metres, dropping linearly by VERGE_DROP (0.25 m over 30 m, so it
always stays above the terrain unit's ground, which sits at centre - 0.3 m - 1 cm/m).
The verge is clipped where it would reach closer to another part of the track than to
its own centreline (inside of hairpins, parallel sections), so it never folds or
overlaps. Road edge and verge share exact edge positions, so there is no step.

Chunks: ~180 m each; consecutive chunks share their boundary cross-section bit-for-bit
(same float arrays), and normals are computed on the whole closed lap before splitting,
so shading and collision are seamless across chunk boundaries.

UVs: UV0 = (s, lateral metres, + right), UV1 = (racing-line lateral offset, half width).
The tarmac shader uses world-space XZ for texture tiling and UV0/UV1 for painted lines.

Crossovers
----------
Where the lap crosses itself (track.json "crossings", a figure of eight) the upper road is
carried over the lower one on a bridge, see cad/track/bridge.py: both roads lose their
verges where the other one is in the way, and the upper road gets a concrete deck with side
walls and an underpass for the lower road (extra node "bridge_NN", material "concrete").
The stretches are written to road_profile.json ("bridges") for the trackside, which puts
the parapets on the deck. A lap that does not cross itself builds exactly as before.

Retaining walls
---------------
On a hillside circuit two stretches of the lap run side by side at different heights (the
terraces of Monaco: Beau Rivage 30 m above the harbour front, the legs of the hairpin). The
verges of both end half way between them, and the terrain there is kept under the lower one
(tools/track/lib/terrain.py: the lowest road wins, up to a mesh cell beyond its verge), so
the outer edge of the upper verge hangs in the air. With ``[road] retaining_walls = true`` in
the recipe a concrete wall goes down from the outer edge of every verge that has a lower
stretch of the lap within WALL_REACH, to WALL_FOOT below that stretch (extra nodes
"wall_NN", material "concrete"). Off by default: every other track builds as before.

Side-by-side roads
------------------
Two stretches of the lap that are the two carriageways of one road (``[[road.pair]]`` in the
recipe: Baku's Turn 6 to Turn 7 road beside the main straight) are checked to leave room for
a wall between their tarmac edges, so the two ribbons cannot overlap, and their verges meet
half way between them instead of each stopping short of the other (pair_spans, pair_verges).
The pairs are written to road_profile.json ("pairs") for the trackside, which builds one
wall on that line instead of one per road. No pair: nothing changes.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import banking  # noqa: E402
import bridge as bridge_mod  # noqa: E402
import road_textures  # noqa: E402
from road_glb import Material, Primitive, write_glb  # noqa: E402

ROOT = HERE.parent.parent
TRACKS_DIR = ROOT / "assets" / "tracks"
TRACK_DIR = TRACKS_DIR / "red_bull_ring"

VERGE_WIDTH = 30.0       # m, nominal grass strip each side
VERGE_DROP = 0.25        # m, total drop over VERGE_WIDTH (coordinated with the terrain unit)
VERGE_ROWS = (0.0, 0.08, 0.3, 1.0)   # fractions of the verge extent
CHUNK_POINTS = 90        # centreline points per chunk (~180 m)
WALL_REACH = 52.0        # m in plan view: a lower road this near takes the ground under a
                         # verge edge (half road + verge + a terrain mesh cell, see terrain.py)
WALL_FOOT = 2.0          # m: the wall ends this far below the lowest road within reach
WALL_MIN = 0.5           # m: no wall where the other road is less than this far below
WALL_ABEAM = 16.0        # m along the other road: it only takes the ground beside itself (a
                         # terrain mesh cell + terrain.py's COVER_SLACK), not ahead or behind
WALL_OWN = 10            # centreline points either way that are the verge's own road
PAIR_GAP = 1.5           # m between the tarmac edges of a [[road.pair]]: the room of one wall
                         # (the default of the recipe key, tools/track/lib/recipe.py PAIR_GAP)
UP = np.array([0.0, 1.0, 0.0])


def _norm(v: np.ndarray) -> np.ndarray:
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


_cyclic_smooth = banking.cyclic_smooth


def _cyclic_min_filter(a: np.ndarray, r: int) -> np.ndarray:
    return np.min(np.stack([np.roll(a, k) for k in range(-r, r + 1)]), axis=0)


def _cyclic_box(a: np.ndarray, r: int) -> np.ndarray:
    return np.mean(np.stack([np.roll(a, k) for k in range(-r, r + 1)]), axis=0)


def verge_extent(P: np.ndarray, edge: np.ndarray, out_dir: np.ndarray, hw: np.ndarray,
                 side: float, step: float) -> np.ndarray:
    """Largest verge width (<= VERGE_WIDTH) at each point such that every verge point stays
    nearer (in plan view) to its own centreline point than to any other part of the track,
    and the offset curve cannot fold on the inside of a bend (offset < 0.75 * local radius).
    ``side`` is -1 for the left verge, +1 for the right one."""
    n = len(P)
    t = _norm(np.roll(P, -1, 0) - P)
    k_right = -np.cross(np.roll(t, 1, 0), t)[:, 1] / step     # signed plan curvature, + = right
    inner = np.maximum(side * k_right, 1e-6)
    fold_limit = _cyclic_min_filter(0.75 / inner - hw, 3)
    ds = np.arange(0.0, VERGE_WIDTH + 1e-6, 1.0)
    cxz = P[:, [0, 2]]
    ext = np.full(n, VERGE_WIDTH)
    for i0 in range(0, n, 128):
        sl = slice(i0, min(i0 + 128, n))
        q = edge[sl, None, :][..., [0, 2]] + out_dir[sl, None, :][..., [0, 2]] * ds[None, :, None]
        d2 = ((q[:, :, None, :] - cxz[None, None, :, :]) ** 2).sum(-1)   # (b, nd, n)
        nearest = np.sqrt(d2.min(-1))
        own = hw[sl, None] + ds[None, :]
        ok = nearest >= own - (0.6 + 0.03 * own)
        bad = ~ok
        first_bad = np.where(bad.any(1), bad.argmax(1), len(ds))
        ext[sl] = np.where(first_bad >= len(ds), VERGE_WIDTH, np.maximum(ds[np.maximum(first_bad - 1, 0)] - 1.0, 0.0))
    ext = np.minimum(ext, fold_limit)
    ext = _cyclic_box(_cyclic_min_filter(ext, 5), 5)
    return np.clip(ext, 0.0, VERGE_WIDTH)


def _stretch_points(r: list, step: float, n: int) -> np.ndarray:
    """Centreline point indices of the s range ``r`` = [from, to] (may wrap)."""
    first = int(round(float(r[0]) / step)) % n
    count = int(round(((float(r[1]) - float(r[0])) % (n * step)) / step)) + 1
    return (first + np.arange(min(count, n))) % n


def pair_spans(pairs: list, P: np.ndarray, Rh: np.ndarray, hw: np.ndarray, step: float) -> list[dict]:
    """The recipe's [[road.pair]] entries measured on the built centreline. Each entry names
    two stretches of the lap that are the two halves of one road (the carriageways of an
    avenue); they must lie side by side with room for a wall between the tarmac edges
    (``gap``, default PAIR_GAP), which is checked here, so the two ribbons can never overlap.

    Returns per pair {"a", "b": the s ranges (cut back to where the other one is beside), "side_a", "side_b": the side of each stretch the
    other one is on (-1 left, +1 right), "gap": [min, max] between the tarmac edges,
    "separation": [min, max] between the centrelines, "legs": per stretch (points, half gap)}.
    Raises ValueError when the stretches are too close for their widths."""
    n = len(P)
    xz = P[:, [0, 2]]
    out = []
    for p in pairs:
        need = float(p.get("gap", PAIR_GAP))
        idx = [_stretch_points(p["a"], step, n), _stretch_points(p["b"], step, n)]
        entry = {"a": [float(v) for v in p["a"]], "b": [float(v) for v in p["b"]], "legs": []}
        gaps, seps = [], []
        for own, other, name in ((idx[0], idx[1], "a"), (idx[1], idx[0], "b")):
            dist = np.linalg.norm(xz[own][:, None, :] - xz[other][None, :, :], axis=-1)
            j = dist.argmin(1)
            near = other[j]
            sep = dist[np.arange(len(own)), j]
            # Beside the other stretch, not beyond one of its ends.
            abeam = (j > 0) & (j < len(other) - 1)
            if not abeam.any():
                raise ValueError(f"[[road.pair]] a = {p['a']}, b = {p['b']}: the two stretches do not "
                                 "run beside each other anywhere")
            gap = sep - hw[own] - hw[near]
            side = np.sign(((xz[near] - xz[own]) * Rh[own][:, [0, 2]]).sum(-1))
            if np.any(side[abeam] != side[abeam][0]):
                raise ValueError(f"[[road.pair]] a = {p['a']}, b = {p['b']}: stretch {name} has the "
                                 "other one on its left in places and on its right in others")
            worst = int(np.argmin(np.where(abeam, gap, np.inf)))
            if gap[worst] < need - 1e-6:
                raise ValueError(
                    f"[[road.pair]] a = {p['a']}, b = {p['b']}: at s = {own[worst] * step:.0f} m the "
                    f"centrelines are {sep[worst]:.1f} m apart and the roads {2 * hw[own[worst]]:.1f} m "
                    f"and {2 * hw[near[worst]]:.1f} m wide, which leaves {gap[worst]:.1f} m between "
                    f"the tarmac edges; a wall needs {need:g} m. The centrelines must be "
                    f"{hw[own[worst]] + hw[near[worst]] + need:.1f} m apart there: raise the pair's "
                    "separation, end the stretches where the roads part, or narrow the roads there")
            entry["side_" + name] = int(side[abeam][0])
            # What the trackside is told: the part of the stretch that has the other one beside
            # it. A point beyond the other stretch's end is an ordinary point of the lap.
            k = np.flatnonzero(abeam)
            entry[name] = [round(float(own[k[0]] * step), 3), round(float(own[k[-1]] * step), 3)]
            entry["legs"].append((own, abeam, 0.5 * gap))
            gaps.append(gap[abeam])
            seps.append(sep[abeam])
        gaps, seps = np.concatenate(gaps), np.concatenate(seps)
        entry["gap"] = [round(float(gaps.min()), 2), round(float(gaps.max()), 2)]
        entry["separation"] = [round(float(seps.min()), 2), round(float(seps.max()), 2)]
        out.append(entry)
    return out


def pair_verges(spans: list[dict], ext_l: np.ndarray, ext_r: np.ndarray) -> None:
    """Between the two roads of a pair both verges end on the line half way between the tarmac
    edges (in place): one continuous median, with the pair's wall standing on the seam. The
    general clipping of verge_extent() leaves a strip of nothing there, as it must between
    two unrelated stretches of the lap."""
    for sp in spans:
        for (own, abeam, half), side in zip(sp["legs"], (sp["side_a"], sp["side_b"])):
            ext = ext_l if side < 0 else ext_r
            ext[own] = np.where(abeam, np.clip(half, 0.0, VERGE_WIDTH), ext[own])


def _ear_clip(poly: np.ndarray) -> list[tuple[int, int, int]]:
    """Triangulate a simple polygon given in plan view (x, z), any orientation. Returns
    triangles wound counter-clockwise seen from above (+y), i.e. facing up in glTF."""
    def area2(a, b, c):  # > 0: counter-clockwise seen from +y (x right, z towards viewer)
        return (b[0] - a[0]) * (a[1] - c[1]) - (a[1] - b[1]) * (c[0] - a[0])

    idx = list(range(len(poly)))
    signed = sum(area2(poly[0], poly[i], poly[i + 1]) for i in range(1, len(poly) - 1))
    if signed < 0:
        idx.reverse()
    tris = []
    guard = 0
    while len(idx) > 3 and guard < 10000:
        guard += 1
        m = len(idx)
        for k in range(m):
            i0, i1, i2 = idx[(k - 1) % m], idx[k], idx[(k + 1) % m]
            a, b, c = poly[i0], poly[i1], poly[i2]
            if area2(a, b, c) <= 1e-9:
                continue
            inside = False
            for j in idx:
                if j in (i0, i1, i2):
                    continue
                p = poly[j]
                if area2(a, b, p) >= 0 and area2(b, c, p) >= 0 and area2(c, a, p) >= 0:
                    inside = True
                    break
            if not inside:
                tris.append((i0, i1, i2))
                del idx[k]
                break
        else:
            break  # degenerate remainder: stop
    if len(idx) == 3:
        tris.append(tuple(idx))
    return tris


def corner_infills(P: np.ndarray, s: np.ndarray, outer: np.ndarray, ext: np.ndarray,
                   hw: np.ndarray, rl: np.ndarray, side: float) -> list[dict]:
    """Grass patches for the pockets left on the inside of tight corners, where the verge
    had to be clipped short: the polygon between the clipped verge's outer edge and the
    chord joining the points where the verge is full width again. Built from the exact
    outer-edge vertices, so it joins the verge without gaps."""
    n = len(P)
    short = ext < VERGE_WIDTH - 0.05
    if not short.any() or short.all():
        return []
    start = int(np.argmin(short))          # a full-width point: walk runs from here
    fills = []
    i = 0
    while i < n:
        j = (start + i) % n
        if not short[j]:
            i += 1
            continue
        k = i
        while k < n and short[(start + k) % n]:
            k += 1
        run = [(start + q) % n for q in range(i - 1, k + 1)]   # include full-width ends
        i = k
        if len(run) < 4:
            continue
        poly3 = outer[run]
        poly = poly3[:, [0, 2]]
        # Never cover another part of the track: every centreline point that is not part
        # of this corner must stay well outside the patch.
        cen = poly.mean(0)
        rad = np.max(np.linalg.norm(poly - cen, axis=1))
        far = np.ones(n, bool)
        far[np.array(run)] = False
        lo, hi = run[0], run[-1]
        span = [(lo - 20 + q) % n for q in range((hi - lo) % n + 41)]
        far[np.array(span)] = False
        if np.any(np.linalg.norm(P[far][:, [0, 2]] - cen, axis=1) < rad + 10.0):
            continue
        tris = _ear_clip(poly)
        if not tris:
            continue
        tri = np.array(tris, dtype=np.uint32)
        fn = np.cross(poly3[tri[:, 1]] - poly3[tri[:, 0]], poly3[tri[:, 2]] - poly3[tri[:, 0]])
        # Chicane pockets can be non-simple polygons, where ear clipping winds a few triangles
        # the other way: flip those so every triangle faces up, and drop zero-area ones.
        down = fn[:, 1] < 0.0
        tri[down] = tri[down][:, [0, 2, 1]]
        tri = tri[np.abs(fn[:, 1]) > 1e-9]
        if len(tri) == 0:
            continue
        acc = np.zeros_like(poly3)
        for c in range(3):
            np.add.at(acc, tri[:, c], fn)
        # Vertices the ear clipping left out (collinear / degenerate): straight up, not NaN.
        acc[np.linalg.norm(acc, axis=-1) < 1e-9] = UP
        fills.append({
            "anchor": run[len(run) // 2],
            "positions": poly3,
            "normals": _norm(acc),
            "uv0": np.stack([s[run], side * (hw[run] + ext[run])], 1),
            "uv1": np.stack([rl[run], hw[run]], 1),
            "indices": tri,
        })
    return fills


def wall_feet(P: np.ndarray, outer: np.ndarray) -> np.ndarray:
    """Height of the lowest other stretch of the lap that takes the ground under each point of
    the verge's outer edge ``outer`` (one per centreline point): a centreline point within
    WALL_REACH in plan view that has the edge point beside it (within WALL_ABEAM along its
    own direction) and is not the verge's own road just ahead or behind, which a gradient
    alone would make "lower". The edge's own height where there is none."""
    n = len(P)
    cxz, cy = P[:, [0, 2]], P[:, 1]
    t = np.roll(cxz, -1, 0) - np.roll(cxz, 1, 0)
    t = t / np.linalg.norm(t, axis=1, keepdims=True)
    idx = np.arange(n)
    low = np.empty(len(outer))
    for i0 in range(0, len(outer), 256):
        q = outer[i0:i0 + 256][:, [0, 2]]
        d = q[:, None, :] - cxz[None, :, :]
        gap = np.abs(idx[None, :] - np.arange(i0, i0 + len(q))[:, None])
        other = np.minimum(gap, n - gap) > WALL_OWN
        takes = ((d ** 2).sum(-1) <= WALL_REACH ** 2) & (np.abs((d * t[None, :, :]).sum(-1)) <= WALL_ABEAM) & other
        low[i0:i0 + 256] = np.where(takes, cy[None, :], np.inf).min(1)
    return np.minimum(low, outer[:, 1])


def wall_primitive(outer: np.ndarray, low: np.ndarray, out_dir: np.ndarray, s: np.ndarray,
                   a: int, b: int) -> Primitive | None:
    """Retaining wall under the verge edge ``outer`` for cross-sections a..b (b may equal n),
    flat-shaded quads facing ``out_dir``; None when no part of it needs one."""
    n = len(outer)
    pos, nrm, uv0, uv1, tris = [], [], [], [], []
    for k in range(a, b):
        i, j = k % n, (k + 1) % n
        if max(outer[i, 1] - low[i], outer[j, 1] - low[j]) < WALL_MIN:
            continue
        ta, tb = outer[i], outer[j]
        fa = np.array([ta[0], min(low[i], ta[1]) - WALL_FOOT, ta[2]])
        fb = np.array([tb[0], min(low[j], tb[1]) - WALL_FOOT, tb[2]])
        quad = [ta, tb, fb, fa]
        nv = np.cross(tb - ta, fb - ta)
        if np.linalg.norm(nv) < 1e-9:
            continue                      # zero-length segment (a verge clipped to a point)
        if np.dot(nv, out_dir[i]) < 0.0:
            quad, nv = quad[::-1], -nv
        base = len(pos)
        for q in quad:
            pos.append(q)
            nrm.append(nv / np.linalg.norm(nv))
            uv0.append((s[i] if q is ta or q is fa else s[i] + (s[1] - s[0]), q[1]))
            uv1.append((0.0, 6.5))
        tris.extend([(base, base + 1, base + 2), (base, base + 2, base + 3)])
    if not tris:
        return None
    return Primitive("concrete", np.array(pos), np.array(nrm), np.array(uv0), np.array(uv1),
                     np.array(tris, dtype=np.uint32))


def racing_line(P: np.ndarray, step: float, hw: np.ndarray) -> np.ndarray:
    """Cheap racing-line estimate (lateral offset, + right): inside at apexes, outside on
    entry/exit, from band-passed signed curvature. Only used for the rubbered-in look."""
    n = len(P)
    t = _norm(np.roll(P, -1, 0) - np.roll(P, 1, 0))
    k_right = -np.cross(t, np.roll(t, -1, 0))[:, 1] / step
    sig1 = 12.0 / step
    sig2 = 45.0 / step
    band = _cyclic_smooth(k_right, sig1) - 0.85 * _cyclic_smooth(k_right, sig2)
    off = (hw - 1.6) * np.tanh(band * 120.0)
    return _cyclic_smooth(off, 6.0 / step)


def build(track_path: Path = TRACK_DIR / "track.json", out_dir: Path = TRACK_DIR,
          road_cfg: dict | None = None, track_id: str | None = None) -> dict:
    """Builds the road of ``track_path`` into ``out_dir``. ``road_cfg`` is the recipe's [road]
    table (None / {}: automatic widths and banking); ``track_id`` names the glTF scene."""
    track_path, out_dir = Path(track_path), Path(out_dir)
    track_id = track_id or track_path.parent.name
    d = json.loads(track_path.read_text(encoding="utf-8"))
    P = np.array([p["p"] for p in d["points"]], dtype=float)
    n = len(P)
    step = float(d["step"])
    length = float(d["length"])
    s = np.arange(n) * step

    T = _norm(np.roll(P, -1, 0) - np.roll(P, 1, 0))
    Rh = _norm(np.cross(T, UP))
    U0 = _norm(np.cross(Rh, T))
    curvature = np.array([p.get("curvature", 0.0) for p in d["points"]], dtype=float)
    bank, width = banking.profile(s, length, curvature, float(d.get("start_s", 0.0)), road_cfg or {})
    hw = 0.5 * width
    R = Rh * np.cos(bank)[:, None] - U0 * np.sin(bank)[:, None]

    left_edge = P - R * hw[:, None]
    right_edge = P + R * hw[:, None]
    ext_l = verge_extent(P, left_edge, -Rh, hw, -1.0, step)
    ext_r = verge_extent(P, right_edge, Rh, hw, 1.0, step)
    pairs = pair_spans((road_cfg or {}).get("pair", []), P, Rh, hw, step)
    pair_verges(pairs, ext_l, ext_r)
    bridges = (bridge_mod.bridge_spans(d["crossings"], P, Rh, hw, ext_l, ext_r, step, VERGE_WIDTH)
               if d.get("crossings") else [])
    rl = racing_line(P, step, hw)

    # ---- full-lap vertex grids: (n, rows, 3), rows ordered left -> right ----
    road_lat = np.stack([-hw, np.zeros(n), hw], 1)
    road_v = P[:, None, :] + R[:, None, :] * road_lat[:, :, None]

    def verge(edge: np.ndarray, out: np.ndarray, ext: np.ndarray, side: float):
        f = np.array(VERGE_ROWS)
        dd = ext[:, None] * f[None, :]                       # (n, rows) outward distance
        v = edge[:, None, :] + out[:, None, :] * dd[:, :, None]
        v[:, :, 1] -= VERGE_DROP * dd / VERGE_WIDTH
        lat = side * (hw[:, None] + dd)
        if side < 0:                                         # reorder left -> right
            v, lat = v[:, ::-1], lat[:, ::-1]
        return v, lat

    vl, lat_l = verge(left_edge, -Rh, ext_l, -1.0)
    vr, lat_r = verge(right_edge, Rh, ext_r, 1.0)

    def grid_normals(v: np.ndarray) -> np.ndarray:
        """Area-weighted vertex normals of a closed-loop (cyclic in axis 0) grid."""
        a = v
        b = np.roll(v, -1, 0)
        e_lat = a[:, 1:] - a[:, :-1]
        e_fwd = b[:, :-1] - a[:, :-1]
        fn1 = np.cross(e_lat, e_fwd)                          # tri (A,B,C)
        fn2 = np.cross(b[:, 1:] - a[:, 1:], b[:, :-1] - a[:, 1:])   # tri (B,D,C)
        quad = fn1 + fn2
        tmp = np.zeros_like(v)
        tmp[:, :-1] += quad
        tmp[:, 1:] += quad
        acc = tmp + np.roll(tmp, 1, 0)          # quads before and after each cross-section
        # Zero-extent verge rows collapse to one point: fall back to straight up.
        acc[np.linalg.norm(acc, axis=-1) < 1e-9] = UP
        nrm = _norm(acc)
        bad = np.argwhere((fn1[..., 1] < -1e-9) | (fn2[..., 1] < -1e-9))
        assert len(bad) == 0, f"folded triangles at (point, row): {bad[:20].tolist()} of {len(bad)}"
        return nrm

    road_n = grid_normals(road_v)
    verge_n = [grid_normals(vl), grid_normals(vr)]

    def strip(v, nrm, lat, a, b) -> Primitive:
        """Primitive for cross-sections a..b inclusive (b may equal n: wraps to 0, s=length)."""
        idx = np.arange(a, b + 1) % n
        sv = np.arange(a, b + 1) * step
        rows = v.shape[1]
        pos = v[idx].reshape(-1, 3)
        nn = nrm[idx].reshape(-1, 3)
        uv0 = np.stack([np.repeat(sv, rows), lat[idx].reshape(-1)], 1)
        uv1 = np.stack([np.repeat(rl[idx], rows), np.repeat(hw[idx], rows)], 1)
        tris = []
        for i in range(b - a):
            for r in range(rows - 1):
                A = i * rows + r
                B = A + 1
                C = A + rows
                D = C + 1
                tris.append((A, B, C))
                tris.append((B, D, C))
        return Primitive("", pos, nn, uv0, uv1, np.array(tris, dtype=np.uint32))

    infills = []
    for side, v, ext in ((-1.0, vl, ext_l), (1.0, vr, ext_r)):
        outer = v[:, 0] if side < 0 else v[:, -1]
        infills += corner_infills(P, s, outer, ext, hw, rl, side)

    nchunks = int(np.ceil(n / CHUNK_POINTS))
    bounds = np.linspace(0, n, nchunks + 1).round().astype(int)
    chunks = []
    tri_total = 0
    for c in range(nchunks):
        a, b = bounds[c], bounds[c + 1]
        tar = strip(road_v, road_n, road_lat, a, b)
        tar.material = "tarmac"
        gl = strip(vl, verge_n[0], lat_l, a, b)
        gr = strip(vr, verge_n[1], lat_r, a, b)
        off = len(gl.positions)
        grass = Primitive("grass",
                          np.concatenate([gl.positions, gr.positions]),
                          np.concatenate([gl.normals, gr.normals]),
                          np.concatenate([gl.uv0, gr.uv0]),
                          np.concatenate([gl.uv1, gr.uv1]),
                          np.concatenate([gl.indices, gr.indices + off]))
        for fill in infills:
            if a <= fill["anchor"] < b:
                off = len(grass.positions)
                grass = Primitive("grass",
                                  np.concatenate([grass.positions, fill["positions"]]),
                                  np.concatenate([grass.normals, fill["normals"]]),
                                  np.concatenate([grass.uv0, fill["uv0"]]),
                                  np.concatenate([grass.uv1, fill["uv1"]]),
                                  np.concatenate([grass.indices, fill["indices"] + off]))
        tri_total += len(tar.indices) + len(grass.indices)
        chunks.append((f"road_{c:02d}", [tar, grass]))

    mats = [Material("tarmac", (0.20, 0.20, 0.21, 1.0), 0.85),
            Material("grass", (0.22, 0.38, 0.14, 1.0), 0.95)]
    walls = (road_cfg or {}).get("retaining_walls", False) is True
    if bridges or walls:
        mats.append(Material("concrete", (0.62, 0.61, 0.58, 1.0), 0.9))
    wall_len = 0.0
    if walls:
        sides = [(vl[:, 0], -Rh), (vr[:, -1], Rh)]
        feet = [wall_feet(P, outer) for outer, _ in sides]
        for c in range(nchunks):
            parts = [w for (outer, out), low in zip(sides, feet)
                     if (w := wall_primitive(outer, low, out, s, bounds[c], bounds[c + 1])) is not None]
            if parts:
                tri_total += sum(len(w.indices) for w in parts)
                wall_len += sum(len(w.indices) for w in parts) / 2 * step
                chunks.append((f"wall_{c:02d}", parts))
    for k, bridge in enumerate(bridges):
        deck = bridge_mod.deck_primitive(bridge, P, T, R, Rh, hw, step)
        tri_total += len(deck.indices)
        chunks.append((f"bridge_{k:02d}", [deck]))
    scene_name = "".join(w.capitalize() for w in track_id.split("_")) + "Road"
    write_glb(out_dir / "road_mesh.glb", mats, chunks, scene_name,
              "fun/cad/track/road.py (parametric code-CAD)")

    profile = {
        "source": "cad/track/road.py + cad/track/banking.py",
        "convention": "bank radians, + = left edge higher; lateral + = right; verge drops "
                      "linearly from the road edge, horizontally outward",
        "length": length,
        "step": step,
        "verge_width": VERGE_WIDTH,
        "verge_drop": VERGE_DROP,
        "chunks": [[int(bounds[c]), int(bounds[c + 1])] for c in range(nchunks)],
        "width": np.round(width, 4).tolist(),
        "bank": np.round(bank, 6).tolist(),
        "verge_left": np.round(ext_l, 3).tolist(),
        "verge_right": np.round(ext_r, 3).tolist(),
        "racing_line": np.round(rl, 3).tolist(),
    }
    if bridges:
        profile["bridges"] = bridges
    pairs = [{k: v for k, v in sp.items() if k != "legs"} for sp in pairs]
    if pairs:
        # Only laps with a [[road.pair]] have the key, so every other profile is unchanged.
        profile["pairs"] = pairs
    (out_dir / "road_profile.json").write_text(json.dumps(profile, separators=(",", ":")))
    road_textures.write_all(out_dir)
    return {"chunks": nchunks, "triangles": tri_total, "bridges": bridges, "pairs": pairs,
            "wall_length": wall_len,
            "verge_min": float(min(ext_l.min(), ext_r.min())),
            "width": (float(width.min()), float(width.max())),
            "bank": (float(bank.min()), float(bank.max()))}


def main(argv: list[str]) -> None:
    """Stand-alone use: rebuilds the road of an existing track folder with its recipe."""
    import argparse
    ap = argparse.ArgumentParser(description="Rebuild the road mesh of a track folder.")
    ap.add_argument("track_id", nargs="?", default="red_bull_ring")
    ap.add_argument("--out", help="folder with track.json, also the output (default assets/tracks/<id>)")
    args = ap.parse_args(argv)
    track_id = args.track_id
    out_dir = Path(args.out) if args.out else TRACKS_DIR / track_id
    track_path = out_dir / "track.json"
    if not track_path.exists():
        track_path = TRACKS_DIR / track_id / "track.json"
    # Only the [road] table matters here, so read it directly: the rest of the recipe (OSM
    # source, lengths) may legitimately come from the build command line.
    import tomllib
    recipe_path = ROOT / "tools" / "track" / "tracks" / f"{track_id}.toml"
    road_cfg = tomllib.loads(recipe_path.read_text(encoding="utf-8")).get("road", {}) if recipe_path.exists() else {}
    if not road_cfg:
        print(f"note: no [road] table in {recipe_path.name}: automatic widths and banking")
    info = build(track_path, out_dir, road_cfg, track_id)
    print(f"road_mesh.glb: {info['chunks']} chunks, {info['triangles']} triangles; "
          f"width {info['width'][0]:.1f}-{info['width'][1]:.1f} m, bank "
          f"{info['bank'][0]:+.3f}..{info['bank'][1]:+.3f} rad, min verge {info['verge_min']:.1f} m")


if __name__ == "__main__":
    main(sys.argv[1:])
