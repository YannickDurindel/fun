#!/usr/bin/env python3
"""Parametric F1 / Trackmania-Stadium-style car body, modelled with build123d.

Regenerate the Godot asset with one command (from the repo root):

    .venv/bin/python cad/body/f1_body.py            # -> assets/car/body.glb

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.

Setup (once): ``python3 -m venv .venv && .venv/bin/pip install -r cad/requirements.txt``

Frame: the model is built in a CAD frame x = backward, y = right, z = up, which
maps 1:1 (cyclic permutation) onto the Godot car-local frame used by
``scripts/car/car.gd``: forward = -Z, up = +Y, right = +X. The origin is at
axle height, front axle at x = -1.80, rear axle at x = +1.80, ground at
z = -0.36. No wheels or suspension here (those are a separate unit).

Every part is a build123d solid (lofts through superellipse sections, airfoil
extrusions, swept tubes, filleted plates, mirrored for symmetry). Parts are
grouped by material and written as one named mesh per material:
Livery, LiveryWhite, Accent, Carbon, Metal, Helmet, Visor, Light.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

from build123d import (
    Axis,
    Box,
    Circle,
    Edge,
    Face,
    Location,
    Part,
    Plane,
    Solid,
    Sphere,
    Vector,
    Wire,
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
OUT_PATH = REPO / "assets" / "car" / "body.glb"

# --------------------------------------------------------------------------
# Global dimensions (metres, CAD frame)
# --------------------------------------------------------------------------
GROUND_Z = -0.36
FLOOR_BOTTOM_Z = -0.30  # 6 cm ride height
FLOOR_T = 0.02
FRONT_AXLE_X = -1.80
REAR_AXLE_X = 1.80
NOSE_X = -2.88  # front wing leading edge  -> overall length ~5.6 m
TAIL_X = 2.70  # rear wing trailing edge
FW_HALF_SPAN = 0.985  # front wing 1.97 m wide
RW_HALF_SPAN = 0.48

TESS_TOL = 0.0015  # linear deflection (m)
TESS_ANG = 0.18  # angular deflection (rad)

# --------------------------------------------------------------------------
# Materials (Trackmania-ish deep blue / white / red livery)
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


def wing_element(le_x, le_z, chord, aoa, y_from, y_to, camber=0.06, thickness=0.10) -> Part:
    face = airfoil_face(le_x, le_z, y_from, chord, aoa, camber=camber, thickness=thickness)
    return extrude(face, amount=y_to - y_from, dir=(0, 1, 0))


def both_sides(shape) -> list:
    return [shape, mirror(shape, about=Plane.XZ)]


def tube(points: list[tuple[float, float, float]], radius: float) -> Part:
    path = Wire([Edge.make_spline([Vector(*p) for p in points])])
    plane = Plane(origin=path @ 0, z_dir=path % 0)
    return sweep(plane * Circle(radius), path=path)


# --------------------------------------------------------------------------
# Parts
# --------------------------------------------------------------------------
CHASSIS_SECTIONS = [
    # x,      width, z_bot, z_top
    Section(-2.860, 0.150, -0.262, -0.200, n_top=2.2, n_bot=2.6, taper=0.8),
    Section(-2.700, 0.230, -0.266, -0.150, n_top=2.4, n_bot=3.0),
    Section(-2.300, 0.290, -0.250, -0.065),
    Section(-1.800, 0.350, -0.235, 0.040),
    Section(-1.300, 0.420, -0.230, 0.140),
    Section(-0.800, 0.600, -0.245, 0.215),
    Section(-0.300, 0.760, -0.260, 0.255, taper=0.68),
    Section(0.200, 0.800, -0.265, 0.290, taper=0.62),
    Section(0.800, 0.560, -0.265, 0.250, taper=0.55),
    Section(1.400, 0.400, -0.265, 0.160, taper=0.6),
    Section(1.900, 0.250, -0.230, 0.060, taper=0.7),
    Section(2.300, 0.150, -0.170, -0.030, n_top=2.4, n_bot=3.0),
    Section(2.420, 0.090, -0.140, -0.065, n_top=2.2, n_bot=2.4, taper=0.85),
]

COCKPIT_X0, COCKPIT_X1 = -0.66, 0.14
COCKPIT_HALF_W = 0.245


def make_chassis() -> list[PartSpec]:
    tub = loft(CHASSIS_SECTIONS)

    # Cockpit opening: rounded slot cut from above.
    opening = Box(COCKPIT_X1 - COCKPIT_X0, 2 * COCKPIT_HALF_W, 0.6).locate(
        Location(((COCKPIT_X0 + COCKPIT_X1) / 2, 0, 0.05 + 0.3))
    )
    opening = try_fillet(opening, opening.edges().filter_by(Axis.Z), COCKPIT_HALF_W - 0.01)
    tub = tub - opening

    # Livery split: red nose tip.
    nose_cut = Box(1.0, 1.0, 1.0).locate(Location((-2.48 - 0.5, 0, 0)))
    nose_tip = tub & nose_cut
    body = tub - nose_cut

    # Seat / cockpit floor in carbon so the opening reads dark.
    seat = loft(
        [
            Section(COCKPIT_X0 + 0.02, 0.40, -0.02, 0.06, n_top=3, n_bot=3, taper=1.0),
            Section(COCKPIT_X1 - 0.02, 0.44, -0.02, 0.10, n_top=3, n_bot=3, taper=1.0),
        ]
    )
    # Headrest pads either side of the helmet + behind it.
    headrest = loft(
        [
            Section(0.02, 0.56, 0.18, 0.30, n_top=3, n_bot=3, taper=0.9),
            Section(0.16, 0.60, 0.18, 0.31, n_top=3, n_bot=3, taper=0.9),
        ]
    ) - Box(0.30, 0.30, 0.30).locate(Location((-0.02, 0, 0.30)))
    return [
        PartSpec("chassis", body, "Livery"),
        PartSpec("nose_tip", nose_tip, "Accent"),
        PartSpec("seat", seat, "Carbon", False),
        PartSpec("headrest", headrest, "Carbon"),
    ]


def make_sidepods() -> list[PartSpec]:
    secs = [
        Section(-0.640, 0.360, -0.040, 0.200, y_center=0.560, n_top=3.2, n_bot=3.2, taper=0.88),
        Section(-0.420, 0.420, -0.095, 0.215, y_center=0.575, n_top=3.0, n_bot=3.0, taper=0.85),
        Section(0.100, 0.420, -0.180, 0.205, y_center=0.555, n_top=2.8, n_bot=3.2, taper=0.80),
        Section(0.600, 0.340, -0.240, 0.165, y_center=0.475, n_top=2.6, n_bot=3.4, taper=0.75),
        Section(1.100, 0.230, -0.265, 0.080, y_center=0.340, n_top=2.4, n_bot=3.4, taper=0.7),
        Section(1.480, 0.110, -0.268, -0.010, y_center=0.230, n_top=2.2, n_bot=3.0, taper=0.7),
    ]
    pod = loft(secs)
    # Letterbox inlet
    inlet = loft(
        [
            Section(-0.700, 0.300, 0.005, 0.160, y_center=0.565, n_top=4, n_bot=4, taper=0.95),
            Section(-0.480, 0.280, 0.015, 0.150, y_center=0.565, n_top=4, n_bot=4, taper=0.95),
        ]
    )
    pod = pod - inlet
    plug = loft(
        [
            Section(-0.500, 0.290, 0.005, 0.160, y_center=0.565, n_top=4, n_bot=4, taper=0.95),
            Section(-0.470, 0.290, 0.005, 0.160, y_center=0.565, n_top=4, n_bot=4, taper=0.95),
        ]
    )
    # White inlet lip: the front of the pod, split off by a slab.
    stripe_cut = Box(0.5, 0.6, 0.6).locate(Location((-0.80, 0.56, 0.0)))
    stripe = pod & stripe_cut
    pod_rest = pod - stripe_cut
    out = []
    for i, s in enumerate(both_sides(pod_rest)):
        out.append(PartSpec(f"sidepod{i}", s, "Livery"))
    for i, s in enumerate(both_sides(stripe)):
        out.append(PartSpec(f"sidepod_front{i}", s, "LiveryWhite"))
    for i, s in enumerate(both_sides(plug)):
        out.append(PartSpec(f"inlet{i}", s, "Carbon"))
    return out


def make_airbox_and_fin() -> list[PartSpec]:
    box = loft(
        [
            Section(0.080, 0.260, 0.200, 0.575, n_top=2.2, n_bot=3.0, taper=0.45, z_split=0.33),
            Section(0.420, 0.300, 0.200, 0.560, n_top=2.2, n_bot=3.0, taper=0.40, z_split=0.31),
            Section(1.000, 0.220, 0.150, 0.390, n_top=2.2, n_bot=3.0, taper=0.45),
            Section(1.600, 0.100, 0.050, 0.170, n_top=2.2, n_bot=3.0, taper=0.6),
        ]
    )
    intake_secs = [
        Section(0.040, 0.170, 0.400, 0.540, n_top=2.0, n_bot=2.2, taper=0.75),
        Section(0.260, 0.150, 0.410, 0.525, n_top=2.0, n_bot=2.2, taper=0.75),
    ]
    box = box - loft(intake_secs)
    plug = loft(
        [
            Section(0.240, 0.160, 0.400, 0.535, n_top=2.0, n_bot=2.2, taper=0.75),
            Section(0.270, 0.160, 0.400, 0.535, n_top=2.0, n_bot=2.2, taper=0.75),
        ]
    )

    fin = xz_plate(
        [
            (0.50, 0.30),
            (0.47, 0.540),
            (0.75, 0.530),
            (1.30, 0.430),
            (1.85, 0.300),
            (2.02, 0.200),
            (2.02, 0.000),
            (1.40, 0.120),
        ],
        -0.005,
        0.010,
    )
    fin = try_fillet(fin, fin.edges().filter_by(Axis.Y), 0.02)

    # T-camera on the airbox
    tcam = Box(0.09, 0.05, 0.025).locate(Location((0.33, 0, 0.575)))
    tcam = try_fillet(tcam, tcam.edges(), 0.008)
    return [
        PartSpec("airbox", box, "Livery"),
        PartSpec("airbox_plug", plug, "Carbon"),
        PartSpec("shark_fin", fin, "Livery", surface_control=False),
        PartSpec("tcam", tcam, "Accent", False),
    ]


def make_halo() -> list[PartSpec]:
    hoop_pts = [
        (0.16, -0.330, 0.150),
        (0.06, -0.335, 0.330),
        (-0.10, -0.320, 0.410),
        (-0.36, -0.250, 0.440),
        (-0.52, -0.130, 0.445),
        (-0.575, 0.000, 0.445),
        (-0.52, 0.130, 0.445),
        (-0.36, 0.250, 0.440),
        (-0.10, 0.320, 0.410),
        (0.06, 0.335, 0.330),
        (0.16, 0.330, 0.150),
    ]
    hoop = tube(hoop_pts, 0.024)
    pillar = tube([(-0.575, 0.0, 0.47), (-0.62, 0.0, 0.40), (-0.70, 0.0, 0.29), (-0.78, 0.0, 0.17)], 0.026)
    return [PartSpec("halo", hoop, "Carbon", False), PartSpec("halo_pillar", pillar, "Carbon", False)]


def make_mirrors() -> list[PartSpec]:
    housing = Box(0.06, 0.15, 0.05).locate(Location((-0.48, 0.52, 0.335)))
    housing = try_fillet(housing, housing.edges(), 0.018)
    glass = Box(0.004, 0.13, 0.035).locate(Location((-0.48 + 0.031, 0.52, 0.335)))
    stalk = Solid.make_cylinder(
        0.010, 0.20, Plane(origin=(-0.46, 0.36, 0.17), z_dir=Vector(-0.1, 0.8, 0.85).normalized())
    )
    out = []
    for i, s in enumerate(both_sides(housing)):
        out.append(PartSpec(f"mirror{i}", s, "Livery", False))
    for i, s in enumerate(both_sides(glass)):
        out.append(PartSpec(f"mirror_glass{i}", s, "Metal"))
    for i, s in enumerate(both_sides(stalk)):
        out.append(PartSpec(f"mirror_stalk{i}", s, "Carbon"))
    return out


def make_front_wing() -> list[PartSpec]:
    out: list[PartSpec] = []
    # Mainplane spans the full width (the nose sits on it).
    main = wing_element(NOSE_X, -0.285, 0.30, 5.0, -FW_HALF_SPAN + 0.012, FW_HALF_SPAN - 0.012,
                        camber=0.05, thickness=0.09)
    out.append(PartSpec("fw_main", main, "Carbon", surface_control=False))
    flaps = [
        # le_x,  le_z,   chord, aoa, inner y
        (-2.640, -0.255, 0.170, 16.0, 0.16, "LiveryWhite"),
        (-2.520, -0.205, 0.140, 28.0, 0.22, "LiveryWhite"),
        (-2.430, -0.145, 0.115, 40.0, 0.30, "Accent"),
    ]
    for i, (lx, lz, c, a, yin, mat) in enumerate(flaps):
        flap = wing_element(lx, lz, c, a, yin, FW_HALF_SPAN - 0.012, camber=0.07, thickness=0.09)
        for j, s in enumerate(both_sides(flap)):
            out.append(PartSpec(f"fw_flap{i}_{j}", s, mat, surface_control=False))
    endplate = xz_plate(
        [
            (NOSE_X - 0.03, -0.315),
            (-2.33, -0.315),
            (-2.30, -0.20),
            (-2.33, -0.065),
            (-2.52, -0.055),
            (-2.78, -0.13),
            (NOSE_X - 0.04, -0.23),
        ],
        FW_HALF_SPAN - 0.012,
        0.012,
    )
    endplate = try_fillet(endplate, endplate.edges().filter_by(Axis.Y), 0.025)
    # Outwash tip "arch" turning vane
    vane = xz_plate([(-2.62, -0.315), (-2.36, -0.315), (-2.38, -0.25), (-2.60, -0.27)],
                    FW_HALF_SPAN - 0.075, 0.008)
    for j, s in enumerate(both_sides(endplate)):
        out.append(PartSpec(f"fw_endplate{j}", s, "Accent"))
    for j, s in enumerate(both_sides(vane)):
        out.append(PartSpec(f"fw_vane{j}", s, "Carbon"))
    return out


def make_rear_wing() -> list[PartSpec]:
    out: list[PartSpec] = []
    main = wing_element(2.235, 0.415, 0.290, 9.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.08, thickness=0.11)
    flap = wing_element(2.480, 0.470, 0.200, 32.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.07, thickness=0.09)
    out.append(PartSpec("rw_main", main, "LiveryWhite", surface_control=False))
    out.append(PartSpec("rw_flap", flap, "Accent", surface_control=False))
    # Beam wing: two small elements low down
    b1 = wing_element(2.290, 0.030, 0.150, 8.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.06, thickness=0.10)
    b2 = wing_element(2.450, 0.065, 0.120, 24.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.06, thickness=0.10)
    out.append(PartSpec("beam_wing0", b1, "Carbon", surface_control=False))
    out.append(PartSpec("beam_wing1", b2, "Carbon", surface_control=False))
    endplate = xz_plate(
        [
            (2.42, 0.000),
            (2.58, 0.000),
            (2.60, 0.150),
            (2.70, 0.320),
            (2.70, 0.640),
            (2.30, 0.640),
            (2.17, 0.540),
            (2.20, 0.380),
            (2.40, 0.180),
        ],
        RW_HALF_SPAN,
        0.014,
    )
    endplate = try_fillet(endplate, endplate.edges().filter_by(Axis.Y), 0.05)
    for j, s in enumerate(both_sides(endplate)):
        out.append(PartSpec(f"rw_endplate{j}", s, "Accent"))
    # Swan-neck pylon (single central, from gearbox to mainplane underside)
    pylon = xz_plate(
        [(2.05, -0.02), (2.20, -0.02), (2.40, 0.43), (2.30, 0.45), (2.22, 0.30)],
        -0.008,
        0.016,
    )
    pylon = try_fillet(pylon, pylon.edges().filter_by(Axis.Y), 0.012)
    out.append(PartSpec("rw_pylon", pylon, "Carbon"))
    return out


def make_floor_and_diffuser() -> list[PartSpec]:
    out: list[PartSpec] = []
    half = [
        (-1.05, 0.0),
        (-1.05, 0.30),
        (-0.85, 0.52),
        (-0.62, 0.78),
        (1.15, 0.78),
        (1.30, 0.62),
        (1.45, 0.54),
        (1.62, 0.54),
        (1.62, 0.0),
    ]
    outline = half + [(x, -y) for x, y in reversed(half[1:-1])]
    floor = xy_plate(outline, FLOOR_BOTTOM_Z, FLOOR_T)
    floor = try_fillet(floor, floor.edges().filter_by(Axis.Z), 0.03)
    out.append(PartSpec("floor", floor, "Carbon"))

    # Floor edge wing: small upturned lip along the outer edge.
    edge_wing = xz_plate([(-0.55, 0.0), (1.05, 0.0), (1.05, 0.020), (-0.45, 0.035)], 0.0, 0.006)
    lip = edge_wing.moved(Location((0, 0.775, FLOOR_BOTTOM_Z + FLOOR_T - 0.001)))
    for j, s in enumerate(both_sides(lip)):
        out.append(PartSpec(f"edge_wing{j}", s, "Carbon"))

    # Floor fences ahead of the sidepods (leading edge of the venturi tunnels)
    for y in (0.20, 0.32, 0.44):
        fence = xz_plate([(-1.02, FLOOR_BOTTOM_Z + 0.015), (-0.55, FLOOR_BOTTOM_Z + 0.015),
                          (-0.60, FLOOR_BOTTOM_Z + 0.09), (-0.98, FLOOR_BOTTOM_Z + 0.07)], y, 0.006)
        for j, s in enumerate(both_sides(fence)):
            out.append(PartSpec(f"fence{y}_{j}", s, "Carbon"))

    # Diffuser: ramp, side walls and strakes.
    dx0, dx1 = 1.50, 2.32
    ramp = xz_plate([(dx0, FLOOR_BOTTOM_Z), (dx1, -0.090), (dx1, -0.072), (dx0, FLOOR_BOTTOM_Z + 0.018)],
                    -0.54, 1.08)
    out.append(PartSpec("diffuser", ramp, "Carbon"))
    wall = xz_plate([(dx0 - 0.05, FLOOR_BOTTOM_Z), (dx1, -0.095), (dx1, 0.00), (dx0 - 0.05, -0.24)], 0.53, 0.012)
    wall = try_fillet(wall, wall.edges().filter_by(Axis.Y), 0.02)
    for j, s in enumerate(both_sides(wall)):
        out.append(PartSpec(f"diff_wall{j}", s, "Carbon"))
    for y in (0.17, 0.35):
        strake = xz_plate([(dx0 + 0.05, FLOOR_BOTTOM_Z + 0.012), (dx1, -0.088), (dx1, -0.17),
                           (dx0 + 0.30, -0.27)], y, 0.008)
        for j, s in enumerate(both_sides(strake)):
            out.append(PartSpec(f"strake{y}_{j}", s, "Carbon"))
    return out


def make_rear_details() -> list[PartSpec]:
    exhaust = Solid.make_cylinder(0.042, 0.42, Plane(origin=(1.95, 0, 0.075), z_dir=(1, 0, 0.06)))
    bore = Solid.make_cylinder(0.032, 0.2, Plane(origin=(2.25, 0, 0.093), z_dir=(1, 0, 0.06)))
    exhaust = exhaust - bore
    light = Box(0.03, 0.10, 0.05).locate(Location((2.425, 0, -0.105)))
    light = try_fillet(light, light.edges().filter_by(Axis.X), 0.012)
    return [PartSpec("exhaust", exhaust, "Metal"), PartSpec("rain_light", light, "Light")]


def make_driver() -> list[PartSpec]:

    c = Vector(-0.05, 0.0, 0.335)
    shell = scale(Sphere(0.125), by=(1.12, 1.0, 1.04)).moved(Location(c))
    visor_band = Box(0.20, 0.30, 0.050).locate(Location((c.X - 0.10, 0, c.Z + 0.005)))
    visor_shell = scale(Sphere(0.1275), by=(1.12, 1.0, 1.04)).moved(Location(c)) & visor_band
    visor_shell = visor_shell - Box(0.30, 0.30, 0.30).locate(Location((c.X + 0.10, 0, c.Z)))
    # Neck / shoulders hidden in the cockpit
    neck = Solid.make_cylinder(0.06, 0.16, Plane(origin=(c.X + 0.01, 0, 0.10)))
    return [
        PartSpec("helmet", shell, "Helmet"),
        PartSpec("visor", visor_shell, "Visor"),
        PartSpec("neck", neck, "Carbon"),
    ]


def build_parts() -> list[PartSpec]:
    builders = [
        make_chassis,
        make_sidepods,
        make_airbox_and_fin,
        make_halo,
        make_mirrors,
        make_front_wing,
        make_rear_wing,
        make_floor_and_diffuser,
        make_rear_details,
        make_driver,
    ]
    parts: list[PartSpec] = []
    for b in builders:
        print(f"building {b.__name__} ...")
        parts.extend(b())
    return parts


def main() -> None:
    parts = build_parts()
    groups = {name: MeshGroup(mat) for name, mat in MATERIALS.items()}
    total = 0
    for p in parts:
        n = groups[p.material].add_shape(p.shape, TESS_TOL, TESS_ANG, p.surface_control)
        total += n
        print(f"  {p.name:18s} {p.material:12s} {n:7d} tris")
    write_glb(OUT_PATH, list(groups.values()))
    for g in groups.values():
        print(f"{g.material.name:12s} {g.triangle_count:7d} tris")
    print(f"total {total} triangles -> {OUT_PATH.relative_to(REPO)}")


if __name__ == "__main__":
    main()
