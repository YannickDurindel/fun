"""IGN LiDAR HD ground model along a lap: a 0.25 m road grid and a 1 m terrain grid.

Run from tools/track (the tiles must be in the cache, see lib/ign_data.py):

    nice -n 10 ../../.venv/bin/python -m lib.lidar wec_le_mans_survey

FORMAT (version 1). Two grids, each a JSON header + a binary file next to track.json:

    lidar_road.json / lidar_road.bin         cell 0.25 m, tiles of 256 cells (64 m), cells within
                                             40 m of the centreline, quantum 1 mm
    lidar_terrain.json / lidar_terrain.bin   cell 1 m, tiles of 256 cells (256 m), cells within
                                             600 m of the centreline, quantum 1 cm

Frame: the track frame of track.json, x = east, z = -north, metres from the finish line, in the
plan scale of the build (``plan_scale``): a Lambert-93 point goes to lat / lon with pyproj
(EPSG:2154 -> EPSG:4326) and then through lib.geom.Projection(origin_latlon, plan_scale).
Heights are IGN69 metres (absolute); the track's y is ``height - origin_elevation_m``.

The grid is a lattice of square cells: cell (ix, iz) (any integers) covers
x in [ix * cell, (ix + 1) * cell), z in [iz * cell, (iz + 1) * cell); its value is the height at
its centre ((ix + 0.5) * cell, (iz + 0.5) * cell). Only the tiles of ``tile`` x ``tile`` cells
that hold data are stored: tile (ti, tj) holds the cells ix = ti * tile + c, iz = tj * tile + r
(c, r = 0 .. tile - 1). JSON ``tiles`` lists [ti, tj, offset, nbytes, base] per tile:
``nbytes`` bytes at ``offset`` in the .bin are one xz stream (Python's lzma.decompress) that
inflates to

    int16[tile * tile]  little endian, row-major (row r = z, column c = x), -32768 = no data
                        (NaN: no ground there, or outside the corridor). Other values D are
                        differences: walking a row from c = 0, each cell with data has
                        Q = D + (Q of the previous cell WITH DATA in that row, 0 for the first),
                        i.e. Q = cumulative sum of D along the row, skipping no-data cells; the
                        height is base + Q * quantum (absolute metres)
    uint8[tile * tile]  same order: 0 no data, 1 measured (median of ground points), 2 filled
                        (a small hole, inverse distance), 3 bridge deck (class 17 points
                        carrying the lap), 4 under an overhead bridge (filled across it)

(float32 would be 4 bytes a cell, about 70 MB for the road; the differences of 1 mm steps
compress to about 1 byte a cell.) ``Grid.load(json)`` reads it, ``Grid.tile_arrays(ti, tj)``
gives one tile as float32 / uint8 arrays, ``Grid.height(x, z)`` is a bilinear sample (corners
without data drop out; NaN when less than half the weight is left), ``Grid.y(x, z)`` the same
relative to the finish line. JSON ``stats`` holds the point density and cell counts, ``bridges``
the class 17 stretches found along the lap (s range, kind "deck" / "over").

How the heights are made: ground points (class 2, and 9 water at its level) of every tile,
moved to the track frame; per cell the median; a robust local plane (least squares over
PLANE_HALF cells around, cells further than OUTLIER from it dropped and the plane fitted
again); points further than OUTLIER from their cell's plane are rejected and the median taken
again; a cell that loses most of its points to that and is itself off the plane is dropped.
Holes no wider than SMALL_HOLE are filled by inverse distance; bigger holes stay NaN (the
build then falls back to RGE ALTI there). Bridges: class 17 (bridge) points near the
centreline are grouped along the lap; a deck within DECK_TOL of the line joining the ground
heights before and after it carries the lap and replaces the ground under it (flag 3), a deck
well above it passes over the track and the ground under it is filled across (flag 4).
"""
import json
import math
import os
import sys
import time
import lzma

import numpy as np

from . import geom

FORMAT = "fun-racer lidar grid 1"
ATTRIBUTION = "LiDAR HD (IGN, Licence Ouverte 2.0)"
GROUND = (2, 9)
BRIDGE = 17
NODATA = -32768

ROAD = {"name": "lidar_road", "cell": 0.25, "tile": 256, "reach": 40.0, "quantum": 0.001,
        "small_hole": 1.5}
TERRAIN = {"name": "lidar_terrain", "cell": 1.0, "tile": 256, "reach": 600.0, "quantum": 0.01,
           "small_hole": 3.0}
PLANE_HALF = 3          # cells: the local plane is fitted over (2 * 3 + 1)^2 cells (1.75 m road)
OUTLIER = 0.15          # m from the local plane: point / cell rejected
TERRAIN_OUTLIER = 0.5   # m: the same test on the 1 m terrain grid (natural slopes, ditches)
IDW_POWER = 2.0
RIM = 3                 # cells: the data around a hole that the inverse distance fill uses
DECK_TOL = 1.2          # m: a deck this close to the approaches' line carries the lap
DECK_LAT = 8.0          # m from the centreline: class 17 points nearer than this are a bridge of the lap
OVER_CLEAR = 3.0        # m: a deck at least this far above the road passes over it
SHADOW_FILL = 12.0      # m: largest hole filled across under an overhead bridge
FLAG_NONE, FLAG_MEASURED, FLAG_FILLED, FLAG_DECK, FLAG_UNDER = 0, 1, 2, 3, 4


# ---------- frame ----------

class Frame:
    """Lambert-93 <-> track frame (x east, z -north, plan scale k) of one track."""

    def __init__(self, origin_latlon, plan_scale):
        self.lat0, self.lon0 = float(origin_latlon[0]), float(origin_latlon[1])
        self.k = float(plan_scale)
        self.proj = geom.Projection(self.lat0, self.lon0, self.k)
        self._fwd = self._inv = None

    def l93_to_xz(self, e, n):
        from pyproj import Transformer
        if self._fwd is None:
            self._fwd = Transformer.from_crs("EPSG:2154", "EPSG:4326", always_xy=True)
        lon, lat = self._fwd.transform(np.asarray(e, float), np.asarray(n, float))
        return self.proj.to_xz(np.asarray(lat), np.asarray(lon))

    def xz_to_l93(self, x, z):
        from pyproj import Transformer
        if self._inv is None:
            self._inv = Transformer.from_crs("EPSG:4326", "EPSG:2154", always_xy=True)
        lat, lon = self.proj.to_latlon(np.asarray(x, float), np.asarray(z, float))
        return self._inv.transform(lon, lat)

    def tile_fit(self, x0, y0, x1, y1, n=17):
        """A cubic polynomial (e, n) -> (x, z) for one Lambert-93 box, to well under 1 mm:
        pyproj on tens of millions of points per tile would dominate the run time."""
        cx, cy, h = 0.5 * (x0 + x1), 0.5 * (y0 + y1), 0.5 * max(x1 - x0, y1 - y0)
        g = np.linspace(-1.0, 1.0, n)
        u, v = [a.ravel() for a in np.meshgrid(g, g)]
        x, z = self.l93_to_xz(cx + u * h, cy + v * h)
        A = _poly_terms(u, v)
        cxz = np.linalg.lstsq(A, np.column_stack([x, z]), rcond=None)[0]
        err = np.abs(A @ cxz - np.column_stack([x, z])).max()
        if err > 1e-3:
            raise RuntimeError(f"Lambert-93 -> track frame fit is off by {err:.4f} m")

        def apply(e, nn):
            uu = (np.asarray(e, float) - cx) / h
            vv = (np.asarray(nn, float) - cy) / h
            x = np.full(uu.shape, cxz[0, 0])
            z = np.full(uu.shape, cxz[0, 1])
            for k, t in enumerate(_poly_iter(uu, vv), start=1):
                x += cxz[k, 0] * t
                z += cxz[k, 1] * t
            return x, z
        return apply


