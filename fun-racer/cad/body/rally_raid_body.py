#!/usr/bin/env python3
"""Parametric desert-raid prototype (a generic T1-style four-wheel-drive pickup: long bonnet,
two-seat cab with a roof scoop and light bar, huge wheel arches, an open bed with two spare
wheels standing in it; no make or brand), modelled with build123d like ``touring_body.py``.
Materials: the body scene scenes/car/rally_raid_body_visual.tscn.

Regenerate the Godot assets with one command (from the repo root):

    .venv/bin/python cad/body/rally_raid_body.py   # -> assets/car/rally_raid/body.glb, wheel.glb

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.
``--out DIR`` writes the GLBs somewhere else.

Frame: same as ``f1_body.py``: CAD x = backward, y = right, z = up (Godot car-local:
forward = -Z, up = +Y, right = +X). The origin is where every car's is: 0.36 m above the
ground (z = -0.36), the height the physics holds the body at (Car.ride_ground_y).

Dimensions: length 4.75 m, width 2.26 m over the arch flares, roof 1.90 m above the ground,
33 cm ground clearance, wheelbase 2.95 m: front axle x = -1.475, rear x = +1.475.

Wheels: its own (wheel.glb, kit_wheels.py): R 0.47 m (37 in) all-terrain tyres 0.32 m wide on
17 in beadlock rims, centres at (+-0.96, +0.11, -+1.475) Godot car-local, i.e. 0.47 m above
the ground. CarKit draws them there (``"wheels"`` of its kit); the arches are cut for them
with room for the long suspension travel.

Material order: the F1 body's eight first (the body scene overrides nodes by index,
``body_motion.gd`` moves Helmet + Visor, ``bot_manager.gd`` recolours Livery / LiveryWhite /
Accent / Helmet), then Glass and Headlight as on the endurance body, then the spare wheels'
Rubber, Rim, RimAccent and Hub.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from build123d import Axis, Location, Plane, Solid, Sphere, mirror, scale

sys.path.insert(0, str(Path(__file__).resolve().parent))
from endurance_body import (  # noqa: E402
    PartSpec, both_sides, box, loft, mirrored_box, split, try_fillet, xz_plate,
)
from glb_writer import Material, MeshGroup, write_glb  # noqa: E402
from kit_wheels import MATERIALS as WHEEL_MATERIALS, WheelSpec, spare, write_wheel  # noqa: E402
from profiles import Section  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "assets" / "car" / "rally_raid"

GROUND_Z = -0.36
FLOOR_Z = -0.03                 # skid plate: 33 cm above the ground
FRONT_AXLE_X, REAR_AXLE_X = -1.475, 1.475
WHEEL_Y = 0.96
WHEEL = WheelSpec(radius=0.47, width=0.32, rim_radius=0.216, shoulder=0.05,
                  lugs=26, lug_depth=0.022, holes=6, beadlock=True)
AXLE_Z = GROUND_Z + WHEEL.radius   # +0.11
HALF_WIDTH = 1.0                # body sides; the flares stick out to 1.13
ARCH_R = WHEEL.radius + 0.07    # arch radius round the wheel at rest ...
ARCH_RISE = 0.10                # ... and again this much higher: room for the bump travel
BED_X0, BED_X1, BED_HALF, BED_FLOOR = 0.86, 2.14, 0.90, 0.42

TESS_TOL = 0.0018
TESS_ANG = 0.2

MATERIALS = {
    "Livery": Material("Livery", (0.05, 0.22, 0.30, 1.0), 0.25, 0.32),
    "LiveryWhite": Material("LiveryWhite", (0.86, 0.80, 0.66, 1.0), 0.05, 0.40),
    "Accent": Material("Accent", (0.98, 0.45, 0.05, 1.0), 0.10, 0.32),
    "Carbon": Material("Carbon", (0.030, 0.031, 0.034, 1.0), 0.20, 0.45),
    "Metal": Material("Metal", (0.70, 0.70, 0.72, 1.0), 1.0, 0.25),
    "Helmet": Material("Helmet", (0.95, 0.95, 0.95, 1.0), 0.05, 0.22),
    "Visor": Material("Visor", (0.02, 0.02, 0.03, 1.0), 0.6, 0.08),
    "Light": Material("Light", (0.6, 0.0, 0.0, 1.0), 0.0, 0.4, emissive=(1.0, 0.05, 0.03)),
    "Glass": Material("Glass", (0.05, 0.06, 0.07, 1.0), 0.0, 0.05),
    "Headlight": Material("Headlight", (0.9, 0.9, 0.85, 1.0), 0.0, 0.3, emissive=(1.0, 0.96, 0.88)),
    **WHEEL_MATERIALS,
}

# Lower body: high nose (approach angle), bonnet, doors, bed sides, high tail (departure angle).
HULL = [
    #       x,     width, z_bot,  z_top
    Section(-2.400, 1.560, 0.120, 0.420, n_top=2.6, n_bot=3.0, taper=0.86),
    Section(-2.320, 1.860, 0.040, 0.560, n_top=3.4, n_bot=4.0, taper=0.90),
    Section(-2.080, 1.980, FLOOR_Z, 0.640, n_top=4.0, n_bot=5.0, taper=0.92),
    Section(-1.200, 2.000, FLOOR_Z, 0.710, n_top=4.0, n_bot=5.0, taper=0.92),
    Section(-0.550, 2.000, FLOOR_Z, 0.760, n_top=4.0, n_bot=5.0, taper=0.92),
    Section(0.500, 2.000, FLOOR_Z, 0.780, n_top=4.4, n_bot=5.0, taper=0.93),
    Section(1.400, 2.000, FLOOR_Z, 0.780, n_top=4.4, n_bot=5.0, taper=0.93),
    Section(2.050, 1.980, 0.020, 0.770, n_top=4.0, n_bot=4.0, taper=0.93),
    Section(2.320, 1.840, 0.140, 0.720, n_top=3.4, n_bot=3.0, taper=0.92),
]
# Cab: steep windscreen, flat roof, upright back wall. Its lower half is buried in the hull.
CABIN = [
    Section(-0.640, 1.820, 0.700, 0.780, n_top=2.6, n_bot=4.0, taper=0.82),
    Section(-0.300, 1.800, 0.560, 1.240, n_top=3.0, n_bot=4.0, taper=0.80),
    Section(0.050, 1.760, 0.560, 1.520, n_top=3.6, n_bot=4.0, taper=0.80),
    Section(0.600, 1.760, 0.560, 1.540, n_top=3.6, n_bot=4.0, taper=0.80),
    Section(0.800, 1.740, 0.560, 1.500, n_top=3.6, n_bot=4.0, taper=0.80),
    Section(0.840, 1.660, 0.640, 1.400, n_top=3.0, n_bot=4.0, taper=0.82),
]
GLASS_X0, GLASS_X1 = -0.58, 0.80
GLASS_Z0, GLASS_Z1 = 0.880, 1.430


def flare(axle_x: float, top: float) -> list[Section]:
    """Box flare round one wheel; its inner half is buried in the hull."""
    return [
        Section(axle_x - 0.80, 0.160, 0.020, 0.300, y_center=0.990, n_top=3.0, n_bot=4.0, taper=0.80),
        Section(axle_x - 0.60, 0.270, -0.010, top - 0.05, y_center=1.000, n_top=3.6, n_bot=4.0, taper=0.80),
        Section(axle_x, 0.270, -0.010, top, y_center=1.000, n_top=3.6, n_bot=4.0, taper=0.80),
        Section(axle_x + 0.60, 0.270, -0.010, top - 0.05, y_center=1.000, n_top=3.6, n_bot=4.0, taper=0.80),
        Section(axle_x + 0.80, 0.160, 0.020, 0.300, y_center=0.990, n_top=3.0, n_bot=4.0, taper=0.80),
    ]


def arch_cutter(axle_x: float, y0: float, grow: float = 0.0) -> Solid:
    """A stadium-shaped arch: the wheel's circle swept ARCH_RISE upward (bump travel)."""
    r = ARCH_R + grow
    length = HALF_WIDTH + 0.4 - y0
    lo = Solid.make_cylinder(r, length, Plane(origin=(axle_x, y0, AXLE_Z), z_dir=(0, 1, 0)))
    hi = Solid.make_cylinder(r, length, Plane(origin=(axle_x, y0, AXLE_Z + ARCH_RISE), z_dir=(0, 1, 0)))
    mid = box(axle_x, y0 + 0.5 * length, AXLE_Z + 0.5 * ARCH_RISE, 2 * r, length, ARCH_RISE)
    return lo + hi + mid


