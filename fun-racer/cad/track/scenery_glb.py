"""Scenery meshes around a circuit (buildings, grandstands, bridges, tunnel shells) and their
binary glTF writer, built on road_glb.py.

The surroundings step (tools/track/lib/surroundings.py) decides what stands where; this module
turns footprints into triangles. One node per 400 m chunk (``chunk_<i>_<j>``), one primitive
per material name of MATERIALS. Vertex attributes: POSITION, NORMAL, TEXCOORD_0 (float32) and
COLOR_0 (normalised uint8 RGBA); indices are uint16 where a primitive has fewer than 65536
vertices. Faces are flat shaded: every face has its own vertices.

Conventions the runtime shaders rely on:
  * TEXCOORD_0 is in metres. On walls u runs along the wall and v is the height above the
    object's ground line (negative in the plinth that reaches into the ground); on roofs and
    other flat faces it is the plan position relative to the object's anchor; on grandstand
    treads u runs along the row and v is the depth from the front row.
  * COLOR_0.rgb is the object's tint in linear colour, the same on every vertex of one
    building. COLOR_0.a is 1 on facades that have windows and 0 on blank surfaces.

Plan-view rings are numpy arrays of (x, z) points without the closing duplicate. "Positive"
orientation means positive signed area in (x, z), which is clockwise on a north-up map.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np

from road_glb import Material, _pad

CHUNK = 400.0   # m: side of one scenery chunk (one node of the glb)

MATERIALS = [
    Material("building_wall", (0.80, 0.78, 0.74, 1.0), 0.9),
    Material("building_roof", (0.45, 0.42, 0.40, 1.0), 0.85),
    Material("building_glass", (0.35, 0.45, 0.55, 1.0), 0.15),
    Material("stand_seats", (0.55, 0.57, 0.62, 1.0), 0.8),
    Material("stand_structure", (0.62, 0.62, 0.60, 1.0), 0.9),
    Material("concrete", (0.66, 0.65, 0.62, 1.0), 0.95),
    Material("metal", (0.55, 0.57, 0.60, 1.0), 0.45),
    Material("emissive_window", (1.0, 0.92, 0.75, 1.0), 0.5),
    Material("emissive_light", (1.0, 0.97, 0.90, 1.0), 0.5),
]
MATERIAL_NAMES = [m.name for m in MATERIALS]

UP = np.array([0.0, 1.0, 0.0])
ROW_DEPTH = 0.85      # m: one row of grandstand seating
MAX_ROWS = 40
STAND_FRONT = 1.2     # m: height of the first row above the ground
STAND_SLOPE = 0.5     # rise per metre of depth when the map gives no height
SMOOTH_CORNER = 0.87  # cos(30 deg): the wall u coordinate runs on across flatter corners
SHELL = 0.8           # m: thickness of the walls and the slab of a tunnel shell


# ----------------------------------------------------------------------------- polygons
def signed_area(ring):
    x, z = ring[:, 0], ring[:, 1]
    return 0.5 * float(np.sum(x * np.roll(z, -1) - np.roll(x, -1) * z))


def clean_ring(ring, tol=1e-6):
    """Ring as a float array without the closing duplicate or repeated points."""
    r = np.asarray(ring, dtype=np.float64).reshape(-1, 2)
    if len(r) > 1 and np.hypot(*(r[0] - r[-1])) <= tol:
        r = r[:-1]
    if len(r) > 1:
        keep = np.hypot(*(r - np.roll(r, 1, axis=0)).T) > tol
        r = r[keep]
    return r


def oriented(ring, positive=True):
    return ring if (signed_area(ring) > 0.0) == positive else ring[::-1].copy()


def clip_halfplane(ring, a, b, c):
    """Part of ``ring`` where a*x + b*z + c >= 0 (Sutherland-Hodgman, one edge). A concave
    ring cut into several pieces comes back as one ring joined along the cut line."""
    if len(ring) == 0:
        return ring
    d = ring[:, 0] * a + ring[:, 1] * b + c
    out = []
    n = len(ring)
    for i in range(n):
        j = (i + 1) % n
        if d[i] >= 0.0:
            out.append(ring[i])
        if (d[i] >= 0.0) != (d[j] >= 0.0):
            t = d[i] / (d[i] - d[j])
            out.append(ring[i] + (ring[j] - ring[i]) * t)
    return clean_ring(np.array(out)) if len(out) >= 3 else np.zeros((0, 2))


def _merge_hole(outer, hole):
    """``outer`` (positive) with ``hole`` (negative) spliced in through a bridge from the
    hole's rightmost vertex to a vertex of the outer ring that it can see."""
    m = int(np.argmax(hole[:, 0]))
    mx, mz = hole[m]
    a, b = outer, np.roll(outer, -1, axis=0)
    straddle = (a[:, 1] <= mz) != (b[:, 1] <= mz)
    best_x, best = np.inf, -1
    for i in np.flatnonzero(straddle):
        x = a[i, 0] + (mz - a[i, 1]) / (b[i, 1] - a[i, 1]) * (b[i, 0] - a[i, 0])
        if mx - 1e-9 <= x < best_x:
            best_x, best = x, i
    if best < 0:
        return outer    # the hole is not inside this ring (bad data): leave it out
    j = (best + 1) % len(outer)
    p = best if outer[best, 0] >= outer[j, 0] else j
    # Any vertex inside the triangle (hole point, hit point, p) hides p: take the one closest
    # in angle to the ray instead.
    tri = np.array([[mx, mz], [best_x, mz], outer[p]])
    if signed_area(tri) < 0.0:
        tri = tri[::-1]
    d = [(tri[(k + 1) % 3, 0] - tri[k, 0]) * (outer[:, 1] - tri[k, 1])
         - (tri[(k + 1) % 3, 1] - tri[k, 1]) * (outer[:, 0] - tri[k, 0]) for k in range(3)]
    inside = (d[0] >= 0.0) & (d[1] >= 0.0) & (d[2] >= 0.0)
    inside[p] = False
    inside &= outer[:, 0] > mx
    if inside.any():
        cand = np.flatnonzero(inside)
        slope = np.abs(outer[cand, 1] - mz) / (outer[cand, 0] - mx)
        p = int(cand[np.argmin(slope)])
    # A vertex that already carries a bridge is in the ring more than once: splice at the
    # copy whose corner the new bridge actually leaves through.
    n = len(outer)

    def left(u, v):
        return (v[0] - u[0]) * (mz - u[1]) - (v[1] - u[1]) * (mx - u[0])

    for q in np.flatnonzero((outer[:, 0] == outer[p, 0]) & (outer[:, 1] == outer[p, 1])):
        prev, here, nxt = outer[q - 1], outer[q], outer[(q + 1) % n]
        convex = (here[0] - prev[0]) * (nxt[1] - here[1]) - (here[1] - prev[1]) * (nxt[0] - here[0]) > 0.0
        a, b = left(prev, here) > 0.0, left(here, nxt) > 0.0
        if (a and b) if convex else (a or b):
            p = int(q)
            break
    return np.concatenate([outer[:p + 1], hole[m:], hole[:m + 1], outer[p:]])


