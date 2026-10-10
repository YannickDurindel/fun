"""Landmark models of the Circuit de Monaco: what stands there on a Grand Prix Sunday and has a
shape of its own, or is not in OpenStreetMap at all.

    .venv/bin/python tools/track/landmarks/monaco.py

Writes assets/tracks/monaco/landmarks/*.glb and assets/tracks/monaco/landmarks.json. It reads
track.json, the terrain grid and the baked land cover, and nothing checks that the models are
newer than those: RUN IT AGAIN AFTER EVERY BUILD OF THE TRACK (any step), then import
(`tools/bin/godot --headless --path . --import`).

    harbour.glb   the yachts of Port Hercule: the big ones stern-to along the Quai des
                  Etats-Unis and the two jetties, the small ones on the pontoons
    pits.glb      the pit building of the Grand Prix (garages below, offices above), the
                  paddock halls behind it and the plane trees of Boulevard Albert 1er
    gantries.glb  the start-light gantry and the footbridges over the track
    casino.glb    the two towers and the pediment of the Casino's front on the square

Every model is in WORLD axes relative to one anchor in the harbour (ANCHOR), where the terrain
grid is flat (open water, one height in every cell around it), so one landmarks.json entry `{"at": {"xz": ANCHOR}}` puts each of them
in place and nothing depends on the heading of the road. Surfaces use the scenery material
names, so they get the game's materials; colours are vertex colours (linear).

Sources. Positions and sizes are read off the IGN aerial photograph (BD ORTHO, 20 cm per
pixel) in the game's own frame; that photograph shows the port on an ordinary spring day, so
the yachts are the ones moored then, not a particular race weekend's. Heights are estimates
unless a figure is given beside them.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "cad" / "track"))
import scenery_glb as sg  # noqa: E402

TRACK_DIR = ROOT / "assets" / "tracks" / "monaco"
OUT_DIR = TRACK_DIR / "landmarks"
ANCHOR = (300.0, -50.0)     # game x, z: open water in the middle of Port Hercule
BIG = 1.0e6                 # one chunk for a whole model


# ----------------------------------------------------------------------------- frame
class Lap:
    """The lap of track.json: points by distance, with the unit vector to the right."""

    def __init__(self):
        t = json.loads((TRACK_DIR / "track.json").read_text())
        self.step = float(t["step"])
        self.length = float(t["length"])
        self.sea = -float(t["origin_elevation_m"])   # y of sea level in the track frame
        p = np.array([q["p"] for q in t["points"]], dtype=np.float64)
        self.xz = p[:, [0, 2]]
        self.y = p[:, 1]
        self.width = np.array([q["width"] for q in t["points"]], dtype=np.float64)
        tan = np.roll(self.xz, -1, axis=0) - np.roll(self.xz, 1, axis=0)
        tan /= np.hypot(tan[:, 0], tan[:, 1])[:, None]
        self.tan = tan
        self.right = np.stack([-tan[:, 1], tan[:, 0]], axis=1)
        terr = json.loads((TRACK_DIR / "terrain.json").read_text())["near"]
        h = np.fromfile(TRACK_DIR / terr["file"], dtype="<f4")[: terr["nx"] * terr["nz"]]
        self._h = h.reshape(terr["nz"], terr["nx"])
        self._terr = terr
        from PIL import Image
        meta = json.loads((TRACK_DIR / "scenery.json").read_text())["landcover"]["near"]
        self._lc = np.array(Image.open(TRACK_DIR / meta["file"]))
        self._lc_grid = meta

    def is_water(self, x, z):
        """True when the baked land cover has water at (x, z)."""
        g = self._lc_grid
        i, j = int((x - g["x0"]) // g["step"]), int((z - g["z0"]) // g["step"])
        return 0 <= i < g["nx"] and 0 <= j < g["nz"] and int(self._lc[j, i]) == 2

    def distance(self, x, z):
        """Distance from (x, z) to the centreline."""
        return float(np.hypot(self.xz[:, 0] - x, self.xz[:, 1] - z).min())

    def ground_y(self, pts):
        """Lowest terrain height under the points (x, z)."""
        return min(self.terrain_y(float(x), float(z)) for x, z in pts)

    def index(self, s):
        return int(round((s % self.length) / self.step)) % len(self.y)

    def at(self, s, lateral=0.0):
        """(x, z) at distance `s`, `lateral` metres to the right of the centreline."""
        i = self.index(s)
        return self.xz[i] + self.right[i] * lateral

    def road_y(self, s):
        return float(self.y[self.index(s)])

    def terrain_y(self, x, z):
        """Bilinear height of the near terrain grid, as Terrain.height_at reads it."""
        t = self._terr
        u, v = (x - t["x0"]) / t["step"], (z - t["z0"]) / t["step"]
        i, j = min(int(u), t["nx"] - 2), min(int(v), t["nz"] - 2)
        tu, tv = u - i, v - j
        a = self._h[j, i] * (1 - tu) + self._h[j, i + 1] * tu
        b = self._h[j + 1, i] * (1 - tu) + self._h[j + 1, i + 1] * tu
        return float(a * (1 - tv) + b * tv)


def lin(r, g, b, a=0.0):
    """sRGB colour as seen on screen -> linear vertex colour; a = 1 for a windowed facade."""
    def f(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (f(r), f(g), f(b), a)


WHITE = lin(0.95, 0.95, 0.94)
OFF_WHITE = lin(0.88, 0.88, 0.86)
NAVY = lin(0.08, 0.11, 0.22)
GLASS = lin(0.10, 0.14, 0.20)
TEAK = lin(0.62, 0.48, 0.33)
STEEL = lin(0.55, 0.57, 0.60)
DARK = lin(0.07, 0.07, 0.08)


class Model:
    """A SceneryMesh in one chunk whose vertices are relative to the anchor (ax, ay, az)."""

    def __init__(self, lap: Lap):
        self.lap = lap
        self.ax, self.az = ANCHOR
        self.ay = lap.terrain_y(*ANCHOR)
        self.mesh = sg.SceneryMesh(-BIG, -BIG, 4.0 * BIG)
        self.mesh.anchor(0.0, 0.0)

    def ring(self, pts):
        return np.asarray(pts, dtype=np.float64) - [self.ax, self.az]

    def prism(self, pts, y0, y1, wall="concrete", roof=None, wall_col=WHITE, roof_col=None, floor=False):
        """Extruded footprint `pts` (world x, z) between world heights y0 and y1."""
        sg.prism(self.mesh, self.ring(pts), [], y0 - self.ay, y1 - self.ay, wall, roof or wall,
                 wall_col, roof_col or wall_col, y0 - self.ay, floor=floor)

    def box(self, centre, half_along, half_across, heading, y0, y1, **kw):
        self.prism(oriented_rect(centre, half_along, half_across, heading), y0, y1, **kw)

    def face(self, material, pts3, facing, colour):
        p = np.asarray(pts3, dtype=np.float64) - [self.ax, self.ay, self.az]
        self.mesh.face(material, p, facing, colour, float(p[:, 1].min()))

    def write(self, name):
        info = sg.write_glb(OUT_DIR / f"{name}.glb", self.mesh, f"monaco_{name}",
                            "fun-racer tools/track/landmarks/monaco.py")
        print(f"  {name}.glb: {info['triangles']} triangles, {info['bytes'] / 1024:.0f} kB")
        return info


def unit(heading_deg):
    """Compass heading (0 = north = -z, 90 = east = +x) -> unit (x, z)."""
    a = math.radians(heading_deg)
    return np.array([math.sin(a), -math.cos(a)])


def oriented_rect(centre, half_along, half_across, heading):
    f = heading if isinstance(heading, np.ndarray) else unit(heading)
    r = np.array([-f[1], f[0]])
    c = np.asarray(centre, dtype=np.float64)
    return [c + f * half_along + r * half_across, c + f * half_along - r * half_across,
            c - f * half_along - r * half_across, c - f * half_along + r * half_across]


# ----------------------------------------------------------------------------- yachts
def yacht(m: Model, stern, heading, length, rng, sea):
    """A motor yacht: `stern` = middle of the transom (x, z), bow `length` metres along
    `heading`. Beam about a fifth of the length, as on the ones in the photograph."""
    f = heading if isinstance(heading, np.ndarray) else unit(heading)
    r = np.array([-f[1], f[0]])
    s0 = np.asarray(stern, dtype=np.float64)
    beam = yacht_beam(length)
    hb = 0.5 * beam
    # Only where the bake has water under the whole hull and the road is not near: the quays
    # and the grandstands over the harbour's edge take their berths on race day.
    probe = [s0 + f * (a * length) + r * (b * hb) for a in (0.0, 0.35, 0.7, 1.0) for b in (-1.0, 0.0, 1.0)]
    if not all(m.lap.is_water(q[0], q[1]) for q in probe) or min(m.lap.distance(q[0], q[1]) for q in probe) < 10.0:
        return False
    free = 0.9 + 0.035 * length                       # freeboard
    hull_col = NAVY if (length > 30 and rng.random() < 0.22) else WHITE
    hull = [s0 + r * hb, s0 + f * 0.62 * length + r * hb, s0 + f * 0.86 * length + r * 0.55 * hb,
            s0 + f * length, s0 + f * 0.86 * length - r * 0.55 * hb, s0 + f * 0.62 * length - r * hb,
            s0 - r * hb]
    m.prism(hull, sea - 0.4, sea + free, "metal", "concrete", hull_col, TEAK if length > 18 else OFF_WHITE)
    if length < 9.0:
        return True
    decks = 1 if length < 18 else 2 if length < 40 else 3
    y = sea + free
    a0, a1, hw = 0.16, 0.66, 0.78 * hb                # deckhouse from / to (share of the length)
    for d in range(decks):
        hgt = 2.3 if length >= 18 else 1.5
        c = s0 + f * (0.5 * (a0 + a1) * length)
        # a dark window band between two white strips
        m.box(c, 0.5 * (a1 - a0) * length, hw, f, y, y + 0.5, wall="metal", wall_col=WHITE)
        m.box(c, 0.5 * (a1 - a0) * length - 0.15, hw - 0.12, f, y + 0.5, y + hgt - 0.5,
              wall="building_glass", roof="metal", wall_col=GLASS, roof_col=WHITE)
        m.box(c, 0.5 * (a1 - a0) * length + (0.6 if d < decks - 1 else 0.0), hw + (0.3 if d < decks - 1 else 0.0),
              f, y + hgt - 0.5, y + hgt, wall="metal", wall_col=WHITE)
        y += hgt
        a0, a1, hw = a0 + 0.08, a1 - 0.10, hw * 0.82
    if length >= 24:                                   # radar arch
        c = s0 + f * (0.42 * length)
        m.box(c, 0.6, 0.55 * hw, f, y, y + 1.6, wall="metal", wall_col=WHITE)
    return True


def yacht_beam(length):
    return max(2.6, 0.21 * length if length < 30 else 0.19 * length)


def build_harbour(lap: Lap):
    m = Model(lap)
    rng = np.random.default_rng(1929)
    sea = lap.sea
    south, east = 180.0, 90.0
    count = 0

    def put(stern, heading, length):
        nonlocal count
        count += bool(yacht(m, stern, heading, float(length), rng, sea))

    def berths(first, direction, heading, lengths, gap=1.6):
        """Boats side by side from `first` along `direction`, a fender's width apart."""
        p = np.asarray(first, dtype=np.float64)
        d = unit(direction)
        for k, length in enumerate(lengths):
            if k:
                p = p + d * (0.5 * yacht_beam(lengths[k - 1]) + gap + 0.5 * yacht_beam(length))
            put(p, heading, length)

    def quay(s_from, lengths, lateral=-13.0, gap=1.6):
        """Stern-to along the quay the track runs on: transoms `lateral` metres from the
        centreline (5 m of road, the wall, the quay's edge), bows away from the track."""
        s = s_from
        for k, length in enumerate(lengths):
            if k:
                s += 0.5 * yacht_beam(lengths[k - 1]) + gap + 0.5 * yacht_beam(length)
            i = lap.index(s)
            put(lap.at(s, lateral), -lap.right[i] if lateral < 0 else lap.right[i], length)

    # Quai des Etats-Unis, stern-to, bows to the south: the five superyachts of 40 to 72 m
    # where the quay is deepest, then six of 25 to 35 m towards Tabac.
    quay(2196.0, [72, 70, 55, 40, 46])
    quay(2283.0, [34, 30, 33, 30, 25, 27])
    # East side of the jetty at x = 288: twelve of 20 to 46 m, bows to the east.
    berths((293, -200), south, east, [20, 24, 26, 30, 32, 34, 38, 44, 46, 42, 40, 38])
    # West side of the same jetty: small craft (the superyachts' berths are 10 m away).
    berths((283, -150), south, 270.0, rng.uniform(7, 9, 10))
    # The corner of Tabac: boats of 25 m against the quay, fanned out.
    for k, (z, hd) in enumerate([(-192, 120), (-181, 114), (-170, 108), (-159, 104)]):
        put((86 + 1.5 * k, z), hd, 25)
    # Pontoon at x = 100 (z = -122 to 0): boats of 8 to 11 m on both sides.
    for k in range(28):
        z = -120 + 4.3 * k
        x = 100 + 0.05 * (z + 120)
        put((x - 2.2, z), 270.0, rng.uniform(7.5, 11))
        put((x + 2.2, z), east, rng.uniform(7.5, 11))
    # Pontoon and pier at x = 145 to 165: small craft on the west side, 18 to 36 m yachts on
    # the east side, then the superyachts (42 to 70 m) at the pier head.
    berths((141.5, -118), south, 270.0, rng.uniform(8, 12, 18), gap=1.2)
    berths((150, -96), south, east, [18, 22, 24, 26, 30, 32, 34, 36])
    berths((168, -28), south, east, [42, 62, 70, 64, 56, 52])
    # North basin, off the Yacht Club: day boats on its pontoons.
    for k in range(10):
        i = lap.index(1915 + 9 * k)
        put(lap.at(1915 + 9 * k, -70.0), -lap.right[i], rng.uniform(12, 18))
    info = m.write("harbour")
    print(f"    {count} boats")
    return info


