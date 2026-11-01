"""Rhineland-Palatinate (LVermGeo RLP) open geodata along a lap: DGM1, laser points, DOP20, LoD2.

All four products are Datenlizenz Deutschland - Namensnennung - Version 2.0 (dl-de/by-2-0, credit
"GeoBasis-DE / LVermGeo RP"), served as plain Apache directory listings, no key, no WCS needed:

    https://geobasis-rlp.de/data/<product>/current/<kind>/<file>

- dgm1      dgm1/current/tif/dgm1_32_<E>_<N>_1_rp_2025.tif   1 km tile, 1 m, float32 GeoTIFF, ~1.5 MB
- las       las/current/las/lpolpg_32_<E>_<N>_1_rp.laz       1 km tile, classified (2 ground, 3-5
                                                             vegetation, 6 building), ~100-160 MB
- dop20     dop20rgb/current/jp2/dop20rgb_32_<E>_<N>_2_rp_2025.jp2 (+ .j2w)   2 km tile, 20 cm RGB, ~140 MB
- lod2      geb3dlo/current/gml/LoD2_32_<E>_<N>_2_RP.gml     2 km tile, CityGML, 40-100 KB
(E, N: south-west corner in km, EPSG:25832 ETRS89 / UTM 32N; heights DHHN2016 normal heights.)

Raw files go to ``~/.cache/fun-racer/rlp/<product>/`` (never git); only a manifest (names, URLs,
sizes, sha256) is committed. Run from tools/track:

    ../../.venv/bin/python -m lib.rlp_data n24_nurburgring --plan
    ../../.venv/bin/python -m lib.rlp_data n24_nurburgring --products dgm1,dop20,lod2 \
        --las-within 150 --manifest out.json
"""
import concurrent.futures
import hashlib
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.request

from .net import BuildError

USER_AGENT = "fun-racer/0.1 (track builder; https://github.com/YannickDurindel/fun)"
BASE = "https://geobasis-rlp.de/data"
CACHE_DIR = "~/.cache/fun-racer/rlp"
ATTRIBUTION = "GeoBasis-DE / LVermGeo RP (dl-de/by-2-0)"
LICENCE = "https://www.govdata.de/dl-de/by-2-0"
CHUNK = 1 << 20

# product -> (listing path, tile edge in m, filename regex group order E, N, file extensions)
PRODUCTS = {
    "dgm1": {"path": "dgm1/current/tif", "tile": 1000, "exts": (".tif",),
             "name": "dgm1_32_{e}_{n}_1_rp_2025.tif"},
    "las": {"path": "las/current/las", "tile": 1000, "exts": (".laz",),
            "name": "lpolpg_32_{e}_{n}_1_rp.laz"},
    "dop20": {"path": "dop20rgb/current/jp2", "tile": 2000, "exts": (".jp2", ".j2w"),
              "name": "dop20rgb_32_{e}_{n}_2_rp_2025.jp2"},
    "lod2": {"path": "geb3dlo/current/gml", "tile": 2000, "exts": (".gml",),
             "name": "LoD2_32_{e}_{n}_2_RP.gml"},
}
_NAME_RE = re.compile(r"_32_(\d+)_(\d+)_")


# ---------- geometry: lap -> UTM 32N -> tiles ----------

def lap_xy_utm(track, plan_scale=1.0):
    """The lap (track.json dict) as an (n, 2) array of EPSG:25832 easting / northing, going
    back to lat / lon the way the build placed the points (lib.geom.Projection, plan scale)."""
    import numpy as np
    from pyproj import Transformer
    from .geom import Projection
    proj = Projection(track["origin_latlon"][0], track["origin_latlon"][1], plan_scale)
    pts = np.array([p["p"] for p in track["points"]], dtype=float)
    lat, lon = proj.to_latlon(pts[:, 0], pts[:, 2])
    e, n = Transformer.from_crs("EPSG:4326", "EPSG:25832", always_xy=True).transform(lon, lat)
    return np.column_stack([e, n])