def merge_holes(outer, holes=()):
    """One positive ring that covers ``outer`` minus ``holes`` (keyhole bridges, which leaves
    coincident edges: fine for ear clipping and for an even-odd fill)."""
    ring = oriented(clean_ring(outer), True)
    hs = [oriented(h, False) for h in (clean_ring(h) for h in holes) if len(h) >= 3]
    for h in sorted(hs, key=lambda h: -float(h[:, 0].max())):
        ring = _merge_hole(ring, h)
    return ring


def ear_clip(pts):
    """Triangles (index triples into ``pts``, positive orientation) of a positive ring that
    may touch itself (bridges)."""
    n = len(pts)
    if n < 3:
        return []
    x = (pts[:, 0] - pts[:, 0].mean()).tolist()
    z = (pts[:, 1] - pts[:, 1].mean()).tolist()
    xa, za = np.array(x), np.array(z)
    eps = 1e-12 * max(1.0, float(np.ptp(xa)) * float(np.ptp(za)))
    prv = [n - 1] + list(range(n - 1))
    nxt = list(range(1, n)) + [0]

    def cross(a, b, c):
        return (x[b] - x[a]) * (z[c] - z[a]) - (z[b] - z[a]) * (x[c] - x[a])

    reflex = np.array([cross(prv[i], i, nxt[i]) <= eps for i in range(n)])
    tris = []
    left, i, idle = n, 0, 0
    while left > 3:
        a, b, c = prv[i], i, nxt[i]
        cr = cross(a, b, c)
        ear = cr > eps
        if ear and idle <= left:
            cand = np.flatnonzero(reflex)
            if len(cand):
                px, pz = xa[cand], za[cand]
                inside = np.ones(len(cand), dtype=bool)
                for u, v in ((a, b), (b, c), (c, a)):
                    inside &= (x[v] - x[u]) * (pz - z[u]) - (z[v] - z[u]) * (px - x[u]) >= -eps
                # The bridge to a hole repeats two vertices: a copy of a corner blocks nothing.
                for u in (a, b, c):
                    inside &= (px != x[u]) | (pz != z[u])
                ear = not inside.any()
        # Flat or folded corners are dropped without a triangle. After a whole round without
        # an ear (self-intersecting input) the next convex corner is cut regardless.
        if ear or abs(cr) <= eps or idle > 2 * left:
            if cr > eps:
                tris.append((a, b, c))
            nxt[a], prv[c] = c, a
            reflex[b] = False
            reflex[a] = cross(prv[a], a, c) <= eps
            reflex[c] = cross(a, c, nxt[c]) <= eps
            left -= 1
            i, idle = a, 0
        else:
            i, idle = c, idle + 1
    a, b, c = prv[i], i, nxt[i]
    if cross(a, b, c) > eps:
        tris.append((a, b, c))
    return tris


