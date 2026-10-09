"""Landmark models of the Red Bull Ring: assets/tracks/red_bull_ring/landmarks/*.glb.

    .venv/bin/python tools/track/landmarks/red_bull_ring.py

Low-poly, no textures; surfaces carry the scenery material names so the game gives them its
materials, the colour is the vertex colour (see scripts/track/scenery.gd). Model frame: metres,
y up, origin on the ground. Placed by assets/tracks/red_bull_ring/landmarks.json.

Real sizes and their sources:
  * Bull of Spielberg (Clemens Neugebauer / Martin Koelldorfer, 2012): Corten steel bull
    leaping through a steel arch, about 18 m high with the arch (motogp.com circuit guide:
    "18-metre-high landmark"; steiermark.com "Der Bulle am Red Bull Ring": 17.2 m), horns
    7 m from tip to tip and gilded. Proportions from photographs (Wikimedia Commons, "2021 4
    Hours of Red Bull Ring - The Bull"): the arch is a narrow parabola whose top stands well
    above the bull's back, the bull's hind hooves are on the ground, the forelegs are tucked.
  * voestalpine wing (2014): the building in the middle of the main grandstand, 92 m long
    and 20 m wide (voestalpine press release of 10 April 2014; lectura.press, 13 April 2015),
    shaped like a rear wing: a dark faceted body that hangs over the back of the grandstand
    under a silver wing roof. Its height is an estimate from photographs (Commons,
    "Voestalpine Tribuene Spielberg"): about 1.5 times the grandstand roof.
  * Gantries: the steel truss bridges with advertising boards that span the track (aerial
    imagery shows them at about seven places round the lap; landmarks.json places the five
    whose feet can stand behind the game's barrier lines), and the start lights gantry. Span
    and height are estimates from the imagery; the boards hang about 7 m above the road.
    Landmarks have no collision, so nothing of them may stand inside the barriers.
"""
import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "cad" / "track"))
import scenery_glb as sg  # noqa: E402

OUT = ROOT / "assets" / "tracks" / "red_bull_ring" / "landmarks"
UP = np.array([0.0, 1.0, 0.0])


def lin(r, g, b, a=0.0):
    """sRGB (as seen on screen) -> the linear RGBA the vertex colours are in."""
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in (r, g, b)) + (a,)


CORTEN = lin(0.40, 0.20, 0.12)
CORTEN_DARK = lin(0.30, 0.14, 0.09)
GOLD = lin(0.86, 0.66, 0.16)
ARCH = lin(0.56, 0.57, 0.56)
STEEL = lin(0.30, 0.32, 0.35)
SILVER = lin(0.78, 0.80, 0.82)
ANTHRACITE = lin(0.20, 0.21, 0.23)
GLASS = lin(0.36, 0.46, 0.54, 1.0)
NAVY = lin(0.06, 0.10, 0.28)
RED = lin(0.80, 0.08, 0.10)
WHITE = lin(0.93, 0.93, 0.91)
BLACK = lin(0.05, 0.05, 0.06)


def new_mesh():
    # One chunk that holds the whole model: a single node in the glb.
    mesh = sg.SceneryMesh(-1000.0, -1000.0, 2000.0)
    mesh.anchor(0.0, 0.0)
    return mesh


def hexa(mesh, material, corners, colour):
    """A solid with eight corners: ``corners`` = the bottom ring (4) then the top ring (4),
    both in the same sense."""
    v = [np.asarray(c, dtype=np.float64) for c in corners]
    c = np.mean(v, axis=0)
    y0 = min(p[1] for p in v)
    for f in ((0, 1, 2, 3), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)):
        mesh.face(material, [v[k] for k in f], None, colour, y0, away_from=c)


