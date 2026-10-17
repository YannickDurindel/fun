"""Road edges, kerbs and run-off traced from the IGN BD ORTHO 20 cm orthophotos.

The orthophoto blocks (``~/.cache/fun-racer/ign/ortho/ortho_<x0>_<y0>.tif``, 400 m squares in
Lambert-93, 2000 x 2000 RGB, fetched by ``lib.ign_data``) are resampled into road-aligned
strips: one row every ``ALONG`` metres of the lap, one column every ``ACROSS`` metres from the
left of the centreline to its right. Every pixel of a strip gets a class from colour and texture
rules (asphalt, white paint, red kerb paint, yellow sausage kerb, grass, gravel, trees / shadow)
and the two edges of the track are traced along the lap with a dynamic programme that trades
edge evidence against smoothness, so a junction, a tree crown or a shadow does not pull the
edge off: the edge is carried across it and the station is flagged with a low confidence.

Run from tools/track (writes ``assets/tracks/<id>/ortho_edges.json``):

    nice -n 10 ../../.venv/bin/python -m lib.ortho wec_le_mans_survey --qa <dir>

Frames and conventions:
- stations are the points of ``track.json`` (every ~2 m), ``s`` in metres along the lap;
- offsets are in track-frame metres, measured along the left normal of the centreline:
  ``left`` > 0 is the distance from the centreline to the left edge, ``right`` > 0 the distance
  to the right edge (driving direction), so the width is ``left + right``;
- the track frame is x east, z -north (``lib.geom.Projection``, ``plan_scale`` from
  terrain.json); a per-station Jacobian maps it to Lambert-93 (EPSG:2154) exactly enough
  (< 1 mm over 60 m).

Products only: nothing here edits a recipe. Licence of the source imagery: IGN, Licence
Ouverte 2.0; the JSON product carries that attribution.
"""
import json
import math
import os
import sys
from collections import OrderedDict

import numpy as np

ATTRIBUTION = "Edges, kerbs and run-off traced from BD ORTHO 20 cm (IGN, Licence Ouverte 2.0)"
CACHE = "~/.cache/fun-racer/ign/ortho"
BLOCK_M = 400.0
BLOCK_PX = 2000
PIX = BLOCK_M / BLOCK_PX          # 0.20 m
ALONG = 0.05                      # strip row spacing, m
ACROSS = 0.05                     # strip column spacing, m
HALF = 22.0                       # strip half width for edges and kerbs, m
RUNOFF_HALF = 70.0                # half width of the coarse run-off strip, m
RUNOFF_PX = 0.25                  # its cell, m

# Pixel classes. The BD ORTHO of the Sarthe is hazy and low in saturation: asphalt is a blue
# grey (b - r about +15), grass, dry grass and gravel are warm (b - r below 0), white paint is
# the only bright neutral, and the circuit paints (blue / green run-off, red / blue kerbs,
# yellow) are the only saturated colours.
ASPHALT, WHITE, RED, BLUE, GREEN, YELLOW, GRASS, GRAVEL, TREE, SHADOW = range(10)
NCLASS = 10
CLASS_NAMES = ["asphalt", "white", "red", "blue", "green", "yellow", "grass", "gravel", "tree",
               "shadow"]
CLASS_RGB = np.array([[60, 60, 60], [255, 255, 255], [230, 20, 20], [30, 90, 255],
                      [0, 200, 160], [255, 220, 0], [90, 180, 60], [230, 190, 120],
                      [0, 70, 0], [0, 0, 90]], dtype=np.uint8)
PAINT_COLOURS = (RED, BLUE, GREEN, YELLOW)


# ---------- geometry ----------

def load_track(track_dir):
    with open(os.path.join(track_dir, "track.json"), encoding="utf-8") as f:
        track = json.load(f)
    scale = 1.0
    tj = os.path.join(track_dir, "terrain.json")
    if os.path.exists(tj):
        with open(tj, encoding="utf-8") as f:
            scale = json.load(f).get("plan_scale", 1.0)
    return track, scale


class Frame:
    """Stations of a closed lap and the local maps track frame -> Lambert-93.

    ``P`` (n, 2) station positions (x, z), ``T`` unit tangents, ``L`` unit left normals,
    ``s`` arc length, ``E`` (n, 2) Lambert-93 of the stations and ``J`` (n, 2, 2) the
    Jacobians d(E, N) / d(x, z)."""

    def __init__(self, P, s, to_l93, length=None):
        self.P = np.asarray(P, dtype=float)
        self.s = np.asarray(s, dtype=float)
        self.n = len(self.P)
        self.length = float(length if length is not None else
                            self.s[-1] + np.hypot(*(self.P[0] - self.P[-1])))
        d = np.roll(self.P, -1, axis=0) - np.roll(self.P, 1, axis=0)
        self.T = d / np.linalg.norm(d, axis=1)[:, None]
        self.L = np.column_stack([self.T[:, 1], -self.T[:, 0]])
        self.E = np.column_stack(to_l93(self.P[:, 0], self.P[:, 1]))
        ex = np.column_stack(to_l93(self.P[:, 0] + 1.0, self.P[:, 1])) - self.E
        ez = np.column_stack(to_l93(self.P[:, 0], self.P[:, 1] + 1.0)) - self.E
        self.J = np.stack([ex, ez], axis=2)          # J[:, :, 0] = d/dx, J[:, :, 1] = d/dz
        self.to_l93 = to_l93

    @classmethod
    def from_track(cls, track, plan_scale=1.0):
        from pyproj import Transformer
        from .geom import Projection
        proj = Projection(track["origin_latlon"][0], track["origin_latlon"][1], plan_scale)
        tr = Transformer.from_crs("EPSG:4326", "EPSG:2154", always_xy=True)

        def to_l93(x, z):
            lat, lon = proj.to_latlon(np.asarray(x, float), np.asarray(z, float))
            return tr.transform(lon, lat)
        pts = track["points"]
        P = [(p["p"][0], p["p"][2]) for p in pts]
        s = [p["s"] for p in pts]
        return cls(P, s, to_l93, track.get("length"))

    def station_at(self, s):
        """Index of the station at or before ``s`` (wrapped) and the fraction to the next."""
        s = np.mod(np.asarray(s, float), self.length)
        i = np.clip(np.searchsorted(self.s, s, side="right") - 1, 0, self.n - 1)
        nxt = np.where(i + 1 < self.n, self.s[np.minimum(i + 1, self.n - 1)], self.length)
        f = (s - self.s[i]) / np.maximum(nxt - self.s[i], 1e-9)
        return i, f

    def frame_at(self, s):
        """Centre (x, z), tangent and left normal at arc length ``s`` (array), interpolated."""
        i, f = self.station_at(s)
        j = (i + 1) % self.n
        c = self.P[i] * (1 - f)[:, None] + self.P[j] * f[:, None]
        t = self.T[i] * (1 - f)[:, None] + self.T[j] * f[:, None]
        t /= np.linalg.norm(t, axis=1)[:, None]
        left = np.column_stack([t[:, 1], -t[:, 0]])
        return c, t, left, i

    def xz_to_l93(self, xz, station):
        """Track-frame points (k, 2) near ``station`` (k,) to Lambert-93 (k, 2)."""
        d = xz - self.P[station]
        J = self.J[station]
        return self.E[station] + np.einsum("kij,kj->ki", J, d)

    def offset_to_xz(self, s, off):
        """Track-frame point at arc length ``s`` and left offset ``off`` (arrays)."""
        c, _, left, _ = self.frame_at(np.atleast_1d(s))
        return c + left * np.atleast_1d(off)[:, None]


# ---------- orthophoto mosaic ----------

