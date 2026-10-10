"""Landmarks of the Bahrain International Circuit (Sakhir): the structures that have a shape of
their own and that the map cannot give, as low-poly models with their real proportions.

    .venv/bin/python tools/track/landmarks/bahrain.py            # models + landmarks.json
    .venv/bin/python tools/track/landmarks/bahrain.py --lawns    # prints the recipe's lawn polygons

Writes assets/tracks/bahrain/landmarks/*.glb and assets/tracks/bahrain/landmarks.json (read by
scripts/track/scenery.gd). Run `tools/bin/godot --headless --path . --import` afterwards.

What is modelled, and where the dimensions come from. Plan sizes and positions are the
OpenStreetMap footprints (the ids are given below), checked against aerial imagery (Esri World
Imagery, 0.54 m per pixel). Heights are estimates from photographs (Wikimedia Commons:
"Bahrain Grandstands 2010", "Bahrain International Circuit before the F1 race - 2024",
"Sakhir view", "Bahrain-International-Circuit-curve-19-vip-tower", "Bahrain International
Circuit back straight"), counted in storeys and in seat rows; none is a surveyed figure.

  sakhir_tower      The round VIP tower inside Turn 1: a glazed podium, eight balcony floors
                    that widen towards the top, a roof terrace under a crown of white tents
                    with spikes, a flag mast. Footprint way 187123438: 37.8 m across. About
                    38 m to the terrace and 47 m to the tent tips (the shaft is as tall as the
                    top floor is wide in the photographs).
  main_grandstand   350 x 30 m (way 187123419), eight bays. One tier of blue seats over a wall,
                    two floors of glazed suites, a three-storey cream building behind, a cream
                    membrane roof in eight tents and a white wind tower (the square frames
                    with arches) behind each tent. Roof edge about 22 m, tower tops about 38 m.
  batelco_stand     The same construction, 244 x 28 m and six bays (way 187123414), facing the
                    drag strip and the Turn 10 to Turn 11 straight.
  pit_building      320 x 25 m, two floors (garages, glazed hospitality with a terrace) under
                    eight white tents, and the three-storey race control block at its south end
                    (way 187123416, which the map tags as a grandstand).
  paddock           The six two-storey team buildings behind the pit building, each with a tent
                    on its roof terrace, and the three-storey building south of them, in the
                    sand-coloured render of the site (the baked boxes come out grey).
  stand_roof_205,   The wavy white canopies on rear masts of the First Turn grandstand
  stand_roof_70     (204 x 18 m) and of the University and Victory grandstands (70 x 18 m).
                    The seating under them is baked by the surroundings step.
  dome_29, dome_15  The two white dome halls west of Turn 15 (relation 20311525): 58 m and
                    30 m across in the aerial imagery; 20 m and 12 m high are estimates.
  gantry_*          The truss bridges over the track: the start lights gantry and the three
                    sponsor gantries (after Turn 4, after Turn 8, on the Turn 10 to Turn 11
                    straight), found in the aerial imagery. Their places are given relative to
                    the turn table of track.json and each span is the road width there plus
                    the room to stand behind the barriers (landmarks have no collision).

Surfaces are named like the scenery materials, so the game gives them its own; the colour is
the vertex colour. The membranes use a material of their own ("membrane", double sided)
because they are seen from both sides; the game keeps it as the file has it.
"""

from __future__ import annotations

import json
import math
import struct
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "cad" / "track"))

import scenery_glb as sg  # noqa: E402
from road_glb import Material  # noqa: E402

TRACK_DIR = ROOT / "assets" / "tracks" / "bahrain"
OUT_DIR = TRACK_DIR / "landmarks"
MEMBRANE = "membrane"

# Linear vertex colours (r, g, b, windows): a = 1 draws windows on building_wall.
CREAM = (0.78, 0.69, 0.52, 0.0)        # the sand-coloured render of every building here
CREAM_WINDOWS = (0.78, 0.69, 0.52, 1.0)
WHITE = (0.90, 0.90, 0.86, 0.0)
TENT = (0.88, 0.84, 0.73, 0.0)         # PTFE membrane, slightly cream
DARK = (0.10, 0.11, 0.12, 0.0)
GLASS = (0.20, 0.26, 0.30, 1.0)
SEAT = (0.16, 0.30, 0.62, 0.0)
STEEL = (0.75, 0.76, 0.76, 0.0)
UP = np.array([0.0, 1.0, 0.0])


