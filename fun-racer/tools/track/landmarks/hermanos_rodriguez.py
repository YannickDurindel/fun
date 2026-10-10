#!/usr/bin/env python3
"""Landmark models of the Autódromo Hermanos Rodríguez (Mexico City).

    .venv/bin/python tools/track/landmarks/hermanos_rodriguez.py

Writes assets/tracks/hermanos_rodriguez/landmarks/*.glb and landmarks.json. Run it after
build_track.py: it reads track.json, terrain.json, the terrain grid and the cached map data
of the track folder, so the models follow a rebuilt centreline.

What is modelled, and where the dimensions come from. Plan shapes are the OpenStreetMap
footprints in raw/surroundings_near_*.json (the ids are given below), checked against aerial
imagery (Esri World Imagery); heights are estimates from the number of seat rows, storeys
and shadow lengths in that imagery and from trackside photographs, unless a source is named.

  foro_sol          The baseball stadium the lap runs through (Turns 12 to 16): a U of
                    seating 35 m deep open to the east, the terracotta membrane roof it got
                    in the 2024 rebuild (as Estadio GNP Seguros), and the 27 m wide passage
                    under the west stand through which the track leaves for the Peraltada.
  pit_straight      Pit building (ways 377679570: 304 m long, three levels), the three
                    covered main grandstands opposite, the hospitality suites on the outside
                    of the Peraltada and the start-light gantry.
  straight_stands   The two covered stands on the left half way down the main straight.
  horquilla_stand   The 230 m covered grandstand on the outside of Turns 5 and 6.
  palacio_deportes  Palacio de los Deportes, the 1968 Olympic arena west of the Peraltada:
                    a copper dome on a low drum (dome footprint way 1527624820, 134 m).
  velodromo         Velódromo Olímpico Agustín Melgar beside the run to the stadium: the
                    turquoise elliptical roof of its 2000s cover (way 377679564).

All models are written in the track frame (x east, y up, z south, metres) about their own
origin and placed by landmarks.json with "xz"; y = 0 of a model is the terrain height at
that origin, as Scenery puts it there.
"""

from __future__ import annotations

import glob
import json
import math
import os
import sys
from pathlib import Path

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "track"))
sys.path.insert(0, os.path.join(ROOT, "cad", "track"))

import scenery_glb as sg  # noqa: E402
from lib import geom  # noqa: E402
from lib.surroundings import Ground  # noqa: E402

TRACK_ID = "hermanos_rodriguez"
OUT = os.path.join(ROOT, "assets", "tracks", TRACK_ID)
UP = np.array([0.0, 1.0, 0.0])

# Linear vertex colours (r, g, b, a); a = 1 puts windows on a building_wall face.
WHITE_ROOF = (0.80, 0.80, 0.77, 0.0)
GREY_ROOF = (0.42, 0.44, 0.45, 0.0)
STEEL = (0.30, 0.31, 0.33, 0.0)
CONCRETE = (0.50, 0.49, 0.46, 0.0)
SEATS = (0.20, 0.30, 0.22, 0.0)
TERRACOTTA = (0.62, 0.22, 0.10, 0.0)        # the stadium membrane seen from above
MEMBRANE_UNDER = (0.72, 0.60, 0.50, 0.0)    # ... and from below, lit through
SEASHELL = (0.86, 0.80, 0.72, 1.0)          # pit building walls (OSM building:colour)
INDIAN_RED = (0.52, 0.11, 0.10, 0.0)        # ... and its roof (OSM roof:colour)
DARK = (0.03, 0.03, 0.035, 0.0)
COPPER = (0.36, 0.17, 0.08, 0.0)            # Palacio de los Deportes dome
TURQUOISE = (0.16, 0.50, 0.42, 0.0)         # velodrome roof


