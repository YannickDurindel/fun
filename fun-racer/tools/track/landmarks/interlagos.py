"""Landmark models of Interlagos: writes assets/tracks/interlagos/landmarks/*.glb and
landmarks.json. Run it after every rebuild of the track (it reads track.json,
road_profile.json and the terrain grid):

    .venv/bin/python tools/track/landmarks/interlagos.py

  runoff_paint   the painted run-off areas. Every run-off at Interlagos is tarmac painted
                 green (the dark aprons on the way into Junção and after the Senna S are
                 painted nearly black), and along the pits plain tarmac reaches the wall. The trackside tarmac material is plain grey, so the
                 paint is a thin skin over the verges, on exactly the surface the road step
                 builds them with (cad/track/road.py: horizontally outward from the road edge,
                 dropping verge_drop over verge_width), lifted PAINT_LIFT above it: the
                 trackside tarmac lies 0.03 m above the verge, the paint just over that.
                 Extents: the RUNOFF table of scripts/track/trackside_layouts/interlagos.gd
                 plus the painted strips beside the start straight, the pit entry and the
                 inside of Curva do Sol (Esri World Imagery; drone photographs of 2023 on
                 Wikimedia Commons, "Vista aérea del Autódromo José Carlos Pace" 01-06 and
                 "Topo do S de Interlagos").
  start_gantry   the start lights gantry over the grid: two lattice posts behind the walls and
                 a beam with the five light pods. Real one: about 7 m clear; estimate.
  pit_roof       the white tensile roof of the pit building: two rows of peaked membrane bays
                 on the 315 m building (bay size counted on the aerial picture: 30 bays, so
                 10.5 m each; rise about 2.5 m, estimate).

Models use the scenery material names (they get the game's materials and take their colour
from the vertex colour) except the paint, which brings its own two materials.
"""
import json
import math
import re
import struct
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "cad" / "track"))
import scenery_glb as sg  # noqa: E402
from road_glb import Material  # noqa: E402

TRACK = ROOT / "assets" / "tracks" / "interlagos"
OUT = TRACK / "landmarks"
LAYOUT = ROOT / "scripts" / "track" / "trackside_layouts" / "interlagos.gd"
UP = np.array([0.0, 1.0, 0.0])

PAINT_LIFT = 0.075                      # m above the verge surface
PAINT_KERB = 1.6                        # m beyond the road edge where a kerb lies (1.5 m wide)
PAINT_EDGE = 0.3                        # ... and where none does: beside the white line
VERGE_MARGIN = 0.6                      # m kept from the outer edge of a clipped verge
GREEN = (0.03, 0.46, 0.34)              # sRGB, the Interlagos run-off green
DARK = (0.06, 0.09, 0.12)               # the dark aprons
ASPHALT = (0.20, 0.20, 0.21)            # plain tarmac between the road and the pit wall
WHITE = (0.93, 0.93, 0.91)
STEEL = (0.50, 0.52, 0.55)



def lin(rgb, a=0.0):
    """sRGB -> linear RGBA (glTF base colours and vertex colours are linear)."""
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb) + (a,)


PAINT_MATERIALS = [Material("paint_green", lin(GREEN, 1.0), 0.85), Material("paint_dark", lin(DARK, 1.0), 0.8),
                   Material("paint_asphalt", lin(ASPHALT, 1.0), 0.9)]
for _m in PAINT_MATERIALS:
    if _m.name not in sg.MATERIAL_NAMES:
        sg.MATERIALS.append(_m)
        sg.MATERIAL_NAMES.append(_m.name)


def norm(v):
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-12)


