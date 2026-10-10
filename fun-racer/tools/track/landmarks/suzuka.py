"""Landmark models of Suzuka: the Ferris wheel of the amusement park behind the Last Curve
and the two gantries over the pit straight.

    .venv/bin/python tools/track/landmarks/suzuka.py        (from fun-racer/)

writes assets/tracks/suzuka/landmarks/*.glb; landmarks.json in the track folder places them.
Surfaces carry the scenery material names, so the game gives them its own materials and
takes the colour from the vertex colour (see scripts/track/scenery.gd).

Dimensions
  * Ferris wheel ("Circuit Wheel", Suzuka Circuit Park): no published figure was found. On the
    GSI seamless orthophoto (0.49 m per pixel) the wheel lies edge-on as a 50 m long white
    line beside its red A-frame, which gives a 48 m wheel; the axle is put at 28.5 m so the
    lowest gondola clears the boarding platform, 52.7 m to the top of the rim.
    Estimate, good to a few metres. White rim and spokes, red legs, gondolas in mixed colours.
  * Gantries: the orthophoto shows one across the road at the timing line and the shadow of
    a second one at the grid's start line. The posts follow the left wall and the pit
    wall there; the 6.5 m clearance is the usual one of a start gantry (estimate).

Model axes: the wheel stands in the local x-y plane with its axle along z, origin on the
ground under the axle. A gantry spans the road along x, origin on the road centre, and faces
the oncoming cars with +z (a landmark placed by lap distance looks along the lap with -z).
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "cad" / "track"))

import scenery_glb as sg  # noqa: E402

OUT = ROOT / "assets" / "tracks" / "suzuka" / "landmarks"


def lin(r, g, b, a=0.0):
    """sRGB (0..1) -> the linear vertex colour the scenery materials expect."""
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in (r, g, b)) + (a,)


WHITE = lin(0.93, 0.93, 0.92)
RED = lin(0.80, 0.10, 0.09)
STEEL = lin(0.30, 0.32, 0.35)
DARK = lin(0.07, 0.07, 0.08)
CONCRETE = lin(0.66, 0.65, 0.62)
GONDOLAS = [lin(0.82, 0.12, 0.10), lin(0.95, 0.78, 0.10), lin(0.12, 0.35, 0.70), lin(0.15, 0.55, 0.30),
            lin(0.93, 0.50, 0.10), lin(0.92, 0.92, 0.90)]


def new_mesh():
    # The origin in the middle of one chunk: the whole model is one node.
    mesh = sg.SceneryMesh(-0.5 * sg.CHUNK, -0.5 * sg.CHUNK)
    mesh.anchor(0.0, 0.0)
    return mesh


def beam(mesh, material, a, b, thickness, colour):
    """A square bar from ``a`` to ``b`` (x, y, z), four sides, no end caps."""
    a, b = np.asarray(a, dtype=float), np.asarray(b, dtype=float)
    axis = b - a
    length = float(np.linalg.norm(axis))
    if length < 1e-6:
        return
    axis /= length
    ref = np.array([0.0, 1.0, 0.0]) if abs(axis[1]) < 0.9 else np.array([1.0, 0.0, 0.0])
    u = np.cross(axis, ref)
    u /= np.linalg.norm(u)
    v = np.cross(axis, u)
    h = 0.5 * thickness
    corners = [u * h + v * h, -u * h + v * h, -u * h - v * h, u * h - v * h]
    mid = 0.5 * (a + b)
    for k in range(4):
        p, q = corners[k], corners[(k + 1) % 4]
        mesh.face(material, [a + p, a + q, b + q, b + p], None, colour, 0.0, away_from=mid)


def ferris_wheel():
    mesh = new_mesh()
    radius, axle, half = 24.0, 28.5, 1.3
    nodes = 24
    hub = np.array([0.0, axle, 0.0])
    ring = [hub + radius * np.array([math.cos(2 * math.pi * k / nodes), math.sin(2 * math.pi * k / nodes), 0.0])
            for k in range(nodes)]
    for z in (-half, half):
        dz = np.array([0.0, 0.0, z])
        for k in range(nodes):
            beam(mesh, "concrete", ring[k] + dz, ring[(k + 1) % nodes] + dz, 0.45, WHITE)
            if k % 2 == 0:
                beam(mesh, "concrete", hub + dz, ring[k] + dz, 0.22, WHITE)
        # A lighter inner ring ties the spokes together, as on the real wheel.
        for k in range(0, nodes, 2):
            a = hub + 0.55 * (ring[k] - hub) + dz
            b = hub + 0.55 * (ring[(k + 2) % nodes] - hub) + dz
            beam(mesh, "concrete", a, b, 0.18, WHITE)
    for k in range(nodes):
        beam(mesh, "concrete", ring[k] - [0, 0, half], ring[k] + [0, 0, half], 0.25, WHITE)
        c = ring[k] - np.array([0.0, 1.9, 0.0])     # the gondola hangs under its pivot
        sg.box(mesh, "building_roof", (c[0] - 0.95, c[1] - 1.1, -0.95), (c[0] + 0.95, c[1] + 1.1, 0.95),
               GONDOLAS[k % len(GONDOLAS)])
    # A-frame: two red legs each side of the wheel, an axle box, the boarding platform.
    for z in (-3.2, 3.2):
        for x in (-10.0, 10.0):
            beam(mesh, "concrete", (0.0, axle, math.copysign(2.0, z)), (x, 0.0, z * 1.6), 1.0, RED)
        beam(mesh, "concrete", (-5.0, axle * 0.5, z * 1.3), (5.0, axle * 0.5, z * 1.3), 0.5, RED)
    sg.box(mesh, "concrete", (-1.2, axle - 1.2, -2.4), (1.2, axle + 1.2, 2.4), RED)
    sg.box(mesh, "concrete", (-9.0, -1.0, -6.5), (9.0, 1.2, 6.5), CONCRETE)
    sg.box(mesh, "building_roof", (-7.0, 4.4, -3.2), (7.0, 4.7, 3.2), WHITE)       # platform canopy
    for x in (-6.5, 6.5):
        for z in (-2.9, 2.9):
            sg.box(mesh, "metal", (x - 0.12, 1.2, z - 0.12), (x + 0.12, 4.4, z + 0.12), STEEL)
    return mesh


def gantry(left, right, clear, board=None, lights=False):
    """Two posts at x = -left and x = right and a truss across the road. ``board`` =
    (height, colour, band colour) puts a sign on the truss, ``lights`` the five start lights
    under it."""
    mesh = new_mesh()
    span = left + right
    top = clear + 1.3
    for sx in (-left, right):
        sg.box(mesh, "metal", (sx - 0.35, -0.5, -0.35), (sx + 0.35, top, 0.35), STEEL)
    # Truss: four chords and a zigzag on the two faces.
    for y in (clear, top):
        for z in (-0.6, 0.6):
            beam(mesh, "metal", (-left, y, z), (right, y, z), 0.22, STEEL)
    bays = int(round(span / 2.0))
    for z in (-0.6, 0.6):
        for k in range(bays):
            x0, x1 = -left + span * k / bays, -left + span * (k + 1) / bays
            y0, y1 = (clear, top) if k % 2 == 0 else (top, clear)
            beam(mesh, "metal", (x0, y0, z), (x1, y1, z), 0.12, STEEL)
    if board is not None:
        height, colour, band = board
        a, b = -left + 1.5, right - 1.5
        sg.box(mesh, "concrete", (a, top - 0.2, 0.62), (b, top - 0.2 + height, 0.74), colour)
        sg.box(mesh, "concrete", (a, top - 0.2, 0.74), (b, top + 0.25, 0.78), band)
    if lights:
        sg.box(mesh, "concrete", (-3.6, clear - 1.0, 0.45), (3.6, clear - 0.05, 0.75), DARK)
        for k in range(5):
            cx = -2.8 + 1.4 * k
            for cy in (clear - 0.72, clear - 0.33):
                sg.box(mesh, "emissive_light", (cx - 0.16, cy - 0.16, 0.75), (cx + 0.16, cy + 0.16, 0.80),
                       (1.0, 1.0, 1.0, 0.0))
    return mesh


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    models = {
        "ferris_wheel": ferris_wheel(),
        # 15 m of road: the left post behind the wall 4 m out, the right one on the pit wall
        # (9.3 to 9.9 m from the centreline, see the recipe), never in the pit lane.
        "start_gantry": gantry(12.5, 9.6, 6.5, lights=True),
        "sign_bridge": gantry(12.5, 9.6, 6.5, board=(2.0, WHITE, RED)),
    }
    for name, mesh in models.items():
        info = sg.write_glb(OUT / f"{name}.glb", mesh, name, "fun-racer tools/track/landmarks/suzuka.py")
        print(f"{name}.glb: {info['triangles']} triangles, {info['bytes'] / 1024:.0f} kB")


if __name__ == "__main__":
    main()