# ----------------------------------------------------------------------------- inputs
class Site:
    """Centreline, terrain and map shapes of the built track."""

    def __init__(self):
        with open(os.path.join(OUT, "track.json"), encoding="utf-8") as f:
            self.track = json.load(f)
        self.ground = Ground(OUT)
        ter = self.ground.meta
        self.proj = geom.Projection(ter["origin_latlon"][0], ter["origin_latlon"][1], ter["plan_scale"])
        p = np.array([q["p"] for q in self.track["points"]], dtype=np.float64)
        self.xz, self.y = p[:, [0, 2]], p[:, 1]
        self.width = np.array([q["width"] for q in self.track["points"]])
        self.step, self.length = float(self.track["step"]), float(self.track["length"])
        t = np.roll(self.xz, -1, axis=0) - np.roll(self.xz, 1, axis=0)
        self.tan = t / np.hypot(t[:, 0], t[:, 1])[:, None]
        self.right = np.stack([-self.tan[:, 1], self.tan[:, 0]], axis=1)   # x east, z south
        self.rings = {}
        cache = sorted(glob.glob(os.path.join(OUT, "raw", "surroundings_near_*.json")))
        if not cache:
            raise SystemExit("no raw/surroundings_near_*.json: run the surroundings step first")
        with open(cache[-1], encoding="utf-8") as f:
            for el in json.load(f)["elements"]:
                if el["t"] == "n":
                    continue
                flat = el["g"] if el["t"] == "w" else el["o"][0]
                ll = np.asarray(flat, dtype=np.float64).reshape(-1, 2)
                x, z = self.proj.to_xz(ll[:, 0], ll[:, 1])
                self.rings[el["id"]] = np.stack([x, z], axis=1)

    def ring(self, osm_id, closed=False):
        """Footprint of a map object in track metres (with the closing point if asked)."""
        r = self.rings[osm_id]
        return r if closed else sg.clean_ring(r)

    def index(self, s):
        return int(round((s % self.length) / self.step)) % len(self.xz)

    def at(self, s, lateral=0.0):
        """(x, z) of the point `lateral` metres right of the centreline at distance s."""
        i = self.index(s)
        return self.xz[i] + self.right[i] * lateral

    def road_y(self, s):
        return float(self.y[self.index(s)])

    def toward_track(self, p):
        """Unit vector from p to the nearest centreline point."""
        d = self.xz - np.asarray(p)
        v = d[int(np.argmin(np.hypot(d[:, 0], d[:, 1])))]
        return v / max(float(np.hypot(*v)), 1e-6)

    def height(self, x, z):
        return float(self.ground.height(np.array([x]), np.array([z]))[0])


class Model:
    """One landmark: a SceneryMesh kept in a single node, written about its own origin."""

    def __init__(self, site, name, origin):
        self.site, self.name = site, name
        self.origin = np.array(origin, dtype=np.float64)
        self.y0 = site.height(*self.origin)
        self.mesh = sg.SceneryMesh(-5.0e5, -5.0e5, 1.0e6)
        self.mesh.anchor(self.origin[0], self.origin[1])

    def write(self):
        shift = np.array([self.origin[0], self.y0, self.origin[1]], dtype=np.float32)
        for key, parts in self.mesh.parts.items():
            self.mesh.parts[key] = [(p[0] - shift,) + p[1:] for p in parts]
        path = Path(OUT) / "landmarks" / (self.name + ".glb")
        info = sg.write_glb(path, self.mesh, self.name, "landmarks/" + TRACK_ID + ".py")
        print(f"  {self.name}.glb: {info['triangles']} triangles, {info['bytes'] / 1024:.0f} kB")
        return {"model": self.name, "at": {"xz": [round(float(self.origin[0]), 2), round(float(self.origin[1]), 2)]}}


# ----------------------------------------------------------------------------- shapes
def p3(q, y):
    return np.array([q[0], y, q[1]], dtype=np.float64)


def slab(mesh, material, a0, a1, b0, b1, colour, under=None, thickness=0.3):
    """A sheet between two edges a0-a1 and b0-b1 (3D points): top face, and an underside
    `thickness` lower in the colour `under` (cull_back materials show one side only)."""
    mesh.face(material, [a0, a1, b1, b0], UP, colour)
    d = UP * thickness
    mesh.face(material, [a0 - d, a1 - d, b1 - d, b0 - d], -UP, under or colour)