def new_mesh() -> sg.SceneryMesh:
    """One chunk for the whole model: a landmark is far smaller than a scenery chunk."""
    mesh = sg.SceneryMesh(x0=-5.0e5, z0=-5.0e5, chunk=1.0e6)
    mesh.anchor(0.0, 0.0)
    return mesh


def quad(mesh, material, a, b, c, d, colour, facing=None, away=None, v_ref=0.0):
    mesh.face(material, [a, b, c, d], facing, colour, v_ref, away_from=away)


def post(mesh, material, x, z, y0, y1, half, colour):
    sg.box(mesh, material, (x - half, y0, z - half), (x + half, y1, z + half), colour)


def tent(mesh, x0, x1, z_back, z_front, y_eave, y_peak, z_peak, arch=2.5, sag=0.38):
    """One membrane tent over the rectangle x0..x1, z_back..z_front: a cone hung from a mast
    ring at (centre, y_peak, z_peak), with edges that arch up between the corners and a
    surface that sags below the straight line, as a tensioned membrane does."""
    xc = 0.5 * (x0 + x1)
    rim = [
        (x0, y_eave, z_back), (xc, y_eave + 0.6 * arch, z_back), (x1, y_eave, z_back),
        (x1, y_eave + 0.4 * arch, 0.5 * (z_back + z_front)), (x1, y_eave, z_front),
        (xc, y_eave + arch, z_front), (x0, y_eave, z_front),
        (x0, y_eave + 0.4 * arch, 0.5 * (z_back + z_front)),
    ]
    apex = np.array([xc, y_peak, z_peak])
    rim = [np.array(p, dtype=np.float64) for p in rim]
    # Two rings between the rim and the mast: (share of the way in plan, share of the height).
    # A straight cone would have equal shares; a membrane hangs below it and steepens at the mast.
    def ring_at(run, rise):
        out = []
        for p in rim:
            q = p + (apex - p) * run
            q[1] = p[1] + (y_peak - p[1]) * rise
            out.append(q)
        return out

    mid = ring_at(0.45, 0.45 * sag)
    top = ring_at(0.88, 0.80)
    n = len(rim)
    for k in range(n):
        j = (k + 1) % n
        for lo, hi in ((rim, mid), (mid, top)):
            mesh.face(MEMBRANE, [lo[k], lo[j], hi[j]], UP, TENT)
            mesh.face(MEMBRANE, [lo[k], hi[j], hi[k]], UP, TENT)
        mesh.face(MEMBRANE, [top[k], top[j], apex], UP, TENT)


def wind_tower(mesh, x, z, y0, y1, size=7.0):
    """The white square frame with pointed arches above a tent (a stylised wind tower): four
    posts, three rings of beams and the arch heads between them."""
    h = 0.5 * size
    p = 0.32
    for sx in (-1.0, 1.0):
        for sz in (-1.0, 1.0):
            post(mesh, "concrete", x + sx * h, z + sz * h, y0, y1, p, WHITE)
    for y in (y0 + 0.30 * (y1 - y0), y0 + 0.62 * (y1 - y0), y1 - 0.5):
        for s in (-1.0, 1.0):
            sg.box(mesh, "concrete", (x - h, y, z + s * h - 0.22), (x + h, y + 0.5, z + s * h + 0.22), WHITE)
            sg.box(mesh, "concrete", (x + s * h - 0.22, y, z - h), (x + s * h + 0.22, y + 0.5, z + h), WHITE)
    # Arch heads under the top ring: a thin triangle in each half of each face.
    ya, yb = y1 - 0.5, y1 - 0.5 - 0.22 * (y1 - y0)
    for s in (-1.0, 1.0):
        for a, b in ((-h, 0.0), (0.0, h)):
            m = 0.5 * (a + b)
            for flip in (1.0, -1.0):
                mesh.face("concrete", [[x + a, ya, z + s * h], [x + m, ya, z + s * h], [x + a, yb, z + s * h]],
                          np.array([0.0, 0.0, flip]), WHITE)
                mesh.face("concrete", [[x + b, ya, z + s * h], [x + m, ya, z + s * h], [x + b, yb, z + s * h]],
                          np.array([0.0, 0.0, flip]), WHITE)
                mesh.face("concrete", [[x + s * h, ya, z + a], [x + s * h, ya, z + m], [x + s * h, yb, z + a]],
                          np.array([flip, 0.0, 0.0]), WHITE)
                mesh.face("concrete", [[x + s * h, ya, z + b], [x + s * h, ya, z + m], [x + s * h, yb, z + b]],
                          np.array([flip, 0.0, 0.0]), WHITE)


