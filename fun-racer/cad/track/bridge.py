"""Crossovers: the bridge that carries the upper road where a lap crosses itself.

Used by cad/track/road.py for every entry of track.json "crossings" (written by the
centreline step for a figure-of-eight lap such as Suzuka). Nothing here runs for a lap that
does not cross itself.

What the rest of the pipeline does at a crossing, and why a bridge is more than a slab:

  * The terrain step keeps the ground under the LOWER road. Every mesh vertex within the
    lower road's half width + verge + CELL_REACH is pressed under it, and the cells around
    that zone slope up to the ground of the upper road, one more CELL_REACH out. Seen from
    the upper road this "low zone" is open air. With a 10 m terrain mesh it is 70 m wide or
    more, far wider than a real underpass.
  * So the upper road is carried by a deck over the whole low zone (the "span", plus
    DECK_APPROACH of slab on solid ground at both ends), and the deck's sides are closed
    down to the ground by walls: it looks like an embankment between retaining walls.
  * The lower road passes through an opening in those walls, UNDERPASS_MARGIN wider than
    its tarmac on both sides, between two walls that close the hollow under the deck.

Verges: the upper road has none on the deck and ends its verges before the low zone; the
lower road ends its verges before the deck's footprint. Both are tapered with the same
closing filter as cad/track/road.py verge_extent().

The stretches are written to road_profile.json ("bridges") for the trackside
(scripts/track/trackside.gd), which stands the parapets on the deck and keeps the lower
road's barriers inside the underpass.
"""

from __future__ import annotations

import numpy as np

from road_glb import Primitive

CROSS_WINDOW = 140.0     # m either side of a crossing in which the two roads are a pair
CELL_REACH = 14.2        # m, tools/track/lib/terrain.py CELL_REACH: a terrain mesh cell diagonal
DECK_SHOULDER = 2.8      # m of deck beyond each road edge: room for a kerb and the parapet
DECK_THICKNESS = 1.2     # m
DECK_APPROACH = 12.0     # m the slab continues onto solid ground at both ends
PARAPET_OFFSET = 2.0     # m from the road edge to the parapet line
UNDERPASS_MARGIN = 2.0   # m from the lower road's edge to the walls of the underpass
BARRIER_ROOM = 1.0       # m from the lower road's verge (or edge) to its barrier line
WALL_FOOT = 1.5          # m the walls reach below the lower road
UP = np.array([0.0, 1.0, 0.0])


def _min_filter(a: np.ndarray, r: int) -> np.ndarray:
    return np.min(np.stack([np.roll(a, k) for k in range(-r, r + 1)]), axis=0)


def _box(a: np.ndarray, r: int) -> np.ndarray:
    return np.mean(np.stack([np.roll(a, k) for k in range(-r, r + 1)]), axis=0)


def _covered(q: np.ndarray, xz: np.ndarray, fwd: np.ndarray, right: np.ndarray,
             reach_l: np.ndarray, reach_r: np.ndarray, slack: float) -> np.ndarray:
    """True for plan points ``q`` (m, 2) that lie beside one of the cross-sections (xz, fwd,
    right), no further out than its reach on that side."""
    d = q[:, None, :] - xz[None, :, :]
    along = (d * fwd[None]).sum(-1)
    lat = (d * right[None]).sum(-1)
    reach = np.where(lat > 0.0, reach_r[None, :], reach_l[None, :])
    return ((np.abs(along) <= slack) & (np.abs(lat) <= reach)).any(1)


