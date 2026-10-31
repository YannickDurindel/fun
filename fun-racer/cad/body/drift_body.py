#!/usr/bin/env python3
"""Parametric drift car body (a generic front-engine, rear-drive two-door coupe: long bonnet,
cabin set back, short boot with a ducktail, bolt-on box overfenders round a wide track, a deep
front bumper with a big mouth and lip, a wing on tall stands, a side-exit exhaust; no make or
brand), modelled with build123d like ``touring_body.py``. Materials:
scenes/car/drift_body_visual.tscn.

Regenerate the Godot asset with one command (from the repo root):

    .venv/bin/python cad/body/drift_body.py     # -> assets/car/drift/body.glb

Then re-import in Godot: ``tools/bin/godot --headless --path . --import``.
``--out PATH`` writes the GLB somewhere else.

Frame: same as ``f1_body.py``: CAD x = backward, y = right, z = up (Godot car-local:
forward = -Z, up = +Y, right = +X). The origin is at axle height, ground at z = -0.36.

Dimensions: length 4.50 m (lip included), width 2.02 m over the overfenders (1.76 m body),
roof 1.30 m above the ground, wheelbase 2.60 m: front axle x = -1.30, rear x = +1.30.

Wheels: none here. The car reuses the F1 wheel assets (front R 0.33 m, rear R 0.36 m) at the
centres the game must use (Godot car-local, like ``Car.WHEEL_OFFSETS``): front
(+-0.84, 0, -1.30), rear (+-0.84, 0, +1.30).

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
OUT_PATH = REPO / "assets" / "car" / "drift" / "body.glb"

GROUND_Z = -0.36
FLOOR_BOTTOM_Z = -0.27  # 9 cm ride height
FRONT_AXLE_X, REAR_AXLE_X = -1.30, 1.30
NOSE_X, TAIL_X = -2.15, 2.25
FLARE_Y, FLARE_W = 0.86, 0.30
HALF_WIDTH = FLARE_Y + 0.5 * FLARE_W
FRONT_TYRE_R, REAR_TYRE_R = 0.33, 0.36
ARCH_CLEARANCE = 0.04
ARCH_Y0 = 0.64        # the arches are cut from here outward (inside the tyres' inner faces)
RW_HALF_SPAN = 0.80
ROOF_Z = 0.94

TESS_TOL = 0.0015
TESS_ANG = 0.18

MATERIALS = {
    "Livery": Material("Livery", (0.42, 0.05, 0.55, 1.0), 0.30, 0.28),
    "LiveryWhite": Material("LiveryWhite", (0.90, 0.90, 0.88, 1.0), 0.05, 0.30),
    "Accent": Material("Accent", (0.02, 0.78, 0.85, 1.0), 0.10, 0.30),
    "Carbon": Material("Carbon", (0.030, 0.031, 0.034, 1.0), 0.20, 0.30),
    "Metal": Material("Metal", (0.80, 0.80, 0.82, 1.0), 1.0, 0.12),
    "Helmet": Material("Helmet", (0.95, 0.95, 0.95, 1.0), 0.05, 0.22),
    "Visor": Material("Visor", (0.02, 0.02, 0.03, 1.0), 0.6, 0.08),
    "Light": Material("Light", (0.6, 0.0, 0.0, 1.0), 0.0, 0.4, emissive=(1.0, 0.05, 0.03)),
    "Glass": Material("Glass", (0.05, 0.06, 0.07, 1.0), 0.0, 0.05),
    "Headlight": Material("Headlight", (0.9, 0.9, 0.85, 1.0), 0.0, 0.3, emissive=(1.0, 0.96, 0.88)),
}

# Lower body: deep bumper, a long bonnet rising gently to the cowl, doors, a short high boot.
HULL = [
    #       x,     width, z_bot,  z_top
    Section(NOSE_X, 1.550, -0.220, 0.080, n_top=2.6, n_bot=3.0, taper=0.88),
    Section(-2.050, 1.740, -0.262, 0.220, n_top=3.4, n_bot=4.0, taper=0.88),
    Section(-1.700, 1.760, -0.270, 0.330, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(-1.000, 1.760, -0.270, 0.390, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(-0.500, 1.760, -0.270, 0.420, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(0.300, 1.760, -0.270, 0.440, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(1.200, 1.760, -0.270, 0.470, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(1.800, 1.740, -0.260, 0.500, n_top=4.0, n_bot=5.0, taper=0.90),
    Section(2.150, 1.680, -0.220, 0.505, n_top=3.6, n_bot=4.0, taper=0.90),
    Section(TAIL_X, 1.550, -0.160, 0.470, n_top=3.0, n_bot=3.0, taper=0.88),
]
# Greenhouse: a raked windscreen, a short roof, a sloping rear window down to the boot.
CABIN = [
    Section(-0.550, 1.500, 0.380, 0.440, n_top=2.6, n_bot=4.0, taper=0.80),
    Section(-0.150, 1.480, 0.200, 0.780, n_top=2.8, n_bot=4.0, taper=0.78),
    Section(0.300, 1.420, 0.100, ROOF_Z, n_top=3.2, n_bot=4.0, taper=0.76),
    Section(0.900, 1.380, 0.100, ROOF_Z - 0.01, n_top=3.2, n_bot=4.0, taper=0.76),
    Section(1.400, 1.320, 0.300, 0.720, n_top=3.0, n_bot=4.0, taper=0.78),
    Section(1.720, 1.280, 0.450, 0.550, n_top=2.6, n_bot=4.0, taper=0.80),
]
GLASS_X0, GLASS_X1 = -0.53, 1.62
GLASS_Z0, GLASS_Z1 = 0.520, 0.900


def overfender(axle_x: float, top: float) -> list[Section]:
    """Bolt-on box overfender: a squared bulge round one wheel, its inner half in the body."""
    w, y = FLARE_W, FLARE_Y
    return [
        Section(axle_x - 0.66, w * 0.5, -0.255, 0.100, y_center=y - 0.03, n_top=3.0, n_bot=4.0, taper=0.80),
        Section(axle_x - 0.50, w, -0.262, top - 0.05, y_center=y, n_top=4.0, n_bot=4.5, taper=0.82),
        Section(axle_x, w, -0.262, top, y_center=y, n_top=4.0, n_bot=4.5, taper=0.82),
        Section(axle_x + 0.50, w, -0.262, top - 0.05, y_center=y, n_top=4.0, n_bot=4.5, taper=0.82),
        Section(axle_x + 0.66, w * 0.5, -0.255, 0.100, y_center=y - 0.03, n_top=3.0, n_bot=4.0, taper=0.80),
    ]


def arch_cutter(axle_x: float, tyre_r: float, y0: float, extra: float = 0.0) -> Solid:
    return Solid.make_cylinder(tyre_r + ARCH_CLEARANCE + extra, HALF_WIDTH + 0.2 - y0,
                               Plane(origin=(axle_x, y0, 0.0), z_dir=(0, 1, 0)))


def make_bodywork() -> list[PartSpec]:
    body = loft(HULL)
    cabin = loft(CABIN)   # not fused: its lower half is buried in the hull
    for axle_x, top in ((FRONT_AXLE_X, 0.45), (REAR_AXLE_X, 0.49)):
        for side in both_sides(loft(overfender(axle_x, top))):
            body = body + side
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        for c in both_sides(arch_cutter(axle_x, r, ARCH_Y0)):
            body = body - c
    out: list[PartSpec] = []

    # Glazing: windscreen, side windows and the rear window in one band.
    cabin, glass = split(cabin, box(0.5 * (GLASS_X0 + GLASS_X1), 0, 0.5 * (GLASS_Z0 + GLASS_Z1),
                                  GLASS_X1 - GLASS_X0, 1.70, GLASS_Z1 - GLASS_Z0))
    # Black frames: the belt line, a B pillar at the back of the long door, the C pillars.
    frame = mirrored_box(0.55, 0.66, GLASS_Z0 + 0.012, 2.4, 0.12, 0.026)
    frame = frame + mirrored_box(0.62, 0.66, 0.72, 0.09, 0.14, 0.40)
    glass, frames = split(glass, frame)
    out += [PartSpec("glazing", glass, "Glass"), PartSpec("window_frames", frames, "Carbon")]

    # Front: a big mouth in the bumper, a slim grille above it, narrow headlights.
    body, mouth = split(body, box(-2.14, 0, -0.100, 0.24, 1.20, 0.160))
    body, grille = split(body, box(-2.14, 0, 0.100, 0.20, 0.70, 0.050))
    out += [PartSpec("mouth", mouth, "Carbon"), PartSpec("grille", grille, "Carbon")]
    body, lamps = split(body, mirrored_box(-2.07, 0.62, 0.180, 0.24, 0.34, 0.060))
    out.append(PartSpec("headlights", lamps, "Headlight"))
    # A carbon bonnet with a vent over the engine.
    body, bonnet = split(body, box(-1.25, 0, 0.42, 1.30, 1.10, 0.14))
    bonnet, vent = split(bonnet, box(-1.35, 0, 0.42, 0.50, 0.56, 0.14))
    out += [PartSpec("bonnet", bonnet, "Carbon"), PartSpec("bonnet_vent", vent, "Metal")]

    # Tail: wide light clusters, a black lower bumper.
    body, tail = split(body, mirrored_box(TAIL_X, 0.58, 0.340, 0.12, 0.44, 0.080))
    out.append(PartSpec("tail_lights", tail, "Light"))
    body, rear_panel = split(body, box(TAIL_X, 0, -0.140, 0.16, 2.2, 0.12))
    out.append(PartSpec("rear_panel", rear_panel, "Carbon"))
    # Ducktail: a small kicked-up lip on the boot lid.
    duck = xz_plate([(1.95, 0.49), (2.24, 0.48), (2.27, 0.55), (2.20, 0.54)], -0.70, 1.40)
    out.append(PartSpec("ducktail", duck, "Carbon", False))

    # Black sills; livery: a white band along the doors, an accent stripe below it.
    body, sills = split(body, mirrored_box(0.0, 0.92, -0.225, 4.6, 0.30, 0.09))
    out.append(PartSpec("sills", sills, "Carbon"))
    body, band = split(body, mirrored_box(0.0, 1.00, 0.180, 4.6, 0.40, 0.12))
    body, stripe = split(body, mirrored_box(0.0, 1.00, 0.060, 4.6, 0.40, 0.045))
    cabin, roof_st = split(cabin, mirrored_box(0.55, 0.30, ROOF_Z + 0.02, 1.20, 0.10, 0.10))
    out.append(PartSpec("cabin", cabin, "Livery"))
    out += [PartSpec("door_band", band, "LiveryWhite"), PartSpec("flank_stripe", stripe, "Accent"),
            PartSpec("roof_stripes", roof_st, "Accent")]

    # Wheel-arch liners.
    liners = None
    for axle_x, r in ((FRONT_AXLE_X, FRONT_TYRE_R), (REAR_AXLE_X, REAR_TYRE_R)):
        ring = arch_cutter(axle_x, r, ARCH_Y0 - 0.05, 0.035) - arch_cutter(axle_x, r, ARCH_Y0)
        ring = ring + mirror(ring, about=Plane.XZ)
        liners = ring if liners is None else liners + ring
    body, liner = split(body, liners)
    out.append(PartSpec("arch_liners", liner, "Carbon"))

    # Shut lines: doors, boot lid; the overfenders' seams on the body.
    g = 0.006
    grooves = mirrored_box(-0.60, 0.92, 0.10, g, 0.3, 0.60)
    grooves = grooves + mirrored_box(0.68, 0.92, 0.10, g, 0.3, 0.60)
    grooves = grooves + box(1.78, 0, 0.50, g, 1.4, 0.2)
    body, gr = split(body, grooves)
    out.append(PartSpec("panel_lines", gr, "Carbon"))

    out.insert(0, PartSpec("body", body, "Livery"))
    return out


def make_mirrors() -> list[PartSpec]:
    housing = loft([
        Section(-0.500, 0.130, 0.540, 0.610, y_center=0.880, n_top=2.6, n_bot=2.6, taper=0.85),
        Section(-0.410, 0.170, 0.530, 0.630, y_center=0.890, n_top=3.0, n_bot=3.0, taper=0.90),
        Section(-0.370, 0.170, 0.530, 0.630, y_center=0.890, n_top=3.0, n_bot=3.0, taper=0.90),
    ])
    housing, glass = split(housing, box(-0.365, 0.890, 0.580, 0.03, 0.15, 0.08))
    stalk = box(-0.43, 0.79, 0.535, 0.08, 0.10, 0.03)
    out = []
    for i, s in enumerate(both_sides(housing)):
        out.append(PartSpec(f"mirror{i}", s, "Livery"))
    for i, s in enumerate(both_sides(glass)):
        out.append(PartSpec(f"mirror_glass{i}", s, "Metal"))
    for i, s in enumerate(both_sides(stalk)):
        out.append(PartSpec(f"mirror_stalk{i}", s, "Carbon", False))
    return out


def make_rear_wing() -> list[PartSpec]:
    """A single-element wing on two tall straight stands from the boot lid."""
    out: list[PartSpec] = []
    main = wing_element(1.980, 0.840, 0.320, 9.0, -RW_HALF_SPAN, RW_HALF_SPAN, camber=0.07, thickness=0.11)
    out.append(PartSpec("rw_main", main, "Carbon", surface_control=False))
    gurney = box(2.292, 0, 0.895, 0.006, 2 * RW_HALF_SPAN, 0.030)
    out.append(PartSpec("rw_gurney", gurney, "Accent", False))
    endplate = xz_plate([(1.94, 0.76), (2.32, 0.76), (2.32, 0.96), (2.02, 0.96)], RW_HALF_SPAN, 0.012)
    endplate = try_fillet(endplate, endplate.edges().filter_by(Axis.Y), 0.03)
    for j, s in enumerate(both_sides(endplate)):
        out.append(PartSpec(f"rw_endplate{j}", s, "Carbon", surface_control=False))
    stand = xz_plate([(2.02, 0.48), (2.14, 0.48), (2.18, 0.84), (2.06, 0.84)], 0.45, 0.014)
    for j, s in enumerate(both_sides(stand)):
        out.append(PartSpec(f"rw_stand{j}", s, "Carbon", False))
    return out


def make_underbody() -> list[PartSpec]:
    out: list[PartSpec] = []
    half = [(-1.95, 0.0), (-1.95, 0.64), (2.05, 0.64), (2.05, 0.0)]
    outline = half + [(x, -y) for x, y in reversed(half[1:-1])]
    out.append(PartSpec("floor", xy_plate(outline, FLOOR_BOTTOM_Z, 0.02), "Carbon", False))
    # A wide front lip splitter standing proud of the bumper.
    split_half = [(-2.26, 0.0), (-2.26, 0.74), (-2.18, 0.86), (-1.95, 0.88), (-1.95, 0.0)]
    split_outline = split_half + [(x, -y) for x, y in reversed(split_half[1:-1])]
    splitter = xy_plate(split_outline, FLOOR_BOTTOM_Z + 0.03, 0.018)
    splitter = try_fillet(splitter, splitter.edges().filter_by(Axis.Z), 0.03)
    out.append(PartSpec("splitter", splitter, "Carbon", False))
    for j, s in enumerate(both_sides(xy_plate([(-2.16, 0.66), (-2.02, 0.66), (-1.96, 0.88), (-2.10, 0.88)],
                                                -0.080, 0.010))):
        out.append(PartSpec(f"canard{j}", s, "Carbon", False))
    ramp = xz_plate([(1.95, FLOOR_BOTTOM_Z), (2.28, -0.170), (2.28, -0.155), (1.95, FLOOR_BOTTOM_Z + 0.018)],
                    -0.60, 1.20)
    out.append(PartSpec("diffuser", ramp, "Carbon", False))
    # Side-exit exhaust just ahead of the right rear wheel, angled down.
    exhaust = Solid.make_cylinder(0.055, 0.20, Plane(origin=(0.68, 0.80, -0.20), z_dir=(0, 1, -0.15)))
    out.append(PartSpec("exhaust", exhaust, "Metal", False))
    rain = box(TAIL_X + 0.02, 0, -0.120, 0.02, 0.12, 0.05)
    out.append(PartSpec("rain_light", rain, "Light", False))
    out.append(PartSpec("tow_front", box(NOSE_X - 0.05, 0.40, -0.12, 0.06, 0.04, 0.08), "Accent", False))
    out.append(PartSpec("tow_rear", box(TAIL_X + 0.03, -0.45, -0.10, 0.06, 0.04, 0.08), "Accent", False))
    return out


def make_driver() -> list[PartSpec]:
    """Helmet + visor behind the side window (driver seated left of the centreline)."""
    c = (0.38, -0.32, 0.660)
    shell = scale(Sphere(0.125), by=(1.12, 1.0, 1.04)).moved(Location(c))
    visor_band = box(c[0] - 0.10, c[1], c[2] + 0.005, 0.20, 0.30, 0.050)
    visor = scale(Sphere(0.1275), by=(1.12, 1.0, 1.04)).moved(Location(c)) & visor_band
    visor = visor - box(c[0] + 0.10, c[1], c[2], 0.30, 0.30, 0.30)
    return [PartSpec("helmet", shell, "Helmet"), PartSpec("visor", visor, "Visor")]


def build_parts() -> list[PartSpec]:
    parts: list[PartSpec] = []
    for b in (make_bodywork, make_mirrors, make_rear_wing, make_underbody, make_driver):
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
    write_glb(out_path, list(groups.values()), root_name="DriftBody")
    print(f"total {total} triangles -> {out_path}")


if __name__ == "__main__":
    main()
