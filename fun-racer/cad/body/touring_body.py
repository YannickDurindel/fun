#!/usr/bin/env python3
"""Parametric touring car body (a generic four-door racing saloon: three-box shape, flared
wheel arches, deep front splitter, boot-mounted rear wing; no make or brand), modelled with
build123d like ``endurance_body.py``. Materials: the body scene scenes/car/touring_body_visual.tscn.

Regenerate the Godot asset with one command (from the repo root):

    .venv/bin/python cad/body/touring_body.py     # -> assets/car/touring/body.glb

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.
``--out PATH`` writes the GLB somewhere else.

Frame: same as ``f1_body.py``: CAD x = backward, y = right, z = up (Godot car-local:
forward = -Z, up = +Y, right = +X). The origin is at axle height, ground at z = -0.36.

Dimensions: length 4.50 m (splitter included), width 1.95 m over the arch flares (1.84 m
body), roof 1.40 m above the ground, wheelbase 2.70 m: front axle x = -1.35, rear x = +1.35.

Wheels: none here. The car reuses the F1 wheel assets (front R 0.33 m, rear R 0.36 m) at
the centres the game must use (Godot car-local, like ``Car.WHEEL_OFFSETS``): front
(+-0.80, 0, -1.35), rear (+-0.78, 0, +1.35). The arches are cut for those with 4 cm clearance.

Material order: the F1 body's eight first (the body scene overrides nodes by index,
``body_motion.gd`` moves Helmet + Visor, ``bot_manager.gd`` recolours Livery / LiveryWhite /
Accent / Helmet), then Glass and Headlight, as on the endurance body.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from build123d import Location, Plane, Solid, Sphere, mirror, scale

sys.path.insert(0, str(Path(__file__).resolve().parent))
from endurance_body import (  # noqa: E402
    PartSpec, both_sides, box, loft, mirrored_box, split, try_fillet, wing_element, xy_plate, xz_plate,
)
from glb_writer import Material, MeshGroup, write_glb  # noqa: E402
from profiles import Section  # noqa: E402

from build123d import Axis  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
OUT_PATH = REPO / "assets" / "car" / "touring" / "body.glb"

GROUND_Z = -0.36
FLOOR_BOTTOM_Z = -0.27  # 9 cm ride height
FRONT_AXLE_X, REAR_AXLE_X = -1.35, 1.35
NOSE_X, TAIL_X = -2.22, 2.22
HALF_WIDTH = 0.975
FRONT_TYRE_R, REAR_TYRE_R = 0.33, 0.36
ARCH_CLEARANCE = 0.04
RW_HALF_SPAN = 0.74

TESS_TOL = 0.0015
TESS_ANG = 0.18

MATERIALS = {
    "Livery": Material("Livery", (0.06, 0.20, 0.55, 1.0), 0.30, 0.28),
    "LiveryWhite": Material("LiveryWhite", (0.88, 0.88, 0.86, 1.0), 0.05, 0.30),
    "Accent": Material("Accent", (0.95, 0.45, 0.05, 1.0), 0.10, 0.30),
    "Carbon": Material("Carbon", (0.030, 0.031, 0.034, 1.0), 0.20, 0.30),
    "Metal": Material("Metal", (0.80, 0.80, 0.82, 1.0), 1.0, 0.12),
    "Helmet": Material("Helmet", (0.95, 0.95, 0.95, 1.0), 0.05, 0.22),
    "Visor": Material("Visor", (0.02, 0.02, 0.03, 1.0), 0.6, 0.08),
    "Light": Material("Light", (0.6, 0.0, 0.0, 1.0), 0.0, 0.4, emissive=(1.0, 0.05, 0.03)),
    "Glass": Material("Glass", (0.05, 0.06, 0.07, 1.0), 0.0, 0.05),
    "Headlight": Material("Headlight", (0.9, 0.9, 0.85, 1.0), 0.0, 0.3, emissive=(1.0, 0.96, 0.88)),
}

# Lower body: nose (bumper + bonnet), doors, boot. Squarish sections with a little tumblehome.
HULL = [
    #       x,     width, z_bot,  z_top
    Section(-2.220, 1.500, -0.200, 0.100, n_top=2.6, n_bot=3.0, taper=0.86),
    Section(-2.120, 1.740, -0.240, 0.260, n_top=3.6, n_bot=4.0, taper=0.88),
    Section(-1.750, 1.820, -0.265, 0.380, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(-1.100, 1.840, -0.270, 0.470, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(-0.600, 1.840, -0.270, 0.530, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(0.300, 1.840, -0.270, 0.580, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(1.200, 1.830, -0.270, 0.620, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(1.800, 1.800, -0.255, 0.640, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(2.140, 1.720, -0.215, 0.620, n_top=3.6, n_bot=4.0, taper=0.90),
    Section(2.220, 1.560, -0.160, 0.550, n_top=3.0, n_bot=3.0, taper=0.88),
]
# Greenhouse: windscreen, roof, rear window down to the boot lid. Its lower half is buried in
# the hull; the widest line (z_split) is the belt line.
CABIN = [
    Section(-0.720, 1.580, 0.470, 0.550, n_top=2.6, n_bot=4.0, taper=0.80),
    Section(-0.250, 1.580, 0.260, 0.900, n_top=2.8, n_bot=4.0, taper=0.78),
    Section(0.250, 1.540, 0.160, 1.040, n_top=3.2, n_bot=4.0, taper=0.76),
    Section(0.950, 1.520, 0.210, 1.030, n_top=3.2, n_bot=4.0, taper=0.76),
    Section(1.450, 1.500, 0.460, 0.820, n_top=3.0, n_bot=4.0, taper=0.78),
    Section(1.780, 1.480, 0.620, 0.680, n_top=2.6, n_bot=4.0, taper=0.80),
]
GLASS_X0, GLASS_X1 = -0.70, 1.76
GLASS_Z0, GLASS_Z1 = 0.635, 0.985


def flare(axle_x: float, top: float) -> list[Section]:
    """Box-flared wheel arch: a bulge round one wheel, its inner half buried in the hull."""
    return [
        Section(axle_x - 0.62, 0.180, -0.255, 0.150, y_center=0.830, n_top=3.0, n_bot=4.0, taper=0.80),
        Section(axle_x - 0.45, 0.300, -0.262, top - 0.04, y_center=0.825, n_top=3.6, n_bot=4.0, taper=0.80),
        Section(axle_x, 0.300, -0.262, top, y_center=0.825, n_top=3.6, n_bot=4.0, taper=0.80),
        Section(axle_x + 0.45, 0.300, -0.262, top - 0.04, y_center=0.825, n_top=3.6, n_bot=4.0, taper=0.80),
        Section(axle_x + 0.62, 0.180, -0.255, 0.150, y_center=0.830, n_top=3.0, n_bot=4.0, taper=0.80),
    ]


def arch_cutter(axle_x: float, tyre_r: float, y0: float) -> Solid:
    return Solid.make_cylinder(tyre_r + ARCH_CLEARANCE, HALF_WIDTH + 0.2 - y0,
                               Plane(origin=(axle_x, y0, 0.0), z_dir=(0, 1, 0)))


def make_bodywork() -> list[PartSpec]:
    body = loft(HULL)
    cabin = loft(CABIN)   # not fused: the boolean with the hull fails; its lower half is buried
    for axle_x, top in ((FRONT_AXLE_X, 0.48), (REAR_AXLE_X, 0.50)):
        for side in both_sides(loft(flare(axle_x, top))):
            body = body + side
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        for c in both_sides(arch_cutter(axle_x, r, 0.55)):
            body = body - c
    out: list[PartSpec] = []

    # Glazing: windscreen, side windows and rear window in one band round the greenhouse.
    cabin, glass = split(cabin, box(0.5 * (GLASS_X0 + GLASS_X1), 0, 0.5 * (GLASS_Z0 + GLASS_Z1),
                                  GLASS_X1 - GLASS_X0, 1.70, GLASS_Z1 - GLASS_Z0))
    # Black window frames: the belt line, the B pillar, the A pillars' feet and the C pillars.
    frame = mirrored_box(0.5, 0.74, GLASS_Z0 + 0.012, 2.6, 0.12, 0.026)
    frame = frame + mirrored_box(0.32, 0.74, 0.81, 0.09, 0.14, 0.40)
    frame = frame + mirrored_box(1.12, 0.73, 0.81, 0.16, 0.14, 0.40)
    glass, frames = split(glass, frame)
    out += [PartSpec("glazing", glass, "Glass"), PartSpec("window_frames", frames, "Carbon")]

    # Front: black grille and lower intake in the bumper, headlights at its corners.
    body, grille = split(body, box(-2.20, 0, 0.060, 0.20, 0.90, 0.090))
    body, intake = split(body, box(-2.20, 0, -0.130, 0.24, 1.30, 0.110))
    out += [PartSpec("grille", grille, "Carbon"), PartSpec("intake", intake, "Carbon")]
    body, lamps = split(body, mirrored_box(-2.12, 0.66, 0.150, 0.26, 0.34, 0.075))
    out.append(PartSpec("headlights", lamps, "Headlight"))
    # Bonnet vents over the front wheels.
    body, vents = split(body, mirrored_box(-1.45, 0.50, 0.46, 0.40, 0.22, 0.12))
    out.append(PartSpec("bonnet_vents", vents, "Carbon"))

    # Tail: light clusters at the corners, a black diffuser panel below the bumper.
    body, tail = split(body, mirrored_box(2.20, 0.66, 0.53, 0.14, 0.38, 0.080))
    out.append(PartSpec("tail_lights", tail, "Light"))
    body, rear_panel = split(body, box(2.20, 0, -0.16, 0.16, 2.2, 0.14))
    out.append(PartSpec("rear_panel", rear_panel, "Carbon"))

    # Black sills (side skirts) from arch to arch and the lower edge of the flares.
    body, sills = split(body, mirrored_box(0.0, 0.92, -0.225, 4.6, 0.30, 0.09))
    out.append(PartSpec("sills", sills, "Carbon"))
    # Livery: a white door panel (race number board) and an orange stripe along the flanks.
    body, panel = split(body, mirrored_box(0.25, 1.00, 0.22, 0.95, 0.30, 0.34))
    body, stripe = split(body, mirrored_box(0.0, 1.00, -0.075, 4.8, 0.40, 0.07))
    cabin, roof_st = split(cabin, box(0.55, 0, 1.06, 1.10, 0.36, 0.16))
    out.append(PartSpec("cabin", cabin, "Livery"))
    out += [PartSpec("door_panel", panel, "LiveryWhite"), PartSpec("flank_stripe", stripe, "Accent"),
            PartSpec("roof_stripe", roof_st, "Accent")]

    # Wheel-arch liners: the dark inner surface of each arch.
    liners = None
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        big = Solid.make_cylinder(r + ARCH_CLEARANCE + 0.035, HALF_WIDTH + 0.2 - 0.50,
                                  Plane(origin=(axle_x, 0.50, 0.0), z_dir=(0, 1, 0)))
        ring = big - arch_cutter(axle_x, r, 0.55)
        ring = ring + mirror(ring, about=Plane.XZ)
        liners = ring if liners is None else liners + ring
    body, liner = split(body, liners)
    out.append(PartSpec("arch_liners", liner, "Carbon"))

    # Shut lines: doors, bonnet and boot lid.
    g = 0.006
    grooves = mirrored_box(-0.62, 0.95, 0.15, g, 0.3, 0.75)
    grooves = grooves + mirrored_box(0.36, 0.95, 0.15, g, 0.3, 0.75)
    grooves = grooves + mirrored_box(1.06, 0.95, 0.15, g, 0.3, 0.75)
    grooves = grooves + box(-0.80, 0, 0.53, g, 1.5, 0.2)
    grooves = grooves + box(1.85, 0, 0.64, g, 1.5, 0.2)
    body, gr = split(body, grooves)
    out.append(PartSpec("panel_lines", gr, "Carbon"))

    out.insert(0, PartSpec("body", body, "Livery"))
    return out


def make_mirrors() -> list[PartSpec]:
    housing = loft([
        Section(-0.660, 0.140, 0.640, 0.720, y_center=0.890, n_top=2.6, n_bot=2.6, taper=0.85),
        Section(-0.560, 0.180, 0.630, 0.740, y_center=0.900, n_top=3.0, n_bot=3.0, taper=0.90),
        Section(-0.520, 0.180, 0.630, 0.740, y_center=0.900, n_top=3.0, n_bot=3.0, taper=0.90),
    ])
    housing, glass = split(housing, box(-0.515, 0.900, 0.685, 0.03, 0.16, 0.09))
    stalk = box(-0.58, 0.80, 0.635, 0.08, 0.10, 0.03)
    out = []
    for i, s in enumerate(both_sides(housing)):
        out.append(PartSpec(f"mirror{i}", s, "Carbon"))
    for i, s in enumerate(both_sides(glass)):
        out.append(PartSpec(f"mirror_glass{i}", s, "Metal"))
    for i, s in enumerate(both_sides(stalk)):
        out.append(PartSpec(f"mirror_stalk{i}", s, "Carbon", False))
    return out


def make_rear_wing() -> list[PartSpec]:
    """Single-element wing on two pylons on the boot lid, small end plates."""
    out: list[PartSpec] = []
    main = wing_element(1.880, 0.915, 0.280, 8.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.07, thickness=0.11)
    out.append(PartSpec("rw_main", main, "Carbon", surface_control=False))
    gurney = box(2.160, 0, 0.960, 0.006, 2 * RW_HALF_SPAN, 0.030)
    out.append(PartSpec("rw_gurney", gurney, "Accent", False))
    endplate = xz_plate([(1.84, 0.82), (2.20, 0.82), (2.20, 1.01), (1.92, 1.01)], RW_HALF_SPAN, 0.012)
    endplate = try_fillet(endplate, endplate.edges().filter_by(Axis.Y), 0.03)
    for j, s in enumerate(both_sides(endplate)):
        out.append(PartSpec(f"rw_endplate{j}", s, "Carbon", surface_control=False))
    pylon = xz_plate([(1.86, 0.60), (2.02, 0.60), (2.08, 0.92), (1.96, 0.92)], 0.42, 0.014)
    for j, s in enumerate(both_sides(pylon)):
        out.append(PartSpec(f"rw_pylon{j}", s, "Carbon", False))
    return out


def make_floor_splitter() -> list[PartSpec]:
    out: list[PartSpec] = []
    half = [(-2.00, 0.0), (-2.00, 0.66), (2.05, 0.66), (2.05, 0.0)]
    outline = half + [(x, -y) for x, y in reversed(half[1:-1])]
    out.append(PartSpec("floor", xy_plate(outline, FLOOR_BOTTOM_Z, 0.02), "Carbon", False))
    split_half = [(-2.30, 0.0), (-2.30, 0.78), (-2.22, 0.88), (-1.95, 0.90), (-1.95, 0.0)]
    split_outline = split_half + [(x, -y) for x, y in reversed(split_half[1:-1])]
    splitter = xy_plate(split_outline, FLOOR_BOTTOM_Z, 0.018)
    splitter = try_fillet(splitter, splitter.edges().filter_by(Axis.Z), 0.03)
    out.append(PartSpec("splitter", splitter, "Carbon", False))
    # Canards on the bumper corners.
    for j, s in enumerate(both_sides(xy_plate([(-2.20, 0.70), (-2.06, 0.70), (-2.00, 0.92), (-2.14, 0.92)],
                                                -0.060, 0.010))):
        out.append(PartSpec(f"canard{j}", s, "Carbon", False))
    ramp = xz_plate([(1.95, FLOOR_BOTTOM_Z), (2.26, -0.180), (2.26, -0.165), (1.95, FLOOR_BOTTOM_Z + 0.018)],
                    -0.62, 1.24)
    out.append(PartSpec("diffuser", ramp, "Carbon", False))
    exhaust = Solid.make_cylinder(0.045, 0.16, Plane(origin=(2.08, -0.55, -0.20), z_dir=(1, 0, 0)))
    out.append(PartSpec("exhaust", exhaust, "Metal", False))
    rain = box(TAIL_X + 0.03, 0, -0.130, 0.02, 0.12, 0.05)
    out.append(PartSpec("rain_light", rain, "Light", False))
    return out


def make_driver() -> list[PartSpec]:
    """Helmet + visor behind the side window (driver seated left of the centreline)."""
    c = (0.30, -0.36, 0.780)
    shell = scale(Sphere(0.125), by=(1.12, 1.0, 1.04)).moved(Location(c))
    visor_band = box(c[0] - 0.10, c[1], c[2] + 0.005, 0.20, 0.30, 0.050)
    visor = scale(Sphere(0.1275), by=(1.12, 1.0, 1.04)).moved(Location(c)) & visor_band
    visor = visor - box(c[0] + 0.10, c[1], c[2], 0.30, 0.30, 0.30)
    return [PartSpec("helmet", shell, "Helmet"), PartSpec("visor", visor, "Visor")]


def build_parts() -> list[PartSpec]:
    parts: list[PartSpec] = []
    for b in (make_bodywork, make_mirrors, make_rear_wing, make_floor_splitter, make_driver):
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
    write_glb(out_path, list(groups.values()), root_name="TouringBody")
    print(f"total {total} triangles -> {out_path}")


if __name__ == "__main__":
    main()