def frame_to_utm(track, x, z, plan_scale=1.0):
    """Godot frame (x east, z -north, metres) -> EPSG:25832 (e, n)."""
    from pyproj import Transformer
    from .geom import Projection
    proj = Projection(track["origin_latlon"][0], track["origin_latlon"][1], plan_scale)
    lat, lon = proj.to_latlon(x, z)
    return Transformer.from_crs("EPSG:4326", "EPSG:25832", always_xy=True).transform(lon, lat)


def _box_dist(xy, x0, y0, x1, y1):
    import numpy as np
    dx = np.maximum(np.maximum(x0 - xy[:, 0], xy[:, 0] - x1), 0.0)
    dy = np.maximum(np.maximum(y0 - xy[:, 1], xy[:, 1] - y1), 0.0)
    return np.hypot(dx, dy)


def corridor_cells(xy, buffer_m, tile_m):
    """Set of (i, j) cells (south-west corner / tile_m, floored) of a ``tile_m`` grid whose box
    lies within ``buffer_m`` of the polyline ``xy`` (vertices are dense enough: 2 m)."""
    import numpy as np
    xy = np.asarray(xy, dtype=float)
    out = set()
    i0, i1 = (np.floor((xy[:, 0].min() - buffer_m) / tile_m), np.floor((xy[:, 0].max() + buffer_m) / tile_m))
    j0, j1 = (np.floor((xy[:, 1].min() - buffer_m) / tile_m), np.floor((xy[:, 1].max() + buffer_m) / tile_m))
    for i in range(int(i0), int(i1) + 1):
        for j in range(int(j0), int(j1) + 1):
            near = xy[(xy[:, 0] > i * tile_m - buffer_m - 1) & (xy[:, 0] < (i + 1) * tile_m + buffer_m + 1)
                      & (xy[:, 1] > j * tile_m - buffer_m - 1) & (xy[:, 1] < (j + 1) * tile_m + buffer_m + 1)]
            if len(near) and _box_dist(near, i * tile_m, j * tile_m, (i + 1) * tile_m,
                                       (j + 1) * tile_m).min() <= buffer_m:
                out.add((i, j))
    return out


def tile_name(product, e_km, n_km):
    """Published file name of the tile whose south-west corner is (e_km, n_km) km. The 2 km
    products are named by an even-km corner."""
    return PRODUCTS[product]["name"].format(e=e_km, n=n_km)


def tile_bounds(name):
    """(x0, y0, x1, y1) in EPSG:25832 metres of a published tile name."""
    m = _NAME_RE.search(name)
    if not m:
        raise BuildError(f"not an RLP tile name: {name}")
    e, n = int(m.group(1)) * 1000, int(m.group(2)) * 1000
    edge = 2000 if re.search(r"_2_(rp|RP)", name) else 1000
    return (e, n, e + edge, n + edge)


def corridor_tiles(xy, product, buffer_m=600.0):
    """Tile names of ``product`` covering the buffered lap."""
    edge = PRODUCTS[product]["tile"]
    return sorted(tile_name(product, i * edge // 1000, j * edge // 1000)
                  for i, j in corridor_cells(xy, buffer_m, edge))


def parse_size(txt):
    """'159M' / '1.6M' / '86K' / '2.1G' / '1234' (Apache listing) -> bytes."""
    txt = txt.strip()
    mult = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30}.get(txt[-1:].upper(), 1)
    return int(float(txt[:-1] if mult > 1 else txt) * mult)


def parse_listing(html):
    """{file name: approximate bytes} from an Apache directory listing page."""
    out = {}
    for m in re.finditer(r'<a href="([^"?/][^"]*)">[^<]*</a></td>\s*<td[^>]*>[^<]*</td>\s*<td[^>]*>\s*([\d.]+[KMG]?)\s*</td>', html):
        out[m.group(1)] = parse_size(m.group(2))
    return out


# ---------- network, cached ----------