# ----------------------------------------------------------------------------- grandstands
def tent_grandstand(length, depth, bays, tower_top, tower_size):
    """A grandstand of the main straight's kind. Local frame: x along the stand, +z towards
    the track, y up from the ground at the centre of the footprint."""
    mesh = new_mesh()
    hl = 0.5 * length
    zf, zb = 0.5 * depth, -0.5 * depth        # front of the seating, back of the building
    z_suite = zf - 16.0                        # back of the tier = front of the suites
    y_front, y_tier, y_suite, y_back = 2.6, 11.0, 17.0, 18.0
    base = -1.5
    # Front wall and the tier of seats (one sloping face per bay: the seat shader draws the
    # rows from the uv, which is the plan position in metres).
    quad(mesh, "concrete", [-hl, base, zf], [hl, base, zf], [hl, y_front, zf], [-hl, y_front, zf], CREAM,
         facing=np.array([0.0, 0.0, 1.0]), v_ref=0.0)
    w = length / bays
    for k in range(bays):
        a, b = -hl + k * w, -hl + (k + 1) * w
        quad(mesh, "stand_seats", [a, y_front, zf], [b, y_front, zf], [b, y_tier, z_suite], [a, y_tier, z_suite],
             SEAT, facing=UP)
    # Glazed suites and the building behind them.
    sg.box(mesh, "building_glass", (-hl, y_tier, z_suite - 5.0), (hl, y_suite, z_suite), GLASS)
    sg.box(mesh, "concrete", (-hl, y_suite, z_suite - 5.5), (hl, y_suite + 0.5, z_suite + 1.2), WHITE)
    ring = np.array([[-hl, zb], [hl, zb], [hl, z_suite - 5.0], [-hl, z_suite - 5.0]])
    sg.prism(mesh, ring, [], base, y_back, "building_wall", "building_roof", CREAM_WINDOWS, CREAM, 0.0)
    # End walls under the tier.
    for s in (-1.0, 1.0):
        x = s * hl
        mesh.face("stand_structure", [[x, base, zf], [x, y_front, zf], [x, y_tier, z_suite], [x, base, z_suite]],
                  np.array([s, 0.0, 0.0]), CREAM)
    # Roof: one tent per bay, hung from the wind tower behind the suites.
    y_eave, y_peak = 21.5, 28.0
    z_tower = z_suite - 9.0
    for k in range(bays):
        a, b = -hl + k * w, -hl + (k + 1) * w
        tent(mesh, a, b, zb - 5.0, zf + 6.0, y_eave, y_peak, z_tower + 3.0, arch=3.0)
        xc = 0.5 * (a + b)
        wind_tower(mesh, xc, z_tower, y_peak - 2.0, tower_top, tower_size)
        # Roof masts at the bay lines, front and back.
        for x in (a, b) if k == 0 else (b,):
            post(mesh, "concrete", x, z_suite - 2.5, y_suite, y_eave, 0.35, WHITE)
            post(mesh, "concrete", x, zb - 4.0, base, y_eave, 0.35, WHITE)
    return mesh


