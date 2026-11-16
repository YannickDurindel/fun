#!/usr/bin/env python3
"""Parametric hill-climb prototype body (a generic open-cockpit sports racer: a low central
tub with the driver on the centreline behind a wrap-round screen, peaked fenders enclosing
the wheels, a tall airbox that doubles as the roll structure, a big rear wing on swan necks,
a long splitter with two dive planes per side and a deep diffuser; no make or brand),
modelled with build123d like ``endurance_body.py``. Materials:
scenes/car/hillclimb_body_visual.tscn.

Regenerate the Godot asset with one command (from the repo root):

    .venv/bin/python cad/body/hillclimb_body.py     # -> assets/car/hill_climb/body.glb

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.
``--out PATH`` writes the GLB somewhere else.

Frame: same as ``f1_body.py``: CAD x = backward, y = right, z = up (Godot car-local:
forward = -Z, up = +Y, right = +X). The origin is at axle height, ground at z = -0.36.

Dimensions: length 4.55 m (splitter included), width 2.01 m over the fenders, the airbox
1.02 m above the ground, wheelbase 2.60 m: front axle x = -1.30, rear x = +1.30.

Wheels: none here. The car reuses the F1 wheel assets (front R 0.33 m, rear R 0.36 m) at the
centres the game must use (Godot car-local, like ``Car.WHEEL_OFFSETS``): front
(+-0.82, 0, -1.30), rear (+-0.80, 0, +1.30).

Material order: the F1 body's eight first (the body scene overrides nodes by index,
``body_motion.gd`` moves Helmet + Visor, ``bot_manager.gd`` recolours Livery / LiveryWhite /
Accent / Helmet), then Glass and Headlight, as on the endurance body.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from build123d import Axis, Location, Plane, Solid, Sphere, mirror, scale

sys.path.insert(0, str(Path(__file__).resolve().parent))
from endurance_body import (  # noqa: E402
    PartSpec, both_sides, box, loft, mirrored_box, split, try_fillet, wing_element, xy_plate, xz_plate,
)
from glb_writer import Material, MeshGroup, write_glb  # noqa: E402
from profiles import Section  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
OUT_PATH = REPO / "assets" / "car" / "hill_climb" / "body.glb"

GROUND_Z = -0.36
FLOOR_BOTTOM_Z = -0.30  # 6 cm ride height
FRONT_AXLE_X, REAR_AXLE_X = -1.30, 1.30
NOSE_X, TAIL_X = -2.25, 2.22
HALF_WIDTH = 1.005
FRONT_TYRE_R, REAR_TYRE_R = 0.33, 0.36
ARCH_CLEARANCE = 0.04
RW_HALF_SPAN = 0.86
COCKPIT = (-0.25, 0.0, 0.30, 1.00, 0.62, 0.60)   # centre x, y, z and size of the opening

TESS_TOL = 0.0015
TESS_ANG = 0.18

MATERIALS = {
    "Livery": Material("Livery", (0.95, 0.36, 0.03, 1.0), 0.30, 0.28),
    "LiveryWhite": Material("LiveryWhite", (0.90, 0.90, 0.88, 1.0), 0.05, 0.30),
    "Accent": Material("Accent", (0.05, 0.10, 0.32, 1.0), 0.10, 0.30),
    "Carbon": Material("Carbon", (0.030, 0.031, 0.034, 1.0), 0.20, 0.30),
    "Metal": Material("Metal", (0.80, 0.80, 0.82, 1.0), 1.0, 0.12),
    "Helmet": Material("Helmet", (0.95, 0.95, 0.95, 1.0), 0.05, 0.22),
    "Visor": Material("Visor", (0.02, 0.02, 0.03, 1.0), 0.6, 0.08),
    "Light": Material("Light", (0.6, 0.0, 0.0, 1.0), 0.0, 0.4, emissive=(1.0, 0.05, 0.03)),
    "Glass": Material("Glass", (0.05, 0.06, 0.07, 1.0), 0.0, 0.05),
    "Headlight": Material("Headlight", (0.9, 0.9, 0.85, 1.0), 0.0, 0.3, emissive=(1.0, 0.96, 0.88)),
}

# Central tub: a low nose rising to the cockpit sides, then the engine bay.
HULL = [
    #       x,     width, z_bot,  z_top
    Section(NOSE_X, 1.400, -0.250, -0.120, n_top=2.8, n_bot=3.0, taper=0.92),
    Section(-2.000, 1.500, -0.285, -0.030, n_top=3.2, n_bot=4.0, taper=0.90),
    Section(-1.400, 1.100, -0.290, 0.060, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(-0.800, 1.100, -0.290, 0.180, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(0.000, 1.200, -0.290, 0.220, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(0.800, 1.300, -0.290, 0.180, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(1.600, 1.300, -0.280, 0.140, n_top=3.0, n_bot=4.0, taper=0.88),
    Section(TAIL_X, 1.300, -0.180, 0.120, n_top=3.0, n_bot=4.0, taper=0.90),
]
# Front fenders: tall and peaked over the wheels, falling into the sidepods.
FRONT_FENDER = [
    Section(-2.240, 0.400, -0.240, 0.000, y_center=0.745, n_top=2.4, n_bot=3.0, taper=0.78),
    Section(-2.050, 0.460, -0.270, 0.160, y_center=0.755, n_top=2.3, n_bot=3.5, taper=0.70),
    Section(-1.750, 0.500, -0.280, 0.340, y_center=0.755, n_top=2.2, n_bot=3.5, taper=0.62),
    Section(-1.300, 0.500, -0.280, 0.440, y_center=0.755, n_top=2.2, n_bot=3.5, taper=0.60),
    Section(-0.950, 0.500, -0.280, 0.380, y_center=0.755, n_top=2.3, n_bot=3.5, taper=0.64),
    Section(-0.650, 0.460, -0.285, 0.220, y_center=0.740, n_top=2.6, n_bot=3.5, taper=0.78),
    Section(-0.400, 0.420, -0.285, 0.120, y_center=0.720, n_top=3.0, n_bot=3.5, taper=0.85),
]
SIDEPOD = [
    Section(-0.700, 0.440, -0.285, 0.140, y_center=0.710, n_top=3.2, n_bot=3.5, taper=0.86),
    Section(0.000, 0.480, -0.290, 0.100, y_center=0.700, n_top=3.2, n_bot=3.5, taper=0.86),
    Section(0.600, 0.480, -0.290, 0.120, y_center=0.700, n_top=3.2, n_bot=3.5, taper=0.86),
    Section(0.900, 0.460, -0.285, 0.180, y_center=0.710, n_top=3.2, n_bot=3.5, taper=0.86),
]
REAR_FENDER = [
    Section(0.550, 0.440, -0.285, 0.140, y_center=0.720, n_top=3.0, n_bot=3.5, taper=0.85),
    Section(0.900, 0.480, -0.285, 0.340, y_center=0.745, n_top=2.6, n_bot=3.5, taper=0.72),
    Section(1.300, 0.500, -0.285, 0.470, y_center=0.755, n_top=2.4, n_bot=3.5, taper=0.66),
    Section(1.750, 0.500, -0.270, 0.440, y_center=0.755, n_top=2.4, n_bot=3.5, taper=0.68),
    Section(TAIL_X, 0.480, -0.180, 0.340, y_center=0.750, n_top=2.6, n_bot=3.2, taper=0.74),
]
# Airbox: rises behind the driver's head (the roll structure), tapers down the engine cover.
AIRBOX = [
    Section(0.280, 0.480, 0.000, 0.660, n_top=2.4, n_bot=3.0, taper=0.55),
    Section(0.700, 0.680, 0.000, 0.520, n_top=2.4, n_bot=3.0, taper=0.58),
    Section(1.300, 0.800, 0.000, 0.360, n_top=2.4, n_bot=3.0, taper=0.62),
    Section(1.900, 0.800, -0.050, 0.250, n_top=2.4, n_bot=3.0, taper=0.66),
    Section(TAIL_X, 0.700, -0.100, 0.180, n_top=2.4, n_bot=3.0, taper=0.72),
]
# Wrap-round screen in front of the cockpit (a low tinted deflector).
SCREEN = [
    Section(-1.100, 0.700, 0.040, 0.100, n_top=2.4, n_bot=3.0, taper=0.70),
    Section(-0.880, 0.800, 0.040, 0.300, n_top=2.4, n_bot=3.0, taper=0.66),
    Section(-0.720, 0.820, 0.040, 0.370, n_top=2.4, n_bot=3.0, taper=0.66),
]


def arch_cutter(axle_x: float, tyre_r: float, y0: float, extra: float = 0.0) -> Solid:
    return Solid.make_cylinder(tyre_r + ARCH_CLEARANCE + extra, HALF_WIDTH + 0.2 - y0,
                               Plane(origin=(axle_x, y0, 0.0), z_dir=(0, 1, 0)))


def make_bodywork() -> list[PartSpec]:
    body = loft(HULL) + loft(AIRBOX)
    for secs in (FRONT_FENDER, SIDEPOD, REAR_FENDER):
        for side in both_sides(loft(secs)):
            body = body + side
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        for c in both_sides(arch_cutter(axle_x, r, 0.50)):
            body = body - c
    cx, cy, cz, dx, dy, dz = COCKPIT
    body = body - box(cx, cy, cz, dx, dy, dz)
    out: list[PartSpec] = []

    # The cockpit's walls and floor: carbon.
    body, tub = split(body, box(cx, cy, cz - 0.02, dx + 0.04, dy + 0.04, dz + 0.04))
    out.append(PartSpec("cockpit", tub, "Carbon"))
    # Airbox intake over the driver's head.
    body, mouth = split(body, box(0.285, 0, 0.560, 0.03, 0.26, 0.120))
    out.append(PartSpec("airbox_mouth", mouth, "Carbon"))

    # Front: black lip with the radiator mouth, headlights in the fender faces.
    body, lip = split(body, box(-2.20, 0, -0.230, 0.60, 2.4, 0.10))
    body, mouth = split(body, box(-2.27, 0, -0.140, 0.30, 0.60, 0.06))
    out += [PartSpec("nose_lip", lip, "Carbon"), PartSpec("nose_mouth", mouth, "Carbon")]
    body, lamps = split(body, mirrored_box(-2.17, 0.76, 0.020, 0.26, 0.26, 0.070))
    out.append(PartSpec("headlights", lamps, "Headlight"))
    # Louvres on the fenders over the front wheels.
    body, louvres = split(body, mirrored_box(-1.30, 0.755, 0.50, 0.44, 0.26, 0.14))
    out.append(PartSpec("louvres", louvres, "Carbon"))

    # Tail: lights at the top of the rear fenders, a black panel across the gearbox.
    body, tail = split(body, mirrored_box(TAIL_X, 0.76, 0.250, 0.10, 0.26, 0.060))
    out.append(PartSpec("tail_lights", tail, "Light"))
    body, rear_panel = split(body, box(TAIL_X, 0, -0.06, 0.14, 1.2, 0.28))
    out.append(PartSpec("rear_panel", rear_panel, "Carbon"))

    # Black sills, a number board on each sidepod, a stripe up the nose and over the airbox.
    body, sills = split(body, mirrored_box(0.0, 0.95, -0.235, 4.4, 0.40, 0.11))
    out.append(PartSpec("sills", sills, "Carbon"))
    body, board = split(body, mirrored_box(0.25, 1.00, -0.050, 0.55, 0.40, 0.22))
    body, nose_st = split(body, box(-1.60, 0, 0.0, 1.40, 0.24, 0.50))
    body, spine = split(body, box(1.00, 0, 0.55, 1.60, 0.16, 0.50))
    out += [PartSpec("number_board", board, "LiveryWhite"), PartSpec("nose_stripe", nose_st, "Accent"),
            PartSpec("airbox_stripe", spine, "Accent")]

    # Wheel-arch liners.
    liners = None
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        ring = arch_cutter(axle_x, r, 0.46, 0.035) - arch_cutter(axle_x, r, 0.50)
        ring = ring + mirror(ring, about=Plane.XZ)
        liners = ring if liners is None else liners + ring
    body, liner = split(body, liners)
    out.append(PartSpec("arch_liners", liner, "Carbon"))

    # Panel lines: front and rear clam shells.
    g = 0.006
    grooves = box(-0.90, 0, 0.1, g, 2.2, 0.5) + box(0.85, 0, 0.1, g, 2.2, 0.5)
    body, gr = split(body, grooves)
    out.append(PartSpec("panel_lines", gr, "Carbon"))

    out.insert(0, PartSpec("body", body, "Livery"))
    screen = loft(SCREEN) - box(cx, cy, cz, dx, dy, dz)
    out.append(PartSpec("screen", screen, "Glass"))
    return out


def make_mirrors() -> list[PartSpec]:
    """Mirror pods on stalks from the front fenders."""
    housing = loft([
        Section(-0.800, 0.120, 0.280, 0.350, y_center=0.800, n_top=2.6, n_bot=2.6, taper=0.85),
        Section(-0.710, 0.160, 0.270, 0.370, y_center=0.800, n_top=3.0, n_bot=3.0, taper=0.90),
        Section(-0.680, 0.160, 0.270, 0.370, y_center=0.800, n_top=3.0, n_bot=3.0, taper=0.90),
    ])
    housing, glass = split(housing, box(-0.675, 0.800, 0.320, 0.03, 0.14, 0.08))
    stalk = box(-0.72, 0.77, 0.20, 0.05, 0.03, 0.16)
    out = []
    for i, s in enumerate(both_sides(housing)):
        out.append(PartSpec(f"mirror{i}", s, "Livery"))
    for i, s in enumerate(both_sides(glass)):
        out.append(PartSpec(f"mirror_glass{i}", s, "Metal"))
    for i, s in enumerate(both_sides(stalk)):
        out.append(PartSpec(f"mirror_stalk{i}", s, "Carbon", False))
    return out


def make_rear_wing() -> list[PartSpec]:
    """A big two-element wing standing high behind the car, on swan necks from the cover."""
    out: list[PartSpec] = []
    main = wing_element(1.800, 0.780, 0.400, 8.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.08, thickness=0.11)
    flap = wing_element(2.170, 0.830, 0.170, 32.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.07, thickness=0.09)
    out.append(PartSpec("rw_main", main, "Carbon", surface_control=False))
    out.append(PartSpec("rw_flap", flap, "Accent", surface_control=False))
    endplate = xz_plate([(1.700, 0.450), (2.400, 0.400), (2.420, 0.950), (2.100, 0.950), (1.850, 0.820)],
                        RW_HALF_SPAN, 0.016)
    endplate = try_fillet(endplate, endplate.edges().filter_by(Axis.Y), 0.04)
    for j, s in enumerate(both_sides(endplate)):
        out.append(PartSpec(f"rw_endplate{j}", s, "Carbon", surface_control=False))
    gurney = box(2.322, 0, 0.900, 0.006, 2 * RW_HALF_SPAN, 0.035)
    out.append(PartSpec("rw_gurney", gurney, "LiveryWhite", False))
    neck = xz_plate([(1.550, 0.250), (1.700, 0.250), (1.820, 0.700), (1.950, 0.830), (2.100, 0.850),
                     (2.100, 0.880), (1.920, 0.870), (1.750, 0.750), (1.620, 0.450)], 0.280, 0.016)
    neck = try_fillet(neck, neck.edges().filter_by(Axis.Y), 0.012)
    for j, s in enumerate(both_sides(neck)):
        out.append(PartSpec(f"rw_neck{j}", s, "Carbon", False))
    return out


def make_floor_splitter_diffuser() -> list[PartSpec]:
    out: list[PartSpec] = []
    half = [(-1.95, 0.0), (-1.95, 0.62), (1.95, 0.62), (1.95, 0.0)]
    outline = half + [(x, -y) for x, y in reversed(half[1:-1])]
    out.append(PartSpec("floor", xy_plate(outline, FLOOR_BOTTOM_Z, 0.02), "Carbon", False))
    split_half = [(-2.42, 0.0), (-2.42, 0.80), (-2.30, 0.97), (-1.95, 0.99), (-1.95, 0.0)]
    split_outline = split_half + [(x, -y) for x, y in reversed(split_half[1:-1])]
    splitter = xy_plate(split_outline, FLOOR_BOTTOM_Z, 0.018)
    splitter = try_fillet(splitter, splitter.edges().filter_by(Axis.Z), 0.03)
    out.append(PartSpec("splitter", splitter, "Carbon", False))
    # Two dive planes on each corner of the nose.
    for k, (x0, z) in enumerate(((-2.24, -0.140), (-2.02, -0.060))):
        plane = xy_plate([(x0, 0.74), (x0 + 0.15, 0.74), (x0 + 0.21, 0.99), (x0 + 0.05, 0.99)], z, 0.012)
        for j, s in enumerate(both_sides(plane)):
            out.append(PartSpec(f"dive_plane{k}_{j}", s, "Carbon", False))
    dx0, dx1 = 1.85, TAIL_X + 0.02
    ramp = xz_plate([(dx0, FLOOR_BOTTOM_Z), (dx1, -0.150), (dx1, -0.130), (dx0, FLOOR_BOTTOM_Z + 0.018)],
                    -0.62, 1.24)
    out.append(PartSpec("diffuser", ramp, "Carbon", False))
    for y in (0.0, 0.20, 0.40, 0.60):
        strake = xz_plate([(dx0 + 0.05, FLOOR_BOTTOM_Z + 0.012), (dx1, -0.148), (dx1, -0.230),
                           (dx0 + 0.25, -0.290)], y - 0.006, 0.012)
        for j, s in enumerate(both_sides(strake) if y else [strake]):
            out.append(PartSpec(f"strake{y}_{j}", s, "Carbon", False))
    exhaust = Solid.make_cylinder(0.045, 0.14, Plane(origin=(TAIL_X - 0.10, 0.20, 0.06), z_dir=(1, 0, 0)))
    for j, s in enumerate(both_sides(exhaust)):
        out.append(PartSpec(f"exhaust{j}", s, "Metal", False))
    rain = box(TAIL_X + 0.012, 0, -0.095, 0.02, 0.12, 0.05)
    out.append(PartSpec("rain_light", rain, "Light", False))
    return out


def make_driver() -> list[PartSpec]:
    """Helmet + visor in the open cockpit, on the centreline (body_motion.gd moves them)."""
    c = (0.05, 0.0, 0.330)
    shell = scale(Sphere(0.125), by=(1.12, 1.0, 1.04)).moved(Location(c))
    visor_band = box(c[0] - 0.10, c[1], c[2] + 0.005, 0.20, 0.30, 0.050)
    visor = scale(Sphere(0.1275), by=(1.12, 1.0, 1.04)).moved(Location(c)) & visor_band
    visor = visor - box(c[0] + 0.10, c[1], c[2], 0.30, 0.30, 0.30)
    return [PartSpec("helmet", shell, "Helmet"), PartSpec("visor", visor, "Visor")]


def build_parts() -> list[PartSpec]:
    parts: list[PartSpec] = []
    for b in (make_bodywork, make_mirrors, make_rear_wing, make_floor_splitter_diffuser, make_driver):
        print(f"building {b.__name__} ...")
        parts.extend(b())
    return parts


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=OUT_PATH)
    args = ap.parse_args()
    out_path: Path = args.out.resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    parts = build_parts()
    groups = {name: MeshGroup(mat) for name, mat in MATERIALS.items()}
    total = 0
    for p in parts:
        if p.shape is None:
            print(f"  {p.name:18s} EMPTY, skipped")
            continue
        n = groups[p.material].add_shape(p.shape, TESS_TOL, TESS_ANG, p.surface_control)
        total += n
        print(f"  {p.name:18s} {p.material:12s} {n:7d} tris")
    write_glb(out_path, list(groups.values()), root_name="HillClimbBody")
    print(f"total {total} triangles -> {out_path}")


if __name__ == "__main__":
    main()
