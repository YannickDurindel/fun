"""Landmark models of the Las Vegas Strip Circuit: everything round the lap that has a shape of
its own and is not a plain extruded footprint.

    .venv/bin/python tools/track/landmarks/las_vegas.py      (from fun-racer/, after a build)

Writes assets/tracks/las_vegas/landmarks/*.glb and assets/tracks/las_vegas/landmarks.json. It
reads the built track (track.json, terrain.json, terrain_height.bin) and the cached map data in
raw/, so run it again after the centreline or the terrain changed. Positions along the lap are
(s, lateral, height) in the built track's frame; map positions are lat / lon.

Every model is baked in world coordinates around its own anchor and placed at that anchor with
`y_offset` = minus the terrain height there, so a vertex's y is its real game height.

Surfaces named like the scenery materials (concrete, metal, building_roof) get
the game's materials and take their colour from the vertex colour. "neon" is this file's own
material: unlit and double-sided, vertex-coloured, for LED walls, signs and lit rims; the
scenery runtime keeps it as the model has it.

Dimensions and where they come from (heights above the ground):
  Sphere            111.6 m high, 157 m wide exosphere (Sphere Entertainment fact sheet; Wikipedia,
                    "Sphere (venue)"). Its skin is a 54,000 m2 LED screen: modelled as unlit colour,
                    showing the emoji in a helmet band it wore during the race weeks.
  Eiffel Tower      165 m (541 ft), a half-scale replica (Paris Las Vegas; Wikipedia). The profile
                    follows the original's platforms at 57 m and 115 m of 300 m. Footprint from OSM.
  High Roller       167.6 m high, 158.5 m diameter, 28 cabins (Caesars Entertainment; Wikipedia).
                    The wheel stands north-south, as its shadow on the aerial imagery shows.
  Campanile         the Venetian's bell tower, 96 m (315 ft; Emporis). Position from the imagery.
  Pit building logo the three roof screens of the F1 logo are mapped in OSM (man_made=video_wall);
                    28,000 sq ft LED roof (Samsung press release, November 2023).
  Flamingo bridge   the temporary road bridge that carries Flamingo Road over Koval Lane for the
                    race: 230 m (760 ft) long with its ramps, four lanes (Clark County / Las Vegas
                    Review-Journal, 2023 and 2024). Clearance and width are estimates.
  Monorail          the Las Vegas Monorail guideway in the median of Sands Avenue, crossing the lap
                    where it turns south at Koval Lane; traced from the imagery, underside about 10.5 m
                    up (estimate: it clears the footbridge at Koval Lane).
  Median palms      the palms of the Strip's central reservation, about every 12 m (imagery).
  Signs, LED walls  where the resorts' marquees and screens stand; sizes are estimates from street
                    photographs, the pictures on them are abstract colour tiles.
  Bellagio fountain the jets of the Fountains of Bellagio (up to 140 m in reality; the usual show
                    arcs of 25 to 75 m are modelled), along the pipe rings seen on the imagery.
  Cranes            the two tower cranes on the Hard Rock guitar hotel site (imagery).
"""
from __future__ import annotations

import json
import math
import struct
import sys
import zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "cad" / "track"))
import scenery_glb as sg  # noqa: E402  (triangulate)

TRACK = ROOT / "assets" / "tracks" / "las_vegas"
OUT = TRACK / "landmarks"
UP = np.array([0.0, 1.0, 0.0])

# name -> (base colour, roughness, metallic, unlit)
MATERIALS = {
    "concrete": ((0.66, 0.65, 0.62), 0.95, 0.0, False),
    "metal": ((0.55, 0.57, 0.60), 0.45, 0.6, False),
    "building_roof": ((0.45, 0.42, 0.40), 0.85, 0.0, False),
    "neon": ((1.0, 1.0, 1.0), 1.0, 0.0, True),
}


# ----------------------------------------------------------------------------- track and ground
class Lap:
    def __init__(self):
        t = json.loads((TRACK / "track.json").read_text())
        self.p = np.array([q["p"] for q in t["points"]], dtype=np.float64)
        self.w = np.array([q["width"] for q in t["points"]], dtype=np.float64)
        self.n = len(self.p)
        self.length = float(t["length"])
        self.step = self.length / self.n
        self.start_s = float(t["start_s"])
        d = np.roll(self.p, -1, axis=0) - np.roll(self.p, 1, axis=0)
        d[:, 1] = 0.0
        self.t = d / np.linalg.norm(d, axis=1)[:, None]
        self.r = np.stack([-self.t[:, 2], np.zeros(self.n), self.t[:, 0]], axis=1)   # to the right
        ter = json.loads((TRACK / "terrain.json").read_text())
        self.lat0, self.lon0 = ter["origin_latlon"]
        self.k = float(ter["plan_scale"])
        g = ter["near"]
        self.g = g
        self.h = np.fromfile(TRACK / g["file"], dtype="<f4").reshape(g["nz"], g["nx"])

    def i(self, s):
        return int(round((s % self.length) / self.step)) % self.n

    def at(self, s, lateral=0.0, height=0.0):
        """Point `lateral` metres to the right of the centreline at s, `height` above the road."""
        i = self.i(s)
        return self.p[i] + self.r[i] * lateral + UP * height

    def half(self, s):
        return 0.5 * float(self.w[self.i(s)])

    def xz(self, lat, lon):
        """Game (x, z) of a latitude / longitude: the runtime's Terrain.latlon_to_xz."""
        m = 111320.0 * self.k
        return np.array([(lon - self.lon0) * m * math.cos(math.radians(self.lat0)), -(lat - self.lat0) * m])

    def ground(self, x, z):
        """Terrain height at (x, z), as the runtime's Terrain.height_at; 0 outside the grid."""
        g = self.g
        u, v = (x - g["x0"]) / g["step"], (z - g["z0"]) / g["step"]
        if u < 0 or v < 0 or u > g["nx"] - 1 or v > g["nz"] - 1:
            return 0.0
        i, j = min(int(u), g["nx"] - 2), min(int(v), g["nz"] - 2)
        tu, tv = u - i, v - j
        a = self.h[j, i] * (1 - tu) + self.h[j, i + 1] * tu
        b = self.h[j + 1, i] * (1 - tu) + self.h[j + 1, i + 1] * tu
        return float(a * (1 - tv) + b * tv)

    def on_ground(self, lat, lon, height=0.0):
        x, z = self.xz(lat, lon)
        return np.array([x, self.ground(x, z) + height, z])

    def distance(self, x, z):
        return float(np.min(np.hypot(self.p[:, 0] - x, self.p[:, 2] - z)))


