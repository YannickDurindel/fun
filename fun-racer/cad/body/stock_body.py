#!/usr/bin/env python3
"""Parametric stock car body (a generic modern American oval racer in the NASCAR mould: a boxy
notchback with a tall upright greenhouse, a steep rear window over a flat deck lid, a blunt
front fascia over a wide splitter, flat sides with squared-off arch flares, a tall blade
spoiler across the whole deck edge, big number boards on the doors and the roof; no make, no
manufacturer face, no brand), modelled with build123d like ``touring_body.py``.
Materials: the body scene scenes/car/stock_body_visual.tscn.

Regenerate the Godot asset with one command (from the repo root):

    .venv/bin/python cad/body/stock_body.py     # -> assets/car/stock/body.glb

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.
``--out PATH`` writes the GLB somewhere else.

Frame: same as ``f1_body.py``: CAD x = backward, y = right, z = up (Godot car-local:
forward = -Z, up = +Y, right = +X). The origin is at axle height, ground at z = -0.36.

Dimensions: length 4.98 m (splitter included), width 1.96 m, roof 1.33 m above the ground,
deck lid 1.00 m, bonnet nose 0.70 m, wheelbase 2.80 m: front axle x = -1.40, rear x = +1.40.

Wheels: none here. The car reuses the F1 wheel assets (front R 0.33 m, rear R 0.36 m) at
the centres the game must use (Godot car-local, like ``Car.WHEEL_OFFSETS``): front
(+-0.80, 0, -1.40), rear (+-0.78, 0, +1.40). The arches are cut for those with 4 cm clearance.

Material order: as ``touring_body.py`` (the F1 body's eight, then Glass and Headlight), then
Number (the matt black race numbers).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from build123d import Axis, Location, Plane, Solid, Sphere, mirror, scale

sys.path.insert(0, str(Path(__file__).resolve().parent))
from endurance_body import (  # noqa: E402
    PartSpec, both_sides, box, loft, mirrored_box, split, try_fillet, xy_plate, xz_plate,
)
from glb_writer import Material, MeshGroup, write_glb  # noqa: E402
from profiles import Section  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
OUT_PATH = REPO / "assets" / "car" / "stock" / "body.glb"

GROUND_Z = -0.36
FLOOR_BOTTOM_Z = -0.28  # 8 cm ride height
FRONT_AXLE_X, REAR_AXLE_X = -1.40, 1.40
NOSE_X, TAIL_X = -2.44, 2.42
HALF_WIDTH = 0.98
FRONT_TYRE_R, REAR_TYRE_R = 0.33, 0.36
ARCH_CLEARANCE = 0.04
DECK_Z = 0.640          # flat deck lid, 1.00 m off the ground
ROOF_Z = 0.970          # 1.33 m off the ground
RACE_NUMBER = "24"

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
    "Number": Material("Number", (0.015, 0.015, 0.018, 1.0), 0.0, 0.55),
}

# Lower body: a blunt, near-vertical front fascia, a broad bonnet rising gently to the
# windscreen, flat slab sides and a flat deck lid ending in a squared-off tail panel.
_BOX = dict(n_top=9.0, n_bot=6.0, taper=0.94)
HULL = [
    #       x,     width, z_bot,  z_top
    Section(-2.440, 1.780, -0.180, 0.250, n_top=5.0, n_bot=4.0, taper=0.92),
    Section(-2.400, 1.900, -0.235, 0.315, n_top=7.0, n_bot=5.0, taper=0.93),
    Section(-2.250, 1.950, -0.260, 0.365, **_BOX),
    Section(-1.800, 1.955, -0.270, 0.430, **_BOX),
    Section(-1.300, 1.955, -0.275, 0.490, **_BOX),
    Section(-0.800, 1.955, -0.275, 0.560, **_BOX),
    Section(-0.200, 1.955, -0.275, 0.600, **_BOX),
    Section(0.700, 1.955, -0.275, 0.620, **_BOX),
    Section(1.500, 1.955, -0.275, DECK_Z, **_BOX),
    Section(2.250, 1.950, -0.270, DECK_Z, **_BOX),
    Section(2.380, 1.920, -0.240, DECK_Z - 0.005, n_top=7.0, n_bot=5.0, taper=0.94),
    Section(2.420, 1.860, -0.200, DECK_Z - 0.020, n_top=5.0, n_bot=4.0, taper=0.93),
]
# Greenhouse: a windscreen at about 30 degrees, a long flat roof and a steep rear window down
# onto the deck (a notchback, not a fastback). Its lower part is buried in the hull; the
# belt line is where it leaves the hull.
_GH = dict(n_top=5.5, n_bot=4.0, taper=0.84, z_split=0.50)
CABIN = [
    Section(-0.950, 1.600, 0.300, 0.570, **_GH),
    Section(-0.850, 1.600, 0.300, 0.620, **_GH),
    Section(-0.550, 1.590, 0.300, 0.790, **_GH),
    Section(-0.280, 1.580, 0.300, 0.935, **_GH),
    Section(-0.100, 1.570, 0.300, ROOF_Z - 0.006, **_GH),
    Section(0.400, 1.570, 0.300, ROOF_Z, **_GH),
    Section(0.850, 1.570, 0.300, ROOF_Z - 0.010, **_GH),
    Section(1.020, 1.580, 0.300, 0.890, **_GH),
    Section(1.230, 1.590, 0.300, 0.720, **_GH),
    Section(1.360, 1.600, 0.300, 0.640, **_GH),
    Section(1.420, 1.600, 0.300, 0.600, **_GH),
]
GLASS_X0, GLASS_X1 = -0.84, 1.30
GLASS_Z0, GLASS_Z1 = 0.655, 0.900

# Seven-segment race numbers: segment -> (u centre, v centre, du, dv) in glyph units (width 1,
# height 2, stroke T), u to the reader's right and v up.
_T = 0.24
_SEG = {
    "a": (0.0, 1.0 - _T / 2, 1.0, _T), "d": (0.0, -1.0 + _T / 2, 1.0, _T), "g": (0.0, 0.0, 1.0, _T),
    "f": (-0.5 + _T / 2, 0.5, _T, 1.0 + _T), "b": (0.5 - _T / 2, 0.5, _T, 1.0 + _T),
    "e": (-0.5 + _T / 2, -0.5, _T, 1.0 + _T), "c": (0.5 - _T / 2, -0.5, _T, 1.0 + _T),
}
_DIGITS = {"0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd", "4": "fgbc", "5": "afgcd",
           "6": "afgedc", "7": "abc", "8": "abcdefg", "9": "abcdfg"}


def number_rects(text: str, height: float, gap: float) -> list[tuple[float, float, float, float]]:
    """The segments of ``text`` as (u, v, du, dv) rectangles, centred on (0, 0)."""
    k = height / 2.0          # glyph units -> metres (glyph height 2)
    pitch = k + gap
    out = []
    for i, ch in enumerate(text):
        u0 = (i - (len(text) - 1) / 2.0) * pitch
        for s in _DIGITS[ch]:
            u, v, du, dv = _SEG[s]
            out.append((u0 + u * k, v * k, du * k, dv * k))
    return out


def door_number(x0: float, z0: float, sgn: int):
    """A cutter for the door number on one side, readable from that side (the reader's right
    is forward on the right flank and backward on the left one)."""
    ux = -1.0 if sgn > 0 else 1.0
    cut = None
    for u, v, du, dv in number_rects(RACE_NUMBER, 0.46, 0.09):
        b = box(x0 + ux * u, sgn * 1.0, z0 + v, du, 0.30, dv)
        cut = b if cut is None else cut + b
    return cut


def roof_number(x0: float):
    """The roof number, read from the car's right (the outside of an oval, the grandstands):
    the reader's right is forward, up is to the car's left."""
    cut = None
    for u, v, du, dv in number_rects(RACE_NUMBER, 0.62, 0.07):
        b = box(x0 - u, -v, ROOF_Z, du, dv, 0.16)
        cut = b if cut is None else cut + b
    return cut


def flare(axle_x: float, top: float) -> list[Section]:
    """A squared-off fender flare round one wheel: flat-topped, slab-sided, its inner half
    buried in the hull."""
    sq = dict(y_center=0.885, n_top=7.0, n_bot=5.0, taper=0.88)
    return [
        Section(axle_x - 0.66, 0.120, -0.255, 0.120, **sq),
        Section(axle_x - 0.52, 0.205, -0.262, top - 0.02, **sq),
        Section(axle_x, 0.210, -0.262, top, **sq),
        Section(axle_x + 0.52, 0.205, -0.262, top - 0.02, **sq),
        Section(axle_x + 0.66, 0.120, -0.255, 0.120, **sq),
    ]


def arch_cutter(axle_x: float, tyre_r: float, y0: float) -> Solid:
    return Solid.make_cylinder(tyre_r + ARCH_CLEARANCE, HALF_WIDTH + 0.2 - y0,
                               Plane(origin=(axle_x, y0, 0.0), z_dir=(0, 1, 0)))


def make_bodywork() -> list[PartSpec]:
    body = loft(HULL)
    cabin = loft(CABIN)   # not fused: its lower part is buried in the hull
    for axle_x, top in ((FRONT_AXLE_X, 0.43), (REAR_AXLE_X, 0.47)):
        for side in both_sides(loft(flare(axle_x, top))):
            body = body + side
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        for c in both_sides(arch_cutter(axle_x, r, 0.55)):
            body = body - c
    out: list[PartSpec] = []

    # Glazing: windscreen, side windows and the rear window in one band.
    cabin, glass = split(cabin, box(0.5 * (GLASS_X0 + GLASS_X1), 0, 0.5 * (GLASS_Z0 + GLASS_Z1),
                                  GLASS_X1 - GLASS_X0, 1.70, GLASS_Z1 - GLASS_Z0))
    # Black frames: the belt line, the B pillar and the windscreen's A pillars.
    frame = mirrored_box(0.20, 0.74, GLASS_Z0 + 0.012, 2.3, 0.14, 0.026)
    frame = frame + mirrored_box(0.38, 0.74, 0.77, 0.08, 0.16, 0.30)
    frame = frame + mirrored_box(-0.55, 0.66, 0.77, 0.60, 0.07, 0.30)
    glass, frames = split(glass, frame)
    # Painted C pillars from the roof down to the deck (no rear side window), framing a
    # rear window narrower than the roof.
    glass, quarter = split(glass, mirrored_box(0.95, 0.70, 0.77, 0.95, 0.36, 0.34))
    out += [PartSpec("glazing", glass, "Glass"), PartSpec("window_frames", frames, "Carbon"),
            PartSpec("quarter_panels", quarter, "Livery")]

    # Front fascia: sticker grille and headlights over a full-width black intake.
    body, grille = split(body, box(-2.42, 0, 0.130, 0.12, 0.90, 0.120))
    body, intake = split(body, box(-2.42, 0, -0.110, 0.14, 1.60, 0.150))
    out += [PartSpec("grille", grille, "Carbon"), PartSpec("intake", intake, "Carbon")]
    body, lamps = split(body, mirrored_box(-2.38, 0.70, 0.215, 0.20, 0.36, 0.080))
    out.append(PartSpec("headlights", lamps, "Headlight"))
    # Bonnet louvres on either side of the centreline, and the cowl in front of the screen.
    body, vents = split(body, mirrored_box(-1.70, 0.40, 0.46, 0.36, 0.30, 0.10))
    out.append(PartSpec("bonnet_vents", vents, "Carbon"))

    # Tail: a light bar across the top of the rear panel, a black lower panel.
    body, tail = split(body, box(2.41, 0, 0.535, 0.10, 1.66, 0.070))
    out.append(PartSpec("tail_lights", tail, "Light"))
    body, rear_panel = split(body, box(2.41, 0, -0.10, 0.12, 2.2, 0.18))
    out.append(PartSpec("rear_panel", rear_panel, "Carbon"))

    # Black side skirts from arch to arch.
    body, sills = split(body, mirrored_box(0.0, 0.94, -0.230, 4.9, 0.30, 0.08))
    out.append(PartSpec("sills", sills, "Carbon"))
    # Livery: big white number boards on the doors, a yellow band along the flanks and a
    # number board on the roof, read from the grandstands above the banking.
    body, panel = split(body, mirrored_box(0.0, 1.00, 0.180, 1.20, 0.30, 0.600))
    body, stripe = split(body, mirrored_box(0.0, 1.00, -0.145, 5.0, 0.40, 0.07))
    digits = door_number(0.0, 0.185, 1) + door_number(0.0, 0.185, -1)
    panel, door_digits = split(panel, digits)
    cabin, roof_board = split(cabin, box(0.32, 0, ROOF_Z, 0.80, 0.98, 0.16))
    roof_board, roof_digits = split(roof_board, roof_number(0.32))
    cabin, flaps = split(cabin, mirrored_box(0.80, 0.30, ROOF_Z, 0.10, 0.24, 0.16))
    out.append(PartSpec("cabin", cabin, "Livery"))
    out += [PartSpec("door_number", panel, "LiveryWhite"), PartSpec("door_digits", door_digits, "Number"),
            PartSpec("flank_band", stripe, "Accent"), PartSpec("roof_number", roof_board, "LiveryWhite"),
            PartSpec("roof_digits", roof_digits, "Number"), PartSpec("roof_flaps", flaps, "Carbon")]

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
    grooves = mirrored_box(-0.68, 0.97, 0.15, g, 0.3, 0.76)
    grooves = grooves + mirrored_box(0.68, 0.97, 0.15, g, 0.3, 0.76)
    grooves = grooves + box(-0.92, 0, 0.56, g, 1.5, 0.2)
    grooves = grooves + box(1.55, 0, DECK_Z, g, 1.5, 0.2)
    body, gr = split(body, grooves)
    out.append(PartSpec("panel_lines", gr, "Carbon"))

    out.insert(0, PartSpec("body", body, "Livery"))
    return out


def make_mirrors() -> list[PartSpec]:
    housing = loft([
        Section(-0.640, 0.120, 0.660, 0.730, y_center=0.880, n_top=2.6, n_bot=2.6, taper=0.85),
        Section(-0.550, 0.150, 0.650, 0.750, y_center=0.890, n_top=3.0, n_bot=3.0, taper=0.90),
        Section(-0.520, 0.150, 0.650, 0.750, y_center=0.890, n_top=3.0, n_bot=3.0, taper=0.90),
    ])
    housing, glass = split(housing, box(-0.515, 0.890, 0.700, 0.03, 0.13, 0.08))
    stalk = box(-0.57, 0.80, 0.665, 0.07, 0.10, 0.03)
    out = []
    for i, s in enumerate(both_sides(housing)):
        out.append(PartSpec(f"mirror{i}", s, "Carbon"))
    for i, s in enumerate(both_sides(glass)):
        out.append(PartSpec(f"mirror_glass{i}", s, "Metal"))
    for i, s in enumerate(both_sides(stalk)):
        out.append(PartSpec(f"mirror_stalk{i}", s, "Carbon", False))
    return out


def make_spoiler() -> list[PartSpec]:
    """The stock car's spoiler: a tall flat blade across the full width of the deck edge,
    leaning back a little, on triangular braces, with end plates at the deck's corners."""
    out: list[PartSpec] = []
    top = DECK_Z + 0.26
    blade = xz_plate([(2.36, DECK_Z - 0.01), (2.42, DECK_Z - 0.01), (2.47, top), (2.43, top)], -0.93, 1.86)
    out.append(PartSpec("spoiler", blade, "Carbon", surface_control=False))
    lip = box(2.452, 0, top + 0.006, 0.040, 1.86, 0.012)
    out.append(PartSpec("spoiler_lip", lip, "Accent", False))
    for y in (-0.55, 0.0, 0.55):
        brace = xz_plate([(2.12, DECK_Z), (2.38, DECK_Z), (2.43, top - 0.03)], y - 0.006, 0.012)
        out.append(PartSpec(f"spoiler_brace{y}", brace, "Carbon", False))
    end = xz_plate([(2.05, DECK_Z - 0.02), (2.44, DECK_Z - 0.02), (2.47, top), (2.40, top)], 0.925, 0.010)
    for j, s in enumerate(both_sides(end)):
        out.append(PartSpec(f"spoiler_end{j}", s, "Carbon", False))
    return out


def make_floor_splitter() -> list[PartSpec]:
    out: list[PartSpec] = []
    half = [(-2.15, 0.0), (-2.15, 0.70), (2.20, 0.70), (2.20, 0.0)]
    outline = half + [(x, -y) for x, y in reversed(half[1:-1])]
    out.append(PartSpec("floor", xy_plate(outline, FLOOR_BOTTOM_Z, 0.02), "Carbon", False))
    # A wide, flat splitter sticking out ahead of the fascia across the whole nose.
    split_half = [(-2.56, 0.0), (-2.56, 0.88), (-2.50, 0.95), (-2.10, 0.96), (-2.10, 0.0)]
    split_outline = split_half + [(x, -y) for x, y in reversed(split_half[1:-1])]
    splitter = xy_plate(split_outline, FLOOR_BOTTOM_Z, 0.022)
    splitter = try_fillet(splitter, splitter.edges().filter_by(Axis.Z), 0.02)
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
    c = (0.30, -0.34, 0.730)
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