def pit_building(length, depth, bays, control_len):
    """Local frame: x along the pit lane, +z towards the track; placed facing west, +x is
    south (against the direction of travel). The race control block continues the building
    at its +x end, the pit entry side."""
    mesh = new_mesh()
    hl = 0.5 * length
    zf, zb = 0.5 * depth, -0.5 * depth
    base = -1.5
    y1, y2 = 5.2, 10.4
    # Ground floor: garages, dark and open to the pit lane; a plain wall to the paddock.
    quad(mesh, "concrete", [-hl, base, zf - 1.0], [hl, base, zf - 1.0], [hl, y1, zf - 1.0], [-hl, y1, zf - 1.0], DARK,
         facing=np.array([0.0, 0.0, 1.0]))
    # (the body stops 0.3 m behind the garage face, so the two never share a plane)
    ring = np.array([[-hl, zb], [hl, zb], [hl, zf - 1.3], [-hl, zf - 1.3]])
    sg.prism(mesh, ring, [], base, y1, "building_wall", "building_roof", CREAM, CREAM, 0.0)
    w = length / bays
    # Garage piers every half bay and the terrace slab above them.
    for k in range(2 * bays + 1):
        x = -hl + k * 0.5 * w
        sg.box(mesh, "concrete", (x - 0.6, base, zf - 1.0), (x + 0.6, y1, zf), CREAM)
    sg.box(mesh, "concrete", (-hl, y1, zb), (hl, y1 + 0.5, zf + 1.5), WHITE)
    # First floor: glazed hospitality set back behind the terrace.
    sg.box(mesh, "building_glass", (-hl, y1 + 0.5, zb + 1.0), (hl, y2, zf - 4.0), GLASS)
    sg.box(mesh, "concrete", (-hl, y2, zb), (hl, y2 + 0.4, zf - 3.0), WHITE)
    # Tents: two rows of masts per bay in reality; one tent per bay here.
    for k in range(bays):
        a, b = -hl + k * w, -hl + (k + 1) * w
        tent(mesh, a + 1.0, b - 1.0, zb - 2.0, zf + 3.0, y2 + 2.2, y2 + 8.5, 0.0, arch=2.2)
        post(mesh, "concrete", 0.5 * (a + b), 0.0, y2, y2 + 9.5, 0.3, WHITE)
        if k > 0:
            # The small stair pavilion between two tents.
            sg.box(mesh, "building_wall", (a - 4.0, y2 + 0.4, zb + 2.0), (a + 4.0, y2 + 4.6, zb + 12.0), CREAM)
    # Race control: three storeys, windows all round, a flat roof with a parapet.
    x0, x1 = hl + 2.0, hl + control_len
    ring = np.array([[x0, zb], [x1, zb], [x1, zf], [x0, zf]])
    sg.prism(mesh, ring, [], base, 14.5, "building_wall", "building_roof", CREAM_WINDOWS, CREAM, 0.0)
    sg.box(mesh, "building_glass", (x0 + 2.0, 10.6, zf), (x1 - 2.0, 14.0, zf + 0.6), GLASS)
    return mesh


def paddock():
    """The buildings behind the pit building that the map has as plain boxes: the six team
    buildings (ways 187123411, -12, -18, -13, -15, -17: 44 x 14 m, two storeys, a small tent on
    the roof terrace) and the three-storey building south of them (way 187123421, 58 x 30 m).
    Local frame: +x south along the row, +z west (towards the pit building); the origin is
    the middle of the row."""
    mesh = new_mesh()
    base = -1.5
    for x in (-126.9, -79.0, -23.5, 24.0, 76.0, 127.0):
        ring = np.array([[x - 21.9, -7.1], [x + 21.9, -7.1], [x + 21.9, 7.1], [x - 21.9, 7.1]])
        sg.prism(mesh, ring, [], base, 7.4, "building_wall", "building_roof", CREAM_WINDOWS, CREAM, 0.0)
        tent(mesh, x - 14.0, x + 14.0, -6.0, 6.0, 9.0, 12.5, 0.0, arch=1.2)
        for sx in (-14.0, 14.0):
            for sz in (-6.0, 6.0):
                post(mesh, "concrete", x + sx, sz, 7.4, 9.0, 0.15, WHITE)
    ring = np.array([[168.0, -4.0], [226.4, -4.0], [226.4, 28.3], [168.0, 28.3]])
    sg.prism(mesh, ring, [], base, 12.0, "building_wall", "building_roof", CREAM_WINDOWS, CREAM, 0.0)
    return mesh