def beam(mesh, material, p0, p1, w0, w1, colour, h0=None, h1=None, side=None):
    """A bar from ``p0`` to ``p1``, ``w`` wide and ``h`` deep (default: square) at each end.
    ``side`` fixes the width direction; without it the width is horizontal."""
    p0, p1 = np.asarray(p0, dtype=np.float64), np.asarray(p1, dtype=np.float64)
    d = p1 - p0
    d /= np.linalg.norm(d)
    if side is None:
        side = np.cross(d, UP)
        if np.linalg.norm(side) < 1e-6:
            side = np.array([1.0, 0.0, 0.0])
    side = np.asarray(side, dtype=np.float64)
    side = side - d * float(side @ d)
    side /= np.linalg.norm(side)
    top = np.cross(side, d)
    h0 = w0 if h0 is None else h0
    h1 = w1 if h1 is None else h1
    ring = lambda p, w, h: [p - side * w / 2 - top * h / 2, p + side * w / 2 - top * h / 2,
                            p + side * w / 2 + top * h / 2, p - side * w / 2 + top * h / 2]
    hexa(mesh, material, ring(p0, w0, h0) + ring(p1, w1, h1), colour)


def loft(mesh, material, sections, colour, sides=8):
    """Skin over elliptical sections [(centre xyz, half width, half height), ...] that follow
    one another along z; the two ends are closed."""
    rings = []
    for c, hw, hh in sections:
        ang = np.arange(sides) * (2.0 * math.pi / sides) + math.pi / sides
        rings.append(np.stack([c[0] + hw * np.cos(ang), c[1] + hh * np.sin(ang), np.full(sides, c[2])], axis=1))
    for a, b in zip(rings[:-1], rings[1:]):
        mid = 0.5 * (a.mean(axis=0) + b.mean(axis=0))
        for k in range(sides):
            j = (k + 1) % sides
            mesh.face(material, [a[k], a[j], b[j], b[k]], None, colour, away_from=mid)
    mesh.face(material, rings[0], None, colour, away_from=rings[1].mean(axis=0))
    mesh.face(material, rings[-1], None, colour, away_from=rings[-2].mean(axis=0))


# ----------------------------------------------------------------------------- the bull
def bull():
    """The bull heads along -z; the arch stands across it, a little behind the shoulders."""
    mesh = new_mesh()
    # Body, from the rump (z > 0) to the muzzle: the back climbs to the shoulder hump and
    # the head is carried low, as in a charge.
    loft(mesh, "metal", [
        ((0.0, 5.9, 6.2), 1.2, 1.4),
        ((0.0, 6.5, 4.6), 1.8, 2.0),
        ((0.0, 7.1, 1.5), 1.9, 2.1),
        ((0.0, 7.9, -1.5), 2.2, 2.6),
        ((0.0, 8.5, -3.6), 2.2, 2.9),
        ((0.0, 7.9, -5.6), 1.6, 2.1),
        ((0.0, 6.9, -7.2), 1.1, 1.4),
        ((0.0, 6.0, -8.7), 0.65, 0.75),
    ], CORTEN)
    for sx in (-1.0, 1.0):
        # Hind legs: thigh, then the shank stretched back down to the hoof on the ground.
        beam(mesh, "metal", (sx * 1.3, 6.2, 4.6), (sx * 1.4, 3.4, 5.8), 1.5, 0.9, CORTEN_DARK)
        beam(mesh, "metal", (sx * 1.4, 3.4, 5.8), (sx * 1.4, 0.0, 8.4), 0.9, 0.55, CORTEN_DARK)
        # Forelegs, tucked under the chest.
        beam(mesh, "metal", (sx * 1.3, 6.4, -2.6), (sx * 1.3, 3.9, -4.6), 1.2, 0.7, CORTEN_DARK)
        beam(mesh, "metal", (sx * 1.3, 3.9, -4.6), (sx * 1.3, 3.0, -2.6), 0.7, 0.45, CORTEN_DARK)
        # Horns: 7 m from tip to tip, gilded.
        beam(mesh, "metal", (sx * 0.8, 7.5, -7.0), (sx * 2.9, 7.7, -7.9), 0.55, 0.42, GOLD)
        beam(mesh, "metal", (sx * 2.9, 7.7, -7.9), (sx * 3.5, 8.5, -9.6), 0.42, 0.08, GOLD)
    # Tail, thrown up.
    beam(mesh, "metal", (0.0, 6.8, 6.6), (0.0, 8.4, 8.4), 0.35, 0.25, CORTEN_DARK)
    beam(mesh, "metal", (0.0, 8.4, 8.4), (0.0, 7.2, 9.6), 0.25, 0.5, CORTEN_DARK)
    # The arch: a parabola 17.5 m high over a 13 m base, turned 25 degrees to the bull's
    # axis and leaning forward over its back; the section tapers from 2.2 m to 1.3 m.
    height, half = 17.5, 6.5
    turn = math.radians(25.0)
    ax = np.array([math.cos(turn), 0.0, math.sin(turn)])
    lean = np.array([-math.sin(turn), 0.0, math.cos(turn)])
    base = np.array([0.0, 0.0, -0.8])
    n = 14
    pts, widths = [], []
    for k in range(n + 1):
        u = -1.0 + 2.0 * k / n
        y = height * (1.0 - u * u)
        pts.append(base + ax * (half * u) + UP * y + lean * (0.08 * y))
        widths.append(2.2 - 0.9 * (y / height))
    for k in range(n):
        beam(mesh, "concrete", pts[k], pts[k + 1], widths[k], widths[k + 1], ARCH,
             h0=0.55 * widths[k], h1=0.55 * widths[k + 1], side=lean)
    # The knoll the sculpture stands on. Its sides reach 3 m down: the ground under it slopes
    # by 2 m, and landmarks.json lifts the model so that the top clears the uphill side.
    sg.prism(mesh, sg.ngon(0.0, 0.0, 11.0, 10), [], -3.0, 0.02, "concrete", "concrete",
             lin(0.30, 0.44, 0.17), lin(0.30, 0.44, 0.17), 0.0)
    return mesh


