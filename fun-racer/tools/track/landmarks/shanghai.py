#!/usr/bin/env python3
"""Landmark models of the Shanghai International Circuit.

    .venv/bin/python tools/track/landmarks/shanghai.py            # writes the models
    .venv/bin/python tools/track/landmarks/shanghai.py --recipe   # also prints the lat / lon
                                                                  # rings of shanghai.toml

Writes assets/tracks/shanghai/landmarks/*.glb (+ .import) and landmarks.json. Run it after the
track's centreline step: everything on the pit straight is placed in the frame of the built
centreline (a = metres along the straight from the finish line, l = metres to the right).

What is modelled, and from what:
  * main_complex: the two "wings" that span the start straight, the roof of the main
    grandstand on its columns, and the start gantry.
      - Plan: OpenStreetMap way 107371135 ("A看台") is the outline of grandstand + wings: each
        wing is 31 m wide and 137-139 m long, square to the track, 22 m before the finish line
        and 337 m after it; the grandstand front is 17.2 m left of the centreline.
      - Heights: OpenStreetMap's building parts give the wings from 24.5 to 35 m (ways
        1371942059 / 1371942060, "roof:shape = round") and the grandstand roof from 29.75 m
        (way 1371942058). That agrees with "The Media Centre is located on the 9th floor of
        the control tower" and "a media center above the track" (FIA media kit, Chinese Grand
        Prix 2026). The surroundings step can only build those parts as boxes, so they are
        excluded in the recipe and modelled here: the wing as the lens it is in elevation
        (photographs on Wikimedia Commons, "Shanghai International Circuit 2.jpg",
        "Shanghai F1 Circui 01.jpg"), with the red banner bands of a race weekend.
      - The round glass towers under the wings and the red stair drums are in the map with
        their heights and are left to the surroundings step.
      - "400-metres long and 40.6-metres wide ... its height ranges from 2.74 metres to
        27 metres" (the stepped seating of the main grandstand; mondodr.com on its sound
        system). The seating is baked by the surroundings step ([[surroundings.add]] in the
        recipe), so it gets the game's seat shader; this model only adds the roof.
  * lotus_h, lotus_k: the "roof based on a lotus leaf" (FIA media kit) of grandstands H and K
    either side of the turn 14 hairpin: 13 round membrane canopies per stand, each on one
    mast. Centres, the 32 m diameter, the rim heights (19 and 23.5 m alternately, so the
    discs overlap) and the mast tops (29 and 33 m) are OpenStreetMap's building parts; the
    step would build them as flat discs on four posts, so they are excluded in the recipe
    and modelled here as the shallow funnels they are (photographs on Wikimedia Commons,
    "Shanghai International Circuit 1.jpg", "Shanghai formula1 2.jpg").

Colours are sRGB here and stored linear, as scenery.glb has them. Surfaces carry the scenery
material names, so the game gives them its own materials (see scripts/track/scenery.gd).
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "cad" / "track"))
import scenery_glb as sg  # noqa: E402

TRACK = ROOT / "assets" / "tracks" / "shanghai"
OUT = TRACK / "landmarks"
GENERATOR = "fun-racer tools/track/landmarks/shanghai.py"

# ---- measures (metres; a along the pit straight from the finish line, l to the right) ----
WING_EAST = (-22.5, 8.4)        # a range of the wing before the finish line (OSM)
WING_WEST = (337.1, 368.2)      # a range of the wing at the end of the grid (OSM)
WING_L = (-69.5, 69.0)          # both wings, across the track (OSM)
WING_MID_Y = 29.75              # OSM: 24.5 m underside, 35 m top
WING_HALF_T = 5.25
STAND_FRONT_L = -17.2           # OSM
STAND_DEPTH = 40.6              # source: 40.6 m wide
STAND_TOP = 27.0                # source: 27 m
ROOF_Y = 29.75                  # OSM: underside of the roof part
ROOF_L = (-15.0, -62.0)         # Esri World Imagery: the roof is about 47 m deep
GANTRY_A = 200.0                # start lights, 10 m beyond the start line (estimate)

LOTUS_COUNT = 13
LOTUS_RADIUS = 16.0
# First and last disc centre (x, z), OSM. Row H is drawn 25 m from the back straight; on Esri
# World Imagery its disc edges are 4.5 m from the tarmac (28 m to the centreline): moved out 2.5 m.
LOTUS_H = ((373.1, -57.4), (533.1, 183.6))
LOTUS_K = ((265.0, 20.0), (435.0, 253.0))
LOTUS_RIMS = (19.0, 23.5)       # OSM, alternating from the first disc
LOTUS_MASTS = (29.0, 33.0)      # OSM
LOTUS_STAND_TOP = 13.0           # OSM: the seating slabs (ways 156346098, 156346102)
# Stand under the discs, metres from the disc line: (towards the track, away from it).
LOTUS_H_STAND = (9.0, 15.0)
LOTUS_K_STAND = (12.0, 12.0)

# Housing blocks of Jiading new town, 0.9 to 1.5 km east of the back straight: the map has
# none of them. Centres (game x, z) of the slabs read off Esri World Imagery; heights are
# ESTIMATES from the length of their shadows there (towers about 2.5 to 3 times the six-storey
# rows beside them). (name, height, (length, depth), centres)
HOUSING = (
    ("housing tower, Jiading new town (south estate)", 58.0, (52.0, 15.0),
     [(1425, -277), (1446, -218), (1489, -357), (1596, -341), (1618, -250), (1725, -379), (1757, -304),
      (1704, -486), (1864, -529), (1886, -437), (1961, -368)]),
    ("housing tower, Jiading new town (middle estate)", 48.0, (48.0, 14.0),
     [(1350, -984), (1457, -1016), (1607, -1075), (1629, -1032), (1661, -936), (1286, -1182), (1414, -1171),
      (1521, -1150)]),
    ("housing tower, Jiading new town (north estate)", 45.0, (48.0, 14.0),
     [(921, -1461), (1029, -1450), (1264, -1439), (1350, -1364), (1489, -1279), (1864, -1096), (1939, -1279)]),
    ("six-storey housing row, Jiading new town", 18.0, (55.0, 12.0),
     [(950, -1000), (1090, -1040), (1010, -940), (1150, -980), (1060, -880), (1200, -920), (1100, -790),
      (1240, -830), (1130, -720), (1270, -760), (1330, -900), (1380, -800)]),
)

SILVER = (0.80, 0.82, 0.84)
WHITE = (0.93, 0.93, 0.90)
MEMBRANE = (0.95, 0.94, 0.89)
RED = (0.74, 0.09, 0.07)
CONCRETE = (0.62, 0.62, 0.60)
DARK = (0.16, 0.17, 0.19)


def lin(rgb, alpha=0.0):
    """sRGB triple -> linear RGBA vertex colour (alpha 1 = a facade with windows)."""
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb) + (alpha,)


def new_mesh():
    # One chunk for the whole model: a landmark is one node.
    return sg.SceneryMesh(-1.0e6, -1.0e6, 4.0e6)


class Straight:
    """Frame of the pit straight in model coordinates (relative to the finish-line point)."""

    def __init__(self, track):
        pts = track["points"]
        s = np.array([p["s"] for p in pts])
        xz = np.array([[p["p"][0], p["p"][2]] for p in pts])
        self.origin = xz[int(np.argmin(np.abs(s)))]
        i0, i1 = int(np.argmin(np.abs(s - 20.0))), int(np.argmin(np.abs(s - 330.0)))
        u = xz[i1] - xz[i0]
        self.u = u / np.linalg.norm(u)
        self.r = np.array([-self.u[1], self.u[0]])    # right of travel (x east, z south)

    def xz(self, a, l):
        """Model (x, z) of the point a metres along and l metres right."""
        return self.u * a + self.r * l

    def rect(self, a0, a1, l0, l1):
        return np.array([self.xz(a0, l0), self.xz(a1, l0), self.xz(a1, l1), self.xz(a0, l1)])

    def ellipse(self, a, l, ra, rl, sides=16):
        t = np.arange(sides) * (2.0 * np.pi / sides)
        return np.array([self.xz(a + ra * math.cos(v), l + rl * math.sin(v)) for v in t])

    def p(self, a, l, y):
        q = self.xz(a, l)
        return np.array([q[0], y, q[1]])


def wing(mesh, f, a_range, colour, banner):
    """A lens-shaped deck across the track: thickest at mid-span, thin at the tips, with a
    six-sided section (flat top and underside, bevelled edges). The upper bevels of the middle
    part carry the red banner band."""
    a_c, half_w = 0.5 * (a_range[0] + a_range[1]), 0.5 * (a_range[1] - a_range[0])
    l_c, half_l = 0.5 * (WING_L[0] + WING_L[1]), 0.5 * (WING_L[1] - WING_L[0])
    stations = np.linspace(-1.0, 1.0, 15)
    rings = []
    for t in stations:
        ht = max(0.5, WING_HALF_T * (1.0 - t * t))
        hw = half_w * (1.0 - 0.3 * t ** 4)
        l = l_c + t * half_l
        sect = [(-0.72 * hw, ht), (0.72 * hw, ht), (hw, 0.0), (0.72 * hw, -ht), (-0.72 * hw, -ht), (-hw, 0.0)]
        rings.append([f.p(a_c + da, l, WING_MID_Y + dy) for da, dy in sect])
    for k in range(len(rings) - 1):
        axis = 0.5 * (f.p(a_c, l_c + stations[k] * half_l, WING_MID_Y)
                      + f.p(a_c, l_c + stations[k + 1] * half_l, WING_MID_Y))
        mid = 0.5 * (stations[k] + stations[k + 1])
        for i in range(6):
            j = (i + 1) % 6
            red = banner and i in (1, 5) and abs(mid) < 0.6
            mesh.face("concrete", [rings[k][i], rings[k][j], rings[k + 1][j], rings[k + 1][i]], None,
                      lin(RED) if red else colour, away_from=axis)
    for ring, t in ((rings[0], -1.0), (rings[-1], 1.0)):
        inside = f.p(a_c, l_c + 0.9 * t * half_l, WING_MID_Y)
        mesh.face("concrete", ring, None, colour, away_from=inside)


def main_complex(track):
    f = Straight(track)
    mesh = new_mesh()
    mesh.anchor(0.0, 0.0)
    for a_range in (WING_EAST, WING_WEST):
        wing(mesh, f, a_range, lin(SILVER), True)
    # Grandstand roof between the wings: a cantilever slab on a row of columns at the back.
    a0, a1 = WING_EAST[1] - 2.0, WING_WEST[0] + 2.0
    sg.prism(mesh, f.rect(a0, a1, ROOF_L[1], ROOF_L[0]), [], ROOF_Y, ROOF_Y + 1.2, "concrete", "building_roof",
             lin(WHITE), lin(WHITE), 0.0, floor=True)
    back = STAND_FRONT_L - STAND_DEPTH - 1.5
    for a in np.arange(a0 + 8.0, a1 - 4.0, 18.0):
        sg.prism(mesh, f.rect(a - 0.8, a + 0.8, back - 1.6, back), [], -1.5, ROOF_Y, "concrete",
                 "concrete", lin(CONCRETE), lin(CONCRETE), 0.0)
    # Start gantry: two posts outside the walls and a beam over the grid.
    half = 12.5
    for l in (-half, half):
        sg.prism(mesh, f.rect(GANTRY_A - 0.35, GANTRY_A + 0.35, l - 0.35, l + 0.35), [], -1.5, 9.2,
                 "concrete", "concrete", lin(DARK), lin(DARK), 0.0)
    sg.prism(mesh, f.rect(GANTRY_A - 0.6, GANTRY_A + 0.6, -half, half), [], 7.6, 9.2, "concrete", "concrete",
             lin(DARK), lin(DARK), 0.0, floor=True)
    return mesh, [float(f.origin[0]), float(f.origin[1])]


def umbrella(mesh, cx, cz, rim_y, top_y):
    """One lotus-leaf canopy: a shallow funnel on a mast that ends in a spike."""
    sides = 16
    ang = np.arange(sides) * (2.0 * np.pi / sides)
    outer = np.stack([cx + LOTUS_RADIUS * np.cos(ang), np.full(sides, rim_y), cz + LOTUS_RADIUS * np.sin(ang)], axis=1)
    inner_lo = np.stack([cx + 1.2 * np.cos(ang), np.full(sides, rim_y - 3.2), cz + 1.2 * np.sin(ang)], axis=1)
    inner_hi = np.stack([cx + 1.2 * np.cos(ang), np.full(sides, rim_y - 1.6), cz + 1.2 * np.sin(ang)], axis=1)
    col = lin(MEMBRANE)
    below, above = np.array([cx, rim_y - 30.0, cz]), np.array([cx, rim_y + 30.0, cz])
    for i in range(sides):
        j = (i + 1) % sides
        mesh.face("building_roof", [inner_lo[i], inner_lo[j], outer[j], outer[i]], None, col, away_from=above)
        mesh.face("building_roof", [inner_hi[i], inner_hi[j], outer[j], outer[i]], None, col, away_from=below)
    mast = sg.ngon(cx, cz, 0.7, 6)
    sg.wall_quads(mesh, "concrete", mast, -1.5, rim_y, lin(WHITE), 0.0)
    tip = np.array([cx, top_y, cz])
    axis = np.array([cx, rim_y, cz])
    for i in range(6):
        j = (i + 1) % 6
        a = np.array([mast[i][0], rim_y - 1.6, mast[i][1]])
        b = np.array([mast[j][0], rim_y - 1.6, mast[j][1]])
        mesh.face("concrete", [a, b, tip], None, lin(WHITE), away_from=axis)


def lotus_row(ends):
    """The canopies of one stand, relative to the middle of the row."""
    c0, c1 = np.array(ends[0]), np.array(ends[1])
    mid = 0.5 * (c0 + c1)
    mesh = new_mesh()
    mesh.anchor(0.0, 0.0)
    for k in range(LOTUS_COUNT):
        c = c0 + (c1 - c0) * k / (LOTUS_COUNT - 1) - mid
        umbrella(mesh, float(c[0]), float(c[1]), LOTUS_RIMS[k % 2], LOTUS_MASTS[k % 2])
    return mesh, [float(mid[0]), float(mid[1])]


IMPORT = """[remap]