def obox(mesh, material, centre, half, yaw, colour):
    """Box about `centre` (x, y, z) with half extents (along, up, across), its long axis
    turned `yaw` radians from +x towards +z."""
    c, s = math.cos(yaw), math.sin(yaw)
    ax, az = np.array([c, 0.0, s]), np.array([-s, 0.0, c])
    centre = np.asarray(centre, dtype=np.float64)
    v = [centre + ax * half[0] * i + UP * half[1] * j + az * half[2] * k
         for i in (-1, 1) for j in (-1, 1) for k in (-1, 1)]
    for f in ((0, 1, 3, 2), (4, 5, 7, 6), (0, 1, 5, 4), (2, 3, 7, 6), (0, 2, 6, 4), (1, 3, 7, 5)):
        mesh.face(material, [v[k] for k in f], None, colour, centre[1] - half[1], away_from=centre)


def beam(mesh, material, a, b, width, depth, colour):
    """Horizontal box from a to b (x, y, z of the top centreline)."""
    a, b = np.asarray(a, dtype=np.float64), np.asarray(b, dtype=np.float64)
    mid = 0.5 * (a + b) - UP * depth * 0.5
    yaw = math.atan2(b[2] - a[2], b[0] - a[0])
    obox(mesh, material, mid, (0.5 * float(np.hypot(b[0] - a[0], b[2] - a[2])), depth * 0.5, width * 0.5), yaw, colour)


def post(mesh, material, q, y0, y1, size, colour):
    obox(mesh, material, (q[0], 0.5 * (y0 + y1), q[1]), (size * 0.5, 0.5 * (y1 - y0), size * 0.5), 0.0, colour)


def bowl(mesh, inner, outer, y_ground, y_front, y_top, colour, clear=None, ends=(True, True),
         back=CONCRETE):
    """Stepped seating between two matched lines `inner` (front row) and `outer` (back),
    both (n, 2): rows 0.85 m deep rising from y_front to y_top above y_ground. With `clear`
    the rows below that height are left out and closed by a soffit (a stand bridging the
    track). Returns the number of rows."""
    inner, outer = np.asarray(inner, dtype=np.float64), np.asarray(outer, dtype=np.float64)
    depth = float(np.hypot(*(outer - inner).T).mean())
    rows = int(max(2, round(depth / sg.ROW_DEPTH)))
    ys = [y_ground + y_front + (y_top - y_front) * k / (rows - 1) for k in range(rows)]
    line = [inner + (outer - inner) * (k / rows) for k in range(rows + 1)]
    u = np.concatenate([[0.0], np.cumsum(np.hypot(*np.diff(0.5 * (inner + outer), axis=0).T))])
    structure = (colour[0], colour[1], colour[2], 0.0)
    k0 = 0
    if clear is not None:
        k0 = next(k for k in range(rows) if ys[k] >= y_ground + clear)
    y_base = y_ground - 1.5 if clear is None else y_ground + clear - 0.6
    n = len(inner)
    for j in range(n - 1):
        inward = (inner[j] + inner[j + 1] - outer[j] - outer[j + 1])
        inward = np.array([inward[0], 0.0, inward[1]]) / max(float(np.hypot(*inward)), 1e-9)
        for k in range(k0, rows):
            a0, a1 = line[k][j], line[k][j + 1]
            b0, b1 = line[k + 1][j], line[k + 1][j + 1]
            pos = np.array([p3(a0, ys[k]), p3(a1, ys[k]), p3(b1, ys[k]), p3(b0, ys[k])])
            v0, v1 = k * depth / rows, (k + 1) * depth / rows
            uv = np.array([[u[j], v0], [u[j + 1], v0], [u[j + 1], v1], [u[j], v1]])
            mesh.tris("stand_seats", pos, np.tile(UP, (4, 1)), uv, colour, [[0, 2, 1], [0, 3, 2]])
            lo = y_base if k == k0 else ys[k - 1]
            mat, col = ("stand_structure", structure) if k == k0 else ("stand_seats", colour)
            mesh.face(mat, [p3(a0, lo), p3(a1, lo), p3(a1, ys[k]), p3(a0, ys[k])], inward, col, y_ground)
        # Back wall with a parapet, and the soffit of a bridging stand.
        o0, o1 = outer[j], outer[j + 1]
        mesh.face("concrete", [p3(o0, y_base), p3(o1, y_base), p3(o1, ys[-1] + 1.1), p3(o0, ys[-1] + 1.1)],
                  -inward, back, y_ground)
        if clear is not None:
            f0, f1 = line[k0][j], line[k0][j + 1]
            mesh.face("concrete", [p3(f0, y_base), p3(f1, y_base), p3(o1, y_base), p3(o0, y_base)], -UP, back)
    for j, on in ((0, ends[0]), (n - 1, ends[1])):
        if not on:
            continue
        other = 1 if j == 0 else n - 2
        out = inner[j] - inner[other]
        out = np.array([out[0], 0.0, out[1]]) / max(float(np.hypot(*out)), 1e-9)
        for k in range(k0, rows):
            mesh.face("stand_structure", [p3(line[k][j], y_base), p3(line[k + 1][j], y_base),
                                          p3(line[k + 1][j], ys[k]), p3(line[k][j], ys[k])], out, structure, y_ground)
    return rows


