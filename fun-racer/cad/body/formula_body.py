#!/usr/bin/env python3
"""Two more single-seaters derived from the F1 body (``f1_body.py``), each a generic design with
no make or brand:

    .venv/bin/python cad/body/formula_body.py --formula-e       # -> assets/car/formula_e/body.glb
    .venv/bin/python cad/body/formula_body.py --super-formula   # -> assets/car/super_formula/body.glb

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.

``--formula-e``: the electric street racer of the Formula E kit. The F1 tub shortened to a
2.97 m wheelbase and narrowed (1.78 m over the rear tyres), a low rounded hump behind the
driver instead of the airbox (no engine to feed), no shark fin and no exhaust, a simple
two-element front wing whose endplates run into a fairing over the top and front of each
front wheel, fairings over the top and back of the rear wheels on struts from the diffuser,
and a low-drag two-element rear wing on twin pylons. White / graphite / lime livery.

``--super-formula``: the high-downforce Japanese single-seater of the Super Formula kit. The F1
car's aero (three-flap front wing, fin, two-element rear wing and beam wing) on a tub shortened
to a 3.165 m wheelbase and 1.90 m wide, with twin rear wing pylons. Orange / white / black
livery.

Both reuse f1_body.py's part builders (not its flags) and scale the result: CAD x by
wheelbase / 3.60 and y by the width factor, about the origin (the axles stay centred on it);
the driver's helmet is not scaled. Wheels: none here; the car reuses the F1 wheel assets (front
R 0.33 m, rear R 0.36 m). Wheel centres the game must use (Godot car-local, like
``Car.WHEEL_OFFSETS``):

    formula_e      front (+-0.720, 0, -1.485), rear (+-0.702, 0, +1.485)
    super_formula  front (+-0.760, 0, -1.5825), rear (+-0.741, 0, +1.5825)

Frame and material order: as ``f1_body.py`` (Livery, LiveryWhite, Accent, Carbon, Metal,
Helmet, Visor, Light).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from build123d import Axis, Box, Location, Plane, Solid, scale

sys.path.insert(0, str(Path(__file__).resolve().parent))
import f1_body as f1  # noqa: E402
from f1_body import PartSpec, both_sides, loft, try_fillet, wing_element, xz_plate  # noqa: E402
from glb_writer import Material, MeshGroup, write_glb  # noqa: E402
from profiles import Section  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
F1_WHEELBASE = 3.60

VARIANTS = {
    "formula_e": {
        "wheelbase": 2.97,
        "width_scale": 0.90,
        "root": "FormulaEBody",
        "materials": {
            "Livery": Material("Livery", (0.88, 0.89, 0.91, 1.0), 0.10, 0.28),
            "LiveryWhite": Material("LiveryWhite", (0.10, 0.11, 0.13, 1.0), 0.30, 0.30),
            "Accent": Material("Accent", (0.50, 0.88, 0.10, 1.0), 0.10, 0.30),
        },
    },
    "super_formula": {
        "wheelbase": 3.165,
        "width_scale": 0.95,
        "root": "SuperFormulaBody",
        "materials": {
            "Livery": Material("Livery", (0.92, 0.30, 0.04, 1.0), 0.20, 0.30),
            "LiveryWhite": Material("LiveryWhite", (0.88, 0.88, 0.90, 1.0), 0.05, 0.32),
            "Accent": Material("Accent", (0.04, 0.04, 0.05, 1.0), 0.20, 0.30),
        },
    },
}

FRONT_TYRE_R, REAR_TYRE_R = 0.33, 0.36
FRONT_TYRE_W, REAR_TYRE_W = 0.30, 0.38
FRONT_AXLE_Z = -(REAR_TYRE_R - FRONT_TYRE_R)   # the smaller fronts sit lower (level body)


# --------------------------------------------------------------------------
# Parts in the F1 frame (scaled afterwards)
# --------------------------------------------------------------------------
def make_hump() -> list[PartSpec]:
    """Formula E: a low rounded fairing over the roll hoop, no intake, no fin."""
    hump = loft(
        [
            Section(0.080, 0.250, 0.200, 0.470, n_top=2.2, n_bot=3.0, taper=0.50, z_split=0.31),
            Section(0.400, 0.290, 0.200, 0.455, n_top=2.2, n_bot=3.0, taper=0.45, z_split=0.30),
            Section(1.000, 0.210, 0.150, 0.330, n_top=2.2, n_bot=3.0, taper=0.50),
            Section(1.600, 0.100, 0.050, 0.160, n_top=2.2, n_bot=3.0, taper=0.6),
        ]
    )
    hoop = loft(
        [
            Section(0.120, 0.130, 0.420, 0.490, n_top=2.0, n_bot=2.2, taper=0.75),
            Section(0.300, 0.130, 0.420, 0.480, n_top=2.0, n_bot=2.2, taper=0.75),
        ]
    )
    tcam = Box(0.09, 0.05, 0.025).locate(Location((0.33, 0, 0.490)))
    tcam = try_fillet(tcam, tcam.edges(), 0.008)
    return [
        PartSpec("hump", hump, "Livery"),
        PartSpec("roll_hoop", hoop, "Carbon"),
        PartSpec("tcam", tcam, "Accent", False),
    ]


def make_front_wing_fe() -> list[PartSpec]:
    """Formula E: mainplane and one flap, plain endplates (no turning vanes)."""
    out: list[PartSpec] = []
    main = wing_element(f1.NOSE_X, -0.285, 0.30, 4.0, -f1.FW_HALF_SPAN + 0.012, f1.FW_HALF_SPAN - 0.012,
                        camber=0.05, thickness=0.09)
    out.append(PartSpec("fw_main", main, "LiveryWhite", surface_control=False))
    flap = wing_element(-2.630, -0.255, 0.200, 14.0, 0.18, f1.FW_HALF_SPAN - 0.012, camber=0.06, thickness=0.09)
    for j, s in enumerate(both_sides(flap)):
        out.append(PartSpec(f"fw_flap{j}", s, "Accent", surface_control=False))
    endplate = xz_plate(
        [
            (f1.NOSE_X - 0.03, -0.315),
            (-2.30, -0.315),
            (-2.22, -0.10),
            (-2.40, -0.05),
            (-2.78, -0.13),
            (f1.NOSE_X - 0.04, -0.23),
        ],
        f1.FW_HALF_SPAN - 0.012,
        0.012,
    )
    endplate = try_fillet(endplate, endplate.edges().filter_by(Axis.Y), 0.025)
    for j, s in enumerate(both_sides(endplate)):
        out.append(PartSpec(f"fw_endplate{j}", s, "LiveryWhite"))
    return out


def make_rear_wing(variant: str) -> list[PartSpec]:
    """Two elements between the F1 endplates on twin straight pylons. Formula E: a flat, low-drag
    main and a small flap, no beam wing. Super Formula: the F1 car's elements and beam wing."""
    hs = f1.RW_HALF_SPAN
    out: list[PartSpec] = []
    if variant == "formula_e":
        main = wing_element(2.240, 0.420, 0.300, 4.0, -hs, hs, camber=0.05, thickness=0.10)
        flap = wing_element(2.480, 0.460, 0.150, 16.0, -hs, hs, camber=0.06, thickness=0.09)
    else:
        main = wing_element(2.235, 0.415, 0.290, 9.0, -hs, hs, camber=0.08, thickness=0.11)
        flap = wing_element(2.480, 0.470, 0.200, 30.0, -hs, hs, camber=0.07, thickness=0.09)
        b1 = wing_element(2.290, 0.030, 0.150, 8.0, -hs, hs, camber=0.06, thickness=0.10)
        b2 = wing_element(2.450, 0.065, 0.120, 22.0, -hs, hs, camber=0.06, thickness=0.10)
        out.append(PartSpec("beam_wing0", b1, "Carbon", surface_control=False))
        out.append(PartSpec("beam_wing1", b2, "Carbon", surface_control=False))
    out.append(PartSpec("rw_main", main, "LiveryWhite", surface_control=False))
    out.append(PartSpec("rw_flap", flap, "Accent", surface_control=False))
    endplate = xz_plate(
        [(2.42, 0.000), (2.58, 0.000), (2.60, 0.150), (2.70, 0.320), (2.70, 0.640), (2.30, 0.640),
         (2.17, 0.540), (2.20, 0.380), (2.40, 0.180)],
        hs,
        0.014,
    )
    endplate = try_fillet(endplate, endplate.edges().filter_by(Axis.Y), 0.05)
    plate_mat = "Livery" if variant == "formula_e" else "Accent"
    for j, s in enumerate(both_sides(endplate)):
        out.append(PartSpec(f"rw_endplate{j}", s, plate_mat))
    for y in (-0.20, 0.20):
        post = xz_plate([(2.10, -0.02), (2.24, -0.02), (2.42, 0.42), (2.30, 0.42)], y - 0.008, 0.016)
        out.append(PartSpec(f"rw_pylon{y}", post, "Carbon"))
    return out


