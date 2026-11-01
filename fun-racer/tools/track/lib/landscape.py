"""Far landscape of a survey track: the IGN orthophoto draped over the terrain, and the
buildings' real heights from BD TOPO.

1. Orthophoto drape (run from tools/track; downloads the low-resolution blocks it needs once):

    nice -n 10 ../../.venv/bin/python -m lib.landscape wec_le_mans_survey

   writes next to terrain.json

     terrain_ortho.jpg       the near terrain rectangle, one pixel per land-cover cell (2.5 m)
     terrain_ortho_far.jpg   the far terrain rectangle, FAR_PX x FAR_PX pixels (~5.7 m)
     landscape.json          their grids, how they are encoded, the attribution

   The pictures are not colours but RATIOS: every pixel holds, per channel, log2 of (linear
   orthophoto colour) / (mean linear orthophoto colour of its land-cover class in that
   picture), mapped from [LOG_MIN, LOG_MAX] to 0..255, so 128 = "as the class average". The
   game multiplies its land-cover palette colour by 2^(that x strength) (scripts/track/
   terrain_ortho.gd, realistic look only), which keeps the track's
   own palette (the "realistic" terrain_palette of environment.json) as the average and takes
   only the real pattern from the photograph: fields, hedgerows, tracks, clearings, town
   blocks. The haze and the colour cast of the aerial photograph divide out, so it does not
   read as a satellite picture glued on. The game fades it out on the verges and lets the
   procedural ground detail through near the camera.

   Sources: the BD ORTHO 20 cm blocks already in the cache (``ortho/ortho_<x0>_<y0>.tif``,
   fetched by lib.ign_data along the lap) averaged down, and, where they do not reach, blocks
   of the same WMS layer asked at 2 m (near) or 4 m (far) per pixel, cached in
   ``ortho_lowres/``. Everything is resampled from Lambert-93 (EPSG:2154) into the track frame
   with pyproj and lib.geom.Projection (the plan scale of terrain.json), as lib.ortho does.

2. Building heights (``apply_building_heights``, called by lib/surroundings.py): every OSM
   building whose footprint is covered by BD TOPO ``batiment`` features (cached by
   lib.ign_data, ``topo/batiment/``) gets the measured height: highest roof point minus lowest
   ground point (``altitude_maximale_toit - altitude_minimale_sol``, IGN photogrammetry /
   lidar), else ``hauteur`` (to the gutter) plus a roof allowance. The OSM guesses (type
   default, neighbours, levels x 3 m) are replaced; heights set by the recipe stay. BD TOPO
   buildings that OSM does not have (over MISSING_MIN_AREA) come back as extra solids. Tracks
   without ``raw/ign_manifest.json`` in their folder, or without the BD TOPO cache, are left
   exactly as before.

Licence: IGN, Licence Ouverte 2.0 (credit "IGN"); the products carry the attribution.
"""
import json
import math
import os
import sys

import numpy as np

from . import geom
from .net import BuildError

ATTRIBUTION = "Orthophotos and building heights: BD ORTHO, BD TOPO (IGN, Licence Ouverte 2.0)"
CACHE = "~/.cache/fun-racer/ign"
BLOCK_M = 400.0                  # cached 20 cm blocks (lib.ign_data)
BLOCK_PX = 2000
NEAR_FILE = "terrain_ortho.jpg"
FAR_FILE = "terrain_ortho_far.jpg"
META_FILE = "landscape.json"
NEAR_SRC_RES = 1.0               # m per pixel of the Lambert-93 mosaic behind the near picture
FAR_SRC_RES = 4.0
NEAR_WMS = (2000.0, 1000)        # low-resolution WMS block: edge (m), pixels (2 m per pixel)
FAR_WMS = (4000.0, 1000)         # 4 m per pixel
FAR_PX = 2048
JPEG_QUALITY = 85
LOG_MIN, LOG_MAX = -2.0, 2.0     # encoded range of log2(ratio): 1/4 .. 4 x the class mean
MIN_CLASS_PIXELS = 2000          # fewer: the class takes the mean of the whole picture
WMS_URL = "https://data.geopf.fr/wms-r/wms"
ORTHO_LAYER = "ORTHOIMAGERY.ORTHOPHOTOS.BDORTHO"