def canopy(mesh, front, back, y_front, y_back, top, under, columns=0.0, y_ground=0.0, fascia=1.0):
    """Roof sheet between two matched lines (n, 2), with a fascia along the front edge and
    a steel column every `columns` metres along the back line."""
    front, back = np.asarray(front, dtype=np.float64), np.asarray(back, dtype=np.float64)
    for j in range(len(front) - 1):
        f0, f1, b0, b1 = p3(front[j], y_front), p3(front[j + 1], y_front), p3(back[j], y_back), p3(back[j + 1], y_back)
        slab(mesh, "metal", f0, f1, b0, b1, top, under)
        inward = front[j] + front[j + 1] - back[j] - back[j + 1]
        inward = np.array([inward[0], 0.0, inward[1]]) / max(float(np.hypot(*inward)), 1e-9)
        mesh.face("metal", [f0 - UP * fascia, f1 - UP * fascia, f1, f0], inward, top)
        mesh.face("metal", [b0 - UP * fascia, b1 - UP * fascia, b1, b0], -inward, top)
    if columns > 0.0:
        seg = np.hypot(*np.diff(back, axis=0).T)
        dist = np.concatenate([[0.0], np.cumsum(seg)])
        for d in np.arange(columns * 0.5, dist[-1], columns):
            j = int(np.searchsorted(dist, d) - 1)
            t = (d - dist[j]) / max(seg[j], 1e-9)
            q = back[j] + (back[j + 1] - back[j]) * t
            post(mesh, "metal", q, y_ground - 1.0, y_back - 0.2, 0.6, STEEL)


def covered_stand(site, mesh, ring, height, roof_height, roof_colour, seats=SEATS, overhang=2.5):
    """A straight grandstand over a map footprint, facing the track, with a roof on columns
    along its back and a back wall up to the roof."""
    ring = sg.oriented(sg.clean_ring(ring), True)
    c = ring.mean(axis=0)
    toward = site.toward_track(c)
    g = float(site.ground.height(ring[:, 0], ring[:, 1]).min())
    sg.grandstand(mesh, ring, toward, g, g - 1.5, height, seats, False)
    back = sg.stand_axis(ring, toward)
    along = np.array([-back[1], back[0]])
    t, a = ring @ back, ring @ along
    f0 = along * a.min() + back * (t.min() - overhang)
    f1 = along * a.max() + back * (t.min() - overhang)
    b0 = along * a.min() + back * t.max()
    b1 = along * a.max() + back * t.max()
    canopy(mesh, [f0, f1], [b0, b1], g + roof_height + 1.0, g + roof_height, roof_colour,
           (roof_colour[0] * 0.8, roof_colour[1] * 0.8, roof_colour[2] * 0.8, 0.0), 12.0, g)
    mesh.face("concrete", [p3(b0, g + height), p3(b1, g + height), p3(b1, g + roof_height), p3(b0, g + roof_height)],
              np.array([back[0], 0.0, back[1]]), CONCRETE, g)
    mesh.face("concrete", [p3(b0, g + height), p3(b1, g + height), p3(b1, g + roof_height), p3(b0, g + roof_height)],
              -np.array([back[0], 0.0, back[1]]), CONCRETE, g)


