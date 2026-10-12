#!/usr/bin/env python3
"""Parametric endurance prototype body (a Le Mans Hypercar inspired by the 2023-24 Ferrari 499P:
broad low nose between tall peaked fenders, visor canopy, shark fin, high wing between big end
plates), modelled with build123d. Materials and decals: endurance_decals.py + the body scene.

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
    # Ferrari-red body, yellow accents, white roundels (scenes/car/endurance_body_visual.tscn
    # overrides these with clear-coat paint, triplanar carbon and emissive lights).
    "Livery": Material("Livery", (0.55, 0.012, 0.012, 1.0), 0.30, 0.28),
    "LiveryWhite": Material("LiveryWhite", (0.88, 0.88, 0.86, 1.0), 0.05, 0.30),
    "Accent": Material("Accent", (0.96, 0.74, 0.04, 1.0), 0.10, 0.30),
    "Carbon": Material("Carbon", (0.030, 0.031, 0.034, 1.0), 0.20, 0.30),
    "Metal": Material("Metal", (0.80, 0.80, 0.82, 1.0), 1.0, 0.12),
    "Helmet": Material("Helmet", (0.95, 0.78, 0.05, 1.0), 0.05, 0.22),
    "Visor": Material("Visor", (0.02, 0.02, 0.03, 1.0), 0.6, 0.08),
    "Light": Material("Light", (0.6, 0.0, 0.0, 1.0), 0.0, 0.4, emissive=(1.0, 0.05, 0.03)),
    "Glass": Material("Glass", (0.05, 0.06, 0.07, 1.0), 0.0, 0.05),
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
    # x,      width, z_bot, z_top   (a broad, low nose whose centre dips between the fenders)
    Section(-2.450, 1.500, -0.250, -0.100, n_top=2.8, n_bot=3.0, taper=0.92),
    Section(-2.150, 1.600, -0.285, 0.000, n_top=3.2, n_bot=4.0, taper=0.90),
    Section(-1.550, 1.240, -0.290, 0.080, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(-0.900, 1.300, -0.290, 0.140, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(0.000, 1.340, -0.290, 0.170, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(1.000, 1.340, -0.290, 0.170, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(1.800, 1.300, -0.280, 0.150, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(2.450, 1.300, -0.180, 0.130, n_top=3.0, n_bot=4.0, taper=0.90),
]

# Fenders: tall and peaked over the front wheels with a blunt, near-vertical front face (the
# headlight modules sit in it), falling into the doors; their inner half is buried in the hull.
FRONT_FENDER = [
    Section(-2.440, 0.420, -0.240, 0.010, y_center=0.745, n_top=2.4, n_bot=3.0, taper=0.78),
    Section(-2.300, 0.470, -0.270, 0.150, y_center=0.755, n_top=2.3, n_bot=3.5, taper=0.70),
    Section(-2.000, 0.500, -0.280, 0.320, y_center=0.760, n_top=2.2, n_bot=3.5, taper=0.62),
    Section(-1.550, 0.500, -0.280, 0.450, y_center=0.760, n_top=2.2, n_bot=3.5, taper=0.60),
    Section(-1.200, 0.500, -0.280, 0.420, y_center=0.760, n_top=2.3, n_bot=3.5, taper=0.64),
    Section(-0.900, 0.480, -0.285, 0.240, y_center=0.745, n_top=2.6, n_bot=3.5, taper=0.78),
    Section(-0.650, 0.440, -0.285, 0.140, y_center=0.720, n_top=3.0, n_bot=3.5, taper=0.85),
]
DOOR = [
    Section(-0.950, 0.480, -0.285, 0.170, y_center=0.720, n_top=3.2, n_bot=3.5, taper=0.86),
    Section(-0.300, 0.500, -0.290, 0.120, y_center=0.705, n_top=3.2, n_bot=3.5, taper=0.86),
    Section(0.400, 0.500, -0.290, 0.130, y_center=0.705, n_top=3.2, n_bot=3.5, taper=0.86),
    Section(0.950, 0.480, -0.285, 0.190, y_center=0.720, n_top=3.2, n_bot=3.5, taper=0.86),
]
# Long rear fenders, high and peaked over the rear wheels, carried to the tail.
REAR_FENDER = [
    Section(0.650, 0.440, -0.285, 0.160, y_center=0.720, n_top=3.0, n_bot=3.5, taper=0.85),
    Section(1.050, 0.490, -0.285, 0.360, y_center=0.745, n_top=2.6, n_bot=3.5, taper=0.72),
    Section(1.550, 0.500, -0.285, 0.470, y_center=0.755, n_top=2.4, n_bot=3.5, taper=0.66),
    Section(2.050, 0.500, -0.270, 0.440, y_center=0.755, n_top=2.4, n_bot=3.5, taper=0.68),
    Section(2.470, 0.480, -0.180, 0.340, y_center=0.750, n_top=2.6, n_bot=3.2, taper=0.74),
]
ENGINE_COVER = [
    Section(0.450, 1.000, 0.000, 0.600, n_top=2.4, n_bot=3.0, taper=0.58),
    Section(1.050, 0.860, 0.000, 0.460, n_top=2.4, n_bot=3.0, taper=0.60),
    Section(1.750, 0.760, 0.000, 0.330, n_top=2.4, n_bot=3.0, taper=0.66),
    Section(2.450, 0.700, -0.050, 0.220, n_top=2.4, n_bot=3.0, taper=0.72),
]
# Canopy: a teardrop bubble whose glazing wraps round the front like a visor.
CANOPY_SECTIONS = [
    Section(-1.250, 0.520, -0.050, 0.060, n_top=2.4, n_bot=3.0, taper=0.62),
    Section(-0.850, 0.940, 0.000, 0.380, n_top=2.4, n_bot=3.0, taper=0.58),
    Section(-0.400, 1.120, 0.000, 0.630, n_top=2.4, n_bot=3.0, taper=0.54),
    Section(0.050, 1.120, 0.000, ROOF_Z, n_top=2.4, n_bot=3.0, taper=0.56),
    Section(0.450, 1.000, 0.000, 0.610, n_top=2.4, n_bot=3.0, taper=0.58),
]
GLASS_X0, GLASS_X1 = -1.15, 0.40   # glazing: windscreen and side windows, the roof above
GLASS_Z0, GLASS_Z1 = 0.22, 0.585


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
    # Side scoops behind the front wheels: a deep pocket in the front of each door.
    body = body - mirrored_box(-0.86, 1.10, 0.02, 0.44, 0.36, 0.26)
    out: list[PartSpec] = []

    # Front: black lower lip across the whole nose (with the radiator mouth) above the splitter.
    body, lip = split(body, box(-2.30, 0, -0.235, 0.70, 2.4, 0.11))
    body, mouth = split(body, box(-2.47, 0, -0.150, 0.32, 0.50, 0.06))
    out += [PartSpec("nose_lip", lip, "Carbon"), PartSpec("nose_mouth", mouth, "Carbon")]

    # Headlights: a low square carbon module in the face of each fender with a 3 x 2 matrix of
    # LED cells, and a slim light bar above it along the top of the fender face.
    body, housing = split(body, mirrored_box(-2.42, 0.765, -0.100, 0.36, 0.31, 0.135))
    cells = None
    for i in range(3):
        for j in range(2):
            c = mirrored_box(-2.42, 0.675 + 0.09 * i, -0.130 + 0.058 * j, 0.40, 0.064, 0.036)
            cells = c if cells is None else cells + c
    housing, led = split(housing, cells)
    body, upper = split(body, mirrored_box(-2.40, 0.765, 0.035, 0.40, 0.30, 0.022))
    out += [PartSpec("headlight_housing", housing, "Carbon"),
            PartSpec("headlights", led + upper, "Headlight")]

    # Louvres on top of the front fenders, over the wheel: a carbon panel with open slots.
    body, panel = split(body, mirrored_box(-1.36, 0.775, 0.62, 0.50, 0.30, 0.60))
    for k in range(7):
        panel = panel - mirrored_box(-1.56 + 0.065 * k, 0.775, 0.64, 0.028, 0.24, 0.60)
    out.append(PartSpec("louvres", panel, "Carbon"))
    floor = None
    for k in range(7):
        f = mirrored_box(-1.56 + 0.065 * k, 0.775, 0.342, 0.028, 0.24, 0.006)
        floor = f if floor is None else floor + f
    out.append(PartSpec("louvre_depth", floor, "Carbon", False))

    # The scoop pocket: carbon inside, with three vertical vanes.
    body, scoop = split(body, mirrored_box(-0.86, 1.06, 0.02, 0.48, 0.44, 0.30))
    vanes = None
    for k in range(3):
        v = mirrored_box(-1.00 + 0.11 * k, 0.94, 0.02, 0.018, 0.08, 0.24)
        vanes = v if vanes is None else vanes + v
    out += [PartSpec("side_scoops", scoop, "Carbon"), PartSpec("scoop_vanes", vanes, "Carbon", False)]

    # Tail: a full-width red light bar across the top of the tail, carbon housing round it.
    body, thouse = split(body, box(2.46, 0, 0.140, 0.12, 2.4, 0.07))
    thouse, tled = split(thouse, box(2.46, 0, 0.140, 0.14, 2.4, 0.026))
    out += [PartSpec("tail_housing", thouse, "Carbon"), PartSpec("tail_light", tled, "Light")]

    # Black rear: the whole tail below the light bar (gearbox / diffuser exit, crash structure).
    body, rear_panel = split(body, box(2.47, 0, -0.06, 0.12, 2.4, 0.33))
    out.append(PartSpec("rear_panel", rear_panel, "Carbon"))

    # Black lower body: deep carbon sills from the nose to the tail.
    body, sills = split(body, mirrored_box(0.15, 0.85, -0.225, 4.3, 0.50, 0.13))
    out.append(PartSpec("sills", sills, "Carbon"))

    # Yellow band along each flank above the sills, and a yellow stripe up the nose centre.
    body, st = split(body, mirrored_box(0.55, 1.06, -0.135, 3.0, 0.40, 0.050))
    body, nose_st = split(body, mirrored_box(-2.10, 0.075, 0.0, 0.70, 0.035, 0.40))
    out += [PartSpec("flank_stripe", st, "Accent"), PartSpec("nose_stripes", nose_st, "Accent")]

    # Wheel-arch liners: the dark inner surface of each arch.
    liners = None
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        big = Solid.make_cylinder(r + ARCH_CLEARANCE + 0.035, HALF_WIDTH + 0.2 - 0.46,
                                  Plane(origin=(axle_x, 0.46, 0.0), z_dir=(0, 1, 0)))
        ring_c = big - arch_cutter(axle_x, r, 0.50)
        ring_c = ring_c + mirror(ring_c, about=Plane.XZ)
        liners = ring_c if liners is None else liners + ring_c
    body, liner = split(body, liners)
    out.append(PartSpec("arch_liners", liner, "Carbon"))

    # Panel lines and shut lines: thin recessed grooves round the doors and covers.
    g = 0.006
    grooves = mirrored_box(-0.62, 0.9, -0.04, g, 0.7, 0.34)           # door front
    grooves = grooves + mirrored_box(0.90, 0.9, -0.04, g, 0.7, 0.34)  # door rear
    grooves = grooves + mirrored_box(0.14, 0.9, 0.126, 1.52, 0.7, g)  # door top
    grooves = grooves + mirrored_box(1.55, 0.30, 0.3, 1.9, g, 0.8)    # engine cover split
    grooves = grooves + box(0.50, 0, 0.3, g, 0.7, 0.8)
    grooves = grooves + box(-1.10, 0, 0.1, g, 0.7, 0.5)
    body, groove_part = split(body, grooves)
    out.append(PartSpec("panel_lines", groove_part, "Carbon"))

    out.insert(0, PartSpec("body", body, "Livery"))
    return out


def _canopy_pt(x: float, sfrac: float, sgn: int):
    """Point on the canopy skin at station x, at height fraction ``sfrac`` of the upper half."""
    import math
    secs = CANOPY_SECTIONS
    for a, b in zip(secs, secs[1:]):
        if a.x <= x <= b.x:
            t = (x - a.x) / (b.x - a.x)
            break
    else:
        a = b = secs[0] if x < secs[0].x else secs[-1]
        t = 0.0
    lerp = lambda u, v: u + (v - u) * t  # noqa: E731
    half, taper = 0.5 * lerp(a.width, b.width), lerp(a.taper, b.taper)
    zt, zb = lerp(a.z_top, b.z_top), lerp(a.z_bot, b.z_bot)
    zs = 0.5 * (zt + zb)
    n = lerp(a.n_top, b.n_top)
    ang = math.asin(sfrac)
    c, sn = math.cos(ang), math.sin(ang)
    y = half * c ** (2.0 / n) * (1.0 - (1.0 - taper) * sn * sn)
    z = zs + (zt - zs) * sn ** (2.0 / n)
    return (x, sgn * y, z)


def make_canopy() -> list[PartSpec]:
    canopy = loft(CANOPY_SECTIONS)
    band = box(0.5 * (GLASS_X0 + GLASS_X1), 0, 0.5 * (GLASS_Z0 + GLASS_Z1),
               GLASS_X1 - GLASS_X0, 2.0, GLASS_Z1 - GLASS_Z0)
    shell, glass = split(canopy, band)
    out_extra: list[PartSpec] = []
    # Sunstrip: a yellow band across the top of the windscreen, wrapping round like a visor.
    shell, sun = split(shell, box(-0.47, 0, 0.75, 0.34, 2.0, 0.33))
    out_extra += [PartSpec("sunstrip", sun, "Accent")]
    # Windscreen frame, belt line, rear window frame and A-pillars: Carbon strips on the glazing.
    frame = box(GLASS_X0 + 0.02, 0, 0.45, 0.04, 2.0, 0.7)
    frame = frame + box(GLASS_X1 - 0.02, 0, 0.45, 0.04, 2.0, 0.7)
    frame = frame + box(-0.3, 0, GLASS_Z0 + 0.012, 1.5, 2.0, 0.026)
    glass, frame_part = split(glass, frame)
    pil = None
    for sgn in (1, -1):
        pts = []
        for x in (-1.12, -0.95, -0.75, -0.55, -0.35, -0.10):
            pts.append(_canopy_pt(x, 0.88, sgn))
        t = tube(pts, 0.032)
        pil = t if pil is None else pil + t
    glass, pillars = split(glass, pil)
    frame_part = frame_part + pillars
    # Roof intake (engine air): a black scoop with a split mouth and a camera pod on top.
    scoop = loft([
        Section(-0.050, 0.240, 0.560, 0.715, n_top=2.8, n_bot=3.0, taper=0.82),
        Section(0.300, 0.260, 0.560, 0.745, n_top=2.8, n_bot=3.0, taper=0.82),
        Section(0.750, 0.170, 0.480, 0.640, n_top=2.4, n_bot=3.0, taper=0.80),
    ])
    scoop = scoop - box(0.07, 0, 0.655, 0.26, 0.17, 0.06)
    divider = box(-0.03, 0, 0.66, 0.06, 0.012, 0.07)
    cam = box(0.06, 0, 0.765, 0.10, 0.07, 0.07)
    cam = try_fillet(cam, cam.edges(), 0.012)
    lens = box(0.008, 0, 0.770, 0.006, 0.035, 0.030)
    return [
        PartSpec("canopy", shell, "Livery"),
        PartSpec("glazing", glass, "Glass"),
        PartSpec("windscreen_frame", frame_part, "Carbon"),
        *out_extra,
        PartSpec("roof_scoop", scoop + divider, "Carbon"),
        PartSpec("camera_pod", cam, "Carbon"),
        PartSpec("camera_lens", lens, "Glass", False),
    ]


def make_fin() -> list[PartSpec]:
    """Tall dark shark fin on the centreline, from the roof scoop back to the rear wing."""
    fin = xz_plate(
        [(0.70, 0.650), (0.95, 0.730), (1.60, 0.780), (2.06, 0.800), (2.14, 0.760),
         (2.12, 0.300), (1.70, 0.330), (1.10, 0.480)],
        -0.006, 0.012,
    )
    fin = try_fillet(fin, fin.edges().filter_by(Axis.Y), 0.03)
    fin, fin_stripe = split(fin, box(1.5, 0, 0.705, 1.6, 0.1, 0.035))
    antenna = Solid.make_cylinder(0.006, 0.14, Plane(origin=(-0.25, 0.0, 0.69), z_dir=(0, 0, 1)))
    return [PartSpec("shark_fin", fin, "Carbon", surface_control=False),
            PartSpec("fin_stripe", fin_stripe, "Accent", surface_control=False),
            PartSpec("antenna", antenna, "Carbon", False)]


def make_mirrors() -> list[PartSpec]:
    """Mirrors on carbon stalks rising from the inner edge of the front fenders."""
    housing = loft([
        Section(-1.160, 0.150, 0.470, 0.530, y_center=0.585, n_top=2.6, n_bot=2.6, taper=0.85),
        Section(-1.060, 0.190, 0.460, 0.550, y_center=0.590, n_top=3.0, n_bot=3.0, taper=0.90),
        Section(-1.010, 0.190, 0.460, 0.550, y_center=0.590, n_top=3.0, n_bot=3.0, taper=0.90),
    ])
    housing, glass = split(housing, box(-1.005, 0.590, 0.505, 0.03, 0.17, 0.075))
    stalk = tube([(-1.090, 0.640, 0.270), (-1.085, 0.620, 0.380), (-1.080, 0.600, 0.470)], 0.016)
    out = []
    for i, s in enumerate(both_sides(housing)):
        out.append(PartSpec(f"mirror{i}", s, "Livery"))
    for i, s in enumerate(both_sides(glass)):
        out.append(PartSpec(f"mirror_glass{i}", s, "Metal"))
    for i, s in enumerate(both_sides(stalk)):
        out.append(PartSpec(f"mirror_stalk{i}", s, "Carbon", False))
    return out


def make_rear_wing() -> list[PartSpec]:
    """High rear wing between very large carbon end plates on the rear fenders."""
    out: list[PartSpec] = []
    main = wing_element(2.060, 0.700, 0.340, 7.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.07, thickness=0.11)
    flap = wing_element(2.370, 0.740, 0.120, 30.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.06, thickness=0.09)
    out.append(PartSpec("rw_main", main, "Carbon", surface_control=False))
    out.append(PartSpec("rw_flap", flap, "Accent", surface_control=False))
    endplate = xz_plate(
        [(1.780, 0.300), (2.440, 0.240), (2.540, 0.330), (2.540, 0.880), (2.200, 0.880),
         (1.980, 0.720)],
        RW_HALF_SPAN, 0.016,
    )
    endplate = try_fillet(endplate, endplate.edges().filter_by(Axis.Y), 0.05)
    for j, s in enumerate(both_sides(endplate)):
        out.append(PartSpec(f"rw_endplate{j}", s, "Carbon", surface_control=False))
    gurney = box(2.482, 0, 0.708, 0.006, 2 * RW_HALF_SPAN, 0.040)
    out.append(PartSpec("rw_gurney_flap", gurney, "Carbon", False))
    # A thin white edge along the top of each end plate.
    top = xz_plate([(2.20, 0.865), (2.54, 0.865), (2.54, 0.880), (2.20, 0.880)], RW_HALF_SPAN + 0.016, 0.004)
    for j, s in enumerate(both_sides(top)):
        out.append(PartSpec(f"rw_edge{j}", s, "LiveryWhite", False))
    # Swan-neck pylons: up from the engine cover, over the leading edge, onto the top surface.
    neck = xz_plate(
        [(1.780, 0.200), (1.920, 0.200), (2.040, 0.660), (2.160, 0.760), (2.300, 0.780),
         (2.300, 0.810), (2.130, 0.805), (1.990, 0.730), (1.880, 0.450)],
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

    split_half = [(-2.62, 0.0), (-2.62, 0.80), (-2.50, 0.96), (-2.10, 0.99), (-2.10, 0.0)]
    split_outline = split_half + [(x, -y) for x, y in reversed(split_half[1:-1])]
    splitter = xy_plate(split_outline, FLOOR_BOTTOM_Z, 0.018)
    splitter = try_fillet(splitter, splitter.edges().filter_by(Axis.Z), 0.03)
    out.append(PartSpec("splitter", splitter, "Carbon", False))
    # Vertical fences under the nose, between the splitter and the black lip.
    for y in (0.0, 0.16, 0.32):
        fence = xz_plate([(-2.58, FLOOR_BOTTOM_Z + 0.01), (-2.20, FLOOR_BOTTOM_Z + 0.01), (-2.20, -0.20),
                          (-2.47, -0.20)], y - 0.005, 0.010)
        for j, f in enumerate(both_sides(fence) if y else [fence]):
            out.append(PartSpec(f"nose_fence{y}_{j}", f, "Carbon", False))
    # Splitter end plates (vertical, with a rounded leading corner).
    ep = xz_plate([(-2.62, FLOOR_BOTTOM_Z), (-2.10, FLOOR_BOTTOM_Z), (-2.10, -0.17), (-2.48, -0.15),
                   (-2.62, -0.24)], 0.975, 0.012)
    ep = try_fillet(ep, ep.edges().filter_by(Axis.Y), 0.02)
    for j, s in enumerate(both_sides(ep)):
        out.append(PartSpec(f"splitter_endplate{j}", s, "Carbon", False))
    # Second dive plane, higher and further back.
    for j, s in enumerate(both_sides(xy_plate([(-2.20, 0.82), (-2.04, 0.82), (-1.98, 1.00), (-2.14, 1.00)],
                                                -0.100, 0.012))):
        out.append(PartSpec(f"dive_plane2_{j}", s, "Carbon", False))
    # Dive planes on the corners of the nose.
    for j, s in enumerate(both_sides(xy_plate([(-2.44, 0.70), (-2.30, 0.70), (-2.24, 0.95), (-2.40, 0.95)],
                                                -0.150, 0.012))):
        out.append(PartSpec(f"dive_plane{j}", s, "Carbon", False))

    dx0, dx1 = 1.95, TAIL_X + 0.02
    ramp = xz_plate([(dx0, FLOOR_BOTTOM_Z), (dx1, -0.150), (dx1, -0.130), (dx0, FLOOR_BOTTOM_Z + 0.018)],
                    -0.62, 1.24)
    out.append(PartSpec("diffuser", ramp, "Carbon", False))
    for y in (0.0, 0.17, 0.34, 0.51):
        strake = xz_plate([(dx0 + 0.05, FLOOR_BOTTOM_Z + 0.012), (dx1, -0.148), (dx1, -0.230),
                           (dx0 + 0.25, -0.280)], y - 0.006, 0.012)
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
