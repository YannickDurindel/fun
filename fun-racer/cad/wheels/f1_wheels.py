#!/usr/bin/env python3
"""Parametric F1 wheels, uprights and suspension (build123d) -> glTF binaries.

Run from the repo root:  .venv/bin/python cad/wheels/f1_wheels.py

Outputs (assets/car/):
  wheel_front.glb / wheel_rear.glb                   rotating parts: tyre, rim, nut, brake disc
  wheel_upright_front.glb / wheel_upright_rear.glb   steering, non-rotating: upright, caliper, duct
  suspension_front.glb / suspension_rear.glb         wishbones + push/pull rod (+ track/toe link,
                                                     rear driveshaft), wheel hub -> chassis

All parts are modelled for a RIGHT-hand wheel in the per-wheel visual frame (origin = wheel
centre, axle along X, outer rim face toward +X). Godot mirrors them (scale.x = -1) for the
left wheels.

CAD frame is OCCT's Z-up: +X = outboard (right), +Y = forward, +Z = up. build123d's glTF
exporter rotates this to glTF's Y-up, which gives Godot's car frame (forward = -Z).

The raw OCCT export emits one glTF primitive per B-rep face (hundreds of draw calls), so
the file is post-processed: transforms are baked, primitives are merged per material, PBR
roughness/metalness are set, and everything ends up in one mesh with one surface per
material.
"""
from __future__ import annotations

import json
import shutil
import struct
import tempfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from build123d import (
    Axis,
    Color,
    Compound,
    Cylinder,
    Ellipse,
    Plane,
    Polygon,
    Pos,
    Rectangle,
    RegularPolygon,
    Rot,
    Unit,
    Vector,
    export_gltf,
    extrude,
    fillet,
    loft,
    revolve,
)

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "assets" / "car"

# Tessellation: fine enough for smooth tyre silhouettes, coarse enough for an HD 520.
LINEAR_DEFLECTION = 0.0015  # metres
ANGULAR_DEFLECTION = 0.16  # radians (~40 segments around a revolved surface)
MAX_TRIS_PER_WHEEL = 40_000

INCH = 0.0254
RIM_DIAMETER = 18 * INCH
BEAD_R = RIM_DIAMETER / 2  # 0.2286 m

# --------------------------------------------------------------------------- materials
# name -> (sRGB colour, metallic, roughness). The mesh label of each solid is its material.
MATERIALS: dict[str, tuple[tuple[float, float, float], float, float]] = {
    "rubber": ((0.07, 0.07, 0.075), 0.0, 0.85),
    "stripe": ((0.92, 0.08, 0.06), 0.0, 0.6),  # soft-compound red sidewall band
    "rim": ((0.30, 0.30, 0.33), 0.55, 0.35),  # gunmetal forged magnesium
    "rim_lip": ((0.55, 0.56, 0.58), 0.9, 0.25),  # polished lip catches the light
    "nut": ((0.85, 0.62, 0.12), 0.9, 0.3),  # anodised gold wheel nut
    "carbon_disc": ((0.10, 0.095, 0.09), 0.0, 0.7),
    "caliper": ((0.75, 0.06, 0.05), 0.3, 0.4),
    "carbon": ((0.045, 0.045, 0.05), 0.15, 0.35),  # glossy carbon fibre
    "metal": ((0.35, 0.35, 0.37), 0.9, 0.35),  # uprights, joints, shafts
}