def triangulate(outer, holes=()):
    """(points (n, 2), triangles (m, 3)) covering ``outer`` minus ``holes``; triangles have
    positive orientation in (x, z)."""
    ring = merge_holes(outer, holes)
    tris = ear_clip(ring)
    return ring, np.array(tris, dtype=np.int64).reshape(-1, 3)


# ----------------------------------------------------------------------------- mesh builder
class SceneryMesh:
    """Collects triangles per (chunk, material). ``anchor(x, z)`` picks the chunk and the UV
    origin of whatever is added next, so one object never straddles two chunks."""

    def __init__(self, x0=0.0, z0=0.0, chunk=CHUNK):
        self.x0, self.z0, self.chunk = float(x0), float(z0), float(chunk)
        self.parts = {}    # (i, j, material) -> [positions, normals, uvs, colours, triangles]
        self.counts = {}   # (i, j, material) -> vertices so far
        self._key = (0, 0)
        self.origin = np.zeros(2)

    def anchor(self, x, z):
        self._key = (int(np.floor((x - self.x0) / self.chunk)), int(np.floor((z - self.z0) / self.chunk)))
        self.origin = np.array([float(x), float(z)])

    def tris(self, material, pos, nrm, uv, colour, tri):
        if len(tri) == 0:
            return
        assert material in MATERIAL_NAMES, material
        pos = np.asarray(pos, dtype=np.float64).reshape(-1, 3)
        col = np.broadcast_to(np.asarray(colour, dtype=np.float64), (len(pos), 4))
        key = self._key + (material,)
        base = self.counts.get(key, 0)
        self.parts.setdefault(key, []).append((
            pos.astype(np.float32), np.asarray(nrm, dtype=np.float32).reshape(-1, 3),
            np.asarray(uv, dtype=np.float32).reshape(-1, 2),
            np.round(np.clip(col, 0.0, 1.0) * 255.0).astype(np.uint8),
            np.asarray(tri, dtype=np.int64).reshape(-1, 3) + base))
        self.counts[key] = base + len(pos)

    def quads(self, material, pos, nrm, uv, colour):
        """``pos`` (m, 4, 3) corners counter-clockwise seen from the front, ``nrm`` (m, 3)."""
        pos = np.asarray(pos, dtype=np.float64).reshape(-1, 4, 3)
        m = len(pos)
        if m == 0:
            return
        base = np.arange(m)[:, None] * 4
        tri = np.concatenate([base + [0, 1, 2], base + [0, 2, 3]])
        self.tris(material, pos.reshape(-1, 3), np.repeat(np.asarray(nrm).reshape(-1, 3), 4, axis=0),
                  np.asarray(uv).reshape(-1, 2), colour, tri)

    def face(self, material, pts, facing, colour, v_ref=0.0, away_from=None):
        """A flat convex polygon ``pts`` (k, 3), wound so its front looks along ``facing`` (or
        away from the point ``away_from``)."""
        pts = np.asarray(pts, dtype=np.float64).reshape(-1, 3)
        n = np.zeros(3)
        for k in range(1, len(pts) - 1):
            n = n + np.cross(pts[k] - pts[0], pts[k + 1] - pts[0])
        length = float(np.linalg.norm(n))
        if length < 1e-9:
            return
        n /= length
        want = (pts.mean(axis=0) - np.asarray(away_from)) if away_from is not None else np.asarray(facing)
        if float(n @ want) < 0.0:
            pts, n = pts[::-1], -n
        if abs(n[1]) < 0.7:     # wall: u along its horizontal direction, v = height
            t = np.cross(UP, n)
            t /= np.linalg.norm(t)
            u = (pts - pts[0]) @ t
            uv = np.stack([u - u.min(), pts[:, 1] - v_ref], axis=1)
        else:                   # roof / floor: plan position
            uv = pts[:, [0, 2]] - self.origin
        k = len(pts)
        tri = np.stack([np.zeros(k - 2, dtype=np.int64), np.arange(1, k - 1), np.arange(2, k)], axis=1)
        self.tris(material, pts, np.tile(n, (k, 1)), uv, colour, tri)

    def triangle_counts(self):
        out = {name: 0 for name in MATERIAL_NAMES}
        for (_, _, material), parts in self.parts.items():
            out[material] += sum(len(p[4]) for p in parts)
        return out

    def arrays(self, i, j, material):
        parts = self.parts[(i, j, material)]
        return tuple(np.concatenate([p[k] for p in parts]) for k in range(5))


