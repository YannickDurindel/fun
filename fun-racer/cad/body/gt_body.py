#!/usr/bin/env python3
"""Parametric GT3-style coupe body (a generic front-engine racing coupe: long bonnet between
peaked front fenders, cabin set back, fastback roof, wide rear haunches, swan-neck rear wing,
splitter and diffuser), modelled with build123d. No real car or brand is copied.

Regenerate the Godot asset with one command (from the repo root):

    .venv/bin/python cad/body/gt_body.py     # -> assets/car/gt/body.glb

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.
``--out PATH`` writes the GLB somewhere else.

Frame and conventions: as ``endurance_body.py`` (CAD x = backward, y = right, z = up; origin
at axle height, ground at z = -0.36), whose helpers this module reuses. The first eight
materials are the F1 body's, in the same order (scenes/car/gt_body_visual.tscn, body_motion.gd
and bot_manager.gd rely on their names), then Glass and Headlight.

Dimensions (GT3 class): length 4.60 m, width 2.04 m over the fenders, roof 1.22 m above the
ground, wheelbase 2.65 m: front axle x = -1.325, rear axle x = +1.325. Front overhang 1.05 m,
rear 0.90 m. Wheels: the F1 wheel assets (front R 0.33 m, rear R 0.36 m). Wheel centres the
game must use (Godot car-local): front (+-0.84, 0, -1.325), rear (+-0.82, 0, +1.325).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from build123d import Axis, Location, Plane, Solid, Sphere, Vector, mirror, scale

sys.path.insert(0, str(Path(__file__).resolve().parent))
from glb_writer import Material, MeshGroup, write_glb  # noqa: E402
from profiles import Section  # noqa: E402
from endurance_body import (  # noqa: E402
    PartSpec,
    both_sides,
    box,
    loft,
    mirrored_box,
    split,
    try_fillet,
    tube,
    wing_element,
    xy_plate,
    xz_plate,
)

REPO = Path(__file__).resolve().parents[2]
OUT_PATH = REPO / "assets" / "car" / "gt" / "body.glb"

GROUND_Z = -0.36
FLOOR_BOTTOM_Z = -0.27  # 9 cm ride height
FLOOR_T = 0.02
FRONT_AXLE_X = -1.325
REAR_AXLE_X = 1.325
NOSE_X = -2.375
TAIL_X = 2.225
HALF_WIDTH = 1.02
ROOF_Z = GROUND_Z + 1.22

FRONT_TYRE_R, REAR_TYRE_R = 0.33, 0.36
FRONT_WHEEL_Z = FRONT_TYRE_R - REAR_TYRE_R  # the front wheels sit lower by the radius difference
ARCH_CLEARANCE = 0.04
RW_HALF_SPAN = 0.86

TESS_TOL = 0.0015
TESS_ANG = 0.18

MATERIALS = {
    # Deep blue paint, white panels, orange accents (the scene overrides them with clear coat).
    "Livery": Material("Livery", (0.03, 0.10, 0.40, 1.0), 0.30, 0.28),
    "LiveryWhite": Material("LiveryWhite", (0.88, 0.88, 0.86, 1.0), 0.05, 0.30),
    "Accent": Material("Accent", (0.98, 0.42, 0.04, 1.0), 0.10, 0.30),
    "Carbon": Material("Carbon", (0.030, 0.031, 0.034, 1.0), 0.20, 0.30),
    "Metal": Material("Metal", (0.80, 0.80, 0.82, 1.0), 1.0, 0.12),
    "Helmet": Material("Helmet", (0.95, 0.95, 0.95, 1.0), 0.05, 0.22),
    "Visor": Material("Visor", (0.02, 0.02, 0.03, 1.0), 0.6, 0.08),
    "Light": Material("Light", (0.6, 0.0, 0.0, 1.0), 0.0, 0.4, emissive=(1.0, 0.05, 0.03)),
    "Glass": Material("Glass", (0.05, 0.06, 0.07, 1.0), 0.0, 0.05),
    "Headlight": Material("Headlight", (0.9, 0.9, 0.85, 1.0), 0.0, 0.3, emissive=(1.0, 0.96, 0.88)),
}

# --------------------------------------------------------------------------
# Sections
# --------------------------------------------------------------------------
HULL_SECTIONS = [
    # x,      width, z_bot, z_top: a low nose, the bonnet rising to the cowl, a high tail deck
    Section(-2.360, 1.600, -0.235, -0.070, n_top=3.0, n_bot=3.0, taper=0.90),
    Section(-2.150, 1.800, -0.262, 0.070, n_top=3.4, n_bot=4.0, taper=0.90),
    Section(-1.700, 1.860, -0.270, 0.215, n_top=3.4, n_bot=4.0, taper=0.88),
    Section(-1.000, 1.880, -0.270, 0.280, n_top=3.4, n_bot=4.0, taper=0.88),
    Section(-0.550, 1.900, -0.270, 0.330, n_top=3.4, n_bot=4.0, taper=0.88),
    Section(0.300, 1.900, -0.270, 0.370, n_top=3.4, n_bot=4.0, taper=0.88),
    Section(1.200, 1.900, -0.270, 0.410, n_top=3.4, n_bot=4.0, taper=0.88),
    Section(1.900, 1.860, -0.250, 0.430, n_top=3.6, n_bot=4.0, taper=0.88),
    Section(2.220, 1.760, -0.180, 0.405, n_top=3.6, n_bot=3.6, taper=0.90),
]
# Front fenders: peaked over the wheels, standing proud of the bonnet, into the doors.
FRONT_FENDER = [
    Section(-2.300, 0.360, -0.235, 0.060, y_center=0.760, n_top=2.6, n_bot=3.0, taper=0.78),
    Section(-2.050, 0.440, -0.262, 0.280, y_center=0.790, n_top=2.4, n_bot=3.5, taper=0.70),
    Section(-1.700, 0.460, -0.270, 0.390, y_center=0.800, n_top=2.4, n_bot=3.5, taper=0.66),
    Section(-1.325, 0.460, -0.270, 0.430, y_center=0.800, n_top=2.4, n_bot=3.5, taper=0.66),
    Section(-0.950, 0.460, -0.270, 0.390, y_center=0.800, n_top=2.5, n_bot=3.5, taper=0.70),
    Section(-0.600, 0.400, -0.270, 0.300, y_center=0.780, n_top=2.8, n_bot=3.5, taper=0.80),
    Section(-0.300, 0.340, -0.270, 0.250, y_center=0.760, n_top=3.0, n_bot=3.5, taper=0.86),
]
# Rear haunches: wider and higher, carried to the tail.
REAR_FENDER = [
    Section(0.350, 0.340, -0.270, 0.300, y_center=0.770, n_top=3.0, n_bot=3.5, taper=0.86),
    Section(0.800, 0.440, -0.270, 0.430, y_center=0.800, n_top=2.6, n_bot=3.5, taper=0.72),
    Section(1.325, 0.460, -0.270, 0.500, y_center=0.800, n_top=2.4, n_bot=3.5, taper=0.68),
    Section(1.850, 0.460, -0.255, 0.470, y_center=0.800, n_top=2.5, n_bot=3.5, taper=0.70),
    Section(2.200, 0.420, -0.185, 0.420, y_center=0.785, n_top=2.8, n_bot=3.2, taper=0.76),
]
# Cabin: windscreen from the cowl, roof peak behind the driver, a long fastback to the deck.
CABIN_SECTIONS = [
    Section(-0.760, 1.360, 0.000, 0.360, z_split=0.300, n_top=2.6, n_bot=3.0, taper=0.70),
    Section(-0.450, 1.500, 0.000, 0.600, z_split=0.380, n_top=2.6, n_bot=3.0, taper=0.68),
    Section(-0.100, 1.520, 0.000, 0.820, z_split=0.400, n_top=2.6, n_bot=3.0, taper=0.66),
    Section(0.350, 1.500, 0.000, ROOF_Z, z_split=0.410, n_top=2.6, n_bot=3.0, taper=0.66),
    Section(0.850, 1.440, 0.000, 0.780, z_split=0.420, n_top=2.6, n_bot=3.0, taper=0.68),
    Section(1.400, 1.260, 0.000, 0.600, z_split=0.430, n_top=2.6, n_bot=3.0, taper=0.72),
    Section(1.880, 0.960, 0.000, 0.460, z_split=0.420, n_top=2.6, n_bot=3.0, taper=0.80),
]
GLASS_X0, GLASS_X1 = -0.600, 0.950
GLASS_Z0, GLASS_Z1 = 0.440, 0.790


def arch_cutter(axle_x: float, axle_z: float, tyre_r: float, y0: float) -> Solid:
    return Solid.make_cylinder(tyre_r + ARCH_CLEARANCE, HALF_WIDTH + 0.2 - y0,
                               Plane(origin=(axle_x, y0, axle_z), z_dir=(0, 1, 0)))


AXLES = ((FRONT_AXLE_X, FRONT_WHEEL_Z, FRONT_TYRE_R), (REAR_AXLE_X, 0.0, REAR_TYRE_R))


def make_bodywork() -> list[PartSpec]:
    body = loft(HULL_SECTIONS)
    for secs in (FRONT_FENDER, REAR_FENDER):
        for side in both_sides(loft(secs)):
            body = body + side
    for axle_x, axle_z, r in AXLES:
        for c in both_sides(arch_cutter(axle_x, axle_z, r, 0.55)):
            body = body - c
    # Vents behind the front wheels (fender exits).
    body = body - mirrored_box(-0.80, 1.12, 0.10, 0.30, 0.30, 0.18)
    out: list[PartSpec] = []

    # Nose: black lip, central radiator mouth, two side intakes.
    body, lip = split(body, box(-2.25, 0, -0.230, 0.40, 2.4, 0.08))
    body, mouth = split(body, box(-2.40, 0, -0.120, 0.36, 0.86, 0.13))
    body, side_in = split(body, mirrored_box(-2.36, 0.68, -0.140, 0.30, 0.20, 0.08))
    out += [PartSpec("nose_lip", lip, "Carbon"), PartSpec("nose_mouth", mouth + side_in, "Carbon")]

    # Headlights: slim strips on the front faces of the fenders.
    body, lights = split(body, mirrored_box(-2.17, 0.79, 0.090, 0.26, 0.30, 0.075))
    out.append(PartSpec("headlights", lights, "Headlight"))

    # Bonnet vents behind the front axle: carbon panels with slots.
    body, vent = split(body, mirrored_box(-1.10, 0.36, 0.30, 0.42, 0.30, 0.25))
    for k in range(6):
        vent = vent - mirrored_box(-1.26 + 0.065 * k, 0.36, 0.32, 0.028, 0.24, 0.25)
    out.append(PartSpec("bonnet_vents", vent, "Carbon"))
    floor = None
    for k in range(6):
        f = mirrored_box(-1.26 + 0.065 * k, 0.36, 0.20, 0.028, 0.24, 0.006)
        floor = f if floor is None else floor + f
    out.append(PartSpec("vent_depth", floor, "Carbon", False))

    # Fender exits: carbon inside.
    body, exits = split(body, mirrored_box(-0.80, 1.08, 0.10, 0.34, 0.38, 0.22))
    out.append(PartSpec("fender_exits", exits, "Carbon"))

    # Tail: a full-width red light bar, black panel and diffuser exit below it.
    body, tled = split(body, box(2.20, 0, 0.290, 0.14, 2.4, 0.040))
    body, rear_panel = split(body, box(2.20, 0, -0.030, 0.14, 2.4, 0.24))
    out += [PartSpec("tail_light", tled, "Light"), PartSpec("rear_panel", rear_panel, "Carbon")]

    # Black sills between the arches.
    body, sills = split(body, mirrored_box(0.0, 0.98, -0.225, 1.95, 0.30, 0.10))
    out.append(PartSpec("sills", sills, "Carbon"))

    # White number panel on each door, an orange band above the sills.
    door = Solid.make_cylinder(0.19, 0.40, Plane(origin=(-0.05, 0.80, 0.080), z_dir=(0, 1, 0)))
    body, panel = split(body, door + mirror(door, about=Plane.XZ))
    body, band = split(body, mirrored_box(0.0, 1.06, -0.150, 1.95, 0.40, 0.045))
    body, nose_band = split(body, mirrored_box(-1.90, 0.10, 0.10, 0.90, 0.07, 0.40))
    out += [PartSpec("door_panels", panel, "LiveryWhite"), PartSpec("flank_band", band + nose_band, "Accent")]

    # Wheel-arch liners.
    liners = None
    for axle_x, axle_z, r in AXLES:
        big = Solid.make_cylinder(r + ARCH_CLEARANCE + 0.035, HALF_WIDTH + 0.2 - 0.51,
                                  Plane(origin=(axle_x, 0.51, axle_z), z_dir=(0, 1, 0)))
        ring = big - arch_cutter(axle_x, axle_z, r, 0.55)
        ring = ring + mirror(ring, about=Plane.XZ)
        liners = ring if liners is None else liners + ring
    body, liner = split(body, liners)
    out.append(PartSpec("arch_liners", liner, "Carbon"))

    # Shut lines: doors, bonnet, boot lid.
    g = 0.006
    grooves = mirrored_box(-0.55, 0.95, 0.0, g, 0.3, 0.50)
    grooves = grooves + mirrored_box(0.55, 0.95, 0.0, g, 0.3, 0.50)
    grooves = grooves + mirrored_box(-1.55, 0.55, 0.2, 1.6, g, 0.4)
    grooves = grooves + box(-0.70, 0, 0.25, g, 1.2, 0.3)
    grooves = grooves + box(1.70, 0, 0.40, g, 1.2, 0.3)
    body, groove_part = split(body, grooves)
    out.append(PartSpec("panel_lines", groove_part, "Carbon"))

    out.insert(0, PartSpec("body", body, "Livery"))
    return out


def make_cabin() -> list[PartSpec]:
    cabin = loft(CABIN_SECTIONS)
    band = box(0.5 * (GLASS_X0 + GLASS_X1), 0, 0.5 * (GLASS_Z0 + GLASS_Z1),
               GLASS_X1 - GLASS_X0, 2.0, GLASS_Z1 - GLASS_Z0)
    shell, glass = split(cabin, band)
    # A small rear window in the fastback; the rest of it is body colour.
    shell, rear_glass = split(shell, box(1.20, 0, 0.62, 0.50, 0.70, 0.28))
    glass = glass + rear_glass
    quarter = None
    glass, bpil = split(glass, mirrored_box(0.42, 0.85, 0.55, 0.08, 0.60, 0.5))
    # Black frame round the windscreen (A-pillars and lower edge) and the belt line.
    glass, frame = split(glass, box(GLASS_X0 + 0.03, 0, 0.45, 0.06, 2.0, 0.3))
    glass, belt = split(glass, box(0.5 * (GLASS_X0 + GLASS_X1), 0, GLASS_Z0 + 0.012, GLASS_X1 - GLASS_X0, 2.0, 0.024))
    # Orange roof stripe.
    shell, stripe = split(shell, box(0.30, 0, 0.88, 1.6, 0.22, 0.12))
    return [
        PartSpec("cabin", shell + bpil, "Livery"),
        PartSpec("glazing", glass, "Glass"),
        PartSpec("glass_frame", frame + belt, "Carbon"),
        PartSpec("roof_stripe", stripe, "Accent"),
    ]


def make_mirrors() -> list[PartSpec]:
    housing = loft([
        Section(-0.560, 0.150, 0.420, 0.480, y_center=1.000, n_top=2.6, n_bot=2.6, taper=0.85),
        Section(-0.470, 0.190, 0.410, 0.500, y_center=1.005, n_top=3.0, n_bot=3.0, taper=0.90),
        Section(-0.420, 0.190, 0.410, 0.500, y_center=1.005, n_top=3.0, n_bot=3.0, taper=0.90),
    ])
    housing, glass = split(housing, box(-0.415, 1.005, 0.455, 0.03, 0.17, 0.075))
    stalk = tube([(-0.50, 0.80, 0.33), (-0.49, 0.88, 0.40), (-0.48, 0.93, 0.44)], 0.016)
    out = []
    for i, s in enumerate(both_sides(housing)):
        out.append(PartSpec(f"mirror{i}", s, "Livery"))
    for i, s in enumerate(both_sides(glass)):
        out.append(PartSpec(f"mirror_glass{i}", s, "Metal"))
    for i, s in enumerate(both_sides(stalk)):
        out.append(PartSpec(f"mirror_stalk{i}", s, "Carbon", False))
    return out


def make_rear_wing() -> list[PartSpec]:
    """Big single-element wing on swan-neck pylons from the boot lid."""
    out: list[PartSpec] = []
    main = wing_element(1.800, 0.930, 0.380, 8.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.07, thickness=0.11)
    out.append(PartSpec("rw_main", main, "Carbon", surface_control=False))
    endplate = xz_plate(
        [(1.740, 0.780), (2.240, 0.780), (2.260, 0.840), (2.260, 1.060), (2.000, 1.060), (1.740, 0.960)],
        RW_HALF_SPAN, 0.014,
    )
    endplate = try_fillet(endplate, endplate.edges().filter_by(Axis.Y), 0.04)
    for j, s in enumerate(both_sides(endplate)):
        out.append(PartSpec(f"rw_endplate{j}", s, "Carbon", surface_control=False))
    gurney = box(2.172, 0, 1.000, 0.006, 2 * RW_HALF_SPAN, 0.035)
    out.append(PartSpec("rw_gurney_flap", gurney, "Accent", False))
    neck = xz_plate(
        [(1.980, 0.300), (2.140, 0.300), (2.100, 0.680), (2.010, 0.900), (1.900, 0.975), (1.800, 0.985),
         (1.800, 0.955), (1.880, 0.940), (1.960, 0.860), (2.020, 0.680)],
        0.320, 0.016,
    )
    neck = try_fillet(neck, neck.edges().filter_by(Axis.Y), 0.012)
    for j, s in enumerate(both_sides(neck)):
        out.append(PartSpec(f"rw_neck{j}", s, "Carbon", False))
    return out


def make_floor_splitter_diffuser() -> list[PartSpec]:
    out: list[PartSpec] = []
    half = [(-2.00, 0.0), (-2.00, 0.55), (-0.90, 0.55), (-0.85, 0.92), (0.85, 0.92),
            (0.90, 0.55), (1.85, 0.55), (1.85, 0.0)]
    outline = half + [(x, -y) for x, y in reversed(half[1:-1])]
    out.append(PartSpec("floor", xy_plate(outline, FLOOR_BOTTOM_Z, FLOOR_T), "Carbon", False))

    split_half = [(-2.47, 0.0), (-2.47, 0.78), (-2.38, 0.92), (-2.00, 0.94), (-2.00, 0.0)]
    split_outline = split_half + [(x, -y) for x, y in reversed(split_half[1:-1])]
    splitter = xy_plate(split_outline, FLOOR_BOTTOM_Z, 0.018)
    splitter = try_fillet(splitter, splitter.edges().filter_by(Axis.Z), 0.03)
    out.append(PartSpec("splitter", splitter, "Carbon", False))
    # Canards on the nose corners.
    for z in (-0.170, -0.090):
        for j, s in enumerate(both_sides(xy_plate([(-2.36, 0.70), (-2.24, 0.70), (-2.16, 0.92), (-2.30, 0.92)],
                                                    z, 0.010))):
            out.append(PartSpec(f"canard{z}_{j}", s, "Carbon", False))

    dx0, dx1 = 1.85, TAIL_X + 0.02
    ramp = xz_plate([(dx0, FLOOR_BOTTOM_Z), (dx1, -0.170), (dx1, -0.150), (dx0, FLOOR_BOTTOM_Z + 0.018)],
                    -0.70, 1.40)
    out.append(PartSpec("diffuser", ramp, "Carbon", False))
    for y in (0.0, 0.22, 0.44, 0.66):
        strake = xz_plate([(dx0 + 0.05, FLOOR_BOTTOM_Z + 0.012), (dx1, -0.168), (dx1, -0.240),
                           (dx0 + 0.20, -0.265)], y - 0.006, 0.012)
        for j, s in enumerate(both_sides(strake) if y else [strake]):
            out.append(PartSpec(f"strake{y}_{j}", s, "Carbon", False))
    rain_light = box(TAIL_X + 0.03, 0, -0.130, 0.02, 0.12, 0.05)
    out.append(PartSpec("rain_light", rain_light, "Light", False))
    # Twin exhausts in the sills, ahead of the rear wheels.
    for j, s in enumerate(both_sides(Solid.make_cylinder(0.04, 0.08, Plane(origin=(0.75, 0.92, -0.215),
                                                                            z_dir=(0, 1, 0))))):
        out.append(PartSpec(f"exhaust{j}", s, "Metal", False))
    return out


def make_driver() -> list[PartSpec]:
    """Helmet + visor on the left seat (body_motion.gd moves these two as the head)."""
    c = Vector(0.20, -0.30, 0.560)
    shell = scale(Sphere(0.125), by=(1.12, 1.0, 1.04)).moved(Location(c))
    visor_band = box(c.X - 0.10, c.Y, c.Z + 0.005, 0.20, 0.30, 0.050)
    visor_shell = scale(Sphere(0.1275), by=(1.12, 1.0, 1.04)).moved(Location(c)) & visor_band
    visor_shell = visor_shell - box(c.X + 0.10, c.Y, c.Z, 0.30, 0.30, 0.30)
    return [PartSpec("helmet", shell, "Helmet"), PartSpec("visor", visor_shell, "Visor")]


def build_parts() -> list[PartSpec]:
    parts: list[PartSpec] = []
    for b in (make_bodywork, make_cabin, make_mirrors, make_rear_wing, make_floor_splitter_diffuser,
              make_driver):
        print(f"building {b.__name__} ...")
        parts.extend(b())
    return parts


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=OUT_PATH, help=f"GLB to write (default {OUT_PATH.relative_to(REPO)})")
    args = ap.parse_args()
    out_path: Path = args.out.resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    groups = {name: MeshGroup(mat) for name, mat in MATERIALS.items()}
    total = 0
    for p in build_parts():
        n = groups[p.material].add_shape(p.shape, TESS_TOL, TESS_ANG, p.surface_control)
        total += n
        print(f"  {p.name:18s} {p.material:12s} {n:7d} tris")
    write_glb(out_path, list(groups.values()), root_name="GtBody")
    shown = out_path.relative_to(REPO) if out_path.is_relative_to(REPO) else out_path
    print(f"total {total} triangles -> {shown}")


if __name__ == "__main__":
    main()