def stand_roof(length, depth, y_back, y_front):
    """Canopy of a steel-truss grandstand. Local frame as tent_grandstand; the roof hangs from
    masts behind the last row and rises towards the track in shallow waves."""
    mesh = new_mesh()
    hl = 0.5 * length
    zb, zf = -0.5 * depth - 1.5, 0.5 * depth + 1.0
    waves = max(2, int(round(length / 11.5)))
    w = length / waves
    for k in range(waves):
        a, b = -hl + k * w, -hl + (k + 1) * w
        m = 0.5 * (a + b)
        # A shallow vault per wave: two faces meeting on a ridge 0.9 m above the valleys.
        for xa, xb, ya, yb in ((a, m, 0.0, 0.9), (m, b, 0.9, 0.0)):
            pts = [[xa, y_back + ya, zb], [xb, y_back + yb, zb], [xb, y_front + yb, zf], [xa, y_front + ya, zf]]
            mesh.face(MEMBRANE, pts, UP, WHITE)
        # Truss beam under each valley and the mast behind it with its stay.
        mesh.face("metal", [[a - 0.15, y_back - 0.9, zb], [a + 0.15, y_back - 0.9, zb],
                            [a + 0.15, y_front - 0.9, zf], [a - 0.15, y_front - 0.9, zf]], -UP, STEEL)
        for f in (1.0, -1.0):
            mesh.face("metal", [[a, y_back - 0.9, zb], [a, y_back, zb], [a, y_front, zf], [a, y_front - 0.9, zf]],
                      np.array([f, 0.0, 0.0]), STEEL)
        post(mesh, "metal", a, zb, -1.5, y_back + 5.0, 0.22, STEEL)
        mesh.face("metal", [[a - 0.1, y_back + 5.0, zb], [a + 0.1, y_back + 5.0, zb], [a + 0.1, y_front + 0.2, zf - 2.0],
                            [a - 0.1, y_front + 0.2, zf - 2.0]], UP, STEEL)
    post(mesh, "metal", hl, zb, -1.5, y_back + 5.0, 0.22, STEEL)
    return mesh


# ----------------------------------------------------------------------------- the tower
def sakhir_tower():
    mesh = new_mesh()
    sides = 20
    floors = 8
    y_podium, floor_h = 6.0, 4.0

    def ring(r):
        return sg.ngon(0.0, 0.0, r, sides)

    # Podium: a glazed drum two storeys high with a white roof ring.
    sg.prism(mesh, ring(17.5), [], -1.5, y_podium, "building_glass", "building_roof", GLASS, WHITE, 0.0)
    y = y_podium
    for k in range(floors):
        # The floors widen from 13.5 m to 17.5 m radius; each is a dark glass band behind a
        # white balcony slab that stands 1.6 m proud of it.
        r = 13.5 + 4.0 * k / (floors - 1)
        sg.prism(mesh, ring(r), [], y, y + floor_h, "building_glass", "building_roof", GLASS, WHITE, 0.0)
        sg.prism(mesh, ring(r + 1.6), [], y + floor_h - 0.45, y + floor_h + 0.45, "concrete", "concrete",
                 WHITE, WHITE, 0.0, floor=True)
        y += floor_h
    y_deck = y + 0.45
    # Roof terrace: a recessed drum (plant, lifts) and the crown of tents around it.
    sg.prism(mesh, ring(8.0), [], y_deck, y_deck + 4.5, "building_wall", "building_roof", WHITE, WHITE, 0.0)
    crown = 10
    r_in, r_out = 8.0, 20.5
    for k in range(crown):
        a0 = 2.0 * math.pi * k / crown
        a1 = 2.0 * math.pi * (k + 1) / crown
        am = 0.5 * (a0 + a1)
        y_eave, y_peak = y_deck + 3.4, y_deck + 8.6

        def pt(ang, rad, yy):
            return np.array([rad * math.cos(ang), yy, rad * math.sin(ang)])

        apex = pt(am, 14.0, y_peak)
        rim = [pt(a0, r_in, y_eave + 1.0), pt(a0, r_out, y_eave), pt(am, r_out + 1.2, y_eave + 1.6),
               pt(a1, r_out, y_eave), pt(a1, r_in, y_eave + 1.0)]
        for i in range(len(rim)):
            j = (i + 1) % len(rim)
            p, q = rim[i], rim[j]
            pm = p + (apex - p) * 0.5
            qm = q + (apex - q) * 0.5
            pm[1] = p[1] + (apex[1] - p[1]) * 0.28
            qm[1] = q[1] + (apex[1] - q[1]) * 0.28
            mesh.face(MEMBRANE, [p, q, qm, pm], UP, TENT)
            mesh.face(MEMBRANE, [pm, qm, apex], UP, TENT)
        # Mast with its spike through the peak of the tent.
        post(mesh, "concrete", apex[0], apex[2], y_deck, y_peak, 0.18, WHITE)
        tip = apex + UP * 5.5
        foot = [apex + np.array([0.25 * math.cos(a), 0.0, 0.25 * math.sin(a)]) for a in (0.0, 2.094, 4.189)]
        for i in range(3):
            mesh.face("concrete", [foot[i], foot[(i + 1) % 3], tip], None, WHITE, away_from=apex + UP * 2.0)
    # Flag mast on the plant drum.
    post(mesh, "metal", 0.0, 0.0, y_deck + 4.5, y_deck + 22.0, 0.2, WHITE)
    return mesh