# ----------------------------------------------------------------------------- solids
def wall_quads(mesh, material, ring, y_base, y_top, colour, v_ref):
    """Vertical walls along a ring, facing left of its direction of travel in (x, z) seen
    from above with z down the page: outward for a positive ring, into the courtyard for a
    hole given in negative orientation. ``y_base`` / ``y_top`` are scalars or one value per
    ring vertex."""
    n = len(ring)
    if n < 2:
        return
    a, b = ring, np.roll(ring, -1, axis=0)
    d = b - a
    length = np.hypot(d[:, 0], d[:, 1])
    ok = length > 1e-6
    dn = d / np.where(ok, length, 1.0)[:, None]
    # u runs on from one wall to the next round gentle corners (curved facades), and starts
    # again at every real corner so each wall has whole windows from its own edge.
    turn = np.sum(dn * np.roll(dn, 1, axis=0), axis=1)
    start = int(np.argmin(turn))
    u0 = np.zeros(n)
    acc = 0.0
    for k in range(n):
        i = (start + k) % n
        if turn[i] < SMOOTH_CORNER or k == 0:
            acc = 0.0
        u0[i] = acc
        acc += length[i]
    yb = np.broadcast_to(np.asarray(y_base, dtype=np.float64), (n,))
    yt = np.broadcast_to(np.asarray(y_top, dtype=np.float64), (n,))
    yb1, yt1 = np.roll(yb, -1), np.roll(yt, -1)
    pos = np.empty((n, 4, 3))
    pos[:, 0] = np.stack([b[:, 0], yb1, b[:, 1]], axis=1)
    pos[:, 1] = np.stack([a[:, 0], yb, a[:, 1]], axis=1)
    pos[:, 2] = np.stack([a[:, 0], yt, a[:, 1]], axis=1)
    pos[:, 3] = np.stack([b[:, 0], yt1, b[:, 1]], axis=1)
    nrm = np.stack([dn[:, 1], np.zeros(n), -dn[:, 0]], axis=1)
    uv = np.empty((n, 4, 2))
    uv[:, 0] = np.stack([u0 + length, yb1 - v_ref], axis=1)
    uv[:, 1] = np.stack([u0, yb - v_ref], axis=1)
    uv[:, 2] = np.stack([u0, yt - v_ref], axis=1)
    uv[:, 3] = np.stack([u0 + length, yt1 - v_ref], axis=1)
    mesh.quads(material, pos[ok], nrm[ok], uv[ok], colour)


def cap(mesh, material, outer, holes, y, colour, up=True):
    """Flat polygon at height ``y``: a roof (``up``) or a soffit."""
    pts, tri = triangulate(outer, holes)
    if len(tri) == 0:
        return
    pos = np.stack([pts[:, 0], np.full(len(pts), float(y)), pts[:, 1]], axis=1)
    if up:
        tri = tri[:, ::-1]     # positive in (x, z) looks down in the y-up frame
    nrm = np.tile([0.0, 1.0 if up else -1.0, 0.0], (len(pts), 1))
    mesh.tris(material, pos, nrm, pts - mesh.origin, colour, tri)