# ----------------------------------------------------------------------------- mesh
class Model:
    """Triangles per material, flat shaded, written as one glb node."""

    def __init__(self, name, anchor):
        self.name = name
        self.anchor = np.array([anchor[0], 0.0, anchor[1]])
        self.parts: dict[str, list] = {}

    def tri(self, mat, a, b, c, col, away=None, both=False):
        a, b, c = (np.asarray(v, dtype=np.float64) for v in (a, b, c))
        cols = list(col) if isinstance(col, list) else [col, col, col]
        n = np.cross(b - a, c - a)
        if away is not None and np.dot(n, (a + b + c) / 3.0 - np.asarray(away)) < 0.0:
            b, c = c, b
            cols = [cols[0], cols[2], cols[1]]
        self.parts.setdefault(mat, []).append((a, b, c, cols))
        if both:
            self.parts[mat].append((a, c, b, [cols[0], cols[2], cols[1]]))

    def quad(self, mat, a, b, c, d, col, away=None, both=False):
        cols = col if isinstance(col, list) else [col] * 4
        self.tri(mat, a, b, c, [cols[0], cols[1], cols[2]], away, both)
        self.tri(mat, a, c, d, [cols[0], cols[2], cols[3]], away, both)

    def hull(self, mat, bottom, top, col, caps=True):
        """Frustum between two rings of equally many points (convex), with end caps."""
        bottom = [np.asarray(v, dtype=np.float64) for v in bottom]
        top = [np.asarray(v, dtype=np.float64) for v in top]
        centre = (sum(bottom) + sum(top)) / (len(bottom) + len(top))
        n = len(bottom)
        for k in range(n):
            j = (k + 1) % n
            self.quad(mat, bottom[k], bottom[j], top[j], top[k], col, away=centre)
        if caps:
            for ring in (bottom, top):
                for k in range(1, n - 1):
                    self.tri(mat, ring[0], ring[k], ring[k + 1], col, away=centre)

    def box(self, mat, lo, hi, col):
        (x0, y0, z0), (x1, y1, z1) = lo, hi
        self.hull(mat, [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
                  [(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)], col)

    def beam(self, mat, p, q, width, depth, col):
        """A bar from p to q: `width` across (horizontal, or along x for a vertical bar),
        `depth` below the line p-q for a horizontal bar."""
        p, q = np.asarray(p, dtype=np.float64), np.asarray(q, dtype=np.float64)
        d = q - p
        flat = np.array([d[0], 0.0, d[2]])
        if np.linalg.norm(flat) < 1e-6:      # vertical: a square column
            u, v = np.array([0.5 * width, 0, 0]), np.array([0, 0, 0.5 * depth])
            self.hull(mat, [p - u - v, p + u - v, p + u + v, p - u + v], [q - u - v, q + u - v, q + u + v, q - u + v], col)
            return
        side = np.cross(UP, flat / np.linalg.norm(flat)) * (0.5 * width)
        down = UP * depth
        self.hull(mat, [p - side, p + side, p + side - down, p - side - down],
                  [q - side, q + side, q + side - down, q - side - down], col)

    def ring_prism(self, mat, centre, radius0, radius1, y0, y1, col, sides=8, turn=0.0):
        cx, cz = centre
        a = [turn + 2 * math.pi * k / sides for k in range(sides)]
        self.hull(mat, [(cx + radius0 * math.cos(t), y0, cz + radius0 * math.sin(t)) for t in a],
                  [(cx + radius1 * math.cos(t), y1, cz + radius1 * math.sin(t)) for t in a], col)

    def triangles(self):
        return sum(len(v) for v in self.parts.values())

    def write(self, path):
        blob = bytearray()
        views, accessors, prims, mats = [], [], [], []

        def accessor(arr, kind, comp, target=34962, minmax=False, normalized=False):
            raw = arr.tobytes()
            views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(raw), "target": target})
            blob.extend(raw + b"\x00" * ((4 - len(raw) % 4) % 4))
            acc = {"bufferView": len(views) - 1, "componentType": comp, "count": len(arr), "type": kind}
            if normalized:
                acc["normalized"] = True
            if minmax:
                acc["min"], acc["max"] = arr.min(axis=0).tolist(), arr.max(axis=0).tolist()
            accessors.append(acc)
            return len(accessors) - 1

        for name in MATERIALS:
            tris = self.parts.get(name)
            if not tris:
                continue
            pos = np.array([v - self.anchor for t in tris for v in t[:3]], dtype=np.float32)
            nrm = np.zeros_like(pos)
            for k in range(0, len(pos), 3):
                n = np.cross(pos[k + 1] - pos[k], pos[k + 2] - pos[k])
                nrm[k:k + 3] = n / max(float(np.linalg.norm(n)), 1e-9)
            col = np.array([list(c)[:3] + [list(c)[3] if len(c) > 3 else 0.0] for t in tris for c in t[3]])
            col = np.clip(np.round(col * 255.0), 0, 255).astype(np.uint8)
            uv = np.stack([pos[:, 0] + pos[:, 2], pos[:, 1]], axis=1).astype(np.float32)
            idx = np.arange(len(pos), dtype=np.uint32)
            base, rough, metallic, unlit = MATERIALS[name]
            m = {"name": name, "pbrMetallicRoughness": {"baseColorFactor": list(base) + [1.0],
                                                        "metallicFactor": metallic, "roughnessFactor": rough}}
            if unlit:
                m["extensions"] = {"KHR_materials_unlit": {}}
                m["doubleSided"] = True
            mats.append(m)
            prims.append({"attributes": {"POSITION": accessor(pos, "VEC3", 5126, minmax=True),
                                         "NORMAL": accessor(nrm, "VEC3", 5126),
                                         "TEXCOORD_0": accessor(uv, "VEC2", 5126),
                                         "COLOR_0": accessor(col, "VEC4", 5121, normalized=True)},
                          "indices": accessor(idx, "SCALAR", 5125, target=34963),
                          "material": len(mats) - 1, "mode": 4})
        gltf = {"asset": {"version": "2.0", "generator": "fun-racer tools/track/landmarks/las_vegas.py"},
                "scene": 0, "scenes": [{"name": self.name, "nodes": [0]}],
                "nodes": [{"name": self.name, "mesh": 0}],
                "meshes": [{"name": self.name, "primitives": prims}],
                "materials": mats, "accessors": accessors, "bufferViews": views,
                "buffers": [{"byteLength": len(blob)}]}
        if any("extensions" in m for m in mats):
            gltf["extensionsUsed"] = ["KHR_materials_unlit"]
        js = json.dumps(gltf, separators=(",", ":")).encode()
        js += b" " * ((4 - len(js) % 4) % 4)
        out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob))
        out += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + bytes(blob)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(out)