def make_bodywork() -> list[PartSpec]:
    body = loft(HULL)
    cabin = loft(CABIN)   # not fused (as on the touring car): its lower half is buried
    # Arches cut in the hull and in each flare before they are fused: cutting the fused body
    # makes OCC fail on the front pair (it returns the cutter instead of the hole).
    for axle_x in (FRONT_AXLE_X, REAR_AXLE_X):
        for c in both_sides(arch_cutter(axle_x, 0.50)):
            body = body - c
    for axle_x, top in ((FRONT_AXLE_X, 0.80), (REAR_AXLE_X, 0.84)):
        for side, c in zip(both_sides(loft(flare(axle_x, top))), both_sides(arch_cutter(axle_x, 0.50))):
            body = body + (side - c)
    # The open bed behind the cab.
    body = body - box(0.5 * (BED_X0 + BED_X1), 0, BED_FLOOR + 0.5, BED_X1 - BED_X0, 2 * BED_HALF, 1.0)
    out: list[PartSpec] = []

    # Glazing round the cab, black frames: belt line, A pillars' feet, B pillar.
    cabin, glass = split(cabin, box(0.5 * (GLASS_X0 + GLASS_X1), 0, 0.5 * (GLASS_Z0 + GLASS_Z1),
                                  GLASS_X1 - GLASS_X0, 1.90, GLASS_Z1 - GLASS_Z0))
    frame = mirrored_box(0.1, 0.85, GLASS_Z0 + 0.015, 1.6, 0.14, 0.03)
    frame = frame + mirrored_box(0.28, 0.84, 1.16, 0.10, 0.16, 0.60)
    glass, frames = split(glass, frame)
    out += [PartSpec("glazing", glass, "Glass"), PartSpec("window_frames", frames, "Carbon")]

    # Front: black grille, headlights, a big skid plate under the nose.
    body, grille = split(body, box(-2.36, 0, 0.36, 0.20, 1.00, 0.16))
    out.append(PartSpec("grille", grille, "Carbon"))
    body, lamps = split(body, mirrored_box(-2.30, 0.66, 0.46, 0.22, 0.34, 0.10))
    out.append(PartSpec("headlights", lamps, "Headlight"))
    body, bumper = split(body, box(-2.30, 0, 0.12, 0.40, 2.2, 0.16))
    out.append(PartSpec("front_bumper", bumper, "Carbon"))
    # Bonnet vents (the radiator air leaves upward) and the bonnet straps.
    body, vents = split(body, mirrored_box(-1.55, 0.42, 0.70, 0.55, 0.36, 0.12))
    out.append(PartSpec("bonnet_vents", vents, "Carbon"))

    # Tail: lights high on the corners, a black rear bumper.
    body, tail = split(body, mirrored_box(2.30, 0.80, 0.58, 0.12, 0.26, 0.12))
    out.append(PartSpec("tail_lights", tail, "Light"))
    body, rear_bumper = split(body, box(2.28, 0, 0.20, 0.30, 2.2, 0.18))
    out.append(PartSpec("rear_bumper", rear_bumper, "Carbon"))

    # Rock sliders between the arches, the lower edge of the flares in black.
    body, sliders = split(body, mirrored_box(0.0, 0.96, 0.04, 5.0, 0.32, 0.14))
    out.append(PartSpec("sliders", sliders, "Carbon"))
    # Livery: sand door panels (race number boards), an orange band along the flanks, a sand
    # roof with an orange stripe.
    body, panel = split(body, mirrored_box(0.05, 1.10, 0.44, 0.95, 0.30, 0.30))
    body, stripe = split(body, mirrored_box(0.0, 1.10, 0.22, 5.0, 0.30, 0.08))
    cabin, roof = split(cabin, box(0.30, 0, 1.60, 1.20, 1.90, 0.14))
    roof, roof_stripe = split(roof, box(0.30, 0, 1.60, 1.20, 0.30, 0.14))
    out.append(PartSpec("cabin", cabin, "Livery"))
    out += [PartSpec("door_panel", panel, "LiveryWhite"), PartSpec("flank_stripe", stripe, "Accent"),
            PartSpec("roof", roof, "LiveryWhite"), PartSpec("roof_stripe", roof_stripe, "Accent")]

    # Arch liners: the dark inside of each arch.
    liners = None
    for axle_x in (FRONT_AXLE_X, REAR_AXLE_X):
        ring = arch_cutter(axle_x, 0.45, 0.04) - arch_cutter(axle_x, 0.40)
        ring = ring + mirror(ring, about=Plane.XZ)
        liners = ring if liners is None else liners + ring
    body, liner = split(body, liners)
    out.append(PartSpec("arch_liners", liner, "Carbon"))

    # Shut lines: doors and bonnet.
    g = 0.006
    grooves = mirrored_box(-0.55, 1.0, 0.36, g, 0.4, 0.70)
    grooves = grooves + mirrored_box(0.78, 1.0, 0.36, g, 0.4, 0.70)
    grooves = grooves + box(-0.95, 0, 0.74, g, 1.7, 0.2)
    body, gr = split(body, grooves)
    out.append(PartSpec("panel_lines", gr, "Carbon"))

    out.insert(0, PartSpec("body", body, "Livery"))
    return out