def prism(mesh, outer, holes, y_base, y_top, wall, roof, wall_colour, roof_colour, v_ref,
          floor=False):
    """Extruded footprint: walls from ``y_base`` to ``y_top``, a flat roof and (for parts
    that hang in the air) a floor."""
    outer = oriented(clean_ring(outer), True)
    if len(outer) < 3:
        return
    holes = [oriented(h, False) for h in (clean_ring(h) for h in holes) if len(h) >= 3]
    for ring in [outer] + holes:
        wall_quads(mesh, wall, ring, y_base, y_top, wall_colour, v_ref)
    cap(mesh, roof, outer, holes, y_top, roof_colour, up=True)
    if floor:
        cap(mesh, wall, outer, holes, y_base, (wall_colour[0], wall_colour[1], wall_colour[2], 0.0), up=False)


def gabled_roof(mesh, ring, y_eave, rise, wall, roof, wall_colour, roof_colour, v_ref):
    """Pitched roof over a four-cornered footprint: the ridge runs along the long side, the
    two gable triangles are wall."""
    ring = oriented(clean_ring(ring), True)
    assert len(ring) == 4
    p = [np.array([x, y_eave, z]) for x, z in ring]
    side = [float(np.hypot(*(ring[(k + 1) % 4] - ring[k]))) for k in range(4)]
    k0 = 0 if side[0] + side[2] >= side[1] + side[3] else 1     # edges k0, k0 + 2 are the eaves
    q = [p[(k0 + k) % 4] for k in range(4)]
    m1 = 0.5 * (q[1] + q[2]) + UP * rise
    m3 = 0.5 * (q[3] + q[0]) + UP * rise
    centre = np.mean(q, axis=0)
    mesh.face(roof, [q[0], q[1], m1, m3], UP, roof_colour)
    mesh.face(roof, [q[2], q[3], m3, m1], UP, roof_colour)
    blank = (wall_colour[0], wall_colour[1], wall_colour[2], 0.0)
    mesh.face(wall, [q[1], q[2], m1], None, blank, v_ref, away_from=centre)
    mesh.face(wall, [q[3], q[0], m3], None, blank, v_ref, away_from=centre)


def pyramid_roof(mesh, ring, y_eave, rise, roof, roof_colour):
    ring = oriented(clean_ring(ring), True)
    apex = np.array([ring[:, 0].mean(), y_eave + rise, ring[:, 1].mean()])
    centre = np.array([apex[0], y_eave, apex[2]])
    for k in range(len(ring)):
        a, b = ring[k], ring[(k + 1) % len(ring)]
        mesh.face(roof, [[a[0], y_eave, a[1]], [b[0], y_eave, b[1]], apex], None, roof_colour,
                  away_from=centre)


def ngon(cx, cz, radius, sides=8):
    ang = -np.arange(sides) * (2.0 * np.pi / sides)     # positive orientation in (x, z)
    return np.stack([cx + radius * np.cos(ang), cz - radius * np.sin(ang)], axis=1)


def box(mesh, material, lo, hi, colour):
    """Axis-aligned box between the corners ``lo`` and ``hi`` (x, y, z), all six faces."""
    (x0, y0, z0), (x1, y1, z1) = lo, hi
    c = np.array([0.5 * (x0 + x1), 0.5 * (y0 + y1), 0.5 * (z0 + z1)])
    v = [np.array([x, y, z]) for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)]
    for f in ((0, 1, 3, 2), (4, 5, 7, 6), (0, 1, 5, 4), (2, 3, 7, 6), (0, 2, 6, 4), (1, 3, 7, 5)):
        mesh.face(material, [v[k] for k in f], None, colour, y0, away_from=c)


def ribbon(mesh, material, centre, right, width, thickness, colour, ends=True):
    """A deck swept along ``centre`` (n, 3; its top surface) with unit horizontal ``right``
    vectors (n, 2): top, underside, both edges and the two end faces."""
    centre = np.asarray(centre, dtype=np.float64)
    n = len(centre)
    if n < 2:
        return
    off = np.stack([right[:, 0], np.zeros(n), right[:, 1]], axis=1) * (0.5 * width)
    lt, rt = centre - off, centre + off
    lb, rb = lt - UP * thickness, rt - UP * thickness
    mid = 0.5 * (lb + rt)
    for k in range(n - 1):
        m = 0.5 * (mid[k] + mid[k + 1])
        mesh.face(material, [lt[k], rt[k], rt[k + 1], lt[k + 1]], UP, colour)
        mesh.face(material, [lb[k], rb[k], rb[k + 1], lb[k + 1]], -UP, colour)
        mesh.face(material, [lt[k], lb[k], lb[k + 1], lt[k + 1]], None, colour, away_from=m)
        mesh.face(material, [rt[k], rb[k], rb[k + 1], rt[k + 1]], None, colour, away_from=m)
    if ends:
        mesh.face(material, [lt[0], rt[0], rb[0], lb[0]], None, colour, away_from=mid[1])
        mesh.face(material, [lt[-1], rt[-1], rb[-1], lb[-1]], None, colour, away_from=mid[-2])