def srgb_to_linear(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def tag(shape, material: str):
    shape.label = material
    shape.color = Color(*MATERIALS[material][0])
    return shape


# --------------------------------------------------------------------------- primitives
def revolve_xr(points: list[tuple[float, float]], arc: float = 360.0, fillets=None):
    """Revolves a closed (x, radius) polygon about the X (axle) axis.

    fillets: optional list of (predicate(vertex)->bool, radius) applied to the 2D profile.
    """
    face = Plane.XZ * Polygon(*points, align=None)
    for pred, radius in fillets or []:
        verts = [v for v in face.vertices() if pred(v)]
        if verts:
            face = fillet(verts, radius)
    return revolve(face, Axis.X, revolution_arc=arc)


def ring(x0: float, x1: float, r0: float, r1: float):
    return revolve_xr([(x0, r0), (x1, r0), (x1, r1), (x0, r1)])


def disc_x(x0: float, length: float, radius: float):
    """Solid cylinder along +X starting at x0."""
    return Plane.YZ.offset(x0) * Cylinder(radius, length, align=None)


def tube(p0, p1, a: float, b: float | None = None):
    """Elliptic tube from p0 to p1. Major semi-axis a lies horizontal (aero wishbone section)."""
    p0, p1 = Vector(*p0), Vector(*p1)
    d = p1 - p0
    length = d.length
    d = d.normalized()
    xd = d.cross(Vector(0, 0, 1))
    if xd.length < 1e-6:
        xd = Vector(1, 0, 0)
    sec = Plane(origin=p0, x_dir=xd.normalized(), z_dir=d) * Ellipse(a, b if b else a)
    return extrude(sec, amount=length)


def ball(p, r: float):
    """Joint boss: a short cylinder along the fore-aft axis (cheap stand-in for a spherical joint)."""
    return Pos(*p) * (Plane.XZ * Cylinder(r, 2 * r))


def loft_bar(p0, p1, w0: float, t0: float, w1: float, t1: float, up=(1, 0, 0)):
    """Tapered rectangular bar from p0 to p1; t (thickness) is measured along `up`."""
    p0, p1 = Vector(*p0), Vector(*p1)
    d = (p1 - p0).normalized()
    upv = Vector(*up)
    xd = upv - d * upv.dot(d)
    s0 = Plane(origin=p0, x_dir=xd.normalized(), z_dir=d) * Rectangle(t0, w0)
    s1 = Plane(origin=p1, x_dir=xd.normalized(), z_dir=d) * Rectangle(t1, w1)
    return loft([s0, s1], ruled=True)


# --------------------------------------------------------------------------- parameters
@dataclass
class WheelSpec:
    name: str
    radius: float  # tyre outer radius
    width: float  # tyre width
    shoulder: float  # tread-to-sidewall fillet radius
    disc_r: float  # brake disc outer radius
    disc_t: float  # brake disc thickness
    chassis_x: float  # inboard pickup x in the wheel frame (chassis at |x| ~ 0.40 in car frame)
    spokes: int = 10

    @property
    def face(self) -> float:  # outer sidewall plane
        return self.width / 2

    @property
    def hub_x(self) -> float:  # hub mounting face
        return self.face - 0.075

    @property
    def disc_x(self) -> float:  # brake disc centre plane
        return -self.face + 0.12

    @property
    def upright_x(self) -> float:  # upright / ball-joint plane (inside the rim barrel)
        return -self.face + 0.035


FRONT = WheelSpec("front", radius=0.33, width=0.30, shoulder=0.065, disc_r=0.139, disc_t=0.032,
                  chassis_x=0.40 - 0.80)
REAR = WheelSpec("rear", radius=0.36, width=0.38, shoulder=0.075, disc_r=0.133, disc_t=0.028,
                 chassis_x=0.40 - 0.78)


# --------------------------------------------------------------------------- rotating wheel
def build_tyre(s: WheelSpec) -> list:
    w2, R = s.face, s.radius
    prof = [(-w2, BEAD_R), (w2, BEAD_R), (w2, R), (-w2, R)]
    tyre = revolve_xr(prof, fillets=[
        (lambda v: v.Z > (BEAD_R + R) / 2, s.shoulder),  # rounded shoulders
        (lambda v: v.Z < (BEAD_R + R) / 2, 0.012),  # bead
    ])
    parts = [tag(tyre, "rubber")]
    # Sidewall colour band on both sidewalls, in the flat part of the sidewall.
    r0 = BEAD_R + 0.024
    for sign in (1, -1):
        x0 = sign * w2
        band = ring(min(x0, x0 + sign * 0.0025), max(x0, x0 + sign * 0.0025), r0, r0 + 0.011)
        parts.append(tag(band, "stripe"))
    return parts


def build_rim(s: WheelSpec) -> list:
    f = s.face
    barrel_r = BEAD_R - 0.012
    parts = []
    # Barrel (seats the tyre beads) and polished outer lip.
    parts.append(tag(ring(-f + 0.012, f - 0.01, barrel_r, BEAD_R + 0.002), "rim"))
    parts.append(tag(ring(f - 0.014, f - 0.002, barrel_r - 0.006, BEAD_R + 0.007), "rim_lip"))
    parts.append(tag(ring(-f + 0.004, -f + 0.016, barrel_r, BEAD_R + 0.006), "rim"))
    # Hub centre: dished boss the spokes run into.
    hub_r = 0.072
    parts.append(tag(revolve_xr([
        (s.hub_x - 0.03, 0.0), (s.hub_x + 0.02, 0.0), (s.hub_x + 0.02, hub_r - 0.012),
        (s.hub_x + 0.005, hub_r), (s.hub_x - 0.03, hub_r)]), "rim"))
    # Multi-spoke face: each spoke runs from the hub (deep) to the lip (shallow) - a dished rim.
    for i in range(s.spokes):
        ang = 360.0 / s.spokes * i
        for side in (-1, 1):  # twin spokes
            off = side * 0.011
            p0 = (s.hub_x + 0.005, off * 0.6, hub_r - 0.01)
            p1 = (f - 0.022, off * 2.3, barrel_r - 0.004)
            bar = loft_bar(p0, p1, w0=0.02, t0=0.02, w1=0.015, t1=0.012)
            parts.append(tag(Rot(ang, 0, 0) * bar, "rim"))
    # Wheel nut (hex) + retaining pin + small cover cap.
    nut = Plane.YZ.offset(s.hub_x + 0.02) * extrude(RegularPolygon(0.032, 6), amount=0.034)
    parts.append(tag(nut, "nut"))
    parts.append(tag(disc_x(s.hub_x + 0.054, 0.012, 0.019), "nut"))
    # Brake disc (carbon) + bell connecting it to the hub.
    t = s.disc_t
    parts.append(tag(ring(s.disc_x - t / 2, s.disc_x + t / 2, 0.092, s.disc_r), "carbon_disc"))
    parts.append(tag(ring(s.disc_x - 0.004, s.hub_x - 0.02, 0.080, 0.092), "metal"))
    return parts


# --------------------------------------------------------------------------- steering upright
def build_upright(s: WheelSpec) -> list:
    ux = s.upright_x
    parts = []
    # Upright body (tall, slim, rounded) with ball-joint bosses top and bottom.
    body = loft_bar((ux, 0.0, -0.15), (ux, 0.0, 0.17), w0=0.07, t0=0.04, w1=0.05, t1=0.034)
    parts.append(tag(body, "metal"))
    parts.append(tag(ball((ux - 0.01, 0, -0.15), 0.022), "metal"))
    parts.append(tag(ball((ux - 0.01, 0, 0.17), 0.02), "metal"))
    # Stub axle carrier between upright and disc bell.
    parts.append(tag(disc_x(ux, s.disc_x - 0.02 - ux, 0.06), "metal"))
    # Brake caliper straddling the disc, rear-top (revolved arc segment).
    t = s.disc_t
    cal = revolve_xr([(s.disc_x - t / 2 - 0.016, s.disc_r - 0.05),
                      (s.disc_x + t / 2 + 0.016, s.disc_r - 0.05),
                      (s.disc_x + t / 2 + 0.016, s.disc_r + 0.018),
                      (s.disc_x - t / 2 - 0.016, s.disc_r + 0.018)], arc=55)
    parts.append(tag(Rot(20, 0, 0) * cal, "caliper"))
    # Brake duct drum (open towards the rim so the disc is visible through the spokes).
    dx0 = -s.face + 0.006
    dx1 = s.disc_x - t / 2 - 0.022
    dr = BEAD_R - 0.014  # just inside the rim barrel, so nothing shows through the spokes
    parts.append(tag(revolve_xr([(dx0, 0.07), (dx0 + 0.006, 0.07), (dx0 + 0.006, dr - 0.008),
                                 (dx1, dr - 0.008), (dx1, dr), (dx0, dr)]), "carbon"))
    # Forward-facing intake scoop feeding the drum.
    sx0, sx1 = dx0 - 0.075, dx0 + 0.02
    scoop = loft([Plane(origin=(sx0, 0.205, 0.03), x_dir=(1, 0, 0), z_dir=(0, -1, 0)) * Rectangle(0.07, 0.10),
                  Plane(origin=(sx1 - 0.005, 0.08, 0.03), x_dir=(1, 0, 0), z_dir=(0, -1, 0)) * Rectangle(0.03, 0.08)],
                 ruled=True)
    parts.append(tag(scoop, "carbon"))
    return parts


# --------------------------------------------------------------------------- suspension
def build_suspension(s: WheelSpec) -> list:
    cx = s.chassis_x
    ux = s.upright_x - 0.012
    parts = []
    lo_out = (ux, 0.0, -0.15)
    up_out = (ux, 0.0, 0.17)
    # Lower wishbone: swept A-arm, legs to front and rear chassis pickups.
    for y in (0.24, -0.12):
        parts.append(tag(tube(lo_out, (cx, y, -0.10), 0.020, 0.008), "carbon"))
        parts.append(tag(ball((cx, y, -0.10), 0.014), "metal"))
    # Upper wishbone.
    for y in (0.20, -0.10):
        parts.append(tag(tube(up_out, (cx, y, 0.14), 0.017, 0.007), "carbon"))
        parts.append(tag(ball((cx, y, 0.14), 0.013), "metal"))
    if s is FRONT:
        # Push rod: lower wishbone outer end up to the rocker inside the monocoque.
        parts.append(tag(tube((ux - 0.02, 0.0, -0.125), (cx + 0.01, 0.03, 0.27), 0.012), "carbon"))
        # Track rod (steering) slightly ahead of the axle.
        parts.append(tag(tube((ux, 0.11, 0.035), (cx, 0.12, 0.05), 0.014, 0.007), "carbon"))
    else:
        # Pull rod: upper wishbone outer end down to the gearbox-mounted rocker.
        parts.append(tag(tube((ux - 0.02, 0.0, 0.15), (cx + 0.01, 0.02, -0.12), 0.012), "carbon"))
        # Toe link behind the axle.
        parts.append(tag(tube((ux, -0.11, 0.03), (cx, -0.12, 0.04), 0.014, 0.007), "carbon"))
        # Driveshaft to the gearbox with CV-joint boots.
        parts.append(tag(tube((s.upright_x, 0, 0), (cx, 0, 0), 0.018), "metal"))
        for x in (s.upright_x - 0.05, cx + 0.01):
            parts.append(tag(revolve_xr([(x, 0.0), (x + 0.04, 0.0), (x + 0.04, 0.02), (x + 0.02, 0.034),
                                         (x, 0.03)]), "rubber"))
    return parts


# --------------------------------------------------------------------------- glTF output
def _read_glb(path: Path) -> tuple[dict, bytes]:
    data = path.read_bytes()
    magic, _version, _length = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67, "not a GLB"
    off = 12
    js, binary = None, b""
    while off < len(data):
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk)
        elif ctype == 0x004E4942:
            binary = chunk
        off += 8 + clen
    return js, binary