def make_rain_light() -> list[PartSpec]:
    light = Box(0.03, 0.10, 0.05).locate(Location((2.425, 0, -0.105)))
    light = try_fillet(light, light.edges().filter_by(Axis.X), 0.012)
    return [PartSpec("rain_light", light, "Light")]


# --------------------------------------------------------------------------
# Formula E wheel fairings, in the scaled frame
# --------------------------------------------------------------------------
def fairing(axle_x: float, axle_z: float, y: float, r: float, w: float, front: bool) -> Solid:
    """A curved shell over a wheel (10 mm off the tyre, 30 mm thick, 6 cm wider than it): over
    the top and front of a front wheel, over the top and back of a rear wheel."""
    plane = Plane(origin=(axle_x, y - w / 2 - 0.03, axle_z), z_dir=(0, 1, 0))
    drum = Solid.make_cylinder(r + 0.045, w + 0.06, plane) - Solid.make_cylinder(r + 0.015, w + 0.06, plane)
    if front:   # from level with the axle ahead of the wheel, over the top, to 12 cm behind it
        keep = Box(r + 0.17, w + 0.1, r + 0.1).locate(Location((axle_x - (r + 0.17) / 2 + 0.12, y, axle_z + 0.03 + (r + 0.1) / 2)))
    else:       # from 10 cm ahead of the axle over the top and down the back to 8 cm above it
        keep = Box(r + 0.15, w + 0.1, r + 0.1).locate(Location((axle_x + (r + 0.15) / 2 - 0.10, y, axle_z + 0.08 + (r + 0.1) / 2)))
    return drum & keep


