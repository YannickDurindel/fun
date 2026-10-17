"""Landmarks of the Circuit de la Sarthe, survey version (wec_le_mans_survey): the hero buildings
and bridges beside and over the lap, written as low-poly GLBs with the scenery material names.

    .venv/bin/python tools/track/landmarks/wec_le_mans_survey.py        (from fun-racer/)

Run it AFTER tools/track/build_track.py wec_le_mans_survey: it reads the built track.json (road
heights, widths), road_profile.json (bank) and the trackside table
scripts/track/trackside_layouts/wec_le_mans_survey.gd when there is one (only to check that
nothing stands on the track side of the barriers; without a table the automatic layout's
straight distance is used), and writes assets/tracks/wec_le_mans_survey/landmarks/*.glb, their
.import files and assets/tracks/wec_le_mans_survey/landmarks.json. Run it again when any of those
change.

Every model is placed with an "s" anchor (a point of the lap, at road height, yaw 0) and is
written in the frame of that anchor, so it follows the road however the terrain is off beside
it. Every model comes twice: <name>.glb, drawn up to LOD_DISTANCE from the camera, and
<name>_far.glb, a simplified shell drawn beyond it. The switch is the visibility range of the
mesh nodes, set in the .import files this script writes (Godot scene import, node options
mesh_instance/visibility_range_*), so the runtime (scripts/track/scenery.gd) needs nothing new.

Where the shapes come from (all IGN, Licence Ouverte 2.0; read with lib/lidar.Frame in the track
frame: x east, z -north, metres from the finish line, heights relative to it):
  * footprints: BD TOPO "batiment" polygons (simplified to 0.6 m), the ids are noted below;
  * heights: LiDAR HD 2021-22 classified points (class 6 building, 17 bridge, 1 unclassified for
    the steel footbridges), median of the roof points above the median of the ground points
    (class 2) around the footprint; profiles across the footprints give the slope of the roofs;
  * placement and anything the two above miss (the drum of the race control tower, the garage
    doors, the stand on the roof of the pits): the BD ORTHO 20 cm orthophoto and Wikimedia
    Commons photographs (Le Mans Race Control, 24h du Mans pit lane, The Dunlop Bridge,
    Passerelle Dunlop / Porsche), looked at only.
What a model shows that the data cannot (window bands, colours, the tread of the tyre arch)
is an estimate from those photographs. No brand names or logos: sign faces carry plain colours.

  * the pits complex: the pit building (Tribune, BD TOPO batiment.2193060: 245 x 21 m, its roof
    19.4 m above the ground over the pit lane and 21.7 m at the back), garages below, two glass
    floors, the open stand on its roof; the race control tower (batiment.47923382, 21.5 m);
  * the covered grandstands of the pit straight and the run to Dunlop, left of the lap (eleven
    BD TOPO Tribunes and stands with flat roofs 9.5 to 22 m high, among them the main grandstand
    opposite the pits, batiment.2193058);
  * the Dunlop curve grandstand (batiment.2193223) and the Dunlop bridge: the tyre arch over
    the crest after the Dunlop chicane (lidar: a 62 m span, crown 12.6 m above the ground, 7 m
    deep) with the walkway under it;
  * the footbridges over the pit straight (s = 185) and over the exit of the Esses towards
    Tertre Rouge (s = 1780): deck heights, widths, spans and directions from the lidar points.
    The lidar shows eight more over the lap (s = 7270, 8525, 9090, 9970, 10375, 11850, 12770 and
    13000: 2-4.5 m wide decks 6.5-8.6 m above the road); they are not modelled (yet).
"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "cad" / "track"))
import scenery_glb as sg  # noqa: E402

TRACK_ID = "wec_le_mans_survey"
TRACK = ROOT / "assets" / "tracks" / TRACK_ID
OUT = TRACK / "landmarks"
LAYOUT = ROOT / "scripts" / "track" / "trackside_layouts" / f"{TRACK_ID}.gd"
AUTO_BARRIER_STRAIGHT = 3.5   # scripts/track/trackside_layout.gd AUTO_TUNING for this track
LOD_DISTANCE = 300.0          # m from the camera: the near model up to here, the far one beyond
LOD_MARGIN = 10.0             # hysteresis of the switch
GENERATOR = "tools/track/landmarks/wec_le_mans_survey.py"

# Linear vertex colours (the scenery materials take their colour from them; alpha = 1 on
# facades whose shader draws windows).
WHITE = (1.0, 1.0, 1.0, 0.0)
SEATS = (1.0, 1.0, 1.0, 1.0)
STEEL = (0.30, 0.31, 0.33, 0.0)
DARK = (0.025, 0.025, 0.03, 0.0)
CONCRETE = (0.45, 0.44, 0.42, 0.0)
PALE = (0.62, 0.62, 0.60, 0.0)              # rendered walls of the pits
WALL_WINDOWS = (0.70, 0.70, 0.68, 1.0)
GLASS = (0.55, 0.60, 0.66, 1.0)
ROOF = (0.55, 0.56, 0.57, 0.0)              # light grey steel roofs of the stands
ROOF_DARK = (0.16, 0.17, 0.19, 0.0)
TYRE = (0.035, 0.037, 0.040, 0.0)
TYRE_TREAD = (0.020, 0.021, 0.024, 0.0)
SIDEWALL = (0.07, 0.075, 0.08, 0.0)
YELLOW = (0.80, 0.56, 0.02, 0.0)
SIGN_BLUE = (0.02, 0.07, 0.30, 0.0)         # fictional sign faces of the footbridges
SIGN_GREEN = (0.02, 0.20, 0.08, 0.0)
SIGN_RED = (0.40, 0.03, 0.03, 0.0)


class Lap:
    """The built centreline: positions, tangents and widths by distance."""

    def __init__(self):
        t = json.loads((TRACK / "track.json").read_text())
        self.length = float(t["length"])
        self.step = float(t["step"])
        self.p = np.array([q["p"] for q in t["points"]], dtype=np.float64)
        self.s = np.array([q["s"] for q in t["points"]], dtype=np.float64)
        self.width = np.array([q["width"] for q in t["points"]], dtype=np.float64)
        self.n = len(self.p)
        self.barrier_straight = AUTO_BARRIER_STRAIGHT
        if LAYOUT.exists():
            m = re.search(r"const BARRIER_STRAIGHT: float = ([0-9.]+)", LAYOUT.read_text())
            if m:
                self.barrier_straight = float(m.group(1))

    def _i(self, s):
        u = (s % self.length) / self.step
        i = int(math.floor(u)) % self.n
        return i, (i + 1) % self.n, u - math.floor(u)

    def pos(self, s):
        i, j, f = self._i(s)
        return self.p[i] + (self.p[j] - self.p[i]) * f

    def tangent(self, s):
        d = self.pos(s + self.step) - self.pos(s - self.step)
        return np.array([d[0], d[2]]) / math.hypot(d[0], d[2])

    def half_width(self, s):
        i, j, f = self._i(s)
        return 0.5 * (self.width[i] + (self.width[j] - self.width[i]) * f)

    def nearest(self, x, z):
        """(s, distance) of the lap point nearest to world (x, z)."""
        d = (self.p[:, 0] - x) ** 2 + (self.p[:, 2] - z) ** 2
        k = int(np.argmin(d))
        return float(self.s[k]), math.sqrt(float(d[k]))

    def crossing(self, centre, axis, s_hint, reach=60.0):
        """s where the lap crosses the line through `centre` along `axis` (world x, z), searched
        within `reach` of s_hint, and the distance along the axis from `centre` to it."""
        c, a = np.asarray(centre, float), np.asarray(axis, float)
        nrm = np.array([-a[1], a[0]])
        best = None
        for s in np.arange(s_hint - reach, s_hint + reach, 0.25):
            p = self.pos(s)
            off = abs((np.array([p[0], p[2]]) - c) @ nrm)
            if best is None or off < best[0]:
                best = (off, s, float((np.array([p[0], p[2]]) - c) @ a))
        return best[1] % self.length, best[2]


class Anchor:
    """The frame the runtime gives a landmark placed with {"s": s, "dist": 0} and yaw 0
    (scripts/track/scenery.gd, _landmark_transform): origin on the road centre at s, local -Z
    along the lap. Every builder below works in it through `pt` / `vec`."""

    def __init__(self, lap: Lap, s: float):
        self.s = round(float(s) % lap.length, 1)
        self.origin = lap.pos(self.s)
        f = lap.tangent(self.s)
        self.theta = math.atan2(-f[0], -f[1])

    def local(self, w):
        w = np.asarray(w, dtype=np.float64)
        d = w - self.origin
        c, s = math.cos(self.theta), math.sin(self.theta)
        return np.stack([d[..., 0] * c - d[..., 2] * s, d[..., 1], d[..., 0] * s + d[..., 2] * c], axis=-1)

    def pt(self, x, z, y):
        """World (x, z) at track-frame height y -> model point."""
        return self.local(np.array([x, y, z], dtype=np.float64))

    def xz(self, x, z):
        return self.pt(x, z, self.origin[1])[[0, 2]]

    def vec(self, dx, dz):
        """World horizontal direction -> model (x, z), unit length."""
        c, s = math.cos(self.theta), math.sin(self.theta)
        v = np.array([dx * c - dz * s, dx * s + dz * c])
        return v / np.linalg.norm(v)

    def entry(self, model):
        return {"model": model, "at": {"s": self.s, "side": 1, "dist": 0.0}, "yaw_deg": 0.0}


def new_mesh():
    """One node (chunk_0_0) for the whole model, whatever its size."""
    m = sg.SceneryMesh(-1.0e5, -1.0e5, 2.0e5)
    m.anchor(0.0, 0.0)
    return m


UP = np.array([0.0, 1.0, 0.0])


def hexa(mesh, material, bottom, top, colour, side_colour=None, side_dir=None, skip_bottom=False):
    """A six-faced solid from four bottom and four top corners (model x, y, z, same order round
    the solid). Faces whose normal runs along `side_dir` (model x, z) get `side_colour`."""
    b, t = np.asarray(bottom, float), np.asarray(top, float)
    centre = 0.5 * (b.mean(axis=0) + t.mean(axis=0))
    faces = [[b[0], b[1], b[2], b[3]], [t[0], t[1], t[2], t[3]]]
    for k in range(4):
        j = (k + 1) % 4
        faces.append([b[k], b[j], t[j], t[k]])
    for f_i, f in enumerate(faces):
        if f_i == 0 and skip_bottom:
            continue
        col = colour
        if side_colour is not None and f_i >= 2:
            f3 = np.asarray(f)
            n = np.cross(f3[1] - f3[0], f3[2] - f3[0])
            n2 = np.array([n[0], n[2]])
            if np.linalg.norm(n2) > 1e-9 and abs(n2 @ side_dir) / np.linalg.norm(n2) > 0.8:
                col = side_colour
        mesh.face(material, f, None, col, float(b[:, 1].min()), away_from=centre)


def obox(mesh, material, c, e, half_e, half_n, y0, y1, colour, **kw):
    """A box of plan centre c (model x, z), long axis e (unit), half sizes along e and across."""
    c, e = np.asarray(c, float), np.asarray(e, float)
    n = np.array([-e[1], e[0]])
    ring = [c - e * half_e - n * half_n, c + e * half_e - n * half_n, c + e * half_e + n * half_n,
            c - e * half_e + n * half_n]
    hexa(mesh, material, [[p[0], y0, p[1]] for p in ring], [[p[0], y1, p[1]] for p in ring], colour, **kw)


def slab(mesh, material, top, thickness, colour):
    """A plate under the four top corners `top` (model x, y, z)."""
    top = np.asarray(top, float)
    hexa(mesh, material, top - UP * thickness, top, colour)


def frustum(mesh, material, c, r0, r1, y0, y1, colour, sides=14, caps=True):
    """A cone frustum (radius r0 at y0, r1 at y1) round plan point c."""
    ang = np.arange(sides) * (2.0 * math.pi / sides)
    lo = [np.array([c[0] + r0 * math.cos(a), y0, c[1] + r0 * math.sin(a)]) for a in ang]
    hi = [np.array([c[0] + r1 * math.cos(a), y1, c[1] + r1 * math.sin(a)]) for a in ang]
    axis = np.array([c[0], 0.5 * (y0 + y1), c[1]])
    for k in range(sides):
        j = (k + 1) % sides
        mesh.face(material, [lo[k], lo[j], hi[j], hi[k]], None, colour, y0, away_from=axis)
    if caps:
        mesh.face(material, hi, UP, colour)
        mesh.face(material, lo, -UP, colour)


# ----------------------------------------------------------------------------- footprints
class Rect:
    """The oriented rectangle of a footprint (world x, z): centre, long axis e, half length,
    half depth, and `n` the unit normal of its long side that faces the lap."""

    def __init__(self, lap: Lap, ring):
        r = np.asarray(ring, dtype=np.float64)
        self.c = r.mean(axis=0)
        _, _, vt = np.linalg.svd(r - self.c, full_matrices=False)
        e = vt[0]
        n = np.array([-e[1], e[0]])
        te, tn = (r - self.c) @ e, (r - self.c) @ n
        self.c = self.c + e * 0.5 * (te.max() + te.min()) + n * 0.5 * (tn.max() + tn.min())
        self.half_e = 0.5 * (te.max() - te.min())
        self.half_n = 0.5 * (tn.max() - tn.min())
        s, _ = lap.nearest(*self.c)
        p = lap.pos(s)
        if (np.array([p[0], p[2]]) - self.c) @ n < 0.0:
            n = -n
        self.e, self.n = e, n
        self.s = s

    def front(self, k):
        """World point on the front (lap side) edge, k in [-1, 1] along it."""
        return self.c + self.n * self.half_n + self.e * self.half_e * k

    def corners(self, front_out=0.0, back_out=0.0, end_out=0.0):
        e, n = self.e * (self.half_e + end_out), self.n
        f, b = self.half_n + front_out, -self.half_n - back_out
        return [self.c - e + n * b, self.c + e + n * b, self.c + e + n * f, self.c - e + n * f]


def model_ring(a: Anchor, pts):
    return np.array([a.xz(*p) for p in pts])


def covered_stand(mesh, a: Anchor, rect: Rect, ground, roof, lod, columns=True):
    """A grandstand under a flat roof: rows from the front edge (lap side) up to 4.5 m under
    the roof, a back wall, the roof sticking out 2.5 m over the front row on slim columns.
    `ground` is the track-frame y of the ground, `roof` the height of the roof top above it."""
    top = max(roof - 4.5, 3.0)
    y_roof = ground + roof - a.origin[1]
    g = ground - a.origin[1]
    n_m = a.vec(*rect.n)
    ring = model_ring(a, rect.corners())
    if lod == 0:
        sg.grandstand(mesh, ring, n_m, g, g - 3.0, top, SEATS)
        back = model_ring(a, rect.corners(back_out=0.4, front_out=-2.0 * rect.half_n))
        hexa(mesh, "stand_structure", [[p[0], g - 3.0, p[1]] for p in back],
             [[p[0], y_roof - 0.4, p[1]] for p in back], PALE)
        if columns:
            count = max(2, int(round(2.0 * rect.half_e / 12.0)) + 1)
            e_m = a.vec(*rect.e)
            for k in np.linspace(-0.97, 0.97, count):
                c = a.xz(*(rect.front(k) + rect.n * 0.6))
                obox(mesh, "metal", c, e_m, 0.15, 0.15, g, y_roof - 0.4, STEEL)
    else:
        wedge_b = model_ring(a, rect.corners())
        lo = [[p[0], g - 3.0, p[1]] for p in wedge_b]
        hi = [[p[0], g + (top if k < 2 else 1.2), p[1]] for k, p in enumerate(wedge_b)]
        hexa(mesh, "stand_structure", lo, hi, PALE)
    roof_ring = model_ring(a, rect.corners(front_out=2.5, back_out=0.4, end_out=0.3))
    slab(mesh, "building_roof", [[p[0], y_roof, p[1]] for p in roof_ring], 0.4, ROOF)


# ----------------------------------------------------------------------------- the pits
PIT_BUILDING = [[23.9, -44.2], [45.5, -43.4], [52.3, -287.7], [37.2, -287.2], [36.9, -279.7], [31.7, -279.7]]
PIT_GROUND = 1.7                  # track-frame y of the ground at the pit building (lidar)
PIT_ROOF_FRONT, PIT_ROOF_BACK = 19.4, 21.7
RACE_CONTROL = [[27.0, 26.3], [31.1, 26.0], [36.0, 24.0], [39.2, 21.4], [45.0, 10.2], [45.3, 2.7],
                [43.3, 2.7], [43.3, -7.3], [47.5, -27.2], [41.4, -27.5], [41.4, -30.5], [39.8, -30.4],
                [39.7, -35.1], [33.9, -32.4], [33.4, -27.9], [26.5, -28.0], [25.1, 2.1], [22.9, 2.1],
                [22.7, 8.1], [24.2, 13.8], [27.5, 17.3]]
RACE_CONTROL_GROUND = 0.0
DRUM = (34.0, 13.5)               # plan centre of the glass drum (orthophoto: the round nose)


def pits(lap: Lap, a: Anchor, lod):
    m = new_mesh()
    r = Rect(lap, PIT_BUILDING)
    g = PIT_GROUND - a.origin[1]
    e_m, n_m = a.vec(*r.e), a.vec(*r.n)
    floors = 12.5
    body = model_ring(a, r.corners())
    # Garages (5 m), two glass floors of hospitality, the stand on the roof.
    if lod == 0:
        hexa(m, "building_wall", [[p[0], g - 3.0, p[1]] for p in body], [[p[0], g + 5.0, p[1]] for p in body],
             PALE, skip_bottom=True)
        bays = int(2.0 * r.half_e / 4.3)
        for k in range(bays):
            t = -1.0 + (k + 0.5) * 2.0 / bays
            c = a.xz(*(r.front(t) + r.n * 0.06))
            obox(m, "concrete", c, e_m, 1.75, 0.06, g, g + 4.0, DARK)
        glass = model_ring(a, r.corners(front_out=0.3))
        hexa(m, "building_glass", [[p[0], g + 5.0, p[1]] for p in glass], [[p[0], g + floors, p[1]] for p in glass],
             GLASS)
        stand = model_ring(a, r.corners(front_out=-0.8, back_out=-2.5))
        sg.grandstand(m, stand, n_m, g + floors, g + floors - 0.5, 5.6, SEATS)
        back = model_ring(a, r.corners(front_out=-2.0 * r.half_n + 2.5))
        hexa(m, "building_wall", [[p[0], g + floors, p[1]] for p in back],
             [[p[0], g + PIT_ROOF_BACK - 0.5, p[1]] for p in back], WALL_WINDOWS)
        for k in np.linspace(-0.985, 0.985, 11):
            c = a.xz(*(r.front(k) - r.n * 0.5))
            obox(m, "metal", c, e_m, 0.2, 0.2, g + floors, g + PIT_ROOF_FRONT - 0.45, STEEL)
        for k in (-1.0, 1.0):     # end walls of the roof stand
            c = a.xz(*(r.c + r.e * r.half_e * k - r.e * 0.2 * k - r.n * 1.0))
            obox(m, "stand_structure", c, n_m, r.half_n - 1.0, 0.2, g + floors, g + PIT_ROOF_FRONT - 1.0, PALE)
    else:
        hexa(m, "building_glass", [[p[0], g - 3.0, p[1]] for p in body], [[p[0], g + floors, p[1]] for p in body],
             GLASS, skip_bottom=True)
        hexa(m, "stand_structure", [[p[0], g + floors, p[1]] for p in body],
             [[p[0], g + (floors + 3.0 if k >= 2 else PIT_ROOF_BACK - 1.0), p[1]] for k, p in enumerate(body)], PALE)
    roof = model_ring(a, r.corners(front_out=3.0, end_out=0.4))
    slab(m, "building_roof", [[p[0], g + (PIT_ROOF_FRONT if k >= 2 else PIT_ROOF_BACK), p[1]] for k, p in enumerate(roof)],
         0.5, ROOF)

    # Race control: the block behind (to the roof of the second floor) and the glass drum of
    # three tiers that widen upwards, on a concrete base.
    gc = RACE_CONTROL_GROUND - a.origin[1]
    ring = sg.oriented(sg.clean_ring(model_ring(a, RACE_CONTROL)), True)
    sg.prism(m, ring, [], gc - 2.0, gc + 15.5, "building_wall", "building_roof", WALL_WINDOWS, ROOF_DARK, gc)
    c = a.xz(*DRUM)
    sides = 16 if lod == 0 else 8
    frustum(m, "concrete", c, 8.5, 8.5, gc - 1.0, gc + 8.0, PALE, sides)
    if lod == 0:
        for y0, y1, r0, r1 in ((8.0, 11.4, 9.6, 11.0), (12.1, 15.6, 10.0, 11.5), (16.3, 19.7, 10.6, 12.1)):
            frustum(m, "building_glass", c, r0, r1, gc + y0, gc + y1, GLASS, sides, caps=False)
            frustum(m, "metal", c, r1 + 0.3, r1 + 0.3, gc + y1, gc + y1 + 0.7, WHITE, sides)
        frustum(m, "metal", c, 12.5, 12.5, gc + 19.7, gc + 20.6, WHITE, sides)
        frustum(m, "metal", c, 6.0, 5.0, gc + 20.6, gc + 21.5, STEEL, sides)
    else:
        frustum(m, "building_glass", c, 9.6, 12.1, gc + 8.0, gc + 20.6, GLASS, sides)
    return m


# Covered grandstands left of the pit straight and on the run to Dunlop: BD TOPO footprint,
# ground (track-frame y, lidar), roof top above the ground (lidar median of the roof points).
STANDS_PIT = [
    ("batiment.2193045", [[-41.7, -5.1], [-30.1, -4.9], [-29.4, -35.1], [-41.0, -35.3]], 1.16, 12.2),
    ("batiment.2193044", [[-40.3, -43.9], [-29.1, -43.6], [-28.0, -101.6], [-39.2, -101.8]], 2.72, 11.1),
    ("batiment.2193047", [[-29.5, -112.0], [-28.5, -169.7], [-39.6, -169.9], [-40.6, -112.2]], 2.82, 12.4),
]
STANDS_MAIN = [
    # the main grandstand opposite the pits, flat roof 21.7 m above the ground
    ("batiment.2193058", [[-45.3, -252.7], [-47.0, -190.1], [-34.1, -189.6], [-34.3, -186.2], [-25.3, -187.7],
                          [-23.8, -189.2], [-23.6, -235.1], [-22.0, -252.7]], 4.55, 21.7),
    ("batiment.2193059", [[-22.8, -253.4], [-21.7, -299.5], [-34.5, -300.1], [-36.0, -253.9]], 6.63, 11.7),
]
STANDS_NORTH = [
    ("batiment.17447897", [[-17.1, -356.3], [-31.7, -357.0], [-30.3, -397.6], [-15.2, -396.8]], 8.18, 9.8),
    ("batiment.344901", [[-10.6, -444.8], [-26.5, -446.0], [-29.5, -405.2], [-14.0, -403.5]], 8.95, 10.0),
    ("batiment.2193061", [[-21.6, -452.7], [-12.1, -451.9], [-9.7, -477.2], [-19.2, -478.1]], 10.15, 9.6),
    ("batiment.40374312", [[-24.0, -496.6], [-8.9, -495.3], [-4.9, -535.5], [-19.7, -537.1]], 10.71, 10.0),
    ("batiment.40374139", [[-14.2, -551.1], [0.8, -549.7], [4.6, -590.2], [-10.2, -591.5]], 11.78, 9.5),
]
# The Dunlop curve grandstand, outside the curve (roof 10.5 m).
STANDS_DUNLOP = [
    ("batiment.2193223", [[197.4, -815.4], [239.6, -856.0], [231.9, -863.9], [189.8, -823.4]], 27.04, 10.5),
]


def stands(lap: Lap, a: Anchor, table, lod):
    m = new_mesh()
    for _, ring, ground, roof in table:
        covered_stand(m, a, Rect(lap, ring), ground, roof, lod)
    return m


# ----------------------------------------------------------------------------- Dunlop bridge
# The tyre arch: its axis on the lidar from ARCH_A towards ARCH_B (world x, z); along it the
# arch stands from t = 4 to 66 m, crown 12.6 m above the ground at t = 35; it is 7 m deep with
# its middle 1.5 m to the left of the axis line (seen from A).
ARCH_A, ARCH_B = (350.0, -917.5), (378.75, -867.5)
ARCH_T0, ARCH_T1, ARCH_CROWN, ARCH_DEPTH, ARCH_SHIFT = 4.0, 66.0, 12.6, 7.0, 1.5
ARCH_GROUND = 82.4               # m IGN69 under the arch
ARCH_THICK = 2.6                 # radial thickness of the tyre


def dunlop_bridge(lap: Lap, a: Anchor, crossing_t, lod):
    m = new_mesh()
    A, B = np.array(ARCH_A), np.array(ARCH_B)
    u = (B - A) / np.linalg.norm(B - A)
    nrm = np.array([-u[1], u[0]])
    g = ARCH_GROUND - lap_origin_elevation() - a.origin[1]
    tc, R = 0.5 * (ARCH_T0 + ARCH_T1), 0.5 * (ARCH_T1 - ARCH_T0)
    seg = 18 if lod == 0 else 8
    th = np.linspace(math.pi, 0.0, seg + 1)
    half = 0.5 * ARCH_DEPTH
    n_m = a.vec(*nrm)

    def ring_pts(t, y):
        base = A + u * t + nrm * ARCH_SHIFT
        return [np.array([*a.xz(*(base - nrm * half))]), np.array([*a.xz(*(base + nrm * half))])]

    for k in range(seg):
        quads = []
        for j in (k, k + 1):
            out_t, out_y = tc + R * math.cos(th[j]), ARCH_CROWN * math.sin(th[j])
            in_t, in_y = tc + (R - ARCH_THICK) * math.cos(th[j]), (ARCH_CROWN - ARCH_THICK) * math.sin(th[j])
            if j in (0, seg):
                out_y = in_y = -2.0
            quads.append(((out_t, out_y), (in_t, in_y)))
        (o0, i0), (o1, i1) = quads
        po0, po1 = ring_pts(o0[0], 0), ring_pts(o1[0], 0)
        pi0, pi1 = ring_pts(i0[0], 0), ring_pts(i1[0], 0)
        bottom = [[*pi0[0][:1], g + i0[1], pi0[0][1]], [pi1[0][0], g + i1[1], pi1[0][1]],
                  [pi1[1][0], g + i1[1], pi1[1][1]], [pi0[1][0], g + i0[1], pi0[1][1]]]
        top = [[po0[0][0], g + o0[1], po0[0][1]], [po1[0][0], g + o1[1], po1[0][1]],
               [po1[1][0], g + o1[1], po1[1][1]], [po0[1][0], g + o0[1], po0[1][1]]]
        tread = TYRE_TREAD if (lod == 0 and k % 2) else TYRE
        hexa(m, "stand_structure", bottom, top, tread, side_colour=SIDEWALL, side_dir=n_m)
    # The walkway under the arch, between two piers beyond the verges, its faces yellow.
    if lod == 0:
        span = 13.0
        for sign in (-1.0, 1.0):
            c = a.xz(*(A + u * (crossing_t + sign * span) + nrm * ARCH_SHIFT))
            obox(m, "concrete", c, a.vec(*u), 1.6, 1.8, g - 2.0, 7.9, PALE)
        c = a.xz(*(A + u * crossing_t + nrm * ARCH_SHIFT))
        obox(m, "metal", c, a.vec(*u), span, 1.8, 5.9, 7.9, YELLOW, side_colour=YELLOW, side_dir=n_m)
        obox(m, "metal", c, a.vec(*u), span, 1.9, 7.9, 8.3, STEEL)
    return m


_ORIGIN_ELEV = None


def lap_origin_elevation():
    global _ORIGIN_ELEV
    if _ORIGIN_ELEV is None:
        _ORIGIN_ELEV = float(json.loads((TRACK / "track.json").read_text())["origin_elevation_m"])
    return _ORIGIN_ELEV


# ----------------------------------------------------------------------------- footbridges
# (s near the crossing, plan centre of the points (x, z), axis, t range of the deck along the
# axis from that centre, underside and top of the deck above the road at the crossing, width,
# sign colour). Lidar class 1 / 6 points 4 to 30 m above the road within 9 m of the lap.
FOOTBRIDGES = [
    (185.0, (21.3, -185.7), (0.989, 0.148), (-37.0, -3.0), 5.2, 6.8, 3.0, SIGN_GREEN),
    (1780.0, (907.9, -1298.5), (-0.641, -0.767), (-20.5, 6.0), 4.7, 6.5, 3.0, SIGN_BLUE),
]
STAIR_RUN = 1.7      # m of stair per m of rise


def footbridge(lap: Lap, a: Anchor, centre, axis, t_range, under, top, width, sign, cross_t, lod):
    """A steel walkway with sign boards on both faces, on a pair of legs at each end beyond the
    road, a stair down from each end along the axis. The span is widened where the points stop
    short of the verges (their ends are hidden by trees)."""
    m = new_mesh()
    c, u = np.asarray(centre, float), np.asarray(axis, float)
    u = u / np.linalg.norm(u)
    tan = lap.tangent(a.s)
    sin = max(abs(u[0] * tan[1] - u[1] * tan[0]), 0.3)
    reach = (lap.half_width(a.s) + lap.barrier_straight + 1.0) / sin
    t0, t1 = min(t_range[0], cross_t - reach), max(t_range[1], cross_t + reach)
    e_m = a.vec(*u)
    mid = a.xz(*(c + u * 0.5 * (t0 + t1)))
    half = 0.5 * (t1 - t0)
    obox(m, "metal", mid, e_m, half, 0.5 * width, under, top, sign, side_colour=sign, side_dir=a.vec(-u[1], u[0]))
    if lod == 0:
        obox(m, "metal", mid, e_m, half + 0.05, 0.5 * width + 0.05, top - 0.25, top, WHITE)
        obox(m, "metal", mid, e_m, half + 0.05, 0.5 * width + 0.05, under, under + 0.2, WHITE)
        nrm = np.array([-u[1], u[0]])
        for t, out in ((t0, -1.0), (t1, 1.0)):
            for side in (-1.0, 1.0):
                p = a.xz(*(c + u * (t - out * 0.4) + nrm * side * (0.5 * width - 0.2)))
                obox(m, "metal", p, e_m, 0.18, 0.18, -2.5, under, STEEL)
            # stair: a sloped flight from the deck end down to the ground, outward along the axis
            run = STAIR_RUN * under
            p0 = c + u * t
            p1 = c + u * (t + out * run)
            w = 0.6 * width
            q = [p0 - nrm * w, p0 + nrm * w, p1 + nrm * w, p1 - nrm * w]
            qm = [a.xz(*p) for p in q]
            yt = [under, under, -0.5, -0.5]
            hexa(m, "metal", [[p[0], y - 0.35, p[1]] for p, y in zip(qm, yt)],
                 [[p[0], y, p[1]] for p, y in zip(qm, yt)], STEEL)
    return m


# ----------------------------------------------------------------------------- output
def import_file(glb: Path, far: bool):
    """The Godot import settings of one model: the defaults of the scene importer and the
    visibility range of its node (near model up to LOD_DISTANCE, far model beyond)."""
    uid = ""
    old = Path(str(glb) + ".import")
    if old.exists():
        mm = re.search(r'^uid="([^"]+)"', old.read_text(), re.M)
        if mm:
            uid = 'uid="%s"\n' % mm.group(1)
    if far:
        node = {"mesh_instance/visibility_range_begin": LOD_DISTANCE,
                "mesh_instance/visibility_range_begin_margin": LOD_MARGIN,
                "mesh_instance/cast_shadow": 0}    # beyond the shadow distance anyway
    else:
        node = {"mesh_instance/visibility_range_end": LOD_DISTANCE,
                "mesh_instance/visibility_range_end_margin": LOD_MARGIN}
    sub = json.dumps({"nodes": {"PATH:chunk_0_0": node}})
    rel = glb.relative_to(ROOT).as_posix()
    return f"""[remap]

