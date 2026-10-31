#!/usr/bin/env python3
"""Parametric rally car body (a generic three-door 4WD rally hatchback: short nose, tall cabin
with the roof carried to a near-vertical tailgate, box-flared arches high over long-travel
wheels, roof scoop, mud flaps behind every wheel, a wing at roof level; no make or brand),
modelled with build123d like ``touring_body.py``. Materials: scenes/car/rally_body_visual.tscn.

Regenerate the Godot assets with one command each (from the repo root):

    .venv/bin/python cad/body/rally_body.py                # -> assets/car/rally/body.glb
    .venv/bin/python cad/body/rally_body.py --rallycross   # -> assets/car/rallycross/body.glb

``--rallycross``: the rallycross car of the same family: wider arches over a wider track,
a lower stance, a big two-element wing on tall end plates, a deeper splitter and its own
livery (scenes/car/rallycross_body_visual.tscn).

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.
``--out PATH`` writes the GLB somewhere else.

Frame: same as ``f1_body.py``: CAD x = backward, y = right, z = up (Godot car-local:
forward = -Z, up = +Y, right = +X). The origin is at axle height, ground at z = -0.36.

Dimensions: length 4.05 m, width 1.95 m over the arch flares (rallycross 2.06 m), roof
1.42 m above the ground, wheelbase 2.50 m: front axle x = -1.25, rear x = +1.25. The floor is
19 cm off the ground (rallycross 15 cm) and the arches leave 7 cm over the tyres for the long
suspension travel.

Wheels: none here. The car reuses the F1 wheel assets (front R 0.33 m, rear R 0.36 m) at the
centres the game must use (Godot car-local, like ``Car.WHEEL_OFFSETS``): front
(+-0.80, 0, -1.25), rear (+-0.78, 0, +1.25); rallycross front (+-0.84, 0, -1.25), rear
(+-0.82, 0, +1.25).

Material order: the F1 body's eight first (the body scene overrides nodes by index,
``body_motion.gd`` moves Helmet + Visor, ``bot_manager.gd`` recolours Livery / LiveryWhite /
Accent / Helmet), then Glass and Headlight, as on the touring body.
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
RX = "--rallycross" in sys.argv[1:]
OUT_PATH = REPO / "assets" / "car" / ("rallycross" if RX else "rally") / "body.glb"

GROUND_Z = -0.36
FLOOR_Z = -0.21 if RX else -0.17      # bottom of the hull: 15 / 19 cm ride height
FRONT_AXLE_X, REAR_AXLE_X = -1.25, 1.25
NOSE_X, TAIL_X = -2.03, 1.97
BODY_HALF = 0.90
FLARE_Y, FLARE_W = (0.875, 0.31) if RX else (0.825, 0.30)   # flare centre and width
HALF_WIDTH = FLARE_Y + 0.5 * FLARE_W
FRONT_TYRE_R, REAR_TYRE_R = 0.33, 0.36
ARCH_CLEARANCE = 0.07
ROOF_Z = 1.06

TESS_TOL = 0.0015
TESS_ANG = 0.18

if RX:
    PAINT = {"Livery": (0.07, 0.08, 0.10, 1.0), "LiveryWhite": (0.88, 0.88, 0.86, 1.0),
             "Accent": (0.55, 0.85, 0.05, 1.0)}
else:
    PAINT = {"Livery": (0.62, 0.05, 0.06, 1.0), "LiveryWhite": (0.90, 0.90, 0.88, 1.0),
             "Accent": (0.98, 0.78, 0.05, 1.0)}
MATERIALS = {
    "Livery": Material("Livery", PAINT["Livery"], 0.30, 0.28),
    "LiveryWhite": Material("LiveryWhite", PAINT["LiveryWhite"], 0.05, 0.30),
    "Accent": Material("Accent", PAINT["Accent"], 0.10, 0.30),
    "Carbon": Material("Carbon", (0.030, 0.031, 0.034, 1.0), 0.20, 0.30),
    "Metal": Material("Metal", (0.80, 0.80, 0.82, 1.0), 1.0, 0.12),
    "Helmet": Material("Helmet", (0.95, 0.95, 0.95, 1.0), 0.05, 0.22),
    "Visor": Material("Visor", (0.02, 0.02, 0.03, 1.0), 0.6, 0.08),
    "Light": Material("Light", (0.6, 0.0, 0.0, 1.0), 0.0, 0.4, emissive=(1.0, 0.05, 0.03)),
    "Glass": Material("Glass", (0.05, 0.06, 0.07, 1.0), 0.0, 0.05),
    "Headlight": Material("Headlight", (0.9, 0.9, 0.85, 1.0), 0.0, 0.3, emissive=(1.0, 0.96, 0.88)),
}

B = FLOOR_Z
# Lower body: bumper, short bonnet, doors, a short tail under the tailgate.
HULL = [
    #       x,     width, z_bot,   z_top
    Section(NOSE_X, 1.500, B + 0.06, 0.120, n_top=2.6, n_bot=3.0, taper=0.86),
    Section(-1.950, 1.740, B + 0.015, 0.300, n_top=3.4, n_bot=4.0, taper=0.88),
    Section(-1.600, 1.800, B, 0.420, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(-1.000, 1.800, B, 0.500, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(-0.550, 1.800, B, 0.550, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(0.300, 1.800, B, 0.580, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(1.200, 1.780, B, 0.600, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(1.750, 1.760, B, 0.620, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(1.930, 1.700, B + 0.03, 0.600, n_top=3.6, n_bot=4.0, taper=0.90),
    Section(TAIL_X, 1.560, B + 0.07, 0.550, n_top=3.0, n_bot=3.0, taper=0.88),
]
# Greenhouse: a steep windscreen, a long flat roof and a near-vertical tailgate (hatchback).
CABIN = [
    Section(-0.620, 1.560, 0.500, 0.560, n_top=2.6, n_bot=4.0, taper=0.80),
    Section(-0.200, 1.560, 0.300, 0.880, n_top=2.8, n_bot=4.0, taper=0.78),
    Section(0.250, 1.520, 0.200, ROOF_Z, n_top=3.4, n_bot=4.0, taper=0.76),
    Section(1.100, 1.500, 0.200, ROOF_Z + 0.015, n_top=3.4, n_bot=4.0, taper=0.76),
    Section(1.600, 1.460, 0.400, 1.040, n_top=3.2, n_bot=4.0, taper=0.78),
    Section(1.880, 1.420, 0.560, 0.920, n_top=3.0, n_bot=4.0, taper=0.80),
]
GLASS_X0, GLASS_X1 = -0.60, 1.95   # past the tailgate: the cabin's end face is the rear window
GLASS_Z0, GLASS_Z1 = 0.635, 0.995


def flare(axle_x: float, top: float) -> list[Section]:
    """Box-flared wheel arch: a bulge round one wheel, its inner half buried in the hull."""
    w, y = FLARE_W, FLARE_Y
    return [
        Section(axle_x - 0.62, w * 0.6, B + 0.012, 0.150, y_center=y + 0.005, n_top=3.0, n_bot=4.0, taper=0.80),
        Section(axle_x - 0.46, w, B + 0.006, top - 0.04, y_center=y, n_top=3.6, n_bot=4.0, taper=0.80),
        Section(axle_x, w, B + 0.006, top, y_center=y, n_top=3.6, n_bot=4.0, taper=0.80),
        Section(axle_x + 0.46, w, B + 0.006, top - 0.04, y_center=y, n_top=3.6, n_bot=4.0, taper=0.80),
        Section(axle_x + 0.62, w * 0.6, B + 0.012, 0.150, y_center=y + 0.005, n_top=3.0, n_bot=4.0, taper=0.80),
    ]


def arch_cutter(axle_x: float, tyre_r: float, y0: float, extra: float = 0.0) -> Solid:
    return Solid.make_cylinder(tyre_r + ARCH_CLEARANCE + extra, HALF_WIDTH + 0.2 - y0,
                               Plane(origin=(axle_x, y0, 0.0), z_dir=(0, 1, 0)))


def make_bodywork() -> list[PartSpec]:
    body = loft(HULL)
    cabin = loft(CABIN)   # not fused: its lower half is buried in the hull
    for axle_x, top in ((FRONT_AXLE_X, 0.53), (REAR_AXLE_X, 0.56)):
        for side in both_sides(loft(flare(axle_x, top))):
            body = body + side
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        for c in both_sides(arch_cutter(axle_x, r, 0.52)):
            body = body - c
    out: list[PartSpec] = []

    # Glazing: windscreen, side windows and the tailgate window in one band.
    cabin, glass = split(cabin, box(0.5 * (GLASS_X0 + GLASS_X1), 0, 0.5 * (GLASS_Z0 + GLASS_Z1),
                                  GLASS_X1 - GLASS_X0, 1.70, GLASS_Z1 - GLASS_Z0))
    # Black window frames: the belt line, the long door's B pillar, the wide C pillars.
    frame = mirrored_box(0.6, 0.72, GLASS_Z0 + 0.012, 2.7, 0.12, 0.026)
    frame = frame + mirrored_box(0.55, 0.72, 0.81, 0.10, 0.14, 0.40)
    frame = frame + mirrored_box(1.42, 0.71, 0.81, 0.34, 0.14, 0.40)
    glass, frames = split(glass, frame)
    out += [PartSpec("glazing", glass, "Glass"), PartSpec("window_frames", frames, "Carbon")]

    # Front: a big open grille and a lower intake for the radiators, headlights at the corners.
    body, grille = split(body, box(-2.02, 0, 0.130, 0.20, 0.80, 0.110))
    body, intake = split(body, box(-2.02, 0, -0.050, 0.24, 1.40, 0.150))
    out += [PartSpec("grille", grille, "Carbon"), PartSpec("intake", intake, "Carbon")]
    body, lamps = split(body, mirrored_box(-1.96, 0.62, 0.240, 0.24, 0.30, 0.080))
    out.append(PartSpec("headlights", lamps, "Headlight"))
    # Bonnet: a big central vent (hot air out of the radiator) and louvres over the wheels.
    body, vents = split(body, box(-1.35, 0, 0.47, 0.42, 0.62, 0.12))
    body, louvres = split(body, mirrored_box(-1.30, 0.72, 0.50, 0.36, 0.14, 0.12))
    out += [PartSpec("bonnet_vent", vents, "Carbon"), PartSpec("bonnet_louvres", louvres, "Carbon")]

    # Tail: light clusters on the corners, a black lower panel (exhaust and diffuser).
    body, tail = split(body, mirrored_box(1.95, 0.68, 0.48, 0.12, 0.26, 0.120))
    out.append(PartSpec("tail_lights", tail, "Light"))
    body, rear_panel = split(body, box(1.97, 0, B + 0.09, 0.16, 2.2, 0.16))
    out.append(PartSpec("rear_panel", rear_panel, "Carbon"))

    # Black sills and the lower edge of the flares (stone guards).
    body, sills = split(body, mirrored_box(0.0, 0.92, B + 0.05, 4.4, 0.40, 0.10))
    out.append(PartSpec("sills", sills, "Carbon"))
    # Livery: white door (number board) and a stripe from the bonnet over the roof.
    body, panel = split(body, mirrored_box(0.05, 1.00, 0.27, 0.90, 0.40, 0.32))
    body, stripe = split(body, mirrored_box(0.0, 1.00, B + 0.14, 4.6, 0.40, 0.07))
    body, bonnet_st = split(body, box(-1.0, 0, 0.55, 2.2, 0.36, 0.20))
    cabin, roof_st = split(cabin, box(0.60, 0, ROOF_Z + 0.03, 1.40, 0.36, 0.12))
    out.append(PartSpec("cabin", cabin, "Livery"))
    out += [PartSpec("door_panel", panel, "LiveryWhite"), PartSpec("flank_stripe", stripe, "Accent"),
            PartSpec("bonnet_stripe", bonnet_st, "LiveryWhite"), PartSpec("roof_stripe", roof_st, "LiveryWhite")]

    # Wheel-arch liners: the dark inner surface of each arch.
    liners = None
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        ring = arch_cutter(axle_x, r, 0.47, 0.035) - arch_cutter(axle_x, r, 0.52)
        ring = ring + mirror(ring, about=Plane.XZ)
        liners = ring if liners is None else liners + ring
    body, liner = split(body, liners)
    out.append(PartSpec("arch_liners", liner, "Carbon"))

    # Shut lines: the long door, bonnet and tailgate.
    g = 0.006
    grooves = mirrored_box(-0.58, 0.92, 0.15, g, 0.3, 0.75)
    grooves = grooves + mirrored_box(0.62, 0.92, 0.15, g, 0.3, 0.75)
    grooves = grooves + box(-0.70, 0, 0.55, g, 1.5, 0.2)
    grooves = grooves + box(1.80, 0, 0.62, g, 1.5, 0.2)
    body, gr = split(body, grooves)
    out.append(PartSpec("panel_lines", gr, "Carbon"))

    out.insert(0, PartSpec("body", body, "Livery"))
    return out


def make_roof_scoop() -> list[PartSpec]:
    """The air scoop on the roof (cabin ventilation) with its dark mouth."""
    scoop = loft([
        Section(0.000, 0.300, ROOF_Z - 0.05, ROOF_Z + 0.010, n_top=2.6, n_bot=3.0, taper=0.85),
        Section(0.200, 0.340, ROOF_Z - 0.05, ROOF_Z + 0.090, n_top=3.0, n_bot=3.0, taper=0.85),
        Section(0.500, 0.340, ROOF_Z - 0.05, ROOF_Z + 0.090, n_top=3.0, n_bot=3.0, taper=0.85),
        Section(0.700, 0.300, ROOF_Z - 0.05, ROOF_Z + 0.040, n_top=2.6, n_bot=3.0, taper=0.85),
    ])
    scoop, mouth = split(scoop, box(0.205, 0, ROOF_Z + 0.050, 0.03, 0.26, 0.060))
    return [PartSpec("roof_scoop", scoop, "Accent"), PartSpec("scoop_mouth", mouth, "Carbon")]


def make_mirrors() -> list[PartSpec]:
    housing = loft([
        Section(-0.560, 0.140, 0.660, 0.740, y_center=0.880, n_top=2.6, n_bot=2.6, taper=0.85),
        Section(-0.460, 0.180, 0.650, 0.760, y_center=0.890, n_top=3.0, n_bot=3.0, taper=0.90),
        Section(-0.420, 0.180, 0.650, 0.760, y_center=0.890, n_top=3.0, n_bot=3.0, taper=0.90),
    ])
    housing, glass = split(housing, box(-0.415, 0.890, 0.705, 0.03, 0.16, 0.09))
    stalk = box(-0.48, 0.79, 0.655, 0.08, 0.10, 0.03)
    out = []
    for i, s in enumerate(both_sides(housing)):
        out.append(PartSpec(f"mirror{i}", s, "Livery"))
    for i, s in enumerate(both_sides(glass)):
        out.append(PartSpec(f"mirror_glass{i}", s, "Metal"))
    for i, s in enumerate(both_sides(stalk)):
        out.append(PartSpec(f"mirror_stalk{i}", s, "Carbon", False))
    return out


def make_rear_wing() -> list[PartSpec]:
    """Rally: one element at roof level over the tailgate. Rallycross: a big two-element wing
    standing higher and wider on tall end plates."""
    out: list[PartSpec] = []
    if RX:
        span = 0.84
        main = wing_element(1.700, 1.130, 0.360, 6.0, -span, span, camber=0.08, thickness=0.11)
        flap = wing_element(2.030, 1.175, 0.180, 26.0, -span, span, camber=0.07, thickness=0.09)
        out.append(PartSpec("rw_main", main, "Carbon", surface_control=False))
        out.append(PartSpec("rw_flap", flap, "Accent", surface_control=False))
        endplate = xz_plate([(1.62, 0.90), (2.24, 0.90), (2.24, 1.28), (1.76, 1.28)], span, 0.014)
        pylon = xz_plate([(1.70, 0.98), (1.86, 0.98), (1.98, 1.15), (1.84, 1.15)], 0.50, 0.016)
    else:
        span = 0.72
        main = wing_element(1.720, 1.045, 0.300, 7.0, -span, span, camber=0.07, thickness=0.11)
        out.append(PartSpec("rw_main", main, "Carbon", surface_control=False))
        gurney = box(2.010, 0, 1.090, 0.006, 2 * span, 0.030)
        out.append(PartSpec("rw_gurney", gurney, "Accent", False))
        endplate = xz_plate([(1.68, 0.96), (2.06, 0.96), (2.06, 1.13), (1.76, 1.13)], span, 0.012)
        pylon = xz_plate([(1.70, 0.93), (1.84, 0.93), (1.90, 1.06), (1.78, 1.06)], 0.42, 0.014)
    endplate = try_fillet(endplate, endplate.edges().filter_by(Axis.Y), 0.03)
    for j, s in enumerate(both_sides(endplate)):
        out.append(PartSpec(f"rw_endplate{j}", s, "Carbon", surface_control=False))
    for j, s in enumerate(both_sides(pylon)):
        out.append(PartSpec(f"rw_pylon{j}", s, "Carbon", False))
    return out


def make_underbody() -> list[PartSpec]:
    """Sump guard, splitter, mud flaps, exhaust, tow straps."""
    out: list[PartSpec] = []
    half = [(-1.85, 0.0), (-1.85, 0.62), (1.80, 0.62), (1.80, 0.0)]
    outline = half + [(x, -y) for x, y in reversed(half[1:-1])]
    out.append(PartSpec("sump_guard", xy_plate(outline, B - 0.012, 0.02), "Metal", False))
    reach = 0.16 if RX else 0.08
    split_half = [(NOSE_X - reach, 0.0), (NOSE_X - reach, 0.70), (NOSE_X - reach + 0.08, 0.80),
                  (-1.80, 0.82), (-1.80, 0.0)]
    split_outline = split_half + [(x, -y) for x, y in reversed(split_half[1:-1])]
    splitter = xy_plate(split_outline, B + 0.02, 0.016)
    splitter = try_fillet(splitter, splitter.edges().filter_by(Axis.Z), 0.03)
    out.append(PartSpec("splitter", splitter, "Carbon", False))
    # Mud flaps: rubber sheets behind every wheel, hanging to a few cm off the ground.
    flap_bot = GROUND_Z + 0.06
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        x = axle_x + r + 0.12
        flap = box(x, HALF_WIDTH - 0.17, 0.5 * (flap_bot + B + 0.10), 0.010, 0.30, B + 0.10 - flap_bot)
        for j, s in enumerate(both_sides(flap)):
            out.append(PartSpec(f"mud_flap{axle_x:+.0f}{j}", s, "LiveryWhite" if RX else "Accent", False))
    exhaust = Solid.make_cylinder(0.050, 0.18, Plane(origin=(TAIL_X - 0.12, 0.55, B + 0.07), z_dir=(1, 0, 0)))
    out.append(PartSpec("exhaust", exhaust, "Metal", False))
    rain = box(TAIL_X + 0.01, 0, 0.38, 0.02, 0.12, 0.05)
    out.append(PartSpec("rain_light", rain, "Light", False))
    for x in (NOSE_X - 0.02, TAIL_X + 0.01):   # tow straps
        out.append(PartSpec(f"tow{x:+.1f}", box(x, -0.45, B + 0.12, 0.03, 0.05, 0.10), "Accent", False))
    return out


def make_driver() -> list[PartSpec]:
    """Helmet + visor behind the side window (driver seated left of the centreline)."""
    c = (0.38, -0.36, 0.800)
    shell = scale(Sphere(0.125), by=(1.12, 1.0, 1.04)).moved(Location(c))
    visor_band = box(c[0] - 0.10, c[1], c[2] + 0.005, 0.20, 0.30, 0.050)
    visor = scale(Sphere(0.1275), by=(1.12, 1.0, 1.04)).moved(Location(c)) & visor_band
    visor = visor - box(c[0] + 0.10, c[1], c[2], 0.30, 0.30, 0.30)
    return [PartSpec("helmet", shell, "Helmet"), PartSpec("visor", visor, "Visor")]


def build_parts() -> list[PartSpec]:
    parts: list[PartSpec] = []
    for b in (make_bodywork, make_roof_scoop, make_mirrors, make_rear_wing, make_underbody, make_driver):
        print(f"building {b.__name__} ...")
        parts.extend(b())
    return parts


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=OUT_PATH)
    ap.add_argument("--rallycross", action="store_true", help="the rallycross variant")
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
    write_glb(out_path, list(groups.values()), root_name="RallycrossBody" if RX else "RallyBody")
    print(f"total {total} triangles -> {out_path}")


if __name__ == "__main__":
    main()