class Lap:
    """The centreline frames and edges exactly as cad/track/road.py builds them."""

    def __init__(self):
        d = json.loads((TRACK / "track.json").read_text(encoding="utf-8"))
        prof = json.loads((TRACK / "road_profile.json").read_text(encoding="utf-8"))
        self.P = np.array([p["p"] for p in d["points"]], dtype=float)
        self.n = len(self.P)
        self.step = float(d["step"])
        self.length = float(d["length"])
        self.start_s = float(d.get("start_s", 0.0))
        self.turns = {t["id"]: t for t in d["turns"]}
        T = norm(np.roll(self.P, -1, 0) - np.roll(self.P, 1, 0))
        self.T = T
        self.Rh = norm(np.cross(T, UP))
        U0 = norm(np.cross(self.Rh, T))
        bank = np.array(prof["bank"], dtype=float)
        self.hw = 0.5 * np.array(prof["width"], dtype=float)
        R = self.Rh * np.cos(bank)[:, None] - U0 * np.sin(bank)[:, None]
        self.edge = {-1.0: self.P - R * self.hw[:, None], 1.0: self.P + R * self.hw[:, None]}
        self.ext = {-1.0: np.array(prof["verge_left"], dtype=float), 1.0: np.array(prof["verge_right"], dtype=float)}
        self.verge_width = float(prof["verge_width"])
        self.verge_drop = float(prof["verge_drop"])

    def index(self, s):
        return int(round((s % self.length) / self.step)) % self.n

    def verge_point(self, i, side, dd):
        """Point of the verge surface ``dd`` metres beyond the road edge (see road.py: verge)."""
        p = self.edge[side][i] + self.Rh[i] * side * dd
        p = p.copy()
        p[1] -= self.verge_drop * dd / self.verge_width
        return p

    def turn(self, tid):
        t = self.turns[tid]
        return float(t["s_apex"]), (1.0 if t["direction"] == "right" else -1.0)


def smoothstep(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0) if b > a else float(x >= b)
    return t * t * (3.0 - 2.0 * t)


def _table(name):
    text = LAYOUT.read_text(encoding="utf-8")
    body = text[text.index("const " + name):]
    return body[:body.index("\n]")]


def _rows(name, pattern, lap):
    """Rows of a table of the trackside script. It is read as text, so every row must be
    written the plain way (string and number literals); a row this cannot read, or one for a
    turn the track does not have, stops the build instead of silently losing its paint."""
    body = _table(name)
    found = list(re.finditer(pattern, body))
    written = len(re.findall(r'^\s*\["', body, flags=re.MULTILINE))
    if len(found) != written:
        raise SystemExit(f"{LAYOUT.name}: {written} rows in {name}, only {len(found)} could be read")
    for m in found:
        if m.group(1) not in lap.turns:
            raise SystemExit(f"{LAYOUT.name}: {name} names turn {m.group(1)}, which track.json does not have")
    return found


def layout_runoff(lap):
    """The RUNOFF rows of the trackside table: [turn, side, from, to, kind, u0, u1]."""
    return [(m.group(1), m.group(2), float(m.group(3)), float(m.group(4)), m.group(5), float(m.group(6)),
             float(m.group(7)))
            for m in _rows("RUNOFF", r'\["(T\d+)",\s*"(in|out)",\s*(-?[\d.]+),\s*(-?[\d.]+),\s*"(\w+)",\s*(-?[\d.]+),\s*(-?[\d.]+)\]', lap)]


def layout_kerbs(lap):
    """Kerbs of the trackside table as (from s, length, side), sausage kerbs left out (they
    stand on a flat kerb)."""
    out = []
    for m in _rows("KERBS", r'\["(T\d+)",\s*"(in|out)",\s*(-?[\d.]+),\s*(-?[\d.]+),\s*"(\w+)"\]', lap):
        if m.group(5) == "sausage":
            continue
        apex, sign = lap.turn(m.group(1))
        out.append(((apex + float(m.group(3))) % lap.length, float(m.group(4)) - float(m.group(3)),
                    sign if m.group(2) == "in" else -sign))
    return out


def paint_patch(mesh, lap, kerbs, s0, length, side, u1, dark=(), ramp=None, base="paint_green"):
    """A painted strip from s0 over ``length`` metres on ``side``, from the road edge (or the
    kerb, where one lies there: the paint must not cover it) to u1 metres beyond the edge,
    tapering in and out over ``ramp`` like the trackside run-off. ``dark`` = (from, to)
    distances from s0 that are painted dark instead of green. One quad per centreline step is
    exact: the verge is straight from the road edge outward, and its drop is the same
    function of the distance on every cross-section."""
    ramp = min(25.0, 0.3 * length) if ramp is None else ramp
    i0 = lap.index(s0)
    rows = max(2, int(round(length / lap.step)))
    prev = None
    quads = {base: [], "paint_dark": []}
    for r in range(rows + 1):
        t = r * lap.step
        i = (i0 + r) % lap.n
        s = i * lap.step
        # 3 m of margin along the lap: a kerb's ends are ramps.
        kerb = any(sd == side and (s - k0 + 3.0) % lap.length <= kl + 6.0 for k0, kl, sd in kerbs)
        u0 = PAINT_KERB if kerb else PAINT_EDGE
        taper = smoothstep(0.0, ramp, t) * smoothstep(0.0, ramp, rows * lap.step - t)
        # Never beyond the verge the road step built (it is clipped where another part of
        # the lap is near), nor beyond the run-off.
        room = max(lap.ext[side][i] - VERGE_MARGIN, 0.0)
        a = min(u0, room)
        b = min(u0 + (u1 - u0) * taper, room)
        row = (lap.verge_point(i, side, a) + UP * PAINT_LIFT, lap.verge_point(i, side, b) + UP * PAINT_LIFT, b - a)
        if prev is not None and min(row[2], prev[2]) > 0.05:
            material = "paint_dark" if dark and dark[0] <= t <= dark[1] else base
            quads[material].append([prev[0], prev[1], row[1], row[0]])
        prev = row
    for material, q in quads.items():
        if not q:
            continue
        pos = np.array(q)
        # Counter-clockwise seen from above, whichever side of the road the strip is on.
        nrm = np.cross(pos[:, 1] - pos[:, 0], pos[:, 2] - pos[:, 0])
        flip = nrm[:, 1] < 0.0
        pos[flip] = pos[flip][:, ::-1]
        mesh.quads(material, pos, np.tile(UP, (len(pos), 1)), pos.reshape(-1, 3)[:, [0, 2]], (1.0, 1.0, 1.0, 0.0))