importer="scene"
importer_version=1
type="PackedScene"
{uid}
[deps]

source_file="res://{rel}"

[params]

nodes/root_type=""
nodes/root_name=""
nodes/root_script=null
mesh_library/use_node_names_as_mesh_names=false
array_mesh/deduplicate_surfaces=true
nodes/apply_root_scale=true
nodes/root_scale=1.0
nodes/import_as_skeleton_bones=false
nodes/use_name_suffixes=true
nodes/use_node_type_suffixes=true
meshes/ensure_tangents=true
meshes/generate_lods={'false' if far else 'true'}
meshes/create_shadow_meshes=true
meshes/light_baking=1
meshes/lightmap_texel_size=0.2
meshes/force_disable_compression=false
skins/use_named_skins=true
animation/import=false
animation/fps=30
animation/trimming=false
animation/remove_immutable_tracks=true
animation/import_rest_as_RESET=false
import_script/path=""
materials/extract=0
materials/extract_format=0
materials/extract_path=""
_subresources={sub}
gltf/naming_version=2
gltf/embedded_image_handling=1
gltf/texture_map_mode=1
"""


def clearance(lap: Lap, a: Anchor, mesh, name, overhead):
    """Model points that stand on the track side of the barrier line (straight distance) below
    `overhead` metres above the road: printed, so a change of the road or the barriers that
    puts a landmark in the way is seen."""
    pts = []
    for (_, _, _), parts in mesh.parts.items():
        for p in parts:
            pts.append(p[0])
    if not pts:
        return 0
    pts = np.concatenate(pts).astype(np.float64)
    c, s = math.cos(a.theta), math.sin(a.theta)
    wx = a.origin[0] + pts[:, 0] * c + pts[:, 2] * s
    wz = a.origin[2] - pts[:, 0] * s + pts[:, 2] * c
    wy = pts[:, 1] + a.origin[1]
    bad = 0
    sub = lap.p[::2]
    for x, y, z in zip(wx[::3], wy[::3], wz[::3]):
        d = (sub[:, 0] - x) ** 2 + (sub[:, 2] - z) ** 2
        k = int(np.argmin(d))
        s_k = 2 * k * lap.step
        lim = lap.half_width(s_k) + lap.barrier_straight
        if math.sqrt(d[k]) < lim and y < sub[k, 1] + overhead:
            bad += 1
    if bad:
        print(f"  WARNING {name}: {bad} points inside the barrier line", file=sys.stderr)
    return bad


def main():
    lap = Lap()
    OUT.mkdir(parents=True, exist_ok=True)
    entries, report = [], []

    def write(name, build, anchor, overhead=4.0):
        for lod, suffix in ((0, ""), (1, "_far")):
            mesh = build(lod)
            path = OUT / f"{name}{suffix}.glb"
            info = sg.write_glb(path, mesh, name + suffix, GENERATOR)
            Path(str(path) + ".import").write_text(import_file(path, lod == 1))
            entries.append(anchor.entry(name + suffix))
            if lod == 0:
                clearance(lap, anchor, mesh, name, overhead)
                near = info
            else:
                report.append(f"  {name}: {near['triangles']} / {info['triangles']} triangles (near / far), "
                              f"{(near['bytes'] + info['bytes']) // 1024} kB, s = {anchor.s:.0f}")

    s_pits, _ = lap.nearest(35.0, -120.0)
    a = Anchor(lap, s_pits)
    write("pits", lambda lod: pits(lap, a, lod), a)
    for name, table in (("stands_pit", STANDS_PIT), ("stands_main", STANDS_MAIN), ("stands_north", STANDS_NORTH),
                        ("stand_dunlop", STANDS_DUNLOP)):
        c = np.mean([np.mean(r[1], axis=0) for r in table], axis=0)
        a = Anchor(lap, lap.nearest(*c)[0])
        write(name, lambda lod, a=a, table=table: stands(lap, a, table, lod), a)

    A, B = np.array(ARCH_A), np.array(ARCH_B)
    s_x, t_x = lap.crossing(A, (B - A) / np.linalg.norm(B - A), 1045.0)
    a = Anchor(lap, s_x)
    write("dunlop_bridge", lambda lod: dunlop_bridge(lap, a, t_x, lod), a, overhead=5.5)

    for k, (s, centre, axis, t_range, under, top, width, sign) in enumerate(FOOTBRIDGES):
        u = np.asarray(axis, float) / np.linalg.norm(axis)
        s_x, t_x = lap.crossing(centre, u, s)
        a = Anchor(lap, s_x)
        write(f"footbridge_{int(round(s)):05d}",
              lambda lod, a=a, c=centre, u=u, tr=t_range, un=under, tp=top, w=width, sg_=sign, tx=t_x:
              footbridge(lap, a, c, u, tr, un, tp, w, sg_, tx, lod), a, overhead=under - 0.5)

    made = {e["model"] for e in entries}
    for old in OUT.glob("*.glb"):
        if old.stem not in made:
            old.unlink()
            Path(str(old) + ".import").unlink(missing_ok=True)
    (TRACK / "landmarks.json").write_text(json.dumps(entries, indent=1) + "\n")
    print("landmarks: %d placed, %d models" % (len(entries), len(list(OUT.glob('*.glb')))))
    print("\n".join(report))


if __name__ == "__main__":
    main()