def make_roof_kit() -> list[PartSpec]:
    """Roof scoop (engine air), light bar over the windscreen, mirrors, side exhaust."""
    out: list[PartSpec] = []
    scoop = loft([
        Section(-0.100, 0.380, 1.500, 1.560, n_top=3.0, n_bot=4.0, taper=0.85),
        Section(0.050, 0.420, 1.500, 1.720, n_top=3.0, n_bot=4.0, taper=0.85),
        Section(0.600, 0.420, 1.500, 1.700, n_top=3.0, n_bot=4.0, taper=0.85),
        Section(0.800, 0.360, 1.480, 1.600, n_top=3.0, n_bot=4.0, taper=0.85),
    ])
    scoop, mouth = split(scoop, box(0.03, 0, 1.635, 0.08, 0.34, 0.13))
    out += [PartSpec("scoop", scoop, "Livery"), PartSpec("scoop_mouth", mouth, "Carbon")]
    bar = box(-0.12, 0, 1.585, 0.10, 1.40, 0.10)
    out.append(PartSpec("light_bar", bar, "Carbon"))
    for i, y in enumerate((-0.54, -0.18, 0.18, 0.54)):
        lamp = Solid.make_cylinder(0.075, 0.03, Plane(origin=(-0.17, y, 1.585), z_dir=(-1, 0, 0)))
        out.append(PartSpec(f"spot{i}", lamp, "Headlight"))
    housing = box(-0.48, 1.06, 0.95, 0.10, 0.16, 0.12)
    for i, s in enumerate(both_sides(housing)):
        out.append(PartSpec(f"mirror{i}", s, "Carbon"))
    for i, s in enumerate(both_sides(box(-0.535, 1.06, 0.95, 0.012, 0.13, 0.09))):
        out.append(PartSpec(f"mirror_glass{i}", s, "Metal"))
    for i, s in enumerate(both_sides(box(-0.48, 0.95, 0.92, 0.06, 0.12, 0.03))):
        out.append(PartSpec(f"mirror_stalk{i}", s, "Carbon", False))
    pipe = Solid.make_cylinder(0.06, 0.24, Plane(origin=(0.62, 0.92, 0.10), z_dir=(0, 1, 0)))
    out.append(PartSpec("exhaust", pipe, "Metal"))
    return out