# ----------------------------------------------------------------------------- frames


def track_frame(track_dir):
    """(track, terrain meta, to_l93(x, z) -> (E, N), from_l93(E, N) -> (x, z))."""
    from pyproj import Transformer
    with open(os.path.join(track_dir, "track.json"), encoding="utf-8") as f:
        track = json.load(f)
    with open(os.path.join(track_dir, "terrain.json"), encoding="utf-8") as f:
        terr = json.load(f)
    proj = geom.Projection(track["origin_latlon"][0], track["origin_latlon"][1], terr.get("plan_scale", 1.0))
    fwd = Transformer.from_crs("EPSG:4326", "EPSG:2154", always_xy=True)
    back = Transformer.from_crs("EPSG:2154", "EPSG:4326", always_xy=True)

    def to_l93(x, z):
        lat, lon = proj.to_latlon(np.asarray(x, float), np.asarray(z, float))
        return fwd.transform(lon, lat)

    def from_l93(e, n):
        lon, lat = back.transform(np.asarray(e, float), np.asarray(n, float))
        return proj.to_xz(lat, lon)
    return track, terr, to_l93, from_l93


def grid_l93(to_l93, x0, z0, step, nx, nz, coarse=16):
    """Lambert-93 of the centres of an nx x nz grid of `step` cells (row = z): exact on every
    `coarse`-th node, bilinear in between (the map is smooth to well under a centimetre)."""
    from scipy.ndimage import map_coordinates
    ci = np.arange(0, nx + coarse, coarse, dtype=float)
    cj = np.arange(0, nz + coarse, coarse, dtype=float)
    X, Z = np.meshgrid(x0 + (ci + 0.5) * step, z0 + (cj + 0.5) * step)
    E, N = to_l93(X, Z)
    jj, ii = np.meshgrid(np.arange(nz) / coarse, np.arange(nx) / coarse, indexing="ij")
    return (map_coordinates(np.asarray(E), [jj, ii], order=1),
            map_coordinates(np.asarray(N), [jj, ii], order=1))


# ----------------------------------------------------------------------------- the mosaic

def wms_url(e0, n0, size_m, px):
    import urllib.parse
    q = {"SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetMap", "LAYERS": ORTHO_LAYER,
         "STYLES": "", "CRS": "EPSG:2154", "FORMAT": "image/jpeg",
         "BBOX": f"{e0},{n0},{e0 + size_m},{n0 + size_m}", "WIDTH": px, "HEIGHT": px}
    return WMS_URL + "?" + urllib.parse.urlencode(q)