_COMP = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}
_NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def _accessor(js: dict, binary: bytes, idx: int) -> np.ndarray:
    acc = js["accessors"][idx]
    bv = js["bufferViews"][acc["bufferView"]]
    dtype = np.dtype(_COMP[acc["componentType"]])
    n = _NCOMP[acc["type"]]
    start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = bv.get("byteStride", 0)
    if stride and stride != dtype.itemsize * n:
        elem = dtype.itemsize * n
        arr = np.lib.stride_tricks.as_strided(
            np.frombuffer(binary, np.uint8, count=stride * (acc["count"] - 1) + elem, offset=start),
            shape=(acc["count"], elem), strides=(stride, 1)).copy().view(dtype)
    else:
        arr = np.frombuffer(binary, dtype, count=acc["count"] * n, offset=start)
    return arr.reshape(acc["count"], n) if n > 1 else arr.copy()


def _node_matrix(node: dict) -> np.ndarray:
    if "matrix" in node:
        return np.array(node["matrix"], dtype=np.float64).reshape(4, 4).T
    m = np.eye(4)
    if "scale" in node:
        m = np.diag([*node["scale"], 1.0]) @ m
    if "rotation" in node:
        x, y, z, w = node["rotation"]
        r = np.array([
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ])
        rm = np.eye(4)
        rm[:3, :3] = r
        m = rm @ m
    if "translation" in node:
        t = np.eye(4)
        t[:3, 3] = node["translation"]
        m = t @ m
    return m