def _poly_iter(u, v):
    """The non-constant terms of the cubic, one array at a time (no big matrix)."""
    yield u
    yield v
    uu = u * u
    yield uu
    yield u * v
    vv = v * v
    yield vv
    yield uu * u
    yield uu * v
    yield u * vv
    yield vv * v


def _poly_terms(u, v):
    return np.column_stack([np.ones_like(u)] + list(_poly_iter(u, v)))


# ---------- centreline helpers ----------

def densify_loop(xz, step=0.5):
    """Closed polyline ``xz`` (n, 2) -> (points every ~step m, their s along the loop)."""
    xz = np.asarray(xz, float)
    nxt = np.roll(xz, -1, axis=0)
    seg = np.hypot(*(nxt - xz).T)
    k = np.maximum(1, np.ceil(seg / step).astype(int))
    pts, ss = [], []
    s0 = np.concatenate([[0.0], np.cumsum(seg)[:-1]])
    for a, b, d, kk, s in zip(xz, nxt, seg, k, s0):
        t = np.arange(kk)[:, None] / kk
        pts.append(a + (b - a) * t)
        ss.append(s + d * t[:, 0])
    return np.vstack(pts), np.concatenate(ss)


class DistanceField:
    """Distance to the centreline on a 1 m raster over the corridor's bounding box."""

    def __init__(self, xz, reach, res=1.0):
        from scipy import ndimage
        pts, _ = densify_loop(xz, 0.5 * res)
        pad = reach + 4.0 * res
        self.x0 = math.floor((pts[:, 0].min() - pad) / res) * res
        self.z0 = math.floor((pts[:, 1].min() - pad) / res) * res
        self.nx = int(math.ceil((pts[:, 0].max() + pad - self.x0) / res)) + 1
        self.nz = int(math.ceil((pts[:, 1].max() + pad - self.z0) / res)) + 1
        self.res = res
        free = np.ones((self.nz, self.nx), bool)
        ci = np.round((pts[:, 0] - self.x0) / res).astype(int)
        cj = np.round((pts[:, 1] - self.z0) / res).astype(int)
        free[cj, ci] = False
        self.d = ndimage.distance_transform_edt(free).astype(np.float32) * res

    def __call__(self, x, z):
        """Distance (m, about +/- res / 2) of points to the centreline; inf off the raster."""
        i = np.round((np.asarray(x) - self.x0) / self.res).astype(np.int64)
        j = np.round((np.asarray(z) - self.z0) / self.res).astype(np.int64)
        ok = (i >= 0) & (i < self.nx) & (j >= 0) & (j < self.nz)
        out = np.full(i.shape, np.inf, np.float32)
        out[ok] = self.d[j[ok], i[ok]]
        return out

    def bilinear(self, x, z):
        u = (np.asarray(x) - self.x0) / self.res
        v = (np.asarray(z) - self.z0) / self.res
        i = np.clip(np.floor(u).astype(np.int64), 0, self.nx - 2)
        j = np.clip(np.floor(v).astype(np.int64), 0, self.nz - 2)
        tu, tv = np.clip(u - i, 0, 1), np.clip(v - j, 0, 1)
        d = self.d
        a = d[j, i] * (1 - tu) + d[j, i + 1] * tu
        b = d[j + 1, i] * (1 - tu) + d[j + 1, i + 1] * tu
        return a * (1 - tv) + b * tv


# ---------- robust per-cell statistics ----------

