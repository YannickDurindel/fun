#!/usr/bin/env python3
"""Parametric prototype race bike (a generic Grand Prix motorcycle: full fairing with winglets,
tank, tail unit, carbon swingarm, high exhaust, telescopic fork; no make or brand) and its
rider in leathers, modelled with build123d like ``kart_body.py``.
Materials: the body scene scenes/car/moto_body_visual.tscn.

Regenerate the Godot assets with one command (from the repo root):

    .venv/bin/python cad/body/moto_body.py   # -> assets/car/moto/*.glb

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.
``--out DIR`` writes the GLBs somewhere else.

Frame: same as ``f1_body.py``: CAD x = backward, y = right, z = up (Godot car-local:
forward = -Z, up = +Y, right = +X). The origin is where every car's is: 0.36 m above the
ground (z = -0.36), the height the physics holds the body at (Car.ride_ground_y).

Dimensions: wheelbase 1.45 m (front axle x = -0.725, rear x = +0.725), 2.05 m long, 0.62 m
wide over the winglets, seat 0.83 m above the ground, 12 cm ground clearance, 24 deg rake.

The bike is several GLBs, because scripts/car/bike_visual.gd moves the parts separately:
  body.glb         frame, fairing, tank, seat, tail, swingarm, exhaust (fixed to the bike)
  fork.glb         fork legs, clamps, clip-on bars, front mudguard, discs (steer)
  wheel_front.glb  120/70-17 front slick, wheel_rear.glb 200/65-17 rear slick (kit_wheels.py:
                   centre at the origin, axle along Godot X)
  rider_lower.glb  hips, legs and boots (hang off with the rider)
  rider_upper.glb  torso with the aero hump, arms, helmet (tucks about the hips)
The body's mesh nodes Livery / LiveryWhite / Accent and the rider's Livery / Helmet are what
``bot_manager.gd`` recolours.
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

from build123d import Axis, Location, Plane, Solid, Sphere, Vector, scale

sys.path.insert(0, str(Path(__file__).resolve().parent))
from endurance_body import PartSpec, both_sides, box, loft, split, try_fillet, xz_plate  # noqa: E402
from glb_writer import Material, MeshGroup, write_glb  # noqa: E402
from kit_wheels import WheelSpec, write_wheel  # noqa: E402
from profiles import Section  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "assets" / "car" / "moto"

GROUND_Z = -0.36
FRONT_AXLE_X, REAR_AXLE_X = -0.725, 0.725
FRONT = WheelSpec(radius=0.300, width=0.125, rim_radius=0.216, shoulder=0.055, holes=5)
REAR = WheelSpec(radius=0.330, width=0.200, rim_radius=0.216, shoulder=0.085, holes=5)
FRONT_Z = GROUND_Z + FRONT.radius
REAR_Z = GROUND_Z + REAR.radius
RAKE = math.radians(24.0)
FORK_LEN = 0.62
FORK_DIR = (math.sin(RAKE), 0.0, math.cos(RAKE))      # up and back along the steering axis
FORK_TOP = (FRONT_AXLE_X + FORK_DIR[0] * FORK_LEN, 0.0, FRONT_Z + FORK_DIR[2] * FORK_LEN)
SEAT_Z = GROUND_Z + 0.83
HIP = (0.22, 0.0, SEAT_Z + 0.08)                      # rider's pelvis pivot (tuck)
GRIP = (-0.40, 0.30, FORK_TOP[2] - 0.07)

TESS_TOL = 0.0012
TESS_ANG = 0.2

MATERIALS = {
    "Livery": Material("Livery", (0.08, 0.20, 0.75, 1.0), 0.05, 0.30),
    "LiveryWhite": Material("LiveryWhite", (0.90, 0.90, 0.88, 1.0), 0.05, 0.30),
    "Accent": Material("Accent", (0.98, 0.70, 0.05, 1.0), 0.10, 0.30),
    "Carbon": Material("Carbon", (0.030, 0.031, 0.034, 1.0), 0.15, 0.40),
    "Metal": Material("Metal", (0.72, 0.72, 0.74, 1.0), 1.0, 0.25),
    "Gold": Material("Gold", (0.80, 0.62, 0.22, 1.0), 1.0, 0.25),
    "Glass": Material("Glass", (0.05, 0.06, 0.07, 1.0), 0.0, 0.05),
    "Helmet": Material("Helmet", (0.95, 0.95, 0.95, 1.0), 0.05, 0.22),
    "Visor": Material("Visor", (0.02, 0.02, 0.03, 1.0), 0.6, 0.08),
    "Suit": Material("Suit", (0.07, 0.07, 0.08, 1.0), 0.0, 0.65),
}


def rod(p0: tuple[float, float, float], p1: tuple[float, float, float], r: float) -> Solid:
    a, b = Vector(*p0), Vector(*p1)
    return Solid.make_cylinder(r, (b - a).length, Plane(origin=a, z_dir=b - a))


def ellipsoid(c: tuple[float, float, float], rx: float, ry: float, rz: float, tilt: float = 0.0):
    e = scale(Sphere(1.0), by=(rx, ry, rz))
    if tilt:
        e = e.rotate(Axis.Y, tilt)
    return e.moved(Location(c))


def limb(p0, p1, r0: float, r1: float) -> Solid:
    """A tapered limb with round ends."""
    a, b = Vector(*p0), Vector(*p1)
    cone = Solid.make_cone(r0, r1, (b - a).length, Plane(origin=a, z_dir=b - a))
    return cone + Sphere(r0).moved(Location(p0)) + Sphere(r1).moved(Location(p1))


# ------------------------------------------------------------------ bike
def make_bodywork() -> list[PartSpec]:
    out: list[PartSpec] = []
    # Upper fairing over the front wheel: nose, headlight-less front, screen base.
    upper = loft([
        Section(-0.985, 0.08, 0.200, 0.300, n_top=2.4, n_bot=2.4, taper=0.85),
        Section(-0.930, 0.30, 0.150, 0.420, n_top=2.6, n_bot=3.0, taper=0.70),
        Section(-0.800, 0.44, 0.120, 0.480, n_top=2.8, n_bot=3.2, taper=0.62),
        Section(-0.620, 0.48, 0.120, 0.500, n_top=3.0, n_bot=3.4, taper=0.60),
        Section(-0.450, 0.46, 0.100, 0.470, n_top=3.0, n_bot=3.4, taper=0.62),
    ])
    upper, number = split(upper, box(-0.94, 0, 0.30, 0.16, 0.40, 0.14))
    upper, stripe = split(upper, box(-0.70, 0, 0.12, 0.70, 0.60, 0.06))
    out += [PartSpec("upper_fairing", upper, "Livery"), PartSpec("nose_number", number, "LiveryWhite"),
            PartSpec("upper_stripe", stripe, "Accent")]
    # Lower fairing behind the front wheel down to the belly pan.
    lower = loft([
        Section(-0.410, 0.40, -0.040, 0.420, n_top=2.8, n_bot=3.0, taper=0.80),
        Section(-0.300, 0.46, -0.200, 0.420, n_top=3.0, n_bot=3.4, taper=0.80),
        Section(-0.050, 0.46, -0.240, 0.380, n_top=3.0, n_bot=3.6, taper=0.82),
        Section(0.180, 0.40, -0.220, 0.280, n_top=2.8, n_bot=3.4, taper=0.85),
        Section(0.320, 0.20, -0.120, 0.160, n_top=2.4, n_bot=2.8, taper=0.85),
    ])
    lower, side_panel = split(lower, box(-0.08, 0, 0.08, 0.40, 0.60, 0.20))
    lower, belly = split(lower, box(0.0, 0, -0.22, 0.80, 0.60, 0.06))
    out += [PartSpec("lower_fairing", lower, "Livery"), PartSpec("side_panel", side_panel, "LiveryWhite"),
            PartSpec("belly_pan", belly, "Carbon")]
    # Screen: a thin clear bubble on the upper fairing.
    screen = loft([
        Section(-0.790, 0.30, 0.420, 0.505, n_top=2.2, n_bot=2.2, taper=0.80),
        Section(-0.640, 0.32, 0.470, 0.600, n_top=2.2, n_bot=2.2, taper=0.75),
        Section(-0.500, 0.28, 0.470, 0.640, n_top=2.2, n_bot=2.2, taper=0.75),
    ])
    out.append(PartSpec("screen", screen, "Glass"))
    # Fuel tank and seat.
    tank = loft([
        Section(-0.440, 0.30, 0.300, 0.500, n_top=2.6, n_bot=3.0, taper=0.70),
        Section(-0.250, 0.38, 0.280, 0.540, n_top=2.8, n_bot=3.0, taper=0.68),
        Section(-0.020, 0.36, 0.300, 0.500, n_top=2.8, n_bot=3.0, taper=0.70),
        Section(0.080, 0.28, 0.320, 0.440, n_top=2.6, n_bot=3.0, taper=0.75),
    ])
    out.append(PartSpec("tank", tank, "Livery"))
    seat = loft([
        Section(0.060, 0.24, 0.380, 0.455, n_top=3.0, n_bot=3.0, taper=0.85),
        Section(0.340, 0.24, 0.400, 0.475, n_top=3.0, n_bot=3.0, taper=0.85),
    ])
    out.append(PartSpec("seat", seat, "Carbon"))
    # Tail unit over the rear wheel, with a number panel on each side.
    tail = loft([
        Section(0.300, 0.30, 0.300, 0.420, n_top=2.6, n_bot=3.0, taper=0.80),
        Section(0.420, 0.28, 0.360, 0.560, n_top=2.8, n_bot=3.0, taper=0.78),
        Section(0.640, 0.20, 0.400, 0.590, n_top=2.8, n_bot=3.0, taper=0.76),
        Section(0.800, 0.08, 0.450, 0.560, n_top=2.4, n_bot=2.4, taper=0.85),
    ])
    tail, tail_number = split(tail, box(0.55, 0, 0.48, 0.20, 0.40, 0.10))
    out += [PartSpec("tail", tail, "Livery"), PartSpec("tail_number", tail_number, "LiveryWhite")]
    # Winglets: two stacked aerofoil plates each side of the upper fairing, with an endplate.
    for s in (-1, 1):
        for k, z in enumerate((0.300, 0.360)):
            plate = box(-0.660 + 0.02 * k, s * 0.29, z, 0.16, 0.12, 0.016)
            plate = plate.rotate(Axis.Y, -6.0).moved(Location((0.0, 0.0, 0.0)))
            out.append(PartSpec(f"winglet{s}_{k}", plate, "Carbon", False))
        out.append(PartSpec(f"wing_endplate{s}", box(-0.655, s * 0.348, 0.330, 0.17, 0.010, 0.11), "Accent", False))
    return out


def make_mechanics() -> list[PartSpec]:
    out: list[PartSpec] = []
    # Twin-spar aluminium frame from the steering head to the swingarm pivot, seen in the gap
    # between the tank and the fairing.
    for s in (-1, 1):
        out.append(PartSpec(f"spar{s}", rod((FORK_TOP[0] + 0.03, s * 0.10, FORK_TOP[2] - 0.08),
                                            (0.18, s * 0.17, 0.10), 0.035), "Metal", False))
        out.append(PartSpec(f"pivot_plate{s}", box(0.20, s * 0.17, 0.02, 0.10, 0.03, 0.24), "Metal", False))
    # Carbon swingarm: two tapered arms from the pivot to the rear axle, a cross brace.
    for s in (-1, 1):
        arm = limb((0.20, s * 0.145, 0.02), (REAR_AXLE_X, s * 0.135, REAR_Z), 0.045, 0.028)
        out.append(PartSpec(f"swingarm{s}", arm, "Carbon"))
    out.append(PartSpec("swingarm_brace", rod((0.38, -0.15, 0.00), (0.38, 0.15, 0.00), 0.03), "Carbon", False))
    out.append(PartSpec("rear_axle", rod((REAR_AXLE_X, -0.15, REAR_Z), (REAR_AXLE_X, 0.15, REAR_Z), 0.016), "Metal", False))
    out.append(PartSpec("rear_disc", rod((REAR_AXLE_X, -0.122, REAR_Z), (REAR_AXLE_X, -0.116, REAR_Z), 0.11), "Metal", False))
    out.append(PartSpec("sprocket", rod((REAR_AXLE_X, 0.118, REAR_Z), (REAR_AXLE_X, 0.124, REAR_Z), 0.12), "Carbon", False))
    out.append(PartSpec("chain", box(0.46, 0.121, REAR_Z + 0.01, 0.55, 0.012, 0.03).rotate(Axis.Y, 0.0), "Metal", False))
    # Engine block under the tank, inside the fairing (visible through the cut-outs).
    out.append(PartSpec("engine", box(-0.10, 0.0, -0.06, 0.40, 0.30, 0.26), "Carbon", False))
    # Exhaust: from under the engine, along the right side, up under the tail.
    pipe = rod((-0.05, 0.16, -0.22), (0.35, 0.18, -0.10), 0.035) + rod((0.35, 0.18, -0.10), (0.60, 0.16, 0.20), 0.040)
    out.append(PartSpec("exhaust", pipe, "Metal", False))
    out.append(PartSpec("silencer", rod((0.56, 0.16, 0.14), (0.86, 0.14, 0.33), 0.055), "Carbon", False))
    # Rear sets: footpegs and their hangers.
    for s in (-1, 1):
        out.append(PartSpec(f"peg{s}", rod((0.24, s * 0.16, -0.02), (0.24, s * 0.24, -0.02), 0.012), "Metal", False))
        out.append(PartSpec(f"hanger{s}", box(0.26, s * 0.17, 0.03, 0.10, 0.012, 0.12), "Metal", False))
    # Rear shock and the subframe under the seat.
    out.append(PartSpec("shock", rod((0.30, 0.0, 0.00), (0.22, 0.0, 0.30), 0.03), "Gold", False))
    return out


def make_fork() -> list[PartSpec]:
    """Everything that steers: fork legs (gold stanchions), clamps, clip-ons, mudguard, discs."""
    out: list[PartSpec] = []
    dx, dz = FORK_DIR[0], FORK_DIR[2]
    for s in (-1, 1):
        y = s * 0.095
        bottom = (FRONT_AXLE_X - 0.02 * dx, y, FRONT_Z - 0.02 * dz)
        mid = (FRONT_AXLE_X + 0.30 * dx, y, FRONT_Z + 0.30 * dz)
        top = (FORK_TOP[0], y, FORK_TOP[2])
        out.append(PartSpec(f"slider{s}", rod(bottom, mid, 0.032), "Carbon", False))
        out.append(PartSpec(f"stanchion{s}", rod(mid, top, 0.026), "Gold", False))
        # Clip-on bar below the top clamp, out to the grip.
        out.append(PartSpec(f"clipon{s}", rod((FORK_TOP[0] + 0.01, y, GRIP[2] + 0.02), (GRIP[0], s * GRIP[1], GRIP[2]), 0.012), "Metal", False))
        out.append(PartSpec(f"grip{s}", rod((GRIP[0], s * (GRIP[1] - 0.10), GRIP[2]), (GRIP[0], s * GRIP[1], GRIP[2]), 0.018), "Carbon", False))
        # Disc and radial caliper.
        out.append(PartSpec(f"disc{s}", rod((FRONT_AXLE_X, s * 0.075, FRONT_Z), (FRONT_AXLE_X, s * 0.081, FRONT_Z), 0.17), "Metal", False))
        out.append(PartSpec(f"caliper{s}", box(FRONT_AXLE_X + 0.10, s * 0.095, FRONT_Z + 0.10, 0.05, 0.04, 0.11), "Accent", False))
    out.append(PartSpec("axle", rod((FRONT_AXLE_X, -0.12, FRONT_Z), (FRONT_AXLE_X, 0.12, FRONT_Z), 0.012), "Metal", False))
    out.append(PartSpec("top_clamp", box(FORK_TOP[0], 0.0, FORK_TOP[2] - 0.01, 0.10, 0.26, 0.03), "Metal", False))
    out.append(PartSpec("bottom_clamp", box(FORK_TOP[0] - 0.06, 0.0, FORK_TOP[2] - 0.14, 0.10, 0.26, 0.04), "Metal", False))
    # Mudguard: a strip of a cylinder over the tyre.
    r = FRONT.radius + 0.03
    shell = Solid.make_cylinder(r, 0.14, Plane(origin=(FRONT_AXLE_X, -0.07, FRONT_Z), z_dir=(0, 1, 0))) \
        - Solid.make_cylinder(r - 0.008, 0.16, Plane(origin=(FRONT_AXLE_X, -0.08, FRONT_Z), z_dir=(0, 1, 0)))
    guard = shell & box(FRONT_AXLE_X + 0.02, 0.0, FRONT_Z + 0.25, 0.40, 0.2, 0.30)
    out.append(PartSpec("mudguard", guard, "Livery"))
    return out


# ------------------------------------------------------------------ rider
def make_rider_lower() -> list[PartSpec]:
    """Hips, legs folded onto the rear sets, boots: in leathers."""
    out: list[PartSpec] = []
    hx, _, hz = HIP
    suit = ellipsoid((hx + 0.01, 0.0, hz - 0.01), 0.14, 0.17, 0.10)
    for s in (-1, 1):
        hip = (hx - 0.02, s * 0.10, hz - 0.03)
        knee = (-0.08, s * 0.25, 0.30)
        ankle = (0.20, s * 0.19, -0.01)
        suit = suit + limb(hip, knee, 0.075, 0.055)
        suit = suit + limb(knee, ankle, 0.052, 0.040)
        # Knee slider on the outside of each knee.
        out.append(PartSpec(f"slider{s}", ellipsoid((-0.08, s * 0.30, 0.29), 0.05, 0.02, 0.035), "Accent"))
        out.append(PartSpec(f"boot{s}", ellipsoid((0.25, s * 0.19, -0.02), 0.10, 0.045, 0.055, tilt=-10.0), "Carbon"))
    out.append(PartSpec("leathers_lower", suit, "Suit"))
    # Coloured panels on the thighs.
    for s in (-1, 1):
        out.append(PartSpec(f"thigh_panel{s}", limb((hx - 0.04, s * 0.11, hz), (-0.04, s * 0.24, 0.33), 0.078, 0.058)
                            & box(0.08, s * 0.22, 0.42, 0.40, 0.10, 0.40), "Livery"))
    return out


def make_rider_upper() -> list[PartSpec]:
    """Torso leaning over the tank with the aero hump, arms to the grips, helmet."""
    out: list[PartSpec] = []
    hx, _, hz = HIP
    ang = math.radians(35.0)        # torso pitch above the horizontal
    L = 0.50
    sh = (hx - L * math.cos(ang), 0.0, hz + L * math.sin(ang))
    torso = ellipsoid((0.5 * (hx + sh[0]), 0.0, 0.5 * (hz + sh[2])), 0.30, 0.19, 0.13, tilt=35.0)
    out.append(PartSpec("leathers_upper", torso, "Suit"))
    # Aero hump on the back and the coloured back panel.
    hump = ellipsoid((0.5 * (hx + sh[0]) + 0.08, 0.0, 0.5 * (hz + sh[2]) + 0.12), 0.20, 0.10, 0.08, tilt=30.0)
    out.append(PartSpec("hump", hump, "Livery"))
    for s in (-1, 1):
        shoulder = (sh[0] + 0.02, s * 0.18, sh[2] - 0.02)
        elbow = (-0.30, s * 0.27, 0.60)
        grip = (GRIP[0] + 0.01, s * (GRIP[1] - 0.04), GRIP[2] + 0.02)
        arm = limb(shoulder, elbow, 0.055, 0.045) + limb(elbow, grip, 0.044, 0.036)
        out.append(PartSpec(f"arm{s}", arm, "Suit"))
        out.append(PartSpec(f"shoulder_pad{s}", ellipsoid(shoulder, 0.075, 0.06, 0.07), "Livery"))
        out.append(PartSpec(f"glove{s}", ellipsoid(grip, 0.05, 0.04, 0.04), "Carbon"))
    # Helmet ahead of the shoulders, chin down to the tank, visor forward.
    c = (sh[0] - 0.10, 0.0, sh[2] + 0.12)
    shell = scale(Sphere(0.135), by=(1.15, 1.0, 1.0)).moved(Location(c))
    spoiler = ellipsoid((c[0] + 0.12, 0.0, c[2] + 0.04), 0.06, 0.07, 0.03)
    visor_band = box(c[0] - 0.11, 0.0, c[2] + 0.0, 0.20, 0.30, 0.06)
    visor = scale(Sphere(0.1375), by=(1.15, 1.0, 1.0)).moved(Location(c)) & visor_band
    visor = visor - box(c[0] + 0.10, 0.0, c[2], 0.30, 0.30, 0.30)
    shell, stripe = split(shell, box(c[0], 0.0, c[2] + 0.07, 0.40, 0.05, 0.20))
    out += [PartSpec("helmet", shell + spoiler, "Helmet"), PartSpec("visor", visor, "Visor"),
            PartSpec("helmet_stripe", stripe, "Accent")]
    return out


def write_parts(path: Path, parts: list[PartSpec], root: str) -> None:
    groups = {name: MeshGroup(mat) for name, mat in MATERIALS.items()}
    total = 0
    for p in parts:
        if p.shape is None:
            print(f"  {p.name:18s} EMPTY, skipped")
            continue
        total += groups[p.material].add_shape(p.shape, TESS_TOL, TESS_ANG, p.surface_control)
    write_glb(path, [g for g in groups.values() if g.triangle_count > 0], root_name=root)
    print(f"{root}: {total} triangles -> {path}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=OUT_DIR)
    args = ap.parse_args()
    out_dir: Path = args.out.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    write_parts(out_dir / "body.glb", make_bodywork() + make_mechanics(), "MotoBody")
    write_parts(out_dir / "fork.glb", make_fork(), "MotoFork")
    write_parts(out_dir / "rider_lower.glb", make_rider_lower(), "RiderLower")
    write_parts(out_dir / "rider_upper.glb", make_rider_upper(), "RiderUpper")
    write_wheel(out_dir / "wheel_front.glb", FRONT, "MotoWheelFront")
    write_wheel(out_dir / "wheel_rear.glb", REAR, "MotoWheelRear")


if __name__ == "__main__":
    main()
