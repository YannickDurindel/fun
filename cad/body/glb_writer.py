"""Tessellate build123d shapes and write a binary glTF (GLB) with PBR materials.

build123d's own exporter writes one colour per shape; we need one named mesh
per livery material and smooth per-vertex normals, so this module tessellates
each shape itself (normals come from the B-rep triangulation, so they are
smooth inside every face and creased only on real B-rep edges) and packs the
result into a minimal glTF 2.0 container.
"""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from build123d import Shape
from OCP.BRep import BRep_Tool
from OCP.BRepLib import BRepLib_ToolTriangulatedShape
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.TopAbs import TopAbs_Orientation
from OCP.TopLoc import TopLoc_Location
from OCP.BRepTools import BRepTools
from OCP.IMeshTools import IMeshTools_Parameters

# CAD frame (x back, y right, z up) -> Godot car-local (X right, Y up, Z back).
# Cyclic permutation: keeps handedness, so no winding flip is required.
_CAD_TO_GODOT = [1, 2, 0]


@dataclass
class Material:
    name: str
    base_color: tuple[float, float, float, float]
    metallic: float
    roughness: float
    emissive: tuple[float, float, float] = (0.0, 0.0, 0.0)


@dataclass
class MeshGroup:
    """All triangles that share one material; exported as one named node."""

    material: Material
    positions: list[np.ndarray] = field(default_factory=list)
    normals: list[np.ndarray] = field(default_factory=list)
    indices: list[np.ndarray] = field(default_factory=list)
    _count: int = 0

    def add_shape(
        self,
        shape: Shape,
        tolerance: float,
        angular_tolerance: float,
        surface_control: bool = True,
    ) -> int:
        """Tessellate ``shape`` and append it; returns the triangle count."""
        # Absolute deflection (build123d's default meshing is relative to edge
        # length). Surface-deflection control massively over-refines extruded
        # B-spline airfoils along their (ruled) span, so plates and wing
        # elements switch it off.
        params = IMeshTools_Parameters()
        params.Deflection = tolerance
        params.Angle = angular_tolerance
        params.Relative = False
        params.InParallel = True
        params.ControlSurfaceDeflection = surface_control
        BRepTools.Clean_s(shape.wrapped)
        BRepMesh_IncrementalMesh(shape.wrapped, params)

        ps, ns, ts = [], [], []
        offset = 0
        for face in shape.faces():
            loc = TopLoc_Location()
            poly = BRep_Tool.Triangulation_s(face.wrapped, loc)
            if poly is None or poly.NbTriangles() == 0:
                continue
            # Exact surface normals at every node (smooth inside each B-rep face).
            BRepLib_ToolTriangulatedShape.ComputeNormals_s(face.wrapped, poly)
            trsf = loc.Transformation()
            nb = poly.NbNodes()
            pts = np.empty((nb, 3))
            nrm = np.empty((nb, 3))
            for i in range(1, nb + 1):
                q = poly.Node(i).Transformed(trsf)
                pts[i - 1] = (q.X(), q.Y(), q.Z())
                d = poly.Normal(i).Transformed(trsf)
                nrm[i - 1] = (d.X(), d.Y(), d.Z())
            tri = np.array(
                [(t.Value(1), t.Value(2), t.Value(3)) for t in poly.Triangles()], dtype=np.int64
            ) - 1
            if face.wrapped.Orientation() == TopAbs_Orientation.TopAbs_REVERSED:
                tri = tri[:, [0, 2, 1]]
            ps.append(pts)
            ns.append(nrm)
            ts.append(tri + offset)
            offset += nb
        if not ts:
            return 0
        p = np.concatenate(ps)[:, _CAD_TO_GODOT]
        n = np.concatenate(ns)[:, _CAD_TO_GODOT]
        t = np.concatenate(ts)

        # Make vertex normals agree with the triangle winding (outward), voting
        # per vertex with the area-weighted triangle normals.
        fn = np.cross(p[t[:, 1]] - p[t[:, 0]], p[t[:, 2]] - p[t[:, 0]])
        acc = np.zeros_like(p)
        for k in range(3):
            np.add.at(acc, t[:, k], fn)
        flip = np.einsum("ij,ij->i", acc, n) < 0.0
        n[flip] *= -1.0
        # Fall back to the area-weighted face normal where OCC gave none.
        bad = np.linalg.norm(n, axis=1) < 1e-9
        n[bad] = acc[bad]
        n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)

        self.positions.append(p)
        self.normals.append(n)
        self.indices.append(t + self._count)
        self._count += len(p)
        return len(t)

    @property
    def triangle_count(self) -> int:
        return sum(len(i) for i in self.indices)