def _lateral(q: np.ndarray, xz: np.ndarray, right: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Signed lateral offset of plan points ``q`` in the frame of their nearest cross-section,
    and that cross-section's index."""
    d = q[:, None, :] - xz[None, :, :]
    j = (d ** 2).sum(-1).argmin(1)
    return (d[np.arange(len(q)), j] * right[j]).sum(-1), j


def bridge_spans(crossings: list, P: np.ndarray, Rh: np.ndarray, hw: np.ndarray,
                 ext_l: np.ndarray, ext_r: np.ndarray, step: float, verge_width: float) -> list[dict]:
    """One bridge per crossing; clips the verge widths ``ext_l`` / ``ext_r`` in place (see the
    module docstring). Returns, per crossing (s in metres along the lap):

        {s_upper, s_lower, clearance,
         span: [s0, s1]            upper road above open ground,
         deck: [s0, s1]            upper road on the slab (span + approaches),
         upper_window, lower_window: [s0, s1]   where the two roads are treated as a pair,
         shoulder, thickness, parapet_offset, underpass_margin, barrier_room,
         deck_points: [first centreline index, count]}
    """
    n = len(P)
    half = int(round(CROSS_WINDOW / step))
    pad = int(round(DECK_APPROACH / step))
    slack = step + 0.5
    xz = P[:, [0, 2]]
    right = Rh[:, [0, 2]]
    fwd = np.stack([Rh[:, 2], -Rh[:, 0]], 1)            # horizontal forward (Rh = forward x up)
    ds = np.arange(0.0, verge_width + 1e-6, 1.0)
    out = []
    for c in crossings:
        iu = int(round(float(c["s_upper"]) / step)) % n
        il = int(round(float(c["s_lower"]) / step)) % n
        up = np.arange(iu - half, iu + half + 1) % n
        lo = np.arange(il - half, il + half + 1) % n
        m = len(up)

        def low(q: np.ndarray) -> np.ndarray:
            """Inside the low zone of the lower road (with its verges as they are now)."""
            return _covered(q, xz[lo], fwd[lo], right[lo], hw[lo] + ext_l[lo] + 2.0 * CELL_REACH,
                            hw[lo] + ext_r[lo] + 2.0 * CELL_REACH, slack)

        def span() -> tuple[int, int]:
            """First and last window index of the upper road's stretch above the low zone."""
            lat = np.linspace(-1.0, 1.0, 9)[None, :] * (hw[up] + DECK_SHOULDER)[:, None]
            q = xz[up][:, None, :] + right[up][:, None, :] * lat[:, :, None]
            over = low(q.reshape(-1, 2)).reshape(m, -1).any(1)
            if not over[half]:
                raise ValueError(f"crossover at s = {c['s_upper']}: the upper road is not above the lower one")
            a = b = half
            while a > 0 and over[a - 1]:
                a -= 1
            while b < m - 1 and over[b + 1]:
                b += 1
            if a - pad < 1 or b + pad > m - 2 or over[:a].any() or over[b + 1:].any():
                raise ValueError(
                    f"crossover at s = {c['s_upper']}: the two roads stay on top of each other for more "
                    f"than {CROSS_WINDOW:.0f} m; a bridge that long cannot be built")
            return a, b

        def clip(sec: np.ndarray, inside, zero: np.ndarray | None = None) -> None:
            """Ends the verges of cross-sections ``sec`` before the region ``inside``."""
            for ext, side in ((ext_l, -1.0), (ext_r, 1.0)):
                edge = xz[sec] + right[sec] * (side * hw[sec])[:, None]
                q = edge[:, None, :] + right[sec][:, None, :] * (side * ds)[None, :, None]
                bad = inside(q.reshape(-1, 2)).reshape(len(sec), len(ds))
                first = np.where(bad.any(1), bad.argmax(1), len(ds))
                lim = np.full(n, verge_width)
                lim[sec] = np.where(first >= len(ds), verge_width,
                                    np.maximum(ds[np.maximum(first - 1, 0)] - 1.0, 0.0))
                if zero is not None:
                    lim[zero] = 0.0
                ext[:] = np.minimum(ext, _box(_min_filter(lim, 5), 5))

        # 1. Span with the lower road's verges as they are, 2. keep those verges out of the
        # deck's footprint, 3. the low zone is narrower now: final span (never a longer one).
        a, b = span()
        foot = up[a - pad:b + pad + 1]
        reach = hw[foot] + DECK_SHOULDER + 1.0
        clip(lo, lambda q: _covered(q, xz[foot], fwd[foot], right[foot], reach, reach, slack))
        a, b = span()
        clip(up, low, zero=up[a:b + 1])
        d0, d1 = a - pad, b + pad

        def s_of(i: int) -> float:
            return round(float(i * step), 3)

        out.append({
            "s_upper": float(c["s_upper"]), "s_lower": float(c["s_lower"]),
            "clearance": float(c.get("clearance", 0.0)),
            "span": [s_of(up[a]), s_of(up[b])],
            "deck": [s_of(up[d0]), s_of(up[d1])],
            "upper_window": [s_of(up[0]), s_of(up[-1])],
            "lower_window": [s_of(lo[0]), s_of(lo[-1])],
            "shoulder": DECK_SHOULDER, "thickness": DECK_THICKNESS, "parapet_offset": PARAPET_OFFSET,
            "underpass_margin": UNDERPASS_MARGIN, "barrier_room": BARRIER_ROOM,
            "deck_points": [int(up[d0]), int(d1 - d0 + 1)],
        })
    return out


def _split(fa: float, fb: float) -> list[tuple[float, float]]:
    """Parts [(t0, t1)] of a segment (t in 0..1) where a linear measure, fa at t = 0 and fb at
    t = 1, is negative."""
    if fa >= 0.0 and fb >= 0.0:
        return []
    if fa < 0.0 and fb < 0.0:
        return [(0.0, 1.0)]
    t = fa / (fa - fb)
    return [(0.0, t)] if fa < 0.0 else [(t, 1.0)]


def deck_primitive(bridge: dict, P: np.ndarray, T: np.ndarray, R: np.ndarray, Rh: np.ndarray,
                   hw: np.ndarray, step: float) -> Primitive:
    """Concrete of one bridge, as flat-shaded quads:
      * the slab: shoulders beside the tarmac (in the road's banked plane), side faces,
        underside and end faces;
      * the side walls from the slab down to WALL_FOOT below the lower road, left open where
        the lower road passes;
      * the two walls of the underpass, along the lower road under the deck."""
    n = len(P)
    i0, count = bridge["deck_points"]
    idx = (i0 + np.arange(count)) % n
    sv = (i0 + np.arange(count)) * step
    half = int(round(CROSS_WINDOW / step))
    il = int(round(bridge["s_lower"] / step)) % n
    lo = np.arange(il - half, il + half + 1) % n
    xz = P[:, [0, 2]]
    right = Rh[:, [0, 2]]
    out = (hw[idx] + bridge["shoulder"])[:, None]
    thick = bridge["thickness"]
    drop = UP[None, :] * thick
    # Columns across the deck, left to right: slab bottom, slab top, road edge | road edge, top, bottom.
    cols = [P[idx] - R[idx] * out - drop, P[idx] - R[idx] * out, P[idx] - R[idx] * hw[idx][:, None],
            P[idx] + R[idx] * hw[idx][:, None], P[idx] + R[idx] * out, P[idx] + R[idx] * out - drop]
    lats = [-out[:, 0], -out[:, 0], -hw[idx], hw[idx], out[:, 0], out[:, 0]]
    pos, nrm, uv0, uv1, tris = [], [], [], [], []

    def quad(corners: list, want: np.ndarray) -> None:
        """corners: [(position, s, lateral)] x 4 around the quad; it faces ``want``."""
        pts = np.array([q[0] for q in corners])
        nv = np.cross(pts[1] - pts[0], pts[2] - pts[0])
        if np.linalg.norm(nv) < 1e-9:
            nv = np.cross(pts[2] - pts[0], pts[3] - pts[0])
        if np.linalg.norm(nv) < 1e-9:
            return
        if np.dot(nv, want) < 0.0:
            corners, nv = corners[::-1], -nv
        base = len(pos)
        for q in corners:
            pos.append(q[0])
            nrm.append(nv / np.linalg.norm(nv))
            uv0.append((q[1], q[2]))
            uv1.append((0.0, 6.5))
        tris.extend([(base, base + 1, base + 2), (base, base + 2, base + 3)])

    def corner(col: int, k: int) -> tuple:
        return (cols[col][k], sv[k], lats[col][k])

    # ---- slab: side, shoulder, [the tarmac is the road mesh], shoulder, side, underside
    for k in range(count - 1):
        for ca, cb, want in ((0, 1, -Rh[idx[k]]), (1, 2, UP), (3, 4, UP), (4, 5, Rh[idx[k]]), (5, 0, -UP)):
            quad([corner(ca, k), corner(cb, k), corner(cb, k + 1), corner(ca, k + 1)], want)
    for k, sign in ((0, -1.0), (count - 1, 1.0)):
        quad([corner(1, k), corner(4, k), corner(5, k), corner(0, k)], T[idx[k]] * sign)

    # ---- side walls, open over the lower road
    lower_y = P[lo][:, 1]
    foot_y = float(lower_y[half - 30:half + 31].min()) - WALL_FOOT
    for col, side in ((0, -1.0), (5, 1.0)):
        lat, j = _lateral(cols[col][:, [0, 2]], xz[lo], right[lo])
        f = (hw[lo][j] + bridge["underpass_margin"]) - np.abs(lat)   # > 0: above the lower road
        for k in range(count - 1):
            for t0, t1 in _split(f[k], f[k + 1]):
                a = cols[col][k] + (cols[col][k + 1] - cols[col][k]) * t0
                b = cols[col][k] + (cols[col][k + 1] - cols[col][k]) * t1
                sa, sb = sv[k] + step * t0, sv[k] + step * t1
                quad([(a, sa, lats[col][k]), (b, sb, lats[col][k]),
                      (np.array([b[0], foot_y, b[2]]), sb, lats[col][k]),
                      (np.array([a[0], foot_y, a[2]]), sa, lats[col][k])], Rh[idx[k]] * side)

    # ---- underpass walls, along the lower road where it is under the deck
    for side in (-1.0, 1.0):
        off = side * (hw[lo] + bridge["underpass_margin"])
        w = P[lo] + Rh[lo] * off[:, None]
        lat, i = _lateral(w[:, [0, 2]], xz[idx], right[idx])
        inside = (i > 0) & (i < count - 1)                 # beside the deck, not beyond its ends
        g = np.where(inside, np.abs(lat) - out[i, 0], 1.0)   # < 0: under the deck
        top = P[idx][i, 1] - thick + 0.4                   # ends inside the slab
        for k in range(len(lo) - 1):
            for t0, t1 in _split(g[k], g[k + 1]):
                a = w[k] + (w[k + 1] - w[k]) * t0
                b = w[k] + (w[k + 1] - w[k]) * t1
                ta = top[k] + (top[k + 1] - top[k]) * t0
                tb = top[k] + (top[k + 1] - top[k]) * t1
                sa, sb = (lo[k] + t0) * step, (lo[k] + t1) * step
                quad([(np.array([a[0], a[1] - WALL_FOOT, a[2]]), sa, off[k]),
                      (np.array([b[0], b[1] - WALL_FOOT, b[2]]), sb, off[k]),
                      (np.array([b[0], tb, b[2]]), sb, off[k]),
                      (np.array([a[0], ta, a[2]]), sa, off[k])], -Rh[lo[k]] * side)
    return Primitive("concrete", np.array(pos), np.array(nrm), np.array(uv0), np.array(uv1),
                     np.array(tris, dtype=np.uint32))
