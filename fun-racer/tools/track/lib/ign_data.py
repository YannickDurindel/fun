"""IGN Geoplateforme open data along a lap: LiDAR HD, BD ORTHO 20 cm and BD TOPO.

All three are Licence Ouverte 2.0 (credit "IGN"). The raw files are large (a LiDAR HD tile is
100-300 MB), so they live in a cache shared by every build, ``~/.cache/fun-racer/ign/``, and
never in git; only a small manifest (tile ids, URLs, sizes, sha256) is committed next to the
track. Run from tools/track:

    ../../.venv/bin/python -m lib.ign_data wec_le_mans --plan            # list + sizes, no download
    ../../.venv/bin/python -m lib.ign_data wec_le_mans --lidar-within 150 --manifest out.json

Interfaces (all anonymous, rate limit 1 request per second per client):
- LiDAR HD tile index: WFS ``https://data.geopf.fr/wfs/ows`` layer
  ``IGNF_LIDAR-HD_METADONNEE:metadata``; each feature carries ``url_npl``, the COPC .laz
  download (``data.geopf.fr/telechargement/download/LiDARHD-NUALID/...``), 1 km tiles named by
  their north-west corner in km, ``LHD_FXX_<E>_<N>_PTS_LAMB93_IGN69.copc.laz`` (EPSG:2154,
  heights IGN69). Point classes: 2 ground, 9 water, 3-5 vegetation, 6 building, 17 bridge.
- BD ORTHO 20 cm: WMS ``https://data.geopf.fr/wms-r/wms`` layer
  ``ORTHOIMAGERY.ORTHOPHOTOS.BDORTHO``, asked in EPSG:2154 as 2000 x 2000 px GeoTIFF blocks of
  400 m (exactly 0.20 m per pixel, georeferenced).
- BD TOPO v3: WFS layers ``BDTOPO_V3:batiment`` (footprints, ``hauteur``) and a few road
  furniture layers, as GeoJSON in EPSG:2154, one file per 1 km tile.
- PCRS 5 cm: Le Mans Metropole has a PCRS project, but the WFS graph
  ``GRAPHE.PCRS.ANCT:graphe_pcrs_anct`` marks it ``licence = "ferme"`` with no diffusion
  layer, so it is not open data and is not fetched.
"""
import hashlib
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from .net import BuildError

USER_AGENT = "fun-racer/0.1 (track builder; https://github.com/YannickDurindel/fun)"
CACHE_DIR = "~/.cache/fun-racer/ign"
ATTRIBUTION = "IGN (Licence Ouverte 2.0)"
WFS_URL = "https://data.geopf.fr/wfs/ows"
WMS_URL = "https://data.geopf.fr/wms-r/wms"
LIDAR_LAYER = "IGNF_LIDAR-HD_METADONNEE:metadata"
ORTHO_LAYER = "ORTHOIMAGERY.ORTHOPHOTOS.BDORTHO"
ORTHO_BLOCK_M = 400          # block edge, m
ORTHO_BLOCK_PX = 2000        # 0.20 m per pixel
TOPO_LAYERS = ("batiment", "construction_surfacique", "construction_lineaire",
               "construction_ponctuelle", "equipement_de_transport", "troncon_de_route")
TILE_M = 1000
PAUSE = 1.1                  # s between two requests (the service allows 1 per second)
CHUNK = 1 << 20


# ---------- geometry: lap -> Lambert-93 -> tiles ----------

def lap_xy_l93(track, plan_scale=1.0):
    """The lap (track.json dict) as an (n, 2) array of Lambert-93 easting / northing.

    The frame is x east, z -north from ``origin_latlon`` on lib.geom.Projection's flat earth,
    scaled by ``plan_scale`` (terrain.json), so the points go back to lat / lon the same way
    the build placed them and are then projected with pyproj."""
    import numpy as np
    from pyproj import Transformer
    from .geom import Projection
    proj = Projection(track["origin_latlon"][0], track["origin_latlon"][1], plan_scale)
    pts = np.array([p["p"] for p in track["points"]], dtype=float)
    lat, lon = proj.to_latlon(pts[:, 0], pts[:, 2])
    tr = Transformer.from_crs("EPSG:4326", "EPSG:2154", always_xy=True)
    e, n = tr.transform(lon, lat)
    return np.column_stack([e, n])


def _box_dist(xy, x0, y0, x1, y1):
    """Distance of each point of ``xy`` to the axis-aligned box (0 inside it)."""
    import numpy as np
    dx = np.maximum(np.maximum(x0 - xy[:, 0], xy[:, 0] - x1), 0.0)
    dy = np.maximum(np.maximum(y0 - xy[:, 1], xy[:, 1] - y1), 0.0)
    return np.hypot(dx, dy)