def merge_glb(src: Path, dst: Path, mesh_name: str) -> int:
    """Bakes node transforms, merges all primitives per material, writes a compact GLB.

    Returns the triangle count.
    """
    js, binary = _read_glb(src)
    # material index -> material key (via the mesh labels we gave each solid)
    buckets: dict[str, dict[str, list]] = {}

    def visit(ni: int, parent: np.ndarray) -> None:
        node = js["nodes"][ni]
        m = parent @ _node_matrix(node)
        if "mesh" in node:
            mesh = js["meshes"][node["mesh"]]
            key = mesh.get("name", "")
            if key not in MATERIALS:
                raise ValueError(f"mesh label {key!r} is not a known material")
            nm = np.linalg.inv(m[:3, :3]).T
            b = buckets.setdefault(key, {"pos": [], "nrm": [], "idx": [], "n": [0]})
            for prim in mesh["primitives"]:
                if prim.get("mode", 4) != 4:
                    continue
                pos = _accessor(js, binary, prim["attributes"]["POSITION"]).astype(np.float64)
                nrm = _accessor(js, binary, prim["attributes"]["NORMAL"]).astype(np.float64)
                idx = _accessor(js, binary, prim["indices"]).astype(np.uint32)
                pos = pos @ m[:3, :3].T + m[:3, 3]
                nrm = nrm @ nm.T
                nrm /= np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-12)
                b["pos"].append(pos)
                b["nrm"].append(nrm)
                b["idx"].append(idx + b["n"][0])
                b["n"][0] += len(pos)
        for c in node.get("children", []):
            visit(c, m)

    for root in js["scenes"][js.get("scene", 0)]["nodes"]:
        visit(root, np.eye(4))

    out = bytearray()
    views, accessors, materials, prims = [], [], [], []
    tris = 0

    def add_view(arr: np.ndarray, target: int) -> int:
        while len(out) % 4:
            out.append(0)
        views.append({"buffer": 0, "byteOffset": len(out), "byteLength": arr.nbytes, "target": target})
        out.extend(arr.tobytes())
        return len(views) - 1

    for key in MATERIALS:  # stable order
        if key not in buckets:
            continue
        b = buckets[key]
        pos = np.concatenate(b["pos"]).astype(np.float32)
        nrm = np.concatenate(b["nrm"]).astype(np.float32)
        idx = np.concatenate(b["idx"])
        idx = idx.astype(np.uint16) if len(pos) < 65536 else idx.astype(np.uint32)
        tris += len(idx) // 3
        a_pos = len(accessors)
        accessors.append({"bufferView": add_view(pos, 34962), "componentType": 5126, "count": len(pos),
                          "type": "VEC3", "min": pos.min(0).tolist(), "max": pos.max(0).tolist()})
        accessors.append({"bufferView": add_view(nrm, 34962), "componentType": 5126, "count": len(nrm),
                          "type": "VEC3"})
        accessors.append({"bufferView": add_view(idx, 34963),
                          "componentType": 5123 if idx.dtype == np.uint16 else 5125,
                          "count": len(idx), "type": "SCALAR"})
        rgb, metal, rough = MATERIALS[key]
        materials.append({"name": key, "pbrMetallicRoughness": {
            "baseColorFactor": [*(srgb_to_linear(c) for c in rgb), 1.0],
            "metallicFactor": metal, "roughnessFactor": rough}})
        prims.append({"attributes": {"POSITION": a_pos, "NORMAL": a_pos + 1}, "indices": a_pos + 2,
                      "material": len(materials) - 1, "mode": 4})
    while len(out) % 4:
        out.append(0)

    gltf = {
        "asset": {"version": "2.0", "generator": "cad/wheels/f1_wheels.py (build123d + OCCT)"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": mesh_name, "mesh": 0}],
        "meshes": [{"name": mesh_name, "primitives": prims}],
        "materials": materials,
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(out)}],
    }
    jbytes = json.dumps(gltf, separators=(",", ":")).encode()
    jbytes += b" " * (-len(jbytes) % 4)
    total = 12 + 8 + len(jbytes) + 8 + len(out)
    with open(dst, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, total))
        fh.write(struct.pack("<II", len(jbytes), 0x4E4F534A))
        fh.write(jbytes)
        fh.write(struct.pack("<II", len(out), 0x004E4942))
        fh.write(out)
    return tris