def dome(radius, height):
    """A white dome hall: part of a sphere, `height` tall over a circle of `radius`."""
    mesh = new_mesh()
    seg, rings = 18, 5
    big = (radius * radius + height * height) / (2.0 * height)     # sphere radius
    top = math.asin(min(1.0, radius / big))                         # polar angle of the rim
    def pt(i, k):
        a = top * i / rings
        ang = 2.0 * math.pi * k / seg
        return np.array([big * math.sin(a) * math.cos(ang), height - big * (1.0 - math.cos(a)), big * math.sin(a) * math.sin(ang)])
    for i in range(rings):
        for k in range(seg):
            quad_pts = [pt(i, k), pt(i, k + 1), pt(i + 1, k + 1), pt(i + 1, k)]
            mesh.face("building_roof", quad_pts[1:] if i == 0 else quad_pts, None, WHITE, away_from=np.array([0.0, -big, 0.0]))
    sg.prism(mesh, sg.ngon(0.0, 0.0, radius, seg), [], -1.5, 0.3, "concrete", "concrete", WHITE, WHITE, 0.0)
    return mesh


# ----------------------------------------------------------------------------- gantries
def gantry(span, clear, lights):
    """Truss bridge over the track. Local frame of an "s" placement: +x to the right of the
    road, -z along the lap, y up from the road surface."""
    mesh = new_mesh()
    hs = 0.5 * span
    y0, y1 = clear, clear + 2.2
    for s in (-1.0, 1.0):
        x = s * hs
        for dz in (-1.1, 1.1):
            post(mesh, "metal", x, dz, -2.0, y1, 0.16, STEEL)
        sg.box(mesh, "metal", (x - 0.16, y0 - 0.2, -1.1), (x + 0.16, y0, 1.1), STEEL)
    # The beam: four chords and a dark sign board on both faces.
    for y in (y0, y1 - 0.2):
        for dz in (-1.1, 1.1):
            sg.box(mesh, "metal", (-hs, y, dz - 0.1), (hs, y + 0.2, dz + 0.1), STEEL)
    for dz, f in ((-1.22, -1.0), (1.22, 1.0)):
        quad(mesh, "concrete", [-hs + 1.0, y0 + 0.25, dz], [hs - 1.0, y0 + 0.25, dz], [hs - 1.0, y1 - 0.25, dz],
             [-hs + 1.0, y1 - 0.25, dz], DARK, facing=np.array([0.0, 0.0, f]))
        # A pale band where the sponsor lettering is.
        quad(mesh, "concrete", [-0.3 * span, y0 + 0.6, dz + 0.02 * f], [0.3 * span, y0 + 0.6, dz + 0.02 * f],
             [0.3 * span, y1 - 0.6, dz + 0.02 * f], [-0.3 * span, y1 - 0.6, dz + 0.02 * f], WHITE,
             facing=np.array([0.0, 0.0, f]))
    if lights:
        # Start lights: five panels facing the grid (the cars come from +z).
        for k in range(5):
            x = (k - 2) * 1.5
            sg.box(mesh, "metal", (x - 0.45, y0 - 1.5, 1.2), (x + 0.45, y0 - 0.1, 1.5), DARK)
            quad(mesh, "emissive_light", [x - 0.3, y0 - 1.3, 1.52], [x + 0.3, y0 - 1.3, 1.52], [x + 0.3, y0 - 0.9, 1.52],
                 [x - 0.3, y0 - 0.9, 1.52], WHITE, facing=np.array([0.0, 0.0, 1.0]))
    return mesh


# ----------------------------------------------------------------------------- output
def write(mesh: sg.SceneryMesh, name: str) -> dict:
    """Writes OUT_DIR/<name>.glb. The membrane material is not one of the game's: it is made
    double sided in the file (write_glb has no such option), and the game keeps it as it is.
    No glow: a baked emissive would stay on by day, and the floodlights light it at night."""
    path = OUT_DIR / f"{name}.glb"
    stats = sg.write_glb(path, mesh, name, "tools/track/landmarks/bahrain.py")
    raw = path.read_bytes()
    js_len = struct.unpack_from("<I", raw, 12)[0]
    doc = json.loads(raw[20:20 + js_len])
    rest = raw[20 + js_len:]
    for m in doc.get("materials", []):
        if m["name"] == MEMBRANE:
            m["doubleSided"] = True
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * ((4 - len(js) % 4) % 4)
    out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + len(rest))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js + rest
    path.write_bytes(out)
    stats["bytes"] = len(out)
    print(f"  {name}.glb: {stats['triangles']} triangles, {stats['bytes'] / 1024:.0f} kB")
    return stats