def corridor_cells(xy, buffer_m, size_m):
    """{(i, j): min distance} for the size_m squares [i*size, (i+1)*size) x [j*size,
    (j+1)*size) lying within ``buffer_m`` of the polyline ``xy`` (points at most a few metres
    apart, as in track.json; a coarser polyline is densified first)."""
    import numpy as np
    xy = densify(xy, 5.0)
    i0 = int(math.floor((xy[:, 0].min() - buffer_m) / size_m))
    i1 = int(math.floor((xy[:, 0].max() + buffer_m) / size_m))
    j0 = int(math.floor((xy[:, 1].min() - buffer_m) / size_m))
    j1 = int(math.floor((xy[:, 1].max() + buffer_m) / size_m))
    out = {}
    for i in range(i0, i1 + 1):
        for j in range(j0, j1 + 1):
            d = float(_box_dist(xy, i * size_m, j * size_m, (i + 1) * size_m,
                                (j + 1) * size_m).min())
            if d <= buffer_m:
                out[(i, j)] = d
    return out


def densify(xy, max_step):
    """``xy`` with extra points so that no two neighbours are further than ``max_step``."""
    import numpy as np
    xy = np.asarray(xy, dtype=float)
    seg = np.hypot(*(xy[1:] - xy[:-1]).T)
    if len(seg) == 0 or seg.max() <= max_step:
        return xy
    out = [xy[:1]]
    for a, b, d in zip(xy[:-1], xy[1:], seg):
        k = max(1, int(math.ceil(d / max_step)))
        t = (np.arange(1, k + 1) / k)[:, None]
        out.append(a + (b - a) * t)
    return np.vstack(out)


def lidar_tile_id(i, j):
    """Tile id of the 1 km square with south-west corner (i, j) km: IGN names a tile by its
    north-west corner, so the northing is j + 1."""
    return f"LHD_FXX_{i:04d}_{j + 1:04d}_PTS_LAMB93_IGN69.copc.laz"


def lidar_tile_bounds(tile_id):
    """(x0, y0, x1, y1) in Lambert-93 metres of a LiDAR HD tile id."""
    parts = tile_id.split("_")
    i, jn = int(parts[2]), int(parts[3])
    return (i * TILE_M, (jn - 1) * TILE_M, (i + 1) * TILE_M, jn * TILE_M)


def lidar_corridor(xy, buffer_m):
    """{tile id: distance of the tile to the lap}."""
    return {lidar_tile_id(i, j): d for (i, j), d in corridor_cells(xy, buffer_m, TILE_M).items()}


def ortho_blocks(xy, buffer_m):
    """{(x0, y0): distance} for the 400 m orthophoto blocks of the corridor (south-west corner)."""
    return {(i * ORTHO_BLOCK_M, j * ORTHO_BLOCK_M): d
            for (i, j), d in corridor_cells(xy, buffer_m, ORTHO_BLOCK_M).items()}


def ortho_url(x0, y0):
    q = {"SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetMap", "LAYERS": ORTHO_LAYER,
         "STYLES": "", "CRS": "EPSG:2154", "FORMAT": "image/geotiff",
         "BBOX": f"{x0},{y0},{x0 + ORTHO_BLOCK_M},{y0 + ORTHO_BLOCK_M}",
         "WIDTH": ORTHO_BLOCK_PX, "HEIGHT": ORTHO_BLOCK_PX}
    return WMS_URL + "?" + urllib.parse.urlencode(q)


def topo_url(layer, x0, y0, size=TILE_M, start=0, count=5000):
    q = {"SERVICE": "WFS", "VERSION": "2.0.0", "REQUEST": "GetFeature",
         "TYPENAMES": f"BDTOPO_V3:{layer}", "OUTPUTFORMAT": "application/json",
         "SRSNAME": "EPSG:2154", "COUNT": count, "STARTINDEX": start,
         "BBOX": f"{x0},{y0},{x0 + size},{y0 + size},EPSG:2154"}
    return WFS_URL + "?" + urllib.parse.urlencode(q)


# ---------- cached, polite downloads ----------