class Mosaic:
    """Lazy reader of the cached BD ORTHO blocks with bilinear sampling in Lambert-93."""

    def __init__(self, root=CACHE, keep=48):
        self.root = os.path.expanduser(root)
        self.keep = keep
        self._blocks = OrderedDict()

    def block(self, x0, y0):
        key = (int(x0), int(y0))
        if key in self._blocks:
            self._blocks.move_to_end(key)
            return self._blocks[key]
        path = os.path.join(self.root, f"ortho_{key[0]}_{key[1]}.tif")
        arr = None
        if os.path.exists(path):
            from PIL import Image
            with Image.open(path) as im:
                arr = np.asarray(im.convert("RGB"))
        self._blocks[key] = arr
        if len(self._blocks) > self.keep:
            self._blocks.popitem(last=False)
        return arr

    def window(self, e0, n0, e1, n1):
        """RGB array covering [e0, e1] x [n0, n1] on the 0.2 m pixel grid (row 0 north) and the
        Lambert-93 of the centre of its pixel (0, 0). Missing blocks are zeros."""
        c0 = int(math.floor(e0 / PIX)) - 1
        c1 = int(math.ceil(e1 / PIX)) + 1
        r0 = int(math.floor(n0 / PIX)) - 1     # southmost pixel row index (north-up counted)
        r1 = int(math.ceil(n1 / PIX)) + 1
        out = np.zeros((r1 - r0, c1 - c0, 3), dtype=np.uint8)
        valid = np.zeros((r1 - r0, c1 - c0), dtype=bool)
        bx0 = int(math.floor(c0 * PIX / BLOCK_M))
        bx1 = int(math.floor(c1 * PIX / BLOCK_M))
        by0 = int(math.floor(r0 * PIX / BLOCK_M))
        by1 = int(math.floor(r1 * PIX / BLOCK_M))
        for bx in range(bx0, bx1 + 1):
            for by in range(by0, by1 + 1):
                arr = self.block(bx * BLOCK_M, by * BLOCK_M)
                if arr is None:
                    continue
                # global pixel columns of this block: bx*2000 .. ; rows (north index) by*2000..
                gc0, gr0 = bx * BLOCK_PX, by * BLOCK_PX
                lc0, lc1 = max(c0, gc0), min(c1, gc0 + BLOCK_PX)
                lr0, lr1 = max(r0, gr0), min(r1, gr0 + BLOCK_PX)
                if lc0 >= lc1 or lr0 >= lr1:
                    continue
                # block image row 0 is its north edge: north index gr -> image row 1999-(gr-gr0)
                src = arr[BLOCK_PX - (lr1 - gr0):BLOCK_PX - (lr0 - gr0), lc0 - gc0:lc1 - gc0]
                dst_r0 = (r1 - lr1)
                out[dst_r0:dst_r0 + (lr1 - lr0), lc0 - c0:lc1 - c0] = src
                valid[dst_r0:dst_r0 + (lr1 - lr0), lc0 - c0:lc1 - c0] = True
        # pixel (0, 0) is the north-west one: north index r1 - 1, column c0
        return out, valid, ((c0 + 0.5) * PIX, (r1 - 1 + 0.5) * PIX)

    def sample(self, E, N):
        """Bilinear RGB (float32, ..., 3) at Lambert-93 points, and a validity mask."""
        from scipy.ndimage import map_coordinates
        E = np.asarray(E, float)
        N = np.asarray(N, float)
        img, valid, (ex, ny) = self.window(E.min(), N.min(), E.max(), N.max())
        col = (E - ex) / PIX
        row = (ny - N) / PIX
        out = np.empty(E.shape + (3,), dtype=np.float32)
        for c in range(3):
            out[..., c] = map_coordinates(img[..., c], [row, col], order=1, mode="nearest")
        ok = map_coordinates(valid.astype(np.uint8), [row, col], order=0, mode="constant") > 0
        return out, ok


def strip(frame, mosaic, s0, s1, half=HALF, along=ALONG, across=ACROSS):
    """Road-aligned RGB strip for the lap from ``s0`` to ``s1``: rows every ``along`` m (row 0
    at s0), columns every ``across`` m from +half (left) to -half (right). Returns
    (rgb uint8 (rows, cols, 3), valid mask, s of each row, offset of each column)."""
    srow = np.arange(s0, s1, along)
    offs = half - np.arange(int(round(2 * half / across)) + 1) * across
    c, _, left, st = frame.frame_at(srow)
    xz = c[:, None, :] + left[:, None, :] * offs[None, :, None]
    k = xz.shape[:2]
    stn = np.repeat(st, len(offs))
    en = frame.xz_to_l93(xz.reshape(-1, 2), stn).reshape(k + (2,))
    rgb, ok = mosaic.sample(en[..., 0], en[..., 1])
    return np.clip(rgb + 0.5, 0, 255).astype(np.uint8), ok, srow, offs


# ---------- pixel classes ----------

def hue_deg(rgb):
    a = rgb.astype(np.float32)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mx, mn = a.max(-1), a.min(-1)
    d = np.maximum(mx - mn, 1e-3)
    h = np.where(mx == r, np.mod((g - b) / d, 6.0),
                 np.where(mx == g, (b - r) / d + 2.0, (r - g) / d + 4.0))
    return h * 60.0


def classify(rgb):
    """Class id (uint8) per pixel of an RGB array (..., 3). Rules, applied in order (a later
    rule overrides an earlier one):
    - grass by default (anything warm or green that no other rule takes);
    - asphalt: neutral to blue grey (3 <= b - r < 28), chroma < 45, luminance 50-168;
    - gravel: warm (b - r <= -25) and bright (luminance >= 150);
    - tree: dark green and textured;
    - white: bright neutral (luminance >= 172, chroma < 48, not warm);
    - red / blue / green / yellow paint: saturated hues (kerbs, painted run-off; the washed
      out light blue of the run-off paint has a low chroma but b - r >= 28, the dark navy
      stripe beside it b - r >= 30 at a low luminance);
    - shadow: luminance < 50 (unknown ground)."""
    from scipy import ndimage as ndi
    a = rgb.astype(np.float32)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mx, mn = a.max(-1), a.min(-1)
    ch = mx - mn
    lum = a.mean(-1)
    w = b - r
    h = hue_deg(rgb)
    if lum.ndim == 2:
        m = ndi.uniform_filter(lum, 5)
        tex = np.sqrt(np.maximum(ndi.uniform_filter(lum * lum, 5) - m * m, 0.0))
    else:
        tex = np.zeros_like(lum)
    c = np.full(lum.shape, GRASS, np.uint8)
    c[(ch < 45) & (w >= 3) & (w < 28) & (lum >= 50) & (lum < 168)] = ASPHALT
    c[(w <= -25) & (lum >= 150)] = GRAVEL
    c[(lum < 95) & (g >= r) & (tex > 8) & (w < 3)] = TREE
    c[(lum >= 172) & (ch < 48) & (w > -14)] = WHITE
    c[((h >= 335) | (h < 25)) & (ch > 45) & (r > 100)] = RED
    c[(h >= 185) & (h < 240) & (((ch > 50) & (lum > 105)) | ((w >= 28) & (lum > 112))
                                  | ((w >= 30) & (lum >= 55)))] = BLUE
    c[(h >= 145) & (h < 185) & (ch > 38) & (lum > 95)] = GREEN
    c[(h >= 40) & (h < 70) & (ch > 60) & (lum > 120)] = YELLOW
    c[lum < 50] = SHADOW
    return c


# ---------- per-station profiles across the road ----------

class Profiles:
    """Class fractions across the road for every station, from the 5 cm strip.

    ``frac`` (n, cols, NCLASS) float16: share of each class in the 2 m window around the
    station, per column; ``stripe`` (n, cols) float16: along-lap standard deviation of the
    luminance in that window (kerb stripes alternate every metre or so, paint lines do not);
    ``lum`` (n, cols) and ``rgb`` (n, cols, 3) the mean luminance and colour there;
    ``offs`` (cols,) the left offset of each column (+HALF ... -HALF)."""

    def __init__(self, n, offs):
        self.offs = offs
        self.frac = np.zeros((n, len(offs), NCLASS), np.float16)
        self.stripe = np.zeros((n, len(offs)), np.float16)
        self.lum = np.zeros((n, len(offs)), np.float16)
        self.rgb = np.zeros((n, len(offs), 3), np.float16)
        self.valid = np.zeros(n, bool)

    def col(self, off):
        """Column index of a left offset (float array ok)."""
        return np.rint((self.offs[0] - np.asarray(off, float)) / (self.offs[0] - self.offs[1])
                       ).astype(int)