def yaw_facing(fx: float, fz: float) -> float:
    """yaw_deg that turns the model's +z (its front) to the plan direction (fx, fz)."""
    return round(math.degrees(math.atan2(fx, fz)), 1)


# Footprints from OpenStreetMap (oriented boxes of the ways): centre as lat / lon, and the
# direction the front looks in (plan x east, z south).
PLACES = [
    # way 187123419 "Main Grandstand": 348.9 x 29.4 m, west of the pit straight, facing it.
    {"model": "main_grandstand", "at": {"latlon": [26.032069, 50.510139]}, "yaw_deg": yaw_facing(0.999, 0.036)},
    # way 187123414 "Batelco": 243.9 x 27.9 m, facing east over the drag strip.
    {"model": "batelco_stand", "at": {"latlon": [26.032533, 50.511840]}, "yaw_deg": yaw_facing(0.999, 0.036)},
    # way 187123416: the pit building, facing west to the pit lane: 25 m deep, its tents over
    # the 320 m north of race control (aerial imagery).
    {"model": "pit_building", "at": {"latlon": [26.032071, 50.510865]}, "yaw_deg": yaw_facing(-0.999, -0.032)},
    # The team buildings (ways 187123411 ...) and way 187123421 south of them.
    {"model": "paddock", "at": {"latlon": [26.032116, 50.511409]}, "yaw_deg": yaw_facing(-0.999, -0.035)},
    # way 187123438 "Sakhir Tower".
    {"model": "sakhir_tower", "at": {"latlon": [26.035464, 50.511544]}, "yaw_deg": 0.0},
    # way 271535967 "First Turn Grandstand": 204.5 x 17.9 m, facing east.
    {"model": "stand_roof_205", "at": {"latlon": [26.036034, 50.510289]}, "yaw_deg": yaw_facing(0.999, 0.038)},
    # ways 271535984, 271535959, 271535961 "University Grandstand 1-3": 70 x 18 m, facing the
    # Turn 2 to Turn 3 stretch to their south.
    {"model": "stand_roof_70", "at": {"latlon": [26.037160, 50.512053]}, "yaw_deg": yaw_facing(-0.156, 0.988)},
    {"model": "stand_roof_70", "at": {"latlon": [26.037128, 50.512876]}, "yaw_deg": yaw_facing(-0.151, 0.988)},
    {"model": "stand_roof_70", "at": {"latlon": [26.037090, 50.513685]}, "yaw_deg": yaw_facing(-0.153, 0.988)},
    # ways 271535964, 271535981 "Victory Grandstand 1-2": facing the back straight to their
    # north-west.
    {"model": "stand_roof_70", "at": {"latlon": [26.026463, 50.512596]}, "yaw_deg": yaw_facing(-0.492, -0.871)},
    {"model": "stand_roof_70", "at": {"latlon": [26.025783, 50.511175]}, "yaw_deg": yaw_facing(-0.482, -0.876)},
    # relation 20311525: the dome halls beside the run from Turn 15 onto the pit straight.
    {"model": "dome_29", "at": {"latlon": [26.028364, 50.509587]}, "yaw_deg": 0.0},
    {"model": "dome_15", "at": {"latlon": [26.028715, 50.509857]}, "yaw_deg": 0.0},
]

# Gantries (aerial imagery): (model, turn id or "start", metres after it, lights, post
# setback behind the road edge). The start lights stand 12 m after the start line with their
# posts just behind the pit wall and the grandstand wall (9 m); the sponsor bridges stand
# where no run-off widens the barrier line, posts 17 m out (behind any barrier there).
GANTRIES = [
    ("start_gantry", "start", 12.0, True, 10.0),
    ("gantry_t4", "T4", 180.0, False, 17.0),      # after Turn 4, before the Turn 5 kink
    ("gantry_t8", "T8", 137.0, False, 17.0),      # after Turn 8
    ("gantry_t11", "T11", -370.0, False, 17.0),   # on the Turn 10 to Turn 11 straight
]