def group_median(idx, z):
    """(unique cell ids, median height, point count, order, starts) of points ``idx``, ``z``;
    ``order`` sorts the points by (cell, height), ``starts`` is where each cell begins in it."""
    order = np.lexsort((z, idx))
    si = idx[order]
    sz = z[order]
    u, start, cnt = np.unique(si, return_index=True, return_counts=True)
    med = 0.5 * (sz[start + (cnt - 1) // 2] + sz[start + cnt // 2])
    return u, med, cnt, order, start


def masked_median(sorted_z, start, cnt, keep):
    """Median per cell of the points with ``keep`` (both in the group_median order); NaN for
    cells that keep none, and the number kept."""
    kc = np.add.reduceat(keep.astype(np.int64), start) if len(start) else np.zeros(0, np.int64)
    # Kept points stay sorted inside each cell: push the dropped ones to the end with +inf.
    big = np.where(keep, sorted_z, np.inf)
    cell = np.repeat(np.arange(len(start)), cnt)
    order = np.lexsort((big, cell))
    bz = big[order]
    lo = start + np.maximum(kc - 1, 0) // 2
    hi = start + kc // 2
    hi = np.minimum(hi, start + cnt - 1)
    med = 0.5 * (bz[lo] + bz[hi])
    med = np.where(kc > 0, med, np.nan)
    return med, kc


def plane_fit(h, half=PLANE_HALF, tol=OUTLIER, iters=2, min_cells=6):
    """Robust local plane of the grid ``h`` (NaN = no data) at every cell: the least-squares
    plane over the (2 half + 1)^2 cells around (weighted by data), refitted without the cells
    further than ``tol`` from it. Returns the plane's value at each cell centre (NaN where
    fewer than ``min_cells`` support it)."""
    from scipy import ndimage
    r = np.arange(-half, half + 1, dtype=np.float64)
    KZ, KX = np.meshgrid(r, r, indexing="ij")
    K1 = np.ones_like(KX)
    kern = {"1": K1, "x": KX, "z": KZ, "xx": KX * KX, "xz": KX * KZ, "zz": KZ * KZ}
    valid = np.isfinite(h)
    w = valid.astype(np.float64)
    hv = np.where(valid, h, 0.0).astype(np.float64)
    p = np.full(h.shape, np.nan)
    for it in range(iters):
        # correlate: out[c] = sum_k K[k] * f[c + k]; offsets are relative to the fitted cell.
        S = {k: ndimage.correlate(w, K, mode="constant") for k, K in kern.items()}
        T = {k: ndimage.correlate(w * hv, kern[k], mode="constant") for k in ("1", "x", "z")}
        # Normal equations of h = a + b dx + c dz, solved for a (the value at the centre).
        a11, a12, a13 = S["1"], S["x"], S["z"]
        a22, a23, a33 = S["xx"], S["xz"], S["zz"]
        b1, b2, b3 = T["1"], T["x"], T["z"]
        det = (a11 * (a22 * a33 - a23 * a23) - a12 * (a12 * a33 - a23 * a13)
               + a13 * (a12 * a23 - a22 * a13))
        num = (b1 * (a22 * a33 - a23 * a23) - a12 * (b2 * a33 - a23 * b3)
               + a13 * (b2 * a23 - a22 * b3))
        ok = (S["1"] >= min_cells) & (np.abs(det) > 1e-9)
        p = np.where(ok, num / np.where(ok, det, 1.0), np.nan)
        # Too few or collinear cells: the plain mean.
        mean = np.where(S["1"] > 0, T["1"] / np.maximum(S["1"], 1e-9), np.nan)
        p = np.where(ok, p, np.where(S["1"] >= min_cells, mean, np.nan))
        if it + 1 < iters:
            bad = valid & np.isfinite(p) & (np.abs(h - p) > tol)
            w = (valid & ~bad).astype(np.float64)
    return p


def fill_small_holes(h, flags, cell, small, shadow=None, shadow_reach=SHADOW_FILL):
    """Fills, in place, every hole (connected no-data cells) whose cells are all within
    ``small`` metres of data, by inverse-distance weighting of the data within 2 * small;
    holes under ``shadow`` (an overhead bridge) are filled up to ``shadow_reach``. Returns the
    number of cells filled."""
    from scipy import ndimage
    hole = ~np.isfinite(h)
    if not hole.any() or hole.all():
        return 0
    dist = ndimage.distance_transform_edt(hole) * cell
    lab, n = ndimage.label(hole)
    if n == 0:
        return 0
    # Holes touching the array's border are unknown in size: not filled.
    border = np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))
    mx = ndimage.maximum(dist, lab, index=np.arange(1, n + 1))
    lim = np.full(n + 1, small)
    if shadow is not None:
        under = ndimage.maximum(shadow.astype(np.int8), lab, index=np.arange(1, n + 1))
        lim[1:][under > 0] = shadow_reach
    fill = np.zeros(n + 1, bool)
    fill[1:] = np.asarray(mx) <= lim[1:]
    fill[border] = False
    fill[0] = False
    target = fill[lab]
    if not target.any():
        return 0
    # Inverse distance from the data on the holes' rim (within RIM cells of a hole, as GDAL's
    # fillnodata does): two FFT convolutions per hole class (small / under a bridge).
    from scipy.signal import fftconvolve
    data = np.isfinite(h)
    filled = 0
    for under in (False, True):
        sel = target & (lim[lab] > small) if under else target & (lim[lab] <= small)
        if not sel.any():
            continue
        # out to twice the widest hole of the class (its largest distance to data)
        widest = float(dist[sel].max())
        r = max(2, int(math.ceil(2.0 * widest / cell)) + 1)
        rim = data & ndimage.binary_dilation(sel, structure=np.ones((3, 3)), iterations=RIM)
        k = np.arange(-r, r + 1, dtype=np.float64)
        d2 = k[:, None] ** 2 + k[None, :] ** 2
        kern = np.where((d2 > 0) & (d2 <= r * r), 1.0 / np.maximum(d2, 1.0) ** (IDW_POWER / 2.0), 0.0)
        num = fftconvolve(np.where(rim, h, 0.0).astype(np.float64), kern, mode="same")
        den = fftconvolve(rim.astype(np.float64), kern, mode="same")
        ok = sel & (den > 1e-9)
        h[ok] = (num[ok] / den[ok]).astype(h.dtype)
        if flags is not None:
            flags[ok] = FLAG_UNDER if under else FLAG_FILLED
        filled += int(ok.sum())
    return filled


# ---------- tiled grid storage ----------

def _encode(h, flags, base, quantum):
    """One tile -> xz stream (see the module docstring)."""
    q = np.full(h.shape, NODATA, np.int32)
    ok = np.isfinite(h)
    q[ok] = np.round((h[ok] - base) / quantum).astype(np.int32)
    if ok.any() and np.abs(q[ok]).max() > 16383:
        raise ValueError("tile heights too far from the base for the int16 differences")
    # Difference to the previous cell WITH DATA of the same row (the first one: its value).
    col = np.broadcast_to(np.arange(h.shape[1]), h.shape)
    last = np.maximum.accumulate(np.where(ok, col, -1), axis=1)
    prev = np.concatenate([np.full((h.shape[0], 1), -1), last[:, :-1]], axis=1)
    prev_val = np.where(prev >= 0, np.take_along_axis(q, np.maximum(prev, 0), axis=1), 0)
    out = np.where(ok, q - prev_val, NODATA)
    payload = out.astype("<i2").tobytes() + flags.astype(np.uint8).tobytes()
    return lzma.compress(payload, format=lzma.FORMAT_XZ, preset=9)


def _decode(blob, tile, base, quantum):
    """xz stream -> (heights float32 absolute m with NaN, flags uint8) of one tile."""
    raw = lzma.decompress(blob)
    n = tile * tile
    q = np.frombuffer(raw[:2 * n], "<i2").reshape(tile, tile).astype(np.int32)
    flags = np.frombuffer(raw[2 * n:3 * n], np.uint8).reshape(tile, tile).copy()
    m = q != NODATA
    run = np.cumsum(np.where(m, q, 0), axis=1)
    h = np.where(m, base + run * quantum, np.nan).astype(np.float32)
    return h, flags


def _tile_base(h):
    v = h[np.isfinite(h)]
    if not len(v):
        return None
    lo, hi = float(v.min()), float(v.max())
    return round(0.5 * (lo + hi), 2), hi - lo