def _pad(data: bytes, fill: bytes) -> bytes:
    return data + fill * ((4 - len(data) % 4) % 4)


def write_glb(path: Path, groups: list[MeshGroup], root_name: str = "F1Body") -> None:
    groups = [g for g in groups if g.indices]
    bin_blob = bytearray()
    buffer_views: list[dict] = []
    accessors: list[dict] = []
    materials: list[dict] = []
    meshes: list[dict] = []
    nodes: list[dict] = []  # one top-level node per material

    def add_view(arr: np.ndarray, target: int) -> int:
        nonlocal bin_blob
        raw = arr.tobytes()
        offset = len(bin_blob)
        bin_blob += _pad(raw, b"\x00")
        buffer_views.append(
            {"buffer": 0, "byteOffset": offset, "byteLength": len(raw), "target": target}
        )
        return len(buffer_views) - 1

    for g in groups:
        pos = np.concatenate(g.positions).astype(np.float32)
        nrm = np.concatenate(g.normals).astype(np.float32)
        idx = np.concatenate(g.indices).astype(np.uint32).reshape(-1)

        pv = add_view(pos, 34962)
        accessors.append(
            {
                "bufferView": pv,
                "componentType": 5126,
                "count": len(pos),
                "type": "VEC3",
                "min": pos.min(axis=0).tolist(),
                "max": pos.max(axis=0).tolist(),
            }
        )
        pa = len(accessors) - 1
        nv = add_view(nrm, 34962)
        accessors.append({"bufferView": nv, "componentType": 5126, "count": len(nrm), "type": "VEC3"})
        na = len(accessors) - 1
        iv = add_view(idx, 34963)
        accessors.append({"bufferView": iv, "componentType": 5125, "count": len(idx), "type": "SCALAR"})
        ia = len(accessors) - 1

        m = g.material
        mat = {
            "name": m.name,
            "pbrMetallicRoughness": {
                "baseColorFactor": list(m.base_color),
                "metallicFactor": m.metallic,
                "roughnessFactor": m.roughness,
            },
            "doubleSided": False,
        }
        if any(m.emissive):
            mat["emissiveFactor"] = list(m.emissive)
        materials.append(mat)
        meshes.append(
            {
                "name": m.name,
                "primitives": [
                    {
                        "attributes": {"POSITION": pa, "NORMAL": na},
                        "indices": ia,
                        "material": len(materials) - 1,
                        "mode": 4,
                    }
                ],
            }
        )
        nodes.append({"name": m.name, "mesh": len(meshes) - 1})

    gltf = {
        "asset": {"version": "2.0", "generator": "fun/cad/body/f1_body.py (build123d)"},
        "scene": 0,
        "scenes": [{"name": root_name, "nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": materials,
        "accessors": accessors,
        "bufferViews": buffer_views,
        "buffers": [{"byteLength": len(bin_blob)}],
    }
    json_chunk = _pad(json.dumps(gltf, separators=(",", ":")).encode(), b" ")
    bin_chunk = bytes(bin_blob)
    total = 12 + 8 + len(json_chunk) + 8 + len(bin_chunk)
    out = bytearray()
    out += struct.pack("<III", 0x46546C67, 2, total)
    out += struct.pack("<II", len(json_chunk), 0x4E4F534A) + json_chunk
    out += struct.pack("<II", len(bin_chunk), 0x004E4942) + bin_chunk
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(out))