# Stretches painted dark instead of green: (turn, side, from, to) in the terms of the RUNOFF
# table. The half of the Senna S bowl that lies inside its second corner, and the apron on
# the way into Junção.
DARK_PAINT = (("T1", "out", 62.0, 140.0), ("T12", "out", -175.0, -45.0))


def build_paint(lap):
    mesh = one_chunk()
    kerbs = layout_kerbs(lap)
    for tid, where, a, b, kind, _u0, u1 in layout_runoff(lap):
        if kind != "tarmac":
            continue
        apex, sign = lap.turn(tid)
        side = sign if where == "in" else -sign
        dark = next(((d0 - a, d1 - a) for t, w, d0, d1 in DARK_PAINT if t == tid and w == where), ())
        paint_patch(mesh, lap, kerbs, apex + a, b - a, side, u1, dark)
    # Strips that are paint only (no run-off behind them): [from s, length, side, u1].
    t3, _ = lap.turn("T3")
    t14, _ = lap.turn("T14")
    for s0, length, side, u1 in (
            (t14 + 180.0, lap.length - (t14 + 180.0) + 300.0, 1.0, 4.6),    # right of the start straight
            (t14 + 300.0, 285.0, -1.0, 4.6),                                # the pit entry
            (t3 - 50.0, 330.0, -1.0, 4.6)):                                 # inside Curva do Sol, to the pit exit
        paint_patch(mesh, lap, kerbs, s0, length, side, u1, ramp=20.0)
    # The pit wall stands at the edge of the road: no grass between them, plain tarmac.
    paint_patch(mesh, lap, kerbs, t14 + 585.0, lap.length - (t14 + 585.0) + 330.0, -1.0, 4.6, ramp=10.0,
                base="paint_asphalt")
    return mesh


def one_chunk():
    """A SceneryMesh that keeps everything in one node."""
    m = sg.SceneryMesh(-1.0e5, -1.0e5, 2.0e5)
    m.anchor(0.0, 0.0)
    return m


