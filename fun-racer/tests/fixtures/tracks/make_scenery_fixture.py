#!/usr/bin/env python3
"""Generates SYNTHETIC scenery files in the format the track pipeline bakes (the
`surroundings` step, tools/track/README.md; the runtime side is described in the headers of
scripts/track/scenery.gd and scripts/track/track_environment.gd), so the scenery runtime can
be tested and looked at before a track has real, baked surroundings:

    landcover.png, landcover_far.png   class ids (0 grass 1 forest 2 water 3 sand 4 urban
                                       5 farmland 6 rock 7 gravel 8 scrub 9 beach)
    scenery.glb                        chunk_<i>_<j> nodes: buildings, a grandstand, a pit building
    scenery_points.bin                 trees: float32 x, y, z, height, species
                                       (0 broadleaved 1 needleleaved 2 palm 3 bush)
    scenery.json                       grids, tree record, water bodies
    environment.json                   the look (unless --no-environment)
    landmarks.json + landmarks/tower.glb

Nothing here is real: land cover comes from noise, the "sea" is east of the lap.

Usage (python with numpy and pillow, e.g. fun-racer/.venv/bin/python):
    make_scenery_fixture.py
        -> tests/fixtures/tracks/scenery_oval/  (the test fixture: test_oval's lap + scenery)
    make_scenery_fixture.py --track assets/tracks/monaco --out /tmp/scratch/monaco [--time night]
        -> scenery for a real lap in a scratch folder; look at it with
           tools/screenshot.sh ... --track=monaco --scenery-dir=/tmp/scratch/monaco
       (never write generated scenery into assets/tracks/<id>/: the real bake goes there)
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
import struct
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
GRASS, FOREST, WATER, SAND, URBAN, FARMLAND, ROCK, GRAVEL, SCRUB, BEACH = range(10)
BROADLEAF, CONIFER, PALM, BUSH = range(4)   # species ids as the pipeline writes them
CHUNK = 400.0


# ----------------------------------------------------------------------------- noise
def _hash(ix: np.ndarray, iz: np.ndarray, seed: int) -> np.ndarray:
    h = (ix.astype(np.int64) * 374761393 + iz.astype(np.int64) * 668265263 + seed * 2147483647) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFF) / 65535.0


def noise(x: np.ndarray, z: np.ndarray, scale: float, seed: int) -> np.ndarray:
    """Smooth value noise in 0..1, the same at any resolution (near and far grids agree)."""
    u, v = x / scale, z / scale
    iu, iv = np.floor(u), np.floor(v)
    fu, fv = u - iu, v - iv
    fu, fv = fu * fu * (3 - 2 * fu), fv * fv * (3 - 2 * fv)
    a = _hash(iu, iv, seed) * (1 - fu) + _hash(iu + 1, iv, seed) * fu
    b = _hash(iu, iv + 1, seed) * (1 - fu) + _hash(iu + 1, iv + 1, seed) * fu
    return a * (1 - fv) + b * fv


def fbm(x: np.ndarray, z: np.ndarray, scale: float, seed: int) -> np.ndarray:
    return 0.6 * noise(x, z, scale, seed) + 0.3 * noise(x, z, scale / 2.3, seed + 1) + 0.1 * noise(x, z, scale / 5.1, seed + 2)


# ----------------------------------------------------------------------------- track
class Lap:
    def __init__(self, folder: Path):
        d = json.loads((folder / "track.json").read_text())
        self.pts = np.array([p["p"] for p in d["points"]], dtype=np.float64)
        self.widths = np.array([p.get("width", 13.0) for p in d["points"]], dtype=np.float64)
        self.step = float(d["step"])
        self.length = float(d["length"])
        self.start_s = float(d.get("start_s", 0.0))
        self.terrain = None
        tj = folder / "terrain.json"
        if tj.exists():
            t = json.loads(tj.read_text())
            n = t["near"]
            h = np.frombuffer((folder / n["file"]).read_bytes(), dtype="<f4").reshape(n["nz"], n["nx"])
            self.terrain = (t, h)

    def frame(self, s: float):
        """(position, forward, right) on the centreline at s."""
        n = len(self.pts)
        i = int(s / self.step) % n
        p = self.pts[i]
        fwd = self.pts[(i + 1) % n] - self.pts[(i - 1) % n]
        fwd[1] = 0.0
        fwd /= np.linalg.norm(fwd)
        right = np.array([-fwd[2], 0.0, fwd[0]])   # forward x up
        return p.copy(), fwd, right, self.widths[i]

    def distance(self, x: np.ndarray, z: np.ndarray) -> np.ndarray:
        """Distance to the centreline (m), computed on a coarse grid and interpolated."""
        pts = self.pts[:: max(1, int(6.0 / self.step))]
        flat = np.stack([x.ravel(), z.ravel()], axis=1)
        out = np.empty(len(flat))
        for a in range(0, len(flat), 20000):
            b = flat[a:a + 20000]
            d2 = (b[:, None, 0] - pts[None, :, 0]) ** 2 + (b[:, None, 1] - pts[None, :, 2]) ** 2
            out[a:a + 20000] = np.sqrt(d2.min(axis=1))
        return out.reshape(x.shape)

    def ground(self, x: float, z: float) -> float:
        """Ground height at (x, z): the baked terrain, else the nearest lap point, a bit lower."""
        if self.terrain is not None:
            t, h = self.terrain
            n = t["near"]
            u = (x - n["x0"]) / n["step"]
            v = (z - n["z0"]) / n["step"]
            if 0 <= u < n["nx"] - 1 and 0 <= v < n["nz"] - 1:
                i, j = int(u), int(v)
                fu, fv = u - i, v - j
                return float((h[j, i] * (1 - fu) + h[j, i + 1] * fu) * (1 - fv)
                             + (h[j + 1, i] * (1 - fu) + h[j + 1, i + 1] * fu) * fv)
        k = int(np.argmin((self.pts[:, 0] - x) ** 2 + (self.pts[:, 2] - z) ** 2))
        return float(self.pts[k, 1]) - 0.4


# ----------------------------------------------------------------------------- land cover
def grids(lap: Lap) -> tuple[dict, dict]:
    if lap.terrain is not None:
        t = lap.terrain[0]
        n, f = t["near"], t["far"]
        near = {"x0": n["x0"], "z0": n["z0"], "step": 2.5,
                "nx": int((n["nx"] - 1) * n["step"] / 2.5), "nz": int((n["nz"] - 1) * n["step"] / 2.5)}
        far = {"x0": f["x0"], "z0": f["z0"], "step": 50.0,
               "nx": int((f["nx"] - 1) * f["step"] / 50.0), "nz": int((f["nz"] - 1) * f["step"] / 50.0)}
        return near, far
    lo = lap.pts.min(axis=0)
    hi = lap.pts.max(axis=0)
    x0, z0 = math.floor((lo[0] - 400) / 20) * 20.0, math.floor((lo[2] - 400) / 20) * 20.0
    near = {"x0": x0, "z0": z0, "step": 2.5,
            "nx": int(math.ceil((hi[0] + 400 - x0) / 2.5)), "nz": int(math.ceil((hi[2] + 400 - z0) / 2.5))}
    fx0, fz0 = x0 - 2000.0, z0 - 2000.0
    far = {"x0": fx0, "z0": fz0, "step": 50.0,
           "nx": int(math.ceil((hi[0] + 2400 - fx0) / 50.0)), "nz": int(math.ceil((hi[2] + 2400 - fz0) / 50.0))}
    return near, far


def coast_x(lap: Lap, z: np.ndarray) -> np.ndarray:
    """The sea lies east of this wobbly line."""
    return lap.pts[:, 0].max() + 190.0 + 90.0 * (noise(z, z * 0.0, 420.0, 77) - 0.5) + 30.0 * (noise(z, z * 0.0, 90.0, 78) - 0.5)


def lake(lap: Lap) -> tuple[float, float, float, float]:
    """(cx, cz, rx, rz) of a lake west of the lap."""
    lo = lap.pts.min(axis=0)
    hi = lap.pts.max(axis=0)
    return lo[0] - 170.0, (lo[2] + hi[2]) * 0.5, 95.0, 60.0


def classify(lap: Lap, g: dict) -> np.ndarray:
    xs = g["x0"] + (np.arange(g["nx"]) + 0.5) * g["step"]
    zs = g["z0"] + (np.arange(g["nz"]) + 0.5) * g["step"]
    x, z = np.meshgrid(xs, zs)
    # Distance on a 10 m lattice, then per cell: cheap and smooth enough.
    k = max(1, int(round(10.0 / g["step"])))
    dc = lap.distance(x[::k, ::k], z[::k, ::k])
    dist = np.asarray(Image.fromarray(dc.astype(np.float32)).resize((g["nx"], g["nz"]), Image.BILINEAR), dtype=np.float32)
    cls = np.full(x.shape, GRASS, dtype=np.uint8)
    cls[(fbm(x, z, 520.0, 11) > 0.56) & (dist > 260)] = FARMLAND
    cls[(fbm(x, z, 300.0, 21) > 0.60) & (dist > 150)] = SCRUB
    cls[(fbm(x, z, 380.0, 31) > 0.54) & (dist > 55)] = FOREST
    cls[(fbm(x, z, 700.0, 41) > 0.66) & (dist > 500)] = ROCK
    town = fbm(x, z, 450.0, 51)
    cls[(town > 0.57) & (dist > 28)] = URBAN
    cls[(dist > 14) & (dist < 22) & (noise(x, z, 160.0, 61) > 0.62)] = GRAVEL
    cx = coast_x(lap, z)
    cls[(x > cx - 45) & (cls != URBAN)] = BEACH
    cls[x > cx] = WATER
    lx, lz, rx, rz = lake(lap)
    e = ((x - lx) / rx) ** 2 + ((z - lz) / rz) ** 2
    cls[(e < 1.5) & (cls != URBAN)] = SAND
    cls[e < 1.0] = WATER
    cls[dist < 13] = GRASS
    return cls


# ----------------------------------------------------------------------------- meshes
class MeshBuilder:
    """Triangles per (chunk node, material): positions, normals, uv, colour."""

    def __init__(self):
        self.prims: dict[tuple[str, str], list] = {}

    def quad(self, node: str, mat: str, a, b, c, d, normal, uv=None, tint=(1.0, 1.0, 1.0), windows=0.0):
        a, b, c, d = (np.asarray(p, dtype=np.float64) for p in (a, b, c, d))
        uv = uv or [(0, 0), (1, 0), (1, 1), (0, 1)]
        normal = np.asarray(normal, dtype=np.float64)
        normal = normal / np.linalg.norm(normal)
        verts = [a, b, c, d]
        # glTF front faces wind counter-clockwise.
        if np.dot(np.cross(b - a, c - a), normal) < 0:
            verts = [a, d, c, b]
            uv = [uv[0], uv[3], uv[2], uv[1]]
        store = self.prims.setdefault((node, mat), [])
        for i in (0, 1, 2, 0, 2, 3):
            store.append((*verts[i], *normal, *uv[i], *tint, windows))

    def box(self, node, mat_wall, mat_roof, cx, cz, y0, y1, half_x, half_z, yaw, tint, base_y=None, windows=1.0):
        """Upright box: four walls (UV in metres, v = height above base_y; colour alpha =
        `windows`, the "this facade has windows" mask) and a roof."""
        base_y = y0 if base_y is None else base_y
        ca, sa = math.cos(yaw), math.sin(yaw)
        corners = [(cx + ca * dx - sa * dz, cz + sa * dx + ca * dz)
                   for dx, dz in ((-half_x, -half_z), (half_x, -half_z), (half_x, half_z), (-half_x, half_z))]
        for k in range(4):
            (x0, z0), (x1, z1) = corners[k], corners[(k + 1) % 4]
            length = math.hypot(x1 - x0, z1 - z0)
            mid = ((x0 + x1) * 0.5 - cx, (z0 + z1) * 0.5 - cz)
            self.quad(node, mat_wall, (x0, y0, z0), (x1, y0, z1), (x1, y1, z1), (x0, y1, z0),
                      (mid[0], 0.0, mid[1]),
                      [(0, y0 - base_y), (length, y0 - base_y), (length, y1 - base_y), (0, y1 - base_y)], tint, windows)
        if mat_roof:
            self.quad(node, mat_roof, (*corners[0][:1], y1, corners[0][1]), (corners[1][0], y1, corners[1][1]),
                      (corners[2][0], y1, corners[2][1]), (corners[3][0], y1, corners[3][1]), (0, 1, 0), None,
                      tuple(c * 0.4 for c in tint))

    def write(self, path: Path, materials: list[str]):
        blob = bytearray()
        views, accessors, meshes, nodes = [], [], [], []

        def accessor(arr, kind, comp, target, minmax=False):
            raw = arr.tobytes()
            views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(raw), "target": target})
            blob.extend(raw + b"\x00" * ((4 - len(raw) % 4) % 4))
            acc = {"bufferView": len(views) - 1, "componentType": comp, "count": len(arr), "type": kind}
            if minmax:
                acc["min"], acc["max"] = arr.min(axis=0).tolist(), arr.max(axis=0).tolist()
            accessors.append(acc)
            return len(accessors) - 1

        by_node: dict[str, list] = {}
        for (node, mat), rows in self.prims.items():
            by_node.setdefault(node, []).append((mat, np.array(rows, dtype=np.float32)))
        for node in sorted(by_node):
            prims = []
            for mat, v in sorted(by_node[node], key=lambda p: p[0]):
                prims.append({"mode": 4, "material": materials.index(mat), "attributes": {
                    "POSITION": accessor(np.ascontiguousarray(v[:, 0:3]), "VEC3", 5126, 34962, True),
                    "NORMAL": accessor(np.ascontiguousarray(v[:, 3:6]), "VEC3", 5126, 34962),
                    "TEXCOORD_0": accessor(np.ascontiguousarray(v[:, 6:8]), "VEC2", 5126, 34962),
                    "COLOR_0": accessor(np.ascontiguousarray(v[:, 8:12]), "VEC4", 5126, 34962)},
                    "indices": accessor(np.arange(len(v), dtype=np.uint32), "SCALAR", 5125, 34963)})
            meshes.append({"name": node, "primitives": prims})
            nodes.append({"name": node, "mesh": len(meshes) - 1})
        gltf = {"asset": {"version": "2.0", "generator": "fun-racer make_scenery_fixture.py"},
                "scene": 0, "scenes": [{"name": "scenery", "nodes": list(range(len(nodes)))}],
                "nodes": nodes, "meshes": meshes,
                "materials": [{"name": m, "pbrMetallicRoughness": {"baseColorFactor": [0.7, 0.7, 0.7, 1.0],
                                                                    "metallicFactor": 0.0, "roughnessFactor": 0.8}}
                              for m in materials],
                "accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": len(blob)}]}
        js = json.dumps(gltf, separators=(",", ":")).encode()
        js += b" " * ((4 - len(js) % 4) % 4)
        out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob))
        out += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + bytes(blob)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(out)


MATERIALS = ["building_wall", "building_roof", "building_glass", "stand_seats", "stand_structure",
             "concrete", "metal", "emissive_window", "emissive_light"]
TINTS = [(0.86, 0.80, 0.70), (0.80, 0.72, 0.62), (0.90, 0.88, 0.82), (0.72, 0.62, 0.55), (0.78, 0.76, 0.74),
         (0.88, 0.76, 0.60), (0.66, 0.70, 0.74), (0.84, 0.68, 0.58)]


def chunk_name(x: float, z: float) -> str:
    return "chunk_%d_%d" % (math.floor(x / CHUNK), math.floor(z / CHUNK))


def buildings(lap: Lap, near: dict, cls: np.ndarray, rng: np.random.Generator) -> MeshBuilder:
    mb = MeshBuilder()
    # Town blocks on the urban cells.
    pitch = 30.0
    for gz in np.arange(near["z0"] + 20, near["z0"] + near["nz"] * near["step"] - 20, pitch):
        for gx in np.arange(near["x0"] + 20, near["x0"] + near["nx"] * near["step"] - 20, pitch):
            x = gx + rng.uniform(-5, 5)
            z = gz + rng.uniform(-5, 5)
            i = int((x - near["x0"]) / near["step"])
            j = int((z - near["z0"]) / near["step"])
            if cls[j, i] != URBAN or rng.random() < 0.18:
                continue
            d = float(lap.distance(np.array([x]), np.array([z]))[0])
            hx, hz = rng.uniform(6, 11), rng.uniform(6, 11)
            if d < 30 + max(hx, hz):
                continue
            height = rng.uniform(7, 16) + min(d, 600) / 600 * rng.uniform(0, 22)
            y = lap.ground(x, z)
            node = chunk_name(x, z)
            tint = TINTS[rng.integers(len(TINTS))]
            if height > 26 and rng.random() < 0.6:
                mb.box(node, "building_glass", "building_roof", x, z, y - 3, y + height * 1.5, hx, hz,
                       rng.uniform(0, math.pi), (0.55, 0.65, 0.72), y)
            else:
                yaw = rng.uniform(0, math.pi)
                mb.box(node, "building_wall", "building_roof", x, z, y - 3, y + height, hx, hz, yaw, tint, y)
                if rng.random() < 0.25:
                    # A lit sign / window band as its own geometry.
                    ca, sa = math.cos(yaw), math.sin(yaw)
                    ox, oz = -sa * (hz + 0.05), ca * (hz + 0.05)
                    p = lambda dx, dy: (x + ox + ca * dx, y + dy, z + oz + sa * dx)  # noqa: E731
                    mb.quad(node, "emissive_window", p(-hx * 0.6, 3.0), p(hx * 0.6, 3.0), p(hx * 0.6, 4.2),
                            p(-hx * 0.6, 4.2), (ox, 0, oz))
    # A far skyline north of the lap (outside the near grid for real tracks).
    lo, hi = lap.pts.min(axis=0), lap.pts.max(axis=0)
    for k in range(14):
        x = (lo[0] + hi[0]) * 0.5 + rng.uniform(-500, 500)
        z = lo[2] - rng.uniform(900, 1500)
        y = lap.ground(x, z)
        mb.box(chunk_name(x, z), "building_glass" if k % 3 == 0 else "building_wall", "building_roof", x, z,
               y - 5, y + rng.uniform(40, 110), rng.uniform(10, 18), rng.uniform(10, 18), rng.uniform(0, 3),
               TINTS[k % len(TINTS)], y)
    grandstand(lap, mb)
    pit_building(lap, mb)
    return mb


def grandstand(lap: Lap, mb: MeshBuilder):
    """Raked seating with a roof on the right of the start straight."""
    p, fwd, right, width = lap.frame(lap.start_s + 10.0)
    length, depth, rise = 70.0, 13.0, 9.0
    front = p + right * (width * 0.5 + 15.0)
    y = min(lap.ground(front[0], front[2]), p[1]) - 0.2
    node = chunk_name(front[0], front[2])

    def at(along, out, up):
        q = front + fwd * along + right * out
        return (q[0], y + up, q[2])

    a, b = -length / 2, length / 2
    grey, dark = (0.40, 0.40, 0.39), (0.15, 0.16, 0.18)
    # Seats: u along the row, v = depth from the front (as the pipeline bakes treads).
    mb.quad(node, "stand_seats", at(a, 0, 1.6), at(b, 0, 1.6), at(b, depth, 1.6 + rise), at(a, depth, 1.6 + rise),
            (-right[0] * rise, depth, -right[2] * rise), [(0, 0), (length, 0), (length, depth), (0, depth)], dark)
    mb.quad(node, "concrete", at(a, 0, -2), at(b, 0, -2), at(b, 0, 1.6), at(a, 0, 1.6), -right, None, grey)
    mb.quad(node, "stand_structure", at(a, depth, -2), at(b, depth, -2), at(b, depth, rise + 5), at(a, depth, rise + 5),
            right, None, dark)
    for end, n in ((a, -fwd), (b, fwd)):
        mb.quad(node, "stand_structure", at(end, 0, -2), at(end, depth, -2), at(end, depth, rise + 1.6), at(end, 0, 1.6),
                n, None, dark)
    # Roof, upper and lower face.
    for n in ((0, 1, 0), (0, -1, 0)):
        mb.quad(node, "metal", at(a, -2, rise + 7.5), at(b, -2, rise + 7.5), at(b, depth + 1, rise + 5), at(a, depth + 1, rise + 5),
                n, None, (0.45, 0.46, 0.48))
    for along in np.linspace(a + 2, b - 2, 8):
        q = at(along, depth - 0.5, 0)
        mb.box(node, "stand_structure", "", q[0], q[2], y, y + rise + 5.2, 0.25, 0.25, 0.0, dark, None, 0.0)
    # Lamps under the roof edge.
    mb.quad(node, "emissive_light", at(a + 3, -1.6, rise + 7.2), at(b - 3, -1.6, rise + 7.2), at(b - 3, -0.8, rise + 7.1),
            at(a + 3, -0.8, rise + 7.1), (0, -1, 0))


def pit_building(lap: Lap, mb: MeshBuilder):
    """A long low building close to the road on the left of the start straight (it is inside
    the collision band, so the runtime gives it a body)."""
    p, fwd, right, width = lap.frame(lap.start_s + 10.0)
    c = p - right * (width * 0.5 + 9.0 + 4.0)
    y = min(lap.ground(c[0], c[2]), p[1]) - 0.2
    yaw = math.atan2(fwd[2], fwd[0])
    mb.box(chunk_name(c[0], c[2]), "building_wall", "building_roof", c[0], c[2], y - 2, y + 7.0, 30.0, 4.0, yaw,
           (0.82, 0.82, 0.80), y)


def tower_glb(path: Path):
    """The fixture landmark: a slim tower. "landmark_red" is not a scenery material name, so
    the runtime keeps the model's own material for it."""
    mb = MeshBuilder()
    mb.box("tower", "concrete", "", 0, 0, -2, 28, 3.0, 3.0, 0.0, (0.62, 0.62, 0.60), None, 0.0)
    mb.box("tower", "building_glass", "building_roof", 0, 0, 28, 36, 5.0, 5.0, 0.0, (0.6, 0.7, 0.8), 28)
    mb.box("tower", "landmark_red", "landmark_red", 0, 0, 36, 44, 0.6, 0.6, 0.0, (0.9, 0.1, 0.1), None, 0.0)
    mb.write(path, MATERIALS + ["landmark_red"])


