"""Landmarks of the Circuit de Spa-Francorchamps: the things beside the road that the map data
does not give a shape, written as low-poly GLBs with the scenery material names.

    .venv/bin/python tools/track/landmarks/spa.py        (from fun-racer/)

Run it AFTER tools/track/build_track.py spa: it reads the built track.json (road heights,
widths, turns), road_profile.json (bank), terrain_height.bin (the ground the grandstands stand
on) and the trackside table scripts/track/trackside_layouts/spa.gd (where the barriers stand:
nothing here is put on the track side of them), and writes assets/tracks/spa/landmarks/*.glb
and assets/tracks/spa/landmarks.json. Run it again when any of those change.

Every model is placed with an "s" anchor (a point of the lap, at road height) and is written in
the frame of that anchor, so it follows the road however the terrain model is off beside it.

Where the shapes come from: the orthophoto of the Service public de Wallonie, summer 2023, 25 cm
(geoservices.wallonie.be, IMAGERIE/ORTHO_2023_ETE), read in the track frame (x east, z south,
metres from the finish line). Footprints are good to about 2 m. Heights are estimates from
the number of rows / storeys and from trackside photographs, and are marked as such below.

  * the pit lanes of the Formula 1 pits (start straight) and of the endurance pits (the
    descent to Eau Rouge): the tarmac between the pit wall and the pit building;
  * the start gantry 22 m after the line, the footbridge before Eau Rouge and the five slim
    signal gantries over the lap (s = 3462, 4275, 4705, 5660, 6432 on the photo);
  * the covered grandstands, which the map has as bare outlines without roofs: the red-roofed
    Formula 1 grandstand opposite the pits, the Endurance grandstand with its solar roof,
    the Raidillon grandstand of 2022 (solar roof) with the open stand below it;
  * the open stands the map lacks: the terraces above the endurance straight (Silver 1), the
    blue stand of Speaker's Corner, and the Grand Prix stands outside Pouhon (temporary: not on
    the photo; placed behind the service road from the circuit's Grand Prix seating plan);
  * the edge of the forest. The surroundings step keeps its trees off the 30 m verges, but at
    Spa the spruce stands 10 to 20 m from the white line on much of the lap (after Raidillon,
    the run to Pouhon, Blanchimont): rows of plain low-poly spruces fill that gap, from where
    the photo shows the first trunks out to where the baked trees begin.
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

TRACK = ROOT / "assets" / "tracks" / "spa"
OUT = TRACK / "landmarks"

# Linear vertex colours (the scenery materials take their colour from them).
WHITE = (1.0, 1.0, 1.0, 1.0)
STEEL = (0.30, 0.31, 0.33, 0.0)
DARK = (0.03, 0.03, 0.035, 0.0)
CONCRETE = (0.45, 0.44, 0.42, 0.0)
TARMAC = (0.060, 0.060, 0.066, 0.0)       # pit lane surface
ROOF_RED = (0.42, 0.06, 0.045, 0.0)       # the Formula 1 grandstand
ROOF_SOLAR = (0.06, 0.085, 0.14, 0.0)     # photovoltaic roofs (Endurance, Raidillon)
RED_LIGHT = (1.0, 0.05, 0.03, 0.0)
SPRUCE = [(0.010, 0.040, 0.016, 0.0), (0.020, 0.062, 0.022, 0.0)]   # needles, dark to light
TRUNK = (0.050, 0.035, 0.025, 0.0)

LAYOUT = ROOT / "scripts" / "track" / "trackside_layouts" / "spa.gd"
RUNOFF_KERB_ALLOWANCE = 2.5   # scripts/track/trackside_layout.gd
CORNER_ZONE = (-60.0, 140.0, 40.0)   # ... _build_from_table: from, length, ramp of a corner's zone
RUNOFF_RAMP = 30.0                   # ... _add_runoff_zones


class Lap:
    """The built centreline: positions, tangents, widths and bank by distance."""

    def __init__(self):
        t = json.loads((TRACK / "track.json").read_text())
        self.length = float(t["length"])
        self.step = float(t["step"])
        self.p = np.array([q["p"] for q in t["points"]], dtype=np.float64)
        self.width = np.array([q["width"] for q in t["points"]], dtype=np.float64)
        self.n = len(self.p)
        # + = left edge higher. track.json carries no bank; the built cross-section does.
        profile = json.loads((TRACK / "road_profile.json").read_text())
        self.bank = np.array(profile["bank"], dtype=np.float64)
        self.verge_width, self.verge_drop = float(profile["verge_width"]), float(profile["verge_drop"])
        assert len(self.bank) == self.n, "road_profile.json and track.json disagree: rebuild the track"
        self.zones = self._barrier_zones(t["turns"])
        terr = json.loads((TRACK / "terrain.json").read_text())["near"]
        self.tx0, self.tz0, self.tstep = terr["x0"], terr["z0"], terr["step"]
        self.tnx, self.tnz = terr["nx"], terr["nz"]
        self.th = np.fromfile(TRACK / terr["file"], dtype="<f4").reshape(self.tnz, self.tnx)

    def _i(self, s):
        u = (s % self.length) / self.step
        i = int(math.floor(u)) % self.n
        return i, (i + 1) % self.n, u - math.floor(u)

    def pos(self, s):
        i, j, f = self._i(s)
        return self.p[i] + (self.p[j] - self.p[i]) * f

    def tangent(self, s):
        """Unit horizontal direction of travel (x, z), as TrackData.tangent_at takes it."""
        d = self.pos(s + self.step) - self.pos(s - self.step)
        return np.array([d[0], d[2]]) / math.hypot(d[0], d[2])

    def right(self, s):
        t = self.tangent(s)
        return np.array([-t[1], t[0]])

    def half_width(self, s):
        i, j, f = self._i(s)
        return 0.5 * (self.width[i] + (self.width[j] - self.width[i]) * f)

    def ground_beside(self, s, lat):
        """World point `lat` metres right of the centreline (negative = left) on the road or
        its verge, as scripts/track/road.gd builds the cross-section: the road is banked, the
        verge leaves its edge level and falls `verge_drop` over `verge_width`."""
        i, j, f = self._i(s)
        p, r = self.pos(s), self.right(s)
        bank = self.bank[i] + (self.bank[j] - self.bank[i]) * f
        hw = self.half_width(s)
        on_road = max(-hw, min(hw, lat))
        beyond = abs(lat) - abs(on_road)
        y = p[1] - math.sin(bank) * on_road - self.verge_drop * beyond / self.verge_width
        return np.array([p[0] + r[0] * lat, y, p[2] + r[1] * lat])

    def _barrier_zones(self, turns):
        """The barrier zones of the trackside table (TracksideLayout._build_from_table), read
        from the .gd file so that the two cannot drift apart: [(s0, length, ramp, side, dist)]."""
        src = LAYOUT.read_text()

        def const(name):
            return float(re.search(r"const %s: float = ([0-9.]+)" % name, src).group(1))

        self.barrier_straight = const("BARRIER_STRAIGHT")
        corner, behind = const("BARRIER_CORNER_OUTSIDE"), const("BARRIER_BEHIND_RUNOFF")
        apex = {t["id"]: (float(t["s_apex"]), 1.0 if t["direction"] == "right" else -1.0) for t in turns}
        zones = [(a + CORNER_ZONE[0], CORNER_ZONE[1], CORNER_ZONE[2], -sign, corner) for a, sign in apex.values()]
        block = src[src.index("const RUNOFF: Array = ["):]
        block = block[:block.index("\n]")]
        row = re.compile(r'\["(T\d+)", "(in|out)", (-?[0-9.]+), (-?[0-9.]+), "(?:tarmac|gravel)", [0-9.]+, ([0-9.]+)\]')
        rows = row.findall(block)
        assert rows, "no RUNOFF rows found in %s" % LAYOUT
        for turn, side, s0, s1, u1 in rows:
            a, sign = apex[turn]
            zones.append((a + float(s0), float(s1) - float(s0), RUNOFF_RAMP, sign if side == "in" else -sign,
                          float(u1) + RUNOFF_KERB_ALLOWANCE + behind))
        return zones

    def barrier(self, s, side):
        """Distance of the barrier line from the centreline on `side` (+1 right, -1 left), as
        Trackside._compute_barrier_offsets wants it (before its geometric limits, which only
        apply inside hairpins and between neighbouring legs of the lap)."""
        dist = self.barrier_straight
        for s0, length, ramp, zside, zdist in self.zones:
            if zside != side:
                continue
            t = (s - s0 + 0.5 * self.length) % self.length - 0.5 * self.length
            d = 0.0 if 0.0 <= t <= length else (-t if t < 0.0 else t - length)
            blend = 0.5 + 0.5 * math.cos(math.pi * min(d / ramp, 1.0))
            dist = max(dist, self.barrier_straight + (zdist - self.barrier_straight) * blend)
        return self.half_width(s) + dist

    def closest_s(self, x, z):
        d = (self.p[:, 0] - x) ** 2 + (self.p[:, 2] - z) ** 2
        return float(np.argmin(d)) * self.step

    def terrain(self, x, z):
        u = min(max((x - self.tx0) / self.tstep, 0.0), self.tnx - 1.001)
        v = min(max((z - self.tz0) / self.tstep, 0.0), self.tnz - 1.001)
        i, j = int(u), int(v)
        a = self.th[j, i] + (self.th[j, i + 1] - self.th[j, i]) * (u - i)
        b = self.th[j + 1, i] + (self.th[j + 1, i + 1] - self.th[j + 1, i]) * (u - i)
        return float(a + (b - a) * (v - j))


class Anchor:
    """The frame the runtime gives a landmark placed with {"s": s, "dist": 0} and `yaw_deg`
    (scripts/track/scenery.gd, _landmark_transform): origin on the road centre, local -Z along
    the lap for yaw 0. `axis` (x, z) turns the model so that its +Z runs along that direction."""

    def __init__(self, lap: Lap, s: float, axis=None):
        self.s = round(float(s), 1)
        self.origin = lap.pos(self.s)
        f = lap.tangent(self.s)
        base = math.atan2(-f[0], -f[1])
        self.theta = base if axis is None else math.atan2(axis[0], axis[1])
        self.yaw_deg = math.degrees(self.theta - base)

    def local(self, w):
        """World point(s) (.., 3) -> model coordinates."""
        w = np.asarray(w, dtype=np.float64)
        d = w - self.origin
        c, s = math.cos(self.theta), math.sin(self.theta)
        return np.stack([d[..., 0] * c - d[..., 2] * s, d[..., 1], d[..., 0] * s + d[..., 2] * c], axis=-1)

    def entry(self, model):
        return {"model": model, "at": {"s": self.s, "side": 1, "dist": 0.0},
                "yaw_deg": round(self.yaw_deg, 3)}


def new_mesh():
    m = sg.SceneryMesh()
    m.anchor(0.0, 0.0)
    return m


def both(mesh, material, pts, colour):
    """A flat strip visible from both sides."""
    pts = np.asarray(pts, dtype=np.float64)
    n = np.cross(pts[1] - pts[0], pts[2] - pts[0])
    mesh.face(material, pts, n, colour)
    mesh.face(material, pts, -n, colour)


# ----------------------------------------------------------------------------- gantries
def truss(mesh, x0, x1, y0, y1, depth=1.0, bay=2.4, colour=STEEL):
    """A lattice girder across the road from x0 to x1 (model x = to the right of the lap)
    between the heights y0 and y1, on a post at each end."""
    c, hz = 0.16, 0.5 * depth
    for z in (-hz, hz):
        for y in (y0, y1):
            sg.box(mesh, "metal", (x0, y - c, z - c), (x1, y + c, z + c), colour)
    bays = max(2, int(round((x1 - x0) / bay)))
    xs = np.linspace(x0, x1, bays + 1)
    for k, x in enumerate(xs):
        for z in (-hz, hz):
            sg.box(mesh, "metal", (x - 0.06, y0, z - 0.06), (x + 0.06, y1, z + 0.06), colour)
        if k < bays:
            a, b = (y0, y1) if k % 2 == 0 else (y1, y0)
            for z in (-hz, hz):
                both(mesh, "metal", [(x, a - 0.07, z), (xs[k + 1], b - 0.07, z),
                                     (xs[k + 1], b + 0.07, z), (x, a + 0.07, z)], colour)
    for x in (x0, x1):
        sg.box(mesh, "metal", (x - 0.3, -1.5, -hz - 0.1), (x + 0.3, y1, hz + 0.1), colour)


POST_BEHIND = 1.0   # m: a gantry post stands this far behind the barrier line


def posts(lap: Lap, s, left, right):
    """Post positions (model x) of a gantry at s: where the photo has them (`left`, `right`,
    metres from the centreline), but never on the track side of the barrier."""
    return (-max(left, lap.barrier(s, -1.0) + POST_BEHIND), max(right, lap.barrier(s, 1.0) + POST_BEHIND))


def signal_gantry(x0, x1):
    """One of the slim gantries over the lap that carry the light panels and timing gear: a
    lattice girder 6.5 m above the road (estimate; the photo gives spans of 24 to 28 m)."""
    m = new_mesh()
    truss(m, x0, x1, 6.5, 7.6)
    sg.box(m, "metal", (-1.6, 5.3, -0.25), (1.6, 6.5, 0.25), DARK)        # light panel
    return m


def start_gantry(x0, x1):
    """The start gantry of the Formula 1 straight, 22 m after the line: from the pit wall to
    the fence of the grandstand side (18.5 m left on the photo), with the five pairs of start
    lights over the road. Clear height 7 m (estimate)."""
    m = new_mesh()
    truss(m, x0, x1, 7.0, 8.6, depth=1.6)
    sg.box(m, "metal", (-5.2, 6.1, 0.55), (5.2, 7.0, 0.95), DARK)         # light board, faces the grid
    for k in range(5):
        x = -3.6 + 1.8 * k
        for y in (6.35, 6.72):
            sg.box(m, "emissive_light", (x - 0.2, y - 0.13, 0.95), (x + 0.2, y + 0.13, 1.0), RED_LIGHT)
    return m


def footbridge(x0, x1):
    """The footbridge over the endurance straight (s = 720): a closed walkway 3 m wide and 6 m
    above the road, from a stair tower behind the left barrier to one against the pit
    building, beyond the pit lane (on the photo it spans from 22.5 m left to the pit wall
    10 m right, where the game has its pit lane). Heights are estimates."""
    m = new_mesh()
    sg.box(m, "concrete", (x0, 6.0, -1.6), (x1, 6.4, 1.6), CONCRETE)
    sg.box(m, "metal", (x0, 8.7, -1.7), (x1, 8.9, 1.7), STEEL)
    for z in (-1.6, 1.5):
        sg.box(m, "building_glass", (x0, 6.4, z), (x1, 8.7, z + 0.1), (0.5, 0.55, 0.6, 1.0))
    for x in (x0 - 3.0, x1):
        sg.box(m, "concrete", (x, -2.0, -2.2), (x + 3.0, 9.2, 2.2), CONCRETE)
    return m


# ----------------------------------------------------------------------------- pit lanes
def pit_lane(lap: Lap, anchor: Anchor, s0, s1, outer, taper=40.0):
    """Tarmac on the right of the road from the pit wall (the trackside barrier line) out to
    `outer` metres from the centreline, between s0 and s1, 5 cm above the verge."""
    m = new_mesh()
    span = (s1 - s0) % lap.length
    rows = []
    for k in range(int(span // 4.0) + 1):
        d = min(k * 4.0, span)
        s = s0 + d
        inner = lap.barrier(s, 1.0) + 0.7
        w = min(1.0, d / taper, (span - d) / taper)          # the lane narrows to nothing at its ends
        far = inner + max(outer - inner, 0.0) * max(w, 0.02)
        a = lap.ground_beside(s, inner) + (0.0, 0.05, 0.0)
        b = lap.ground_beside(s, far) + (0.0, 0.05, 0.0)
        rows.append((anchor.local(a), anchor.local(b)))
    for (a0, b0), (a1, b1) in zip(rows[:-1], rows[1:]):
        m.face("concrete", [a0, b0, b1, a1], sg.UP, TARMAC)
    return m


# ----------------------------------------------------------------------------- grandstands
def stand(lap: Lap, front_a, front_b, depth, top, roof=None, module=30.0):
    """A grandstand whose front row runs from front_a to front_b (world x, z) and which is
    `depth` deep, away from the track; the top row is `top` above the ground. It is cut into
    modules that each stand on the terrain under their front row, as the real ones step down
    a slope. `roof`: colour of a cantilever roof 4.5 m above the top row, or None.
    Returns (mesh, anchor)."""
    a, b = np.asarray(front_a, float), np.asarray(front_b, float)
    mid = 0.5 * (a + b)
    anchor = Anchor(lap, lap.closest_s(mid[0], mid[1]), axis=(b - a) / np.linalg.norm(b - a))
    road = lap.pos(anchor.s)
    la = anchor.local([a[0], road[1], a[1]])
    lb = anchor.local([b[0], road[1], b[1]])
    back = 1.0 if la[0] > 0.0 else -1.0          # the track (model origin) is on the other side
    length = lb[2] - la[2]
    count = max(1, int(math.ceil(length / module)))
    m = new_mesh()
    for k in range(count):
        z0 = la[2] + length * k / count
        z1 = la[2] + length * (k + 1) / count
        w = a + (b - a) * ((k + 0.5) / count)
        ground = lap.terrain(w[0], w[1]) - road[1]
        ring = np.array([[la[0], z0], [la[0], z1], [la[0] + back * depth, z1], [la[0] + back * depth, z0]])
        sg.grandstand(m, ring, np.array([-back, 0.0]), ground, ground - 5.0, top, WHITE)
        if roof is not None:
            y = ground + top + 4.5
            xf, xb = la[0] - back * 2.5, la[0] + back * (depth + 0.6)
            sg.box(m, "building_roof", (min(xf, xb), y, z0), (max(xf, xb), y + 0.4, z1), roof)
            # back wall up to the roof, and a roof beam at each end of the module
            x_in, x_out = la[0] + back * depth, la[0] + back * (depth + 0.5)
            sg.box(m, "stand_structure", (min(x_in, x_out), ground - 5.0, z0),
                   (max(x_in, x_out), y, z1), (0.55, 0.55, 0.55, 0.0))
            for z in (z0, z1 - 0.3):
                sg.box(m, "metal", (min(xf, xb), y - 0.6, z), (max(xf, xb), y, z + 0.3), STEEL)
    return m, anchor


# ----------------------------------------------------------------------------- forest edge
def spruce(mesh, base, height, colour, sides=6):
    """A spruce standing on `base` (model x, y, z): two tiers of needles and a short trunk."""
    base = np.asarray(base, dtype=np.float64)
    ang = np.arange(sides + 1) * (2.0 * math.pi / sides)
    for y0, y1, r in ((0.16, 0.74, 0.17), (0.48, 1.0, 0.11)):
        apex = base + (0.0, y1 * height, 0.0)
        ring = [base + (math.cos(a) * r * height, y0 * height, math.sin(a) * r * height) for a in ang]
        for k in range(sides):
            mesh.face("concrete", [ring[k], ring[k + 1], apex], None, colour,
                      away_from=base + (0.0, y0 * height, 0.0))
    t = 0.018 * height
    for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        a = base + (dx * t - dz * t, -0.5, dz * t + dx * t)
        b = base + (dx * t + dz * t, -0.5, dz * t - dx * t)
        top = np.array([0.0, 0.5 + 0.2 * height, 0.0])
        mesh.face("concrete", [a, b, b + top, a + top], None, TRUNK, away_from=base)


def forest_edge(lap: Lap, anchor: Anchor, s0, s1, side, first, rows, rng):
    """Rows of spruces on `side` (+1 right, -1 left) of the lap between s0 and s1: the first
    row `first` metres from the centreline, then one every 6.5 m out to where the baked trees
    begin (road edge + 32 m); trees 6 m apart along a row, jittered. None within 2.5 m of the
    barrier line or on the track side of it: the models have no collision."""
    m = new_mesh()
    count = 0
    for row in range(rows):
        s = s0 + rng.uniform(0.0, 6.0)
        while s < s1:
            lat = first + 6.5 * row + rng.uniform(-1.5, 1.5)
            if lap.barrier(s, side) + 2.5 < lat < lap.half_width(s) + 33.0:
                p = lap.ground_beside(s, side * lat)
                h = rng.uniform(17.0, 27.0) * (0.85 if row == 0 else 1.0)
                spruce(m, anchor.local(p), h, SPRUCE[0] if rng.random() < 0.6 else SPRUCE[1])
                count += 1
            s += rng.uniform(4.5, 7.5)
    return m, count


def lap_edge(lap: Lap, s, lat):
    """World (x, z) of the point `lat` metres right of the centreline at s."""
    p, r = lap.pos(s), lap.right(s)
    return (p[0] + r[0] * lat, p[2] + r[1] * lat)


def main():
    lap = Lap()
    OUT.mkdir(parents=True, exist_ok=True)
    entries = []
    report = []

    def write(name, mesh, anchor):
        info = sg.write_glb(OUT / f"{name}.glb", mesh, name, "tools/track/landmarks/spa.py")
        entries.append(anchor.entry(name))
        report.append(f"  {name}: {info['triangles']} triangles, {info['bytes'] // 1024} kB, s = {anchor.s:.0f}")

    # Gantries. Positions (m from the finish line) read on the photo; each has its posts 12 to
    # 14 m from the centreline there, or behind the barrier where that stands further out.
    for k, s in enumerate((3462.0, 4275.0, 4705.0, 5660.0, 6432.0)):
        write(f"signal_gantry_{k + 1}", signal_gantry(*posts(lap, s, 13.0, 13.0)), Anchor(lap, s))
    write("start_gantry", start_gantry(*posts(lap, 22.0, 18.5, 10.5)), Anchor(lap, 22.0))
    left, _ = posts(lap, 720.0, 22.5, 0.0)
    write("footbridge", footbridge(left, 15.0), Anchor(lap, 720.0))

    # Pit lanes. Formula 1: from the pit entry after the chicane (s = 6790) to the pit exit at
    # La Source (s = 240), out to the pit building 17.5 m from the centreline. Endurance: beside
    # the descent, s = 545 to 905, out to the old pit building 15 m from the centreline.
    a = Anchor(lap, 0.0)
    write("pit_lane_f1", pit_lane(lap, a, 6790.0, 240.0, 17.5), a)
    a = Anchor(lap, 720.0)
    write("pit_lane_endurance", pit_lane(lap, a, 545.0, 905.0, 15.0), a)

    # Grandstands: front row from / to in the track frame (x, z), depth, height of the top row
    # above the ground (estimates: 0.5 m per metre of depth, as on trackside photographs).
    stands = [
        # the red-roofed Formula 1 grandstand opposite the pits: 94 x 24 m on the photo
        ("stand_f1", (-7.9, 31.0), (36.2, 114.3), 21.0, 12.0, ROOF_RED),
        # the Endurance grandstand above the descent, solar roof: 96 x 34 m
        ("stand_endurance", (164.9, -109.7), (239.8, -43.7), 30.0, 15.0, ROOF_SOLAR),
        # the Raidillon grandstand built in 2022, solar roof: 128 x 27 m
        ("stand_raidillon", (521.0, 259.8), (551.0, 391.0), 24.0, 13.0, ROOF_SOLAR),
        # the open stand below it, at the foot of the hill: 35 x 24 m
        ("stand_eau_rouge", (489.3, 214.4), (499.6, 246.1), 22.0, 11.0, None),
        # Speaker's Corner, blue seats, open: 119 x 14 m
        ("stand_speakers", (586.3, 1510.7), (605.9, 1627.8), 14.0, 8.0, None),
    ]
    for name, fa, fb, depth, top, roof in stands:
        mesh, anchor = stand(lap, fa, fb, depth, top, roof)
        write(name, mesh, anchor)
    # Silver 1: the open terraces above the endurance straight, 36 m left of the centreline
    # between s = 475 and 585, 15 m deep (photo).
    mesh, anchor = stand(lap, lap_edge(lap, 475.0, -36.0), lap_edge(lap, 585.0, -36.0), 15.0, 8.0)
    write("stand_silver_1", mesh, anchor)
    # Pouhon, Grand Prix weekend only (ESTIMATE, see the header): two open stands behind the
    # service road on the outside, 64 m right of the centreline.
    for k, (s0, s1) in enumerate(((3725.0, 3815.0), (3850.0, 3950.0))):
        mesh, anchor = stand(lap, lap_edge(lap, s0, 64.0), lap_edge(lap, s1, 64.0), 16.0, 9.0)
        write(f"stand_pouhon_{k + 1}", mesh, anchor)

    # The forest edge: (from, to, side, distance of the first trunks from the centreline, rows),
    # read on the photo. Elsewhere the forest begins beyond the verge and is baked.
    edges = [
        (1340.0, 1560.0, -1, 10.0, 5),    # the trees close in on the left after Raidillon
        (3350.0, 3830.0, -1, 21.0, 3),    # left of the run down to Pouhon
        (4090.0, 4340.0, -1, 16.0, 4),    # left, between Pouhon and Fagnes
        (5620.0, 6000.0, -1, 15.0, 4),    # inside Blanchimont
        (6000.0, 6400.0, -1, 28.0, 2),
        (6400.0, 6540.0, -1, 21.0, 3),    # left of the braking zone for the chicane
        (1450.0, 1600.0, 1, 13.0, 4),     # right after Raidillon
        (1600.0, 1750.0, 1, 19.0, 3),     # Kemmel, right (a clearing follows to s = 1950)
        (1950.0, 2400.0, 1, 20.0, 3),     # Kemmel to Les Combes, right
        (2440.0, 2640.0, 1, 18.0, 4),     # inside Malmedy
        (2800.0, 3100.0, 1, 28.0, 2),     # inside Bruxelles
        (3220.0, 3650.0, 1, 21.0, 3),     # right of the run down to Pouhon
    ]
    rng = np.random.default_rng(284560)   # the lap's OSM relation id: the same forest every run
    trees = 0
    k = 0
    for s0, s1, side, first, rows in edges:
        pieces = max(1, int(math.ceil((s1 - s0) / 200.0)))
        for q in range(pieces):
            a0, a1 = s0 + (s1 - s0) * q / pieces, s0 + (s1 - s0) * (q + 1) / pieces
            anchor = Anchor(lap, 0.5 * (a0 + a1))
            mesh, count = forest_edge(lap, anchor, a0, a1, side, first, rows, rng)
            k += 1
            trees += count
            write(f"forest_edge_{k:02d}", mesh, anchor)
    report.append(f"  forest edge: {trees} spruces")

    # Models of an earlier run that are no longer made go, with their import files.
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