class Mosaic:
    """RGB (float32, 0..255) of the BD ORTHO over a Lambert-93 box on a `res` m pixel grid,
    row 0 north. Filled from the cached 20 cm blocks (box-averaged), then from low-resolution
    WMS blocks (`wms` = (edge m, pixels)) where those are missing; `fetch(url, name)` returns
    the bytes of a WMS answer (cached), None = offline (gaps stay empty)."""

    def __init__(self, e0, n0, e1, n1, res, cache_root, wms, fetch=None, log=print):
        self.res = float(res)
        self.e0 = math.floor(e0 / BLOCK_M) * BLOCK_M
        self.n1 = math.ceil(n1 / BLOCK_M) * BLOCK_M
        e1 = math.ceil(e1 / BLOCK_M) * BLOCK_M
        n0 = math.floor(n0 / BLOCK_M) * BLOCK_M
        self.w = int(round((e1 - self.e0) / res))
        self.h = int(round((self.n1 - n0) / res))
        self.rgb = np.zeros((self.h, self.w, 3), np.float32)
        self.valid = np.zeros((self.h, self.w), bool)
        self.blocks = 0
        self.wms_blocks = 0
        self._fill_blocks(os.path.join(cache_root, "ortho"), n0, e1)
        self._fill_wms(cache_root, wms, fetch, log)

    def _fill_blocks(self, root, n0, e1):
        from PIL import Image
        f = int(round(self.res / (BLOCK_M / BLOCK_PX)))
        if f < 1 or BLOCK_PX % f:
            raise BuildError(f"landscape: {self.res} m is not a whole number of 20 cm pixels")
        bp = BLOCK_PX // f
        for x in np.arange(self.e0, e1, BLOCK_M):
            for y in np.arange(n0, self.n1, BLOCK_M):
                path = os.path.join(root, f"ortho_{int(x)}_{int(y)}.tif")
                if not os.path.exists(path):
                    continue
                with Image.open(path) as im:
                    a = np.asarray(im.convert("RGB"), dtype=np.float32)
                if a.shape[:2] != (BLOCK_PX, BLOCK_PX):
                    continue
                a = a.reshape(bp, f, bp, f, 3).mean(axis=(1, 3))
                c = int(round((x - self.e0) / self.res))
                r = int(round((self.n1 - (y + BLOCK_M)) / self.res))
                # WMS answers outside the coverage are white or black: leave those empty.
                ok = (a.sum(axis=2) > 6.0) & (a.min(axis=2) < 250.0)
                self.rgb[r:r + bp, c:c + bp][ok] = a[ok]
                self.valid[r:r + bp, c:c + bp] |= ok
                self.blocks += 1

    def _fill_wms(self, cache_root, wms, fetch, log):
        from io import BytesIO

        from PIL import Image
        from scipy.ndimage import map_coordinates
        size_m, px = wms
        e_end = self.e0 + self.w * self.res
        n_start = self.n1 - self.h * self.res
        for x in np.arange(math.floor(self.e0 / size_m) * size_m, e_end, size_m):
            for y in np.arange(math.floor(n_start / size_m) * size_m, self.n1, size_m):
                c0 = max(int((x - self.e0) / self.res), 0)
                c1 = min(int(math.ceil((x + size_m - self.e0) / self.res)), self.w)
                r0 = max(int((self.n1 - (y + size_m)) / self.res), 0)
                r1 = min(int(math.ceil((self.n1 - y) / self.res)), self.h)
                if c0 >= c1 or r0 >= r1 or self.valid[r0:r1, c0:c1].all():
                    continue
                name = os.path.join("ortho_lowres", f"bdortho_{int(size_m)}m_{px}px_{int(x)}_{int(y)}.jpg")
                path = os.path.join(cache_root, name)
                body = None
                if os.path.exists(path):
                    with open(path, "rb") as fh:
                        body = fh.read()
                elif fetch is not None:
                    log(f"  WMS {name}")
                    body = fetch(wms_url(int(x), int(y), size_m, px), name)
                if body is None:
                    continue
                with Image.open(BytesIO(body)) as im:
                    a = np.asarray(im.convert("RGB"), dtype=np.float32)
                if a.shape[:2] != (px, px):
                    continue
                cell = size_m / px
                rows, cols = np.mgrid[r0:r1, c0:c1]
                e = self.e0 + (cols + 0.5) * self.res
                n = self.n1 - (rows + 0.5) * self.res
                sc = (e - x) / cell - 0.5
                sr = (y + size_m - n) / cell - 0.5
                hole = ~self.valid[r0:r1, c0:c1]
                for ch in range(3):
                    v = map_coordinates(a[..., ch], [sr, sc], order=1, mode="nearest")
                    self.rgb[r0:r1, c0:c1, ch][hole] = v[hole]
                okw = map_coordinates((a.sum(axis=2) > 6.0).astype(np.float32), [sr, sc], order=0, mode="nearest") > 0
                self.valid[r0:r1, c0:c1] |= hole & okw
                self.wms_blocks += 1

    def sample(self, E, N, footprint):
        """Bilinear RGB at Lambert-93 points after a Gaussian prefilter of about `footprint` m
        (the size of the output pixel), and whether each point had data."""
        from scipy.ndimage import gaussian_filter, map_coordinates
        sigma = max(0.0, 0.42 * footprint / self.res - 0.3)
        col = (np.asarray(E) - self.e0) / self.res - 0.5
        row = (self.n1 - np.asarray(N)) / self.res - 0.5
        out = np.empty(np.shape(E) + (3,), np.float32)
        for ch in range(3):
            img = gaussian_filter(self.rgb[..., ch], sigma) if sigma > 0 else self.rgb[..., ch]
            out[..., ch] = map_coordinates(img, [row, col], order=1, mode="nearest")
        ok = map_coordinates(self.valid.astype(np.uint8), [row, col], order=0, mode="constant") > 0
        return out, ok


