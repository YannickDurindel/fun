#!/usr/bin/env python3
"""Parametric endurance prototype body (Le Mans Hypercar / LMDh style), modelled with build123d.

Regenerate the Godot asset with one command (from the repo root):

    .venv/bin/python cad/body/endurance_body.py     # -> assets/car/endurance/body.glb

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.

Setup (once): ``python3 -m venv .venv && .venv/bin/pip install -r cad/requirements.txt``
``--out PATH`` writes the GLB somewhere else (to try a change without touching the game).

Frame: same as ``f1_body.py``: CAD x = backward, y = right, z = up, which maps 1:1
(cyclic permutation) onto the Godot car-local frame of ``scripts/car/car.gd``:
forward = -Z, up = +Y, right = +X. The origin is at axle height, ground at z = -0.36.

Dimensions (LMH / LMDh rules): length 5.00 m, width 2.00 m, roof 1.06 m above the ground
(roof intake 1.10 m), wheelbase 3.10 m: front axle x = -1.55, rear axle x = +1.55.

Wheels: none here. The car reuses the F1 wheel assets (``cad/wheels/f1_wheels.py``: 18 inch
rims, front tyre R 0.33 m x 0.30 m, rear R 0.36 m x 0.38 m), which match an LMH's 18 inch
rims and ~0.71 m tyres closely enough. Wheel centres the game must use (Godot car-local,
like ``Car.WHEEL_OFFSETS``): front (+-0.80, 0, -1.55), rear (+-0.78, 0, +1.55). The arches
are cut for those positions with 4 cm of clearance round the tyre.

Every part is a build123d solid (lofts through superellipse sections, airfoil extrusions,
plates), grouped by material and written as one named mesh per material. The first eight
materials are the F1 body's, in the same order, because ``scenes/car/car_body_visual.tscn``
overrides nodes by name and index, ``body_motion.gd`` moves Helmet + Visor as the driver's
head and ``bot_manager.gd`` recolours Livery / LiveryWhite / Accent / Helmet. Two materials
are added after them: Glass (the canopy glazing; not Visor, which the game animates) and
Headlight (white LED strips; Light stays the red rear light).
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

from build123d import (
    Axis,
    Box,
    Circle,
    Edge,
    Location,
    Part,
    Plane,
    Solid,
    Sphere,
    Vector,
    Wire,
    Face,
    extrude,
    fillet,
    mirror,
    scale,
    sweep,
)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from glb_writer import Material, MeshGroup, write_glb  # noqa: E402
from profiles import Section, airfoil_face  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
OUT_PATH = REPO / "assets" / "car" / "endurance" / "body.glb"

# --------------------------------------------------------------------------
# Global dimensions (metres, CAD frame)
# --------------------------------------------------------------------------
GROUND_Z = -0.36
FLOOR_BOTTOM_Z = -0.29  # 7 cm ride height
FLOOR_T = 0.02
FRONT_AXLE_X = -1.55
REAR_AXLE_X = 1.55
NOSE_X = -2.50  # splitter reaches -2.55; body length 5.00 m
TAIL_X = 2.50
HALF_WIDTH = 1.00  # 2.00 m over the fenders
ROOF_Z = GROUND_Z + 1.06

FRONT_WHEEL_Y, REAR_WHEEL_Y = 0.80, 0.78
FRONT_TYRE_R, REAR_TYRE_R = 0.33, 0.36
ARCH_CLEARANCE = 0.04

RW_HALF_SPAN = 0.90  # rear wing 1.80 m wide, between the endplates

TESS_TOL = 0.0015  # linear deflection (m)
TESS_ANG = 0.18  # angular deflection (rad)

# --------------------------------------------------------------------------
# Materials: the F1 body's eight in its order (see the docstring), then the extras.
# --------------------------------------------------------------------------
MATERIALS = {
    "Livery": Material("Livery", (0.020, 0.075, 0.33, 1.0), 0.35, 0.30),
    "LiveryWhite": Material("LiveryWhite", (0.86, 0.87, 0.89, 1.0), 0.05, 0.32),
    "Accent": Material("Accent", (0.85, 0.05, 0.06, 1.0), 0.10, 0.30),
    "Carbon": Material("Carbon", (0.035, 0.037, 0.042, 1.0), 0.20, 0.28),
    "Metal": Material("Metal", (0.80, 0.62, 0.32, 1.0), 1.0, 0.25),
    "Helmet": Material("Helmet", (0.95, 0.78, 0.05, 1.0), 0.05, 0.22),
    "Visor": Material("Visor", (0.02, 0.02, 0.03, 1.0), 0.6, 0.08),
    "Light": Material("Light", (0.6, 0.0, 0.0, 1.0), 0.0, 0.4, emissive=(1.0, 0.05, 0.03)),
    "Glass": Material("Glass", (0.05, 0.07, 0.10, 1.0), 0.0, 0.06),
    "Headlight": Material("Headlight", (0.9, 0.9, 0.85, 1.0), 0.0, 0.3, emissive=(1.0, 0.96, 0.88)),
}


@dataclass
class PartSpec:
    name: str
    shape: Part | Solid
    material: str
    # False for extruded wing elements/plates: see MeshGroup.add_shape.
    surface_control: bool = True


def loft(sections: list[Section]) -> Solid:
    return Solid.make_loft([s.wire() for s in sections], ruled=False)


def xz_plate(points: list[tuple[float, float]], y0: float, thickness: float) -> Part:
    """Polygon in the XZ plane at y0, extruded toward +y by ``thickness``."""
    wire = Wire.make_polygon([Vector(x, y0, z) for x, z in points], close=True)
    return extrude(Face(wire), amount=thickness, dir=(0, 1, 0))


def xy_plate(points: list[tuple[float, float]], z0: float, thickness: float) -> Part:
    wire = Wire.make_polygon([Vector(x, y, z0) for x, y in points], close=True)
    return extrude(Face(wire), amount=thickness, dir=(0, 0, 1))


def try_fillet(shape, edges, radius: float):
    try:
        return fillet(edges, radius)
    except Exception as exc:  # OCC fillets can fail on awkward topology
        print(f"  fillet r={radius} skipped: {exc}")
        return shape


def tube(points: list[tuple[float, float, float]], radius: float) -> Part:
    path = Wire([Edge.make_spline([Vector(*p) for p in points])])
    plane = Plane(origin=path @ 0, z_dir=path % 0)
    return sweep(plane * Circle(radius), path=path)


def wing_element(le_x, le_z, chord, aoa, y_from, y_to, camber=0.06, thickness=0.10) -> Part:
    face = airfoil_face(le_x, le_z, y_from, chord, aoa, camber=camber, thickness=thickness)
    return extrude(face, amount=y_to - y_from, dir=(0, 1, 0))


def both_sides(shape) -> list:
    return [shape, mirror(shape, about=Plane.XZ)]


def box(cx, cy, cz, dx, dy, dz) -> Part:
    return Box(dx, dy, dz).locate(Location((cx, cy, cz)))


def arch_cutter(axle_x: float, tyre_r: float, y0: float) -> Solid:
    """Cylinder along y (from y0 outward past the body side) that opens a wheel arch."""
    return Solid.make_cylinder(tyre_r + ARCH_CLEARANCE, HALF_WIDTH + 0.2 - y0,
                               Plane(origin=(axle_x, y0, 0.0), z_dir=(0, 1, 0)))


# --------------------------------------------------------------------------
# Parts
# --------------------------------------------------------------------------
# The bodywork is ONE solid: hull, fenders, doors and engine cover are fused, the wheel
# arches are cut through all of it, and the livery (nose, headlights, tail-light bar, number
# roundels, sills, louvres) is split off that solid, so every colour change is flush with the
# surface, as on the F1 body.

HULL_SECTIONS = [
    # x,      width, z_bot, z_top
    Section(-2.450, 0.860, -0.250, -0.130, n_top=2.6, n_bot=3.0, taper=0.90),
    Section(-2.150, 1.160, -0.285, 0.000, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(-1.550, 1.240, -0.290, 0.090, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(-0.900, 1.300, -0.290, 0.150, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(0.000, 1.340, -0.290, 0.170, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(1.000, 1.340, -0.290, 0.170, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(1.800, 1.300, -0.280, 0.150, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(2.450, 1.300, -0.180, 0.130, n_top=3.0, n_bot=4.0, taper=0.90),
]

# Fenders: tall over the wheels, falling into the doors; their inner half is buried in the hull.
FRONT_FENDER = [
    Section(-2.420, 0.420, -0.230, -0.090, y_center=0.740, n_top=2.6, n_bot=3.0, taper=0.80),
    Section(-2.200, 0.480, -0.270, 0.140, y_center=0.755, n_top=2.8, n_bot=3.5, taper=0.78),
    Section(-1.850, 0.500, -0.280, 0.340, y_center=0.755, n_top=2.8, n_bot=3.5, taper=0.76),
    Section(-1.550, 0.500, -0.280, 0.420, y_center=0.755, n_top=2.8, n_bot=3.5, taper=0.76),
    Section(-1.250, 0.500, -0.280, 0.390, y_center=0.755, n_top=2.8, n_bot=3.5, taper=0.76),
    Section(-0.950, 0.480, -0.285, 0.250, y_center=0.745, n_top=2.8, n_bot=3.5, taper=0.80),
    Section(-0.700, 0.440, -0.285, 0.140, y_center=0.720, n_top=3.0, n_bot=3.5, taper=0.85),
]
DOOR = [
    Section(-0.950, 0.480, -0.285, 0.170, y_center=0.720, n_top=3.2, n_bot=3.5, taper=0.86),
    Section(-0.300, 0.500, -0.290, 0.120, y_center=0.705, n_top=3.2, n_bot=3.5, taper=0.86),
    Section(0.400, 0.500, -0.290, 0.120, y_center=0.705, n_top=3.2, n_bot=3.5, taper=0.86),
    Section(0.950, 0.480, -0.285, 0.170, y_center=0.720, n_top=3.2, n_bot=3.5, taper=0.86),
]
REAR_FENDER = [
    Section(0.700, 0.440, -0.285, 0.150, y_center=0.720, n_top=3.0, n_bot=3.5, taper=0.85),
    Section(1.050, 0.490, -0.285, 0.340, y_center=0.745, n_top=2.8, n_bot=3.5, taper=0.78),
    Section(1.550, 0.500, -0.285, 0.440, y_center=0.755, n_top=2.8, n_bot=3.5, taper=0.76),
    Section(2.000, 0.500, -0.270, 0.410, y_center=0.755, n_top=2.8, n_bot=3.5, taper=0.76),
    Section(2.450, 0.480, -0.180, 0.320, y_center=0.750, n_top=2.8, n_bot=3.2, taper=0.78),
]
ENGINE_COVER = [
    Section(0.450, 1.000, 0.000, 0.600, n_top=2.4, n_bot=3.0, taper=0.58),
    Section(1.050, 0.860, 0.000, 0.460, n_top=2.4, n_bot=3.0, taper=0.60),
    Section(1.750, 0.760, 0.000, 0.330, n_top=2.4, n_bot=3.0, taper=0.66),
    Section(2.450, 0.700, -0.050, 0.220, n_top=2.4, n_bot=3.0, taper=0.72),
]
CANOPY_SECTIONS = [
    Section(-1.150, 0.560, 0.000, 0.110, n_top=2.4, n_bot=3.0, taper=0.62),
    Section(-0.750, 0.960, 0.000, 0.410, n_top=2.4, n_bot=3.0, taper=0.60),
    Section(-0.350, 1.120, 0.000, 0.630, n_top=2.4, n_bot=3.0, taper=0.56),
    Section(0.050, 1.120, 0.000, ROOF_Z, n_top=2.4, n_bot=3.0, taper=0.56),
    Section(0.450, 1.000, 0.000, 0.610, n_top=2.4, n_bot=3.0, taper=0.58),
]
GLASS_X0, GLASS_X1 = -1.05, 0.40   # glazing: windscreen and side windows, the roof above
GLASS_Z0, GLASS_Z1 = 0.25, 0.585


def split(shape, cutter):
    """(shape - cutter, shape & cutter): one livery change, flush with the surface."""
    return shape - cutter, shape & cutter


def mirrored_box(cx, cy, cz, dx, dy, dz) -> Part:
    """A box and its mirror image about y = 0, as one cutter."""
    b = box(cx, cy, cz, dx, dy, dz)
    return b + mirror(b, about=Plane.XZ)


def make_bodywork() -> list[PartSpec]:
    body = loft(HULL_SECTIONS) + loft(ENGINE_COVER)
    for secs in (FRONT_FENDER, DOOR, REAR_FENDER):
        for side in both_sides(loft(secs)):
            body = body + side
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        for c in both_sides(arch_cutter(axle_x, r, 0.50)):
            body = body - c
    out: list[PartSpec] = []

    # Front: red nose band across the whole front, a dark radiator mouth in the middle of it,
    # dark brake-duct openings low on each fender face.
    body, nose = split(body, box(-2.47, 0, 0, 0.30, 2.4, 1.2))
    nose, mouth = split(nose, box(-2.47, 0, -0.175, 0.32, 0.56, 0.075))
    nose, ducts = split(nose, mirrored_box(-2.47, 0.80, -0.185, 0.32, 0.20, 0.06))
    out += [PartSpec("nose", nose, "Accent"), PartSpec("nose_mouth", mouth, "Carbon"),
            PartSpec("brake_ducts", ducts, "Carbon")]

    # LED headlights: a thin blade along the top of each front fender's nose.
    body, leds = split(body, mirrored_box(-2.18, 0.79, 0.085, 0.36, 0.30, 0.030))
    out.append(PartSpec("headlights", leds, "Headlight"))

    # Louvres on top of the front fenders, behind the wheel centre: a carbon panel with slots.
    body, panel = split(body, mirrored_box(-1.24, 0.775, 0.60, 0.42, 0.30, 0.60))
    for k in range(6):
        panel = panel - mirrored_box(-1.40 + 0.065 * k, 0.775, 0.62, 0.028, 0.26, 0.60)
    out.append(PartSpec("louvres", panel, "Carbon"))

    # Tail-light bar across the full width of the tail.
    body, tail = split(body, box(2.47, 0, 0.105, 0.10, 2.4, 0.032))
    out.append(PartSpec("tail_light", tail, "Light"))

    # Dark rear panel between the rear fenders, under the tail lights (gearbox / diffuser exit).
    body, rear_panel = split(body, box(2.47, 0, -0.10, 0.12, 1.06, 0.26))
    out.append(PartSpec("rear_panel", rear_panel, "Carbon"))

    # Carbon sills along the bottom of the doors, between the arches.
    body, sills = split(body, mirrored_box(0.0, 0.85, -0.255, 2.0, 0.40, 0.08))
    out.append(PartSpec("sills", sills, "Carbon"))

    # Number roundels on the doors: a white ring, like the F1 car's.
    def ellipse_rod(rx, rz):
        # Scale about the origin first, then place it: the rod runs along y through the door.
        rod = Solid.make_cylinder(1.0, 0.6, Plane(origin=(0, 0, 0), z_dir=(0, 1, 0)))
        return scale(rod, by=(rx, 1.0, rz)).moved(Location((0.05, 0.45, -0.060)))

    ring = ellipse_rod(0.25, 0.155) - ellipse_rod(0.205, 0.115)
    ring = ring + mirror(ring, about=Plane.XZ)
    body, roundels = split(body, ring)
    out.append(PartSpec("roundels", roundels, "LiveryWhite"))

    out.insert(0, PartSpec("body", body, "Livery"))
    return out


def make_canopy() -> list[PartSpec]:
    canopy = loft(CANOPY_SECTIONS)
    band = box(0.5 * (GLASS_X0 + GLASS_X1), 0, 0.5 * (GLASS_Z0 + GLASS_Z1),
               GLASS_X1 - GLASS_X0, 2.0, GLASS_Z1 - GLASS_Z0)
    shell, glass = split(canopy, band)
    # Roof intake (engine air): a low livery scoop with a dark mouth.
    scoop = loft([
        Section(0.000, 0.200, 0.560, 0.700, n_top=2.4, n_bot=3.0, taper=0.80),
        Section(0.300, 0.230, 0.560, 0.735, n_top=2.4, n_bot=3.0, taper=0.80),
        Section(0.750, 0.170, 0.480, 0.640, n_top=2.4, n_bot=3.0, taper=0.80),
    ])
    scoop, mouth = split(scoop, box(0.0, 0, 0.665, 0.06, 0.15, 0.05))
    return [
        PartSpec("canopy", shell, "Livery"),
        PartSpec("glazing", glass, "Glass"),
        PartSpec("roof_scoop", scoop, "Livery"),
        PartSpec("roof_scoop_mouth", mouth, "Carbon"),
    ]


def make_fin() -> list[PartSpec]:
    """Shark fin on the centreline, from the roof scoop back to the rear wing."""
    fin = xz_plate(
        [(0.70, 0.640), (0.90, 0.690), (1.60, 0.650), (2.12, 0.610), (2.16, 0.560),
         (2.10, 0.300), (1.70, 0.340), (1.10, 0.480)],
        -0.006, 0.012,
    )
    fin = try_fillet(fin, fin.edges().filter_by(Axis.Y), 0.03)
    return [PartSpec("shark_fin", fin, "Livery", surface_control=False)]


def make_mirrors() -> list[PartSpec]:
    """Mirrors on short carbon stalks on the doors, just behind the front fenders."""
    housing = loft([
        Section(-0.800, 0.130, 0.330, 0.390, y_center=0.880, n_top=2.6, n_bot=2.6, taper=0.85),
        Section(-0.700, 0.170, 0.320, 0.410, y_center=0.885, n_top=3.0, n_bot=3.0, taper=0.90),
        Section(-0.650, 0.170, 0.320, 0.410, y_center=0.885, n_top=3.0, n_bot=3.0, taper=0.90),
    ])
    housing, glass = split(housing, box(-0.645, 0.885, 0.365, 0.03, 0.15, 0.075))
    stalk = tube([(-0.700, 0.800, 0.140), (-0.715, 0.840, 0.250), (-0.720, 0.870, 0.335)], 0.014)
    out = []
    for i, s in enumerate(both_sides(housing)):
        out.append(PartSpec(f"mirror{i}", s, "Accent"))
    for i, s in enumerate(both_sides(glass)):
        out.append(PartSpec(f"mirror_glass{i}", s, "Metal"))
    for i, s in enumerate(both_sides(stalk)):
        out.append(PartSpec(f"mirror_stalk{i}", s, "Carbon", False))
    return out


def make_rear_wing() -> list[PartSpec]:
    out: list[PartSpec] = []
    main = wing_element(2.080, 0.600, 0.340, 7.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.07, thickness=0.11)
    flap = wing_element(2.390, 0.640, 0.110, 30.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.06, thickness=0.09)
    out.append(PartSpec("rw_main", main, "LiveryWhite", surface_control=False))
    out.append(PartSpec("rw_gurney", flap, "Accent", surface_control=False))
    endplate = xz_plate(
        [(2.000, 0.420), (2.400, 0.360), (2.520, 0.420), (2.520, 0.760), (2.140, 0.760),
         (2.020, 0.680)],
        RW_HALF_SPAN, 0.014,
    )
    endplate = try_fillet(endplate, endplate.edges().filter_by(Axis.Y), 0.04)
    for j, s in enumerate(both_sides(endplate)):
        out.append(PartSpec(f"rw_endplate{j}", s, "Accent"))
    # Swan-neck pylons: up from the engine cover, over the leading edge, onto the top surface.
    neck = xz_plate(
        [(1.780, 0.200), (1.920, 0.200), (2.040, 0.560), (2.160, 0.660), (2.300, 0.680),
         (2.300, 0.710), (2.130, 0.705), (1.990, 0.630), (1.880, 0.400)],
        0.300, 0.016,
    )
    neck = try_fillet(neck, neck.edges().filter_by(Axis.Y), 0.012)
    for j, s in enumerate(both_sides(neck)):
        out.append(PartSpec(f"rw_neck{j}", s, "Carbon", False))
    return out


def make_floor_splitter_diffuser() -> list[PartSpec]:
    out: list[PartSpec] = []
    half = [(-2.00, 0.0), (-2.00, 0.62), (-1.15, 0.62), (-1.10, 0.95), (1.00, 0.95),
            (1.05, 0.62), (1.95, 0.62), (1.95, 0.0)]
    outline = half + [(x, -y) for x, y in reversed(half[1:-1])]
    out.append(PartSpec("floor", xy_plate(outline, FLOOR_BOTTOM_Z, FLOOR_T), "Carbon", False))

    split_half = [(-2.56, 0.0), (-2.56, 0.78), (-2.44, 0.94), (-2.10, 0.97), (-2.10, 0.0)]
    split_outline = split_half + [(x, -y) for x, y in reversed(split_half[1:-1])]
    splitter = xy_plate(split_outline, FLOOR_BOTTOM_Z, 0.018)
    splitter = try_fillet(splitter, splitter.edges().filter_by(Axis.Z), 0.03)
    out.append(PartSpec("splitter", splitter, "Carbon", False))
    # Dive planes on the corners of the nose.
    for j, s in enumerate(both_sides(xy_plate([(-2.44, 0.70), (-2.30, 0.70), (-2.24, 0.95), (-2.40, 0.95)],
                                                -0.150, 0.012))):
        out.append(PartSpec(f"dive_plane{j}", s, "Carbon", False))

    dx0, dx1 = 1.95, TAIL_X + 0.02
    ramp = xz_plate([(dx0, FLOOR_BOTTOM_Z), (dx1, -0.150), (dx1, -0.130), (dx0, FLOOR_BOTTOM_Z + 0.018)],
                    -0.62, 1.24)
    out.append(PartSpec("diffuser", ramp, "Carbon", False))
    for y in (0.0, 0.22, 0.44):
        strake = xz_plate([(dx0 + 0.05, FLOOR_BOTTOM_Z + 0.012), (dx1, -0.148), (dx1, -0.230),
                           (dx0 + 0.25, -0.280)], y - 0.004, 0.008)
        for j, s in enumerate(both_sides(strake) if y else [strake]):
            out.append(PartSpec(f"strake{y}_{j}", s, "Carbon", False))
    rain_light = box(TAIL_X + 0.012, 0, -0.105, 0.02, 0.12, 0.05)
    out.append(PartSpec("rain_light", rain_light, "Light", False))
    return out


def make_driver() -> list[PartSpec]:
    """Helmet + visor under the canopy (body_motion.gd moves these two as the head)."""
    c = Vector(-0.05, 0.0, 0.420)
    shell = scale(Sphere(0.125), by=(1.12, 1.0, 1.04)).moved(Location(c))
    visor_band = box(c.X - 0.10, 0, c.Z + 0.005, 0.20, 0.30, 0.050)
    visor_shell = scale(Sphere(0.1275), by=(1.12, 1.0, 1.04)).moved(Location(c)) & visor_band
    visor_shell = visor_shell - box(c.X + 0.10, 0, c.Z, 0.30, 0.30, 0.30)
    return [PartSpec("helmet", shell, "Helmet"), PartSpec("visor", visor_shell, "Visor")]


def build_parts() -> list[PartSpec]:
    builders = [
        make_bodywork,
        make_canopy,
        make_fin,
        make_mirrors,
        make_rear_wing,
        make_floor_splitter_diffuser,
        make_driver,
    ]
    parts: list[PartSpec] = []
    for b in builders:
        print(f"building {b.__name__} ...")
        parts.extend(b())
    return parts


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=OUT_PATH, help=f"GLB to write (default {OUT_PATH.relative_to(REPO)})")
    args = ap.parse_args()
    out_path: Path = args.out.resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    parts = build_parts()
    groups = {name: MeshGroup(mat) for name, mat in MATERIALS.items()}
    total = 0
    for p in parts:
        n = groups[p.material].add_shape(p.shape, TESS_TOL, TESS_ANG, p.surface_control)
        total += n
        print(f"  {p.name:18s} {p.material:12s} {n:7d} tris")
    write_glb(out_path, list(groups.values()), root_name="EnduranceBody")
    for g in groups.values():
        print(f"{g.material.name:12s} {g.triangle_count:7d} tris")
    shown = out_path.relative_to(REPO) if out_path.is_relative_to(REPO) else out_path
    print(f"total {total} triangles -> {shown}")


if __name__ == "__main__":
    main()
