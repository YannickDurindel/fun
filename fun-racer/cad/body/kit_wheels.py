"""Simple wheels for the CarKits whose tyres are not the F1 car's (rally raid, kart), modelled
with build123d and written with ``glb_writer`` like the bodies.

A wheel is modelled for a RIGHT-hand wheel in the per-wheel visual frame of
scripts/car/wheel_visual.gd: origin = wheel centre, axle along Godot X with the outer face
toward +X (Godot mirrors it with scale.x = -1 for the left wheels). In the CAD frame of the
body modules (x back, y right, z up) the axle is CAD y.

``CarKit`` swaps these meshes in for the F1 wheel meshes (``WheelVisual.use_kit_wheel``) and
draws them at their own radius; the physics keeps its ray-cast contacts.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path

from build123d import Axis, GeomType, Location, Plane, Solid

from endurance_body import PartSpec, box, try_fillet
from glb_writer import Material, MeshGroup, write_glb

TESS_TOL = 0.0012
TESS_ANG = 0.2

MATERIALS = {
    "Rubber": Material("Rubber", (0.055, 0.055, 0.06, 1.0), 0.0, 0.88),
    "Rim": Material("Rim", (0.62, 0.63, 0.66, 1.0), 0.85, 0.30),
    "RimAccent": Material("RimAccent", (0.95, 0.42, 0.05, 1.0), 0.3, 0.35),
    "Hub": Material("Hub", (0.12, 0.12, 0.13, 1.0), 0.6, 0.45),
}


@dataclass(frozen=True)
class WheelSpec:
    radius: float          # tyre outer radius (m)
    width: float           # tyre section width (m)
    rim_radius: float      # bead seat radius (m)
    shoulder: float        # tread-to-sidewall rounding (m)
    lugs: int = 0          # tread blocks round the tyre (0 = slick)
    lug_depth: float = 0.0
    holes: int = 6         # round holes in the rim face
    beadlock: bool = False

    @property
    def face(self) -> float:
        """Outer sidewall plane (CAD y)."""
        return 0.5 * self.width

    @property
    def rim_face(self) -> float:
        """Where the rim face sits (CAD y), a little inside the sidewall: the speed-blur disc."""
        return self.face - 0.02


def _cyl(r: float, y0: float, y1: float) -> Solid:
    return Solid.make_cylinder(r, y1 - y0, Plane(origin=(0.0, y0, 0.0), z_dir=(0, 1, 0)))


def build_wheel(s: WheelSpec) -> list[PartSpec]:
    out: list[PartSpec] = []
    w2 = s.face
    carcass_r = s.radius - s.lug_depth
    tyre = _cyl(carcass_r, -w2, w2) - _cyl(s.rim_radius, -w2 - 0.01, w2 + 0.01)
    outer = [e for e in tyre.edges() if e.geom_type == GeomType.CIRCLE and e.radius > s.rim_radius + 0.01]
    tyre = try_fillet(tyre, outer, s.shoulder)
    out.append(PartSpec("tyre", tyre, "Rubber"))
    # Tread: two staggered rows of chunky blocks (off-road), plus shoulder blocks.
    if s.lugs > 0:
        step = 360.0 / s.lugs
        bw = 2.0 * math.pi * carcass_r / s.lugs * 0.55
        for i in range(s.lugs):
            for row, (yc, wy) in enumerate(((-0.24 * s.width, 0.40 * s.width), (0.24 * s.width, 0.40 * s.width))):
                ang = i * step + (0.5 * step if row else 0.0)
                lug = box(0.0, yc, carcass_r + 0.5 * s.lug_depth - 0.004, bw, wy, s.lug_depth + 0.008)
                lug = lug.rotate(Axis.Y, ang)
                out.append(PartSpec(f"lug{i}_{row}", lug, "Rubber", False))
    # Rim: barrel, a dished face with round holes, the hub, and an outer lip (beadlock ring).
    barrel = _cyl(s.rim_radius, -w2 + 0.01, w2 - 0.01) - _cyl(s.rim_radius - 0.012, -w2, w2)
    out.append(PartSpec("barrel", barrel, "Rim"))
    face_y = s.rim_face
    disc = _cyl(s.rim_radius - 0.004, face_y - 0.014, face_y)
    hole_r = 0.16 * s.rim_radius
    for i in range(s.holes):
        a = 2.0 * math.pi * (i + 0.5) / s.holes
        rr = 0.62 * s.rim_radius
        c = Solid.make_cylinder(hole_r, 0.05, Plane(origin=(rr * math.cos(a), face_y - 0.03, rr * math.sin(a)),
                                                     z_dir=(0, 1, 0)))
        disc = disc - c
    out.append(PartSpec("rim_face", disc, "Rim"))
    hub = _cyl(0.24 * s.rim_radius, face_y - 0.01, face_y + 0.012)
    out.append(PartSpec("hub", hub, "Hub"))
    lip_w = 0.02 if s.beadlock else 0.008
    lip = _cyl(s.rim_radius + (0.022 if s.beadlock else 0.006), face_y - 0.002, face_y + lip_w) \
        - _cyl(s.rim_radius - 0.012, face_y - 0.01, face_y + lip_w + 0.01)
    out.append(PartSpec("lip", lip, "RimAccent" if s.beadlock else "Rim"))
    if s.beadlock:
        for i in range(16):
            a = 2.0 * math.pi * i / 16
            rr = s.rim_radius + 0.008
            bolt = Solid.make_cylinder(0.006, 0.012, Plane(origin=(rr * math.cos(a), face_y + lip_w, rr * math.sin(a)),
                                                           z_dir=(0, 1, 0)))
            out.append(PartSpec(f"bolt{i}", bolt, "Hub", False))
    # Inner face: a dark disc so the wheel is not see-through from the inside.
    out.append(PartSpec("inner", _cyl(s.rim_radius - 0.012, -w2 + 0.02, -w2 + 0.026), "Hub"))
    return out


def write_wheel(path: Path, s: WheelSpec, root_name: str) -> int:
    groups = {name: MeshGroup(mat) for name, mat in MATERIALS.items()}
    total = 0
    for p in build_wheel(s):
        if p.shape is None:
            continue
        total += groups[p.material].add_shape(p.shape, TESS_TOL, TESS_ANG, p.surface_control)
    write_glb(path, list(groups.values()), root_name=root_name)
    print(f"wheel R={s.radius} w={s.width}: {total} triangles -> {path}")
    return total


def wheel_geometry(s: WheelSpec) -> dict:
    """What CarKit hands WheelVisual.use_kit_wheel (Godot wheel frame, outer face +X)."""
    return {"radius": s.radius, "rim_radius": s.rim_radius, "rim_face_x": s.rim_face}


def spare(s: WheelSpec, at: tuple[float, float, float], axis: str) -> list[PartSpec]:
    """The wheel as body parts (a spare): centred at ``at`` (CAD), axle along CAD ``axis``."""
    out = []
    for p in build_wheel(s):
        shape = p.shape
        if axis == "x":
            shape = shape.rotate(Axis.Z, 90.0)
        elif axis == "z":
            shape = shape.rotate(Axis.X, 90.0)
        out.append(PartSpec("spare_" + p.name, shape.moved(Location(at)), p.material, p.surface_control))
    return out