def lin(rgb):
    """sRGB (as picked from a photograph) -> the linear colour a vertex carries."""
    return tuple(((c + 0.055) / 1.055) ** 2.4 if c > 0.04045 else c / 12.92 for c in rgb)


def rnd(*key):
    """Repeatable number in 0..1 from any key (no random module: the build must not change)."""
    return (zlib.crc32(repr(key).encode()) & 0xFFFFFF) / float(0xFFFFFF)


_WAYS: dict[int, list] = {}


def osm_ring(lap, way_id):
    """Footprint of a cached OSM way in game (x, z)."""
    if not _WAYS:
        for f in sorted((TRACK / "raw").glob("surroundings_near_*.json")):
            for el in json.loads(f.read_text())["elements"]:
                if el["t"] == "w":
                    _WAYS[el["id"]] = el["g"]
    if way_id not in _WAYS:
        raise SystemExit(f"way {way_id} is not in the cached map data of {TRACK / 'raw'}")
    g = np.array(_WAYS[way_id], dtype=np.float64).reshape(-1, 2)
    return np.array([lap.xz(a, b) for a, b in g])


# ----------------------------------------------------------------------------- the Sphere
def sphere(lap):
    ring = osm_ring(lap, 976405284)
    cx, cz = ring[:-1].mean(axis=0)
    g = lap.ground(cx, cz)
    m = Model("sphere", (cx, cz))
    radius, top = 78.5, 111.6
    cy = g + top - radius
    # The podium the exosphere rises from: plaza level, stairs and loading docks.
    m.ring_prism("concrete", (cx, cz), 84.0, 80.0, g - 1.5, g + 9.0, lin((0.20, 0.20, 0.22)), sides=32)
    seg, rows = 72, 34
    lo = math.asin((g + 8.0 - cy) / radius)
    yellow, white, black = (1.0, 0.80, 0.07), (0.95, 0.95, 1.0), (0.02, 0.02, 0.03)
    band, blue = (0.93, 0.90, 0.98), (0.35, 0.72, 1.0)

    def unit(az, el):
        return np.array([math.cos(el) * math.cos(az), math.sin(el), math.cos(el) * math.sin(az)])

    def angle(d, az_deg, el_deg):
        return math.degrees(math.acos(float(np.clip(d @ unit(math.radians(az_deg), math.radians(el_deg)), -1, 1))))

    def colour(az, el):
        # What the exosphere showed through the race weeks of 2023 to 2025: the yellow emoji
        # in a racing helmet band (photographs of the 2024 Grand Prix on Wikimedia Commons).
        # The face looks east, over Turns 7 and 8.
        d = unit(az, el)
        e, a = math.degrees(el), (math.degrees(az) + 180.0) % 360.0 - 180.0
        tilt = e - 7.0 * math.sin(math.radians(a))        # the band sits askew
        if tilt > 54.0:
            return blue
        if tilt > 38.0:
            return band
        for side in (-1.0, 1.0):
            if angle(d, side * 24.0 + 3.0, 5.0) < 7.0:      # pupils, looking down the road
                return black
            if angle(d, side * 23.0, 9.0) < 14.5:
                return white
            if abs(e - 29.0 - side * 0.12 * (a - side * 23.0)) < 2.6 and abs(a - side * 23.0) < 15.0:
                return black                                 # eyebrows
        if abs(a) < 9.0 and abs(e + 9.0 - 0.035 * a * a) < 1.7:
            return black                                     # the smile
        return yellow

    def point(k, r):
        az = 2 * math.pi * k / seg
        el = lo + (math.pi / 2 - lo) * r / rows
        return np.array([cx + radius * math.cos(el) * math.cos(az), cy + radius * math.sin(el),
                         cz + radius * math.cos(el) * math.sin(az)])

    centre = np.array([cx, cy, cz])
    for r in range(rows):
        for k in range(seg):
            # One colour per panel, taken at its middle: the blocky look of an LED skin.
            c = colour(2 * math.pi * (k + 0.5) / seg, lo + (math.pi / 2 - lo) * (r + 0.5) / rows)
            a, b, cc, d = point(k, r), point(k + 1, r), point(k + 1, r + 1), point(k, r + 1)
            if r == rows - 1:
                m.tri("neon", a, b, cc, c, away=centre)
            else:
                m.quad("neon", a, b, cc, d, c, away=centre)
    return m


