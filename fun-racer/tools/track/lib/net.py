"""Cached HTTP access to the OSM API and OpenTopoData.

Every response is cached in the track's ``raw/`` folder, so a build can be repeated with
``--offline`` and the committed caches are what the tests run on.

OpenTopoData public API limits: at most 100 locations per request, 1 request per second and
1000 requests per day. A full track build needs roughly 150-450 requests.
"""
import hashlib
import json
import os
import time
import urllib.error
import urllib.request

USER_AGENT = "fun-racer/0.1 (track builder)"
OSM_API = "https://api.openstreetmap.org/api/0.6"
TOPO_API = "https://api.opentopodata.org/v1"

# name -> (attribution, coverage note)
DATASETS = {
    "eudem25m": "EU-DEM v1.1 25 m (Copernicus, (c) European Union)",
    "srtm30m": "SRTM GL1 30 m (NASA / USGS, public domain)",
    "aster30m": "ASTER GDEM v3 30 m (NASA / METI, public domain)",
    # Not an OpenTopoData dataset: Terrain Tiles on AWS Open Data (Mapzen "terrarium" PNG
    # tiles; a global mosaic of SRTM, EU-DEM, 3DEP and others). No daily quota and a whole
    # circuit needs only a handful of tiles, so this is the source to use when building many
    # tracks. Select it with `[elevation] dataset = "terrarium"`.
    "terrarium": "Terrain Tiles (Mapzen / AWS Open Data; SRTM, EU-DEM, 3DEP and other sources)",
    # The Netherlands only: the national lidar terrain model (ground level, 0.5 m), read
    # through PDOK's WCS as a few averaged GeoTIFF tiles. No quota. Select it with
    # `[elevation] dataset = "ahn"`.
    "ahn": "AHN DTM 0.5 m (Actueel Hoogtebestand Nederland, CC0) via PDOK",
}
TERRARIUM_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium"
TERRARIUM_ZOOM = 13     # ~19 m * cos(latitude) per pixel, finer than the source DEMs
AHN_URL = ("https://service.pdok.nl/rws/ahn/wcs/v1_0?service=WCS&version=2.0.1&request=GetCoverage"
           "&coverageId=dtm_05m&format=image/tiff&interpolation=AVERAGE"
           "&subsettingCrs=http://www.opengis.net/def/crs/EPSG/0/4326"
           "&outputCrs=http://www.opengis.net/def/crs/EPSG/0/4326")
AHN_TILE_PX = 256
# level -> tile size in degrees (lat, lon). "fine" pixels are about 9 x 11 m at 52 N and serve
# the centreline and the near terrain; "coarse" ones (10 times that) serve the horizon grid.
AHN_LEVELS = {"fine": (0.02, 0.04), "coarse": (0.2, 0.4)}
AHN_COARSE_SPAN_DEG = 0.05   # a request spanning more latitude than this is a horizon grid
# EU-DEM covers the EEA39 countries only. This box is a first guess; a null answer inside it
# (North Africa, Russia, open sea) makes the build fall back to the next dataset.
EUDEM_BOX = (34.0, 72.0, -25.0, 45.0)   # lat min, lat max, lon min, lon max


class BuildError(Exception):
    """A problem a human has to fix (recipe, network, data); printed without a traceback."""


class CoverageError(BuildError):
    pass


class Fetcher:
    def __init__(self, cache_dir, offline=False, log=print):
        self.cache_dir = str(cache_dir)
        self.offline = offline
        self.log = log
        self.requests = 0

    def path(self, name):
        return os.path.join(self.cache_dir, name)

    def cached(self, name):
        return os.path.exists(self.path(name))

    def read(self, name):
        with open(self.path(name), "rb") as f:
            return f.read()

    def write(self, name, body):
        os.makedirs(self.cache_dir, exist_ok=True)
        with open(self.path(name), "wb") as f:
            f.write(body)

    def download(self, url, retries=5):
        if self.offline:
            raise BuildError(f"--offline given but {url.split('?')[0]} is not in the cache "
                             f"({self.cache_dir})")
        err = None
        for attempt in range(retries):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
                self.requests += 1
                return urllib.request.urlopen(req, timeout=90).read()
            except urllib.error.HTTPError as e:
                err = e
                if e.code in (400, 404, 410):
                    raise BuildError(f"HTTP {e.code} for {url[:120]}") from e
            except Exception as e:  # timeouts, connection resets
                err = e
            self.log(f"  retry {attempt + 1}/{retries}: {err}")
            time.sleep(3.0 * (attempt + 1))
        raise BuildError(f"download failed: {url[:120]}: {err} (OpenTopoData allows 1000 requests "
                         "per day; everything fetched so far is cached, so just run again later)")

    def get(self, url, name):
        """Body of ``url``, from the cache file ``name`` when present."""
        if self.cached(name):
            return self.read(name)
        body = self.download(url)
        self.write(name, body)
        return body