importer="scene"
importer_version=1
type="PackedScene"

[deps]

source_file="res://assets/tracks/shanghai/landmarks/{name}.glb"

[params]

nodes/root_type=""
nodes/root_name=""
nodes/root_script=null
mesh_library/use_node_names_as_mesh_names=false
array_mesh/deduplicate_surfaces=true
nodes/apply_root_scale=true
nodes/root_scale=1.0
nodes/import_as_skeleton_bones=false
nodes/use_name_suffixes=true
nodes/use_node_type_suffixes=true
meshes/ensure_tangents=false
meshes/generate_lods=false
meshes/create_shadow_meshes=false
meshes/light_baking=0
meshes/lightmap_texel_size=0.2
meshes/force_disable_compression=true
skins/use_named_skins=true
animation/import=false
animation/fps=30
animation/trimming=false
animation/remove_immutable_tracks=true
animation/import_rest_as_RESET=false
import_script/path=""
materials/extract=0
materials/extract_format=0
materials/extract_path=""
_subresources={{}}
gltf/naming_version=2
gltf/embedded_image_handling=1
gltf/texture_map_mode=1
"""


def lotus_stand_ring(ends, depth, track_xz):
    """Footprint of the stand under a row of canopies: 8 m beyond the end discs, ``depth`` =
    (towards the track, away from it) from the disc line."""
    c0, c1 = np.array(ends[0]), np.array(ends[1])
    d = (c1 - c0) / np.linalg.norm(c1 - c0)
    n = np.array([-d[1], d[0]])
    mid = 0.5 * (c0 + c1)
    near = track_xz[int(np.argmin(np.hypot(*(track_xz - mid).T)))]
    if float((near - mid) @ n) < 0.0:
        n = -n
    a, b = c0 - d * 8.0, c1 + d * 8.0
    gap = float(np.min(np.hypot(*(track_xz - mid).T)))
    return np.array([a + n * depth[0], b + n * depth[0], b - n * depth[1], a - n * depth[1]]), gap


def print_recipe(track):
    terr = json.loads((TRACK / "terrain.json").read_text())
    lat0, lon0 = terr["origin_latlon"]
    m = 111320.0 * terr["plan_scale"]
    kx = m * math.cos(math.radians(lat0))

    def ll(ring):
        return "[" + ", ".join("[%.6f, %.6f]" % (lat0 - z / m, lon0 + x / kx) for x, z in ring) + "]"

    f = Straight(track)
    xz = np.array([[p["p"][0], p["p"][2]] for p in track["points"]])
    stand = f.rect(WING_EAST[0], WING_WEST[1], STAND_FRONT_L, STAND_FRONT_L - STAND_DEPTH) + f.origin
    print("# main grandstand seating\npolygon = %s\nheight = %.1f\n" % (ll(stand), STAND_TOP))
    for name, ends, depth in (("H", LOTUS_H, LOTUS_H_STAND), ("K", LOTUS_K, LOTUS_K_STAND)):
        ring, gap = lotus_stand_ring(ends, depth, xz)
        print("# grandstand %s (disc line %.1f m from the centreline)\npolygon = %s\nheight = %.1f\n"
              % (name, gap, ll(ring), LOTUS_STAND_TOP))
        ring, _ = lotus_stand_ring(ends, (19.0, 19.0), xz)
        print("# exclude: the map's canopies, masts and seating slab of stand %s\npolygon = %s\n" % (name, ll(ring)))
    # Ground the map has as grass: game (x, z) corners read off Esri World Imagery.
    apron = f.rect(10.0, 340.0, 8.0, 74.0) + f.origin
    for name, ring in (
        ("pit lane, pit building and the paddock road behind it, up to the lake", apron),
        ("paddock east of the lake (helipad side)", [(-55, -215), (30, -160), (45, -75), (-15, -45), (-60, -60)]),
        ("paddock north of the lake", [(-330, -150), (-250, -190), (-55, -215), (-60, -182), (-250, -172), (-300, -158)]),
        ("paddock west of the lake", [(-395, -35), (-330, -150), (-300, -160), (-365, -25)]),
        ("car park inside turn 8", [(-185, -375), (-150, -390), (-105, -300), (-100, -215), (-190, -200), (-200, -300)]),
        ("plaza behind the main grandstand", [(-385, 165), (55, 62), (75, 120), (-370, 225)]),
    ):
        print("# %s\npolygon = %s\n" % (name, ll(np.array(ring, dtype=float))))
    # Housing estates of Jiading new town, east of the back straight beyond the motorway.
    d = np.array([math.cos(math.radians(15.0)), -math.sin(math.radians(15.0))])   # the street grid
    n = np.array([-d[1], d[0]])
    for name, height, size, centres in HOUSING:
        for x, z in centres:
            c = np.array([x, z], dtype=float)
            ring = [c - d * size[0] / 2 - n * size[1] / 2, c + d * size[0] / 2 - n * size[1] / 2,
                    c + d * size[0] / 2 + n * size[1] / 2, c - d * size[0] / 2 + n * size[1] / 2]
            print('[[surroundings.add]]\nkind = "building"\npolygon = %s\nheight = %.1f\nnote = "%s"\n'
                  % (ll(np.array(ring)), height, name))


def main():
    track = json.loads((TRACK / "track.json").read_text())
    OUT.mkdir(parents=True, exist_ok=True)
    entries = []
    models = [("main_complex",) + main_complex(track), ("lotus_h",) + lotus_row(LOTUS_H),
              ("lotus_k",) + lotus_row(LOTUS_K)]
    for name, mesh, anchor in models:
        stats = sg.write_glb(OUT / f"{name}.glb", mesh, f"shanghai_{name}", GENERATOR)
        imp = OUT / f"{name}.glb.import"
        if not imp.exists():    # Godot adds its uid to these: keep what is there
            imp.write_text(IMPORT.format(name=name), encoding="utf-8")
        # Models are built in world orientation around their anchor, 0.3 m above the terrain
        # (which is pressed that far under the road and its verges).
        entries.append({"model": name, "at": {"xz": [round(anchor[0], 2), round(anchor[1], 2)]},
                        "y_offset": 0.3, "yaw_deg": 0.0, "scale": 1.0})
        print(f"{name}: {stats['triangles']} triangles, {stats['bytes'] / 1024:.0f} kB, anchor {entries[-1]['at']['xz']}")
    (TRACK / "landmarks.json").write_text(json.dumps(entries, indent=1) + "\n", encoding="utf-8")
    if "--recipe" in sys.argv:
        print_recipe(track)


if __name__ == "__main__":
    main()