def build_gantry(half_span):
    """Local frame of an "s" placement: +x = right of the road, -z = along the lap, y = 0 at
    the road. Posts at +/- half_span."""
    mesh = one_chunk()
    steel = lin(STEEL)
    dark = lin((0.10, 0.10, 0.11))
    clear, depth, beam = 7.0, 1.2, 1.3
    for sx in (-1.0, 1.0):
        x = sx * half_span
        sg.box(mesh, "metal", (x - 0.45, -1.0, -depth * 0.5), (x + 0.45, clear + beam, depth * 0.5), steel)
    sg.box(mesh, "metal", (-half_span, clear, -depth * 0.5), (half_span, clear + 0.18, depth * 0.5), steel)
    sg.box(mesh, "metal", (-half_span, clear + beam - 0.18, -depth * 0.5), (half_span, clear + beam, depth * 0.5), steel)
    # Lattice: verticals every 2 m on both faces.
    k = max(1, int(half_span // 2.0))
    for j in range(-k + 1, k):
        x = j * 2.0 * half_span / (2 * k)
        for z in (-depth * 0.5, depth * 0.5 - 0.08):
            sg.box(mesh, "metal", (x - 0.04, clear + 0.18, z), (x + 0.04, clear + beam - 0.18, z + 0.08), steel)
    # Five light pods facing the grid (which stands before the line: +z in this frame).
    for j in range(5):
        x = (j - 2) * 1.5
        sg.box(mesh, "metal", (x - 0.55, clear - 0.95, depth * 0.5), (x + 0.55, clear + 0.25, depth * 0.5 + 0.35), dark)
        for row in range(2):
            y = clear - 0.70 + row * 0.5
            sg.box(mesh, "emissive_light", (x - 0.36, y, depth * 0.5 + 0.35), (x + 0.36, y + 0.30, depth * 0.5 + 0.38),
                   lin((0.95, 0.08, 0.05)))
    return mesh


def build_pit_roof(length=315.0, bays=30, front=18.0, back=22.0, rise=2.5):
    """Local frame as for the gantry; the roof is centred on the origin, its long side along z.
    The front row (lower, over the pit lane side) is on the +x side for a building to the
    LEFT of the road (the placement has side = -1, so +x still points to the right)."""
    mesh = one_chunk()
    white = lin(WHITE)
    steel = lin(STEEL)
    bay = length / bays
    for row, (x0, x1, y) in enumerate(((0.0, front, 0.0), (-back, 0.0, 1.4))):
        for b in range(bays):
            z0 = -0.5 * length + b * bay
            ring = np.array([[x0, z0], [x1, z0], [x1, z0 + bay], [x0, z0 + bay]])
            sg.pyramid_roof(mesh, ring, y, rise, "building_roof", white)
        sg.box(mesh, "metal", (x0, y - 0.35, -0.5 * length), (x1, y, 0.5 * length), steel)
    return mesh


def terrain_node(x, z):
    """Height of the near terrain grid at its node nearest (x, z): the game interpolates the
    same grid (Terrain.height_at), so a landmark placed on a node sits at exactly this."""
    meta = json.loads((TRACK / "terrain.json").read_text(encoding="utf-8"))["near"]
    i = int(round((x - meta["x0"]) / meta["step"]))
    j = int(round((z - meta["z0"]) / meta["step"]))
    if not (0 <= i < meta["nx"] and 0 <= j < meta["nz"]):
        raise SystemExit(f"({x}, {z}) is outside the near terrain grid")
    raw = (TRACK / meta["file"]).read_bytes()
    h = struct.unpack_from("<f", raw, 4 * (j * meta["nx"] + i))[0]
    return meta["x0"] + i * meta["step"], meta["z0"] + j * meta["step"], h


def main():
    lap = Lap()
    OUT.mkdir(parents=True, exist_ok=True)
    report = {}
    entries = []

    paint = build_paint(lap)
    report["runoff_paint"] = sg.write_glb(OUT / "runoff_paint.glb", paint, "interlagos_runoff_paint", "tools/track/landmarks/interlagos.py")
    x, z, h = terrain_node(0.0, 0.0)
    # The model is in track coordinates: the node height is taken off again.
    entries.append({"model": "runoff_paint", "at": {"xz": [x, z]}, "y_offset": round(-h, 4)})

    i = lap.index(lap.start_s)
    half = float(lap.hw[i]) + 6.5
    report["start_gantry"] = sg.write_glb(OUT / "start_gantry.glb", build_gantry(half), "interlagos_start_gantry",
                                         "tools/track/landmarks/interlagos.py")
    entries.append({"model": "start_gantry", "at": {"s": round(lap.start_s + 14.0, 1), "side": 1, "dist": 0.0}})

    report["pit_roof"] = sg.write_glb(OUT / "pit_roof.glb", build_pit_roof(), "interlagos_pit_roof",
                                      "tools/track/landmarks/interlagos.py")
    # The building stands from about 22 m to 338 m after the line, its track-side face 14 to
    # 18 m left of the centreline (aerial picture); the seam between the two roof rows is
    # 32 m out. Height: 10.4 m above the road at s = 180, which is 12 m in the track frame,
    # just over the roof edge the recipe gives the building (way 33779114: 16.3 m above its
    # lowest ground corner at -4.5 m). Change the two together.
    entries.append({"model": "pit_roof", "at": {"s": 180.0, "side": -1, "dist": 32.0}, "y_offset": 10.4})

    (TRACK / "landmarks.json").write_text(json.dumps(entries, indent=1) + "\n", encoding="utf-8")
    for name, r in report.items():
        print(f"{name}: {r['triangles']} triangles, {r['bytes'] / 1024:.0f} kB")


if __name__ == "__main__":
    main()