def make_bed() -> list[PartSpec]:
    """Two spare wheels standing in the bed, facing backward, with a strap bar over them."""
    out: list[PartSpec] = []
    cx = 0.5 * (BED_X0 + BED_X1)
    for y in (-0.47, 0.47):
        out += spare(WHEEL, (cx, y, BED_FLOOR + WHEEL.radius), "x")
    out.append(PartSpec("bed_floor", box(cx, 0, BED_FLOOR - 0.01, BED_X1 - BED_X0, 2 * BED_HALF, 0.02), "Carbon", False))
    hoop = box(BED_X0 + 0.08, 0, 1.30, 0.07, 1.84, 0.07)
    for y in (-0.88, 0.88):
        hoop = hoop + box(BED_X0 + 0.08, y, 0.95, 0.07, 0.07, 0.75)
    out.append(PartSpec("hoop", hoop, "Carbon"))
    strap = box(cx, 0, BED_FLOOR + 2 * WHEEL.radius + 0.01, 0.07, 1.80, 0.02)
    out.append(PartSpec("strap", strap, "Accent", False))
    return out


def make_underbody() -> list[PartSpec]:
    out = [PartSpec("skid", box(-0.40, 0, FLOOR_Z + 0.01, 3.80, 1.50, 0.02), "Carbon", False)]
    # Long-travel arms from the frame to each hub (they read as the suspension under the arches).
    for axle_x in (FRONT_AXLE_X, REAR_AXLE_X):
        for z in (AXLE_Z - 0.08, AXLE_Z + 0.10):
            arm = xz_plate([(axle_x - 0.05, z - 0.02), (axle_x + 0.05, z - 0.02),
                            (axle_x + 0.05, z + 0.02), (axle_x - 0.05, z + 0.02)], 0.30, WHEEL_Y - 0.30 - 0.12)
            for i, s in enumerate(both_sides(arm)):
                out.append(PartSpec(f"arm{axle_x}_{z}_{i}", s, "Metal", False))
    return out