# ----------------------------------------------------------------------------- the ratios

def srgb_to_linear(v):
    v = np.asarray(v, np.float32) / 255.0
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def class_ratios(rgb, ok, classes, nclass=10):
    """(h, w, 3) uint8 picture of log2(linear colour / class mean) on [LOG_MIN, LOG_MAX] and
    the class means.
    `rgb` 0..255 sRGB, `ok` where it has data (elsewhere the ratio is 1), `classes` uint8."""
    lin = srgb_to_linear(rgb)
    all_mean = lin[ok].mean(axis=0) if ok.any() else np.full(3, 0.2, np.float32)
    means = {}
    ratio = np.ones_like(lin)
    for c in range(nclass):
        m = ok & (classes == c)
        n = int(m.sum())
        mean = lin[m].mean(axis=0) if n >= MIN_CLASS_PIXELS else all_mean
        mean = np.maximum(mean, 1e-3)
        sel = classes == c
        ratio[sel] = lin[sel] / mean
        if n:
            means[c] = [round(float(v), 4) for v in mean]
    ratio[~ok] = 1.0
    lg = (np.log2(np.maximum(ratio, 1e-4)) - LOG_MIN) / (LOG_MAX - LOG_MIN)
    enc = np.clip(lg * 255.0 + 0.5, 0, 255).astype(np.uint8)
    return enc, means


def landcover_classes(track_dir, grid, x0, z0, step, nx, nz):
    """Land-cover class (uint8) at the centres of a grid, nearest cell of scenery.json's
    `grid` ("near" / "far"); 0 (grass) where there is none."""
    from PIL import Image
    with open(os.path.join(track_dir, "scenery.json"), encoding="utf-8") as f:
        lc = json.load(f)["landcover"][grid]
    with Image.open(os.path.join(track_dir, lc["file"])) as im:
        ids = np.asarray(im.convert("L"))
    xs = x0 + (np.arange(nx) + 0.5) * step
    zs = z0 + (np.arange(nz) + 0.5) * step
    i = np.floor((xs - lc["x0"]) / lc["step"]).astype(int)
    j = np.floor((zs - lc["z0"]) / lc["step"]).astype(int)
    out = np.zeros((nz, nx), np.uint8)
    ii = (i >= 0) & (i < ids.shape[1])
    jj = (j >= 0) & (j < ids.shape[0])
    sub = ids[np.clip(j, 0, ids.shape[0] - 1)][:, np.clip(i, 0, ids.shape[1] - 1)]
    out[np.ix_(jj, ii)] = sub[np.ix_(jj, ii)]
    return out