def dome(mesh, material, cx, cz, rx, rz, yaw, y_eave, rise, colour, segments=24, rings=5):
    """Elliptical dome: a cap of a sphere stretched to half axes rx (along yaw) and rz."""
    c, s = math.cos(yaw), math.sin(yaw)
    centre = np.array([cx, y_eave - rise, cz])

    def pt(k, j):
        f = k / rings                       # 0 at the eave, 1 at the crown
        r = math.cos(f * math.pi / 2.0)
        ang = 2.0 * math.pi * j / segments
        lx, lz = rx * r * math.cos(ang), rz * r * math.sin(ang)
        return np.array([cx + lx * c - lz * s, y_eave + rise * math.sin(f * math.pi / 2.0), cz + lx * s + lz * c])

    for k in range(rings):
        for j in range(segments):
            quad = [pt(k, j), pt(k, j + 1), pt(k + 1, j + 1), pt(k + 1, j)]
            if k == rings - 1:
                quad = quad[:3]
            mesh.face(material, quad, None, colour, away_from=centre)


# ----------------------------------------------------------------------------- models
def foro_sol(site):
    """The stadium. Ways 377679562 (north arm and the west stand north of the passage) and
    1315400018 (the rest) are the roof outlines; their inner edges are the front rows.
    Heights: 40 rows from 3 m (the wall of the old baseball field) to 23 m; roof 30 m at the
    back rising to 33 m over the front rows (estimates from photographs of the 2024 roof)."""
    n = site.ring(377679562, closed=True)
    s = site.ring(1315400018, closed=True)
    # (inner vertex, outer vertex) pairs, from the east end of the north arm round the west
    # stand to the east end of the south arm. The outer corners are arcs, the inner ones
    # square: the arc points fan out from the inner corner.
    north = [(13, 0), (12, 1)] + [(12, k) for k in (2, 3, 4)] + [(11, k) for k in (5, 6, 7, 8)] + [(10, 9)]
    south = [(10, 9), (11, 8)] + [(11, k) for k in (7, 6, 5)] + [(12, k) for k in (4, 3, 2, 1)] + [(13, 0)]
    ni, no = np.array([n[a] for a, _ in north]), np.array([n[b] for _, b in north])
    si, so = np.array([s[a] for a, _ in south]), np.array([s[b] for _, b in south])
    m = Model(site, "foro_sol", 0.5 * (ni[-1] + si[0]))
    g = min(site.height(*ni[-1]), site.height(*si[0]), site.road_y(3985.0))
    front, top, clear = 3.0, 23.0, 7.5
    bowl(m.mesh, ni, no, g, front, top, SEATS)
    bowl(m.mesh, si, so, g, front, top, SEATS)
    # The passage: the upper rows bridge it (way 1315400019, 27 m wide, 20 m of track).
    gi, go = np.array([ni[-1], si[0]]), np.array([no[-1], so[0]])
    bowl(m.mesh, gi, go, g, front, top, SEATS, clear=clear, ends=(False, False))
    # Roof: one membrane round the whole U, 4 m out over the front rows.
    inner = np.concatenate([ni, si])
    outer = np.concatenate([no, so])
    d = inner - outer
    lip = inner + d / np.hypot(d[:, 0], d[:, 1])[:, None] * 4.0
    canopy(m.mesh, lip, outer, g + 33.0, g + 30.0, TERRACOTTA, MEMBRANE_UNDER, 14.0, g, fascia=1.6)
    # Masts of the roof along the top row, and the end frames of the two arms.
    for q in (ni[0], si[-1]):
        post(m.mesh, "metal", q, g, g + 33.0, 0.9, STEEL)
    return m