def build_profiles(frame, mosaic, chunk_m=100.0, half=HALF, log=print, stations=None):
    """Profiles of every station (or of ``stations``, an index array) of ``frame``."""
    idx = np.arange(frame.n) if stations is None else np.asarray(stations)
    offs = half - np.arange(int(round(2 * half / ACROSS)) + 1) * ACROSS
    prof = Profiles(frame.n, offs)
    rows_per = int(round(2.0 / ALONG))           # the 2 m window
    # group consecutive stations into chunks of about chunk_m
    groups, cur = [], [idx[0]]
    for i in idx[1:]:
        if i == cur[-1] + 1 and frame.s[i] - frame.s[cur[0]] < chunk_m:
            cur.append(i)
        else:
            groups.append(cur)
            cur = [i]
    groups.append(cur)
    for gi, g in enumerate(groups):
        s0, s1 = frame.s[g[0]] - 1.0, frame.s[g[-1]] + 1.0 + ALONG
        rgb, ok, srow, _ = strip(frame, mosaic, s0, s1, half)
        cls = classify(rgb)
        lum = rgb.astype(np.float32).mean(-1)
        onehot = np.zeros(cls.shape + (NCLASS,), np.float32)
        np.put_along_axis(onehot, cls[..., None].astype(np.int64), 1.0, axis=-1)
        for i in g:
            r0 = int(round((frame.s[i] - 1.0 - s0) / ALONG))
            sl = slice(max(r0, 0), max(r0, 0) + rows_per)
            prof.frac[i] = onehot[sl].mean(0)
            prof.stripe[i] = lum[sl].std(0)
            prof.lum[i] = lum[sl].mean(0)
            prof.rgb[i] = rgb[sl].mean(0)
            prof.valid[i] = ok[sl].mean() > 0.95
        if log and gi % 20 == 0:
            log(f"  profiles {frame.s[g[-1]]:.0f} / {frame.length:.0f} m")
    return prof


# ---------- edge tracing ----------

D_MIN = 1.5            # m, nearest edge offset searched
EDGE_WIN = 0.6         # m, half window of the step detector
MAX_STEP = 0.8         # m, largest change of an edge offset between two stations (2 m)
SMOOTH = 1.5           # cost per metre of edge offset change between two stations
LOW_CONF = 0.4         # below this a station's edge is interpolated and flagged


def _dp(cost, max_shift, lam_bin):
    """Minimum cost path through ``cost`` (n, K): one bin per row, moving at most
    ``max_shift`` bins between rows at ``lam_bin`` per bin. Returns the bin of each row."""
    n, K = cost.shape
    acc = cost[0].astype(np.float64).copy()
    back = np.zeros((n, K), np.int8)
    big = 1e18
    for i in range(1, n):
        best = np.full(K, big)
        arg = np.zeros(K, np.int8)
        for k in range(-max_shift, max_shift + 1):
            if k >= 0:
                cand = np.full(K, big)
                cand[k:] = acc[:K - k] + lam_bin * k
            else:
                cand = np.full(K, big)
                cand[:K + k] = acc[-k:] - lam_bin * k
            better = cand < best
            best[better] = cand[better]
            arg[better] = k
        acc = best + cost[i]
        back[i] = arg
    path = np.zeros(n, int)
    path[-1] = int(np.argmin(acc))
    for i in range(n - 1, 0, -1):
        path[i - 1] = path[i] - back[i, path[i]]
    return path


def side_signals(prof, side, d):
    """Signals along the offsets ``d`` (m, >= 0) on one side (+1 left, -1 right), each (n, K):
    track-likeness T, off-ground O, paint colour P, white W, occlusion Q (tree + shadow) and
    stripes (along-lap luminance spread)."""
    from scipy import ndimage as ndi
    cols = prof.col(side * d)
    f = prof.frac[:, cols].astype(np.float32)
    # white bands wider than a painted line are kerbs (or walls, buildings): not tarmac
    wb = f[..., WHITE] >= 0.4
    lab, nl = ndi.label(wb, structure=[[0, 0, 0], [1, 1, 1], [0, 0, 0]])
    step = abs(d[1] - d[0]) if len(d) > 1 else ACROSS
    wide = (np.bincount(lab.ravel(), minlength=nl + 1) * step > LINE_MAX_W)
    wide[0] = False
    paint = f[..., RED] + f[..., BLUE] + f[..., GREEN] + f[..., YELLOW]
    near_paint = ndi.maximum_filter1d(paint, size=max(3, int(round(0.4 / step))), axis=1) >= 0.3
    kerb_white = np.where(wide[lab] | near_paint, f[..., WHITE], 0.0)
    T = f[..., ASPHALT] + f[..., WHITE] - kerb_white + 0.3 * f[..., SHADOW]
    # a narrow band much darker than both its sides: the shadow of a barrier or a kerbstone
    # line at the road's edge, not road
    lum = prof.lum[:, cols].astype(np.float32)
    k1, k2 = max(1, int(round(0.4 / step))), max(2, int(round(1.0 / step)))
    pad = np.pad(lum, ((0, 0), (k2, k2)), mode="edge")
    c = np.concatenate([np.zeros((lum.shape[0], 1)), np.cumsum(pad, axis=1)], axis=1)
    j = np.arange(lum.shape[1]) + k2
    lft = (c[:, j - k1 + 1] - c[:, j - k2 + 1]) / (k2 - k1)
    rgt = (c[:, j + k2] - c[:, j + k1]) / (k2 - k1)
    side_min = np.minimum(lft, rgt)
    dark = np.clip((0.85 * side_min - lum) / (0.15 * side_min + 1e-3), 0.0, 1.0)
    T = T * (1.0 - 0.7 * dark)
    # a narrow band much brighter than both sides is a painted line even when the photo
    # leaves it grey (worn paint, haze): track, and a line candidate
    ridge = np.clip((lum - np.maximum(lft, rgt) - 20.0) / 25.0, 0.0, 1.0) * (lum > 110)
    ridge = np.where(kerb_white > 0, 0.0, ridge)
    T = np.maximum(T, ridge * (paint < 0.3))
    O = f[..., GRASS] + f[..., GRAVEL] + f[..., TREE]
    P = paint + kerb_white
    return {"T": T, "O": O, "P": P, "W": np.maximum(f[..., WHITE] - kerb_white, ridge),
            "KW": kerb_white,
            "A": f[..., ASPHALT],
            "Q": np.clip(f[..., TREE] + f[..., SHADOW] + dark, 0.0, 1.0), "stripe": prof.stripe[:, cols].astype(np.float32),
            "f": f}


def _box(x, k):
    """Mean of x (n, K) over [j - k, j) and [j, j + k) along axis 1 (edge-padded)."""
    n, K = x.shape
    c = np.concatenate([np.zeros((n, 1)), np.cumsum(x, axis=1)], axis=1)
    j = np.arange(K)
    lo = np.clip(j - k, 0, K)
    hi = np.clip(j + k, 0, K)
    inner = (c[:, j] - c[:, lo]) / np.maximum(j - lo, 1)
    outer = (c[:, hi] - c[:, j]) / np.maximum(hi - j, 1)
    return inner, outer


def edge_cost(sig, step):
    """Cost (n, K) of putting the tarmac edge at each offset: minus the step of
    track-likeness from inside to outside, plus the off-ground and paint met on the way out
    from the centreline (an edge beyond a strip of grass is not this road's edge)."""
    k = max(1, int(round(EDGE_WIN / step)))
    tin, tout = _box(sig["T"], k)
    contrast = tin - tout
    inner_off = np.cumsum(sig["O"] * step, axis=1)
    inner_paint = np.cumsum(sig["P"] * step, axis=1)
    # the inner sums stop EDGE_WIN short of the candidate
    sh = np.zeros_like(inner_off)
    sh[:, k:] = inner_off[:, :-k]
    shp = np.zeros_like(inner_paint)
    shp[:, k:] = inner_paint[:, :-k]
    return -contrast + 0.8 * sh + 0.3 * shp, contrast


def trace_side(prof, side, d_max=None):
    """Tarmac edge offsets (m, >= 0) of one side for every station, the raw contrast there and
    the offsets grid used."""
    step = prof.offs[0] - prof.offs[1]
    d_max = d_max or (prof.offs[0] - EDGE_WIN - 0.2)
    d = np.arange(D_MIN, d_max, step)
    sig = side_signals(prof, side, d)
    cost, contrast = edge_cost(sig, step)
    cost[~prof.valid] = 0.0
    path = _dp(cost, int(round(MAX_STEP / step)), SMOOTH * step)
    n = len(path)
    return d[path], contrast[np.arange(n), path], sig, d, path