def gantry_places() -> list[tuple[str, float, float, bool]]:
    """(model, s, span, lights) of the gantries on the built track."""
    track = json.loads((TRACK_DIR / "track.json").read_text())
    apex = {t["id"]: float(t["s_apex"]) for t in track["turns"]}
    apex["start"] = float(track["start_s"])
    pts, step, length = track["points"], float(track["step"]), float(track["length"])
    out = []
    for name, ref, after, lights, setback in GANTRIES:
        s = (apex[ref] + after) % length
        width = float(pts[int(round(s / step)) % len(pts)]["width"])
        out.append((name, round(s, 1), round(width + 2.0 * setback, 1), lights))
    return out


def build() -> None:
    # The membrane is a material of this generator, not of the scenery pipeline.
    sg.MATERIALS.append(Material(MEMBRANE, (1.0, 1.0, 1.0, 1.0), 0.85))
    sg.MATERIAL_NAMES.append(MEMBRANE)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    total = 0
    for name, mesh in (
        ("sakhir_tower", sakhir_tower()),
        ("main_grandstand", tent_grandstand(348.9, 29.4, 8, 38.0, 7.5)),
        ("batelco_stand", tent_grandstand(243.9, 27.9, 6, 36.0, 7.0)),
        ("pit_building", pit_building(320.0, 30.0, 8, 34.0)),
        ("paddock", paddock()),
        ("stand_roof_205", stand_roof(204.5, 17.9, 13.5, 15.5)),
        ("stand_roof_70", stand_roof(69.8, 17.8, 13.5, 15.5)),
        ("dome_29", dome(29.0, 20.0)),
        ("dome_15", dome(15.0, 12.0)),
    ):
        total += write(mesh, name)["triangles"]
    places = list(PLACES)
    for name, s, span, lights in gantry_places():
        total += write(gantry(span, 6.5, lights), name)["triangles"]
        places.append({"model": name, "at": {"s": s, "side": 1, "dist": 0.0}, "yaw_deg": 0.0})
    (TRACK_DIR / "landmarks.json").write_text(json.dumps(places, indent=1) + "\n")
    print(f"  landmarks.json: {len(places)} placements, {total} triangles in the models")


# ----------------------------------------------------------------------------- lawns
def lawns(min_area: float = 250.0, tol: float = 1.2) -> None:
    """Prints `[[surroundings.add]]` entries (kind "farmland", which this track's palette
    paints as irrigated lawn) for the landuse=grass and leisure=garden areas of the cached
    map data. The recipe carries the result: in the desert palette the map's own grass class
    is the bare ground, so the few real lawns have to be named. A courtyard (inner ring)
    follows its lawn as kind "grass", the bare ground: the additions are painted in order
    over the map's own land cover."""
    sys.path.insert(0, str(ROOT / "tools" / "track"))
    from lib import geom, surroundings as su

    terrain = json.loads((TRACK_DIR / "terrain.json").read_text())
    lat0, lon0 = terrain["origin_latlon"]
    proj = geom.Projection(lat0, lon0, float(terrain["plan_scale"]))
    caches = sorted((TRACK_DIR / "raw").glob("surroundings_near_*.json"))
    if not caches:
        sys.exit("no surroundings_near_*.json in raw/: run the surroundings step first")
    feats, _ = su.load_features(caches[0].read_text(), proj)

    def ll(ring):
        ring = su.simplify(ring, tol, closed=True)
        lat, lon = proj.to_latlon(ring[:, 0], ring[:, 1])
        return ", ".join(f"[{a:.6f}, {b:.6f}]" for a, b in zip(lat, lon))

    rows = []
    for f in feats:
        if not (f.tags.get("landuse") == "grass" or f.tags.get("leisure") == "garden"):
            continue
        for k, outer in enumerate(f.outers):
            holes = f.inners if k == 0 else []
            area = abs(sg.signed_area(outer)) - sum(abs(sg.signed_area(h)) for h in holes)
            if area >= min_area:
                rows.append((area, f.ref, outer, holes))
    rows.sort(key=lambda r: -r[0])
    for area, ref, outer, holes in rows:
        print(f'[[surroundings.add]]\nkind = "farmland"\nnote = "lawn, {ref} ({area:.0f} m2)"')
        print(f"polygon = [{ll(outer)}]\n")
        for h in holes:
            print(f'[[surroundings.add]]\nkind = "grass"\nnote = "courtyard of {ref}"')
            print(f"polygon = [{ll(h)}]\n")


if __name__ == "__main__":
    if "--lawns" in sys.argv:
        lawns()
    else:
        build()