def choose_dataset(lat, lon):
    """Best OpenTopoData dataset for a location, by coverage."""
    la0, la1, lo0, lo1 = EUDEM_BOX
    if la0 <= lat <= la1 and lo0 <= lon <= lo1:
        return "eudem25m"
    if -56.0 <= lat <= 60.0:
        return "srtm30m"
    return "aster30m"


def fallback_dataset(dataset, lat):
    """Next dataset to try when ``dataset`` has no data at this latitude, or None."""
    order = ["eudem25m", "srtm30m", "aster30m"] if -56.0 <= lat <= 60.0 else ["eudem25m", "aster30m"]
    later = order[order.index(dataset) + 1:] if dataset in order else []
    return later[0] if later else None


def attribution(dataset):
    if dataset in ("terrarium", "ahn"):
        return f"Elevation: {DATASETS[dataset]}."
    return f"Elevation: {DATASETS.get(dataset, dataset)} via OpenTopoData."


_tiles = {}   # (cache_dir, x, y) -> decoded height array, kept for the run


def _terrarium_tile(fetcher, x, y):
    key = (fetcher.cache_dir, x, y)
    if key not in _tiles:
        import io
        import numpy as np
        from PIL import Image
        z = TERRARIUM_ZOOM
        body = fetcher.get(f"{TERRARIUM_URL}/{z}/{x}/{y}.png", f"terrarium_{z}_{x}_{y}.png")
        rgb = np.asarray(Image.open(io.BytesIO(body)).convert("RGB"), dtype=np.float64)
        _tiles[key] = rgb[:, :, 0] * 256.0 + rgb[:, :, 1] + rgb[:, :, 2] / 256.0 - 32768.0
    return _tiles[key]