# ----------------------------------------------------------------------------- grandstands
def stand_axis(ring, toward):
    """Unit vector from the front row to the back row: the footprint's own axis (along or
    across its longest side) that points most directly away from the track."""
    d = np.roll(ring, -1, axis=0) - ring
    length = np.hypot(d[:, 0], d[:, 1])
    e = d[int(np.argmax(length))] / max(float(length.max()), 1e-9)
    cands = [e, -e, np.array([-e[1], e[0]]), np.array([e[1], -e[0]])]
    away = -np.asarray(toward, dtype=np.float64)
    return max(cands, key=lambda c: float(c @ away))


def grandstand(mesh, ring, toward, y_ground, y_base, height, colour, covered=False):
    """Stepped seating over a footprint, rising away from ``toward`` (unit vector from the
    stand to the track). ``height`` is the top row above ``y_ground`` (None: from the depth).
    Returns (rows, top height)."""
    ring = oriented(clean_ring(ring), True)
    back = stand_axis(ring, toward)
    along = np.array([-back[1], back[0]])
    t = ring @ back
    t0, t1 = float(t.min()), float(t.max())
    depth = t1 - t0
    rows = int(min(MAX_ROWS, max(2, round(depth / ROW_DEPTH))))
    top = float(height) if height else min(STAND_FRONT + STAND_SLOPE * depth, 30.0)
    top = max(top, STAND_FRONT + 0.3)
    step = depth / rows
    ys = [y_ground + STAND_FRONT + (top - STAND_FRONT) * k / (rows - 1) for k in range(rows)]
    eps = 1e-4 * max(1.0, depth)
    structure = (colour[0], colour[1], colour[2], 0.0)
    u0 = float((ring @ along).min())
    for k in range(rows):
        lo, hi = t0 + k * step, t0 + (k + 1) * step
        piece = clip_halfplane(ring, back[0], back[1], -lo)
        piece = clip_halfplane(piece, -back[0], -back[1], hi)
        if len(piece) < 3 or abs(signed_area(piece)) < 0.02:
            continue
        piece = oriented(piece, True)
        pts, tri = triangulate(piece)
        pos = np.stack([pts[:, 0], np.full(len(pts), ys[k]), pts[:, 1]], axis=1)
        uv = np.stack([pts @ along - u0, pts @ back - t0], axis=1)
        mesh.tris("stand_seats", pos, np.tile(UP, (len(pts), 1)), uv, colour, tri[:, ::-1])
        pt = piece @ back
        for i in range(len(piece)):
            j = (i + 1) % len(piece)
            a, b = piece[i], piece[j]
            on_front = abs(pt[i] - lo) < eps and abs(pt[j] - lo) < eps
            on_back = abs(pt[i] - hi) < eps and abs(pt[j] - hi) < eps
            if on_back and k < rows - 1:
                continue    # the next row's riser stands here
            if on_front and k > 0:
                y0, y1, mat, col = ys[k - 1], ys[k], "stand_seats", colour
            else:
                y0, y1, mat, col = y_base, ys[k], "stand_structure", structure
                if covered and k == rows - 1:
                    y1 = y_ground + top + 4.0   # back and end walls carry the roof
            quad = [[b[0], y0, b[1]], [a[0], y0, a[1]], [a[0], y1, a[1]], [b[0], y1, b[1]]]
            d = (b - a) / max(float(np.hypot(*(b - a))), 1e-9)
            mesh.face(mat, quad, np.array([d[1], 0.0, -d[0]]), col, y_ground)
    if covered:
        y_roof = y_ground + top + 4.0
        prism(mesh, ring, [], y_roof, y_roof + 0.35, "metal", "metal", structure, structure, y_ground,
              floor=True)
    return rows, top