def drape(track_dir, cache_root=CACHE, fetch=None, log=print, dest=None):
    """Writes terrain_ortho.jpg, terrain_ortho_far.jpg and landscape.json into `dest` (default
    the track folder); returns the meta."""
    dest = dest or track_dir
    from PIL import Image
    cache_root = os.path.expanduser(cache_root)
    _, terr, to_l93, _ = track_frame(track_dir)
    with open(os.path.join(track_dir, "scenery.json"), encoding="utf-8") as f:
        lc = json.load(f)["landcover"]
    near_t, far_t = terr["near"], terr["far"]
    nl = lc["near"]
    # Near: exactly the land-cover grid (same cells, so the class of a pixel is its cell's).
    grids = {
        "near": (nl["x0"], nl["z0"], nl["step"], nl["nx"], nl["nz"], NEAR_SRC_RES, NEAR_WMS, NEAR_FILE),
    }
    fx0, fz0 = far_t["x0"], far_t["z0"]
    fsize = (far_t["nx"] - 1) * far_t["step"]
    grids["far"] = (fx0, fz0, fsize / FAR_PX, FAR_PX, FAR_PX, FAR_SRC_RES, FAR_WMS, FAR_FILE)
    assert abs(nl["x0"] - near_t["x0"]) < 1e-6 and abs(nl["z0"] - near_t["z0"]) < 1e-6
    meta = {"version": 1, "attribution": ATTRIBUTION, "ortho": {
        "encoding": "per channel: log2(linear BD ORTHO colour / mean linear colour of the pixel's "
                    "land-cover class in the same picture), from [log_min, log_max] to 0..255",
        "log_min": LOG_MIN, "log_max": LOG_MAX,
        "source": "BD ORTHO 20 cm blocks (lib.ign_data cache) averaged down, WMS "
                  f"{ORTHO_LAYER} at {NEAR_WMS[0] / NEAR_WMS[1]:g} / {FAR_WMS[0] / FAR_WMS[1]:g} m per "
                  "pixel where they do not reach"}}
    for key, (x0, z0, step, nx, nz, res, wms, fname) in grids.items():
        E, N = grid_l93(to_l93, x0, z0, step, nx, nz)
        pad = 3 * step + 20.0
        mos = Mosaic(float(E.min()) - pad, float(N.min()) - pad, float(E.max()) + pad, float(N.max()) + pad,
                     res, cache_root, wms, fetch, log)
        rgb, ok = mos.sample(E, N, step)
        classes = landcover_classes(track_dir, key, x0, z0, step, nx, nz)
        enc, means = class_ratios(rgb, ok, classes)
        Image.fromarray(enc, "RGB").save(os.path.join(dest, fname), quality=JPEG_QUALITY,
                                         optimize=True)
        cover = float(ok.mean())
        log(f"landscape: {fname} {nx} x {nz} px, {step:.2f} m, {mos.blocks} 20 cm blocks + "
            f"{mos.wms_blocks} WMS blocks, {cover * 100:.1f} % covered")
        meta["ortho"][key] = {"file": fname, "x0": x0, "z0": z0, "step": round(step, 6), "nx": nx, "nz": nz,
                              "covered": round(cover, 4),
                              "class_mean_linear": {str(c): v for c, v in sorted(means.items())}}
    with open(os.path.join(dest, META_FILE), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=1)
        f.write("\n")
    return meta


# ----------------------------------------------------------------------------- buildings
MISSING_MIN_AREA = 30.0      # m^2: smaller BD TOPO buildings without an OSM twin are left out
MISSING_MIN_DIST = 40.0      # m from the centreline: closer, hero objects and the circuit's own
                             # buildings stand there (landmarks), OSM has the rest
MATCH_SHARE = 0.3            # an OSM footprint takes the BD TOPO heights covering this share of it
ROOF_ALLOWANCE = 0.25        # x hauteur, when BD TOPO has no roof altitude (pitched roof guess)
MIN_HEIGHT, MAX_HEIGHT = 2.0, 150.0
# BD TOPO natures not added as plain blocks (glasshouses, silos, towers, monuments).
SKIP_NATURES = ("Serre", "Silo", "Tour, donjon", "Arc de triomphe", "Moulin à vent", "Monument")


def has_topo(track_dir):
    """True when the track is a survey build: an IGN manifest with BD TOPO tiles."""
    man = os.path.join(track_dir, "raw", "ign_manifest.json")
    if not os.path.exists(man):
        return False
    with open(man, encoding="utf-8") as f:
        return bool(json.load(f).get("topo"))


def topo_tiles(to_l93, rect):
    """Ids of the 1 km BD TOPO tiles (lib.ign_data naming) under a track-frame rectangle."""
    xs = np.linspace(rect[0], rect[1], 24)
    zs = np.linspace(rect[2], rect[3], 24)
    X, Z = np.meshgrid(xs, zs)
    E, N = to_l93(X, Z)
    e0, e1 = int(np.floor(np.min(E) / 1000)), int(np.floor(np.max(E) / 1000))
    n0, n1 = int(np.floor(np.min(N) / 1000)), int(np.floor(np.max(N) / 1000))
    return [f"topo_{e:04d}_{n:04d}" for e in range(e0, e1 + 1) for n in range(n0, n1 + 1)]