def _terrarium_elevations(fetcher, latlon):
    """Bilinear samples of the terrarium tile pyramid at TERRARIUM_ZOOM (pixel centres)."""
    import math
    n = 2 ** TERRARIUM_ZOOM
    out = []
    for lat, lon in latlon:
        fx = (lon + 180.0) / 360.0 * n * 256.0 - 0.5
        la = math.radians(max(-85.0, min(85.0, lat)))
        fy = (1.0 - math.asinh(math.tan(la)) / math.pi) / 2.0 * n * 256.0 - 0.5
        x0, y0 = math.floor(fx), math.floor(fy)
        tx, ty = fx - x0, fy - y0
        h = 0.0
        for dx, dy, w in ((0, 0, (1 - tx) * (1 - ty)), (1, 0, tx * (1 - ty)),
                          (0, 1, (1 - tx) * ty), (1, 1, tx * ty)):
            px = (x0 + dx) % (n * 256)
            py = min(max(y0 + dy, 0), n * 256 - 1)
            h += w * _terrarium_tile(fetcher, px // 256, py // 256)[py % 256, px % 256]
        out.append(round(h, 2))
    return out


def _ahn_tile(fetcher, level, tx, ty):
    """Heights (NaN = no data: water, buildings) of one AHN tile; row 0 is the south edge."""
    key = (fetcher.cache_dir, "ahn", level, tx, ty)
    if key not in _tiles:
        import io
        import numpy as np
        from PIL import Image
        dlat, dlon = AHN_LEVELS[level]
        name = f"ahn_{level}_{tx}_{ty}.tif"
        if fetcher.cached(name):
            body = fetcher.read(name)
        else:
            body = fetcher.download(
                f"{AHN_URL}&subset=y({ty * dlat:.6f},{(ty + 1) * dlat:.6f})"
                f"&subset=x({tx * dlon:.6f},{(tx + 1) * dlon:.6f})"
                f"&scaleSize=x({AHN_TILE_PX}),y({AHN_TILE_PX})")
            if body[:4] not in (b"II*\x00", b"MM\x00*"):
                raise BuildError(f"AHN did not answer with a GeoTIFF for tile {name}: {body[:200]!r}")
            fetcher.write(name, body)
            time.sleep(0.5)
        a = np.asarray(Image.open(io.BytesIO(body)), dtype=np.float64)
        if a.shape != (AHN_TILE_PX, AHN_TILE_PX):
            raise BuildError(f"AHN tile {name} has the wrong size {a.shape}")
        a = np.where((a > 1000.0) | (a < -100.0), np.nan, a)    # no-data is 3.4e38
        _tiles[key] = a[::-1]
    return _tiles[key]


def _ahn_elevations(fetcher, latlon):
    """Bilinear samples of AHN tiles (pixel centres); None where the neighbours are no-data."""
    import math
    lats = [la for la, _ in latlon]
    level = "coarse" if lats and max(lats) - min(lats) > AHN_COARSE_SPAN_DEG else "fine"
    dlat, dlon = AHN_LEVELS[level]
    n = AHN_TILE_PX
    out = []
    for lat, lon in latlon:
        fx, fy = lon / dlon * n - 0.5, lat / dlat * n - 0.5
        x0, y0 = math.floor(fx), math.floor(fy)
        tx, ty = fx - x0, fy - y0
        h = wsum = 0.0
        for dx, dy, w in ((0, 0, (1 - tx) * (1 - ty)), (1, 0, tx * (1 - ty)),
                          (0, 1, (1 - tx) * ty), (1, 1, tx * ty)):
            px, py = x0 + dx, y0 + dy
            v = _ahn_tile(fetcher, level, px // n, py // n)[py % n, px % n] if w > 0.0 else math.nan
            if v == v:
                h += w * v
                wsum += w
        out.append(round(h / wsum, 2) if wsum > 0.25 else None)
    return out


def fetch_elevations(fetcher, latlon, dataset, prefix):
    """Elevations in metres (None = no data) for (lat, lon) pairs, 100 per request, cached as
    ``<prefix>_<hash of the request>.json``."""
    if dataset not in DATASETS:
        raise BuildError(f"unknown DEM dataset '{dataset}' (known: {', '.join(DATASETS)})")
    if dataset == "terrarium":
        return _terrarium_elevations(fetcher, latlon)
    if dataset == "ahn":
        return _ahn_elevations(fetcher, latlon)
    out = []
    for c in range(0, len(latlon), 100):
        chunk = latlon[c:c + 100]
        locs = "|".join(f"{la:.7f},{lo:.7f}" for la, lo in chunk)
        # eudem25m keeps the original (dataset-less) key so the Red Bull Ring caches stay valid.
        seed = locs if dataset == "eudem25m" else f"{dataset}:{locs}"
        name = f"{prefix}_{hashlib.sha1(seed.encode()).hexdigest()[:12]}.json"
        if fetcher.cached(name):
            res = json.loads(fetcher.read(name))
        else:
            res = json.loads(fetcher.download(f"{TOPO_API}/{dataset}?locations={locs}"))
            if res.get("status") != "OK":
                raise BuildError(f"OpenTopoData error for {dataset}: {str(res)[:200]}")
            # Stored compactly: only the elevations; the request is identified by the hash.
            res = {"dataset": dataset, "locations": locs,
                   "elevation": [r["elevation"] for r in res["results"]]}
            fetcher.write(name, json.dumps(res).encode())
            time.sleep(1.1)  # public rate limit: 1 request / s
            if (c // 100) % 10 == 9:
                fetcher.log(f"  DEM {c + len(chunk)}/{len(latlon)} points")
        # Two cache layouts exist: the raw API answer and the compact one written above.
        vals = res["elevation"] if "elevation" in res else [r["elevation"] for r in res["results"]]
        if len(vals) != len(chunk):
            raise BuildError(f"cache file {name} does not match its request")
        out += vals
    return out
