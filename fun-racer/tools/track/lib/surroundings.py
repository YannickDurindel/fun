"""Surroundings step: what really stands around the circuit, baked from OpenStreetMap.

Reads track.json, road_profile.json and the terrain grids from the output folder, asks the
Overpass API for the map features around the lap (two requests, reduced and cached in
raw/surroundings_*.json) and writes, next to the other track files:

  landcover.png        uint8 class per 2.5 m cell over the near terrain rectangle
  landcover_far.png    the same per 50 m cell over the far terrain rectangle
  scenery.glb          buildings, grandstands, bridges, masts, tunnel shells (cad/track/scenery_glb.py)
  scenery_points.bin   tree instances, float32 (x, y, z, height, species)
  scenery.json         grid extents, record layout, water bodies, counts, attribution and the
                       buildings whose height is a guess

Frame: x = east, z = -north, y = elevation - origin_elevation_m, with the plan scale of the
track (geom.Projection). Rasters are row-major like the terrain grids (row = z, column = x);
cell (j, i) covers x0 + i * step .. x0 + (i + 1) * step.

Detail levels: everything inside the detail rectangle (the near terrain rectangle, or the
centreline box + [surroundings] margin_m); beyond it, out to far_margin_m, only buildings
taller than SKYLINE_HEIGHT; land cover out to the edge of the far terrain.

Nothing is placed on the road. Buildings and other solids are cut back to the road edge +
ROAD_CLEAR (street circuits have houses a few metres from the kerb); trees keep off the
verges of road_profile.json, and off RUNOFF m beyond the edge on the outside of corners.

Every output is optional for the game, and no other step reads them.
"""
import hashlib
import json
import math
import os
import re
import sys
import zlib

import numpy as np
from PIL import Image, ImageDraw
from scipy.spatial import cKDTree

from . import geom, net, terrain
from .net import BuildError
from .recipe import ROOT

CAD_DIR = os.path.join(ROOT, "cad", "track")
if CAD_DIR not in sys.path:
    sys.path.insert(0, CAD_DIR)
import scenery_glb as sg  # noqa: E402  (cad/track/scenery_glb.py)

CLASSES = ("grass", "forest", "water", "sand", "paved", "farmland", "rock", "gravel", "scrub", "beach")
GRASS, FOREST, WATER, SAND, PAVED, FARMLAND, ROCK, GRAVEL, SCRUB, BEACH = range(10)
SPECIES = ("broadleaved", "needleleaved", "palm", "bush")
BROADLEAVED, NEEDLELEAVED, PALM, BUSH = range(4)
# Tree cover of a cell, kept in a second raster while painting (not written out).
T_NONE, T_BROAD, T_NEEDLE, T_MIXED, T_PALM, T_ORCHARD, T_PARK, T_SCRUB = range(8)

NEAR_CELL = 2.5         # m: landcover.png
FAR_CELL = 50.0         # m: landcover_far.png
ROAD_CLEAR = 1.5        # m beyond the road edge that every solid is cut back to
RUNOFF = 35.0           # m beyond the road edge kept free of trees outside corners
CORNER_CURVATURE = 1.0 / 400.0
TREE_VERGE_GAP = 2.0    # m between the verge edge and the first tree
SKYLINE_HEIGHT = 25.0   # m: buildings beyond the detail rectangle are kept from this height
OVER_ROAD = 4.5         # m: a part that starts this high above the ground may span the road
DEFAULTS = {"far_margin_m": 3000.0, "default_levels": 2, "level_height_m": 3.0,
            "tree_density": 120.0, "tree_species": "mixed"}
MAX_TREES = 150000
QUERY_VERSION = 1        # raise when a query asks for more, to fetch every track again
NEAR_QUERY_SNAP = 0.002  # degrees: the query boxes are snapped outward, so a small change of
FAR_QUERY_SNAP = 0.02    # the track's size or bounds still finds its cache
ATTRIBUTION = "Surroundings (c) OpenStreetMap contributors (ODbL 1.0), via the Overpass API."

# Tags kept in the cache: the ones this module reads, and the name so a person can find the
# object again.
KEEP_TAGS = {
    "building", "building:part", "building:levels", "roof:levels", "height", "min_height",
    "building:min_level", "roof:shape", "roof:height", "building:colour", "roof:colour",
    "building:material", "name", "leisure", "natural", "landuse", "water", "waterway", "width",
    "highway", "bridge", "tunnel", "lanes", "surface", "amenity", "parking", "man_made",
    "leaf_type", "genus", "species", "railway", "covered", "place", "area", "power", "golf",
    "aeroway", "location", "layer", "type"}

NATURAL_CLASS = {
    "wood": FOREST, "water": WATER, "bay": WATER, "scrub": SCRUB, "heath": SCRUB,
    "grassland": GRASS, "fell": GRASS, "wetland": GRASS, "sand": SAND, "dune": SAND,
    "desert": SAND, "beach": BEACH, "shoal": BEACH, "bare_rock": ROCK, "scree": ROCK,
    "rock": ROCK, "shingle": GRAVEL, "mud": GRAVEL}
LANDUSE_CLASS = {
    "forest": FOREST, "meadow": GRASS, "grass": GRASS, "village_green": GRASS,
    "recreation_ground": GRASS, "cemetery": GRASS, "farmland": FARMLAND, "farmyard": FARMLAND,
    "orchard": FARMLAND, "vineyard": FARMLAND, "allotments": FARMLAND, "plant_nursery": FARMLAND,
    "greenhouse_horticulture": FARMLAND, "residential": PAVED, "commercial": PAVED,
    "industrial": PAVED, "retail": PAVED, "garages": PAVED, "railway": GRAVEL,
    "construction": GRAVEL, "brownfield": GRAVEL, "landfill": GRAVEL, "quarry": ROCK,
    "basin": WATER, "reservoir": WATER, "salt_pond": WATER}
LEISURE_CLASS = {"park": GRASS, "garden": GRASS, "pitch": GRASS, "golf_course": GRASS,
                 "playground": GRASS, "common": GRASS, "swimming_pool": WATER}
GOLF_CLASS = {"bunker": SAND, "green": GRASS, "fairway": GRASS, "tee": GRASS, "rough": GRASS,
              "water_hazard": WATER, "lateral_water_hazard": WATER}
UNPAVED = {"unpaved", "gravel", "fine_gravel", "compacted", "dirt", "ground", "earth", "pebblestone",
           "sand", "mud"}
# Road width in metres when the map has neither width nor lanes.
HIGHWAY_WIDTH = {
    "motorway": 11.0, "trunk": 9.0, "primary": 8.0, "secondary": 7.5, "tertiary": 6.5,
    "motorway_link": 6.0, "trunk_link": 6.0, "primary_link": 5.5, "secondary_link": 5.5,
    "tertiary_link": 5.0, "unclassified": 5.5, "residential": 5.5, "living_street": 5.0,
    "pedestrian": 5.0, "service": 3.5, "raceway": 12.0, "busway": 6.0, "road": 5.0, "track": 2.8}
FOOT_BRIDGES = {"footway": 3.0, "path": 2.5, "cycleway": 3.0, "steps": 2.5}
WATERWAY_WIDTH = {"river": 15.0, "canal": 10.0, "stream": 2.5}
# Height of a building without a height or a level count: ("L", levels) or ("M", metres).
TYPE_HEIGHT = {
    "house": ("L", 2), "detached": ("L", 2), "semidetached_house": ("L", 2), "terrace": ("L", 2),
    "farm": ("L", 2), "bungalow": ("L", 1), "cabin": ("L", 1), "static_caravan": ("M", 2.8),
    "residential": ("L", 3), "apartments": ("L", 5), "dormitory": ("L", 4), "hotel": ("L", 6),
    "commercial": ("L", 3), "retail": ("M", 6.0), "supermarket": ("M", 7.0), "office": ("L", 6),
    "industrial": ("M", 9.0), "warehouse": ("M", 9.0), "hangar": ("M", 12.0),
    "garage": ("M", 3.0), "garages": ("M", 3.0), "carport": ("M", 3.0), "shed": ("M", 2.8),
    "hut": ("M", 2.8), "kiosk": ("M", 3.0), "toilets": ("M", 3.0), "container": ("M", 2.8),
    "barn": ("M", 6.0), "farm_auxiliary": ("M", 6.0), "stable": ("M", 5.0), "cowshed": ("M", 5.0),
    "greenhouse": ("M", 4.0), "church": ("M", 14.0), "chapel": ("M", 9.0), "cathedral": ("M", 30.0),
    "mosque": ("M", 14.0), "temple": ("M", 12.0), "school": ("L", 3), "university": ("L", 4),
    "college": ("L", 4), "hospital": ("L", 5), "public": ("L", 3), "civic": ("L", 3),
    "government": ("L", 4), "stadium": ("M", 20.0), "train_station": ("M", 10.0),
    "transportation": ("M", 8.0), "parking": ("L", 4), "service": ("M", 4.0),
    "transformer_tower": ("M", 6.0), "roof": ("M", 4.5), "ruins": ("M", 4.0), "bunker": ("M", 4.0),
    "pavilion": ("M", 5.0), "sports_hall": ("M", 10.0), "sports_centre": ("M", 10.0),
    "tower": ("M", 20.0), "silo": ("M", 15.0), "storage_tank": ("M", 12.0), "bridge": ("M", 4.0),
    "construction": ("M", 12.0)}
# Types whose neighbours say more about their height than the type does.
TOWN_TYPES = {"yes", "residential", "apartments", "commercial", "retail", "office", "hotel",
              "mixed", "civic", "public"}
BLANK_TYPES = {"industrial", "warehouse", "hangar", "garage", "garages", "carport", "shed", "hut",
               "barn", "farm_auxiliary", "stable", "cowshed", "greenhouse", "service", "roof",
               "transformer_tower", "bunker", "ruins", "silo", "storage_tank", "container",
               "toilets", "church", "chapel", "cathedral", "stadium", "bridge", "tower"}
PITCHED_TYPES = {"house", "detached", "semidetached_house", "terrace", "farm", "bungalow", "cabin",
                 "barn", "farm_auxiliary", "chapel", "church", "residential", "hut", "shed", "stable",
                 "cowshed"}
PITCHED_SHAPES = {"gabled", "hipped", "half-hipped", "gambrel", "saltbox", "mansard"}
POINTED_SHAPES = {"pyramidal", "dome", "onion", "cone"}
STAND_NAME = re.compile(r"grandstand|tribun|tribün|gradas|gradinata|bleacher", re.IGNORECASE)
# Man-made things that are a plain mast or drum: (height, radius, material) when untagged.
MAST_TYPES = {
    "tower": (25.0, 2.5, "concrete"), "communications_tower": (60.0, 3.0, "concrete"),
    "mast": (25.0, 0.4, "metal"), "chimney": (40.0, 1.6, "concrete"),
    "water_tower": (30.0, 5.0, "concrete"), "lighthouse": (20.0, 2.5, "concrete"),
    "silo": (15.0, 3.0, "metal"), "storage_tank": (10.0, 6.0, "metal"),
    "flagpole": (10.0, 0.12, "metal"), "crane": (35.0, 0.8, "metal")}
LAMP_REACH = 60.0       # m from the centreline within which street lamps are built

# Facade and roof tints (sRGB), picked per building by a hash of its id.
FACADES = [(0.86, 0.82, 0.74), (0.80, 0.76, 0.70), (0.90, 0.88, 0.84), (0.78, 0.72, 0.64),
           (0.84, 0.80, 0.78), (0.74, 0.72, 0.70), (0.88, 0.80, 0.68), (0.82, 0.72, 0.64)]
SHEDS = [(0.78, 0.79, 0.80), (0.70, 0.72, 0.74), (0.86, 0.86, 0.84), (0.62, 0.66, 0.70)]
GLASS = [(0.42, 0.52, 0.62), (0.36, 0.46, 0.54), (0.50, 0.58, 0.64)]
FLAT_ROOFS = [(0.52, 0.52, 0.52), (0.44, 0.44, 0.45), (0.60, 0.59, 0.57), (0.38, 0.39, 0.41)]
TILE_ROOFS = [(0.58, 0.30, 0.22), (0.50, 0.26, 0.20), (0.36, 0.34, 0.34), (0.62, 0.38, 0.26)]
STAND_TINTS = [(0.30, 0.38, 0.55), (0.55, 0.57, 0.62), (0.60, 0.22, 0.20), (0.26, 0.42, 0.34)]
CSS_COLOURS = {
    "white": "#ffffff", "black": "#000000", "grey": "#808080", "gray": "#808080", "red": "#b22222",
    "brown": "#8b5a2b", "yellow": "#e8d44d", "beige": "#e8dcc0", "orange": "#e08a2c",
    "green": "#3c7a3c", "blue": "#3a5fa8", "silver": "#c0c0c0", "pink": "#e8b0b8",
    "maroon": "#800000", "tan": "#d2b48c", "cream": "#f2ead0", "darkgrey": "#555555",
    "darkgray": "#555555", "lightgrey": "#cfcfcf", "lightgray": "#cfcfcf"}