# ----------------------------------------------------------------------------- Eiffel Tower
def eiffel(lap):
    ring = osm_ring(lap, 27831699)[:-1]
    c = ring.mean(axis=0)
    # The footprint's own axes: the direction of its longest edge.
    edges = np.roll(ring, -1, axis=0) - ring
    e = edges[np.argmax(np.hypot(*edges.T))]
    ax = np.array([e[0], 0.0, e[1]]) / np.hypot(*e)
    az = np.cross(UP, ax)
    side = 0.5 * float(np.ptp(ring @ np.array([ax[0], ax[2]])) + np.ptp(ring @ np.array([az[0], az[2]])))
    g = lap.ground(c[0], c[1])
    H = 165.0
    o = np.array([c[0], g, c[1]])
    m = Model("eiffel", c)
    iron = lin((0.62, 0.50, 0.30))       # the tower is floodlit gold at night
    glow = (1.0, 0.86, 0.50)
    # height, half width of the tower, width of one leg
    levels = [(0.0, 0.50 * side, 0.20 * side), (0.19 * H, 0.27 * side, 0.115 * side),
              (0.385 * H, 0.135 * side, 0.068 * side)]

    def corner(h, half, leg, sx, sz):
        inner = half - leg
        pts = [(inner, inner), (half, inner), (half, half), (inner, half)]
        return [o + ax * (sx * u) + az * (sz * v) + UP * h for u, v in pts]

    for (h0, w0, l0), (h1, w1, l1) in zip(levels, levels[1:]):
        for sx in (-1, 1):
            for sz in (-1, 1):
                m.hull("metal", corner(h0, w0, l0, sx, sz), corner(h1, w1, l1, sx, sz), iron)

    def square(h, half):
        return [o + ax * u + az * v + UP * h for u, v in ((-half, -half), (half, -half), (half, half), (-half, half))]

    for h, w in ((0.19 * H, 0.27 * side), (0.385 * H, 0.135 * side)):   # the two platforms
        m.hull("metal", square(h - 1.2, w + 1.5), square(h + 1.6, w + 1.5), iron)
        m.hull("neon", square(h + 1.6, w + 1.7), square(h + 2.3, w + 1.7), glow, caps=False)
    m.hull("metal", square(0.385 * H + 1.6, 0.135 * side), square(0.60 * H, 0.062 * side), iron)
    m.hull("metal", square(0.60 * H, 0.062 * side), square(0.90 * H, 0.026 * side), iron)
    m.hull("metal", square(0.90 * H, 0.04 * side), square(0.925 * H, 0.04 * side), iron)       # top cabin
    m.hull("neon", square(0.925 * H, 0.042 * side), square(0.935 * H, 0.042 * side), glow, caps=False)
    m.hull("metal", square(0.925 * H, 0.018 * side), square(H, 0.004 * side), iron)            # mast
    # The Montgolfier balloon sign of Paris Las Vegas on the Strip pavement (about 14 m across
    # on a 21 m pylon; estimate from photographs), blue with gold bands.
    b = lap.at(4858.0, -44.0)
    m.ring_prism("metal", (b[0], b[2]), 1.2, 0.9, b[1], b[1] + 21.0, lin((0.25, 0.25, 0.3)), sides=6)
    cy, rad = b[1] + 29.0, 7.5
    centre = np.array([b[0], cy, b[2]])
    seg, rows = 14, 8
    for r in range(rows):
        for k in range(seg):
            def p(kk, rr):
                az_ = 2 * math.pi * kk / seg
                el = -math.pi / 2 + math.pi * rr / rows
                squash = 1.0 if el > 0 else 1.25      # drawn out towards the basket
                return np.array([b[0] + rad * math.cos(el) * math.cos(az_), cy + rad * math.sin(el) * squash,
                                 b[2] + rad * math.cos(el) * math.sin(az_)])
            col = (0.10, 0.30, 0.95) if (k + r) % 4 else (1.0, 0.80, 0.30)
            m.quad("neon", p(k, r), p(k + 1, r), p(k + 1, r + 1), p(k, r + 1), col, away=centre)
    return m