# ----------------------------------------------------------------------------- the wing
def wing():
    """Local x along the grandstand, -z towards the track. The body is 92 x 20 m."""
    mesh = new_mesh()
    L, W = 46.0, 10.0
    # Plinth: the core the body rests on, set back from the body's edges.
    sg.prism(mesh, np.array([[-34.0, -6.0], [34.0, -6.0], [34.0, 8.0], [-34.0, 8.0]]), [], -2.0, 10.0,
             "building_wall", "building_roof", lin(0.34, 0.35, 0.37, 0.0), ANTHRACITE, 0.0)
    # Body: faceted, the ends raked like the end plates of a wing, glazed towards the track.
    y0, y1 = 10.0, 19.0
    bottom = [(-L + 6.0, y0, -W + 2.0), (L - 6.0, y0, -W + 2.0), (L - 6.0, y0, W), (-L + 6.0, y0, W)]
    top = [(-L, y1, -W - 2.0), (L, y1, -W - 2.0), (L, y1, W), (-L, y1, W)]
    hexa(mesh, "metal", bottom + top, ANTHRACITE)
    # Glass band on the raked front, proud of it by 0.15 m.
    def front(x, t):
        return np.array([x, y0 + t * (y1 - y0), (-W + 2.0) + t * (-4.0) - 0.15])
    mesh.face("building_glass", [front(-L + 9.0, 0.30), front(L - 9.0, 0.30), front(L - 6.0, 0.85),
                                 front(-L + 6.0, 0.85)], np.array([0.0, -0.4, -1.0]), GLASS, y0)
    # The wing roof: a thin silver aerofoil, higher towards the track, overhanging all round.
    xs = (-L - 3.0, L + 3.0)
    profile = [(-W - 7.0, 23.0, 0.25), (-W + 1.0, 22.3, 1.3), (W - 2.0, 20.4, 0.9), (W + 4.0, 19.4, 0.2)]
    for (za, ya, ta), (zb, yb, tb) in zip(profile[:-1], profile[1:]):
        hexa(mesh, "metal", [(xs[0], ya - ta, za), (xs[1], ya - ta, za), (xs[1], yb - tb, zb), (xs[0], yb - tb, zb),
                             (xs[0], ya, za), (xs[1], ya, za), (xs[1], yb, zb), (xs[0], yb, zb)], SILVER)
    # Raking struts that carry the roof at both ends.
    for sx in (-1.0, 1.0):
        beam(mesh, "metal", (sx * (L - 2.0), 0.0, W + 2.0), (sx * (L + 1.0), 20.0, W - 1.0), 1.2, 0.8, STEEL)
        beam(mesh, "metal", (sx * (L - 4.0), 10.0, -W + 1.0), (sx * (L + 1.0), 21.6, -W - 4.0), 0.9, 0.6, STEEL)
    return mesh


