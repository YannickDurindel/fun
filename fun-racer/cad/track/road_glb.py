"""Minimal binary glTF 2.0 writer for the road chunks.

One node per chunk, each with one mesh holding one primitive per material. Vertex
attributes: POSITION, NORMAL, TEXCOORD_0, TEXCOORD_1 (all float32), uint32 indices.
Coordinates are already in the Godot frame (x east, y up, z -north), triangles wound
counter-clockwise seen from the front (glTF convention).
"""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass
from pathlib import Path

import numpy as np


@dataclass
class Material:
    name: str
    base_color: tuple[float, float, float, float]
    roughness: float


@dataclass
class Primitive:
    material: str
    positions: np.ndarray  # (n, 3)
    normals: np.ndarray  # (n, 3)
    uv0: np.ndarray  # (n, 2)
    uv1: np.ndarray  # (n, 2)
    indices: np.ndarray  # (m, 3)


def _pad(data: bytes, fill: bytes) -> bytes:
    return data + fill * ((4 - len(data) % 4) % 4)


def write_glb(path: Path, materials: list[Material], chunks: list[tuple[str, list[Primitive]]],
              scene_name: str, generator: str) -> None:
    blob = bytearray()
    views: list[dict] = []
    accessors: list[dict] = []
    meshes: list[dict] = []
    nodes: list[dict] = []
    mat_index = {m.name: i for i, m in enumerate(materials)}

    def accessor(arr: np.ndarray, kind: str, target: int, comp: int, minmax: bool = False) -> int:
        raw = arr.tobytes()
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(raw), "target": target})
        blob.extend(_pad(raw, b"\x00"))
        acc = {"bufferView": len(views) - 1, "componentType": comp, "count": len(arr), "type": kind}
        if minmax:
            acc["min"] = arr.min(axis=0).tolist()
            acc["max"] = arr.max(axis=0).tolist()
        accessors.append(acc)
        return len(accessors) - 1

    for name, prims in chunks:
        gl_prims = []
        for p in prims:
            if len(p.indices) == 0:
                continue
            f32 = lambda a: np.ascontiguousarray(a, dtype=np.float32)  # noqa: E731
            attrs = {
                "POSITION": accessor(f32(p.positions), "VEC3", 34962, 5126, minmax=True),
                "NORMAL": accessor(f32(p.normals), "VEC3", 34962, 5126),
                "TEXCOORD_0": accessor(f32(p.uv0), "VEC2", 34962, 5126),
                "TEXCOORD_1": accessor(f32(p.uv1), "VEC2", 34962, 5126),
            }
            idx = np.ascontiguousarray(p.indices.reshape(-1), dtype=np.uint32)
            gl_prims.append({
                "attributes": attrs,
                "indices": accessor(idx, "SCALAR", 34963, 5125),
                "material": mat_index[p.material],
                "mode": 4,
            })
        meshes.append({"name": name, "primitives": gl_prims})
        nodes.append({"name": name, "mesh": len(meshes) - 1})

    gltf = {
        "asset": {"version": "2.0", "generator": generator},
        "scene": 0,
        "scenes": [{"name": scene_name, "nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": [
            {
                "name": m.name,
                "pbrMetallicRoughness": {
                    "baseColorFactor": list(m.base_color),
                    "metallicFactor": 0.0,
                    "roughnessFactor": m.roughness,
                },
            }
            for m in materials
        ],
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(blob)}],
    }
    js = _pad(json.dumps(gltf, separators=(",", ":")).encode(), b" ")
    bn = bytes(blob)
    out = bytearray(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(bn)))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js
    out += struct.pack("<II", len(bn), 0x004E4942) + bn
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(out))