# ---------- QA overlays ----------

def qa_overlay(frame, mosaic, result, s0, s1, path, panel_m=100.0, px=0.1, half=HALF):
    """PNG of the photo from s0 to s1 cut into panels of ``panel_m`` (driving direction up,
    left of the road on the left), with the traced edges drawn on it: left edge cyan, right
    edge magenta (orange where the confidence is low and the edge was interpolated), the
    painted edge lines thin white dashes, kerbs as bars outside the edge (red: striped, blue:
    flat, yellow: sausage), run-off outlines (tan: gravel, grey: tarmac, green: grass)."""
    from PIL import Image, ImageDraw
    st = result["stations"]
    panels = []
    a = s0
    while a < s1 - 1e-6:
        b = min(a + panel_m, s1)
        rgb, _, srow, offs = strip(frame, mosaic, a, b, half, along=px, across=px)
        img = Image.fromarray(rgb[::-1].copy())
        dr = ImageDraw.Draw(img)
        H = rgb.shape[0]

        def xy(s, off):
            return ((half - off) / px, H - 1 - (s - a) / px)
        sel = np.nonzero((st["s"] >= a - 2) & (st["s"] <= b + 2))[0]
        for key, sign, colr in (("left", 1, (0, 255, 255)), ("right", -1, (255, 0, 255))):
            conf = st["conf_" + key]
            for i, j in zip(sel[:-1], sel[1:]):
                if j != i + 1:
                    continue
                c = colr if min(conf[i], conf[j]) >= LOW_CONF else (255, 140, 0)
                dr.line([xy(st["s"][i], sign * st[key][i]), xy(st["s"][j], sign * st[key][j])],
                        fill=c, width=2)
                for lk in ("line_" + key,):
                    if np.isfinite(st[lk][i]) and np.isfinite(st[lk][j]) and i % 2 == 0:
                        dr.line([xy(st["s"][i], sign * st[lk][i]),
                                 xy(st["s"][j], sign * st[lk][j])], fill=(255, 255, 255), width=1)
        for k in result["kerbs"]:
            if k["s1"] < a or k["s0"] > b:
                continue
            sign = 1 if k["side"] == "left" else -1
            colr = {"red_white": (255, 30, 30), "flat": (40, 120, 255),
                    "sausage": (255, 220, 0)}[k["kind"]]
            for sx in np.arange(max(k["s0"], a), min(k["s1"], b), 0.5):
                i = int(np.clip(np.searchsorted(st["s"], sx), 0, len(st["s"]) - 1))
                e = st["left" if sign > 0 else "right"][i] + k.get("gap", 0.0)
                p0 = xy(sx, sign * e)
                p1 = xy(sx, sign * (e + k["width"]))
                dr.line([p0, p1], fill=colr, width=1)
        for r in result["runoff"]:
            if r["s1"] < a or r["s0"] > b:
                continue
            colr = {"gravel": (230, 190, 120), "tarmac": (150, 150, 150),
                    "grass": (60, 220, 60)}[r["kind"]]
            pts = [xy(s, o) for s, o in r["ring_so"] if a - 5 <= s <= b + 5]
            if len(pts) > 2:
                dr.line(pts + [pts[0]], fill=colr, width=2)
        for t in range(int(math.ceil(a / 10.0)) * 10, int(b) + 1, 10):
            y = xy(t, 0)[1]
            dr.line([(0, y), (12, y)], fill=(255, 255, 0), width=1)
            if t % 50 == 0:
                dr.text((14, y - 6), f"s={t}", fill=(255, 255, 0))
        for o in range(-int(half), int(half) + 1, 5):
            x = xy(a, o)[0]
            dr.line([(x, H - 8), (x, H - 1)], fill=(255, 255, 0), width=1)
        panels.append(img)
        a = b
    W = sum(p.width for p in panels) + 6 * (len(panels) - 1)
    out = Image.new("RGB", (W, max(p.height for p in panels)), (0, 0, 0))
    x = 0
    for p in panels:
        out.paste(p, (x, out.height - p.height))
        x += p.width + 6
    out.save(path)
    return path


# ---------- painted edge lines, confidence, interpolation ----------

LINE_MIN = 3.2         # m, nearest offset an edge line may have (centre / lane lines are inside)
LINE_MAX_W = 0.8       # m, a white band wider than this is a kerb, not a line
LINE_RUN = 9           # stations of the continuity test (18 m)
RUNOFF_GAP = 1.5       # m of asphalt beyond the outermost edge line that makes it tarmac run-off


def outer_lines(sig, d, edge, step):
    """Outer boundary (m) of the innermost continuous white line beyond LINE_MIN (the track
    limit line: further lines belong to service roads and run-off) inside ``edge`` for every
    station, NaN where there is none. A line is a narrow white band (<= LINE_MAX_W), white over
    at least 75 % of the 2 m window in 80 % of LINE_RUN stations (the dashed lane and edge
    lines of the public roads fail this: their gaps leave windows half white)."""
    from scipy.ndimage import median_filter
    W = sig["W"]
    n, K = W.shape
    out = np.full(n, np.nan)
    strong = W >= 0.75
    lo = np.searchsorted(d, LINE_MIN)
    for i in range(n):
        lim = np.searchsorted(d, edge[i] + 0.1)
        j = lo
        while j < lim:
            if strong[i, j]:
                k = j
                while k + 1 < len(d) and W[i, k + 1] >= 0.25:
                    k += 1
                if (k - j + 1) * step <= LINE_MAX_W:
                    out[i] = d[k]
                break
            j += 1
    ok = np.isfinite(out).astype(float)
    frac = np.convolve(np.r_[ok[-LINE_RUN:], ok, ok[:LINE_RUN]], np.ones(LINE_RUN) / LINE_RUN,
                       "same")[LINE_RUN:-LINE_RUN]
    filled = np.where(np.isfinite(out), out, -1.0)
    med = median_filter(filled, size=LINE_RUN, mode="wrap")
    good = (frac >= 0.8) & (med > 0) & np.isfinite(out) & (np.abs(out - med) < 0.3)
    return np.where(good, out, np.nan)


OPEN_TARMAC = 3.0      # m beyond the local median width: open tarmac, not the road's edge


def weak_lines(sig, d, base, step):
    """Outer side of the innermost narrow white band (dashed allowed: >= 0.3 white in the
    window) within [base - 2.5, base + 2.5] m, per station; NaN where there is none."""
    W = sig["W"]
    n = W.shape[0]
    out = np.full(n, np.nan)
    for i in range(n):
        j = max(np.searchsorted(d, max(base[i] - 2.5, LINE_MIN)), 0)
        j1 = min(np.searchsorted(d, base[i] + 2.5), len(d) - 1)
        while j < j1:
            if W[i, j] >= 0.3:
                k = j
                while k + 1 < len(d) and W[i, k + 1] >= 0.15:
                    k += 1
                if (k - j + 1) * step <= LINE_MAX_W:
                    out[i] = d[k]
                break
            j += 1
    return out


def striped_lines(sig, d, edge, use_line, step):
    """A narrow band of white blocks at a line-limited edge is a kerb (the chicanes of the
    public roads: white blocks between dark - red - ones that the photo does not resolve), not a
    painted line: the edge moves to its inner side. Returns (edge, mask of moved stations)."""
    out = edge.copy()
    moved = np.zeros(len(edge), bool)
    W, st = sig["W"], sig["stripe"]
    for i in np.nonzero(use_line)[0]:
        j1 = min(np.searchsorted(d, edge[i]), len(d) - 1)
        lim = max(j1 - int(0.4 / step), 0)
        while j1 > lim and W[i, j1] < 0.15:
            j1 -= 1
        j = j1
        while j - 1 >= 0 and W[i, j - 1] >= 0.15 and (j1 - j) * step < LINE_MAX_W + 0.2:
            j -= 1
        if j1 - j < 3:
            continue
        if st[i, j:j1 + 1].mean() >= STRIPE_STD:
            out[i] = d[j]
            moved[i] = True
    return out, moved