class Grid:
    """A lidar grid read from its JSON header (see the module docstring for the format)."""

    def __init__(self, meta, blob):
        self.meta = meta
        self.cell = float(meta["cell"])
        self.tile = int(meta["tile"])
        self.quantum = float(meta["quantum"])
        self.origin = float(meta["origin_elevation_m"])
        self._blob = blob
        self._index = {(t[0], t[1]): t for t in meta["tiles"]}
        self._cache = {}

    @classmethod
    def load(cls, json_path):
        with open(json_path, encoding="utf-8") as f:
            meta = json.load(f)
        if meta.get("format") != FORMAT:
            raise ValueError(f"{json_path}: not a {FORMAT} file")
        with open(os.path.join(os.path.dirname(json_path), meta["file"]), "rb") as f:
            blob = f.read()
        return cls(meta, blob)

    def tile_arrays(self, ti, tj):
        """(heights float32 [tile, tile] absolute m, flags uint8) of one tile, or None."""
        key = (int(ti), int(tj))
        if key not in self._cache:
            t = self._index.get(key)
            self._cache[key] = None if t is None else _decode(
                self._blob[t[2]:t[2] + t[3]], self.tile, t[4], self.quantum)
        return self._cache[key]

    def tiles(self):
        return sorted(self._index)

    def cells(self, ix, iz):
        """Heights (absolute m, NaN = no data) of the cells (ix, iz) (integer arrays)."""
        ix = np.asarray(ix, np.int64)
        iz = np.asarray(iz, np.int64)
        out = np.full(ix.shape, np.nan, np.float32)
        ti, tj = ix // self.tile, iz // self.tile
        keys = ti * 1_000_003 + tj
        for key in np.unique(keys):
            m = keys == key
            a = self.tile_arrays(ti[m][0], tj[m][0])
            if a is None:
                continue
            out[m] = a[0][iz[m] - tj[m][0] * self.tile, ix[m] - ti[m][0] * self.tile]
        return out

    def flags(self, ix, iz):
        ix = np.asarray(ix, np.int64)
        iz = np.asarray(iz, np.int64)
        out = np.zeros(ix.shape, np.uint8)
        ti, tj = ix // self.tile, iz // self.tile
        keys = ti * 1_000_003 + tj
        for key in np.unique(keys):
            m = keys == key
            a = self.tile_arrays(ti[m][0], tj[m][0])
            if a is not None:
                out[m] = a[1][iz[m] - tj[m][0] * self.tile, ix[m] - ti[m][0] * self.tile]
        return out

    def height(self, x, z, min_weight=0.5):
        """Bilinear absolute height at (x, z) (arrays, track frame). Corners without data drop
        out and the others are re-weighted; NaN when they carry less than ``min_weight``."""
        x = np.asarray(x, np.float64)
        z = np.asarray(z, np.float64)
        u = x / self.cell - 0.5
        v = z / self.cell - 0.5
        i = np.floor(u).astype(np.int64)
        j = np.floor(v).astype(np.int64)
        tu, tv = u - i, v - j
        acc = np.zeros(x.shape)
        wsum = np.zeros(x.shape)
        for di, dj, w in ((0, 0, (1 - tu) * (1 - tv)), (1, 0, tu * (1 - tv)),
                          (0, 1, (1 - tu) * tv), (1, 1, tu * tv)):
            h = self.cells(i + di, j + dj).astype(np.float64)
            ok = np.isfinite(h)
            acc += np.where(ok, h * w, 0.0)
            wsum += np.where(ok, w, 0.0)
        return np.where(wsum >= min_weight, acc / np.maximum(wsum, 1e-12), np.nan)

    def y(self, x, z):
        """Height relative to the finish line (``origin_elevation_m``): the track's y."""
        return self.height(x, z) - self.origin

    def footprint(self, x, z, half, step, stat="median"):
        """``stat`` (median / mean, NaN ignored) of bilinear samples on a square pattern of
        +/- ``half`` m every ``step`` m around each point: a centreline sample that does not
        depend on whether the point falls on a kerb or a drain."""
        x = np.asarray(x, np.float64)
        z = np.asarray(z, np.float64)
        offs = np.arange(-half, half + 1e-9, step)
        ox, oz = [a.ravel() for a in np.meshgrid(offs, offs)]
        hs = self.height(x[:, None] + ox[None], z[:, None] + oz[None])
        with np.errstate(all="ignore"):
            import warnings
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", RuntimeWarning)
                r = np.nanmedian(hs, axis=1) if stat == "median" else np.nanmean(hs, axis=1)
            # Too few samples: no answer.
            r[np.isfinite(hs).sum(axis=1) < max(1, hs.shape[1] // 3)] = np.nan
        return r


def write_grid(out_dir, spec, tiles, meta):
    """Writes ``<name>.bin`` + ``<name>.json`` from {(ti, tj): (heights, flags)}."""
    name = spec["name"]
    index, chunks, off = [], [], 0
    for (ti, tj) in sorted(tiles):
        h, fl = tiles[(ti, tj)]
        b = _tile_base(h)
        if b is None:
            continue
        base, span = b
        if span / spec["quantum"] > 32000:
            raise RuntimeError(f"tile {ti},{tj} spans {span:.1f} m: too much for int16")
        blob = _encode(h, fl, base, spec["quantum"])
        index.append([int(ti), int(tj), off, len(blob), base])
        chunks.append(blob)
        off += len(blob)
    with open(os.path.join(out_dir, name + ".bin"), "wb") as f:
        for c in chunks:
            f.write(c)
    head = {"format": FORMAT, "file": name + ".bin", "cell": spec["cell"], "tile": spec["tile"],
            "quantum": spec["quantum"], "reach_m": spec["reach"]}
    head.update(meta)
    head["tiles"] = index
    with open(os.path.join(out_dir, name + ".json"), "w", encoding="utf-8") as f:
        json.dump(head, f, indent=1)
        f.write("\n")
    return os.path.getsize(os.path.join(out_dir, name + ".bin"))


def rebase(json_path, origin_elevation_m):
    """Changes the finish-line height the grid's ``y`` is relative to (the data, absolute
    heights, is untouched): after a rebuild moved track.json's origin_elevation_m."""
    with open(json_path, encoding="utf-8") as f:
        meta = json.load(f)
    meta["origin_elevation_m"] = round(float(origin_elevation_m), 3)
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=1)
        f.write("\n")


# ---------- building the grids from the tiles ----------

class _Lattice:
    """Cells of size ``cell`` in tiles of ``tile`` cells over a bounding box (tile aligned)."""

    def __init__(self, cell, tile, x0, z0, x1, z1):
        tm = cell * tile
        self.cell, self.tile = cell, tile
        self.ti0 = int(math.floor(x0 / tm))
        self.tj0 = int(math.floor(z0 / tm))
        self.nti = int(math.floor(x1 / tm)) - self.ti0 + 1
        self.ntj = int(math.floor(z1 / tm)) - self.tj0 + 1
        self.ix0, self.iz0 = self.ti0 * tile, self.tj0 * tile
        self.nx, self.nz = self.nti * tile, self.ntj * tile

    def index(self, x, z):
        """Flat cell index (int64) of points (x, z), -1 off the box."""
        ix = np.floor(x / self.cell).astype(np.int64) - self.ix0
        iz = np.floor(z / self.cell).astype(np.int64) - self.iz0
        ok = (ix >= 0) & (ix < self.nx) & (iz >= 0) & (iz < self.nz)
        return np.where(ok, iz * self.nx + ix, -1)

    def centres(self, flat):
        iz, ix = np.divmod(flat, self.nx)
        return ((ix + self.ix0 + 0.5) * self.cell, (iz + self.iz0 + 0.5) * self.cell)


def _read_tile_points(path, fit, keep, chunk=4_000_000):
    """(x, z, height, classification) of the points of ``keep`` classes of one LAS / LAZ /
    COPC file, in the track frame, streamed in chunks."""
    import laspy
    xs, zs, hs, cs = [], [], [], []
    with laspy.open(path) as f:
        sx, sy, sz = f.header.scales
        ox, oy, oz = f.header.offsets
        for ch in f.chunk_iterator(chunk):
            c = np.asarray(ch.classification)
            m = np.isin(c, keep)
            if not m.any():
                continue
            e = np.asarray(ch.X)[m] * sx + ox
            n = np.asarray(ch.Y)[m] * sy + oy
            h = (np.asarray(ch.Z)[m] * sz + oz).astype(np.float32)
            x, z = fit(e, n)
            xs.append(x)
            zs.append(z)
            hs.append(h)
            cs.append(c[m].astype(np.uint8))
    if not xs:
        e = np.zeros(0)
        return e, e, e.astype(np.float32), e.astype(np.uint8)
    return np.concatenate(xs), np.concatenate(zs), np.concatenate(hs), np.concatenate(cs)


def _tile_bounds(path):
    import laspy
    with laspy.open(path) as f:
        h = f.header
        return float(h.mins[0]), float(h.mins[1]), float(h.maxs[0]), float(h.maxs[1])


def build(track, plan_scale, tile_paths, out_dir, road=ROAD, terrain=TERRAIN, log=print):
    """Builds both grids for ``track`` (track.json dict) from the LAS / LAZ files
    ``tile_paths`` and writes them to ``out_dir``. Returns a report dict."""
    t_start = time.time()
    frame = Frame(track["origin_latlon"], plan_scale)
    xz = np.array([[p["p"][0], p["p"][2]] for p in track["points"]], float)
    base = float(track["origin_elevation_m"])
    reach_r, reach_t = road["reach"], terrain["reach"]
    dfield = DistanceField(xz, max(reach_r, reach_t), 1.0)
    lo = xz.min(axis=0)
    hi = xz.max(axis=0)
    lat_r = _Lattice(road["cell"], road["tile"], lo[0] - reach_r - 2, lo[1] - reach_r - 2,
                     hi[0] + reach_r + 2, hi[1] + reach_r + 2)
    lat_t = _Lattice(terrain["cell"], terrain["tile"], lo[0] - reach_t - 2, lo[1] - reach_t - 2,
                     hi[0] + reach_t + 2, hi[1] + reach_t + 2)
    t_sum = np.zeros(lat_t.nx * lat_t.nz, np.float64)
    t_cnt = np.zeros(lat_t.nx * lat_t.nz, np.int32)
    r_idx, r_h, b_idx, b_h = [], [], [], []
    n_ground = n_bridge = 0
    for k, path in enumerate(tile_paths, 1):
        t0 = time.time()
        fit = frame.tile_fit(*_tile_bounds(path))
        x, z, h, c = _read_tile_points(path, fit, GROUND + (BRIDGE,))
        d = dfield(x, z)
        g = c != BRIDGE
        # road corridor: every ground point, kept for the robust pass
        m = g & (d <= reach_r + 1.5)
        idx = lat_r.index(x[m], z[m])
        ok = idx >= 0
        r_idx.append(idx[ok])
        r_h.append(h[m][ok])
        mb = (~g) & (d <= reach_r + 1.5)
        idx = lat_r.index(x[mb], z[mb])
        ok = idx >= 0
        b_idx.append(idx[ok])
        b_h.append(h[mb][ok])
        # terrain corridor: per-tile median per 1 m cell, merged by point count
        mt = g & (d <= reach_t + 1.5)
        idx = lat_t.index(x[mt], z[mt])
        ok = idx >= 0
        if ok.any():
            u, med, cnt, _, _ = group_median(idx[ok], h[mt][ok])
            t_sum[u] += med.astype(np.float64) * cnt
            t_cnt[u] += cnt
        n_ground += int(g.sum())
        n_bridge += int((~g).sum())
        log(f"  lidar {k}/{len(tile_paths)} {os.path.basename(path)}: {int(g.sum()):,} ground, "
            f"{int((~g).sum()):,} bridge points ({time.time() - t0:.0f} s)")
        del x, z, h, c, d, g
    r_idx = np.concatenate(r_idx) if r_idx else np.zeros(0, np.int64)
    r_h = np.concatenate(r_h) if r_h else np.zeros(0, np.float32)
    b_idx = np.concatenate(b_idx) if b_idx else np.zeros(0, np.int64)
    b_h = np.concatenate(b_h) if b_h else np.zeros(0, np.float32)

    # ---- road grid --------------------------------------------------------------------
    rep = {"road": {}, "terrain": {}}
    road_tiles, road_rep, bridges = _road_grid(lat_r, r_idx, r_h, b_idx, b_h, xz, dfield, road,
                                               log)
    del r_idx, r_h
    rep["road"] = road_rep
    rep["bridges"] = bridges

    # ---- terrain grid -----------------------------------------------------------------
    terrain_tiles, ter_rep = _terrain_grid(lat_t, t_sum, t_cnt, dfield, terrain, log)
    del t_sum, t_cnt
    rep["terrain"] = ter_rep

    common = {
        "frame": track.get("frame", "x = east, y = up, z = -north, metres from the finish line"),
        "origin_latlon": [frame.lat0, frame.lon0],
        "plan_scale": frame.k,
        "origin_elevation_m": round(base, 3),
        "crs": {"source": "EPSG:2154 (RGF93 / Lambert-93), heights IGN69 (NGF)",
                "to_track": "pyproj EPSG:2154 -> EPSG:4326, then x = (lon - lon0) * 111320 * "
                            "cos(lat0) * plan_scale, z = -(lat - lat0) * 111320 * plan_scale "
                            "(lib.geom.Projection)"},
        "attribution": ATTRIBUTION,
        "classes": {"ground": list(GROUND), "bridge": BRIDGE},
        "flags": {"0": "no data", "1": "measured", "2": "filled (small hole)",
                  "3": "bridge deck carrying the lap", "4": "under an overhead bridge (filled)"},
    }
    sizes = {}
    meta = dict(common)
    meta["stats"] = road_rep
    meta["bridges"] = bridges
    sizes["road"] = write_grid(out_dir, road, road_tiles, meta)
    meta = dict(common)
    meta["stats"] = ter_rep
    sizes["terrain"] = write_grid(out_dir, terrain, terrain_tiles, meta)
    rep["bytes"] = sizes
    rep["points"] = {"ground": n_ground, "bridge": n_bridge}
    rep["seconds"] = round(time.time() - t_start, 1)
    log(f"lidar: road grid {sizes['road'] / 1e6:.1f} MB, terrain grid {sizes['terrain'] / 1e6:.1f} MB "
        f"({rep['seconds']:.0f} s)")
    return rep


def _tiles_of(lat, flat_cells):
    """Tile keys (ti, tj) touched by the flat cell indexes."""
    iz, ix = np.divmod(np.unique(flat_cells), lat.nx)
    keys = np.unique((iz // lat.tile) * lat.nti + ix // lat.tile)
    return [(int(k % lat.nti), int(k // lat.nti)) for k in keys]


def _scatter_tiles(lat, cells, values, dtype=np.float32, fill=np.nan):
    """{(lti, ltj): dense tile array} (lattice-relative tile keys) from flat cells / values."""
    iz, ix = np.divmod(cells, lat.nx)
    lti, ltj = ix // lat.tile, iz // lat.tile
    key = ltj * lat.nti + lti
    order = np.argsort(key, kind="stable")
    key, iz, ix, values = key[order], iz[order], ix[order], values[order]
    u, start = np.unique(key, return_index=True)
    out = {}
    ends = list(start[1:]) + [len(key)]
    for k, a, b in zip(u, start, ends):
        t = np.full((lat.tile, lat.tile), fill, dtype)
        ti, tj = int(k % lat.nti), int(k // lat.nti)
        t[iz[a:b] - tj * lat.tile, ix[a:b] - ti * lat.tile] = values[a:b]
        out[(ti, tj)] = t
    return out


def _padded(tiles, key, pad, tile, fill=np.nan, dtype=np.float32):
    """Tile ``key`` with ``pad`` cells of its neighbours around it."""
    ti, tj = key
    out = np.full((tile + 2 * pad, tile + 2 * pad), fill, dtype)
    for dj in (-1, 0, 1):
        for di in (-1, 0, 1):
            t = tiles.get((ti + di, tj + dj))
            if t is None:
                continue
            # destination window in out, source window in t
            zs = slice(max(0, pad + dj * tile), min(out.shape[0], pad + (dj + 1) * tile))
            xs = slice(max(0, pad + di * tile), min(out.shape[1], pad + (di + 1) * tile))
            sz0 = zs.start - (pad + dj * tile)
            sx0 = xs.start - (pad + di * tile)
            out[zs, xs] = t[sz0:sz0 + zs.stop - zs.start, sx0:sx0 + xs.stop - xs.start]
    return out


def _road_grid(lat, idx, h, b_idx, b_h, xz, dfield, spec, log):
    tile, cell = lat.tile, lat.cell
    t0 = time.time()
    u, m1, cnt, order, start = group_median(idx, h)
    sh = h[order]
    log(f"  road: {len(idx):,} ground points in {len(u):,} cells "
        f"({len(idx) / max(1, len(u)) / cell ** 2:.1f} points / m^2)")
    del idx, h, order
    m1_tiles = _scatter_tiles(lat, u, m1.astype(np.float32))
    pad = PLANE_HALF + 1
    # robust local plane of the first medians, tile by tile
    plane_tiles = {}
    for key in m1_tiles:
        P = _padded(m1_tiles, key, pad, tile)
        plane_tiles[key] = plane_fit(P)[pad:-pad, pad:-pad].astype(np.float32)
    iz, ix = np.divmod(u, lat.nx)
    lti, ltj = ix // tile, iz // tile
    plane = np.full(len(u), np.nan, np.float32)
    keys = ltj * lat.nti + lti
    for k in np.unique(keys):
        m = keys == k
        P = plane_tiles[(int(k % lat.nti), int(k // lat.nti))]
        plane[m] = P[iz[m] - (k // lat.nti) * tile, ix[m] - (k % lat.nti) * tile]
    # point-level rejection against the cell's plane
    res = sh - np.repeat(plane, cnt)
    keep = ~(np.abs(res) > OUTLIER)          # NaN plane: keep everything
    m2, kc = masked_median(sh, start, cnt, keep)
    frac = kc / cnt
    off_plane = np.isfinite(plane) & (np.abs(m1 - plane) > OUTLIER)
    final = np.where(frac >= 0.5, m2, np.where(off_plane, np.nan, m1)).astype(np.float32)
    n_rej_pts = int((~keep).sum())
    n_rej_cells = int(np.isnan(final).sum())
    del sh, res, keep
    fin_tiles = _scatter_tiles(lat, u, final)
    flag_tiles = {k: np.where(np.isfinite(v), FLAG_MEASURED, FLAG_NONE).astype(np.uint8)
                  for k, v in fin_tiles.items()}
    cnt_tiles = _scatter_tiles(lat, u, cnt.astype(np.float32), fill=0.0)
    log(f"  road: {n_rej_pts:,} points and {n_rej_cells:,} cells off the local plane "
        f"(> {OUTLIER} m) rejected ({time.time() - t0:.0f} s)")

    # ---- bridges ----
    bridges, shadow_tiles = _bridges(lat, fin_tiles, flag_tiles, b_idx, b_h, xz, log)

    # ---- small holes, corridor crop ----
    pad = int(math.ceil(2.5 * SHADOW_FILL / cell))
    pad = min(pad, tile)
    filled = 0
    out = {}
    for key in fin_tiles:
        P = _padded(fin_tiles, key, pad, tile)
        F = _padded(flag_tiles, key, pad, tile, fill=0, dtype=np.uint8)
        S = _padded(shadow_tiles, key, pad, tile, fill=0, dtype=np.uint8) if shadow_tiles else None
        filled += fill_small_holes(P, F, cell, spec["small_hole"], shadow=S)
        hh = P[pad:-pad, pad:-pad].copy()
        ff = F[pad:-pad, pad:-pad].copy()
        out[key] = (hh, ff)
    # The fill of a hole crossing tile borders is computed in each tile from the same data:
    # identical values. Count only the cells of the tile itself.
    filled = sum(int((v[1] == FLAG_FILLED).sum() + (v[1] == FLAG_UNDER).sum()) for v in out.values())
    final_tiles = {}
    n_meas = n_fill = n_nan = n_deck = 0
    for (ti, tj), (hh, ff) in out.items():
        cx = (np.arange(tile) + lat.ix0 + ti * tile + 0.5) * cell
        cz = (np.arange(tile) + lat.iz0 + tj * tile + 0.5) * cell
        X, Z = np.meshgrid(cx, cz)
        inside = dfield.bilinear(X, Z) <= spec["reach"]
        hh[~inside] = np.nan
        ff[~inside] = FLAG_NONE
        if not inside.any() or not np.isfinite(hh).any():
            continue
        n_meas += int((ff == FLAG_MEASURED).sum())
        n_fill += int(((ff == FLAG_FILLED) | (ff == FLAG_UNDER)).sum())
        n_deck += int((ff == FLAG_DECK).sum())
        n_nan += int((inside & ~np.isfinite(hh)).sum())
        gti, gtj = ti + lat.ti0, tj + lat.tj0
        final_tiles[(gti, gtj)] = (hh, ff)
    cnt_all = np.concatenate([v[np.isfinite(fin_tiles[k]) & (v > 0)] for k, v in cnt_tiles.items()])
    rep = {"cells_in_corridor": n_meas + n_fill + n_deck + n_nan, "measured": n_meas,
           "filled": n_fill, "deck": n_deck, "no_data": n_nan,
           "points_per_m2": {"median": round(float(np.median(cnt_all)) / cell ** 2, 1),
                             "p10": round(float(np.percentile(cnt_all, 10)) / cell ** 2, 1),
                             "p90": round(float(np.percentile(cnt_all, 90)) / cell ** 2, 1)},
           "rejected_points": n_rej_pts, "rejected_cells": n_rej_cells}
    log(f"  road grid: {n_meas:,} measured, {n_fill:,} filled, {n_deck:,} deck, {n_nan:,} no data "
        f"cells; ground density median {rep['points_per_m2']['median']} pts/m^2")
    return final_tiles, rep, bridges


def _bridges(lat, fin_tiles, flag_tiles, b_idx, b_h, xz, log):
    """Class 17 points along the lap: decks carrying it replace the ground (flag 3); decks
    over it mark the cells under them so the hole there is filled across (flag 4)."""
    from scipy.spatial import cKDTree
    tile, cell = lat.tile, lat.cell
    shadow = {}
    if len(b_idx) == 0:
        return [], shadow
    bu, bmed, bcnt, border, bstart = group_median(b_idx, b_h)
    # the low quartile per cell: the deck surface, not the parapets and lamp posts on it
    sb = b_h[border]
    q25 = sb[bstart + (bcnt - 1) // 4]
    bx, bz = lat.centres(bu)
    dense, s_of = densify_loop(xz, 0.5)
    tree = cKDTree(dense)
    dist, near = tree.query(np.column_stack([bx, bz]))
    s_cell = s_of[near]
    length = float(s_of[-1] + math.hypot(*(dense[0] - dense[-1])))
    close = dist <= DECK_LAT
    # shadow: every class-17 cell (overhead or not) marks itself and its neighbours
    for key, t in _scatter_tiles(lat, bu, np.ones(len(bu), np.uint8), np.uint8, 0).items():
        from scipy import ndimage
        shadow[key] = ndimage.binary_dilation(t > 0, iterations=4).astype(np.uint8)
    if not close.any():
        return [], shadow
    # stretches of the lap with deck cells close to the centreline
    ss = np.sort(s_cell[close])
    groups, a = [], ss[0]
    for p, q in zip(ss[:-1], ss[1:]):
        if q - p > 10.0:
            groups.append((a, p))
            a = q
    groups.append((a, ss[-1]))
    if len(groups) > 1 and groups[0][0] < 5.0 and groups[-1][1] > length - 5.0:
        groups[0] = (groups[-1][0] - length, groups[0][1])
        groups.pop()

    def ground_at(s_vals):
        """Median ground (measured cells) within 3 m of the centreline at stations s."""
        out = []
        for s in np.atleast_1d(s_vals):
            k = int(np.argmin(np.abs(((s_of - s) + 0.5 * length) % length - 0.5 * length)))
            px, pz = dense[k]
            r = int(math.ceil(3.0 / cell))
            ixc = int(math.floor(px / cell)) - lat.ix0
            izc = int(math.floor(pz / cell)) - lat.iz0
            vals = []
            for dz in range(-r, r + 1, 2):
                for dx in range(-r, r + 1, 2):
                    ix, iz = ixc + dx, izc + dz
                    t = fin_tiles.get((ix // tile, iz // tile))
                    if t is not None:
                        v = t[iz % tile, ix % tile]
                        if np.isfinite(v):
                            vals.append(v)
            out.append(float(np.median(vals)) if vals else np.nan)
        return np.array(out)

    bridges = []
    for (s0, s1) in groups:
        if s1 - s0 > 400.0:
            log(f"  bridge: class 17 along {s1 - s0:.0f} m of the lap at s = {s0:.0f}: ignored")
            continue
        sel = close & (((s_cell - s0) % length) <= (s1 - s0) % length + 1e-6)
        approach = np.array([s0 - 12.0, s0 - 8.0, s1 + 8.0, s1 + 12.0]) % length
        ga = ground_at(approach)
        g0 = np.nanmean(ga[:2])
        g1 = np.nanmean(ga[2:])
        span = max(1e-6, (s1 - s0) % length)
        t = (((s_cell[sel] - s0) % length) / span).clip(0, 1)
        line = g0 + (g1 - g0) * t
        deck = q25[sel]
        above = deck - line
        med_above = float(np.nanmedian(above)) if np.isfinite(above).any() else np.nan
        mid = ((s0 + s1) / 2) % length
        g_mid = ground_at([mid])[0]
        entry = {"s": [round(s0 % length, 1), round(s1 % length, 1)],
                 "deck_above_line_m": round(med_above, 2),
                 "ground_below_line_m": round(float(line.mean() - g_mid), 2) if np.isfinite(g_mid) else None,
                 "cells": int(sel.sum())}
        if np.isfinite(med_above) and abs(med_above) <= DECK_TOL:
            entry["kind"] = "deck"
            # the deck cells near the lap's height replace the ground (all cells of the
            # stretch, not only the ones close to the centreline: the whole deck surface)
            sel_all = (((s_cell - s0 + 2.0) % length) <= span + 4.0) & (dist <= 40.0)
            tt = (((s_cell[sel_all] - s0) % length) / span).clip(0, 1)
            ln = g0 + (g1 - g0) * tt
            on = np.abs(q25[sel_all] - ln) <= DECK_TOL + 0.05 * dist[sel_all]
            cells = bu[sel_all][on]
            vals = bmed[sel_all][on]
            iz, ix = np.divmod(cells, lat.nx)
            touched = set()
            for c_iz, c_ix, v in zip(iz, ix, vals):
                key = (int(c_ix // tile), int(c_iz // tile))
                if key not in fin_tiles:
                    fin_tiles[key] = np.full((tile, tile), np.nan, np.float32)
                    flag_tiles[key] = np.zeros((tile, tile), np.uint8)
                fin_tiles[key][c_iz % tile, c_ix % tile] = v
                flag_tiles[key][c_iz % tile, c_ix % tile] = FLAG_DECK
                touched.add(key)
            entry["deck_cells"] = int(on.sum())
            _settle_deck(fin_tiles, flag_tiles, touched, tile)
        elif np.isfinite(med_above) and med_above >= OVER_CLEAR:
            entry["kind"] = "over"
        else:
            entry["kind"] = "unclear"
        bridges.append(entry)
        log(f"  bridge at s = {entry['s'][0]:.0f}..{entry['s'][1]:.0f} m: {entry['kind']} "
            f"(deck {med_above:+.1f} m from the approaches' line, {entry['cells']} cells)")
    return bridges, shadow


def _settle_deck(fin_tiles, flag_tiles, keys, tile):
    """After deck cells replaced the ground: deck cells off the deck's own local plane (railings,
    noise) are dropped, and ground cells inside the deck's footprint (closed by 1 m) lying more
    than DECK_TOL below the deck around them (the valley floor seen through a gap) too; the hole
    fill then bridges both from the deck. Cells beside the deck keep their ground."""
    from scipy import ndimage
    pad = 8
    new = {}
    for key in keys:
        P = _padded(fin_tiles, key, pad, tile)
        F = _padded(flag_tiles, key, pad, tile, fill=0, dtype=np.uint8)
        deck = F == FLAG_DECK
        pl = plane_fit(np.where(deck, P, np.nan))
        bad = deck & np.isfinite(pl) & (np.abs(P - pl) > OUTLIER)
        deck &= ~bad
        k = np.ones((9, 9))
        num = ndimage.correlate(np.where(deck, P, 0.0).astype(np.float64), k, mode="constant")
        den = ndimage.correlate(deck.astype(np.float64), k, mode="constant")
        around = np.where(den > 0, num / np.maximum(den, 1e-9), np.nan)
        closed = ndimage.binary_closing(deck, structure=np.ones((3, 3)), iterations=4)
        with np.errstate(invalid="ignore"):
            low = closed & ~deck & np.isfinite(P) & (P < around - DECK_TOL)
        drop = (bad | low)[pad:-pad, pad:-pad]
        new[key] = drop
    for key, drop in new.items():
        fin_tiles[key][drop] = np.nan
        flag_tiles[key][drop] = FLAG_NONE


def _terrain_grid(lat, t_sum, t_cnt, dfield, spec, log):
    tile, cell = lat.tile, lat.cell
    t0 = time.time()
    with np.errstate(invalid="ignore", divide="ignore"):
        h = np.where(t_cnt > 0, t_sum / np.maximum(t_cnt, 1), np.nan).astype(np.float32)
    h = h.reshape(lat.nz, lat.nx)
    cnt = t_cnt.reshape(lat.nz, lat.nx)
    out = {}
    n_meas = n_fill = n_nan = n_rej = 0
    pad = int(math.ceil(2.5 * spec["small_hole"] / cell)) + PLANE_HALF + 1
    for tj in range(lat.ntj):
        for ti in range(lat.nti):
            z0, x0 = tj * tile, ti * tile
            zs = slice(max(0, z0 - pad), min(lat.nz, z0 + tile + pad))
            xs = slice(max(0, x0 - pad), min(lat.nx, x0 + tile + pad))
            P = h[zs, xs].copy()
            if not np.isfinite(P[z0 - zs.start:z0 - zs.start + tile,
                                 x0 - xs.start:x0 - xs.start + tile]).any():
                continue
            pl = plane_fit(P, half=PLANE_HALF, tol=TERRAIN_OUTLIER)
            bad = np.isfinite(P) & np.isfinite(pl) & (np.abs(P - pl) > TERRAIN_OUTLIER)
            P[bad] = np.nan
            F = np.where(np.isfinite(P), FLAG_MEASURED, FLAG_NONE).astype(np.uint8)
            fill_small_holes(P, F, cell, spec["small_hole"])
            a, b = z0 - zs.start, x0 - xs.start
            hh = P[a:a + tile, b:b + tile].copy()
            ff = F[a:a + tile, b:b + tile].copy()
            n_rej += int(bad[a:a + tile, b:b + tile].sum())
            cx = (np.arange(tile) + lat.ix0 + x0 + 0.5) * cell
            cz = (np.arange(tile) + lat.iz0 + z0 + 0.5) * cell
            X, Z = np.meshgrid(cx, cz)
            inside = dfield.bilinear(X, Z) <= spec["reach"]
            hh[~inside] = np.nan
            ff[~inside] = FLAG_NONE
            if not np.isfinite(hh).any():
                continue
            n_meas += int((ff == FLAG_MEASURED).sum())
            n_fill += int((ff == FLAG_FILLED).sum())
            n_nan += int((inside & ~np.isfinite(hh)).sum())
            out[(ti + lat.ti0, tj + lat.tj0)] = (hh, ff)
    c = cnt[cnt > 0]
    rep = {"cells_in_corridor": n_meas + n_fill + n_nan, "measured": n_meas, "filled": n_fill,
           "no_data": n_nan, "rejected_cells": n_rej,
           "points_per_m2": {"median": round(float(np.median(c)) / cell ** 2, 1) if len(c) else 0.0,
                             "p10": round(float(np.percentile(c, 10)) / cell ** 2, 1) if len(c) else 0.0,
                             "p90": round(float(np.percentile(c, 90)) / cell ** 2, 1) if len(c) else 0.0}}
    log(f"  terrain grid: {n_meas:,} measured, {n_fill:,} filled, {n_nan:,} no data cells "
        f"({time.time() - t0:.0f} s)")
    return out, rep


# ---------- build-time sampling (lib/net.py dataset "lidar_hd") ----------

_loaded = {}
DEM_HALF, DEM_STEP_M = 2.0, 1.0        # centreline: median of 5 x 5 samples 1 m apart
TERRAIN_HALF, TERRAIN_STEP_M = 4.0, 4.0  # terrain fetch (20 m grid): mean of 3 x 3, 4 m apart


def grids_for(track_dir):
    """(road Grid or None, terrain Grid or None) of a track folder, loaded once per run."""
    key = os.path.abspath(track_dir)
    if key not in _loaded:
        road = os.path.join(key, ROAD["name"] + ".json")
        ter = os.path.join(key, TERRAIN["name"] + ".json")
        _loaded[key] = (Grid.load(road) if os.path.exists(road) else None,
                        Grid.load(ter) if os.path.exists(ter) else None)
    return _loaded[key]


def sample_latlon(track_dir, latlon, prefix):
    """Absolute heights (NaN = not covered) at (lat, lon) pairs: the centreline ("dem" prefix)
    from the road grid (median of a small footprint) then the terrain grid; the terrain
    ("terrain" prefix) from the terrain grid (mean of a footprint the size of its 20 m cells)."""
    road, ter = grids_for(track_dir)
    if road is None and ter is None:
        raise FileNotFoundError(f"no {ROAD['name']}.json / {TERRAIN['name']}.json in {track_dir}")
    g = road or ter
    lat = np.array([p[0] for p in latlon], float)
    lon = np.array([p[1] for p in latlon], float)
    proj = geom.Projection(g.meta["origin_latlon"][0], g.meta["origin_latlon"][1], g.meta["plan_scale"])
    x, z = proj.to_xz(lat, lon)
    out = np.full(len(lat), np.nan)
    if prefix == "dem":
        if road is not None:
            out = road.footprint(x, z, DEM_HALF, DEM_STEP_M, "median")
        if ter is not None and np.isnan(out).any():
            m = np.isnan(out)
            out[m] = ter.footprint(x[m], z[m], DEM_HALF, DEM_STEP_M, "median")
    else:
        if ter is not None:
            out = ter.footprint(x, z, TERRAIN_HALF, TERRAIN_STEP_M, "mean")
    return out


# ---------- command line ----------

def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("track", help="track id (assets/tracks/<id>/track.json)")
    ap.add_argument("--manifest", help="ign_manifest.json listing the tiles (default: the "
                                       "track's raw/ign_manifest.json)")
    ap.add_argument("--cache", default="~/.cache/fun-racer/ign/lidar")
    ap.add_argument("--out", help="output folder (default: the track folder)")
    ap.add_argument("--within", type=float, default=None,
                    help="only tiles this close to the lap (default: the terrain reach)")
    a = ap.parse_args(argv)
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    tdir = os.path.join(root, "assets", "tracks", a.track)
    with open(os.path.join(tdir, "track.json"), encoding="utf-8") as f:
        track = json.load(f)
    with open(os.path.join(tdir, "build_info.json"), encoding="utf-8") as f:
        info = json.load(f)
    k = track["length"] / float(info["osm"]["length_m"])
    man = a.manifest or os.path.join(tdir, "raw", "ign_manifest.json")
    with open(man, encoding="utf-8") as f:
        manifest = json.load(f)
    within = TERRAIN["reach"] if a.within is None else a.within
    cache = os.path.expanduser(a.cache)
    paths = []
    for t in manifest["lidar"]:
        if t["dist_m"] > within:
            continue
        p = os.path.join(cache, t["id"])
        if not os.path.exists(p):
            print(f"missing tile {t['id']} (run lib.ign_data first)", file=sys.stderr)
            return 1
        paths.append(p)
    rep = build(track, k, paths, a.out or tdir)
    print(json.dumps({k2: v for k2, v in rep.items()}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