class IgnCache:
    """Downloads into ``root``: resumable (``.part`` + Range), polite (one request per PAUSE
    seconds), every finished file gets a ``.sha256`` sidecar so reruns skip it."""

    def __init__(self, root=CACHE_DIR, log=print, pause=PAUSE):
        self.root = os.path.expanduser(root)
        self.log = log
        self.pause = pause
        self._last = 0.0

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def _wait(self):
        dt = time.time() - self._last
        if dt < self.pause:
            time.sleep(self.pause - dt)
        self._last = time.time()

    def _open(self, url, start=0):
        headers = {"User-Agent": USER_AGENT}
        if start:
            headers["Range"] = f"bytes={start}-"
        self._wait()
        return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=90)

    def head_size(self, url):
        """Content-Length of ``url`` (None when the server does not say)."""
        self._wait()
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=60) as r:
            n = r.headers.get("Content-Length")
        return int(n) if n else None

    def get_bytes(self, url, name, retries=5):
        """Small document (WFS answer), cached as ``name``."""
        dest = self.path(name)
        if os.path.exists(dest):
            with open(dest, "rb") as f:
                return f.read()
        err = None
        for attempt in range(retries):
            try:
                with self._open(url) as r:
                    body = r.read()
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                tmp = dest + ".part"
                with open(tmp, "wb") as f:
                    f.write(body)
                os.replace(tmp, dest)
                return body
            except urllib.error.HTTPError as e:
                err = e
                if e.code in (400, 404, 410):
                    raise BuildError(f"HTTP {e.code} for {url[:140]}") from e
            except Exception as e:
                err = e
            self.log(f"  retry {attempt + 1}/{retries}: {err}")
            time.sleep(3.0 * (attempt + 1))
        raise BuildError(f"download failed: {url[:140]}: {err}")

    def fetch(self, url, name, expect_size=None, retries=8):
        """Large file ``name`` (relative to the cache root), resuming a partial download.
        Returns {"path", "bytes", "sha256"}."""
        dest = self.path(name)
        side = dest + ".sha256"
        if os.path.exists(dest) and os.path.exists(side):
            with open(side) as f:
                digest = f.read().split()[0]
            return {"path": dest, "bytes": os.path.getsize(dest), "sha256": digest}
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        part = dest + ".part"
        err = None
        for attempt in range(retries):
            try:
                have = os.path.getsize(part) if os.path.exists(part) else 0
                with self._open(url, have) as r:
                    total = r.headers.get("Content-Length")
                    if have and r.status != 206:      # the server ignored Range: start over
                        have = 0
                    with open(part, "ab" if have else "wb") as f:
                        while True:
                            b = r.read(CHUNK)
                            if not b:
                                break
                            f.write(b)
                size = os.path.getsize(part)
                want = expect_size or (have + int(total) if total else None)
                if want and size != want:
                    raise BuildError(f"{name}: got {size} bytes, expected {want}")
                break
            except urllib.error.HTTPError as e:
                err = e
                if e.code in (400, 404, 410):
                    raise BuildError(f"HTTP {e.code} for {url[:140]}") from e
                if e.code == 416:                      # the .part is already complete
                    break
            except Exception as e:
                err = e
            self.log(f"  retry {attempt + 1}/{retries}: {err}")
            time.sleep(5.0 * (attempt + 1))
        else:
            raise BuildError(f"download failed: {name}: {err} (partial file kept, run again)")
        digest = sha256_file(part)
        os.replace(part, dest)
        with open(side, "w") as f:
            f.write(f"{digest}  {os.path.basename(dest)}\n")
        return {"path": dest, "bytes": os.path.getsize(dest), "sha256": digest}


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(CHUNK), b""):
            h.update(b)
    return h.hexdigest()


# ---------- LiDAR HD tile index ----------

def lidar_index(cache, xy, buffer_m):
    """{tile id: url} for the tiles that cover the corridor, from the WFS tile index (one
    request for the bounding box of the corridor, paged). Tiles the index does not know are
    absent from the result (the caller reports them as gaps)."""
    x0, y0 = xy.min(axis=0) - buffer_m
    x1, y1 = xy.max(axis=0) + buffer_m
    found, start = {}, 0
    while True:
        q = {"SERVICE": "WFS", "VERSION": "2.0.0", "REQUEST": "GetFeature",
             "TYPENAMES": LIDAR_LAYER, "OUTPUTFORMAT": "application/json",
             "SRSNAME": "EPSG:2154", "COUNT": 500, "STARTINDEX": start,
             "BBOX": f"{x0},{y0},{x1},{y1},EPSG:2154"}
        body = cache.get_bytes(WFS_URL + "?" + urllib.parse.urlencode(q),
                               f"index/lidar_{int(x0)}_{int(y0)}_{int(x1)}_{int(y1)}_{start}.json")
        feats = json.loads(body).get("features", [])
        for f in feats:
            url = f["properties"].get("url_npl")
            if url:
                found[os.path.basename(url)] = url
        if len(feats) < 500:
            return found
        start += 500


# ---------- manifest ----------