# ----------------------------------------------------------------------------- tunnel shells
def roof_shell(mesh, centre, right, half_width, y_left, y_right, clear, kind="tunnel",
               thickness=SHELL, colour=(0.62, 0.62, 0.60, 0.0), portals=(True, True)):
    """Tunnel or overpass over a stretch of road.

    ``centre`` (n, 3) are the road centre points, ``right`` (n, 2) unit vectors to the right
    of travel, ``half_width`` (n,) the distance from the centre to the inner face of the walls
    and ``y_left`` / ``y_right`` (n,) the road surface heights there. The ceiling is ``clear``
    above the road centre and follows its profile. Kinds: "tunnel" (two walls), "gallery_left"
    / "gallery_right" (that side open, on columns) and "overpass" (a deck on four columns).
    ``portals`` says which ends get an end face (a long shell is built in pieces).
    Returns the number of ceiling lights."""
    centre = np.asarray(centre, dtype=np.float64)
    n = len(centre)
    if n < 2:
        return 0
    r3 = np.stack([right[:, 0], np.zeros(n), right[:, 1]], axis=1)
    hw = np.asarray(half_width, dtype=np.float64)[:, None]
    ceil_y = centre[:, 1] + clear
    foot_l = np.asarray(y_left, dtype=np.float64) - 0.6
    foot_r = np.asarray(y_right, dtype=np.float64) - 0.6

    def at(lateral, y):
        p = centre + r3 * lateral
        p[:, 1] = y
        return p

    a_in, b_in = at(-hw, foot_l), at(-hw, ceil_y)                  # left wall, inner face
    d_in, c_in = at(hw, foot_r), at(hw, ceil_y)                    # right wall, inner face
    a_out, b_out = at(-hw - thickness, foot_l), at(-hw - thickness, ceil_y + thickness)
    d_out, c_out = at(hw + thickness, foot_r), at(hw + thickness, ceil_y + thickness)
    axis = centre + UP * (0.5 * clear)
    wall_l = kind in ("tunnel", "gallery_right")
    wall_r = kind in ("tunnel", "gallery_left")
    v_ref = float(centre[:, 1].min())

    def sweep(p, q, inward):
        for k in range(n - 1):
            quad = [p[k], q[k], q[k + 1], p[k + 1]]
            m = 0.5 * (axis[k] + axis[k + 1])
            if inward:
                mesh.face("concrete", quad, m - np.mean(quad, axis=0), colour, v_ref)
            else:
                mesh.face("concrete", quad, None, colour, v_ref, away_from=m)

    sweep(b_in, c_in, True)         # ceiling
    sweep(b_out, c_out, False)      # top of the slab
    if wall_l:
        sweep(a_in, b_in, True)
        sweep(a_out, b_out, False)
    else:
        sweep(b_in, b_out, False)   # edge of the slab
    if wall_r:
        sweep(d_in, c_in, True)
        sweep(d_out, c_out, False)
    else:
        sweep(c_in, c_out, False)
    for k, inside in [e for e, on in zip(((0, 1), (n - 1, n - 2)), portals) if on]:
        out = centre[k] - centre[inside]
        mesh.face("concrete", [b_in[k], c_in[k], c_out[k], b_out[k]], out, colour, v_ref)
        if wall_l:
            mesh.face("concrete", [a_in[k], b_in[k], b_out[k], a_out[k]], out, colour, v_ref)
        if wall_r:
            mesh.face("concrete", [d_in[k], c_in[k], c_out[k], d_out[k]], out, colour, v_ref)
    # Columns under an open side: every 8 m for a gallery, the four corners of an overpass.
    seg = np.hypot(*np.diff(centre[:, [0, 2]], axis=0).T)
    dist = np.concatenate([[0.0], np.cumsum(seg)])
    if kind == "overpass":
        posts = [0, n - 1]
    else:
        posts = [int(np.argmin(np.abs(dist - s))) for s in np.arange(0.0, dist[-1] + 1e-6, 8.0)]
    for side, has_wall, foot in ((-1.0, wall_l, foot_l), (1.0, wall_r, foot_r)):
        if has_wall:
            continue
        for k in sorted(set(posts)):
            c = centre[k] + r3[k] * side * (float(hw[k, 0]) + 0.5 * thickness)
            half = 0.5 * thickness
            box(mesh, "concrete", (c[0] - half, foot[k], c[2] - half), (c[0] + half, ceil_y[k], c[2] + half),
                colour)
    # Ceiling lights: two rows of flat lamps, a hand's width under the ceiling.
    lights = 0
    if kind != "overpass":
        for s in np.arange(4.0, dist[-1] - 2.0, 8.0):
            k = int(min(n - 2, np.searchsorted(dist, s) - 1))
            f = (s - dist[k]) / max(seg[k], 1e-9)
            c = centre[k] + (centre[k + 1] - centre[k]) * f
            t = centre[k + 1] - centre[k]
            t = t / max(float(np.linalg.norm(t)), 1e-9)
            y = ceil_y[k] + (ceil_y[k + 1] - ceil_y[k]) * f - 0.06
            for side in (-0.55, 0.55):
                o = c + r3[k] * side * float(hw[k, 0])
                o[1] = y
                quad = [o - t * 0.7 - r3[k] * 0.18, o + t * 0.7 - r3[k] * 0.18,
                        o + t * 0.7 + r3[k] * 0.18, o - t * 0.7 + r3[k] * 0.18]
                mesh.face("emissive_light", quad, -UP, (1.0, 1.0, 1.0, 0.0))
                lights += 1
    return lights