def confidence(edge, contrast, sig, d, step):
    """0..1 per station: edge contrast, minus occlusion (tree, shadow) around the edge, minus
    disagreement with the running median of the edge (a jump that the neighbours do not
    share)."""
    from scipy.ndimage import median_filter
    n = len(edge)
    c_con = np.clip(contrast / 0.6, 0.0, 1.0)
    j = np.clip(np.searchsorted(d, edge), 0, len(d) - 1)
    k = int(round(1.5 / step))
    Q = sig["Q"]
    cs = np.concatenate([np.zeros((n, 1)), np.cumsum(Q, axis=1)], axis=1)
    lo, hi = np.clip(j - k, 0, Q.shape[1]), np.clip(j + k, 0, Q.shape[1])
    occl = (cs[np.arange(n), hi] - cs[np.arange(n), lo]) / np.maximum(hi - lo, 1)
    c_occ = 1.0 - np.clip(2.0 * occl, 0.0, 1.0)
    med = median_filter(edge, size=11, mode="wrap")
    c_cons = np.exp(-((edge - med) / 0.4) ** 2)
    conf = c_con * c_occ * c_cons
    return median_filter(conf, size=5, mode="wrap"), occl


def interpolate_low(edge, conf, thr=LOW_CONF, max_len=150):
    """Edge with stretches of stations under ``thr`` replaced by a straight interpolation
    between the confident stations on both ends (stretches longer than ``max_len`` stations
    keep the traced value). Returns (edge, flagged mask)."""
    n = len(edge)
    out = edge.copy()
    bad = conf < thr
    flag = np.zeros(n, bool)
    if bad.all() or not bad.any():
        return out, bad.copy()
    start = int(np.argmin(bad))                 # a good station: walk the loop from it
    i = 0
    while i < n:
        a = (start + i) % n
        if not bad[a]:
            i += 1
            continue
        j = i
        while j < n and bad[(start + j) % n]:
            j += 1
        p, q = (start + i - 1) % n, (start + j) % n
        L = j - i
        flag[[(start + t) % n for t in range(i, j)]] = True
        if L <= max_len:
            for t in range(i, j):
                f = (t - i + 1) / (L + 1)
                out[(start + t) % n] = edge[p] * (1 - f) + edge[q] * f
        i = j
    return out, flag


def trace_edges(prof, log=print):
    """Both edges of the track for every station. Returns a dict of arrays (n,):
    left / right (final edges, m), tarmac_left / right (asphalt boundary), line_left / right
    (outer edge of the painted edge line, NaN if none), conf_left / right, flag_left / right
    (interpolated, low confidence), runoff_left / right (asphalt continues beyond the line:
    tarmac run-off), occl_left / right."""
    step = prof.offs[0] - prof.offs[1]
    out = {}
    for side, key in ((1, "left"), (-1, "right")):
        tarmac, contrast, sig, d, _ = trace_side(prof, side)
        line = outer_lines(sig, d, tarmac, step)
        use_line = np.isfinite(line) & (tarmac - line > RUNOFF_GAP)
        edge = np.where(use_line, line, tarmac)
        # open tarmac (chicane bypasses, junctions, car parks): an edge far beyond the usual
        # width of the surrounding 600 m snaps to a weaker (dashed) line near that width, or
        # falls back to it and is flagged
        from scipy.ndimage import median_filter as _mf
        base = _mf(edge, size=301, mode="wrap")
        wide = edge > base + OPEN_TARMAC
        weak = weak_lines(sig, d, base, step)
        snap = wide & np.isfinite(weak)
        edge = np.where(snap, weak, np.where(wide, base, edge))
        use_line = use_line | snap
        edge, refined, strength = refine_edge(prof, side, edge, use_line)
        # the refinement of a soft verge jitters from station to station: a running median
        # (keeps real steps: kerb ends, chicanes) then a short mean
        from scipy.ndimage import median_filter, uniform_filter1d
        edge = uniform_filter1d(median_filter(edge, size=7, mode="wrap"), 3, mode="wrap")
        # edge evidence: the class step, or the colour step measured by the refinement
        contrast = np.maximum(contrast, np.where(refined, np.clip(strength / 50.0, 0, 1) * 0.6, 0))
        edge, kerb_line = striped_lines(sig, d, edge, use_line, step)
        conf, occl = confidence(edge, contrast, sig, d, step)
        conf = np.where(wide & ~snap, np.minimum(conf, 0.2), conf)
        final, flag = interpolate_low(edge, conf)
        out[key] = final
        out["tarmac_" + key] = tarmac
        out["line_" + key] = line
        out["conf_" + key] = conf
        out["flag_" + key] = flag
        out["runoff_" + key] = use_line & ~kerb_line
        out["occl_" + key] = occl
        out["_sig_" + key] = (sig, d)
        if log:
            log(f"  {key}: median {np.median(final):.2f} m, line-limited {use_line.mean():.0%},"
                f" low confidence {flag.mean():.0%}")
    return out


def _crossing(x, d, mid, lo, hi, prefer):
    """Offset in [lo, hi] where the profile ``x`` (over offsets ``d``) crosses ``mid``, the
    crossing nearest ``prefer`` (linear interpolation); None when it does not cross."""
    j0, j1 = np.searchsorted(d, lo), min(np.searchsorted(d, hi), len(d) - 1)
    best = None
    for j in range(max(j0, 0), j1):
        a, b = x[j] - mid, x[j + 1] - mid
        if a == 0 or a * b < 0:
            t = 0.0 if a == 0 else a / (a - b)
            o = d[j] + t * (d[j + 1] - d[j])
            if best is None or abs(o - prefer) < abs(best - prefer):
                best = o
    return best


def refine_edge(prof, side, edge, is_line, search=0.8):
    """Sub-pixel edges: the offset where the station's mean colour crosses halfway (in RGB,
    projected on the line between the two colours) from the surface inside to the one
    outside. When the edge is the outer side of a painted line (a white crest just inside it)
    the inside colour is the line's. Edges with no clear colour step (< 15 RGB units) stay as
    traced."""
    step = prof.offs[0] - prof.offs[1]
    d = np.arange(0.0, prof.offs[0] - 0.05, step)
    cols = prof.col(side * d)
    rgb = prof.rgb[:, cols].astype(np.float32)
    lum = rgb.mean(-1)
    out = edge.copy()
    refined = np.zeros(len(edge), bool)
    strength = np.zeros(len(edge))
    for i in range(len(edge)):
        e = edge[i]
        if e + 1.4 > d[-1]:
            continue
        ja, jb = np.searchsorted(d, [e - 1.4, e - 0.6])
        ka, kb = np.searchsorted(d, [e + 0.6, e + 1.4])
        A = np.median(rgb[i, ja:jb + 1], axis=0)
        B = np.median(rgb[i, ka:kb + 1], axis=0)
        j0, j1 = np.searchsorted(d, [e - 0.6, e + 0.1])
        crest = j0 + int(np.argmax(lum[i, j0:j1 + 1]))
        lo = e - search
        c = rgb[i, crest]
        bright = lum[i, crest] > max(A.mean(), B.mean()) + 8
        if is_line[i] or (bright and min(np.linalg.norm(c - A), np.linalg.norm(c - B)) >= 25):
            A = c
            lo = d[crest]
        v = B - A
        nv = float(v @ v)
        strength[i] = math.sqrt(nv)
        if nv < 15.0 ** 2:
            continue
        t = (rgb[i] - A) @ v / nv
        o = _crossing(t, d, 0.5, lo, e + search, e)
        if o is not None:
            out[i] = o
            refined[i] = True
    return out, refined, strength


# ---------- kerbs ----------

KERB_BAND = 3.0        # m beyond the edge searched for a kerb
KERB_MIN_W = 0.5       # m, narrower painted bands are lines
KERB_MAX_W = 2.6       # m, wider solid paint is painted run-off, not a kerb
STRIPE_STD = 9.0       # along-lap luminance spread of a striped kerb (solid paint: 3-5)
SAUSAGE_MAX_W = 1.0    # m