def fetch_topo(ids, cache, log=print):
    """Downloads the ``batiment`` layer of BD TOPO tiles into the cache (as lib.ign_data)."""
    from .ign_data import topo_url
    for k, tid in enumerate(ids, 1):
        e, n = (int(v) * 1000 for v in tid.split("_")[1:3])
        start = 0
        while True:
            body = cache.get_bytes(topo_url("batiment", e, n, start=start), f"topo/batiment/{tid}_{start}.json")
            got = len(json.loads(body).get("features", []))
            if got < 5000:
                break
            start += 5000
        if k % 10 == 0:
            log(f"  BD TOPO {k}/{len(ids)}")


def topo_height(props):
    """Measured top of a BD TOPO building above its lowest ground point (m), None if unknown."""
    top, sol, h = props.get("altitude_maximale_toit"), props.get("altitude_minimale_sol"), props.get("hauteur")
    if top is not None and sol is not None and top > sol:
        v = float(top) - float(sol)
        if h is not None and h > 0:
            # A roof top far above the gutter height is a mast or a chimney sampled with it.
            v = min(v, float(h) * 2.0 + 4.0)
    elif h is not None and h > 0:
        v = float(h) * (1.0 + ROOF_ALLOWANCE)
    else:
        return None
    return v if MIN_HEIGHT <= v <= MAX_HEIGHT else None


def load_topo(track_dir, from_l93, ids=(), cache_root=CACHE):
    """BD TOPO buildings of the manifest's tiles and of the tiles `ids` that are in the cache,
    in the track frame: [(ring (k, 2), height or None, nature, light construction)], each
    feature once (tiles overlap at their edges)."""
    with open(os.path.join(track_dir, "raw", "ign_manifest.json"), encoding="utf-8") as f:
        tiles = [t["id"] for t in json.load(f).get("topo", [])]
    tiles += [t for t in ids if t not in tiles]
    root = os.path.join(os.path.expanduser(cache_root), "topo", "batiment")
    seen, out = set(), []
    for tid in tiles:
        start = 0
        while True:
            path = os.path.join(root, f"{tid}_{start}.json")
            if not os.path.exists(path):
                break
            with open(path, encoding="utf-8") as f:
                feats = json.load(f).get("features", [])
            for ft in feats:
                fid = ft.get("id")
                if fid in seen or not ft.get("geometry"):
                    continue
                seen.add(fid)
                props = ft.get("properties", {})
                if props.get("etat_de_l_objet") not in (None, "En service"):
                    continue
                geo = ft["geometry"]
                polys = geo["coordinates"] if geo["type"] == "MultiPolygon" else [geo["coordinates"]]
                h = topo_height(props)
                for poly in polys:
                    ring = np.asarray(poly[0], float)[:, :2]
                    if len(ring) < 4:
                        continue
                    x, z = from_l93(ring[:, 0], ring[:, 1])
                    out.append((np.stack([x, z], axis=1)[:-1], h, props.get("nature") or "",
                                bool(props.get("construction_legere"))))
            if len(feats) < 5000:
                break
            start += 5000
    return out


def _poly_area(ring):
    x, z = ring[:, 0], ring[:, 1]
    return 0.5 * abs(float(np.dot(x, np.roll(z, -1)) - np.dot(z, np.roll(x, -1))))


def _sample_points(ring, spacing=1.5):
    """Points on a lattice inside a ring (its centroid when it is smaller than a cell)."""
    from matplotlib.path import Path
    lo, hi = ring.min(axis=0), ring.max(axis=0)
    xs = np.arange(lo[0] + spacing / 2, hi[0], spacing)
    zs = np.arange(lo[1] + spacing / 2, hi[1], spacing)
    if len(xs) and len(zs):
        X, Z = np.meshgrid(xs, zs)
        pts = np.stack([X.ravel(), Z.ravel()], axis=1)
        pts = pts[Path(ring).contains_points(pts)]
        if len(pts):
            return pts
    return ring.mean(axis=0)[None]