def export(parts: list, name: str, out_dir: Path) -> int:
    asm = Compound(children=parts)
    asm.label = name
    with tempfile.TemporaryDirectory() as td:
        raw = Path(td) / "raw.glb"
        if not export_gltf(asm, raw, unit=Unit.M, binary=True,
                           linear_deflection=LINEAR_DEFLECTION, angular_deflection=ANGULAR_DEFLECTION):
            raise RuntimeError(f"glTF export failed for {name}")
        tris = merge_glb(raw, out_dir / f"{name}.glb", name)
    print(f"  {name}.glb: {tris} triangles")
    return tris


def geometry(s: WheelSpec) -> dict:
    """Numbers the Godot wheel visual needs to line its nodes up with the meshes."""
    return {
        "tyre_radius": s.radius,
        "tyre_width": s.width,
        "rim_radius": BEAD_R,
        "rim_face_x": s.face - 0.016,  # just inside the lip: where the speed-blur disc sits
        "joint_x": s.upright_x - 0.012,  # outer ball joints = kingpin (steering) axis
        "chassis_x": s.chassis_x,  # inboard pickup line
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        stage = Path(td)
        for s in (FRONT, REAR):
            print(f"{s.name}: R={s.radius} m, width={s.width} m")
            total = export(build_tyre(s) + build_rim(s), f"wheel_{s.name}", stage)
            total += export(build_upright(s), f"wheel_upright_{s.name}", stage)
            total += export(build_suspension(s), f"suspension_{s.name}", stage)
            print(f"  total per {s.name} corner: {total} triangles")
            if total >= MAX_TRIS_PER_WHEEL:  # checked before anything lands in assets/
                raise SystemExit(f"{s.name} corner exceeds {MAX_TRIS_PER_WHEEL} triangles; nothing written")
        (stage / "wheel_geometry.json").write_text(
            json.dumps({s.name: geometry(s) for s in (FRONT, REAR)}, indent=2) + "\n")
        for f in stage.iterdir():
            shutil.copyfile(f, OUT_DIR / f.name)
    print(f"wrote {OUT_DIR}")


if __name__ == "__main__":
    main()