def kerb_stations(prof, edges):
    """Per side, per station: kerb kind ('' none, 'red_white', 'flat', 'sausage'), width, gap
    from the edge and dominant colour, from the class fractions just outside the edge."""
    step = prof.offs[0] - prof.offs[1]
    d = np.arange(0.0, prof.offs[0] - 0.05, step)
    out = {}
    colours = {RED: "red", BLUE: "blue", GREEN: "green", YELLOW: "yellow"}
    for side, key in ((1, "left"), (-1, "right")):
        sig = side_signals(prof, side, d)
        f = sig["f"]
        kerbish = sig["P"] - sig["KW"] + f[..., WHITE]   # coloured paint and any white
        n = len(edges[key])
        kind = np.array([""] * n, dtype=object)
        width = np.zeros(n)
        gap = np.zeros(n)
        colour = np.array([""] * n, dtype=object)
        for i in range(n):
            e = edges[key][i]
            j0 = np.searchsorted(d, e - 0.15)
            j1 = min(np.searchsorted(d, e + KERB_BAND), len(d) - 1)
            if j1 - j0 < 4:
                continue
            k = kerbish[i, j0:j1]
            on = k >= 0.5
            if not on[:max(1, int(0.5 / step))].any():
                continue
            a = int(np.argmax(on))
            b = a
            while b < len(on) and on[b]:
                b += 1
            w = (b - a) * step
            if w < KERB_MIN_W:
                continue
            band = slice(j0 + a, j0 + b)
            fr = f[i, band].mean(0)
            strip_std = float(sig["stripe"][i, band].mean())
            col = max(colours, key=lambda c: fr[c])
            cname = colours[col] if fr[col] >= 0.15 else "white"
            if cname == "yellow" and w <= SAUSAGE_MAX_W:
                kd = "sausage"
            elif strip_std >= STRIPE_STD:
                kd = "red_white"
                if cname == "white":
                    cname = "unresolved"      # the 20 cm photo only keeps the white blocks
            elif w <= KERB_MAX_W:
                kd = "flat"
            else:
                continue                      # painted run-off: see run-off
            kind[i], width[i], gap[i], colour[i] = kd, w, a * step + (d[j0] - e), cname
        # kerbs laid on the tarmac (the removable kerbs of the public-road corners: Arnage,
        # Indianapolis, the chicanes): a striped band 0.45-1.2 m wide up to 2.5 m inside the
        # edge, coloured or wider than a painted line; gap < 0 = its outer side lies inside
        for i in range(n):
            if kind[i]:
                continue
            e = edges[key][i]
            ja, jb = np.searchsorted(d, [max(e - 2.5, D_MIN), e - 0.3])
            if jb - ja < 10:
                continue
            band = (sig["W"][i, ja:jb] + sig["P"][i, ja:jb]) >= 0.4
            j = len(band) - 1
            while j >= 0 and not band[j]:
                j -= 1
            if j < 0:
                continue
            k = j
            while k - 1 >= 0 and band[k - 1]:
                k -= 1
            w = (j - k + 1) * step
            if not 0.45 <= w <= 1.2:
                continue
            sl = slice(ja + k, ja + j + 1)
            fr = f[i, sl].mean(0)
            col = max(colours, key=lambda c: fr[c])
            stripe = float(sig["stripe"][i, sl].mean())
            if stripe < 12.0 or (fr[col] < 0.15 and w < 0.55):
                continue
            kind[i] = "sausage" if colours[col] == "yellow" and fr[col] >= 0.15 else "red_white"
            width[i] = w
            gap[i] = d[ja + k] - e                # negative: inside the edge
            colour[i] = colours[col] if fr[col] >= 0.15 else "unresolved"
        out[key] = {"kind": kind, "width": width, "gap": gap, "colour": colour}
    return out


def kerb_segments(s, ks, length, min_len=6.0, max_gap=4.0):
    """Group per-station kerbs into segments {s0, s1, side, kind, width, colour}. Stations of
    a different kerb kind inside a segment are absorbed when they are a minority; gaps up to
    ``max_gap`` metres are bridged; segments shorter than ``min_len`` are dropped (sausages:
    2 m)."""
    segs = []
    for key, kset in (("left", ("red_white", "flat")), ("left", ("sausage",)),
                      ("right", ("red_white", "flat")), ("right", ("sausage",))):
        k = ks[key]
        idx_all = np.nonzero(np.isin(k["kind"].astype(str), kset))[0]
        if len(idx_all) == 0:
            continue
        groups, cur = [], [idx_all[0]]
        for j in idx_all[1:]:
            if s[j] - s[cur[-1]] <= max_gap + 2.0:
                cur.append(j)
            else:
                groups.append(cur)
                cur = [j]
        groups.append(cur)
        for g in groups:
            idx = np.array(g)
            kinds, counts = np.unique(k["kind"][idx].astype(str), return_counts=True)
            kd = kinds[np.argmax(counts)]
            cols, cc = np.unique(k["colour"][idx].astype(str), return_counts=True)
            s0, s1 = s[idx[0]] - 1.0, s[idx[-1]] + 1.0
            if s1 - s0 >= (2.0 if kd == "sausage" else min_len):
                segs.append({"s0": round(float(s0), 1), "s1": round(float(s1), 1), "side": key,
                             "kind": str(kd),
                             "width": round(float(np.median(k["width"][idx])), 2),
                             "gap": round(float(np.median(k["gap"][idx])), 2),
                             "colour": str(cols[np.argmax(cc)])})
    segs.sort(key=lambda g: g["s0"])
    return segs


# ---------- run-off ----------

RUNOFF_MIN_W = 2.0     # m, narrower bands of gravel / tarmac beyond the edge are verges
RUNOFF_MIN_LEN = 10.0  # m along the lap
GRASS_MAX = 30.0       # m, grass run-off is reported up to this far out
TARMAC_MAX = 40.0      # m, tarmac reaching further is a road or a car park: capped and flagged

SURF_TARMAC, SURF_GRAVEL, SURF_GRASS, SURF_STOP = 0, 1, 2, 3


def surface_class(cls):
    """Run-off surface of each pixel class: tarmac (asphalt, paint), gravel, grass, or a stop
    (trees, shadow: the run-off ends at the tree line or a barrier's shadow)."""
    lut = np.array([SURF_TARMAC, SURF_TARMAC, SURF_TARMAC, SURF_TARMAC, SURF_TARMAC,
                    SURF_TARMAC, SURF_GRASS, SURF_GRAVEL, SURF_STOP, SURF_STOP], np.uint8)
    return lut[cls]


def runoff_surfaces(frame, mosaic, half=RUNOFF_HALF, px=RUNOFF_PX, chunk_m=200.0, log=print):
    """Coarse strip for the run-off: per station, the majority surface class of each 0.25 m
    column over its 2 m window, ``half`` metres to each side. Returns (surf (n, cols) uint8,
    offs)."""
    offs = half - np.arange(int(round(2 * half / px)) + 1) * px
    surf = np.full((frame.n, len(offs)), SURF_STOP, np.uint8)
    along = 0.5
    s0 = 0.0
    while s0 < frame.length:
        s1 = min(s0 + chunk_m, frame.length + 1.0)
        rgb, ok, srow, _ = strip(frame, mosaic, s0 - 1.0, s1 + 1.0, half, along=along, across=px)
        sc = surface_class(classify(rgb))
        sc[~ok] = SURF_STOP
        onehot = np.stack([sc == k for k in range(4)], axis=-1).astype(np.float32)
        sel = np.nonzero((frame.s >= s0) & (frame.s < s1))[0]
        for i in sel:
            r0 = int(round((frame.s[i] - 1.0 - (s0 - 1.0)) / along))
            surf[i] = onehot[r0:r0 + 4].sum(0).argmax(-1)
        if log and int(s0) % 2000 == 0:
            log(f"  run-off strip {s0:.0f} / {frame.length:.0f} m")
        s0 = s1
    return surf, offs


