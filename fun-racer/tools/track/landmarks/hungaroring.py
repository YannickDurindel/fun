"""Landmark models of the Hungaroring: assets/tracks/hungaroring/landmarks/*.glb.

    .venv/bin/python tools/track/landmarks/hungaroring.py

Low-poly, untextured, coloured by vertex colour, with the scenery material names so that the
game gives them its own materials (see scripts/track/scenery.gd). Placed by
assets/tracks/hungaroring/landmarks.json.

Model frame (the frame of an "s" placement with yaw 0): x = to the right of the road in race
direction, y = up from the road, -z = along the lap. Every model is built around its own
origin; which side faces the track is said per model.

Dimensions and where they come from:
  * Main building (pit building, 2025): "more than 340 metres" long (International
    Architecture & Design Awards 2026 entry of the Hungaroring), 341 m by about 25 m on Esri
    World Imagery (2025, 0.4 m per pixel). Four levels: 36 race garages with anthracite doors,
    a glazed hospitality floor behind a balcony, a glazed and louvred floor above it, a white
    roof edge and a roof terrace; dark red portals (press photo of the pit lane, planetf1.com,
    "Huge new pit building unveiled ...", June 2025). Height about 19 m: estimate, four
    levels counted on that photo against the 2.6 m garage doors.
  * Main grandstand (2025): covered, 10,000 seats (grandprix.com, "F1 touches down at
    revamped Hungaroring", July 2025). Roof 273 m by 29 m on the same imagery, its front edge
    about 11 m from the middle of the track. Two tiers under a flat white roof on slim columns
    (the circuit's rendering, f1technical.net news 25005). Height about 24 m: estimate, from
    the tiers of the rendering.
  * Start gantry: across the 15 m track at the line; estimate of a usual light gantry.
  * Footbridges: steel truss bridges with stair towers, about 30 m between the towers on the
    imagery (between Turns 7 and 8, on the back straight, and two in the last sector).
    Clearance 6 m: estimate.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "cad" / "track"))
import scenery_glb as sg  # noqa: E402

OUT = ROOT / "assets" / "tracks" / "hungaroring" / "landmarks"
GENERATOR = "fun-racer tools/track/landmarks/hungaroring.py"


def lin(r, g, b, windows=0.0):
    """Vertex colour (linear) from an sRGB triple; alpha 1 = a facade with windows."""
    c = np.array([r, g, b], dtype=np.float64)
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    return (float(c[0]), float(c[1]), float(c[2]), float(windows))


WHITE = lin(0.93, 0.93, 0.91)
CONCRETE = lin(0.66, 0.65, 0.62)
ANTHRACITE = lin(0.16, 0.16, 0.17)
DARK_RED = lin(0.45, 0.07, 0.10)
STEEL = lin(0.50, 0.52, 0.55)
RUST = lin(0.42, 0.22, 0.14)
PANEL = lin(0.10, 0.11, 0.14)
GLASS = lin(0.75, 0.82, 0.90, 1.0)
SEAT = lin(1.0, 1.0, 1.0)


def new_mesh():
    mesh = sg.SceneryMesh(-5000.0, -5000.0, 10000.0)   # one chunk: one node per model
    mesh.anchor(0.0, 0.0)
    return mesh


def rect(x0, x1, z0, z1):
    return np.array([[x0, z0], [x1, z0], [x1, z1], [x0, z1]], dtype=np.float64)


def block(mesh, x0, x1, y0, y1, z0, z1, wall, colour, roof="building_roof", roof_colour=None):
    sg.prism(mesh, rect(x0, x1, z0, z1), [], y0, y1, wall, roof, colour,
             roof_colour if roof_colour is not None else colour, 0.0, floor=True)


def slab(mesh, material, corners, thickness, colour):
    """A flat or tilted slab: ``corners`` (4, 3) of its top face, in order round the face."""
    top = np.asarray(corners, dtype=np.float64)
    bottom = top - sg.UP * thickness
    centre = 0.5 * (top.mean(axis=0) + bottom.mean(axis=0))
    mesh.face(material, top, sg.UP, colour)
    mesh.face(material, bottom, -sg.UP, colour)
    for k in range(4):
        j = (k + 1) % 4
        mesh.face(material, [top[k], top[j], bottom[j], bottom[k]], None, colour, away_from=centre)


def write(mesh, name):
    OUT.mkdir(parents=True, exist_ok=True)
    stats = sg.write_glb(OUT / f"{name}.glb", mesh, name, GENERATOR)
    print(f"{name}.glb: {stats['triangles']} triangles, {stats['bytes'] / 1024:.0f} kB")


# ----------------------------------------------------------------------------- pit building
def pit_building():
    """341 m along z, 25 m deep. The pit lane side is -x (the building stands to the right of
    the track); the race-control end is +z (towards Turn 14)."""
    mesh = new_mesh()
    half, x0, x1 = 170.5, -12.5, 12.5
    # Garages: an anthracite ground floor, 36 doors on the pit lane side as darker panels.
    block(mesh, x0, x1, -3.0, 5.6, -half, half, "concrete", ANTHRACITE, "concrete", CONCRETE)
    for k in range(36):
        z = -half + 30.0 + k * 7.9
        mesh.face("metal", [[x0 - 0.05, 0.2, z], [x0 - 0.05, 0.2, z + 6.3], [x0 - 0.05, 4.3, z + 6.3],
                            [x0 - 0.05, 4.3, z]], np.array([-1.0, 0.0, 0.0]), lin(0.24, 0.20, 0.19))
    # White band and the balcony of the hospitality floor.
    slab(mesh, "concrete", [[x0 - 2.5, 6.6, -half], [x1, 6.6, -half], [x1, 6.6, half], [x0 - 2.5, 6.6, half]],
         1.0, WHITE)
    # First floor: glass on the pit lane side, plain wall with windows on the paddock side.
    block(mesh, x0 + 1.0, x1, 6.6, 11.0, -half + 1.0, half - 1.0, "building_glass", GLASS, "concrete", CONCRETE)
    slab(mesh, "concrete", [[x0 - 3.5, 12.0, -half + 20.0], [x1, 12.0, -half + 20.0], [x1, 12.0, half],
                            [x0 - 3.5, 12.0, half]], 1.0, CONCRETE)
    # Second floor, set back under the roof edge.
    block(mesh, x0 + 2.5, x1, 12.0, 16.6, -half + 22.0, half - 1.0, "building_glass", GLASS, "concrete", WHITE)
    # Roof: a white edge that rises towards the pit lane.
    slab(mesh, "concrete", [[x0 - 3.0, 18.8, -half + 18.0], [x1 + 0.5, 17.2, -half + 18.0],
                            [x1 + 0.5, 17.2, half + 0.5], [x0 - 3.0, 18.8, half + 0.5]], 0.7, WHITE)
    # The end that folds down to the first floor at the Turn 1 end.
    slab(mesh, "concrete", [[x0 - 3.0, 18.8, -half + 18.0], [x1 + 0.5, 17.2, -half + 18.0],
                            [x1 + 0.5, 7.0, -half + 2.0], [x0 - 3.0, 7.0, -half + 2.0]], 0.7, WHITE)
    # Dark red portals: race control at the +z end and two more along the front.
    for z0, z1 in ((half - 26.0, half - 2.0), (40.0, 58.0), (-70.0, -52.0)):
        block(mesh, x0 - 0.6, x0 + 3.0, 5.6, 17.0, z0, z1, "building_wall", DARK_RED, "concrete", DARK_RED)
    # Paddock side: stair cores.
    for z in (-120.0, -40.0, 40.0, 120.0):
        block(mesh, x1, x1 + 3.0, -3.0, 17.0, z - 4.0, z + 4.0, "building_wall", lin(0.80, 0.80, 0.78, 1.0))
    write(mesh, "pit_building")


# ----------------------------------------------------------------------------- main grandstand
def main_grandstand():
    """270 m along z. The track side is +x (the stand is on the left of the track)."""
    mesh = new_mesh()
    half = 135.0
    # Lower tier, hospitality band, upper tier.
    lower = rect(1.0, 13.0, -half, half)
    sg.grandstand(mesh, lower, np.array([1.0, 0.0]), 2.8, -3.0, 6.2, SEAT, False)
    block(mesh, -1.0, 1.0, 9.0, 12.6, -half, half, "building_glass", GLASS, "concrete", CONCRETE)
    upper = rect(-11.0, -1.0, -half, half)
    sg.grandstand(mesh, upper, np.array([1.0, 0.0]), 11.6, 9.0, 7.0, SEAT, False)
    # The building behind and under the tiers.
    block(mesh, -15.0, -11.0, -3.0, 20.5, -half, half, "building_wall", lin(0.84, 0.84, 0.82, 1.0),
          "concrete", CONCRETE)
    block(mesh, -11.0, 1.0, -3.0, 9.0, -half, half, "concrete", CONCRETE, "concrete", CONCRETE)
    # Front wall under the first row, and the end walls.
    block(mesh, 12.6, 13.2, -3.0, 4.2, -half, half, "concrete", WHITE, "concrete", WHITE)
    for z in (-half, half - 0.6):
        block(mesh, -11.0, 13.0, -3.0, 4.0, z, z + 0.6, "concrete", WHITE, "concrete", WHITE)
    # Flat roof, rising towards the track and reaching 5 m beyond the first row: a white rim
    # round dark panels, as on the aerial.
    y_back, y_front = 22.4, 24.6
    slab(mesh, "concrete", [[-16.0, y_back, -half - 1.5], [18.0, y_front, -half - 1.5],
                            [18.0, y_front, half + 1.5], [-16.0, y_back, half + 1.5]], 0.8, WHITE)
    slope = (y_front - y_back) / 34.0
    for band in ((-13.0, -1.0), (1.0, 15.0)):
        ya, yb = (y_back + slope * (band[0] + 16.0) + 0.05, y_back + slope * (band[1] + 16.0) + 0.05)
        mesh.face("metal", [[band[0], ya, -half + 2.0], [band[1], yb, -half + 2.0],
                            [band[1], yb, half - 2.0], [band[0], ya, half - 2.0]], sg.UP, PANEL)
    # Slim columns under the roof: one row behind the upper tier, raking props to the front.
    for k in range(19):
        z = -half + 4.5 + k * (2.0 * half - 9.0) / 18.0
        sg.box(mesh, "metal", (-11.6, 20.0, z - 0.25), (-11.0, y_back + slope * 5.0 - 0.8, z + 0.25), WHITE)
        a, b = np.array([-1.0, 12.6, z]), np.array([9.0, y_back + slope * 25.0 - 0.8, z])
        w = np.array([0.0, 0.0, 0.25])
        for side in (-1.0, 1.0):
            q = [a + w * side, b + w * side, b + w * side + [0.5, 0.0, 0.0], a + w * side + [0.5, 0.0, 0.0]]
            mesh.face("metal", q, np.array([0.0, 0.0, side]), WHITE)
        mesh.face("metal", [a - w, a + w, b + w, b - w], np.array([-1.0, 0.3, 0.0]), WHITE)
        mesh.face("metal", [a - w + [0.5, 0, 0], a + w + [0.5, 0, 0], b + w + [0.5, 0, 0], b - w + [0.5, 0, 0]],
                  np.array([1.0, -0.3, 0.0]), WHITE)
    write(mesh, "main_grandstand")


# ----------------------------------------------------------------------------- start gantry
def start_gantry():
    """Across the road at the line: posts 10 m either side of the centre, lights facing the
    grid (+z, against the race direction)."""
    mesh = new_mesh()
    for x in (-10.0, 10.0):
        sg.box(mesh, "metal", (x - 0.3, -1.0, -0.3), (x + 0.3, 8.2, 0.3), STEEL)
    sg.box(mesh, "metal", (-10.3, 6.6, -0.45), (10.3, 8.2, 0.45), ANTHRACITE)
    for k in range(5):      # the five start lights
        x = -3.2 + k * 1.6
        sg.box(mesh, "metal", (x - 0.45, 5.6, 0.1), (x + 0.45, 6.6, 0.5), PANEL)
        sg.box(mesh, "emissive_light", (x - 0.25, 5.8, 0.5), (x + 0.25, 6.4, 0.56), lin(0.9, 0.05, 0.03))
    write(mesh, "start_gantry")


# ----------------------------------------------------------------------------- footbridges
def footbridge(name, colour, banner):
    """Truss footbridge across the road (along x), 32 m between its stair towers, deck 6 m up."""
    mesh = new_mesh()
    half, y, w = 16.0, 6.0, 1.5
    slab(mesh, "metal", [[-half, y, -w], [half, y, -w], [half, y, w], [-half, y, w]], 0.35, colour)
    for z in (-w, w):       # side panels (banners) and the top chord
        sg.box(mesh, "metal", (-half, y, z - 0.06), (half, y + 1.3, z + 0.06), banner)
        sg.box(mesh, "metal", (-half, y + 2.6, z - 0.1), (half, y + 2.8, z + 0.1), colour)
        for k in range(9):  # posts of the truss
            x = -half + k * 4.0
            sg.box(mesh, "metal", (x - 0.08, y + 1.3, z - 0.08), (x + 0.08, y + 2.6, z + 0.08), colour)
    for k in range(9):      # roof bows
        x = -half + k * 4.0
        sg.box(mesh, "metal", (x - 0.08, y + 2.6, -w), (x + 0.08, y + 2.75, w), colour)
    for side in (-1.0, 1.0):   # stair towers
        x = side * (half + 1.6)
        sg.box(mesh, "metal", (x - 1.6, -2.0, -3.0), (x + 1.6, y + 2.8, 3.0), colour)
        sg.box(mesh, "concrete", (x - 1.9, -2.0, -3.3), (x + 1.9, 0.4, 3.3), CONCRETE)
    write(mesh, name)


if __name__ == "__main__":
    pit_building()
    main_grandstand()
    start_gantry()
    footbridge("footbridge_rust", RUST, lin(0.55, 0.30, 0.20))
    footbridge("footbridge_white", lin(0.85, 0.86, 0.88), lin(0.92, 0.92, 0.90))