# ----------------------------------------------------------------------------- pits
TEAMS = [lin(0.80, 0.06, 0.08), lin(0.75, 0.77, 0.79), lin(0.07, 0.10, 0.30), lin(0.95, 0.45, 0.05),
         lin(0.00, 0.35, 0.28), lin(0.05, 0.30, 0.65), lin(0.90, 0.40, 0.60), lin(0.92, 0.92, 0.92),
         lin(0.15, 0.15, 0.16), lin(0.10, 0.45, 0.20), lin(0.20, 0.35, 0.75)]


def build_pits(lap: Lap):
    """Since 2004 the pits stand on the old road between the Swimming Pool and La Rascasse:
    the pit lane runs beside the track (and against it), the garages are on its far side with
    their backs to the trees of the start straight, offices on the floor above
    (grandprix.com, "Monaco announces new pits", 2002: garages 15 m long and 10 m deep;
    acm.mc). Eleven double garages follow the lap from s = 2760 to 2895, 17.5 m right of the
    centreline; the storey heights (4.2 m and 3.4 m) are estimates."""
    m = Model(lap)
    s0, s1, front, depth = 2760.0, 2895.0, 17.5, 10.5
    bays = 22
    ds = (s1 - s0) / bays
    for k in range(bays):
        a, b = s0 + k * ds, s0 + (k + 1) * ds
        y = min(lap.road_y(a), lap.road_y(b)) - 0.25
        fa, fb = lap.at(a, front), lap.at(b, front)
        ba, bb = lap.at(a, front + depth), lap.at(b, front + depth)
        team = TEAMS[(k // 2) % len(TEAMS)]
        m.prism([fb, fa, ba, bb], y - 0.5, y + 4.2, "concrete", "concrete", OFF_WHITE, OFF_WHITE)
        # the upper floor oversails the pit lane by 1.5 m and is glazed towards it
        oa, ob = lap.at(a, front - 1.5), lap.at(b, front - 1.5)
        m.prism([ob, oa, ba, bb], y + 4.2, y + 7.6, "building_glass", "metal", lin(0.20, 0.26, 0.32), WHITE,
                floor=True)
        # fascia in the team's colour over an open, dark garage door
        ia, ib = lap.at(a + 0.6, front - 0.05), lap.at(b - 0.6, front - 0.05)
        toward = -lap.right[lap.index(a)]
        f3 = np.array([toward[0], 0.0, toward[1]])
        m.face("metal", [[ia[0], y + 0.05, ia[1]], [ib[0], y + 0.05, ib[1]], [ib[0], y + 3.3, ib[1]],
                         [ia[0], y + 3.3, ia[1]]], f3, DARK)
        ja, jb = lap.at(a, front - 0.08), lap.at(b, front - 0.08)
        m.face("metal", [[ja[0], y + 3.4, ja[1]], [jb[0], y + 3.4, jb[1]], [jb[0], y + 4.2, jb[1]],
                         [ja[0], y + 4.2, ja[1]]], f3, team)
    # Paddock hall behind the pits: the white-roofed hall of the photograph west of the pool
    # (the one north of the pool is under grandstand K; south of the pool the two legs of the
    # lap are 47 m apart and the garages take the room). [s from, s to, lateral from, to, height]
    for a, b, d0, d1, h in ((3206, 3290, 24, 44, 7.0),):
        y = lap.road_y(a) - 0.3
        n = max(1, int((b - a) / 14))
        ss = [a + (b - a) * k / n for k in range(n + 1)]
        ring = [lap.at(s, d0) for s in ss] + [lap.at(s, d1) for s in reversed(ss)]
        m.prism(ring, min(y, lap.ground_y(ring)) - 0.8, y + h, "concrete", "concrete", OFF_WHITE, WHITE)
    # The plane trees of Boulevard Albert 1er: one row along the right of the start straight,
    # between the track and the paddock, a crown about every 9 m on the photograph from
    # Anthony Noghes to Sainte Devote. The pipeline keeps its own trees off the 30 m verge, so
    # the row is modelled here (trunk 5 m, crown 8 m across) and, unlike the game's trees,
    # does not follow environment.json or the scenery setting. None stands at a gantry.
    trunk, leaf_a, leaf_b = lin(0.36, 0.31, 0.25), lin(0.20, 0.33, 0.12), lin(0.26, 0.39, 0.15)
    rng = np.random.default_rng(7)
    s = 3068.0
    k = 0
    while (s - 3068.0) < 3337.0 - 3068.0 + 186.0:
        i = lap.index(s)
        c = lap.at(s, 0.5 * lap.width[i] + 3.6 + float(rng.uniform(-0.2, 0.2)))
        y = lap.road_y(s) - 0.25
        hgt = float(rng.uniform(4.6, 5.6))
        rad = float(rng.uniform(3.4, 4.3))
        step = 9.0 + float(rng.uniform(-0.8, 0.8))
        if min(abs((s - g + 0.5 * lap.length) % lap.length - 0.5 * lap.length) for g in GANTRIES) > 7.0:
            m.prism(sg.ngon(c[0], c[1], 0.3, 5), min(y, lap.terrain_y(c[0], c[1])) - 0.6, y + hgt,
                    "concrete", "concrete", trunk, trunk)
            crown(m, c, y + hgt - 0.8, rad, rad * 1.25, leaf_a if k % 2 else leaf_b)
            k += 1
        s += step
    info = m.write("pits")
    print(f"    {bays} garage bays, {k} plane trees")
    return info


def crown(m: Model, c, y, radius, height, colour):
    """A tree crown: two stacked six-sided frustums."""
    rings = [(0.55, 0.0), (1.0, 0.38), (0.72, 0.78), (0.15, 1.0)]
    for (r0, h0), (r1, h1) in zip(rings[:-1], rings[1:]):
        a = sg.ngon(c[0], c[1], radius * r0, 6)
        b = sg.ngon(c[0], c[1], radius * r1, 6)
        for i in range(6):
            j = (i + 1) % 6
            quad = [[a[i][0], y + height * h0, a[i][1]], [a[j][0], y + height * h0, a[j][1]],
                    [b[j][0], y + height * h1, b[j][1]], [b[i][0], y + height * h1, b[i][1]]]
            out = np.array([a[i][0] + a[j][0] - 2 * c[0], 0.6 * radius, a[i][1] + a[j][1] - 2 * c[1]])
            m.face("concrete", quad, out, colour)


# ----------------------------------------------------------------------------- gantries
START_GANTRY = 2.0
# Footbridges for the spectators (scaffolding decks with a banner on each face). The race has
# about a dozen; these four are over stretches where the game has room for them. Positions
# are ESTIMATES from race photographs: before Sainte Devote, on the quay after the chicane (no
# stairs on the harbour side: the quay ends at the wall), at the Swimming Pool exit and
# before the grid. (s, banner colour, stairs left, stairs right)
FOOTBRIDGES = ((150.0, (0.80, 0.08, 0.08), True, True), (2300.0, (0.06, 0.20, 0.50), False, True),
               (2742.0, (0.80, 0.08, 0.08), True, False), (3150.0, (0.06, 0.20, 0.50), True, True))
GANTRIES = (START_GANTRY,) + tuple(b[0] for b in FOOTBRIDGES)


def portal(m: Model, lap: Lap, s, clear, deck_w, deck_h, colour, banner=None, stairs=(True, True)):
    """A portal over the road at `s`: legs 3 m outside both road edges (behind the barrier),
    a deck `deck_h` high whose underside is `clear` above the road. Legs and stairs go down
    to the ground they stand on."""
    i = lap.index(s)
    f, r = lap.tan[i], lap.right[i]
    half = 0.5 * lap.width[i] + 3.0
    y = lap.road_y(s)
    c = lap.xz[i]
    for side, with_stairs in zip((-1.0, 1.0), stairs):
        leg = c + r * side * half
        m.box(leg, 0.5 * deck_w, 0.45, f, min(y, lap.terrain_y(leg[0], leg[1])) - 0.6, y + clear, wall="metal",
              wall_col=STEEL)
        if with_stairs:     # stair tower: a ramp of boxes down the outside
            for k in range(4):
                q = c + r * side * (half + 1.1 + 1.3 * k)
                m.box(q, 0.5 * deck_w, 0.65, f, min(y, lap.terrain_y(q[0], q[1])) - 0.6,
                      y + clear * (1.0 - (k + 1) / 5.0), wall="metal", wall_col=STEEL)
    m.box(c, 0.5 * deck_w, half + 0.45, f, y + clear, y + clear + deck_h, wall="metal",
          wall_col=banner or colour, roof_col=STEEL, floor=True)


def build_gantries(lap: Lap):
    m = Model(lap)
    # Start lights: a slim portal on the start / finish line (5.6 m clear), the light panel a
    # dark box under its middle.
    portal(m, lap, START_GANTRY, 5.6, 0.9, 0.7, STEEL, banner=lin(0.12, 0.12, 0.14), stairs=(False, False))
    i = lap.index(START_GANTRY)
    y = lap.road_y(START_GANTRY)
    m.box(lap.xz[i], 0.25, 2.2, lap.tan[i], y + 4.7, y + 5.6, wall="metal", wall_col=DARK, floor=True)
    for s, col, left, right in FOOTBRIDGES:
        portal(m, lap, s, 5.6, 3.0, 2.2, STEEL, banner=lin(*col), stairs=(left, right))
    return m.write("gantries")


# ----------------------------------------------------------------------------- casino
def build_casino(lap: Lap):
    """The front of the Casino de Monte-Carlo (Charles Garnier, 1878-79) on the square: two
    towers with pointed copper roofs either side of a pediment with the clock. The body is
    the map's footprint (18 m to the cornice, see the recipe); the towers stand at the ends
    of its 32 m north-west face and rise about 12 m above it (estimate from photographs)."""
    m = Model(lap)
    stone = lin(0.93, 0.88, 0.76)
    copper = lin(0.42, 0.62, 0.56)
    a, b = np.array([537.0, -456.0]), np.array([557.0, -481.0])   # ends of the front (game x, z)
    along = (b - a) / np.hypot(*(b - a))
    out = np.array([along[1], -along[0]])                # towards the square
    if out @ (np.array([509.0, -490.0]) - a) < 0:
        out = -out
    y = lap.road_y(890.0) - 0.2                          # the square
    for p in (a, b):
        c = p + out * 1.5
        m.box(c, 3.2, 3.2, along, y - 1.0, y + 23.0, wall="building_wall", roof="building_roof",
              wall_col=stone[:3] + (1.0,), roof_col=copper)
        ring = np.array(oriented_rect(c, 3.5, 3.5, along)) - [m.ax, m.az]
        sg.pyramid_roof(m.mesh, sg.oriented(ring, True), y + 23.0 - m.ay, 8.5, "building_roof", copper)
        m.box(c, 0.35, 0.35, along, y + 31.0, y + 34.0, wall="metal", wall_col=copper)
    mid = 0.5 * (a + b) + out * 1.0
    m.box(mid, 7.5, 1.5, along, y + 18.0, y + 21.5, wall="building_wall", roof="building_roof",
          wall_col=stone, roof_col=copper)
    # the glass canopy over the entrance steps
    m.box(mid + out * 3.0, 6.0, 2.5, along, y + 4.6, y + 5.0, wall="metal", roof="building_glass",
          wall_col=STEEL, roof_col=GLASS, floor=True)
    return m.write("casino")


def main():
    lap = Lap()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"monaco landmarks -> {OUT_DIR}")
    names = []
    for name, build in (("harbour", build_harbour), ("pits", build_pits), ("gantries", build_gantries),
                        ("casino", build_casino)):
        build(lap)
        names.append(name)
    entries = [{"model": n, "at": {"xz": [ANCHOR[0], ANCHOR[1]]}} for n in names]
    (TRACK_DIR / "landmarks.json").write_text(json.dumps(entries, indent=1) + "\n")
    print(f"  landmarks.json: {len(entries)} entries, anchor {ANCHOR}, terrain there {lap.terrain_y(*ANCHOR):.2f} m")


if __name__ == "__main__":
    main()