def make_crew() -> list[PartSpec]:
    """Driver (left) and co-driver helmets behind the side windows."""
    out: list[PartSpec] = []
    for name, y in (("driver", -0.40), ("codriver", 0.40)):
        c = (0.30, y, 1.140)
        shell = scale(Sphere(0.125), by=(1.12, 1.0, 1.04)).moved(Location(c))
        visor_band = box(c[0] - 0.10, c[1], c[2] + 0.005, 0.20, 0.30, 0.050)
        visor = scale(Sphere(0.1275), by=(1.12, 1.0, 1.04)).moved(Location(c)) & visor_band
        visor = visor - box(c[0] + 0.10, c[1], c[2], 0.30, 0.30, 0.30)
        out += [PartSpec(f"{name}_helmet", shell, "Helmet"), PartSpec(f"{name}_visor", visor, "Visor")]
    return out


def build_parts() -> list[PartSpec]:
    parts: list[PartSpec] = []
    for b in (make_bodywork, make_roof_kit, make_bed, make_underbody, make_crew):
        print(f"building {b.__name__} ...")
        parts.extend(b())
    return parts


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=OUT_DIR)
    args = ap.parse_args()
    out_dir: Path = args.out.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    parts = build_parts()
    groups = {name: MeshGroup(mat) for name, mat in MATERIALS.items()}
    total = 0
    for p in parts:
        if p.shape is None:
            print(f"  {p.name:18s} EMPTY, skipped")
            continue
        n = groups[p.material].add_shape(p.shape, TESS_TOL, TESS_ANG, p.surface_control)
        total += n
    write_glb(out_dir / "body.glb", list(groups.values()), root_name="RallyRaidBody")
    print(f"total {total} triangles -> {out_dir / 'body.glb'}")
    write_wheel(out_dir / "wheel.glb", WHEEL, "RallyRaidWheel")


if __name__ == "__main__":
    main()