# ----------------------------------------------------------------------------- trees
def trees(lap: Lap, near: dict, cls: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    rows = []
    step = near["step"]
    # Woods and scrub: scattered over their cells.
    for kind, share in ((FOREST, 1.0 / 16.0), (SCRUB, 1.0 / 60.0), (BEACH, 1.0 / 220.0), (URBAN, 1.0 / 500.0)):
        jj, ii = np.nonzero(cls == kind)
        pick = rng.random(len(ii)) < share
        for i, j in zip(ii[pick], jj[pick]):
            x = near["x0"] + (i + rng.random()) * step
            z = near["z0"] + (j + rng.random()) * step
            if kind == FOREST:
                sp = CONIFER if noise(np.array([x]), np.array([z]), 240.0, 91)[0] > 0.45 else BROADLEAF
                h = rng.uniform(11, 22)
            elif kind == SCRUB:
                sp, h = BUSH, rng.uniform(1.2, 3.2)
            elif kind == BEACH:
                sp, h = PALM, rng.uniform(8, 13)
            else:
                sp, h = BROADLEAF, rng.uniform(6, 11)
            rows.append((x, lap.ground(x, z), z, h, sp))
    # A row of broadleaf trees along part of the lap, 40 m out on the left.
    for s in np.arange(0.0, lap.length * 0.5, 18.0):
        p, fwd, right, width = lap.frame(s)
        q = p - right * (width * 0.5 + 40.0 + rng.uniform(-3, 3))
        i = int((q[0] - near["x0"]) / step)
        j = int((q[2] - near["z0"]) / step)
        if 0 <= i < near["nx"] and 0 <= j < near["nz"] and cls[j, i] in (GRASS, SCRUB, FARMLAND) \
                and lap.distance(np.array([q[0]]), np.array([q[2]]))[0] > 30:
            rows.append((q[0], lap.ground(q[0], q[2]), q[2], rng.uniform(9, 15), BROADLEAF))
    return np.array(rows, dtype="<f4").reshape(-1, 5)


# ----------------------------------------------------------------------------- environment
def environment(time: str) -> dict:
    env = {
        "preset": {"day": "temperate_day", "dusk": "temperate_day", "night": "floodlit_night"}[time],
        "time": time,
        "kerbs": {"a": [0.05, 0.25, 0.75], "b": [0.95, 0.95, 0.95], "sausage": [0.95, 0.45, 0.05]},
        "verge": {"grass_color": [0.24, 0.40, 0.12], "dry_color": [0.40, 0.42, 0.18]},
        "trees": {"density": 1.0},
        "floodlights": {"enabled": time != "day", "spacing_m": 60, "height_m": 26},
        "stands": {"crowd": 0.7},
    }
    if time == "dusk":
        env["sun"] = {"azimuth_deg": 285, "elevation_deg": 7, "color": [1.0, 0.60, 0.36], "energy": 1.1}
    return env


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--track", type=Path, help="track folder with track.json (default: the test oval)")
    ap.add_argument("--out", type=Path, help="output folder (default: tests/fixtures/tracks/scenery_oval)")
    ap.add_argument("--time", default="day", choices=["day", "dusk", "night"])
    ap.add_argument("--no-environment", action="store_true", help="do not write environment.json")
    args = ap.parse_args()
    track = args.track or HERE / "test_oval"
    out = args.out or HERE / "scenery_oval"
    out.mkdir(parents=True, exist_ok=True)
    if args.track is None:
        # The fixture is a track folder of its own: the oval's lap plus the scenery.
        shutil.copyfile(track / "track.json", out / "track.json")
    lap = Lap(track)
    rng = np.random.default_rng(7)
    near, far = grids(lap)
    cls = classify(lap, near)
    Image.fromarray(cls, mode="L").save(out / "landcover.png")
    Image.fromarray(classify(lap, far), mode="L").save(out / "landcover_far.png")

    mesh = buildings(lap, near, cls, rng)
    mesh.write(out / "scenery.glb", MATERIALS)
    pts = trees(lap, near, cls, rng)
    (out / "scenery_points.bin").write_bytes(pts.tobytes())

    # Water: the sea east of the coast line (out to the far grid's edge) and the lake.
    sea_level = float(lap.pts[:, 1].min()) - 3.0
    fz0, fz1 = far["z0"], far["z0"] + far["nz"] * far["step"]
    zs = np.arange(fz0, fz1 + 1.0, 40.0)
    sea = [[float(x), float(z)] for x, z in zip(coast_x(lap, zs) - 6.0, zs)]
    sea += [[far["x0"] + far["nx"] * far["step"], float(fz1)], [far["x0"] + far["nx"] * far["step"], float(fz0)]]
    lx, lz, rx, rz = lake(lap)
    ring = [[lx + rx * 1.04 * math.cos(a), lz + rz * 1.04 * math.sin(a)] for a in np.linspace(0, 2 * math.pi, 40, endpoint=False)]
    lake_level = min(lap.ground(x, z) for x, z in ring) - 0.6
    meta = {
        "generator": "make_scenery_fixture.py (synthetic test data, not a real place)",
        "landcover": {"near": dict(near, file="landcover.png"), "far": dict(far, file="landcover_far.png")},
        "trees": {"file": "scenery_points.bin", "dtype": "float32", "count": int(len(pts)),
                  "record": ["x", "y", "z", "height", "species"],
                  "species": ["broadleaved", "needleleaved", "palm", "bush"]},
        # The lake carries "triangles" (a fan: it is convex) as the pipeline writes them; the
        # sea has none, so the runtime triangulates it.
        "water": [{"level": sea_level, "kind": "sea", "polygon": sea},
                  {"level": lake_level, "kind": "lake", "polygon": ring,
                   "triangles": [i for k in range(1, len(ring) - 1) for i in (0, k, k + 1)]}],
        "attribution": "Synthetic fixture: no map data.",
    }
    (out / "scenery.json").write_text(json.dumps(meta, indent=1) + "\n")
    if not args.no_environment:
        (out / "environment.json").write_text(json.dumps(environment(args.time), indent=1) + "\n")

    tower_glb(out / "landmarks" / "tower.glb")
    p, fwd, right, width = lap.frame(lap.length * 0.5)
    landmarks = [
        {"model": "tower", "at": {"s": round(lap.length * 0.25, 1), "side": -1, "dist": 45.0}, "yaw_deg": 0.0, "scale": 1.0},
        {"model": "tower.glb", "at": {"xz": [round(float(p[0] + right[0] * 70), 1), round(float(p[2] + right[2] * 70), 1)]},
         "y_offset": -1.0, "yaw_deg": 30.0, "scale": 1.5},
    ]
    if lap.terrain is not None and "origin_latlon" in lap.terrain[0]:
        lat0, lon0 = lap.terrain[0]["origin_latlon"]
        landmarks.append({"model": "tower", "at": {"latlon": [lat0 + 0.0012, lon0 - 0.0015]}, "yaw_deg": 0.0, "scale": 2.0})
    (out / "landmarks.json").write_text(json.dumps(landmarks, indent=1) + "\n")
    print("%s: near %dx%d, far %dx%d, %d trees, %d mesh primitives" % (
        out, near["nx"], near["nz"], far["nx"], far["nz"], len(pts), len(mesh.prims)))


if __name__ == "__main__":
    main()