class TopoIndex:
    """Which BD TOPO building covers a point: 1.5 m cells of feature ids (last one wins where
    footprints overlap), stored in BLOCK x BLOCK cell blocks that exist only where buildings
    are (a town 5 km away does not need a raster of the fields in between)."""
    CELL = 1.5
    BLOCK = 128

    def __init__(self, topo):
        from matplotlib.path import Path
        self.blocks = {}
        for k, ring in enumerate(t[0] for t in topo):
            a = np.floor(ring.min(axis=0) / self.CELL).astype(int)
            b = np.floor(ring.max(axis=0) / self.CELL).astype(int) + 1
            I, J = np.meshgrid(np.arange(a[0], b[0]), np.arange(a[1], b[1]))
            I, J = I.ravel(), J.ravel()
            inside = Path(ring).contains_points(np.stack([(I + 0.5) * self.CELL, (J + 0.5) * self.CELL], axis=1))
            I, J = I[inside], J[inside]
            bi, bj = I // self.BLOCK, J // self.BLOCK
            for key in set(zip(bi.tolist(), bj.tolist())):
                blk = self.blocks.get(key)
                if blk is None:
                    blk = self.blocks[key] = np.full((self.BLOCK, self.BLOCK), -1, np.int32)
                m = (bi == key[0]) & (bj == key[1])
                blk[J[m] % self.BLOCK, I[m] % self.BLOCK] = k
        self.used = np.zeros(len(topo), bool)

    def at(self, pts):
        ij = np.floor(np.asarray(pts, float) / self.CELL).astype(int)
        out = np.full(len(ij), -1, np.int32)
        bi, bj = ij[:, 0] // self.BLOCK, ij[:, 1] // self.BLOCK
        for key in set(zip(bi.tolist(), bj.tolist())):
            blk = self.blocks.get(key)
            if blk is not None:
                m = (bi == key[0]) & (bj == key[1])
                out[m] = blk[ij[m, 1] % self.BLOCK, ij[m, 0] % self.BLOCK]
        return out


def _inside(rect, c):
    return rect is None or (rect[0] <= c[0] <= rect[1] and rect[2] <= c[1] <= rect[3])