def pit_straight(site):
    m = Model(site, "pit_straight", site.at(150.0, 0.0))
    mesh = m.mesh
    # ---- pit building: garages on the ground floor, two glazed floors, a flat red roof.
    ring = sg.oriented(site.ring(377679570), True)
    g = float(site.ground.height(ring[:, 0], ring[:, 1]).min())
    h = 13.0    # three levels (OSM building:levels) at 4.3 m: garages 4.5 m high
    sg.prism(mesh, ring, [], g - 1.5, g + h, "building_wall", "building_roof", SEASHELL, INDIAN_RED, g)
    # The front is the longest edge that faces the track.
    edge = max(range(len(ring)), key=lambda k: float(np.hypot(*(ring[(k + 1) % len(ring)] - ring[k]))))
    a, b = ring[edge], ring[(edge + 1) % len(ring)]
    length = float(np.hypot(*(b - a)))
    along = (b - a) / length
    out = site.toward_track(0.5 * (a + b))
    out3 = np.array([out[0], 0.0, out[1]])
    bay = 6.3
    for k in range(int(length // bay)):
        q0 = a + along * (k * bay + 0.6) + out * 0.08
        q1 = a + along * ((k + 1) * bay - 0.6) + out * 0.08
        mesh.face("metal", [p3(q0, g), p3(q1, g), p3(q1, g + 4.0), p3(q0, g + 4.0)], out3, DARK, g)
    q0, q1 = a + out * 0.08, b + out * 0.08
    mesh.face("building_glass", [p3(q0, g + 5.0), p3(q1, g + 5.0), p3(q1, g + 12.2), p3(q0, g + 12.2)], out3,
              (0.20, 0.26, 0.30, 1.0), g)
    # Roof terrace canopy over the front (the white strips of the aerial view).
    canopy(mesh, [a + out * 3.0, b + out * 3.0], [a - out * 6.0, b - out * 6.0], g + h + 3.6, g + h + 3.2,
           WHITE_ROOF, GREY_ROOF, 12.0, g + h + 1.0)
    # ---- main grandstands opposite the pits (white roofs), ways 736211980, 377679571,
    # 377679572: 17 m deep, 20 rows to about 11 m, roof at 16 m.
    for osm in (736211980, 377679571, 377679572):
        covered_stand(site, mesh, site.ring(osm), 11.0, 16.0, WHITE_ROOF)
    # ---- hospitality suites round the outside of the Peraltada (six white-roofed blocks).
    for osm in (999255082, 999255083, 999255084, 999255085, 999255086, 999255087):
        r = sg.oriented(site.ring(osm), True)
        gg = float(site.ground.height(r[:, 0], r[:, 1]).min())
        sg.prism(mesh, r, [], gg - 1.5, gg + 7.5, "building_glass", "building_roof", (0.22, 0.27, 0.30, 1.0),
                 WHITE_ROOF, gg)
    # ---- start-light gantry: 20 m past pole (aerial view: a truss from the left wall
    # over the track and the pit lane, s = 250 to 258).
    s_g = 252.0
    y = site.road_y(s_g)
    half = 0.5 * float(site.width[site.index(s_g)])
    feet = [site.at(s_g, -half - 2.6), site.at(s_g, half + 1.6), site.at(s_g, half + 16.5)]
    for q in feet:
        post(mesh, "metal", q, y - 0.5, y + 7.6, 0.5, STEEL)
    for dy in (6.4, 7.6):
        beam(mesh, "metal", p3(feet[0], y + dy), p3(feet[2], y + dy), 0.35, 0.35, STEEL)
    for t in np.linspace(0.0, 1.0, 13):
        q = feet[0] + (feet[2] - feet[0]) * t
        post(mesh, "metal", q, y + 6.2, y + 7.4, 0.18, STEEL)
    # The five light panels hang over the middle of the track, facing the grid.
    back_dir = -site.tan[site.index(s_g)]
    yaw = math.atan2(site.right[site.index(s_g)][1], site.right[site.index(s_g)][0])
    c = site.at(s_g, 0.0) + back_dir * 0.4
    obox(mesh, "metal", (c[0], y + 5.6, c[1]), (3.2, 0.55, 0.2), yaw, DARK)
    return m


def straight_stands(site):
    """Ways 1212660336 and 1212660337 (leisure=bleachers): two roofed stands, 180 m in all,
    10 m deep, on the left between 665 and 845 m."""
    m = Model(site, "straight_stands", site.at(755.0, -20.0))
    for osm in (1212660336, 1212660337):
        covered_stand(site, m.mesh, site.ring(osm), 6.5, 9.5, (0.55, 0.56, 0.56, 0.0), overhang=1.5)
    return m


def horquilla_stand(site):
    """Way 1309442839 (mapped as building=yes): the white-roofed grandstand along the outside
    of Turns 5 and 6, 230 m by 28 m; 32 rows to 16 m, roof at 20 m."""
    ring = site.ring(1309442839)
    m = Model(site, "horquilla_stand", ring.mean(axis=0))
    covered_stand(site, m.mesh, ring, 16.0, 20.0, WHITE_ROOF, overhang=3.0)
    return m


def palacio_deportes(site):
    """Palacio de los Deportes (1968, Félix Candela): the dome spans 134 m in the map
    (way 1527624820) on a ring of concrete V supports; the crown is about 45 m above the
    ground (the arena's own figures give a 160 m roof including the overhang)."""
    r = site.ring(1527624820)
    c = r.mean(axis=0)
    radius = float(np.hypot(*(r - c).T).mean())
    m = Model(site, "palacio_deportes", c)
    g = site.height(*c)
    drum = sg.ngon(c[0], c[1], radius * 0.96, 24)
    sg.prism(m.mesh, drum, [], g - 1.5, g + 16.0, "concrete", "concrete", (0.46, 0.38, 0.32, 0.0),
             (0.46, 0.38, 0.32, 0.0), g)
    dome(m.mesh, "building_roof", c[0], c[1], radius * 1.08, radius * 1.08, 0.0, g + 15.0, 30.0, COPPER, 24, 5)
    return m


def velodromo(site):
    """Velódromo Olímpico Agustín Melgar: the 2000s roof is an ellipse of 119 m by 75 m in
    the map (way 377679564), turquoise, about 20 m high at the crown."""
    r = site.ring(377679564)
    c = r.mean(axis=0)
    d = r - c
    # Long axis from the footprint's own spread.
    w, v = np.linalg.eigh(np.cov(d.T))
    major = v[:, 1]
    yaw = math.atan2(major[1], major[0])
    rx = float(np.abs(d @ major).max())
    rz = float(np.abs(d @ v[:, 0]).max())
    m = Model(site, "velodromo", c)
    g = site.height(*c)
    ell = np.array([c + major * rx * 0.97 * math.cos(a) + v[:, 0] * rz * 0.97 * math.sin(a)
                    for a in np.linspace(0.0, 2.0 * math.pi, 24, endpoint=False)])
    sg.prism(m.mesh, ell, [], g - 1.5, g + 8.0, "concrete", "concrete", CONCRETE, CONCRETE, g)
    dome(m.mesh, "building_roof", c[0], c[1], rx * 1.03, rz * 1.03, yaw, g + 7.5, 12.5, TURQUOISE, 24, 4)
    return m


def main():
    site = Site()
    print(f"landmarks of {TRACK_ID} -> {os.path.join(OUT, 'landmarks')}")
    os.makedirs(os.path.join(OUT, "landmarks"), exist_ok=True)
    entries = [build(site).write() for build in (foro_sol, pit_straight, straight_stands, horquilla_stand,
                                                 palacio_deportes, velodromo)]
    with open(os.path.join(OUT, "landmarks.json"), "w", encoding="utf-8") as f:
        json.dump(entries, f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
