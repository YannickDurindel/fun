#!/usr/bin/env python3
"""Parametric racing kart (a generic direct-drive sprint kart: tubular frame, nose fairing,
front panel, side pods, full-width rear bumper, side-mounted single-cylinder engine, and the
driver sitting in the open; no make or brand), modelled with build123d like ``touring_body.py``.
Materials: the body scene scenes/car/kart_body_visual.tscn.

Regenerate the Godot assets with one command (from the repo root):

    .venv/bin/python cad/body/kart_body.py   # -> assets/car/kart/body.glb, wheel_front.glb, wheel_rear.glb

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.
``--out DIR`` writes the GLBs somewhere else.

Frame: same as ``f1_body.py``: CAD x = backward, y = right, z = up (Godot car-local:
forward = -Z, up = +Y, right = +X). The origin is where every car's is: 0.36 m above the
ground (z = -0.36), the height the physics holds the body at (Car.ride_ground_y); on a kart
that is about the driver's chest.

Dimensions: length 1.86 m over the bumpers, 1.42 m wide over the rear tyres, the helmet's top
1.0 m above the ground, 3 cm ground clearance, wheelbase 1.05 m: front axle x = -0.525, rear
x = +0.525.

Wheels: its own (kit_wheels.py): front 10 x 4.5-5 slicks (R 0.127 m, 0.115 m wide), rear
11 x 7.1-5 (R 0.140 m, 0.180 m wide) on 5 in magnesium rims, centres at (+-0.58, -0.233,
-0.525) and (+-0.62, -0.220, +0.525) Godot car-local. CarKit draws them there.

Material order: the F1 body's first seven (the body scene overrides nodes by index,
``body_motion.gd`` moves Helmet + Visor, ``bot_manager.gd`` recolours Livery / LiveryWhite /
Accent / Helmet), then Suit (the driver's overalls). No lights, glass or wings on a kart.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from build123d import Axis, Location, Plane, Solid, Sphere, Vector, mirror, scale

sys.path.insert(0, str(Path(__file__).resolve().parent))
from endurance_body import PartSpec, both_sides, box, loft, split, try_fillet, xz_plate  # noqa: E402
from glb_writer import Material, MeshGroup, write_glb  # noqa: E402
from kit_wheels import WheelSpec, write_wheel  # noqa: E402
from profiles import Section  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "assets" / "car" / "kart"

GROUND_Z = -0.36
FRAME_Z = GROUND_Z + 0.05          # tube centre line: 5 cm above the ground
FRONT_AXLE_X, REAR_AXLE_X = -0.525, 0.525
FRONT_Y, REAR_Y = 0.58, 0.62
FRONT = WheelSpec(radius=0.127, width=0.115, rim_radius=0.0635, shoulder=0.022, holes=3)
REAR = WheelSpec(radius=0.140, width=0.180, rim_radius=0.0635, shoulder=0.024, holes=3)
FRONT_Z = GROUND_Z + FRONT.radius
REAR_Z = GROUND_Z + REAR.radius
TUBE_R = 0.015

TESS_TOL = 0.0012
TESS_ANG = 0.2

MATERIALS = {
    "Livery": Material("Livery", (0.85, 0.10, 0.12, 1.0), 0.05, 0.35),
    "LiveryWhite": Material("LiveryWhite", (0.90, 0.90, 0.88, 1.0), 0.05, 0.35),
    "Accent": Material("Accent", (0.98, 0.78, 0.05, 1.0), 0.05, 0.35),
    "Carbon": Material("Carbon", (0.030, 0.031, 0.034, 1.0), 0.10, 0.55),
    "Metal": Material("Metal", (0.70, 0.70, 0.72, 1.0), 1.0, 0.25),
    "Helmet": Material("Helmet", (0.95, 0.95, 0.95, 1.0), 0.05, 0.22),
    "Visor": Material("Visor", (0.02, 0.02, 0.03, 1.0), 0.6, 0.08),
    "Suit": Material("Suit", (0.10, 0.12, 0.18, 1.0), 0.0, 0.75),
}


def rod(p0: tuple[float, float, float], p1: tuple[float, float, float], r: float) -> Solid:
    a, b = Vector(*p0), Vector(*p1)
    return Solid.make_cylinder(r, (b - a).length, Plane(origin=a, z_dir=b - a))


def ellipsoid(c: tuple[float, float, float], rx: float, ry: float, rz: float, tilt: float = 0.0):
    e = scale(Sphere(1.0), by=(rx, ry, rz))
    if tilt:
        e = e.rotate(Axis.Y, tilt)
    return e.moved(Location(c))


def make_frame() -> list[PartSpec]:
    """Chrome-moly tubes: two main rails, cross members, front stub axles, the rear axle."""
    out: list[PartSpec] = []
    z = FRAME_Z
    tubes = []
    for s in (-1, 1):
        tubes.append(rod((-0.78, s * 0.20, z), (-0.45, s * 0.26, z), TUBE_R))
        tubes.append(rod((-0.45, s * 0.26, z), (0.62, s * 0.30, z), TUBE_R))
        # Front axle beam end: the kingpin carrier, the stub axle out to the wheel.
        tubes.append(rod((FRONT_AXLE_X, s * 0.26, z), (FRONT_AXLE_X, s * 0.46, FRONT_Z), TUBE_R))
        tubes.append(rod((FRONT_AXLE_X, s * 0.46, FRONT_Z), (FRONT_AXLE_X, s * (FRONT_Y - 0.02), FRONT_Z), 0.010))
        # Side-pod and bumper brackets.
        tubes.append(rod((-0.10, s * 0.28, z), (-0.10, s * 0.50, z + 0.02), 0.010))
        tubes.append(rod((0.30, s * 0.29, z), (0.30, s * 0.50, z + 0.02), 0.010))
        tubes.append(rod((0.62, s * 0.30, z), (0.80, s * 0.30, z + 0.04), 0.012))
    tubes.append(rod((FRONT_AXLE_X, -0.26, z), (FRONT_AXLE_X, 0.26, z), TUBE_R))
    tubes.append(rod((-0.05, -0.27, z), (-0.05, 0.27, z), TUBE_R))
    tubes.append(rod((0.62, -0.30, z), (0.62, 0.30, z), TUBE_R))
    for i, t in enumerate(tubes):
        out.append(PartSpec(f"tube{i}", t, "Metal", False))
    # Live rear axle (50 mm) with its brake disc and sprocket.
    out.append(PartSpec("rear_axle", rod((REAR_AXLE_X, -(REAR_Y - 0.06), REAR_Z), (REAR_AXLE_X, REAR_Y - 0.06, REAR_Z), 0.025), "Metal", False))
    out.append(PartSpec("brake_disc", rod((REAR_AXLE_X, -0.22, REAR_Z), (REAR_AXLE_X, -0.21, REAR_Z), 0.095), "Metal", False))
    out.append(PartSpec("sprocket", rod((REAR_AXLE_X, 0.40, REAR_Z), (REAR_AXLE_X, 0.408, REAR_Z), 0.110), "Carbon", False))
    out.append(PartSpec("caliper", box(REAR_AXLE_X - 0.09, -0.215, REAR_Z + 0.02, 0.05, 0.04, 0.06), "Accent", False))
    out.append(PartSpec("floor_tray", box(-0.28, 0, z - 0.012, 0.60, 0.40, 0.006), "Carbon", False))
    return out


def make_bodywork() -> list[PartSpec]:
    out: list[PartSpec] = []
    # Nose fairing ahead of the front wheels.
    nose = loft([
        Section(-0.990, 0.720, -0.330, -0.250, n_top=2.6, n_bot=3.0, taper=0.80),
        Section(-0.940, 1.000, -0.335, -0.185, n_top=3.0, n_bot=4.0, taper=0.82),
        Section(-0.800, 1.100, -0.335, -0.160, n_top=3.4, n_bot=4.0, taper=0.84),
        Section(-0.680, 1.040, -0.330, -0.180, n_top=3.0, n_bot=4.0, taper=0.84),
    ])
    nose, plate = split(nose, box(-0.90, 0, -0.17, 0.20, 0.40, 0.04))
    nose, stripe = split(nose, box(-0.80, 0, -0.335, 0.40, 1.2, 0.05))
    out += [PartSpec("nose", nose, "Livery"), PartSpec("nose_number", plate, "LiveryWhite"),
            PartSpec("nose_stripe", stripe, "Accent")]
    # Front panel (bib) in front of the driver's shins, with the number board.
    panel = xz_plate([(-0.70, -0.30), (-0.64, -0.30), (-0.56, 0.02), (-0.62, 0.02)], -0.21, 0.42)
    panel = try_fillet(panel, panel.edges().filter_by(Axis.X), 0.012)
    panel, number = split(panel, box(-0.60, 0, -0.10, 0.12, 0.30, 0.16))
    out += [PartSpec("front_panel", panel, "Livery"), PartSpec("panel_number", number, "LiveryWhite")]
    # Side pods between the wheels.
    pod = loft([
        Section(-0.360, 0.120, -0.320, -0.240, y_center=0.470, n_top=2.6, n_bot=3.0, taper=0.80),
        Section(-0.280, 0.240, -0.330, -0.190, y_center=0.475, n_top=3.2, n_bot=4.0, taper=0.82),
        Section(0.250, 0.240, -0.330, -0.180, y_center=0.475, n_top=3.2, n_bot=4.0, taper=0.82),
        Section(0.360, 0.140, -0.320, -0.230, y_center=0.470, n_top=2.6, n_bot=3.0, taper=0.80),
    ])
    pod, pod_stripe = split(pod, box(0.0, 0.475, -0.185, 0.50, 0.30, 0.02))
    for i, s in enumerate(both_sides(pod)):
        out.append(PartSpec(f"pod{i}", s, "Livery"))
    for i, s in enumerate(both_sides(pod_stripe)):
        out.append(PartSpec(f"pod_stripe{i}", s, "Accent"))
    # Full-width rear bumper behind the rear wheels.
    bumper = loft([
        Section(0.700, 1.300, -0.315, -0.230, n_top=3.0, n_bot=3.0, taper=0.90),
        Section(0.760, 1.380, -0.320, -0.200, n_top=3.4, n_bot=4.0, taper=0.92),
        Section(0.860, 1.360, -0.315, -0.215, n_top=3.0, n_bot=3.0, taper=0.90),
    ])
    out.append(PartSpec("rear_bumper", bumper, "Carbon"))
    return out


def make_mechanics() -> list[PartSpec]:
    """Seat, fuel tank, steering, engine with airbox and exhaust."""
    out: list[PartSpec] = []
    seat = box(0.17, -0.03, -0.285, 0.30, 0.38, 0.05)
    seat = seat + xz_plate([(0.22, -0.31), (0.30, -0.31), (0.39, 0.12), (0.31, 0.12)], -0.22, 0.38)
    for s in (-1, 1):
        seat = seat + box(0.20, -0.03 + s * 0.19, -0.18, 0.28, 0.02, 0.20)
    out.append(PartSpec("seat", seat, "Carbon"))
    out.append(PartSpec("tank", box(-0.36, 0.0, -0.285, 0.22, 0.18, 0.07), "LiveryWhite"))
    column = rod((-0.56, 0.0, FRAME_Z + 0.01), (-0.30, 0.0, 0.00), 0.012)
    out.append(PartSpec("column", column, "Metal", False))
    d = Vector(0.26, 0.0, 0.31)
    ring = Solid.make_cylinder(0.150, 0.026, Plane(origin=(-0.30, 0.0, 0.0), z_dir=d)) \
        - Solid.make_cylinder(0.128, 0.03, Plane(origin=(-0.302, 0.0, -0.002), z_dir=d))
    spoke = rod((-0.30, -0.13, -0.004), (-0.30, 0.13, -0.004), 0.012)
    out.append(PartSpec("steering_wheel", ring + spoke, "Carbon"))
    # Engine on the right of the seat: crankcase, finned cylinder, airbox ahead, exhaust behind.
    out.append(PartSpec("crankcase", box(0.32, 0.38, -0.25, 0.20, 0.16, 0.12), "Metal"))
    cyl = rod((0.32, 0.38, -0.19), (0.32, 0.38, -0.04), 0.055)
    for k in range(5):
        cyl = cyl + rod((0.32, 0.38, -0.17 + 0.03 * k), (0.32, 0.38, -0.162 + 0.03 * k), 0.075)
    out.append(PartSpec("cylinder", cyl, "Metal"))
    out.append(PartSpec("airbox", box(0.08, 0.40, -0.22, 0.16, 0.18, 0.14), "Carbon"))
    out.append(PartSpec("exhaust", rod((0.36, 0.42, -0.06), (0.60, 0.48, -0.10), 0.032), "Metal", False))
    out.append(PartSpec("silencer", rod((0.60, 0.48, -0.10), (0.80, 0.50, -0.14), 0.045), "Carbon", False))
    return out


def make_driver() -> list[PartSpec]:
    """The driver sitting upright in the open: overalls, gloves on the wheel, boots on the pedals."""
    out: list[PartSpec] = []
    torso = ellipsoid((0.14, -0.03, 0.02), 0.13, 0.21, 0.28, tilt=15.0)
    pelvis = ellipsoid((0.15, -0.03, -0.20), 0.13, 0.19, 0.10)
    suit = torso + pelvis
    for s in (-1, 1):
        y = -0.03 + s * 0.19
        suit = suit + ellipsoid((0.20, y, 0.21), 0.07, 0.07, 0.07)                 # shoulder
        suit = suit + rod((0.20, y, 0.21), (0.00, -0.03 + s * 0.23, 0.02), 0.045)  # upper arm
        suit = suit + rod((0.00, -0.03 + s * 0.23, 0.02), (-0.27, s * 0.13, 0.03), 0.038)
        suit = suit + rod((0.12, -0.03 + s * 0.10, -0.24), (-0.25, s * 0.13, -0.13), 0.065)  # thigh
        suit = suit + rod((-0.25, s * 0.13, -0.13), (-0.56, s * 0.11, -0.26), 0.050)  # shin
    out.append(PartSpec("suit", suit, "Suit"))
    out.append(PartSpec("collar", ellipsoid((0.21, -0.03, 0.30), 0.07, 0.08, 0.05), "Carbon"))
    for s in (-1, 1):
        out.append(PartSpec(f"glove{s}", ellipsoid((-0.28, s * 0.13, 0.03), 0.045, 0.04, 0.05), "Carbon"))
        out.append(PartSpec(f"boot{s}", ellipsoid((-0.60, s * 0.11, -0.26), 0.09, 0.045, 0.05), "Carbon"))
    # Helmet + visor, facing forward (-x).
    c = (0.22, -0.03, 0.42)
    shell = scale(Sphere(0.125), by=(1.12, 1.0, 1.04)).moved(Location(c))
    visor_band = box(c[0] - 0.10, c[1], c[2] + 0.005, 0.20, 0.30, 0.050)
    visor = scale(Sphere(0.1275), by=(1.12, 1.0, 1.04)).moved(Location(c)) & visor_band
    visor = visor - box(c[0] + 0.10, c[1], c[2], 0.30, 0.30, 0.30)
    shell, stripe = split(shell, box(c[0], c[1], c[2] + 0.06, 0.40, 0.06, 0.20))
    out += [PartSpec("helmet", shell, "Helmet"), PartSpec("visor", visor, "Visor"),
            PartSpec("helmet_stripe", stripe, "Accent")]
    return out


def build_parts() -> list[PartSpec]:
    parts: list[PartSpec] = []
    for b in (make_frame, make_bodywork, make_mechanics, make_driver):
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
        total += groups[p.material].add_shape(p.shape, TESS_TOL, TESS_ANG, p.surface_control)
    write_glb(out_dir / "body.glb", list(groups.values()), root_name="KartBody")
    print(f"total {total} triangles -> {out_dir / 'body.glb'}")
    write_wheel(out_dir / "wheel_front.glb", FRONT, "KartWheelFront")
    write_wheel(out_dir / "wheel_rear.glb", REAR, "KartWheelRear")


if __name__ == "__main__":
    main()