# ----------------------------------------------------------------------------- gantries
def truss(mesh, span, clear, depth, colour):
    """Two legs and a box truss whose lower edge is ``clear`` above the road."""
    half = 0.5 * span
    for sx in (-1.0, 1.0):
        for sz in (-1.0, 1.0):
            beam(mesh, "metal", (sx * half, -2.0, sz * 0.9), (sx * half, clear + depth, sz * 0.9), 0.45, 0.45, colour)
        for y in (0.33, 0.66):
            beam(mesh, "metal", (sx * half, y * clear, -0.9), (sx * half, y * clear, 0.9), 0.25, 0.25, colour)
    for sz in (-1.0, 1.0):
        for y in (clear, clear + depth):
            beam(mesh, "metal", (-half, y, sz * 0.9), (half, y, sz * 0.9), 0.35, 0.35, colour)
    bays = max(4, int(round(span / 4.0)))
    for k in range(bays):
        xa, xb = -half + span * k / bays, -half + span * (k + 1) / bays
        lo, hi = (clear, clear + depth) if k % 2 == 0 else (clear + depth, clear)
        for sz in (-1.0, 1.0):
            beam(mesh, "metal", (xa, lo, sz * 0.9), (xb, hi, sz * 0.9), 0.18, 0.18, colour)


def board(mesh, x0, x1, y0, y1, z, colour, facing):
    # "concrete" is the matt material that shows the vertex colour as painted ("metal" would
    # mirror the sky).
    mesh.face("concrete", [(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], np.array([0.0, 0.0, facing]), colour, y0)


def gantry():
    """Advertising bridge over the track. -z is the direction of travel, so the boards on
    +z face the oncoming cars. 44 m between the feet, so that they stand behind the barrier
    lines of a straight (road edge + 10 m), 7 m clear."""
    mesh = new_mesh()
    clear = 7.0
    truss(mesh, 44.0, clear, 2.4, STEEL)
    for z, facing in ((1.12, 1.0), (-1.12, -1.0)):
        board(mesh, -15.0, 15.0, clear - 0.2, clear + 2.6, z, NAVY, facing)
        board(mesh, -15.0, 15.0, clear - 0.2, clear + 0.25, z + 0.02 * facing, RED, facing)
        board(mesh, -4.5, 4.5, clear + 0.7, clear + 2.1, z + 0.02 * facing, WHITE, facing)
    return mesh


def start_gantry():
    """The start lights: a lighter truss with the five-light panel over the middle of the road."""
    mesh = new_mesh()
    clear = 7.5
    truss(mesh, 36.0, clear, 1.6, lin(0.62, 0.63, 0.64))
    sg.box(mesh, "concrete", (-3.2, clear - 1.5, 0.95), (3.2, clear + 0.1, 1.35), BLACK)
    for k in range(5):
        x = -2.4 + 1.2 * k
        for y in (clear - 0.55, clear - 1.1):
            board(mesh, x - 0.22, x + 0.22, y - 0.22, y + 0.22, 1.37, RED, 1.0)
    return mesh


def main():
    for name, build in (("bull", bull), ("voestalpine_wing", wing), ("gantry", gantry),
                        ("start_gantry", start_gantry)):
        info = sg.write_glb(OUT / f"{name}.glb", build(), name, "tools/track/landmarks/red_bull_ring.py")
        print(f"{name}.glb: {info['triangles']} triangles, {info['bytes']} bytes")


if __name__ == "__main__":
    main()