def runoff_stations(surf, offs, edges, kerbs, px=RUNOFF_PX, max_bands=3):
    """Per side, per kind ('gravel' | 'tarmac' | 'grass'), per station: (u0, u1) of the first
    band of that surface beyond the edge and its kerb (u measured outward from the kerb's outer
    edge, or from the edge without kerb), walking outward through up to ``max_bands`` bands
    (a tarmac strip, then the gravel trap, then grass...) until trees / shadow. A band must be
    RUNOFF_MIN_W wide (1 m for the first one); 0.5 m of another surface inside it is tolerated
    (lines, specks). Returns {side: {kind: {"u0", "u1", "has", "capped"}}}."""
    from scipy.ndimage import median_filter
    out = {}
    names = {SURF_TARMAC: "tarmac", SURF_GRAVEL: "gravel", SURF_GRASS: "grass"}
    lims = {SURF_GRASS: GRASS_MAX, SURF_TARMAC: TARMAC_MAX, SURF_GRAVEL: 80.0}
    tol = int(0.5 / px)
    for side, key in ((1, "left"), (-1, "right")):
        n = surf.shape[0]
        res = {nm: {"u0": np.zeros(n), "u1": np.zeros(n), "has": np.zeros(n, bool),
                    "capped": np.zeros(n, bool)} for nm in names.values()}
        d = np.arange(0.0, offs[0], px)
        cols = np.rint((offs[0] - side * d) / px).astype(int)
        for i in range(n):
            base = edges[key][i] + (kerbs[key]["gap"][i] + kerbs[key]["width"][i]
                                    if kerbs[key]["kind"][i] else 0.0)
            row = surf[i, cols]
            j = int(np.searchsorted(d, base + 0.3))
            for band in range(max_bands):
                if j >= len(d) - 2:
                    break
                first = row[j:j + int(1.0 / px)]
                vals, cnt = np.unique(first, return_counts=True)
                k = int(vals[np.argmax(cnt)])
                if k == SURF_STOP:
                    break
                m, miss, last = j, 0, j
                while m < len(d):
                    if row[m] == k:
                        last, miss = m, 0
                    else:
                        miss += 1
                        if miss > tol:
                            break
                    m += 1
                width = (last - j + 1) * px
                nm = names[k]
                if width >= (1.0 if band == 0 else RUNOFF_MIN_W) and not res[nm]["has"][i]:
                    u0 = max(d[j] - base, 0.0) if band else 0.0
                    u1 = d[last] - base + px / 2
                    res[nm]["has"][i] = True
                    res[nm]["u0"][i] = u0
                    res[nm]["u1"][i] = min(u1, u0 + lims[k])
                    res[nm]["capped"][i] = (u1 - u0 >= lims[k]) or last >= len(d) - 1
                j = last + 1
        for nm in res:
            h = res[nm]["has"]
            for f in ("u0", "u1"):
                res[nm][f] = np.where(h, median_filter(res[nm][f], size=5, mode="wrap"), 0.0)
        out[key] = res
    return out


def runoff_polygons(frame, s, edges, kerbs, ro, min_len=RUNOFF_MIN_LEN, max_gap=4.0):
    """Run-off areas {kind, side, s0, s1, u0, u1 (medians), capped, ring, ring_so}: ``ring`` is
    the outline in the track frame [[x, z], ...] (inner side forward, outer side back),
    ``ring_so`` the same in (s, left offset). Gravel and tarmac areas shorter than
    ``min_len`` are dropped; grass is only reported where it is the first band (verge)."""
    polys = []
    for key, sign in (("left", 1.0), ("right", -1.0)):
        for kd in ("gravel", "tarmac", "grass"):
            r = ro[key][kd]
            has = r["has"].copy()
            if kd == "grass":
                has &= r["u0"] <= 0.5
            idx_all = np.nonzero(has)[0]
            if len(idx_all) == 0:
                continue
            groups, cur = [], [idx_all[0]]
            for j in idx_all[1:]:
                if s[j] - s[cur[-1]] <= max_gap + 2.0:
                    cur.append(j)
                else:
                    groups.append(cur)
                    cur = [j]
            groups.append(cur)
            for g in groups:
                idx = np.arange(g[0], g[-1] + 1)
                if s[idx[-1]] - s[idx[0]] < min_len:
                    continue
                base = edges[key][idx] + np.where(kerbs[key]["kind"][idx] != "",
                                                  kerbs[key]["gap"][idx] + kerbs[key]["width"][idx], 0.0)
                u0 = np.interp(idx, g, r["u0"][g])
                u1 = np.interp(idx, g, r["u1"][g])
                inner, outer = base + u0, base + u1
                keep = idx[::2] if len(idx) > 2 else idx
                if keep[-1] != idx[-1]:
                    keep = np.r_[keep, idx[-1]]
                ki = np.searchsorted(idx, keep)
                so = [(float(s[i]), float(sign * inner[k])) for i, k in zip(keep, ki)]
                so += [(float(s[i]), float(sign * outer[k])) for i, k in zip(keep[::-1], ki[::-1])]
                xz = frame.offset_to_xz(np.array([p[0] for p in so]), np.array([p[1] for p in so]))
                polys.append({"kind": kd, "side": key,
                              "s0": round(float(s[idx[0]]), 1), "s1": round(float(s[idx[-1]]), 1),
                              "u0": round(float(np.median(u0)), 1),
                              "u1": round(float(np.median(u1)), 1),
                              "capped": bool(r["capped"][g].mean() > 0.5),
                              "ring": [[round(float(x), 2), round(float(z), 2)] for x, z in xz],
                              "ring_so": [[round(a, 1), round(b, 2)] for a, b in so]})
    polys.sort(key=lambda p: (p["s0"], p["side"]))
    return polys


# ---------- product ----------

def low_conf_stretches(s, edges, min_len=6.0):
    """[{side, s0, s1, length, reason}] of the flagged (interpolated) stretches."""
    out = []
    for key in ("left", "right"):
        f = edges["flag_" + key]
        occ = edges["occl_" + key]
        i, n = 0, len(f)
        while i < n:
            if not f[i]:
                i += 1
                continue
            j = i
            while j + 1 < n and f[j + 1]:
                j += 1
            if s[j] - s[i] + 2.0 >= min_len:
                reason = ("trees / shadow" if occ[i:j + 1].mean() > 0.25 else
                          "weak or ambiguous edge (junction, run-off, worn paint)")
                out.append({"side": key, "s0": round(float(s[i]), 1), "s1": round(float(s[j]), 1),
                            "length": round(float(s[j] - s[i] + 2.0), 1), "reason": reason})
            i = j + 1
    out.sort(key=lambda r: r["s0"])
    return out


def section_widths(s, edges, width_keys):
    """Median traced width per recipe [road] width_keys section (from one key to the next)."""
    w = edges["left"] + edges["right"]
    rows = []
    keys = [k for k in width_keys]
    for a, b in zip(keys, keys[1:] + [[s[-1] + 2.0, None, ""]]):
        sel = (s >= a[0]) & (s < b[0])
        if not sel.any():
            continue
        good = sel & ~edges["flag_left"] & ~edges["flag_right"]
        rows.append({"s0": a[0], "s1": b[0], "name": a[2], "recipe": a[1],
                     "traced_median": round(float(np.median(w[sel])), 2),
                     "traced_p10": round(float(np.percentile(w[sel], 10)), 2),
                     "traced_p90": round(float(np.percentile(w[sel], 90)), 2),
                     "confident_share": round(float(good.sum() / sel.sum()), 2)})
    return rows


# ---------- reader: the [road] widths of a build ----------

WIDTH_MEDIAN_M = 42.0      # running median of the traced width: junction mouths, gaps in a kerb
WIDTH_SIGMA_M = 6.0        # then a Gaussian, so the road edge has no step
WIDTH_CONF_M = 100.0       # window of the confident-edge share
WIDTH_CONF_LO, WIDTH_CONF_HI = 0.3, 0.5   # share at / under which the estimate is used, fully traced
WIDTH_RANGE = (6.5, 25.0)  # m: clamp (cad/track/banking.py allows 6-30 m)


def _smoothstep_keys(keys, s, length):
    """cad/track/banking.py interp_keys (cyclic smoothstep through (s, value[, note]) keys)."""
    ks = np.array([k[0] for k in keys], float)
    kv = np.array([k[1] for k in keys], float)
    ks, kv = np.append(ks, ks[0] + length), np.append(kv, kv[0])
    u = np.mod(np.asarray(s, float) - ks[0], length) + ks[0]
    j = np.clip(np.searchsorted(ks, u, side="right") - 1, 0, len(ks) - 2)
    t = (u - ks[j]) / (ks[j + 1] - ks[j])
    t = t * t * (3.0 - 2.0 * t)
    return kv[j] + (kv[j + 1] - kv[j]) * t


