#!/usr/bin/env python3
"""Parametric stock car body (a generic American oval racer: long bonnet, fastback roof, short
deck with a tall blade spoiler across the tail, flat splitter, side skirts and side exhausts,
sticker headlights; no make or brand), modelled with build123d like ``touring_body.py``.
Materials: the body scene scenes/car/stock_body_visual.tscn.

Regenerate the Godot asset with one command (from the repo root):

    .venv/bin/python cad/body/stock_body.py     # -> assets/car/stock/body.glb

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.
``--out PATH`` writes the GLB somewhere else.

Frame: same as ``f1_body.py``: CAD x = backward, y = right, z = up (Godot car-local:
forward = -Z, up = +Y, right = +X). The origin is at axle height, ground at z = -0.36.

Dimensions: length 4.95 m (splitter included), width 1.96 m, roof 1.29 m above the ground,
wheelbase 2.80 m: front axle x = -1.40, rear x = +1.40.

Wheels: none here. The car reuses the F1 wheel assets (front R 0.33 m, rear R 0.36 m) at
the centres the game must use (Godot car-local, like ``Car.WHEEL_OFFSETS``): front
(+-0.80, 0, -1.40), rear (+-0.78, 0, +1.40). The arches are cut for those with 4 cm clearance.

Material order: as ``touring_body.py`` (the F1 body's eight, then Glass and Headlight).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from build123d import Location, Plane, Solid, Sphere, mirror, scale

sys.path.insert(0, str(Path(__file__).resolve().parent))
from endurance_body import (  # noqa: E402
    PartSpec, both_sides, box, loft, mirrored_box, split, try_fillet, xy_plate, xz_plate,
)
from glb_writer import Material, MeshGroup, write_glb  # noqa: E402
from profiles import Section  # noqa: E402

from build123d import Axis  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
OUT_PATH = REPO / "assets" / "car" / "stock" / "body.glb"

GROUND_Z = -0.36
FLOOR_BOTTOM_Z = -0.28  # 8 cm ride height
FRONT_AXLE_X, REAR_AXLE_X = -1.40, 1.40
NOSE_X, TAIL_X = -2.42, 2.42
HALF_WIDTH = 0.98
FRONT_TYRE_R, REAR_TYRE_R = 0.33, 0.36
ARCH_CLEARANCE = 0.04

TESS_TOL = 0.0015
TESS_ANG = 0.18

MATERIALS = {
    "Livery": Material("Livery", (0.70, 0.04, 0.05, 1.0), 0.30, 0.28),
    "LiveryWhite": Material("LiveryWhite", (0.90, 0.90, 0.88, 1.0), 0.05, 0.30),
    "Accent": Material("Accent", (0.98, 0.78, 0.05, 1.0), 0.10, 0.30),
    "Carbon": Material("Carbon", (0.030, 0.031, 0.034, 1.0), 0.20, 0.30),
    "Metal": Material("Metal", (0.80, 0.80, 0.82, 1.0), 1.0, 0.12),
    "Helmet": Material("Helmet", (0.95, 0.95, 0.95, 1.0), 0.05, 0.22),
    "Visor": Material("Visor", (0.02, 0.02, 0.03, 1.0), 0.6, 0.08),
    "Light": Material("Light", (0.6, 0.0, 0.0, 1.0), 0.0, 0.4, emissive=(1.0, 0.05, 0.03)),
    "Glass": Material("Glass", (0.05, 0.06, 0.07, 1.0), 0.0, 0.05),
    "Headlight": Material("Headlight", (0.75, 0.75, 0.72, 1.0), 0.0, 0.3),
}

# Lower body: blunt nose, long bonnet, flat flanks, a short deck rising to the spoiler.
HULL = [
    #       x,     width, z_bot,  z_top
    Section(-2.420, 1.620, -0.220, 0.080, n_top=2.6, n_bot=3.0, taper=0.86),
    Section(-2.330, 1.860, -0.250, 0.250, n_top=3.4, n_bot=4.0, taper=0.88),
    Section(-1.950, 1.940, -0.270, 0.385, n_top=6.0, n_bot=5.0, taper=0.90),
    Section(-1.300, 1.950, -0.275, 0.440, n_top=6.0, n_bot=5.0, taper=0.90),
    Section(-0.700, 1.950, -0.275, 0.470, n_top=6.0, n_bot=5.0, taper=0.90),
    Section(0.100, 1.950, -0.275, 0.500, n_top=6.0, n_bot=5.0, taper=0.90),
    Section(0.900, 1.950, -0.275, 0.540, n_top=6.0, n_bot=5.0, taper=0.90),
    Section(1.600, 1.940, -0.275, 0.575, n_top=6.0, n_bot=5.0, taper=0.90),
    Section(2.150, 1.910, -0.265, 0.595, n_top=6.0, n_bot=5.0, taper=0.90),
    Section(2.360, 1.840, -0.230, 0.595, n_top=3.6, n_bot=4.0, taper=0.90),
    Section(2.420, 1.720, -0.180, 0.570, n_top=3.0, n_bot=3.0, taper=0.88),
]
# Greenhouse: raked windscreen, low roof and a long fastback down to the deck lid. Its lower
# half is buried in the hull; the widest line (z_split) is the belt line.
CABIN = [
    Section(-0.900, 1.500, 0.400, 0.470, n_top=2.6, n_bot=4.0, taper=0.80),
    Section(-0.450, 1.480, 0.280, 0.790, n_top=2.8, n_bot=4.0, taper=0.76),
    Section(0.050, 1.420, 0.250, 0.950, n_top=3.2, n_bot=4.0, taper=0.72),
    Section(0.550, 1.400, 0.250, 0.935, n_top=3.2, n_bot=4.0, taper=0.72),
    Section(1.100, 1.400, 0.340, 0.780, n_top=3.0, n_bot=4.0, taper=0.74),
    Section(1.650, 1.420, 0.480, 0.640, n_top=2.8, n_bot=4.0, taper=0.78),
    Section(1.950, 1.420, 0.560, 0.610, n_top=2.6, n_bot=4.0, taper=0.80),
]
GLASS_X0, GLASS_X1 = -0.88, 1.78
GLASS_Z0, GLASS_Z1 = 0.575, 0.810


def flare(axle_x: float, top: float) -> list[Section]:
    """Shallow fender bulge round one wheel, its inner half buried in the hull."""
    return [
        Section(axle_x - 0.62, 0.140, -0.255, 0.150, y_center=0.880, n_top=3.0, n_bot=4.0, taper=0.80),
        Section(axle_x - 0.45, 0.220, -0.262, top - 0.04, y_center=0.870, n_top=3.6, n_bot=4.0, taper=0.80),
        Section(axle_x, 0.220, -0.262, top, y_center=0.870, n_top=3.6, n_bot=4.0, taper=0.80),
        Section(axle_x + 0.45, 0.220, -0.262, top - 0.04, y_center=0.870, n_top=3.6, n_bot=4.0, taper=0.80),
        Section(axle_x + 0.62, 0.140, -0.255, 0.150, y_center=0.880, n_top=3.0, n_bot=4.0, taper=0.80),
    ]


def arch_cutter(axle_x: float, tyre_r: float, y0: float) -> Solid:
    return Solid.make_cylinder(tyre_r + ARCH_CLEARANCE, HALF_WIDTH + 0.2 - y0,
                               Plane(origin=(axle_x, y0, 0.0), z_dir=(0, 1, 0)))


def make_bodywork() -> list[PartSpec]:
    body = loft(HULL)
    cabin = loft(CABIN)   # not fused: its lower half is buried in the hull
    for axle_x, top in ((FRONT_AXLE_X, 0.41), (REAR_AXLE_X, 0.47)):
        for side in both_sides(loft(flare(axle_x, top))):
            body = body + side
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        for c in both_sides(arch_cutter(axle_x, r, 0.55)):
            body = body - c
    out: list[PartSpec] = []

    # Glazing: windscreen, side windows and the fastback's rear window in one band.
    cabin, glass = split(cabin, box(0.5 * (GLASS_X0 + GLASS_X1), 0, 0.5 * (GLASS_Z0 + GLASS_Z1),
                                  GLASS_X1 - GLASS_X0, 1.70, GLASS_Z1 - GLASS_Z0))
    # Black frames: the belt line, the A pillars' feet and the broad quarter panels (no rear
    # side window: a stock car's C pillar runs from the roof to the deck).
    frame = mirrored_box(0.45, 0.72, GLASS_Z0 + 0.012, 2.7, 0.12, 0.026)
    frame = frame + mirrored_box(0.62, 0.71, 0.73, 0.10, 0.14, 0.34)
    glass, frames = split(glass, frame)
    glass, quarter = split(glass, mirrored_box(1.30, 0.70, 0.73, 1.0, 0.12, 0.34))
    out += [PartSpec("glazing", glass, "Glass"), PartSpec("window_frames", frames, "Carbon"),
            PartSpec("quarter_panels", quarter, "Livery")]

    # Front: sticker grille and headlights, black lower intake.
    body, grille = split(body, box(-2.40, 0, 0.040, 0.16, 0.80, 0.080))
    body, intake = split(body, box(-2.40, 0, -0.150, 0.20, 1.40, 0.100))
    out += [PartSpec("grille", grille, "Carbon"), PartSpec("intake", intake, "Carbon")]
    body, lamps = split(body, mirrored_box(-2.32, 0.68, 0.140, 0.24, 0.32, 0.070))
    out.append(PartSpec("headlights", lamps, "Headlight"))
    # Bonnet louvres on either side of the centreline.
    body, vents = split(body, mirrored_box(-1.55, 0.36, 0.40, 0.34, 0.30, 0.10))
    out.append(PartSpec("bonnet_vents", vents, "Carbon"))

    # Tail: a light bar across the rear panel, a black diffuser panel below.
    body, tail = split(body, box(2.40, 0, 0.45, 0.10, 1.50, 0.060))
    out.append(PartSpec("tail_lights", tail, "Light"))
    body, rear_panel = split(body, box(2.40, 0, -0.15, 0.16, 2.2, 0.14))
    out.append(PartSpec("rear_panel", rear_panel, "Carbon"))

    # Black side skirts from arch to arch.
    body, sills = split(body, mirrored_box(0.0, 0.94, -0.230, 4.8, 0.30, 0.08))
    out.append(PartSpec("sills", sills, "Carbon"))
    # Livery: a big white number board on the doors, a yellow band along the flanks and a
    # number board on the roof, read from the grandstands above the banking.
    body, panel = split(body, mirrored_box(0.05, 1.00, 0.17, 1.15, 0.30, 0.42))
    body, stripe = split(body, mirrored_box(0.0, 1.00, -0.120, 5.0, 0.40, 0.08))
    cabin, roof_no = split(cabin, box(0.15, 0, 0.95, 0.60, 0.80, 0.16))
    cabin, flaps = split(cabin, mirrored_box(0.63, 0.30, 0.95, 0.12, 0.22, 0.16))
    out.append(PartSpec("cabin", cabin, "Livery"))
    out += [PartSpec("door_number", panel, "LiveryWhite"), PartSpec("flank_band", stripe, "Accent"),
            PartSpec("roof_number", roof_no, "LiveryWhite"), PartSpec("roof_flaps", flaps, "Carbon")]

    # Wheel-arch liners.
    liners = None
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        big = Solid.make_cylinder(r + ARCH_CLEARANCE + 0.035, HALF_WIDTH + 0.2 - 0.50,
                                  Plane(origin=(axle_x, 0.50, 0.0), z_dir=(0, 1, 0)))
        ring = big - arch_cutter(axle_x, r, 0.55)
        ring = ring + mirror(ring, about=Plane.XZ)
        liners = ring if liners is None else liners + ring
    body, liner = split(body, liners)
    out.append(PartSpec("arch_liners", liner, "Carbon"))

    # Shut lines: two doors, bonnet and deck lid.
    g = 0.006
    grooves = mirrored_box(-0.68, 0.97, 0.12, g, 0.3, 0.70)
    grooves = grooves + mirrored_box(0.68, 0.97, 0.12, g, 0.3, 0.70)
    grooves = grooves + box(-0.95, 0, 0.46, g, 1.5, 0.2)
    grooves = grooves + box(2.00, 0, 0.60, g, 1.5, 0.2)
    body, gr = split(body, grooves)
    out.append(PartSpec("panel_lines", gr, "Carbon"))

    out.insert(0, PartSpec("body", body, "Livery"))
    return out


def make_mirrors() -> list[PartSpec]:
    housing = loft([
        Section(-0.600, 0.120, 0.600, 0.670, y_center=0.860, n_top=2.6, n_bot=2.6, taper=0.85),
        Section(-0.510, 0.150, 0.590, 0.690, y_center=0.870, n_top=3.0, n_bot=3.0, taper=0.90),
        Section(-0.480, 0.150, 0.590, 0.690, y_center=0.870, n_top=3.0, n_bot=3.0, taper=0.90),
    ])
    housing, glass = split(housing, box(-0.475, 0.870, 0.640, 0.03, 0.13, 0.08))
    stalk = box(-0.53, 0.78, 0.600, 0.07, 0.10, 0.03)
    out = []
    for i, s in enumerate(both_sides(housing)):
        out.append(PartSpec(f"mirror{i}", s, "Carbon"))
    for i, s in enumerate(both_sides(glass)):
        out.append(PartSpec(f"mirror_glass{i}", s, "Metal"))
    for i, s in enumerate(both_sides(stalk)):
        out.append(PartSpec(f"mirror_stalk{i}", s, "Carbon", False))
    return out


def make_spoiler() -> list[PartSpec]:
    """The stock car's blade spoiler: a tall plate across the whole tail, leaning back, on
    triangular side braces."""
    out: list[PartSpec] = []
    blade = xz_plate([(2.33, 0.560), (2.40, 0.560), (2.46, 0.800), (2.43, 0.800)], -0.90, 1.80)
    out.append(PartSpec("spoiler", blade, "Carbon", surface_control=False))
    lip = box(2.445, 0, 0.805, 0.035, 1.80, 0.012)
    out.append(PartSpec("spoiler_lip", lip, "Accent", False))
    brace = xz_plate([(2.10, 0.570), (2.38, 0.570), (2.43, 0.780)], 0.885, 0.012)
    for j, s in enumerate(both_sides(brace)):
        out.append(PartSpec(f"spoiler_brace{j}", s, "Carbon", False))
    return out


def make_floor_splitter() -> list[PartSpec]:
    out: list[PartSpec] = []
    half = [(-2.15, 0.0), (-2.15, 0.70), (2.20, 0.70), (2.20, 0.0)]
    outline = half + [(x, -y) for x, y in reversed(half[1:-1])]
    out.append(PartSpec("floor", xy_plate(outline, FLOOR_BOTTOM_Z, 0.02), "Carbon", False))
    split_half = [(-2.52, 0.0), (-2.52, 0.80), (-2.44, 0.90), (-2.15, 0.92), (-2.15, 0.0)]
    split_outline = split_half + [(x, -y) for x, y in reversed(split_half[1:-1])]
    splitter = xy_plate(split_outline, FLOOR_BOTTOM_Z, 0.018)
    splitter = try_fillet(splitter, splitter.edges().filter_by(Axis.Z), 0.03)
    out.append(PartSpec("splitter", splitter, "Carbon", False))
    ramp = xz_plate([(2.10, FLOOR_BOTTOM_Z), (2.44, -0.190), (2.44, -0.175), (2.10, FLOOR_BOTTOM_Z + 0.018)],
                    -0.66, 1.32)
    out.append(PartSpec("diffuser", ramp, "Carbon", False))
    # Side exhausts: a pipe out of each skirt ahead of the rear wheels.
    for sgn in (1, -1):
        pipe = Solid.make_cylinder(0.050, 0.14, Plane(origin=(0.80, sgn * 0.86, -0.215), z_dir=(0, sgn, 0)))
        out.append(PartSpec(f"exhaust{sgn}", pipe, "Metal", False))
    return out


def make_driver() -> list[PartSpec]:
    """Helmet + visor behind the side window (driver seated left of the centreline)."""
    c = (0.28, -0.34, 0.690)
    shell = scale(Sphere(0.125), by=(1.12, 1.0, 1.04)).moved(Location(c))
    visor_band = box(c[0] - 0.10, c[1], c[2] + 0.005, 0.20, 0.30, 0.050)
    visor = scale(Sphere(0.1275), by=(1.12, 1.0, 1.04)).moved(Location(c)) & visor_band
    visor = visor - box(c[0] + 0.10, c[1], c[2], 0.30, 0.30, 0.30)
    return [PartSpec("helmet", shell, "Helmet"), PartSpec("visor", visor, "Visor")]


def build_parts() -> list[PartSpec]:
    parts: list[PartSpec] = []
    for b in (make_bodywork, make_mirrors, make_spoiler, make_floor_splitter, make_driver):
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
    write_glb(out_path, list(groups.values()), root_name="StockBody")
    print(f"total {total} triangles -> {out_path}")


if __name__ == "__main__":
    main()