# ----------------------------------------------------------------------------- writer
def write_glb(path: Path, mesh: SceneryMesh, scene_name: str, generator: str) -> dict:
    """Writes the collected chunks; returns {"chunks", "vertices", "triangles", "bytes"}."""
    blob = bytearray()
    views: list[dict] = []
    accessors: list[dict] = []
    meshes: list[dict] = []
    nodes: list[dict] = []
    used = [m for m in MATERIALS if any(k[2] == m.name for k in mesh.parts)]
    mat_index = {m.name: i for i, m in enumerate(used)}

    def accessor(arr, kind, target, comp, minmax=False, normalized=False):
        raw = arr.tobytes()
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(raw), "target": target})
        blob.extend(_pad(raw, b"\x00"))
        acc = {"bufferView": len(views) - 1, "componentType": comp, "count": len(arr), "type": kind}
        if normalized:
            acc["normalized"] = True
        if minmax:
            acc["min"] = arr.min(axis=0).tolist()
            acc["max"] = arr.max(axis=0).tolist()
        accessors.append(acc)
        return len(accessors) - 1

    vertices = triangles = 0
    for i, j in sorted({k[:2] for k in mesh.parts}):
        gl_prims = []
        for m in used:
            if (i, j, m.name) not in mesh.parts:
                continue
            pos, nrm, uv, col, tri = mesh.arrays(i, j, m.name)
            attrs = {
                "POSITION": accessor(np.ascontiguousarray(pos), "VEC3", 34962, 5126, minmax=True),
                "NORMAL": accessor(np.ascontiguousarray(nrm), "VEC3", 34962, 5126),
                "TEXCOORD_0": accessor(np.ascontiguousarray(uv), "VEC2", 34962, 5126),
                "COLOR_0": accessor(np.ascontiguousarray(col), "VEC4", 34962, 5121, normalized=True),
            }
            small = len(pos) < 65536
            idx = np.ascontiguousarray(tri.reshape(-1), dtype=np.uint16 if small else np.uint32)
            gl_prims.append({"attributes": attrs,
                             "indices": accessor(idx, "SCALAR", 34963, 5123 if small else 5125),
                             "material": mat_index[m.name], "mode": 4})
            vertices += len(pos)
            triangles += len(tri)
        name = f"chunk_{i}_{j}"
        meshes.append({"name": name, "primitives": gl_prims})
        nodes.append({"name": name, "mesh": len(meshes) - 1})

    gltf = {
        "asset": {"version": "2.0", "generator": generator},
        "scene": 0,
        "scenes": [{"name": scene_name, "nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": [{"name": m.name,
                       "pbrMetallicRoughness": {"baseColorFactor": list(m.base_color), "metallicFactor": 0.0,
                                                "roughnessFactor": m.roughness}} for m in used],
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(blob)}],
    }
    if not nodes:       # nothing around the circuit: still a valid, empty scene
        for key in ("meshes", "materials", "accessors", "bufferViews", "buffers", "nodes"):
            del gltf[key]
        gltf["scenes"] = [{"name": scene_name}]
    js = _pad(json.dumps(gltf, separators=(",", ":")).encode(), b" ")
    bn = bytes(blob)
    total = 12 + 8 + len(js) + ((8 + len(bn)) if bn else 0)
    out = bytearray(struct.pack("<III", 0x46546C67, 2, total))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js
    if bn:
        out += struct.pack("<II", len(bn), 0x004E4942) + bn
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(out))
    return {"chunks": len(nodes), "vertices": vertices, "triangles": triangles, "bytes": len(out)}