def road_width_keys(path, length, estimate_keys=None, n_points=None):
    """``[road] width_keys`` (one key per station) from an ``ortho_edges.json`` product, for
    ``[road] widths_from`` (lib/recipe.py). Returns (keys, info).

    The traced width (left + right edge, stations of track.json) goes through a running median
    of WIDTH_MEDIAN_M and a Gaussian of WIDTH_SIGMA_M. Where the edges are uncertain the recipe's
    own ``estimate_keys`` take over: the share of confident edges (two per station, an
    interpolated one counts 0) over WIDTH_CONF_M blends from the estimate (share <= 0.3) to the
    trace (>= 0.5), so a single side under trees, interpolated by trace_edges between confident
    stations, still counts as traced. ``info``: the blended stretches and the traced share."""
    from scipy.ndimage import gaussian_filter1d, median_filter, uniform_filter1d
    with open(path, encoding="utf-8") as f:
        st = json.load(f)["stations"]
    s = np.asarray(st["s"], float)
    if n_points is not None and len(s) != n_points:
        raise ValueError(f"{os.path.basename(path)} has {len(s)} stations, track.json {n_points} "
                         "points: trace it again on this centreline (python -m lib.ortho)")
    step = float(np.median(np.diff(s)))
    w = np.asarray(st["left"], float) + np.asarray(st["right"], float)
    good = (2 - np.asarray(st["flag_left"]) - np.asarray(st["flag_right"])) / 2.0
    share = uniform_filter1d(good, max(1, int(round(WIDTH_CONF_M / step))) | 1, mode="wrap")
    a = np.clip((share - WIDTH_CONF_LO) / (WIDTH_CONF_HI - WIDTH_CONF_LO), 0.0, 1.0)
    w = median_filter(w, max(3, int(round(WIDTH_MEDIAN_M / step))) | 1, mode="wrap")
    if estimate_keys:
        est = _smoothstep_keys(estimate_keys, s, length)
        w = est + (w - est) * a
    else:
        a = np.ones_like(a)
    w = np.clip(gaussian_filter1d(w, WIDTH_SIGMA_M / step, mode="wrap"), *WIDTH_RANGE)
    keys = [[round(float(x), 2), round(float(y), 3)] for x, y in zip(s, w) if x < length]
    blended, i, n = [], 0, len(s)
    while i < n:
        if a[i] < 1.0:
            j = i
            while j < n and a[j] < 1.0:
                j += 1
            blended.append([round(float(s[i]), 1), round(float(s[j - 1]), 1),
                            round(float(a[i:j].min()), 2)])
            i = j
        else:
            i += 1
    return keys, {"traced_share": round(float(a.mean()), 3), "blended": blended,
                  "range": [round(float(w.min()), 2), round(float(w.max()), 2)]}


def _r(a, nd=2):
    return [None if not np.isfinite(v) else round(float(v), nd) for v in np.asarray(a, float)]


def product(frame, edges, kerbs, kerb_segs, polys, width_keys=None):
    s = frame.s
    st = {"s": _r(s, 2)}
    for key in ("left", "right"):
        st[key] = _r(edges[key])
        st["conf_" + key] = _r(np.clip(edges["conf_" + key], 0, 1))
        st["flag_" + key] = [int(v) for v in edges["flag_" + key]]
        st["tarmac_" + key] = _r(edges["tarmac_" + key])
        st["line_" + key] = _r(edges["line_" + key])
        st["line_limited_" + key] = [int(v) for v in edges["runoff_" + key]]
    out = {
        "attribution": ATTRIBUTION,
        "source": "BD ORTHO 20 cm (WMS ORTHOIMAGERY.ORTHOPHOTOS.BDORTHO, EPSG:2154), resampled "
                  "into road-aligned strips at 5 cm; PCRS 5 cm is not open for the Sarthe",
        "frame": "offsets in track-frame metres along the left normal of the track.json "
                 "centreline: left > 0 is the distance to the left edge, right > 0 to the right "
                 "edge (driving direction); width = left + right",
        "edge_rule": "inner edge of a kerb or of coloured paint; the outer edge of the painted "
                     "edge line where asphalt continues more than %.1f m beyond it (tarmac "
                     "run-off, line_limited = 1); otherwise the asphalt / verge boundary. "
                     "flag = 1: low confidence (< %.1f), interpolated between confident "
                     "stations." % (RUNOFF_GAP, LOW_CONF),
        "stations": st,
        "kerbs": kerb_segs,
        "kerb_kinds": "red_white: striped (raised / sawtooth) kerb, colour = its paint; flat: "
                      "solid painted strip %.1f-%.1f m; sausage: yellow element <= %.1f m wide. "
                      "gap: m from the edge to the kerb's inner side." % (KERB_MIN_W, KERB_MAX_W,
                                                                          SAUSAGE_MAX_W),
        "runoff": [{k: v for k, v in p.items() if k != "ring_so"} for p in polys],
        "runoff_doc": "u0 / u1: metres outward from the kerb's outer edge (or from the edge "
                      "without kerb), like trackside_layouts RUNOFF; ring: outline [x, z] in the "
                      "track frame; capped: the surface runs past %d m (tarmac) / %d m (grass): "
                      "a road, car park or field, not a run-off." % (TARMAC_MAX, GRASS_MAX),
        "low_confidence": low_conf_stretches(s, edges),
    }
    if width_keys:
        out["sections"] = section_widths(s, edges, width_keys)
    return out


def profiles_cached(frame, mosaic, path, log=print):
    if path and os.path.exists(path):
        z = np.load(path)
        p = Profiles(frame.n, z["offs"])
        if len(z["valid"]) == frame.n:
            p.frac, p.stripe, p.lum, p.rgb, p.valid = (z["frac"], z["stripe"], z["lum"],
                                                       z["rgb"], z["valid"])
            return p
    p = build_profiles(frame, mosaic, log=log)
    if path:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        np.savez(path, frac=p.frac, stripe=p.stripe, lum=p.lum, rgb=p.rgb, valid=p.valid,
                 offs=p.offs)
    return p


def run(track_dir, out_path, qa_dir=None, cache=CACHE, profile_cache=None, width_keys=None,
        log=print):
    track, scale = load_track(track_dir)
    frame = Frame.from_track(track, scale)
    mosaic = Mosaic(cache)
    log("profiles (5 cm strip, classes per station)")
    prof = profiles_cached(frame, mosaic, profile_cache, log)
    log("edges")
    edges = trace_edges(prof, log=log)
    log("kerbs")
    ks = kerb_stations(prof, edges)
    segs = kerb_segments(frame.s, ks, frame.length)
    log(f"  {len(segs)} kerb segments")
    log("run-off")
    surf, roffs = runoff_surfaces(frame, mosaic, log=log)
    ro = runoff_stations(surf, roffs, edges, ks)
    polys = runoff_polygons(frame, frame.s, edges, ks, ro)
    log(f"  {len(polys)} run-off areas")
    prod = product(frame, edges, ks, segs, polys, width_keys)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(prod, f, separators=(",", ":"))
        f.write("\n")
    log(f"wrote {out_path} ({os.path.getsize(out_path) / 1e3:.0f} kB)")
    if qa_dir:
        os.makedirs(qa_dir, exist_ok=True)
        res = {"stations": {k: (np.asarray(v, float) if k != "s" else frame.s)
                            for k, v in edges.items() if not k.startswith("_")},
               "kerbs": segs, "runoff": polys}
        res["stations"]["s"] = frame.s
        a = 0.0
        while a < frame.length:
            p = os.path.join(qa_dir, f"qa_{int(a):05d}.png")
            qa_overlay(frame, mosaic, res, a, min(a + 500.0, frame.length), p)
            a += 500.0
        log(f"QA overlays in {qa_dir}")
    return prod, edges, segs, polys


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("track", help="track id (assets/tracks/<id>/)")
    ap.add_argument("--out", help="default assets/tracks/<id>/ortho_edges.json")
    ap.add_argument("--qa", help="directory for the QA overlays (one PNG per 500 m)")
    ap.add_argument("--profile-cache", help="npz cache of the per-station profiles")
    a = ap.parse_args(argv)
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(os.path.dirname(os.path.dirname(here)))
    tdir = os.path.join(root, "assets", "tracks", a.track)
    keys = None
    recipe = os.path.join(root, "tools", "track", "tracks", a.track + ".toml")
    if os.path.exists(recipe):
        import tomllib
        with open(recipe, "rb") as f:
            keys = tomllib.load(f).get("road", {}).get("width_keys")
    run(tdir, a.out or os.path.join(tdir, "ortho_edges.json"), a.qa,
        profile_cache=a.profile_cache, width_keys=keys)
    return 0


if __name__ == "__main__":
    sys.exit(main())