def cache_dir(sub=""):
    d = os.path.join(os.path.expanduser(CACHE_DIR), sub)
    os.makedirs(d, exist_ok=True)
    return d


def listing(product, refresh=False):
    """Name -> approximate bytes of every file of a product (one big HTML page, cached 30 days)."""
    path = os.path.join(cache_dir(), f"index_{product}.json")
    if not refresh and os.path.exists(path) and time.time() - os.path.getmtime(path) < 30 * 86400:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    url = f"{BASE}/{PRODUCTS[product]['path']}/"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=180) as r:
        files = parse_listing(r.read().decode("utf-8", "replace"))
    with open(path, "w", encoding="utf-8") as f:
        json.dump(files, f)
    return files


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(CHUNK), b""):
            h.update(b)
    return h.hexdigest()


def fetch(product, name, retries=4):
    """Download one file into the cache (resume-safe: ``.part`` + Range, atomic rename) and
    return its manifest entry. A finished file is reused if its ``.sha256`` side file matches."""
    d = cache_dir(product)
    dest, part, side = os.path.join(d, name), os.path.join(d, name + ".part"), os.path.join(d, name + ".sha256")
    url = f"{BASE}/{PRODUCTS[product]['path']}/{name}"
    if os.path.exists(dest) and os.path.exists(side):
        with open(side, encoding="utf-8") as f:
            sha = f.read().strip()
        if sha:
            return {"name": name, "url": url, "bytes": os.path.getsize(dest), "sha256": sha}
    last = None
    for attempt in range(retries):
        try:
            have = os.path.getsize(part) if os.path.exists(part) else 0
            hdr = {"User-Agent": USER_AGENT}
            if have:
                hdr["Range"] = f"bytes={have}-"
            try:
                resp = urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=120)
            except urllib.error.HTTPError as e:
                if e.code == 416:           # part already complete
                    resp = None
                else:
                    raise
            if resp is not None:
                if have and resp.status != 206:
                    have = 0                 # server ignored Range: start over
                with resp, open(part, "ab" if have else "wb") as f:
                    for b in iter(lambda: resp.read(CHUNK), b""):
                        f.write(b)
            os.replace(part, dest)
            sha = sha256_file(dest)
            with open(side, "w", encoding="utf-8") as f:
                f.write(sha)
            return {"name": name, "url": url, "bytes": os.path.getsize(dest), "sha256": sha}
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            last = e
            if isinstance(e, urllib.error.HTTPError) and e.code == 404:
                raise BuildError(f"{url}: 404 (outside the RLP data?)")
            time.sleep(2 * (attempt + 1))
    raise BuildError(f"download failed for {url}: {last}")


def index_by_tile(idx):
    """{(e_km, n_km): [file names]} from a listing (the year in a name varies per tile)."""
    out = {}
    for fname in idx:
        m = _NAME_RE.search(fname)
        if m:
            out.setdefault((int(m.group(1)), int(m.group(2))), []).append(fname)
    return out


def plan(track_id_or_track, products=("dgm1", "las", "dop20", "lod2"), buffer_m=600.0, plan_scale=1.0,
         las_within=None):
    """{product: [(file name, approx bytes)]} for the lap corridor. ``las_within`` (m) restricts
    the (huge) point clouds to tiles within that distance of the lap."""
    xy = lap_xy_utm(track_id_or_track, plan_scale)
    out = {}
    for prod in products:
        buf = las_within if (prod == "las" and las_within is not None) else buffer_m
        idx = listing(prod)
        by_tile = index_by_tile(idx)
        edge = PRODUCTS[prod]["tile"] // 1000
        rows = []
        for i, j in sorted(corridor_cells(xy, buf, edge * 1000)):
            for fname in sorted(by_tile.get((i * edge, j * edge), [])):
                if fname.endswith(PRODUCTS[prod]["exts"]):
                    rows.append((fname, idx[fname]))
        out[prod] = rows
    return out