# ----------------------------------------------------------------------------- High Roller
def high_roller(lap):
    hub = lap.on_ground(36.117544, -115.168136)
    g = hub[1]
    radius, top = 79.25, 167.6
    hub = hub + UP * (top - radius)
    m = Model("high_roller", (hub[0], hub[2]))
    white = lin((0.88, 0.88, 0.90))
    seg = 56

    def rim(k, r):
        a = 2 * math.pi * k / seg
        return hub + np.array([0.0, r * math.cos(a), r * math.sin(a)])

    for k in range(seg):
        a = 2 * math.pi * k / seg
        # The rim's LED lighting: one colour wash running round the wheel.
        col = tuple(np.clip(np.array([0.75 + 0.25 * math.sin(a), 0.10 + 0.25 * math.cos(a) ** 2,
                                      0.80 + 0.20 * math.cos(a)]), 0, 1))
        w = np.array([1.4, 0.0, 0.0])
        m.hull("neon", [rim(k, radius - 1.3) - w, rim(k, radius - 1.3) + w, rim(k, radius + 1.3) + w, rim(k, radius + 1.3) - w],
               [rim(k + 1, radius - 1.3) - w, rim(k + 1, radius - 1.3) + w, rim(k + 1, radius + 1.3) + w,
                rim(k + 1, radius + 1.3) - w], col, caps=False)
    for k in range(28):         # the cabins: 6.7 m glass spheres on the outside of the rim
        c = rim(k * 2, radius + 4.6)
        m.box("neon", c - np.array([3.0, 2.6, 2.6]), c + np.array([3.0, 2.6, 2.6]), (0.80, 0.90, 1.0))
    # Four legs to the east and west of the wheel plane and the brace leg (the shapes on the
    # imagery), and the hub.
    m.box("metal", hub - np.array([6.0, 3.5, 3.5]), hub + np.array([6.0, 3.5, 3.5]), white)
    for dx, dz in ((-22.0, -24.0), (-22.0, 24.0), (22.0, -24.0), (22.0, 24.0)):
        foot = np.array([hub[0] + dx, g, hub[2] + dz])
        head = hub + np.array([math.copysign(5.0, dx), 0.0, 0.0])
        m.hull("metal", [foot + np.array([u, 0, v]) for u, v in ((-1.8, -1.8), (1.8, -1.8), (1.8, 1.8), (-1.8, 1.8))],
               [head + np.array([u, 0, v]) for u, v in ((-1.4, -1.4), (1.4, -1.4), (1.4, 1.4), (-1.4, 1.4))], white)
    foot = np.array([hub[0] + 62.0, g, hub[2] - 12.0])
    m.hull("metal", [foot + np.array([u, 0, v]) for u, v in ((-1.5, -1.5), (1.5, -1.5), (1.5, 1.5), (-1.5, 1.5))],
           [hub + np.array([6.0 + u, 0, v]) for u, v in ((-1.2, -1.2), (1.2, -1.2), (1.2, 1.2), (-1.2, 1.2))], white)
    return m


# ----------------------------------------------------------------------------- along the Strip
def palm(m, base, height, key):
    trunk = lin((0.42, 0.33, 0.24))
    x, y, z = base
    m.ring_prism("building_roof", (x, z), 0.34, 0.20, y - 0.3, y + height, trunk, sides=5, turn=rnd(key, 0) * 6.0)
    top = np.array([x, y + height, z])
    fronds = 7
    for k in range(fronds):
        a = 2 * math.pi * (k + rnd(key, 1)) / fronds
        out = np.array([math.cos(a), 0.0, math.sin(a)])
        side = np.cross(UP, out)
        green = lin((0.20 + 0.08 * rnd(key, k), 0.36 + 0.08 * rnd(key, k, 2), 0.14))
        mid = top + out * 1.6 + UP * 0.7
        tip = top + out * 3.4 - UP * 0.9
        m.tri("building_roof", top, mid - side * 0.75, mid + side * 0.75, green, both=True)
        m.tri("building_roof", mid - side * 0.75, tip, mid + side * 0.75, green, both=True)


PALETTES = {
    "video": [(1.0, 0.25, 0.10), (0.10, 0.45, 1.0), (1.0, 0.85, 0.20), (0.90, 0.10, 0.60), (0.95, 0.95, 1.0),
              (0.10, 0.85, 0.75), (0.05, 0.06, 0.12)],
    "gold": [(1.0, 0.78, 0.36), (1.0, 0.66, 0.25), (1.0, 0.90, 0.60)],
    "pink": [(1.0, 0.25, 0.55), (1.0, 0.45, 0.20), (0.95, 0.15, 0.75), (1.0, 0.65, 0.75)],
    "purple": [(0.55, 0.20, 0.95), (0.85, 0.30, 0.90), (0.25, 0.25, 0.95), (1.0, 0.80, 0.40)],
    "red": [(1.0, 0.10, 0.08), (1.0, 0.95, 0.90), (0.85, 0.05, 0.05)],
    "blue": [(0.15, 0.40, 1.0), (0.40, 0.75, 1.0), (0.95, 0.95, 1.0)],
    "green": [(0.15, 0.85, 0.30), (1.0, 0.20, 0.15), (1.0, 0.95, 0.80)],
    "white": [(1.0, 0.96, 0.88), (1.0, 0.90, 0.75)],
}