def apply_building_heights(solids, track_dir, rect=None, sky=None, avoid=(), corridor_xz=None, keep=None,
                           cache_root=CACHE, log=print):
    """Sets the measured BD TOPO height on the OSM solids (lib.surroundings.Solid) it covers;
    `keep(solid)` true, a recipe height or an OSM ``height`` tag (a mapper's measure) keep
    theirs. Returns (BD TOPO buildings OSM does not have: [(ring, height)], report dict):
    centre inside `rect` [x0, x1, z0, z1], or inside sky = (rectangle, minimum height) and at
    least that tall (the skyline of the town beyond the detailed area); at least
    MISSING_MIN_DIST from `corridor_xz` (centreline points); not under one of the `avoid`
    rings (footprints the recipe removed). Reads the BD TOPO tiles of the manifest and those
    under the rectangles that are in the cache (``python -m lib.landscape <id> --buildings``
    fetches them). Does nothing on a track without an IGN manifest."""
    if not has_topo(track_dir):
        return [], {}
    _, _, to_l93, from_l93 = track_frame(track_dir)
    ids = []
    for r in (rect, sky[0] if sky else None):
        if r is not None:
            ids += [t for t in topo_tiles(to_l93, r) if t not in ids]
    topo = load_topo(track_dir, from_l93, ids, cache_root)
    # Only what can be used: everything in the detailed area, tall buildings beyond it.
    topo = [t for t in topo if _inside(rect, t[0].mean(axis=0))
            or (sky and t[1] is not None and t[1] >= sky[1] and _inside(sky[0], t[0].mean(axis=0)))]
    if not topo:
        log("landscape: no BD TOPO buildings in the cache, OSM heights kept")
        return [], {}
    index = TopoIndex(topo)
    set_count, kept_recipe, unmatched = 0, 0, 0
    changes = []
    for s in solids:
        if s.kind not in ("building", "part"):
            continue
        pts = _sample_points(s.outer)
        hits = index.at(pts)
        hit = hits[hits >= 0]
        if len(hit):
            index.used[np.unique(hit)] = True
        if s.source == "recipe" or s.ref.startswith("add/") or "height" in s.tags or (keep and keep(s)):
            kept_recipe += 1
            continue
        hs = np.array([topo[k][1] for k in hit if topo[k][1] is not None])
        if len(hs) < MATCH_SHARE * len(pts):
            unmatched += 1
            continue
        h = float(np.percentile(hs, 75))
        # A building:part on top of another starts at min_height: the measure is the top.
        if s.kind == "part" and s.min_height and h <= s.min_height + 1.0:
            continue
        changes.append(abs(h - (s.height if s.height is not None else h)))
        s.height, s.source = round(h, 1), "IGN BD TOPO"
        set_count += 1
    for ring in avoid:
        hits = index.at(_sample_points(np.asarray(ring, float)))
        index.used[np.unique(hits[hits >= 0])] = True
    tree = None
    if corridor_xz is not None:
        from scipy.spatial import cKDTree
        tree = cKDTree(np.asarray(corridor_xz, float))
    missing, sky_added = [], 0
    for k, (ring, h, nature, light) in enumerate(topo):
        if index.used[k] or h is None or light or _poly_area(ring) < MISSING_MIN_AREA:
            continue
        c = ring.mean(axis=0)
        if tree is not None and tree.query(c)[0] < MISSING_MIN_DIST:
            continue
        if nature in SKIP_NATURES:
            continue
        missing.append((ring, round(float(h), 1)))
        sky_added += not _inside(rect, c)
    rep = {"topo_buildings": len(topo), "osm_heights_set": set_count, "osm_unmatched": unmatched,
           "kept": kept_recipe, "added_from_topo": len(missing), "added_skyline": sky_added,
           "median_change_m": round(float(np.median(changes)), 1) if changes else 0.0}
    log(f"landscape: BD TOPO heights on {set_count} OSM buildings (median change "
        f"{rep['median_change_m']} m), {unmatched} not covered, {len(missing)} BD TOPO buildings added "
        f"({sky_added} on the skyline)")
    return missing, rep


# ----------------------------------------------------------------------------- CLI

def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("track", help="track id (assets/tracks/<id>/)")
    ap.add_argument("--ortho", action="store_true", help="only the orthophoto drape")
    ap.add_argument("--buildings", action="store_true",
                    help="only fetch the BD TOPO buildings the surroundings step reads")
    ap.add_argument("--offline", action="store_true", help="use only what is in the cache")
    ap.add_argument("--cache", default=CACHE)
    ap.add_argument("--dest", help="where to write the pictures (default: the track folder)")
    a = ap.parse_args(argv)
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    tdir = os.path.join(root, "assets", "tracks", a.track)
    both = not (a.ortho or a.buildings)
    fetch, cache = None, None
    if not a.offline:
        from .ign_data import IgnCache
        cache = IgnCache(a.cache)
        fetch = cache.get_bytes
    if (a.buildings or both) and cache is not None:
        # The surroundings step's rectangles: the near terrain (detail) and the skyline
        # reach around it (lib.surroundings DEFAULTS far_margin_m).
        from .surroundings import DEFAULTS
        _, terr, to_l93, _ = track_frame(tdir)
        n = terr["near"]
        near = [n["x0"], n["x0"] + (n["nx"] - 1) * n["step"], n["z0"], n["z0"] + (n["nz"] - 1) * n["step"]]
        m = DEFAULTS["far_margin_m"]
        ids = topo_tiles(to_l93, [near[0] - m, near[1] + m, near[2] - m, near[3] + m])
        print(f"BD TOPO: {len(ids)} tiles")
        fetch_topo(ids, cache)
    if a.ortho or both:
        drape(tdir, a.cache, fetch, dest=a.dest)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BuildError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