def plan(track_path, buffer_m=600.0, cache=None, log=print):
    """What the corridor needs: lidar tiles (with URL and size), ortho blocks, topo tiles, and
    the gaps (tiles the index does not offer)."""
    with open(track_path, encoding="utf-8") as f:
        track = json.load(f)
    scale = 1.0
    terrain = os.path.join(os.path.dirname(track_path), "terrain.json")
    if os.path.exists(terrain):
        with open(terrain, encoding="utf-8") as f:
            scale = json.load(f).get("plan_scale", 1.0)
    xy = lap_xy_l93(track, scale)
    cache = cache or IgnCache(log=log)
    need = lidar_corridor(xy, buffer_m)
    index = lidar_index(cache, xy, buffer_m)
    lidar = []
    for tid, d in sorted(need.items()):
        url = index.get(tid)
        lidar.append({"id": tid, "bounds": list(lidar_tile_bounds(tid)), "dist_m": round(d, 1),
                      "url": url})
    blocks = [{"id": f"ortho_{x}_{y}", "bounds": [x, y, x + ORTHO_BLOCK_M, y + ORTHO_BLOCK_M],
               "dist_m": round(d, 1), "url": ortho_url(x, y)}
              for (x, y), d in sorted(ortho_blocks(xy, buffer_m).items())]
    topo = [{"id": f"topo_{tid.split('_')[2]}_{int(tid.split('_')[3]) - 1}",
             "bounds": list(lidar_tile_bounds(tid)), "layers": list(TOPO_LAYERS)}
            for tid in sorted(need)]
    return {"attribution": ATTRIBUTION, "crs": "EPSG:2154", "buffer_m": buffer_m,
            "plan_scale": scale, "lidar": lidar, "ortho": blocks, "topo": topo,
            "gaps": [t["id"] for t in lidar if not t["url"]]}


def write_manifest(path, manifest):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=1)
        f.write("\n")


def download_lidar(cache, tiles, log=print):
    for k, t in enumerate(tiles, 1):
        if not t["url"]:
            continue
        if "sha256" in t and os.path.exists(cache.path("lidar", t["id"])):
            continue
        log(f"lidar {k}/{len(tiles)} {t['id']} ({t.get('bytes', 0) / 1e6:.0f} MB)")
        r = cache.fetch(t["url"], os.path.join("lidar", t["id"]), t.get("bytes"))
        t["bytes"], t["sha256"] = r["bytes"], r["sha256"]


def download_ortho(cache, blocks, log=print):
    for k, b in enumerate(blocks, 1):
        log(f"ortho {k}/{len(blocks)} {b['id']}")
        r = cache.fetch(b["url"], os.path.join("ortho", b["id"] + ".tif"))
        b["bytes"], b["sha256"] = r["bytes"], r["sha256"]


def download_topo(cache, tiles, log=print):
    for k, t in enumerate(tiles, 1):
        x0, y0 = t["bounds"][:2]
        t["files"] = {}
        for layer in t["layers"]:
            feats, start = [], 0
            while True:
                body = cache.get_bytes(topo_url(layer, x0, y0, start=start),
                                       f"topo/{layer}/{t['id']}_{start}.json")
                got = json.loads(body).get("features", [])
                feats += got
                if len(got) < 5000:
                    break
                start += 5000
            t["files"][layer] = len(feats)
        log(f"topo {k}/{len(tiles)} {t['id']}: {t['files']}")


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("track", help="track id (assets/tracks/<id>/track.json)")
    ap.add_argument("--buffer", type=float, default=600.0)
    ap.add_argument("--lidar-within", type=float, default=None,
                    help="download only LiDAR tiles within this many metres of the lap")
    ap.add_argument("--plan", action="store_true", help="list and size, do not download")
    ap.add_argument("--manifest", required=False, help="where to write the manifest")
    a = ap.parse_args(argv)
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    track_path = os.path.join(os.path.dirname(root), "assets", "tracks", a.track, "track.json")
    cache = IgnCache()
    m = plan(track_path, a.buffer, cache)
    for t in m["lidar"]:
        if t["url"]:
            t["bytes"] = cache.head_size(t["url"])
    tot = sum(t.get("bytes") or 0 for t in m["lidar"])
    near = sum(t.get("bytes") or 0 for t in m["lidar"] if t["dist_m"] <= (a.lidar_within or 0))
    print(f"lidar: {len(m['lidar'])} tiles {tot / 1e9:.2f} GB"
          + (f", {near / 1e9:.2f} GB within {a.lidar_within} m" if a.lidar_within else "")
          + f"; ortho: {len(m['ortho'])} blocks (~{len(m['ortho']) * 12 / 1000:.1f} GB); "
          f"gaps: {m['gaps']}")
    if a.plan:
        if a.manifest:
            write_manifest(a.manifest, m)
        return 0
    lim = a.lidar_within
    sel = [t for t in m["lidar"] if lim is None or t["dist_m"] <= lim]
    for t in m["lidar"]:
        t["downloaded"] = t in sel
    download_lidar(cache, sel)
    download_ortho(cache, m["ortho"])
    download_topo(cache, m["topo"])
    if a.manifest:
        write_manifest(a.manifest, m)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BuildError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