def run(plan_rows, workers=3):
    """Download everything in ``plan_rows`` ({product: [(name, size)]}); returns the manifest."""
    jobs = [(p, n) for p, rows in plan_rows.items() for n, _ in rows]
    entries = {p: [] for p in plan_rows}
    with concurrent.futures.ThreadPoolExecutor(workers) as ex:
        futs = {ex.submit(fetch, p, n): (p, n) for p, n in jobs}
        done = 0
        for fu in concurrent.futures.as_completed(futs):
            p, n = futs[fu]
            entries[p].append(fu.result())
            done += 1
            if done % 10 == 0 or done == len(jobs):
                print(f"  {done}/{len(jobs)} files", file=sys.stderr, flush=True)
    for p in entries:
        entries[p].sort(key=lambda e: e["name"])
    return {"attribution": ATTRIBUTION, "licence": LICENCE, "base": BASE, "products": entries}


# ---------- reading ----------

def cached_dgm1_tiles():
    """{(e_km, n_km)} of the DGM1 tiles already in the cache."""
    out = set()
    for f in os.listdir(cache_dir("dgm1")):
        m = _NAME_RE.search(f)
        if m and f.endswith(".tif"):
            out.add((int(m.group(1)), int(m.group(2))))
    return out


def dgm1_height(e, n, tiles=None):
    """Bilinear height (m, DHHN2016) of DGM1 at EPSG:25832 (e, n) from the cached tiles, or
    nan where a tile is missing. ``tiles`` is a dict cache shared between calls."""
    import numpy as np
    from PIL import Image
    if tiles is None:
        tiles = {}
    # pixel centres sit at +0.5 m: sample on the grid of centres
    gx, gy = e - 0.5, n - 0.5
    x0, y0 = math.floor(gx), math.floor(gy)
    fx, fy = gx - x0, gy - y0
    vals = []
    for dx in (0, 1):
        for dy in (0, 1):
            px, py = x0 + dx, y0 + dy
            ti, tj = px // 1000, py // 1000
            if (ti, tj) not in tiles:
                d = cache_dir("dgm1")
                hit = [f for f in os.listdir(d) if f.startswith(f"dgm1_32_{ti}_{tj}_") and f.endswith(".tif")]
                tiles[(ti, tj)] = np.array(Image.open(os.path.join(d, hit[0]))) if hit else None
            a = tiles[(ti, tj)]
            vals.append(math.nan if a is None else float(a[999 - (py - tj * 1000), px - ti * 1000]))
    v00, v01, v10, v11 = vals
    return (v00 * (1 - fx) * (1 - fy) + v01 * (1 - fx) * fy + v10 * fx * (1 - fy) + v11 * fx * fy)


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("track")
    ap.add_argument("--products", default="dgm1,las,dop20,lod2")
    ap.add_argument("--buffer", type=float, default=600.0)
    ap.add_argument("--las-within", type=float, default=None, help="point-cloud corridor (m)")
    ap.add_argument("--plan", action="store_true", help="list + sizes, no download")
    ap.add_argument("--manifest")
    a = ap.parse_args(argv)
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    tdir = os.path.join(root, "assets", "tracks", a.track)
    with open(os.path.join(tdir, "track.json"), encoding="utf-8") as f:
        track = json.load(f)
    scale = 1.0
    if os.path.exists(os.path.join(tdir, "terrain.json")):
        with open(os.path.join(tdir, "terrain.json"), encoding="utf-8") as f:
            scale = json.load(f).get("plan_scale", 1.0)
    rows = plan(track, tuple(a.products.split(",")), a.buffer, scale, a.las_within)
    for p, r in rows.items():
        known = sum(s or 0 for _, s in r)
        print(f"{p}: {len(r)} files, ~{known / 1e9:.2f} GB, missing from listing: "
              f"{sum(1 for _, s in r if s is None)}")
    if a.plan:
        return
    man = run(rows)
    if a.manifest:
        with open(a.manifest, "w", encoding="utf-8") as f:
            json.dump(man, f, indent=1)


if __name__ == "__main__":
    main()