def make_fairings(wheels: dict) -> list[PartSpec]:
    fx, fy = wheels["front"]
    rx, ry = wheels["rear"]
    front = fairing(fx, FRONT_AXLE_Z, fy, FRONT_TYRE_R, FRONT_TYRE_W, True)
    rear = fairing(rx, 0.0, ry, REAR_TYRE_R, REAR_TYRE_W, False)
    try:
        front = front.fillet(0.008, front.edges())
        rear = rear.fillet(0.008, rear.edges())
    except Exception as exc:  # cosmetic only
        print(f"  fairing fillet skipped: {exc}")
    # Strut from the diffuser wall up to the inner edge of each rear fairing.
    y_in = ry - REAR_TYRE_W / 2 - 0.03 - 0.014
    strut = xz_plate([(rx - 0.05, -0.05), (rx + 0.22, -0.05), (rx + 0.30, 0.30), (rx + 0.10, 0.42),
                      (rx - 0.02, 0.40)], y_in, 0.014)
    strut = try_fillet(strut, strut.edges().filter_by(Axis.Y), 0.02)
    out = []
    for j, s in enumerate(both_sides(front)):
        out.append(PartSpec(f"front_fairing{j}", s, "Livery"))
    for j, s in enumerate(both_sides(rear)):
        out.append(PartSpec(f"rear_fairing{j}", s, "Livery"))
    for j, s in enumerate(both_sides(strut)):
        out.append(PartSpec(f"fairing_strut{j}", s, "Carbon", False))
    return out


# --------------------------------------------------------------------------
def build_parts(variant: str) -> list[PartSpec]:
    fe = variant == "formula_e"
    builders = [f1.make_chassis, f1.make_sidepods]
    builders.append(make_hump if fe else f1.make_airbox_and_fin)
    builders += [f1.make_halo, f1.make_mirrors]
    builders.append(make_front_wing_fe if fe else f1.make_front_wing)
    builders += [lambda: make_rear_wing(variant), f1.make_floor_and_diffuser]
    builders.append(make_rain_light if fe else f1.make_rear_details)
    parts: list[PartSpec] = []
    for b in builders:
        print(f"building {getattr(b, '__name__', 'part')} ...")
        parts.extend(b())

    v = VARIANTS[variant]
    sx = v["wheelbase"] / F1_WHEELBASE
    sy = v["width_scale"]
    for p in parts:
        p.shape = scale(p.shape, by=(sx, sy, 1.0))
    print("building driver ...")
    parts += f1.make_driver()   # not scaled: the helmet keeps its shape
    if fe:
        print("building fairings ...")
        parts += make_fairings({"front": (-v["wheelbase"] / 2, 0.80 * sy), "rear": (v["wheelbase"] / 2, 0.78 * sy)})
    return parts


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--formula-e", dest="variant", action="store_const", const="formula_e")
    g.add_argument("--super-formula", dest="variant", action="store_const", const="super_formula")
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args()
    variant: str = args.variant
    out_path: Path = (args.out or REPO / "assets" / "car" / variant / "body.glb").resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    materials = dict(f1.MATERIALS)
    materials.pop("Glass", None)   # f1_body's IndyCar extra, never used here
    materials.update(VARIANTS[variant]["materials"])
    parts = build_parts(variant)
    groups = {name: MeshGroup(mat) for name, mat in materials.items()}
    total = 0
    for p in parts:
        n = groups[p.material].add_shape(p.shape, f1.TESS_TOL, f1.TESS_ANG, p.surface_control)
        total += n
        print(f"  {p.name:18s} {p.material:12s} {n:7d} tris")
    write_glb(out_path, list(groups.values()), root_name=VARIANTS[variant]["root"])
    for g in groups.values():
        print(f"{g.material.name:12s} {g.triangle_count:7d} tris")
    print(f"total {total} triangles -> {out_path}")


if __name__ == "__main__":
    main()