GLB_IMPORT = """[remap]

importer="scene"
importer_version=1
type="PackedScene"

[deps]

source_file="res://assets/tracks/{id}/scenery.glb"

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

# Class ids must reach the shader untouched: lossless, no mipmaps, and never re-imported as
# a VRAM-compressed texture when a 3D material uses it (detect_3d).
PNG_IMPORT = """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://assets/tracks/{id}/{name}"

[params]

compress/mode=0
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=false
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=false
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
"""


# ----------------------------------------------------------------------------- small helpers
def parse_length(value):
    """Metres from an OSM length ("12", "12.5 m", "40 ft", "40'"); None when unreadable."""
    m = re.match(r"^\s*([0-9]+(?:[.,][0-9]+)?)\s*(m|ft|feet|')?", str(value))
    if not m:
        return None
    v = float(m.group(1).replace(",", "."))
    return v * 0.3048 if m.group(2) in ("ft", "feet", "'") else v


def parse_number(value):
    try:
        return float(str(value).replace(",", ".").split(";")[0])
    except ValueError:
        return None


def srgb_to_linear(rgb):
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb)


def parse_colour(value):
    """sRGB triple from an OSM colour tag (a CSS name or #rgb / #rrggbb), or None."""
    v = str(value).strip().lower().replace(" ", "").replace("_", "")
    v = CSS_COLOURS.get(v, v)
    if re.fullmatch(r"#[0-9a-f]{3}", v):
        v = "#" + "".join(c * 2 for c in v[1:])
    if not re.fullmatch(r"#[0-9a-f]{6}", v):
        return None
    return tuple(int(v[k:k + 2], 16) / 255.0 for k in (1, 3, 5))


def pick(palette, ref, salt=""):
    return palette[zlib.crc32(f"{ref}{salt}".encode()) % len(palette)]


def simplify_index(pts, tol, closed=False):
    """Indices of the points Douglas-Peucker keeps of a polyline (n, 2), in order; a closed
    ring (no repeated end point) keeps at least three."""
    pts = np.asarray(pts, dtype=np.float64)
    n = len(pts)
    if n <= (3 if closed else 2) or tol <= 0.0:
        return np.arange(n)
    if closed:
        # Split at the two extreme points, so the ring's own first vertex is not special.
        a = int(np.argmin(pts[:, 0]))
        b = int(np.argmax(np.hypot(*(pts - pts[a]).T)))
        lo, hi = min(a, b), max(a, b)
        if lo == hi:
            return np.arange(n)
        back = np.concatenate([np.arange(hi, n), np.arange(0, lo + 1)])
        one = lo + simplify_index(pts[lo:hi + 1], tol)
        two = back[simplify_index(pts[back], tol)]
        out = np.concatenate([one[:-1], two[:-1]])
        return out if len(out) >= 3 else np.arange(n)
    keep = np.zeros(n, dtype=bool)
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        d = pts[j] - pts[i]
        length = float(np.hypot(*d))
        seg = pts[i + 1:j] - pts[i]
        if length < 1e-12:
            dist = np.hypot(seg[:, 0], seg[:, 1])
        else:
            dist = np.abs(seg[:, 0] * d[1] - seg[:, 1] * d[0]) / length
        k = int(np.argmax(dist))
        if dist[k] > tol:
            keep[i + 1 + k] = True
            stack += [(i, i + 1 + k), (i + 1 + k, j)]
    return np.flatnonzero(keep)


def simplify(pts, tol, closed=False):
    pts = np.asarray(pts, dtype=np.float64)
    return pts[simplify_index(pts, tol, closed)]


def points_in_rings(pts, rings):
    """Even-odd test of points (m, 2) against a set of rings."""
    pts = np.asarray(pts, dtype=np.float64).reshape(-1, 2)
    inside = np.zeros(len(pts), dtype=bool)
    for ring in rings:
        a, b = ring, np.roll(ring, -1, axis=0)
        for k in range(0, len(ring), 512):      # bounded memory on long coastlines
            ax, az, bx, bz = a[k:k + 512, 0], a[k:k + 512, 1], b[k:k + 512, 0], b[k:k + 512, 1]
            px, pz = pts[:, 0][:, None], pts[:, 1][:, None]
            cross = (az <= pz) != (bz <= pz)
            with np.errstate(divide="ignore", invalid="ignore"):
                x = ax + (pz - az) / (bz - az) * (bx - ax)
            inside ^= (np.sum(cross & (px < x), axis=1) & 1).astype(bool)
    return inside


def clip_rect(ring, x0, x1, z0, z1):
    """Ring clipped to a rectangle (Sutherland-Hodgman)."""
    if len(ring) == 0 or (ring[:, 0].min() >= x0 and ring[:, 0].max() <= x1
                          and ring[:, 1].min() >= z0 and ring[:, 1].max() <= z1):
        return ring
    for a, b, c in ((1.0, 0.0, -x0), (-1.0, 0.0, x1), (0.0, 1.0, -z0), (0.0, -1.0, z1)):
        ring = sg.clip_halfplane(ring, a, b, c)
        if len(ring) < 3:
            return np.zeros((0, 2))
    return ring


def assemble_rings(ways):
    """Closed rings from the member ways of a multipolygon (lists of points, joined end to
    end in either direction). Ways that do not close are dropped."""
    def key(p):
        return (round(float(p[0]), 7), round(float(p[1]), 7))

    rings, open_ways = [], []
    for w in ways:
        w = [tuple(p) for p in w]
        if len(w) >= 4 and key(w[0]) == key(w[-1]):
            rings.append(w[:-1])
        elif len(w) >= 2:
            open_ways.append(w)
    ends = {}
    for i, w in enumerate(open_ways):
        ends.setdefault(key(w[0]), []).append(i)
        ends.setdefault(key(w[-1]), []).append(i)
    used = [False] * len(open_ways)
    for i, w in enumerate(open_ways):
        if used[i]:
            continue
        used[i] = True
        chain = list(w)
        while key(chain[0]) != key(chain[-1]):
            nxt = next((j for j in ends.get(key(chain[-1]), []) if not used[j]), None)
            if nxt is None:
                chain = None
                break
            used[nxt] = True
            seg = open_ways[nxt]
            chain += seg[1:] if key(seg[0]) == key(chain[-1]) else seg[-2::-1]
        if chain and len(chain) >= 4:
            rings.append(chain[:-1])
    return rings


def polygons_from_rings(outers, inners):
    """[(outer ring, [holes])] from loose rings: every inner goes to the smallest outer ring
    that contains its first point."""
    outers = [sg.clean_ring(r) for r in outers]
    outers = [r for r in outers if len(r) >= 3]
    polys = [(r, []) for r in outers]
    areas = [abs(sg.signed_area(r)) for r in outers]
    for h in inners:
        h = sg.clean_ring(h)
        if len(h) < 3:
            continue
        host = [i for i, r in enumerate(outers) if points_in_rings(h[:1], [r])[0]]
        if host:
            polys[min(host, key=lambda i: areas[i])][1].append(h)
    return polys


# ----------------------------------------------------------------------------- Overpass
def near_query(bbox):
    s, w, n, e = bbox
    return f"""[out:json][timeout:{net.OVERPASS_TIMEOUT}][bbox:{s:.4f},{w:.4f},{n:.4f},{e:.4f}];
(
  wr["building"];
  wr["building:part"];
  wr["leisure"~"^(bleachers|park|garden|pitch|golf_course|playground|common|swimming_pool)$"];
  wr["natural"~"^(wood|water|bay|scrub|heath|grassland|fell|wetland|sand|dune|desert|beach|shoal|bare_rock|scree|rock|shingle|mud|tree_row)$"];
  node["natural"="tree"];
  wr["landuse"];
  wr["golf"];
  wr["waterway"~"^(river|canal|stream|riverbank|dock)$"];
  way["highway"];
  node["highway"="street_lamp"];
  wr["amenity"="parking"];
  wr["place"="square"];
  way["railway"~"^(rail|light_rail|narrow_gauge)$"];
  nwr["man_made"~"^(pier|breakwater|groyne|tower|communications_tower|mast|chimney|water_tower|lighthouse|silo|storage_tank|flagpole|crane)$"];
  node["power"="tower"];
  wr["aeroway"~"^(runway|taxiway|apron)$"];
);
out geom;"""


def far_query(bbox, sky):
    tall = '"height"~"^(2[5-9]|[3-9][0-9]|[1-9][0-9][0-9])"'
    high = '"building:levels"~"^([89]|[1-9][0-9])"'
    f = "({:.3f},{:.3f},{:.3f},{:.3f})".format(*bbox)
    k = "({:.3f},{:.3f},{:.3f},{:.3f})".format(*sky)
    return f"""[out:json][timeout:{net.OVERPASS_TIMEOUT}];
(
  wr["natural"~"^(wood|water|bay|scrub|heath|grassland|wetland|sand|dune|desert|beach|bare_rock|scree)$"]{f};
  way["natural"="coastline"]{f};
  wr["landuse"~"^(forest|meadow|grass|farmland|orchard|vineyard|residential|commercial|industrial|retail|quarry|basin|reservoir|railway)$"]{f};
  wr["leisure"~"^(park|golf_course)$"]{f};
  wr["waterway"~"^(riverbank|dock)$"]{f};
  way["waterway"~"^(river|canal)$"]{f};
  wr["aeroway"~"^(runway|apron)$"]{f};
  wr["building"][{tall}]{k};
  wr["building"][{high}]{k};
  wr["building:part"][{tall}]{k};
  wr["building:part"][{high}]{k};
  nwr["man_made"~"^(tower|communications_tower|chimney|mast|lighthouse)$"]{k};
);
out geom;"""


def _is_area(tags, closed):
    """Whether a closed way is a filled shape (as opposed to a road or a stream in a loop)."""
    if not closed:
        return False
    if tags.get("area") == "no":
        return False
    if any(k in tags for k in ("building", "building:part", "landuse", "leisure", "amenity", "golf", "place")):
        return True
    if "natural" in tags:
        return tags["natural"] not in ("coastline", "tree_row", "cliff")
    if "waterway" in tags:
        return tags["waterway"] in ("riverbank", "dock")
    if "aeroway" in tags:
        return tags["aeroway"] == "apron" or tags.get("area") == "yes"
    if "man_made" in tags:
        return True
    return tags.get("area") == "yes"


def line_is_used(tags):
    """Whether an open way is worth caching: the query asks for every highway, and most of a
    city's are footpaths and steps this step never draws."""
    hw = tags.get("highway")
    if hw is None or hw in HIGHWAY_WIDTH:
        return True
    return hw in FOOT_BRIDGES and tags.get("bridge") not in (None, "no")


def reduce_overpass(res, bbox, tol, building_tol=0.1, min_area=0.0, digits=6, query=""):
    """What is cached of an Overpass answer, as bytes: the tags of KEEP_TAGS and geometry
    clipped to ``bbox`` (s, w, n, e; buildings are kept whole), thinned to ``tol`` metres and
    rounded to ``digits`` decimals. Multipolygons are stored as assembled outer / inner rings.

    Elements, one per line: {"t": "n" | "w" | "r", "id", "tags", then "p": [lat, lon] for a
    node, "g": [lat, lon, lat, lon, ...] for a way (a closed way repeats its first point),
    "o" / "i": lists of such rings (not repeated) for a multipolygon}."""
    s, w, n, e = bbox
    lat_c = 0.5 * (s + n)
    kx = geom.EARTH_M_PER_DEG * math.cos(math.radians(lat_c))
    ky = geom.EARTH_M_PER_DEG

    def metres(pts):
        return np.stack([pts[:, 1] * kx, pts[:, 0] * ky], axis=1)

    def flat(pts):
        return [round(float(v), digits) for v in np.asarray(pts).reshape(-1)]

    def thin(pts, t, closed):
        pts = np.asarray(pts, dtype=np.float64)
        if len(pts) <= 3:
            return pts
        return pts[simplify_index(metres(pts), t, closed)]

    def ring(pts, t, clip):
        r = sg.clean_ring(pts, tol=1e-9)
        if len(r) < 3:
            return None
        if clip:
            r = clip_rect(r, s, n, w, e)       # points are (lat, lon)
            if len(r) < 3:
                return None
        r = thin(r, t, True)
        if abs(sg.signed_area(metres(r))) < max(min_area, 0.5):
            return None
        return r

    def pieces(pts):
        """Parts of a line inside the box (whole segments, so nothing is cut short)."""
        pts = np.asarray(pts, dtype=np.float64)
        a, b = pts[:-1], pts[1:]
        # A segment is kept when its own box touches the query box: that also catches one
        # that crosses a corner with both ends outside.
        seg = ((np.maximum(a[:, 0], b[:, 0]) >= s) & (np.minimum(a[:, 0], b[:, 0]) <= n)
               & (np.maximum(a[:, 1], b[:, 1]) >= w) & (np.minimum(a[:, 1], b[:, 1]) <= e))
        keep = np.zeros(len(pts), dtype=bool)
        keep[:-1] |= seg
        keep[1:] |= seg
        out, run = [], []
        for p, k in zip(pts, keep):
            if k:
                run.append(p)
            else:
                if len(run) >= 2:
                    out.append(np.array(run))
                run = []
        if len(run) >= 2:
            out.append(np.array(run))
        return out

    out = []
    for el in res.get("elements", []):
        tags = {k: v for k, v in (el.get("tags") or {}).items() if k in KEEP_TAGS}
        kind = el.get("type")
        solid = "building" in tags or "building:part" in tags or "man_made" in tags
        if kind == "node":
            if "lat" in el:
                out.append({"t": "n", "id": el["id"], "tags": tags,
                            "p": flat([el["lat"], el["lon"]])})
        elif kind == "way":
            g = [(p["lat"], p["lon"]) for p in el.get("geometry") or [] if p]
            if len(g) < 2:
                continue
            closed = len(g) >= 4 and g[0] == g[-1]
            if _is_area(tags, closed):
                r = ring(g, building_tol if solid else tol, not solid)
                if r is not None:
                    out.append({"t": "w", "id": el["id"], "tags": tags, "g": flat(np.concatenate([r, r[:1]]))})
            elif line_is_used(tags):
                for part in pieces(g):
                    part = thin(part, tol, False)
                    out.append({"t": "w", "id": el["id"], "tags": tags, "g": flat(part)})
        elif kind == "relation":
            if tags.get("type") != "multipolygon":
                continue
            ways = {"outer": [], "inner": []}
            for m in el.get("members", []):
                if m.get("type") == "way" and m.get("geometry"):
                    role = "inner" if m.get("role") == "inner" else "outer"
                    ways[role].append([(p["lat"], p["lon"]) for p in m["geometry"] if p])
            rings = {}
            for role in ("outer", "inner"):
                rs = [ring(r, building_tol if solid else tol, not solid) for r in assemble_rings(ways[role])]
                rings[role] = [flat(r) for r in rs if r is not None]
            if rings["outer"]:
                out.append({"t": "r", "id": el["id"], "tags": tags, "o": rings["outer"], "i": rings["inner"]})
    head = {"source": "Overpass API", "attribution": ATTRIBUTION,
            "osm_base": (res.get("osm3s") or {}).get("timestamp_osm_base", ""),
            "bbox": [s, w, n, e], "query": query}
    return _cache_bytes(head, out)


def _cache_bytes(head, elements):
    """A cache file: one element per line, so a refreshed answer makes a readable diff."""
    lines = ",\n".join(json.dumps(e, separators=(",", ":"), ensure_ascii=False) for e in elements)
    return (json.dumps(head, separators=(",", ":"))[:-1] + ',"elements":[\n' + lines + "\n]}\n").encode()


def _snap_box(lats, lons, snap):
    return (math.floor(min(lats) / snap) * snap, math.floor(min(lons) / snap) * snap,
            math.ceil(max(lats) / snap) * snap, math.ceil(max(lons) / snap) * snap)


def _latlon_box(proj, rect, snap):
    """(s, w, n, e) around a game rectangle [x0, x1, z0, z1], snapped outward."""
    x0, x1, z0, z1 = rect
    corners = [proj.to_latlon(x, z) for x in (x0, x1) for z in (z0, z1)]
    return _snap_box([c[0] for c in corners], [c[1] for c in corners], snap)


class Feature:
    """One map object in game metres: ``rings`` = (outers, inners) for a shape, ``line`` for
    an open way, ``point`` for a node."""
    __slots__ = ("ref", "tags", "outers", "inners", "line", "point")

    def __init__(self, ref, tags):
        self.ref, self.tags = ref, tags
        self.outers, self.inners, self.line, self.point = [], [], None, None

    @property
    def rings(self):
        return self.outers + self.inners


def load_features(body, proj):
    """Features of a reduced cache file, projected to game metres."""
    def xz(flat):
        ll = np.asarray(flat, dtype=np.float64).reshape(-1, 2)
        x, z = proj.to_xz(ll[:, 0], ll[:, 1])
        return np.stack([x, z], axis=1)

    data = json.loads(body)
    out = []
    for el in data["elements"]:
        t = {"n": "node", "w": "way", "r": "relation"}[el["t"]]
        f = Feature(f"{t}/{el['id']}", el.get("tags", {}))
        if t == "node":
            f.point = xz(el["p"])[0]
        elif t == "way":
            pts = xz(el["g"])
            closed = len(pts) >= 4 and el["g"][:2] == el["g"][-2:]
            if _is_area(f.tags, closed):
                f.outers = [sg.clean_ring(pts)]
            else:
                f.line = pts
        else:
            f.outers = [sg.clean_ring(xz(r)) for r in el["o"]]
            f.inners = [sg.clean_ring(xz(r)) for r in el.get("i", [])]
        f.outers = [r for r in f.outers if len(r) >= 3]
        f.inners = [r for r in f.inners if len(r) >= 3]
        if f.outers or f.line is not None or f.point is not None:
            out.append(f)
    return out, data


def _cache_name(kind, boxes):
    """Named after the query boxes and QUERY_VERSION, not the query text: rewording a query
    or changing the timeout must not orphan every committed cache."""
    key = f"{QUERY_VERSION}:{kind}:" + ";".join(",".join(f"{v:.4f}" for v in b) for b in boxes)
    return f"surroundings_{kind}_{hashlib.sha1(key.encode()).hexdigest()[:10]}.json"


def queries(proj, near_rect, far_rect, far_margin):
    """{"near": (query, bbox, cache file), "far": ...} for a track's rectangles."""
    nb = _latlon_box(proj, near_rect, NEAR_QUERY_SNAP)
    fb = _latlon_box(proj, far_rect, FAR_QUERY_SNAP)
    sky = _latlon_box(proj, [near_rect[0] - far_margin, near_rect[1] + far_margin,
                             near_rect[2] - far_margin, near_rect[3] + far_margin], FAR_QUERY_SNAP)
    return {"near": (near_query(nb), nb, _cache_name("near", [nb])),
            "far": (far_query(fb, sky), fb, _cache_name("far", [fb, sky]))}


def fetch(fetcher, proj, near_rect, far_rect, far_margin, log=print):
    """(near features, far features, OSM timestamp), from the cache or the Overpass API."""
    out, stamp = {}, ""
    for kind, (query, bbox, name) in queries(proj, near_rect, far_rect, far_margin).items():
        fresh = not fetcher.cached(name)
        if fresh and not fetcher.offline:
            log(f"  Overpass: {kind} features ...")
        if kind == "near":
            def reduce(res, bbox=bbox, query=query):
                return reduce_overpass(res, bbox, tol=0.4, building_tol=0.1, query=query)
        else:
            def reduce(res, bbox=bbox, query=query):
                # Coastlines and towers keep their shape; land cover only has to fill 50 m cells.
                def sharp(e):
                    t = e.get("tags") or {}
                    return t.get("natural") == "coastline" or "building" in t or "building:part" in t or "man_made" in t
                fine = {"elements": [e for e in res["elements"] if sharp(e)], "osm3s": res.get("osm3s")}
                rest = {"elements": [e for e in res["elements"] if not sharp(e)]}
                a = json.loads(reduce_overpass(fine, bbox, tol=1.0, building_tol=0.5, query=query))
                b = json.loads(reduce_overpass(rest, bbox, tol=10.0, min_area=4000.0, digits=5))
                return _cache_bytes({k: v for k, v in a.items() if k != "elements"}, a["elements"] + b["elements"])
        body = net.fetch_overpass(fetcher, query, name, reduce)
        if fresh:
            gd = fetcher.path(".gdignore")
            if not os.path.exists(gd):
                open(gd, "w").close()
        feats, data = load_features(body, proj)
        out[kind] = feats
        stamp = stamp or data.get("osm_base", "")
        log(f"  {kind}: {len(feats)} map features ({name}, {len(body) / 1024:.0f} kB)")
    return out["near"], out["far"], stamp


# ----------------------------------------------------------------------------- ground, road
class Ground:
    """The baked terrain: bilinear height from the near grid, the far grid outside it."""

    def __init__(self, out_dir):
        with open(os.path.join(out_dir, "terrain.json"), encoding="utf-8") as f:
            self.meta = json.load(f)
        nr, fr = self.meta["near"], self.meta["far"]
        self.near = np.fromfile(os.path.join(out_dir, nr["file"]), dtype="<f4").reshape(nr["nz"], nr["nx"])
        self.far = np.fromfile(os.path.join(out_dir, fr["file"]), dtype="<f4").reshape(fr["nz"], fr["nx"])
        self.dist = np.fromfile(os.path.join(out_dir, nr["dist_file"]), dtype="<u2").reshape(nr["nz"], nr["nx"])
        self.near_rect = [nr["x0"], nr["x0"] + (nr["nx"] - 1) * nr["step"],
                          nr["z0"], nr["z0"] + (nr["nz"] - 1) * nr["step"]]
        self.far_rect = [fr["x0"], fr["x0"] + (fr["nx"] - 1) * fr["step"],
                         fr["z0"], fr["z0"] + (fr["nz"] - 1) * fr["step"]]

    @staticmethod
    def _bilinear(grid, meta, x, z):
        u = np.clip((x - meta["x0"]) / meta["step"], 0.0, meta["nx"] - 1.0)
        v = np.clip((z - meta["z0"]) / meta["step"], 0.0, meta["nz"] - 1.0)
        i = np.minimum(u.astype(np.int64), meta["nx"] - 2)
        j = np.minimum(v.astype(np.int64), meta["nz"] - 2)
        tu, tv = u - i, v - j
        a = grid[j, i] + (grid[j, i + 1] - grid[j, i]) * tu
        b = grid[j + 1, i] + (grid[j + 1, i + 1] - grid[j + 1, i]) * tu
        return a + (b - a) * tv

    def in_near(self, x, z):
        r = self.near_rect
        return (x >= r[0]) & (x <= r[1]) & (z >= r[2]) & (z <= r[3])

    def height(self, x, z):
        x = np.asarray(x, dtype=np.float64)
        z = np.asarray(z, dtype=np.float64)
        near = self._bilinear(self.near, self.meta["near"], x, z)
        far = self._bilinear(self.far, self.meta["far"], x, z)
        return np.where(self.in_near(x, z), near, far)

    def track_distance(self, x, z):
        """Distance to the centreline in metres (terrain_dist.bin); large outside the near grid."""
        m = self.meta["near"]
        i = np.clip(np.rint((np.asarray(x) - m["x0"]) / m["step"]).astype(np.int64), 0, m["nx"] - 1)
        j = np.clip(np.rint((np.asarray(z) - m["z0"]) / m["step"]).astype(np.int64), 0, m["nz"] - 1)
        return np.where(self.in_near(np.asarray(x), np.asarray(z)), self.dist[j, i] * 0.1, 6553.5)


class Corridor:
    """The road and its verges, for keeping things off them."""

    def __init__(self, track, profile):
        pts = np.array([p["p"] for p in track["points"]], dtype=np.float64)
        self.xz, self.y = pts[:, [0, 2]], pts[:, 1]
        self.n = len(pts)
        self.step = float(track["step"])
        t = np.roll(self.xz, -1, axis=0) - np.roll(self.xz, 1, axis=0)
        self.tan = t / np.hypot(t[:, 0], t[:, 1])[:, None]
        self.right = np.stack([-self.tan[:, 1], self.tan[:, 0]], axis=1)
        self.half = 0.5 * np.asarray(profile["width"], dtype=np.float64)
        self.bank = np.asarray(profile["bank"], dtype=np.float64)
        self.verge_l = np.asarray(profile["verge_left"], dtype=np.float64)
        self.verge_r = np.asarray(profile["verge_right"], dtype=np.float64)
        # Turning rate towards the right, per metre, smoothed over ~40 m.
        turn = np.sum((np.roll(self.tan, -1, axis=0) - np.roll(self.tan, 1, axis=0)) * self.right, axis=1)
        turn = turn / (2.0 * self.step)
        w = max(1, int(round(20.0 / self.step)))
        kernel = np.ones(2 * w + 1) / (2 * w + 1)
        self.turn = np.convolve(np.concatenate([turn[-w:], turn, turn[:w]]), kernel, mode="valid")
        self.tree = cKDTree(self.xz)
        # [[surroundings.roof]] stretches: where the road is under a shell, and its top.
        self.roofed = np.zeros(self.n, dtype=bool)
        self.roof_top = np.zeros(self.n)

    def roof_over(self, outer):
        """Top of the tunnel shell under a footprint the roofed road runs through, or None."""
        cand = np.flatnonzero(self.roofed)
        if len(cand) == 0:
            return None
        inside = points_in_rings(self.xz[cand], [outer])
        return float(self.roof_top[cand][inside].max()) if inside.any() else None

    def nearest(self, pts):
        """(index of the nearest centreline point, signed lateral offset (+ = right), distance)."""
        pts = np.asarray(pts, dtype=np.float64).reshape(-1, 2)
        dist, idx = self.tree.query(pts)
        d = pts - self.xz[idx]
        return idx, np.sum(d * self.right[idx], axis=1), dist

    def on_road(self, pts, margin=ROAD_CLEAR):
        idx, _, dist = self.nearest(pts)
        return dist < self.half[idx] + margin

    def keep_out(self, pts):
        """True where a tree may not stand: road, verge, and the run-off outside corners."""
        idx, lat, dist = self.nearest(pts)
        verge = np.where(lat > 0.0, self.verge_r[idx], self.verge_l[idx])
        limit = self.half[idx] + verge + TREE_VERGE_GAP
        outside = (np.abs(self.turn[idx]) > CORNER_CURVATURE) & (np.sign(lat) == -np.sign(self.turn[idx]))
        # A verge the road step narrowed has something real behind it (a wall, another leg of
        # the lap): there the run-off is not assumed.
        limit = np.where(outside & (verge >= 29.0), np.maximum(limit, self.half[idx] + RUNOFF), limit)
        return dist < limit

    def surface_y(self, idx, lateral):
        """Height of the banked road plane at a lateral offset from point ``idx``."""
        return self.y[idx] - lateral * np.sin(self.bank[idx])

    def _edge(self, i, side, margin):
        return self.xz[i] + self.right[i] * side * (self.half[i] + margin)

    def cut(self, ring, margin=ROAD_CLEAR):
        """Pieces of a footprint outside the road + ``margin``: [] when nothing is left, the
        ring itself when it does not touch the road. A footprint the road runs through comes
        back as one piece per side."""
        ring = sg.clean_ring(ring)
        if len(ring) < 3:
            return []
        idx, _, dist = self.nearest(ring)
        edges = np.hypot(*(np.roll(ring, -1, axis=0) - ring).T)
        if dist.min() > (self.half[idx] + margin).max() + 0.5 * edges.max():
            return [ring]
        # Points every 2 m along the outline, so that a wall crossing the road is seen.
        dense = []
        for a, b, length in zip(ring, np.roll(ring, -1, axis=0), edges):
            k = max(1, int(math.ceil(length / 2.0)))
            dense.append(a + (b - a) * (np.arange(k) / k)[:, None])
        pts = np.concatenate(dense)
        idx, lat, dist = self.nearest(pts)
        gap = dist - (self.half[idx] + margin)
        out = gap >= 0.0
        if out.all():
            return [ring]
        if not out.any():
            return []
        m = len(pts)
        first = next(k for k in range(m) if out[k] and not out[k - 1])
        order = [(first + k) % m for k in range(m)]
        # Arcs of the outline outside the road, each with the point where it leaves and the
        # point where it comes back, moved onto the limit line.
        arcs, cur = [], []
        for k in order:
            if out[k]:
                cur.append(k)
            elif cur:
                arcs.append(cur)
                cur = []
        if cur:
            arcs.append(cur)

        def crossing(k_out, k_in):
            f = gap[k_out] / max(gap[k_out] - gap[k_in], 1e-9)
            return pts[k_out] + (pts[k_in] - pts[k_out]) * f

        info = []
        for arc in arcs:
            a, b = arc[0], arc[-1]
            start = crossing(a, (a - 1) % m)
            end = crossing(b, (b + 1) % m)
            body = np.concatenate([[start], pts[arc], [end]])
            info.append({"pts": body, "i0": int(idx[a]), "i1": int(idx[b]),
                         "s0": 1.0 if lat[a] > 0.0 else -1.0, "s1": 1.0 if lat[b] > 0.0 else -1.0})

        def along_edge(i0, i1, side):
            """Limit-line points from centreline point i0 to i1, the short way round the lap."""
            d = (i1 - i0) % self.n
            steps = d if d <= self.n - d else d - self.n
            if abs(steps) * self.step > 250.0:
                return np.zeros((0, 2))     # two legs of the lap side by side: join straight
            ks = [(i0 + j * (1 if steps > 0 else -1)) % self.n for j in range(1, abs(steps))]
            return np.array([self._edge(k, side, margin) for k in ks]).reshape(-1, 2)

        pieces, used = [], [False] * len(info)
        for a0 in range(len(info)):
            if used[a0]:
                continue
            loop, a = [], a0
            while not used[a]:
                used[a] = True
                loop.append(info[a]["pts"])
                # The outline comes back out of the road on the same side at the next arc
                # that starts there: a notch if it is the very next one, else the far end of
                # a stretch where the road runs through the footprint.
                side = info[a]["s1"]
                nxt = next(((a + j) % len(info) for j in range(1, len(info) + 1)
                            if info[(a + j) % len(info)]["s0"] == side), a)
                loop.append(along_edge(info[a]["i1"], info[nxt]["i0"], side))
                a = nxt
            piece = sg.clean_ring(np.concatenate([p for p in loop if len(p)]), tol=1e-3)
            if len(piece) >= 3:
                piece = simplify(piece, 0.05, closed=True)
                if abs(sg.signed_area(piece)) > 2.0:
                    pieces.append(piece)
        return pieces


# ----------------------------------------------------------------------------- rasters
class Raster:
    """A class grid; ``paint`` fills cells whose centre lies inside a shape (even-odd)."""

    def __init__(self, x0, z0, step, nx, nz):
        self.x0, self.z0, self.step, self.nx, self.nz = float(x0), float(z0), float(step), int(nx), int(nz)
        self.cls = np.zeros((self.nz, self.nx), dtype=np.uint8)
        self.trees = np.zeros((self.nz, self.nx), dtype=np.uint8)
        self.built = np.zeros((self.nz, self.nx), dtype=bool)

    def meta(self, name):
        return {"file": name, "x0": self.x0, "z0": self.z0, "step": self.step, "nx": self.nx, "nz": self.nz}

    def mask(self, rings):
        """(row slice, column slice, bool mask) of the cells inside ``rings``, or None."""
        a = np.concatenate(rings)
        b = np.concatenate([np.roll(r, -1, axis=0) for r in rings])
        za, zb = a[:, 1], b[:, 1]
        j0 = np.clip(np.ceil((np.minimum(za, zb) - self.z0) / self.step - 0.5), 0, self.nz).astype(np.int64)
        j1 = np.clip(np.ceil((np.maximum(za, zb) - self.z0) / self.step - 0.5), 0, self.nz).astype(np.int64)
        cnt = j1 - j0
        total = int(cnt.sum())
        if total == 0:
            return None
        e = np.repeat(np.arange(len(a)), cnt)
        j = j0[e] + np.arange(total) - np.repeat(np.cumsum(cnt) - cnt, cnt)
        zc = self.z0 + (j + 0.5) * self.step
        x = a[e, 0] + (zc - za[e]) / (zb[e] - za[e]) * (b[e, 0] - a[e, 0])
        c = np.clip(np.ceil((x - self.x0) / self.step - 0.5), 0, self.nx).astype(np.int64)
        ja, jb, ca, cb = int(j.min()), int(j.max()) + 1, int(c.min()), int(c.max())
        if cb <= ca:
            return None
        diff = np.zeros((jb - ja, cb - ca + 1), dtype=np.int32)
        np.add.at(diff, (j - ja, c - ca), 1)
        inside = (np.cumsum(diff, axis=1)[:, :-1] & 1).astype(bool)
        return slice(ja, jb), slice(ca, cb), inside

    def paint(self, rings, cls, trees=T_NONE, built=False):
        rings = [r for r in rings if len(r) >= 3]
        if not rings:
            return
        m = self.mask(rings)
        if m is None:
            return
        rows, cols, inside = m
        if cls is not None:
            self.cls[rows, cols][inside] = cls
            self.trees[rows, cols][inside] = trees
        if built:
            self.built[rows, cols][inside] = True

    def paint_lines(self, lines, cls, trees=T_NONE):
        """``lines``: [(points (n, 2), width in metres)], drawn as strips at least a cell wide."""
        if not lines:
            return
        img = Image.new("L", (self.nx, self.nz), 0)
        draw = ImageDraw.Draw(img)
        for pts, width in lines:
            # PIL puts whole coordinates on pixel centres; a cell's centre is at index + 0.5.
            px = (np.asarray(pts) - [self.x0, self.z0]) / self.step - 0.5
            draw.line([tuple(p) for p in px.tolist()], fill=1, width=max(1, int(round(width / self.step))),
                      joint="curve")
        hit = np.asarray(img, dtype=bool)
        self.cls[hit] = cls
        self.trees[hit] = trees

    def at(self, grid, x, z):
        i = np.clip(np.floor((np.asarray(x) - self.x0) / self.step).astype(np.int64), 0, self.nx - 1)
        j = np.clip(np.floor((np.asarray(z) - self.z0) / self.step).astype(np.int64), 0, self.nz - 1)
        return grid[j, i]

    def save(self, path):
        Image.fromarray(self.cls, mode="L").save(path, optimize=True)


def land_class(tags):
    """(class, tree cover) a shape paints, or None when it says nothing about the ground."""
    nat, land, lei = tags.get("natural"), tags.get("landuse"), tags.get("leisure")
    leaf = {"broadleaved": T_BROAD, "needleleaved": T_NEEDLE}.get(tags.get("leaf_type"), T_MIXED)
    if "palm" in (tags.get("genus", "") + tags.get("species", "")).lower() or tags.get("leaf_type") == "palm":
        leaf = T_PALM
    surface = tags.get("surface", "")
    if nat in NATURAL_CLASS:
        c = NATURAL_CLASS[nat]
        return c, (leaf if c == FOREST else T_SCRUB if c == SCRUB else T_NONE)
    if land in LANDUSE_CLASS:
        c = LANDUSE_CLASS[land]
        cover = leaf if c == FOREST else T_ORCHARD if land == "orchard" else T_PARK if land == "cemetery" else T_NONE
        return c, cover
    if tags.get("golf") in GOLF_CLASS:
        return GOLF_CLASS[tags["golf"]], T_NONE
    if lei in LEISURE_CLASS:
        c = LEISURE_CLASS[lei]
        if lei == "pitch" and surface in ("asphalt", "concrete", "paved", "acrylic", "tartan"):
            return PAVED, T_NONE
        if lei == "pitch" and surface in ("sand", "clay", "dirt"):
            return SAND if surface == "sand" else GRAVEL, T_NONE
        return c, (T_PARK if lei in ("park", "garden") else T_NONE)
    if tags.get("waterway") in ("riverbank", "dock"):
        return WATER, T_NONE
    if tags.get("amenity") == "parking":
        if tags.get("parking") in ("underground", "multi-storey") or "building" in tags:
            return None
        return (GRASS if surface == "grass" else GRAVEL if surface in UNPAVED else PAVED), T_NONE
    if tags.get("place") == "square" or tags.get("aeroway") in ("apron", "runway", "taxiway"):
        return PAVED, T_NONE
    if tags.get("man_made") == "pier":
        return PAVED, T_NONE
    if tags.get("man_made") in ("breakwater", "groyne"):
        return ROCK, T_NONE
    if "highway" in tags and tags.get("area") == "yes":
        return (GRAVEL if surface in UNPAVED else PAVED), T_NONE
    return None


def line_strip(tags):
    """(class, width in metres) of the strip an open way paints, or None."""
    if tags.get("tunnel") not in (None, "no") or tags.get("bridge") not in (None, "no"):
        return None    # a tunnel leaves no trace; a bridge is a deck, not ground
    width = parse_length(tags["width"]) if "width" in tags else None
    hw = tags.get("highway")
    if hw in HIGHWAY_WIDTH:
        lanes = parse_number(tags.get("lanes", ""))
        w = width or (lanes * 3.3 if lanes else HIGHWAY_WIDTH[hw])
        loose = tags.get("surface") in UNPAVED or (hw == "track" and tags.get("surface") in (None, "grass"))
        if tags.get("surface") == "grass":
            return None
        return (GRAVEL if loose else PAVED), min(w, 40.0)
    if tags.get("railway") in ("rail", "light_rail", "narrow_gauge"):
        return GRAVEL, 4.0
    if tags.get("waterway") in WATERWAY_WIDTH:
        return WATER, min(width or WATERWAY_WIDTH[tags["waterway"]], 80.0)
    if tags.get("aeroway") in ("runway", "taxiway"):
        return PAVED, width or (45.0 if tags["aeroway"] == "runway" else 20.0)
    if tags.get("man_made") == "pier":
        return PAVED, width or 3.0
    return None


# ----------------------------------------------------------------------------- the sea
def sea_polygons(coast, rect, log=print):
    """Sea inside ``rect`` = [x0, x1, z0, z1] from natural=coastline ways (lists of (n, 2)
    points in map order: land on the left of the way, water on the right, north up).
    Returns [(outer ring, [island rings])]."""
    x0, x1, z0, z1 = rect
    w, h = x1 - x0, z1 - z0

    def key(p):
        return (round(float(p[0]), 2), round(float(p[1]), 2))

    # Join the ways into chains (each way ends where the next begins).
    lines = [np.asarray(c, dtype=np.float64) for c in coast if len(c) >= 2]
    starts = {}
    for i, c in enumerate(lines):
        starts.setdefault(key(c[0]), []).append(i)
    used = [False] * len(lines)
    has_prev = {key(c[-1]) for c in lines}
    chains = []
    for i in sorted(range(len(lines)), key=lambda i: key(lines[i][0]) in has_prev):
        if used[i]:
            continue
        used[i] = True
        chain = [lines[i]]
        while True:
            nxt = next((j for j in starts.get(key(chain[-1][-1]), []) if not used[j]), None)
            if nxt is None:
                break
            used[nxt] = True
            chain.append(lines[nxt][1:])
        chains.append(np.concatenate(chain))

    def param(p):
        """Position on the border, growing in the positive direction of the (x, z) plane."""
        x, z = p
        d = [abs(z - z0), abs(x - x1), abs(z - z1), abs(x - x0)]
        k = int(np.argmin(d))
        return [x - x0, w + (z - z0), w + h + (x1 - x), 2 * w + h + (z1 - z)][k]

    def clip_segment(a, b):
        t0, t1 = 0.0, 1.0
        d = b - a
        for p, q in ((-d[0], a[0] - x0), (d[0], x1 - a[0]), (-d[1], a[1] - z0), (d[1], z1 - a[1])):
            if abs(p) < 1e-12:
                if q < 0.0:
                    return None
                continue
            t = q / p
            if p < 0.0:
                t0 = max(t0, t)
            else:
                t1 = min(t1, t)
        return (t0, t1) if t0 < t1 else None

    pieces, islands = [], []
    for chain in chains:
        closed = len(chain) >= 4 and key(chain[0]) == key(chain[-1])
        inside = ((chain[:, 0] >= x0) & (chain[:, 0] <= x1) & (chain[:, 1] >= z0) & (chain[:, 1] <= z1))
        if closed and inside.all():
            islands.append(sg.clean_ring(chain))
            continue
        if closed:      # start outside the map, so every stretch inside runs border to border
            k = int(np.argmin(inside))
            chain = np.concatenate([chain[k:-1], chain[:k + 1]])
        run = []
        for a, b in zip(chain[:-1], chain[1:]):
            c = clip_segment(a, b)
            if c is None:
                continue
            t0, t1 = c
            if t0 > 0.0 or not run:
                if len(run) >= 2:
                    pieces.append(np.array(run))
                run = [a + (b - a) * t0]
            run.append(a + (b - a) * t1)
            if t1 < 1.0:
                pieces.append(np.array(run))
                run = []
        if len(run) >= 2:
            pieces.append(np.array(run))

    def on_border(p):
        return min(abs(p[0] - x0), abs(p[0] - x1), abs(p[1] - z0), abs(p[1] - z1)) < 1e-6

    whole = [p for p in pieces if on_border(p[0]) and on_border(p[-1])]
    if len(whole) < len(pieces):
        log(f"  coastline: {len(pieces) - len(whole)} stretch(es) end inside the map and were ignored")
    corners = [(0.0, (x0, z0)), (w, (x1, z0)), (w + h, (x1, z1)), (2 * w + h, (x0, z1))]
    perimeter = 2 * (w + h)
    entries = sorted((param(p[0]), i) for i, p in enumerate(whole))
    seas, done = [], [False] * len(whole)
    for i0 in range(len(whole)):
        if done[i0]:
            continue
        ring, i = [], i0
        while not done[i]:
            done[i] = True
            ring.append(whole[i])
            # Water is on the right of the coastline, which is the positive direction along
            # the border in this frame: walk it to where the next stretch of coast comes in.
            t = param(whole[i][-1])
            ahead = [((e - t) % perimeter, j) for e, j in entries]
            gap, nxt = min(ahead)
            passed = sorted(((c - t) % perimeter, xy) for c, xy in corners if 0.0 < (c - t) % perimeter < gap)
            if passed:
                ring.append(np.array([xy for _, xy in passed]))
            i = nxt
        r = sg.clean_ring(np.concatenate(ring), tol=1e-6)
        if len(r) >= 3 and abs(sg.signed_area(r)) > 1.0:
            seas.append((r, []))
    isles = [r for r in islands if sg.signed_area(r) < 0.0]     # land on the left = an island
    if not seas and isles:
        seas.append((np.array([(x0, z0), (x1, z0), (x1, z1), (x0, z1)]), []))
    for r in isles:
        host = next((s for s in seas if points_in_rings(r[:1], [s[0]])[0]), None)
        if host is not None:
            host[1].append(r)
    return seas


# ----------------------------------------------------------------------------- buildings
class Solid:
    """A building, part, stand or other extruded shape before it becomes triangles."""
    __slots__ = ("ref", "tags", "kind", "outer", "holes", "type", "height", "min_height", "source",
                 "area", "centre", "name")

    def __init__(self, ref, tags, outer, holes):
        self.ref, self.tags, self.outer, self.holes = ref, tags, outer, holes
        self.kind = "building"
        self.type = tags.get("building") or tags.get("building:part") or "yes"
        self.height = self.min_height = None
        self.source = ""
        self.area = abs(sg.signed_area(outer)) - sum(abs(sg.signed_area(h)) for h in holes)
        self.centre = outer.mean(axis=0)
        self.name = tags.get("name", "")


def classify_solid(s):
    t = s.tags
    if (t.get("building") in ("grandstand", "bleachers") or t.get("leisure") == "bleachers"
            or (STAND_NAME.search(s.name) and t.get("building") in ("yes", "stadium", "roof", None))):
        s.kind = "stand"
    elif t.get("building") in ("roof", "carport") or t.get("building:part") == "roof":
        s.kind = "canopy"
    elif "building" not in t and "building:part" in t:
        s.kind = "part"


def tagged_height(tags, level_height):
    """(height, min height) in metres from the tags; height is None when they do not say."""
    h = parse_length(tags["height"]) if "height" in tags else None
    levels = parse_number(tags["building:levels"]) if "building:levels" in tags else None
    if h is None and levels is not None and levels > 0:
        h = (levels + (parse_number(tags.get("roof:levels", "0")) or 0.0) * 0.6) * level_height
    lo = parse_length(tags["min_height"]) if "min_height" in tags else None
    if lo is None and "building:min_level" in tags:
        lo = (parse_number(tags["building:min_level"]) or 0.0) * level_height
    if h is not None and (h <= 0.0 or h > 1000.0):
        h = None
    return h, max(0.0, lo or 0.0)


def default_height(kind, area, cfg):
    spec = TYPE_HEIGHT.get(kind)
    if spec is None:
        # An untyped shed-sized or hall-sized outline is not a two-storey house.
        if area < 25.0:
            return 2.8
        return cfg["default_levels"] * cfg["level_height_m"]
    return spec[1] * cfg["level_height_m"] if spec[0] == "L" else spec[1]


def resolve_heights(solids, cfg):
    """Fills in ``height`` / ``source`` of every solid: the tags, then the median of the
    tagged neighbours for town buildings, then a default by type."""
    known = []
    for s in solids:
        if s.height is not None:
            continue    # set by the recipe
        h, lo = tagged_height(s.tags, cfg["level_height_m"])
        s.min_height = lo
        if h is not None:
            s.height, s.source = h, "tags"
            if s.kind == "building":
                known.append(s)
    tree = cKDTree(np.array([s.centre for s in known])) if len(known) >= 3 else None
    heights = np.array([s.height for s in known])
    for s in solids:
        if s.height is not None:
            continue
        s.height, s.source = default_height(s.type, s.area, cfg), "type default"
        if s.kind == "building" and s.type in TOWN_TYPES and s.area >= 25.0 and tree is not None:
            near = tree.query_ball_point(s.centre, 150.0)
            if len(near) >= 3:
                s.height, s.source = float(np.median(heights[near])), "neighbours"
    for s in solids:
        if s.min_height is None:
            s.min_height = 0.0
        if s.min_height >= s.height:
            s.min_height = 0.0


def drop_outlines_with_parts(solids):
    """Simple 3D Buildings: an outline whose building:part shapes cover it is not built, the
    parts are. An outline with only a tower mapped as a part keeps its body."""
    outlines = [s for s in solids if s.kind == "building"]
    parts = [s for s in solids if s.kind == "part"]
    if not outlines or not parts:
        return solids
    lo = np.array([s.outer.min(axis=0) for s in outlines])
    hi = np.array([s.outer.max(axis=0) for s in outlines])
    covered = np.zeros(len(outlines))
    for p in parts:
        c = p.centre
        for i in np.flatnonzero((lo[:, 0] <= c[0]) & (hi[:, 0] >= c[0]) & (lo[:, 1] <= c[1]) & (hi[:, 1] >= c[1])):
            if points_in_rings(c[None], [outlines[i].outer])[0]:
                covered[i] += p.area
    gone = {id(o) for o, c in zip(outlines, covered) if c >= 0.7 * o.area}
    return [s for s in solids if id(s) not in gone]


def building_colours(s):
    """(wall material, wall RGBA, roof RGBA) in linear colour; wall alpha 1 = has windows."""
    t = s.tags
    glass = t.get("building:material") == "glass" or (s.type in ("office", "commercial", "hotel") and s.height >= 35.0)
    blank = s.type in BLANK_TYPES or s.kind in ("canopy",)
    wall = parse_colour(t["building:colour"]) if "building:colour" in t else None
    if wall is None:
        wall = pick(GLASS if glass else SHEDS if blank else FACADES, s.ref)
    roof = parse_colour(t["roof:colour"]) if "roof:colour" in t else None
    if roof is None:
        roof = pick(TILE_ROOFS if roof_shape(s)[0] != "flat" else FLAT_ROOFS, s.ref, "roof")
    return ("building_glass" if glass else "building_wall",
            srgb_to_linear(wall) + (0.0 if blank else 1.0,), srgb_to_linear(roof) + (0.0,))


def roof_shape(s):
    """("flat" | "gabled" | "pointed", rise in metres)."""
    t = s.tags
    shape = t.get("roof:shape", "")
    rise = parse_length(t["roof:height"]) if "roof:height" in t else None
    if shape in POINTED_SHAPES:
        return "pointed", rise or min(0.5 * math.sqrt(s.area), 12.0)
    if len(s.outer) != 4 or s.holes or s.min_height > 0.0:
        return "flat", 0.0
    side = np.hypot(*(np.roll(s.outer, -1, axis=0) - s.outer).T)
    span = float(min(side[0] + side[2], side[1] + side[3])) * 0.5
    pitched = shape in PITCHED_SHAPES or (shape == "" and s.type in PITCHED_TYPES and s.height <= 12.0
                                           and s.area < 600.0)
    if not pitched:
        return "flat", 0.0
    return "gabled", rise or min(0.35 * span, 5.0, 0.6 * s.height)


def build_solid(mesh, s, ground, corridor, counts):
    """Triangles of one solid. Returns False when the road leaves nothing of it."""
    spans_road = s.min_height >= OVER_ROAD
    pieces = [s.outer] if spans_road else corridor.cut(s.outer)
    if not pieces:
        return False
    holes = [h for h in s.holes if not corridor.on_road(h).any()]
    cut = len(pieces) != 1 or len(pieces[0]) != len(s.outer)
    # The top is measured from the lowest ground corner of the whole footprint, but a
    # building on a slope still shows a storey above its highest one.
    g = ground.height(s.outer[:, 0], s.outer[:, 1])
    whole_lo = float(g.min())
    whole_top = max(whole_lo + (s.height or 0.0), float(g.max()) + 2.5)
    # A building over a roofed stretch of road (a tunnel under a hotel) keeps its upper
    # floors: the pieces beside the road stop at the top of the shell, the whole footprint
    # goes on from there.
    over = corridor.roof_over(s.outer) if cut and s.kind in ("building", "part") else None
    if over is not None and whole_top < over + 2.0:
        over = None
    for outer in pieces:
        outer = sg.oriented(outer, True)
        mine = [h for h in holes if points_in_rings(h[:1], [outer])[0]] if len(pieces) > 1 else holes
        c = outer.mean(axis=0)
        g = ground.height(np.append(outer[:, 0], c[0]), np.append(outer[:, 1], c[1]))
        g_lo, g_hi = float(g.min()), float(g.max())
        mesh.anchor(c[0], c[1])
        if s.kind == "stand":
            idx, _, _ = corridor.nearest(c[None])
            toward = corridor.xz[idx[0]] - c
            toward = toward / max(float(np.hypot(*toward)), 1e-6)
            tint = parse_colour(s.tags["building:colour"]) if "building:colour" in s.tags else pick(STAND_TINTS, s.ref)
            covered = s.tags.get("covered") == "yes" or "roof:shape" in s.tags
            sg.grandstand(mesh, outer, toward, g_lo, g_lo - 1.5, s.height if s.source != "type default" else None,
                          srgb_to_linear(tint) + (0.0,), covered)
            counts["grandstands"] += 1
            continue
        wall_mat, wall_col, roof_col = building_colours(s)
        top = whole_top if not cut else max(whole_top, g_hi + 2.5)
        if over is not None:
            top = over
        if s.kind == "canopy":
            sg.prism(mesh, outer, [], top - 0.3, top, "metal", "metal", wall_col, roof_col, g_lo, floor=True)
            posts = outer[np.linspace(0, len(outer), min(len(outer), 8), endpoint=False).astype(int)]
            for p in posts:
                q = p + (c - p) * min(1.0, 0.4 / max(float(np.hypot(*(c - p))), 1e-6))
                sg.box(mesh, "metal", (q[0] - 0.12, g_lo - 1.0, q[1] - 0.12), (q[0] + 0.12, top - 0.3, q[1] + 0.12),
                       wall_col)
            counts["canopies"] += 1
            continue
        hanging = s.min_height > 0.0
        base = g_lo + s.min_height if hanging else g_lo - 1.5
        shape, rise = ("flat", 0.0) if cut else roof_shape(s)
        if shape == "gabled" and len(outer) == 4:
            eave = max(top - rise, base + 2.2)
            sg.wall_quads(mesh, wall_mat, outer, base, eave, wall_col, g_lo)
            sg.gabled_roof(mesh, outer, eave, top - eave, wall_mat, "building_roof", wall_col, roof_col, g_lo)
        elif shape == "pointed":
            eave = max(top - rise, base + 2.2)
            sg.wall_quads(mesh, wall_mat, outer, base, eave, wall_col, g_lo)
            sg.pyramid_roof(mesh, outer, eave, top - eave, "building_roof", roof_col)
        else:
            sg.prism(mesh, outer, mine, base, top, wall_mat, "building_roof", wall_col, roof_col, g_lo,
                     floor=hanging)
        counts["buildings"] += 1
    if over is not None:
        c = s.outer.mean(axis=0)
        mesh.anchor(c[0], c[1])
        wall_mat, wall_col, roof_col = building_colours(s)
        sg.prism(mesh, s.outer, s.holes, over, whole_top, wall_mat, "building_roof", wall_col, roof_col,
                 whole_lo, floor=True)
    return True


# ----------------------------------------------------------------------------- structures
def _resample(line, spacing):
    seg = np.hypot(*np.diff(line, axis=0).T)
    dist = np.concatenate([[0.0], np.cumsum(seg)])
    if dist[-1] < 1e-6:
        return line[:1], dist[:1]
    n = max(2, int(math.ceil(dist[-1] / spacing)) + 1)
    s = np.linspace(0.0, dist[-1], n)
    return np.stack([np.interp(s, dist, line[:, 0]), np.interp(s, dist, line[:, 1])], axis=1), s


def _line_frame(line):
    t = np.gradient(line, axis=0)
    t = t / np.maximum(np.hypot(t[:, 0], t[:, 1]), 1e-9)[:, None]
    return np.stack([-t[:, 1], t[:, 0]], axis=1)


def build_bridge(mesh, f, ground, corridor):
    """Deck of a road or foot bridge that is not the race track: a straight grade between
    the ground at its two ends, lifted clear of the track where it crosses it."""
    hw = f.tags.get("highway")
    if hw == "raceway" or (hw not in HIGHWAY_WIDTH and hw not in FOOT_BRIDGES):
        return False
    width = (parse_length(f.tags["width"]) if "width" in f.tags else None) or HIGHWAY_WIDTH.get(hw) or FOOT_BRIDGES[hw]
    line, s = _resample(f.line, 6.0)
    if len(line) < 2 or s[-1] < 4.0:
        return False
    g = ground.height(line[:, 0], line[:, 1])
    y = g[0] + (g[-1] - g[0]) * s / s[-1]
    y = np.maximum(y, g + 0.3)
    idx, lat, dist = corridor.nearest(line)
    over = dist < corridor.half[idx] + 6.0
    if over.any():
        need = float(np.max(corridor.y[idx[over]] + 5.5 + 1.0 - y[over]))
        if need > 0.0:
            ramp = np.clip(np.minimum(s, s[-1] - s) / max(0.25 * s[-1], 1.0), 0.0, 1.0)
            ramp = ramp * ramp * (3.0 - 2.0 * ramp)
            y = y + need * (ramp if ramp[over].min() > 0.95 else 1.0)
    mesh.anchor(*line[len(line) // 2])
    foot = hw in FOOT_BRIDGES
    colour = (0.35, 0.36, 0.38, 0.0) if foot else (0.38, 0.38, 0.37, 0.0)
    centre = np.stack([line[:, 0], y, line[:, 1]], axis=1)
    sg.ribbon(mesh, "metal" if foot else "concrete", centre, _line_frame(line), width + 1.0,
              0.5 if foot else 1.0, colour)
    # Piers where the deck is well above open ground.
    last = -1e9
    for k in range(1, len(line) - 1):
        if y[k] - g[k] > 3.5 and s[k] - last >= 24.0 and not corridor.on_road(line[k][None], 4.0)[0]:
            sg.box(mesh, "concrete", (line[k, 0] - 0.6, g[k] - 1.0, line[k, 1] - 0.6),
                   (line[k, 0] + 0.6, y[k] - 0.4, line[k, 1] + 0.6), colour)
            last = s[k]
    return True


def build_mast(mesh, f, ground, corridor, x, z, footprint=None):
    """Towers, masts, chimneys, tanks: a drum (or the mapped outline) of the tagged height."""
    kind = f.tags.get("man_made") or ("pylon" if f.tags.get("power") == "tower" else None)
    if kind == "pylon":
        height, radius, material = 28.0, 1.6, "metal"
    elif kind in MAST_TYPES:
        height, radius, material = MAST_TYPES[kind]
    else:
        return False
    height = (parse_length(f.tags["height"]) if "height" in f.tags else None) or height
    ring = footprint if footprint is not None else sg.ngon(x, z, radius, 4 if radius < 1.0 or kind == "pylon" else 10)
    if corridor.on_road(ring).any():
        return False
    y = float(ground.height(ring[:, 0], ring[:, 1]).min())
    mesh.anchor(x, z)
    colour = srgb_to_linear((0.60, 0.61, 0.62) if material == "metal" else (0.70, 0.69, 0.66)) + (0.0,)
    if kind == "pylon":     # a lattice tower reads as a tapering spire
        sg.pyramid_roof(mesh, ring, y - 0.5, height + 0.5, "metal", colour)
    else:
        sg.prism(mesh, ring, [], y - 1.0, y + height, material, material, colour, colour, y)
    return True


def build_lamp(mesh, x, z, ground):
    y = float(ground.height(x, z))
    mesh.anchor(x, z)
    pole = sg.ngon(x, z, 0.09, 3)
    grey = (0.20, 0.21, 0.22, 0.0)
    sg.wall_quads(mesh, "metal", pole, y - 0.3, y + 8.0, grey, y)
    head = np.array([[x - 0.35, y + 8.0, z - 0.2], [x + 0.35, y + 8.0, z - 0.2],
                     [x + 0.35, y + 8.0, z + 0.2], [x - 0.35, y + 8.0, z + 0.2]])
    mesh.face("emissive_light", head, -sg.UP, (1.0, 1.0, 1.0, 0.0))
    mesh.face("metal", head + sg.UP * 0.05, sg.UP, grey)


def build_roofs(mesh, recipe_roofs, corridor, log):
    """[[surroundings.roof]]: a shell over the road for s = [from, to]. Also marks the
    stretch in ``corridor``, for the buildings that stand over it."""
    out = []
    n = corridor.n
    for r in recipe_roofs:
        s0, s1 = float(r["s"][0]), float(r["s"][1])
        i0 = int(round(s0 / corridor.step)) % n
        i1 = int(round(s1 / corridor.step)) % n
        count = (i1 - i0) % n
        stride = max(1, int(round(5.0 / corridor.step)))
        ks = [(i0 + j) % n for j in range(0, count, stride)] + [i1]
        clear = float(r.get("clear_height", 5.5))
        kind = r.get("kind", "tunnel")
        idx = np.array(ks)
        half = corridor.half[idx] + ROAD_CLEAR + 0.5
        centre = np.stack([corridor.xz[idx, 0], corridor.y[idx], corridor.xz[idx, 1]], axis=1)
        y_l = corridor.surface_y(idx, -half)
        y_r = corridor.surface_y(idx, half)
        # One mesh piece per ~60 m so every piece lands in the chunk it stands in.
        per = max(2, int(round(60.0 / (stride * corridor.step))))
        lights = 0
        for a in range(0, len(ks) - 1, per):
            b = min(len(ks), a + per + 1)
            mesh.anchor(*corridor.xz[idx[(a + b - 1) // 2]])
            lights += sg.roof_shell(mesh, centre[a:b], corridor.right[idx[a:b]], half[a:b], y_l[a:b], y_r[a:b],
                                    clear, kind, portals=(a == 0, b == len(ks)))
        on = np.array([(i0 + j) % n for j in range(count + 1)])
        corridor.roofed[on] = True
        corridor.roof_top[on] = corridor.y[on] + clear + sg.SHELL
        length = count * corridor.step
        log(f"  roof: {kind} over s = {s0:.0f} to {s1:.0f} m ({length:.0f} m, {clear:.1f} m clear, {lights} lights)")
        out.append({"s": [s0, s1], "kind": kind, "clear_height": clear, "length": round(length, 1)})
    return out


# ----------------------------------------------------------------------------- trees
def scatter_trees(raster, ground, corridor, density, species_default, seed, extra):
    """Tree records (n, 5) float32: jittered-grid points inside the tree-covered cells of the
    near raster, thinned away from the track, plus the mapped single trees and rows
    (``extra``: [(x, z, height or 0, species or -1)])."""
    rng = np.random.default_rng(seed)
    rows = []
    if density > 0.0:
        cell = math.sqrt(10000.0 / density)
        nx = int((raster.nx * raster.step) // cell)
        nz = int((raster.nz * raster.step) // cell)
        jx = rng.uniform(0.08, 0.92, (nz, nx))
        jz = rng.uniform(0.08, 0.92, (nz, nx))
        x = raster.x0 + (np.arange(nx)[None, :] + jx) * cell
        z = raster.z0 + (np.arange(nz)[:, None] + jz) * cell
        x, z = x.ravel(), z.ravel()
        cover = raster.at(raster.trees, x, z)
        d = ground.track_distance(x, z)
        # Full density beside the track, where single trunks show; a third of it from 450 m.
        thin = np.clip(1.0 - (d - 120.0) / 330.0 * 0.65, 0.35, 1.0)
        chance = thin * np.select([cover == T_NONE, cover == T_PARK, cover == T_SCRUB, cover == T_ORCHARD],
                                  [0.0, 0.15, 0.45, 0.8], 1.0)
        keep = (rng.uniform(0.0, 1.0, len(x)) < chance) & ~raster.at(raster.built, x, z)
        x, z, cover = x[keep], z[keep], cover[keep]
        keep = ~corridor.keep_out(np.stack([x, z], axis=1))
        x, z, cover = x[keep], z[keep], cover[keep]
        mix = rng.uniform(0.0, 1.0, len(x))
        default = {"mixed": np.where(mix < 0.65, BROADLEAVED, NEEDLELEAVED),
                   "broadleaved": np.full(len(x), BROADLEAVED), "needleleaved": np.full(len(x), NEEDLELEAVED),
                   "palm": np.full(len(x), PALM)}[species_default]
        sp = np.select([cover == T_BROAD, cover == T_NEEDLE, cover == T_PALM, cover == T_SCRUB,
                        cover == T_ORCHARD], [BROADLEAVED, NEEDLELEAVED, PALM, BUSH, BROADLEAVED], default)
        hgt = _tree_heights(rng, sp)
        hgt = np.where(cover == T_ORCHARD, rng.uniform(3.0, 5.0, len(x)), hgt)
        rows.append(np.stack([x, np.zeros(len(x)), z, hgt, sp.astype(np.float64)], axis=1))
    if extra:
        e = np.array(extra, dtype=np.float64).reshape(-1, 4)
        ok = ~corridor.keep_out(e[:, :2]) & ~raster.at(raster.built, e[:, 0], e[:, 1])
        ok &= raster.at(raster.cls, e[:, 0], e[:, 1]) != WATER
        e = e[ok]
        mix = rng.uniform(0.0, 1.0, len(e))
        default = {"mixed": np.where(mix < 0.8, BROADLEAVED, NEEDLELEAVED), "broadleaved": np.full(len(e), BROADLEAVED),
                   "needleleaved": np.full(len(e), NEEDLELEAVED), "palm": np.full(len(e), PALM)}[species_default]
        sp = np.where(e[:, 3] >= 0, e[:, 3], default).astype(np.int64)
        hgt = np.where(e[:, 2] > 0.0, e[:, 2], _tree_heights(rng, sp) * 0.8)
        rows.append(np.stack([e[:, 0], np.zeros(len(e)), e[:, 1], hgt, sp.astype(np.float64)], axis=1))
    if not rows:
        return np.zeros((0, 5), dtype=np.float32)
    t = np.concatenate(rows)
    if len(t) > MAX_TREES:
        t = t[np.sort(rng.choice(len(t), MAX_TREES, replace=False))]
    t[:, 1] = ground.height(t[:, 0], t[:, 2])
    return t.astype(np.float32)


def _tree_heights(rng, species):
    n = len(species)
    h = np.select([species == NEEDLELEAVED, species == PALM, species == BUSH],
                  [np.clip(rng.normal(20.0, 4.0, n), 10.0, 32.0), rng.uniform(7.0, 13.0, n),
                   rng.uniform(1.2, 3.0, n)], np.clip(rng.normal(14.0, 3.0, n), 7.0, 24.0))
    return h


def tree_species(tags):
    kind = (tags.get("genus", "") + " " + tags.get("species", "")).lower()
    if "palm" in kind or "phoenix" in kind or "washingtonia" in kind or tags.get("leaf_type") == "palm":
        return PALM
    return {"broadleaved": BROADLEAVED, "needleleaved": NEEDLELEAVED}.get(tags.get("leaf_type"), -1)


# ----------------------------------------------------------------------------- water bodies
def water_bodies(shapes, lines, sea, ground, sea_level, rect):
    """[{"level", "kind", "polygon", "triangles"}]: flat pieces of water for the runtime.
    ``shapes`` are (outer, holes) polygons, ``lines`` (points, width) rivers drawn as a line.
    A body whose banks differ in height (a river on a slope) is cut into 150 m squares, each
    at its own level."""
    out = []

    def add(ring, level, kind):
        ring = sg.clean_ring(ring, tol=1e-3)
        if len(ring) < 3 or abs(sg.signed_area(ring)) < 4.0:
            return
        ring = sg.oriented(ring, True)
        tris = sg.ear_clip(ring)
        out.append({"level": round(float(level), 2), "kind": kind,
                    "polygon": [[round(float(x), 2), round(float(z), 2)] for x, z in ring],
                    "triangles": [int(i) for t in tris for i in t]})

    for outer, holes in sea:
        add(sg.merge_holes(outer, holes), sea_level, "sea")
    x0, x1, z0, z1 = rect
    for outer, holes in shapes:
        ring = clip_rect(sg.merge_holes(outer, holes), x0, x1, z0, z1)
        if len(ring) < 3:
            continue
        g = ground.height(ring[:, 0], ring[:, 1])
        if np.percentile(g, 90) - np.percentile(g, 10) <= 2.0:
            add(ring, np.percentile(g, 15), "lake")
            continue
        cell = 150.0
        for cx in np.arange(math.floor(ring[:, 0].min() / cell) * cell, ring[:, 0].max(), cell):
            for cz in np.arange(math.floor(ring[:, 1].min() / cell) * cell, ring[:, 1].max(), cell):
                piece = clip_rect(ring, cx, cx + cell, cz, cz + cell)
                if len(piece) >= 3:
                    add(piece, np.percentile(ground.height(piece[:, 0], piece[:, 1]), 15), "river")
    for pts, width in lines:
        pts, _ = _resample(pts, 25.0)
        if len(pts) < 2:
            continue
        right = _line_frame(pts) * (0.5 * width)
        g = ground.height(pts[:, 0], pts[:, 1])
        for k in range(0, len(pts) - 1, 4):
            sl = slice(k, min(len(pts), k + 5))
            ring = np.concatenate([pts[sl] - right[sl], (pts[sl] + right[sl])[::-1]])
            if ((ring[:, 0] >= x0) & (ring[:, 0] <= x1) & (ring[:, 1] >= z0) & (ring[:, 1] <= z1)).all():
                add(ring, float(np.min(g[sl])), "river")
    return out


# ----------------------------------------------------------------------------- the step
def settings(recipe):
    cfg = dict(DEFAULTS)
    cfg.update({k: v for k, v in recipe.surroundings.items() if k in DEFAULTS or k == "margin_m"})
    return cfg


def _ref_matches(ref, wanted):
    """``wanted``: a bare id (any object type) or "way/123"."""
    return ref == wanted if isinstance(wanted, str) else ref.split("/")[1] == str(wanted)


def _context(recipe, out_dir):
    with open(os.path.join(out_dir, "track.json"), encoding="utf-8") as f:
        track = json.load(f)
    k, _ = terrain.plan_scale(track, out_dir)
    proj = geom.Projection(track["origin_latlon"][0], track["origin_latlon"][1], k)
    ground = Ground(out_dir)
    return track, proj, ground


def have_cache(recipe, out_dir, fetcher):
    """Whether both Overpass answers of this track are in the cache (an offline build of all
    steps skips the surroundings when they are not)."""
    try:
        _, proj, ground = _context(recipe, out_dir)
    except (OSError, BuildError):
        return False
    q = queries(proj, ground.near_rect, ground.far_rect, settings(recipe)["far_margin_m"])
    return all(fetcher.cached(name) for _, _, name in q.values())


def build(recipe, out_dir, fetcher, log=print):
    cfg = settings(recipe)
    sur = recipe.surroundings
    track, proj, ground = _context(recipe, out_dir)
    profile, has_profile = terrain.load_profile(track, out_dir)
    if not has_profile:
        raise BuildError(f"road_profile.json is missing in {out_dir}: run the 'road' step first")
    corridor = Corridor(track, {"width": profile["width"], "bank": profile["bank"],
                                "verge_left": profile["verge_l"], "verge_right": profile["verge_r"]})
    near_rect, far_rect = ground.near_rect, ground.far_rect
    detail = list(near_rect)
    if "margin_m" in cfg:
        m = float(cfg["margin_m"])
        detail = [max(near_rect[0], corridor.xz[:, 0].min() - m), min(near_rect[1], corridor.xz[:, 0].max() + m),
                  max(near_rect[2], corridor.xz[:, 1].min() - m), min(near_rect[3], corridor.xz[:, 1].max() + m)]
    reach = float(cfg["far_margin_m"])
    sky_rect = [near_rect[0] - reach, near_rect[1] + reach, near_rect[2] - reach, near_rect[3] + reach]
    near_feats, far_feats, stamp = fetch(fetcher, proj, near_rect, far_rect, reach, log)

    def inside(rect, p):
        return rect[0] <= p[0] <= rect[1] and rect[2] <= p[1] <= rect[3]

    def ll_ring(poly):
        ll = np.asarray(poly, dtype=np.float64)
        x, z = proj.to_xz(ll[:, 0], ll[:, 1])
        return sg.clean_ring(np.stack([x, z], axis=1))

    # ---- recipe: exclusions ------------------------------------------------------------
    drop_refs = [o["osm"] for o in sur.get("exclude", []) if "osm" in o]
    drop_refs += [o["osm"] for o in sur.get("building", []) if o.get("remove")]
    drop_areas = [ll_ring(o["polygon"]) for o in sur.get("exclude", []) if "polygon" in o]

    def excluded(f):
        if any(_ref_matches(f.ref, w) for w in drop_refs):
            return True
        if not drop_areas:
            return False
        c = f.point if f.point is not None else (f.line if f.line is not None else f.outers[0]).mean(axis=0)
        return bool(points_in_rings(c[None], drop_areas)[0])

    near_feats = [f for f in near_feats if not excluded(f)]
    far_feats = [f for f in far_feats if not excluded(f)]

    # ---- land cover --------------------------------------------------------------------
    nm, fm = ground.meta["near"], ground.meta["far"]
    sub = int(round(nm["step"] / NEAR_CELL))
    near = Raster(nm["x0"], nm["z0"], NEAR_CELL, (nm["nx"] - 1) * sub, (nm["nz"] - 1) * sub)
    fsub = int(round(fm["step"] / FAR_CELL))
    far = Raster(fm["x0"], fm["z0"], FAR_CELL, (fm["nx"] - 1) * fsub, (fm["nz"] - 1) * fsub)
    coast = [f.line if f.line is not None else np.concatenate([f.outers[0], f.outers[0][:1]])
             for f in far_feats if f.tags.get("natural") == "coastline"]
    sea = sea_polygons(coast, far_rect, log) if coast else []
    sea_rings = [r for outer, holes in sea for r in [outer] + holes]

    def paint_all(raster, feats, with_roads):
        shapes = []
        for f in feats:
            if not f.outers or "building" in f.tags or "building:part" in f.tags:
                continue
            c = land_class(f.tags)
            if c is not None:
                shapes.append((sum(abs(sg.signed_area(r)) for r in f.outers), c, f))
        # Big shapes first, so a park inside a residential area or a clearing in a forest
        # shows; then water, which the map draws through everything else.
        shapes.sort(key=lambda s: -s[0])
        for _, (cls, cover), f in shapes:
            if cls != WATER:
                raster.paint(f.rings, cls, cover)
        if sea_rings:
            raster.paint(sea_rings, WATER)
        for _, (cls, cover), f in shapes:
            if cls == WATER:
                raster.paint(f.rings, cls)
        by_class = {}
        for f in feats:
            if f.line is None:
                continue
            strip = line_strip(f.tags)
            if strip is not None and (with_roads or strip[0] == WATER or strip[1] >= 0.5 * raster.step):
                by_class.setdefault(strip[0], []).append((f.line, strip[1]))
        for cls in (WATER, GRAVEL, PAVED):
            raster.paint_lines(sorted(by_class.get(cls, []), key=lambda s: s[1]), cls)
        # Piers and breakwaters stand in the water.
        for _, (cls, cover), f in shapes:
            if f.tags.get("man_made") in ("pier", "breakwater", "groyne"):
                raster.paint(f.rings, cls)

    paint_all(near, near_feats, True)
    paint_all(far, far_feats, False)

    # ---- recipe: hand-made shapes ------------------------------------------------------
    ground_kinds = {"grass": GRASS, "forest": FOREST, "water": WATER, "sand": SAND, "paved": PAVED,
                    "farmland": FARMLAND, "rock": ROCK, "gravel": GRAVEL, "scrub": SCRUB, "beach": BEACH}
    added_water, added_solids = [], []
    for k, o in enumerate(sur.get("add", [])):
        ring = ll_ring(o["polygon"])
        kind = o.get("kind", "building")
        if len(ring) < 3:
            continue
        if kind in ground_kinds:
            cover = T_MIXED if kind == "forest" else T_SCRUB if kind == "scrub" else T_NONE
            near.paint([ring], ground_kinds[kind], cover)
            far.paint([ring], ground_kinds[kind])
            if kind == "water":
                added_water.append((ring, []))
            continue
        tags = {"building": {"grandstand": "grandstand", "glass": "office"}.get(kind, "yes")}
        if kind == "glass":
            tags["building:material"] = "glass"
        s = Solid(f"add/{k + 1}", tags, sg.oriented(ring, True), [])
        classify_solid(s)
        s.height = float(o.get("height", 0.0)) or None
        s.min_height = float(o.get("min_height", 0.0))
        s.source = "recipe"
        added_solids.append((s, kind))

    # ---- solids ------------------------------------------------------------------------
    overrides = sur.get("building", [])
    solids = []
    # The far answer repeats the tall buildings of the near box, thinned differently: the
    # near copy is the one that is built.
    near_refs = {f.ref for f in near_feats}
    for f in near_feats + [f for f in far_feats if f.ref not in near_refs]:
        if not f.outers or not ("building" in f.tags or "building:part" in f.tags):
            continue
        if f.tags.get("building") == "no" or f.tags.get("location") == "underground":
            continue
        for outer, holes in polygons_from_rings(f.outers, f.inners):
            s = Solid(f.ref, dict(f.tags), sg.oriented(outer, True), holes)
            if s.area < 4.0:
                continue
            for o in overrides:
                if _ref_matches(f.ref, o["osm"]):
                    if "type" in o:
                        s.type = o["type"]
                        s.tags["building"] = o["type"]
                    if "levels" in o:
                        s.tags["building:levels"] = str(o["levels"])
                        s.tags.pop("height", None)
                    if "height" in o:
                        s.tags["height"] = str(o["height"])
            classify_solid(s)
            solids.append(s)
    solids = drop_outlines_with_parts(solids)
    resolve_heights(solids, cfg)
    for s, _ in added_solids:
        if s.height is None and s.kind != "stand":
            s.height = s.min_height + default_height(s.type, s.area, cfg)
    kept = []
    for s in solids:
        if inside(detail, s.centre):
            kept.append(s)
        elif inside(sky_rect, s.centre) and s.kind in ("building", "part") and s.height >= SKYLINE_HEIGHT:
            kept.append(s)
    solids = kept

    fr = ground.far_rect
    cx0 = math.floor(fr[0] / sg.CHUNK) * sg.CHUNK
    cz0 = math.floor(fr[2] / sg.CHUNK) * sg.CHUNK
    mesh = sg.SceneryMesh(cx0, cz0)
    roofs = build_roofs(mesh, sur.get("roof", []), corridor, log)
    counts = {"buildings": 0, "grandstands": 0, "canopies": 0, "bridges": 0, "masts": 0, "lamps": 0,
              "skyline": 0, "cut_by_road": 0}
    defaults, footprints = [], []
    for s in solids:
        before = counts["buildings"]
        if not build_solid(mesh, s, ground, corridor, counts):
            counts["cut_by_road"] += 1
            continue
        if not inside(detail, s.centre):
            counts["skyline"] += counts["buildings"] - before
        footprints.append((s.outer, float(s.height or 0.0), s.kind))
        if inside(near_rect, s.centre):
            near.paint([s.outer] + s.holes, PAVED, T_NONE, built=True)
        if s.source in ("type default", "neighbours") and s.kind in ("building", "part"):
            d = float(corridor.nearest(s.centre[None])[2][0])
            entry = {"osm": s.ref, "type": s.type, "height": round(s.height, 1), "from": s.source,
                     "dist": round(d)}
            if s.name:
                entry["name"] = s.name
            defaults.append(entry)
    defaults.sort(key=lambda e: e["dist"])
    for s, kind in added_solids:
        material = {"concrete": "concrete", "metal": "metal", "screen": "emissive_window",
                    "light": "emissive_light"}.get(kind)
        if material is None:
            if s.height is None and s.kind == "stand":
                s.source = "type default"
            build_solid(mesh, s, ground, corridor, counts)
        else:
            for outer in ([s.outer] if s.min_height >= OVER_ROAD else corridor.cut(s.outer)):
                c = outer.mean(axis=0)
                g = float(ground.height(outer[:, 0], outer[:, 1]).min())
                mesh.anchor(c[0], c[1])
                colour = (0.62, 0.62, 0.60, 0.0) if kind in ("concrete", "metal") else (1.0, 1.0, 1.0, 0.0)
                base = g + s.min_height if s.min_height > 0.0 else g - 1.5
                sg.prism(mesh, outer, [], base, g + (s.height or 3.0), material, material, colour, colour, g,
                         floor=s.min_height > 0.0)
        footprints.append((s.outer, float(s.height or 0.0), s.kind))
        near.paint([s.outer], None, built=True)

    # ---- structures and mapped trees ---------------------------------------------------
    extra_trees = []
    for f in near_feats:
        t = f.tags
        if f.point is not None:
            x, z = float(f.point[0]), float(f.point[1])
            if not inside(detail, (x, z)):
                continue
            if t.get("natural") == "tree":
                extra_trees.append((x, z, parse_length(t["height"]) or 0.0 if "height" in t else 0.0,
                                    tree_species(t)))
            elif t.get("highway") == "street_lamp":
                if float(ground.track_distance(x, z)) <= LAMP_REACH and not corridor.on_road(f.point[None], 1.0)[0]:
                    build_lamp(mesh, x, z, ground)
                    counts["lamps"] += 1
            elif build_mast(mesh, f, ground, corridor, x, z):
                counts["masts"] += 1
        elif f.line is not None:
            if not inside(detail, f.line[len(f.line) // 2]):
                continue
            if t.get("natural") == "tree_row":
                pts, _ = _resample(f.line, 8.0)
                extra_trees += [(float(p[0]), float(p[1]), 0.0, tree_species(t)) for p in pts]
            elif t.get("bridge") not in (None, "no") and "highway" in t:
                counts["bridges"] += bool(build_bridge(mesh, f, ground, corridor))
            elif t.get("man_made") in ("pier", "breakwater", "groyne"):
                line, _ = _resample(f.line, 8.0)
                if len(line) >= 2 and not corridor.on_road(line, 4.0).any():
                    y = float(np.median(ground.height(line[:, 0], line[:, 1]))) + 1.2
                    mesh.anchor(*line[len(line) // 2])
                    centre = np.stack([line[:, 0], np.full(len(line), y), line[:, 1]], axis=1)
                    width = (parse_length(t["width"]) if "width" in t else None) or (3.0 if t["man_made"] == "pier" else 6.0)
                    sg.ribbon(mesh, "concrete", centre, _line_frame(line), width, 4.0, (0.45, 0.45, 0.44, 0.0))
        elif t.get("man_made") in MAST_TYPES and "building" not in t:
            c = f.outers[0].mean(axis=0)
            if inside(detail, c) and build_mast(mesh, f, ground, corridor, c[0], c[1], sg.oriented(f.outers[0], True)):
                counts["masts"] += 1
        elif t.get("man_made") in ("pier", "breakwater", "groyne"):
            ring = f.outers[0]
            if inside(detail, ring.mean(axis=0)):
                for outer in corridor.cut(ring):
                    y = float(np.median(ground.height(outer[:, 0], outer[:, 1]))) + 1.2
                    mesh.anchor(*outer.mean(axis=0))
                    col = (0.45, 0.45, 0.44, 0.0)
                    sg.prism(mesh, outer, [], y - 4.0, y, "concrete", "concrete", col, col, y)
    for f in far_feats:     # tall masts and towers on the skyline
        if f.point is not None and f.tags.get("man_made") in MAST_TYPES:
            x, z = float(f.point[0]), float(f.point[1])
            height = parse_length(f.tags["height"]) if "height" in f.tags else None
            if inside(sky_rect, (x, z)) and not inside(detail, (x, z)) and (height or 0.0) >= SKYLINE_HEIGHT:
                counts["masts"] += bool(build_mast(mesh, f, ground, corridor, x, z))

    # ---- trees -------------------------------------------------------------------------
    seed = zlib.crc32(recipe.id.encode())
    trees = scatter_trees(near, ground, corridor, float(cfg["tree_density"]), cfg["tree_species"], seed,
                          extra_trees)
    # Sorted by 400 m chunk, so the runtime can show and hide them in blocks.
    ci = np.floor((trees[:, 0] - cx0) / sg.CHUNK).astype(np.int64)
    cj = np.floor((trees[:, 2] - cz0) / sg.CHUNK).astype(np.int64)
    order = np.lexsort((cj, ci))
    trees, ci, cj = trees[order], ci[order], cj[order]
    tree_chunks = []
    if len(trees):
        cut = np.flatnonzero(np.diff(ci) | np.diff(cj)) + 1
        for a, b in zip(np.concatenate([[0], cut]), np.concatenate([cut, [len(trees)]])):
            tree_chunks.append([int(ci[a]), int(cj[a]), int(a), int(b - a)])

    # ---- water bodies ------------------------------------------------------------------
    lakes, rivers = [], []
    for f in near_feats:
        if f.outers and "building" not in f.tags:
            c = land_class(f.tags)
            if c is not None and c[0] == WATER and f.tags.get("leisure") != "swimming_pool":
                lakes += polygons_from_rings(f.outers, f.inners)
        elif f.line is not None and f.tags.get("waterway") in ("river", "canal"):
            strip = line_strip(f.tags)
            if strip is not None:
                rivers.append((f.line, strip[1]))
    sea_level = -float(track["origin_elevation_m"])
    water = water_bodies(lakes + added_water, rivers, sea, ground, sea_level, near_rect)

    # ---- write -------------------------------------------------------------------------
    near.save(os.path.join(out_dir, "landcover.png"))
    far.save(os.path.join(out_dir, "landcover_far.png"))
    from pathlib import Path
    stats = sg.write_glb(Path(out_dir) / "scenery.glb", mesh, f"{recipe.id}_scenery",
                         "fun-racer tools/track/lib/surroundings.py")
    trees.astype("<f4").tofile(os.path.join(out_dir, "scenery_points.bin"))
    for name, text in (("scenery.glb.import", GLB_IMPORT.format(id=recipe.id)),
                       ("landcover.png.import", PNG_IMPORT.format(id=recipe.id, name="landcover.png")),
                       ("landcover_far.png.import", PNG_IMPORT.format(id=recipe.id, name="landcover_far.png"))):
        dst = os.path.join(out_dir, name)
        if not os.path.exists(dst):     # Godot adds its uid to these: keep what is there
            with open(dst, "w", encoding="utf-8") as f:
                f.write(text)
    tri = mesh.triangle_counts()
    share = np.bincount(near.cls.ravel(), minlength=len(CLASSES)) / near.cls.size
    meta = {
        "version": 1,
        "frame": track["frame"],
        "attribution": ATTRIBUTION,
        "osm_base": stamp,
        "landcover": {
            "classes": list(CLASSES),
            "near": near.meta("landcover.png"),
            "far": far.meta("landcover_far.png"),
            "near_share": {c: round(float(v), 4) for c, v in zip(CLASSES, share)},
        },
        "mesh": {
            "file": "scenery.glb", "chunk_m": sg.CHUNK, "chunk_x0": cx0, "chunk_z0": cz0,
            "node": "chunk_<i>_<j>, i = floor((x - chunk_x0) / chunk_m), j = floor((z - chunk_z0) / chunk_m)",
            "materials": list(sg.MATERIAL_NAMES), "triangles": tri,
            "vertices": stats["vertices"], "chunks": stats["chunks"],
        },
        "trees": {
            "file": "scenery_points.bin", "dtype": "float32", "record": ["x", "y", "z", "height", "species"],
            "record_bytes": 20, "count": int(len(trees)), "species": list(SPECIES),
            "species_counts": {n: int(np.sum(trees[:, 4] == k)) for k, n in enumerate(SPECIES)},
            "chunk_m": sg.CHUNK, "chunks": tree_chunks,
        },
        "water": water,
        "roofs": roofs,
        "counts": counts,
        "default_heights": defaults,
    }
    with open(os.path.join(out_dir, "scenery.json"), "w", encoding="utf-8") as f:
        f.write(_dump(meta))
    log(f"surroundings: {counts['buildings']} buildings ({counts['skyline']} skyline, {len(defaults)} "
        f"with a guessed height), {counts['grandstands']} grandstands, {counts['bridges']} bridges, "
        f"{counts['masts']} masts, {counts['lamps']} lamps, {len(trees)} trees, {len(water)} water bodies")
    log(f"  scenery.glb: {stats['triangles']} triangles in {stats['chunks']} chunks, "
        f"{stats['bytes'] / 1e6:.2f} MB; land cover near: "
        + ", ".join(f"{c} {100 * v:.0f} %" for c, v in zip(CLASSES, share) if v >= 0.005))
    return {"meta": meta, "near": near, "far": far, "footprints": footprints, "trees": trees,
            "track": corridor.xz, "detail": detail, "sea": sea}


def _dump(meta):
    """scenery.json: indented, but with the long number lists on one line each."""
    def compact(v):
        return json.dumps(v, separators=(",", ":"), ensure_ascii=False)

    water = meta["water"]
    defaults = meta["default_heights"]
    chunks = meta["trees"]["chunks"]
    slim = dict(meta, water="@water", default_heights="@defaults",
                trees=dict(meta["trees"], chunks="@chunks"))
    text = json.dumps(slim, indent=1, ensure_ascii=False)
    for token, items in (("@water", water), ("@defaults", defaults)):
        body = "[\n" + ",\n".join("  " + compact(i) for i in items) + "\n ]" if items else "[]"
        text = text.replace(f'"{token}"', body)
    return text.replace('"@chunks"', compact(chunks)) + "\n"


# ----------------------------------------------------------------------------- check plot
PLOT_COLOURS = ["#b7d79a", "#4f8a4c", "#7db7dc", "#ead9a0", "#b9b9b9", "#dcc98a", "#8c8377", "#cdbfa8",
                "#9cb36b", "#f1e3b4"]


def plot(result, path):
    """Top-down check picture: land cover, building footprints coloured by height, trees,
    water outlines and the centreline; the far land cover beside it. North is up."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    from matplotlib.colors import ListedColormap, Normalize

    near, far, meta = result["near"], result["far"], result["meta"]
    cmap = ListedColormap(PLOT_COLOURS)
    fig, (ax, bx) = plt.subplots(1, 2, figsize=(24, 13), gridspec_kw={"width_ratios": [1.6, 1.0]})

    def show(a, r):
        a.imshow(r.cls, cmap=cmap, vmin=-0.5, vmax=9.5, interpolation="nearest",
                 extent=[r.x0, r.x0 + r.nx * r.step, -(r.z0 + r.nz * r.step), -r.z0])

    show(ax, near)
    trees = result["trees"]
    if len(trees):
        colours = np.array(["#1f5c2a", "#0f3d2e", "#7a8f1f", "#6b8f4a"])[trees[:, 4].astype(int)]
        ax.scatter(trees[:, 0], -trees[:, 2], s=1.2, c=colours, linewidths=0)
    polys = [np.stack([r[:, 0], -r[:, 1]], axis=1) for r, _, _ in result["footprints"]]
    heights = np.array([h for _, h, _ in result["footprints"]])
    kinds = [k for _, _, k in result["footprints"]]
    if polys:
        norm = Normalize(0.0, max(30.0, float(np.percentile(heights, 99))))
        pc = PolyCollection(polys, array=heights, cmap="plasma", norm=norm,
                            edgecolors=["#d0021b" if k == "stand" else "#22222288" for k in kinds],
                            linewidths=[1.4 if k == "stand" else 0.2 for k in kinds])
        ax.add_collection(pc)
        fig.colorbar(pc, ax=ax, fraction=0.025, pad=0.01, label="building height (m); grandstands outlined red")
        bx.add_collection(PolyCollection(polys, facecolors="#3b1f6b", edgecolors="none"))
    for body in meta["water"]:
        p = np.array(body["polygon"])
        if body["kind"] != "sea":
            ax.plot(np.append(p[:, 0], p[0, 0]), -np.append(p[:, 1], p[0, 1]), color="#1f5f8f", lw=0.6)
    t = result["track"]
    for a in (ax, bx):
        a.plot(np.append(t[:, 0], t[0, 0]), -np.append(t[:, 1], t[0, 1]), color="#111111", lw=1.6)
        a.set_aspect("equal")
    ax.set_xlim(near.x0, near.x0 + near.nx * near.step)
    ax.set_ylim(-(near.z0 + near.nz * near.step), -near.z0)
    c = meta["counts"]
    ax.set_title(f"near land cover (2.5 m): {c['buildings']} buildings, {c['grandstands']} grandstands, "
                 f"{meta['trees']['count']} trees, {len(meta['water'])} water bodies")
    show(bx, far)
    bx.set_xlim(far.x0, far.x0 + far.nx * far.step)
    bx.set_ylim(-(far.z0 + far.nz * far.step), -far.z0)
    bx.set_title("far land cover (50 m) and every building footprint")
    handles = [plt.Rectangle((0, 0), 1, 1, color=col) for col in PLOT_COLOURS]
    bx.legend(handles, CLASSES, loc="lower right", fontsize=8, ncol=2)
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)
    return path