def sign(m, lap, s0, s1, lateral, h0, h1, palette, key, tile=5.0):
    """An LED wall or lit sign facing the lap: tiles of colour from s0 to s1, `lateral` metres
    from the centreline (+ right), between h0 and h1 above the road."""
    cols = PALETTES[palette]
    nu = max(1, int(round(abs(s1 - s0) / tile)))
    nv = max(1, int(round((h1 - h0) / tile)))
    for a in range(nu):
        sa, sb = s0 + (s1 - s0) * a / nu, s0 + (s1 - s0) * (a + 1) / nu
        for b in range(nv):
            ha, hb = h0 + (h1 - h0) * b / nv, h0 + (h1 - h0) * (b + 1) / nv
            # Neighbouring tiles often share a colour, as the blocks of a picture do.
            c = cols[int(rnd(key, a // 2, b // 2, (a + b) % 3 == 0) * len(cols)) % len(cols)]
            m.quad("neon", lap.at(sa, lateral, ha), lap.at(sb, lateral, ha), lap.at(sb, lateral, hb),
                   lap.at(sa, lateral, hb), c)


# s from, s to, lateral (+ right, - left), bottom, top (m above the road), palette. The distances
# are the building fronts of the baked scenery less a metre; heights are estimates from street
# photographs of each resort's marquee or LED front.
SIGNS = [
    (878.0, 892.0, 21.0, 5.0, 12.0, "green"),       # Ellis Island's neon on Koval Lane
    (3206.0, 3218.0, 30.0, 8.0, 40.0, "red"),       # the Wynn marquee at the Sands Avenue corner (41 m)
    (3292.0, 3392.0, 38.5, 9.0, 22.0, "video"),     # Fashion Show Mall's LED front under the Cloud
    (3344.0, 3356.0, -31.0, 6.0, 38.0, "gold"),     # The Palazzo / Venetian marquee
    (3436.0, 3446.0, 17.0, 6.0, 34.0, "blue"),      # the Treasure Island sign
    (3842.0, 3884.0, -21.5, 6.0, 16.0, "video"),    # Casino Royale and its Walgreens corner screen
    (3956.0, 4008.0, -24.0, 8.0, 22.0, "purple"),   # Harrah's carnival front
    (4000.0, 4078.0, 14.0, 15.0, 19.0, "white"),    # the lit colonnade of the Forum Shops
    (4092.0, 4150.0, -24.0, 6.0, 20.0, "video"),    # The LINQ's screens
    (4126.0, 4140.0, 26.0, 6.0, 34.0, "gold"),      # the Caesars Palace marquee
    (4246.0, 4330.0, -27.0, 6.0, 22.0, "pink"),     # the Flamingo's feathered neon
    (4472.0, 4508.0, -31.0, 30.0, 44.0, "white"),   # The Cromwell's roof sign
    (4642.0, 4698.0, -38.0, 5.0, 16.0, "gold"),     # Horseshoe
    (4722.0, 4838.0, -48.0, 4.0, 15.0, "blue"),     # the Paris casino front
    (4952.0, 5150.0, -33.0, 8.0, 26.0, "video"),    # Miracle Mile Shops / Planet Hollywood LED wrap
    (5040.0, 5068.0, 23.0, 5.0, 60.0, "purple"),    # The Cosmopolitan's marquee column
    (5164.0, 5186.0, 35.0, 4.0, 14.0, "blue"),      # the Crystals corner
    (5216.0, 5294.0, -36.5, 8.0, 24.0, "video"),    # Harmon Corner's 60 m LED front
    (5350.0, 5420.0, -33.0, 10.0, 20.0, "video"),   # Planet Hollywood's Harmon Avenue screens
    (5490.0, 5540.0, -33.0, 10.0, 18.0, "purple"),
]
# The Strip's central reservation, to the left of the southbound lanes the race uses: its palms
# stand about every 12 m between the junctions (from - to, in s).
MEDIAN_PALMS = [(3300.0, 3470.0), (3535.0, 3880.0), (3915.0, 4470.0), (4580.0, 4925.0), (4990.0, 5140.0)]
# Pavement palms on the resort side where the imagery shows them (from, to, lateral).
# None inside the tarmac run-off of Turn 14 (s 5095 onwards): landmarks have no collision.
KERB_PALMS = [(4020.0, 4440.0, 14.5), (4900.0, 5080.0, 13.5), (3400.0, 3680.0, 13.5)]


def strip(lap):
    m = Model("strip", (-950.0, -700.0))
    for a, b in MEDIAN_PALMS:
        for k in range(int((b - a) / 12.0) + 1):
            s = a + 12.0 * k
            lateral = -(lap.half(s) + 5.2 + 0.6 * rnd("m", s))
            palm(m, lap.at(s, lateral), 10.0 + 4.0 * rnd("mh", s), ("m", s))
    for a, b, lateral in KERB_PALMS:
        for k in range(int((b - a) / 14.0) + 1):
            s = a + 14.0 * k
            palm(m, lap.at(s, lateral + rnd("k", s)), 8.0 + 4.0 * rnd("kh", s), ("k", s))
    for k, (s0, s1, lateral, h0, h1, pal) in enumerate(SIGNS):
        sign(m, lap, s0, s1, lateral, h0, h1, pal, k)
    # The Venetian's campanile.
    p = lap.on_ground(36.121719, -115.171412)
    brick, stone, copper = lin((0.62, 0.36, 0.27)), lin((0.90, 0.87, 0.80)), lin((0.36, 0.55, 0.45))
    m.ring_prism("concrete", (p[0], p[2]), 7.8, 7.4, p[1] - 1.0, p[1] + 60.0, brick, sides=4, turn=math.pi / 4)
    m.ring_prism("concrete", (p[0], p[2]), 8.2, 8.2, p[1] + 60.0, p[1] + 72.0, stone, sides=4, turn=math.pi / 4)
    m.ring_prism("concrete", (p[0], p[2]), 7.0, 7.0, p[1] + 72.0, p[1] + 78.0, brick, sides=4, turn=math.pi / 4)
    m.ring_prism("concrete", (p[0], p[2]), 6.6, 0.3, p[1] + 78.0, p[1] + 96.0, copper, sides=4, turn=math.pi / 4)
    # Fountains of Bellagio: the long arc of jets and the big ring (positions from the imagery).
    path = [(36.113855, -115.173525), (36.113444, -115.173847), (36.113076, -115.174029),
            (36.112772, -115.174075), (36.112339, -115.174029), (36.111711, -115.173927)]
    pts = np.array([lap.xz(a, b) for a, b in path])
    water = float(np.mean([lap.at(s, 0.0)[1] for s in (4650.0, 4750.0, 4850.0)])) - 1.0
    seglen = np.hypot(*np.diff(pts, axis=0).T)
    total = float(seglen.sum())
    jets = []
    n = 34
    for k in range(n):
        d = total * (k + 0.5) / n
        j = 0
        while d > seglen[j]:
            d -= seglen[j]
            j += 1
        q = pts[j] + (pts[j + 1] - pts[j]) * d / seglen[j]
        jets.append((q, 26.0 + 44.0 * (0.5 + 0.5 * math.sin(k * 0.55)) ** 2))
    ring_c = lap.xz(36.112902, -115.174276)
    for k in range(16):
        a = 2 * math.pi * k / 16
        jets.append((ring_c + 26.0 * np.array([math.cos(a), math.sin(a)]), 34.0))
    jets.append((ring_c, 75.0))
    for q, h in jets:
        m.ring_prism("neon", (q[0], q[1]), 0.9, 0.12, water, water + h, (0.82, 0.90, 1.0), sides=4, turn=rnd(q[0]))
    # The two tower cranes of the Hard Rock guitar hotel site.
    yellow = lin((0.85, 0.65, 0.12))
    for lat, lon, turn in ((36.121424, -115.173435, 0.6), (36.121294, -115.172791, 2.4)):
        p = lap.on_ground(lat, lon)
        topp = p + UP * 128.0
        m.beam("metal", p, topp, 2.2, 2.2, yellow)
        d = np.array([math.cos(turn), 0.0, math.sin(turn)])
        m.beam("metal", topp - d * 16.0 + UP * 1.5, topp + d * 55.0 + UP * 1.5, 1.6, 1.6, yellow)
        m.box("concrete", topp - d * 16.0 - np.array([1.5, 2.5, 1.5]), topp - d * 12.0 + np.array([1.5, 0.5, 1.5]),
              lin((0.4, 0.4, 0.4)))
        m.box("neon", topp + UP * 7.0 - 0.4, topp + UP * 7.8 + 0.4, (1.0, 0.1, 0.05))
        m.beam("metal", topp, topp + UP * 7.0, 1.0, 1.0, yellow)
    return m


# ----------------------------------------------------------------------------- round the circuit
def gantry(m, lap, s, clear, banner):
    """A truss over the track on two towers, with a lit banner facing the oncoming cars."""
    half = lap.half(s) + 3.8
    steel = lin((0.20, 0.20, 0.22))
    a, b = lap.at(s, -half), lap.at(s, half)
    for foot in (a, b):
        m.beam("metal", foot - UP * 0.5, foot + UP * (clear + 1.6), 0.9, 0.9, steel)
    y = max(a[1], b[1]) + clear
    a2, b2 = np.array([a[0], y + 1.6, a[2]]), np.array([b[0], y + 1.6, b[2]])
    m.beam("metal", a2, b2, 1.2, 1.6, steel)
    i = lap.i(s)
    back = -lap.t[i] * 0.7
    span = b2 - a2
    for k, col in enumerate(banner):
        p, q = a2 + span * (0.12 + 0.76 * k / len(banner)), a2 + span * (0.12 + 0.76 * (k + 1) / len(banner))
        m.quad("neon", p + back - UP * 1.5, q + back - UP * 1.5, q + back - UP * 0.1, p + back - UP * 0.1, col)


def circuit(lap):
    m = Model("circuit", (0.0, 0.0))
    # Start lights gantry just beyond the start line: five red lights over a dark board.
    s = lap.start_s + 9.0
    gantry(m, lap, s, 6.5, [(0.04, 0.04, 0.05)])
    i = lap.i(s)
    for k in range(5):
        c = lap.at(s, -4.0 + 2.0 * k, 6.5 + 0.85) - lap.t[i] * 0.85
        m.box("neon", c - 0.36, c + 0.36, (1.0, 0.06, 0.04))
    # Sponsor bridges, the F1 staple; where they stand on this circuit is an estimate.
    gantry(m, lap, 1320.0, 6.5, [(0.85, 0.05, 0.05), (0.95, 0.95, 0.95), (0.85, 0.05, 0.05)])
    gantry(m, lap, 5700.0, 6.5, [(0.02, 0.45, 0.20), (0.95, 0.95, 0.95), (0.02, 0.45, 0.20)])
    # The F1 logo on the pit building roof: its three LED screens are mapped in OSM.
    for way in (1416395732, 1416395733, 1416395734):
        ring = sg.clean_ring(osm_ring(lap, way))
        ring = sg.oriented(ring, True)
        y = lap.ground(*ring.mean(axis=0)) + 19.5 + 0.35
        ring, tris = sg.triangulate(ring)
        for a, b, c in tris:
            m.tri("neon", (ring[a][0], y, ring[a][1]), (ring[b][0], y, ring[b][1]), (ring[c][0], y, ring[c][1]),
                  (1.0, 0.07, 0.05))
    # Temporary road bridge carrying Flamingo Road over Koval Lane.
    s = 1102.0
    c = lap.at(s)
    i = lap.i(s)
    along, across = lap.r[i], lap.t[i]          # the bridge runs across the lap
    grey = lin((0.52, 0.52, 0.50))
    top, half_w, span, reach = c[1] + 7.0, 8.0, 11.5, 115.0

    def deck(u, y, w):
        return c + along * u + across * w + UP * (y - c[1])

    def foot(u):
        """Ground level where a ramp meets Flamingo Road."""
        q = c + along * u
        return lap.ground(q[0], q[2])

    low = min(foot(-reach), foot(reach), c[1]) - 1.0
    for u0, u1, y0, y1 in ((-reach, -span, foot(-reach) + 0.15, top), (-span, span, top, top),
                           (span, reach, top, foot(reach) + 0.15)):
        a, b = deck(u0, y0, -half_w), deck(u1, y1, -half_w)
        d, e = deck(u0, y0, half_w), deck(u1, y1, half_w)
        m.quad("concrete", a, b, e, d, grey, away=c - UP * 50.0)
        solid = abs(u0) > span or abs(u1) > span
        for p, q in ((a, b), (d, e)):
            # Parapet above the deck, and below it either the ramp's side wall or the span's edge beam.
            m.quad("concrete", p, q, q + UP * 1.1, p + UP * 1.1, grey, both=True)
            if solid:
                m.quad("concrete", np.array([p[0], low, p[2]]), np.array([q[0], low, q[2]]), q, p,
                       lin((0.42, 0.42, 0.41)), both=True)
            else:
                m.quad("concrete", p - UP * 1.2, q - UP * 1.2, q, p, grey, both=True)
        if not solid:
            m.quad("concrete", a - UP * 1.2, b - UP * 1.2, e - UP * 1.2, d - UP * 1.2, lin((0.3, 0.3, 0.3)), both=True)
    for u in (-span, span):         # abutment faces
        m.quad("concrete", deck(u, low, -half_w), deck(u, low, half_w), deck(u, top, half_w),
               deck(u, top, -half_w), lin((0.42, 0.42, 0.41)), both=True)
    # Las Vegas Monorail guideway (two beams side by side, drawn as one 3 m wide deck), traced
    # on the imagery: east along the median of Sands Avenue, then south across the lap at Koval
    # Lane. Its underside is kept above the floodlight masts that stand under it.
    way = [(36.122372, -115.158906), (36.122368, -115.161918), (36.122363, -115.162837),
           (36.122359, -115.163588), (36.122337, -115.163749), (36.122281, -115.163910),
           (36.122186, -115.164031), (36.122056, -115.164085), (36.121908, -115.164098),
           (36.120949, -115.164111), (36.119398, -115.164121)]
    way = [tuple(lap.xz(a, b)) for a, b in way]
    beam_col = lin((0.62, 0.61, 0.58))
    pts = []
    for (x0, z0), (x1, z1) in zip(way, way[1:]):
        n = max(1, int(math.hypot(x1 - x0, z1 - z0) / 28.0))
        pts += [(x0 + (x1 - x0) * k / n, z0 + (z1 - z0) * k / n) for k in range(n)]
    pts.append(way[-1])
    crossing = lap.at(2577.0)[1]
    ys = [max(lap.ground(x, z), crossing) + 12.5 for x, z in pts]
    clear = 12.5        # m from the centreline: behind the wall and the floodlight masts
    for k in range(len(pts) - 1):
        p = np.array([pts[k][0], ys[k], pts[k][1]])
        q = np.array([pts[k + 1][0], ys[k + 1], pts[k + 1][1]])
        m.beam("concrete", p, q, 3.0, 1.9, beam_col)
        # A pier under the beam; where the beam runs over the road or its walls the pier
        # stands beside them and carries the beam on a crosshead.
        j = int(np.argmin(np.hypot(lap.p[:, 0] - p[0], lap.p[:, 2] - p[2])))
        off = np.array([p[0] - lap.p[j][0], 0.0, p[2] - lap.p[j][2]])
        dist = float(np.linalg.norm(off))
        base = p.copy()
        if dist < clear:
            side = off / dist if dist > 0.5 else lap.r[j]
            base = np.array([lap.p[j][0], p[1], lap.p[j][2]]) + side * clear
            m.beam("concrete", p - UP * 1.9, base - UP * 1.9, 1.5, 1.2, beam_col)
        m.beam("concrete", np.array([base[0], lap.ground(base[0], base[2]) - 1.0, base[2]]), base - UP * 1.9,
               1.3, 1.5, beam_col)
    # Topgolf's net poles beside Harmon Avenue (about 50 m high; estimate from photographs).
    for lateral in (24.0, 124.0):
        for k in range(6):
            p = lap.at(5884.0 + 24.0 * k, lateral)
            m.beam("metal", p - UP, p + UP * 48.0, 0.7, 0.7, lin((0.30, 0.32, 0.34)))
    return m


def main():
    lap = Lap()
    entries = []
    total = 0
    for build in (sphere, eiffel, high_roller, strip, circuit):
        m = build(lap)
        path = OUT / f"{m.name}.glb"
        m.write(path)
        x, z = float(m.anchor[0]), float(m.anchor[2])
        entries.append({"model": m.name, "at": {"xz": [round(x, 2), round(z, 2)]},
                        "y_offset": round(-lap.ground(x, z), 3)})
        total += m.triangles()
        print(f"{path.relative_to(ROOT)}: {m.triangles()} triangles, {path.stat().st_size / 1e3:.0f} kB")
    (TRACK / "landmarks.json").write_text(json.dumps(entries, indent=1) + "\n")
    print(f"landmarks.json: {len(entries)} models, {total} triangles")


if __name__ == "__main__":
    main()
