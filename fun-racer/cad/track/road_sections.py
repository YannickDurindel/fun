"""Measured road cross-sections: the road surface from a lidar height grid.

Used by cad/track/road.py when the recipe says ``[road] sections = "lidar"``; every other
track never reaches this module and builds exactly as before (analytic crossfall / banking
from cad/track/banking.py).

Input: the lidar road grid of the track, ``lidar_road.json`` + ``lidar_road.bin`` in the build
output folder (or in assets/tracks/<id>/), as tools/track/lib/lidar.py writes it (0.25 m cells,
40 m either side of the lap, NaN where the lidar has no ground; its docstring has the format).
It is read with lib.lidar.Grid, whose ``y(x, z)`` is a NaN-aware bilinear sample in the
track.json frame.

Section model
-------------
Every centreline point (2 m apart) is sampled at columns across the road no more than
COLUMN_SPACING (0.5 m) apart, at the same fractions of the local half width everywhere, and the
road mesh takes every MESH_EVERY-th of them (no more than MESH_SPACING = 1 m apart, the centre
and both edges always included: a regular grid whose consecutive sections join quad by quad;
between two mesh columns the fitted section deviates from the straight line by a few mm at
most, and the road has half the triangles of a 0.5 m mesh). Column k of point i sits at

    lateral l = u_k * hw_i,  u_k = -1 + 2 k / (K - 1)
    vertex    = p_i + Rh_i * l + UP * xsec[i][k]

with Rh the horizontal right vector of the section frame (cad/track/road.py) and xsec the
height of the road surface above the centreline point, measured.

The fit, per point:
  1. sample the grid at every column on a small patch (ALONG offsets along the road, JITTER
     across), each sample relative to the centreline continued along its tangent, so the grade
     drops out; the median of the patch is the column's raw height;
  2. a robust smoothing of the column heights across the road: penalised least squares on the
     second differences (a Whittaker smoother, SMOOTH), re-weighted with Tukey's biweight so a
     parked car, a kerb artefact or a hole does not pull the section; columns without data get
     no weight and are bridged by the smoother. This keeps a crown or a drainage break (a kink
     between two columns) to within a few millimetres while the noise of the grid averages out;
  3. physically implausible slopes are clamped from the centre outward (|dh/dl| <= MAX_SLOPE
     between neighbouring columns), the section's offset at the centre to MAX_CENTRE;
  4. a point whose patch has too little data (CUT_COVERAGE), or whose measured centre is more
     than CUT_CENTRE from the centreline (a bridge deck the lidar does not see, a cutting the
     centreline does not follow), is not measured. A gap of at most GAP_BRIDGE metres takes
     the sections on either side, interpolated along the lap (a deck or a hole has the road's
     own shape); a longer one keeps the analytic section of banking.py, blended with the
     measured ones over BLEND_POINTS points either side, so the road never steps.
The heights are rounded to the millimetre before the mesh is built and written to
road_profile.json ("xsec"), so the game's surface queries (scripts/track/road.gd) see the very
same numbers as the mesh and its collision.

The profile's "bank" becomes the measured section's mean cross slope (least squares over the
road, + = left edge higher), which is what the trackside's frame, the terrain corridor and the
reports read; the terrain stays at least TERRAIN_ROOM below the measured surface (a section
is never let more than that below the plane of its bank).
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

COLUMN_SPACING = 0.5    # m: largest lateral distance between two sampled columns of a section
MESH_SPACING = 1.0      # m: largest lateral distance between two mesh columns
MESH_EVERY = int(round(MESH_SPACING / COLUMN_SPACING))   # sampled columns per mesh column
ALONG = (-1.0, -0.75, -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0)   # m along the road: the sample patch
JITTER = (-0.125, 0.0, 0.125)           # m across the road
SMOOTH = 0.2            # Whittaker penalty on second differences (columns are ~0.5 m apart)
TUKEY_C = 4.685         # biweight constant, in units of the robust residual scale
MIN_SCALE = 0.01        # m: floor of the robust residual scale (the grid's own noise)
MAX_SLOPE = 0.12        # |dh/dl| between neighbouring columns: steeper is a data artefact
MAX_CENTRE = 0.15       # m: largest kept height of the section's centre above / below the centreline
CUT_CENTRE = 0.5        # m: a measured centre farther than this is not this road (bridge, cutting)
CUT_COVERAGE = 0.6      # fraction of the columns with data below which the point is not measured
GAP_BRIDGE = 150.0      # m: a gap in the measurement up to this long is interpolated across
BLEND_POINTS = 12       # points (24 m) over which measured and analytic sections blend
TERRAIN_ROOM = 0.2      # m: the section never dips more than this below its bank plane
                        # (tools/track/lib/terrain.py keeps the ground CLEARANCE = 0.3 m under it)
GRID_JSON = "lidar_road.json"
GRID_BIN = "lidar_road.bin"


class RoadGrid:
    """The lidar road grid (tools/track/lib/lidar.py): ``sample(x, z)`` = height in the track
    frame (track.json's y), NaN where there is no ground."""

    def __init__(self, grid):
        self.grid = grid

    @classmethod
    def find(cls, out_dir: Path, track_id: str | None, tracks_dir: Path) -> "RoadGrid":
        """The grid of the build folder, else of assets/tracks/<id>/. Raises FileNotFoundError."""
        for folder in [Path(out_dir)] + ([Path(tracks_dir) / track_id] if track_id else []):
            if (folder / GRID_JSON).exists() and (folder / GRID_BIN).exists():
                return cls.load(folder)
        raise FileNotFoundError(f"[road] sections = \"lidar\" needs {GRID_JSON} and {GRID_BIN} in "
                                f"{out_dir}" + (f" or {Path(tracks_dir) / track_id}" if track_id else "")
                                + " (the lidar grids of tools/track/lib/lidar.py)")

    @classmethod
    def load(cls, folder: Path) -> "RoadGrid":
        return cls(lidar_module().Grid.load(str(Path(folder) / GRID_JSON)))

    def sample(self, x: np.ndarray, z: np.ndarray) -> np.ndarray:
        return self.grid.y(np.asarray(x, dtype=np.float64), np.asarray(z, dtype=np.float64))


def lidar_module():
    """tools/track/lib/lidar.py (tools/track is on the path in the pipeline; added if not)."""
    try:
        from lib import lidar
    except ImportError:
        sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools" / "track"))
        from lib import lidar
    return lidar


def columns(hw: np.ndarray) -> np.ndarray:
    """Fractions u_k of the half width (-1 .. 1, odd count) of the mesh columns."""
    k = 2 * int(np.ceil(float(np.max(hw)) / MESH_SPACING - 1e-9)) + 1
    return np.linspace(-1.0, 1.0, max(k, 3))


def sample_columns(hw: np.ndarray) -> np.ndarray:
    """Fractions of the sampled columns: the mesh columns and MESH_EVERY - 1 between each two."""
    k = len(columns(hw))
    return np.linspace(-1.0, 1.0, (k - 1) * MESH_EVERY + 1)


def _whittaker_robust(y: np.ndarray, w0: np.ndarray, lam: float, iters: int = 4) -> np.ndarray:
    """Robust Whittaker smoothing of every row of ``y`` (rows with weights ``w0``, 0 = no data)."""
    n, k = y.shape
    d = np.diff(np.eye(k), 2, axis=0)
    pen = lam * d.T @ d
    yz = np.where(w0 > 0, y, 0.0)
    w = w0.copy()
    fit = np.zeros_like(y)
    for it in range(iters + 1):
        a = pen[None, :, :] + w[:, :, None] * np.eye(k)[None, :, :]
        fit = np.linalg.solve(a + 1e-9 * np.eye(k)[None], (w * yz)[..., None])[..., 0]
        if it == iters:
            break
        r = np.where(w0 > 0, y - fit, np.nan)
        scale = np.maximum(1.4826 * np.nanmedian(np.abs(r), axis=1), MIN_SCALE)
        t = np.nan_to_num(r / (TUKEY_C * scale[:, None]), nan=2.0)
        w = w0 * np.where(np.abs(t) < 1.0, (1.0 - t * t) ** 2, 0.0)
        # A row whose weights all vanished keeps its data weights (nothing better to go on).
        dead = w.sum(1) < 1e-9
        w[dead] = w0[dead]
    return fit


def _clamp_slopes(h: np.ndarray, lat: np.ndarray) -> np.ndarray:
    """Limits |dh/dl| between neighbouring columns to MAX_SLOPE, from the centre column out."""
    out = h.copy()
    c = h.shape[1] // 2
    for k in range(c + 1, h.shape[1]):
        dl = np.abs(lat[:, k] - lat[:, k - 1])
        out[:, k] = out[:, k - 1] + np.clip(h[:, k] - h[:, k - 1], -MAX_SLOPE * dl, MAX_SLOPE * dl)
    for k in range(c - 1, -1, -1):
        dl = np.abs(lat[:, k + 1] - lat[:, k])
        out[:, k] = out[:, k + 1] + np.clip(h[:, k] - h[:, k + 1], -MAX_SLOPE * dl, MAX_SLOPE * dl)
    return out


def _cyclic_window_min(a: np.ndarray, r: int) -> np.ndarray:
    return np.min(np.stack([np.roll(a, k) for k in range(-r, r + 1)]), axis=0)


def _cyclic_box(a: np.ndarray, r: int) -> np.ndarray:
    return np.mean(np.stack([np.roll(a, k) for k in range(-r, r + 1)]), axis=0)


def raw_columns(grid: RoadGrid, P: np.ndarray, T: np.ndarray, Rh: np.ndarray, lat: np.ndarray):
    """Median height (above the centreline continued along its tangent) of the sample patch
    of every column, and the fraction of the patch with data. Shapes (n, K)."""
    n, k = lat.shape
    vals = []
    for a in ALONG:
        for j in JITTER:
            # The jitter stays on the road: the edge column must not average in the verge.
            lj = np.clip(lat + j, lat[:, :1], lat[:, -1:])
            q = P[:, None, :] + T[:, None, :] * a + Rh[:, None, :] * lj[:, :, None]
            ref = P[:, None, 1] + T[:, None, 1] * a
            vals.append(grid.sample(q[..., 0], q[..., 2]) - ref)
    v = np.stack(vals)                                   # (patch, n, K)
    cover = np.isfinite(v).mean(0)
    with np.errstate(all="ignore"):
        med = np.nanmedian(np.where(np.isfinite(v), v, np.nan), axis=0) if np.isfinite(v).any() \
            else np.full((n, k), np.nan)
    return med, cover


def fit(grid: RoadGrid, P: np.ndarray, T: np.ndarray, Rh: np.ndarray, hw: np.ndarray,
        bank: np.ndarray) -> dict:
    """Measured sections of the road (see the module docstring). ``bank`` is the analytic bank
    of banking.py, kept where the grid cannot say. Returns {"u": fractions (K,), "xsec": (n, K)
    heights above the centreline point (mm-rounded), "bank": the sections' mean cross slope as
    a bank (rad), "measured": weight of the measurement per point (0..1, 0 where interpolated or
    analytic), "stats": {...}}."""
    n = len(P)
    u = sample_columns(hw)
    lat = hw[:, None] * u[None, :]
    raw, cover = raw_columns(grid, P, T, Rh, lat)
    has = np.isfinite(raw) & (cover > 0.0)
    w0 = np.where(has, cover, 0.0)
    smooth = _whittaker_robust(np.nan_to_num(raw), w0, SMOOTH)
    smooth = _clamp_slopes(smooth, lat)
    centre = smooth[:, len(u) // 2]
    coverage = has.mean(1)
    ok = (coverage >= CUT_COVERAGE) & (np.abs(centre) <= CUT_CENTRE) & has[:, len(u) // 2]
    # Keep the centre near the centreline: the whole section moves with it.
    shift = np.clip(centre, -MAX_CENTRE, MAX_CENTRE) - centre
    measured = smooth + shift[:, None]
    analytic = -lat * np.sin(bank)[:, None]
    step = float(np.median(np.linalg.norm(np.roll(P, -1, 0) - P, axis=1)))
    keep = ok.copy()                     # measured, or interpolated across a short gap
    if ok.any() and not ok.all():
        start = int(np.argmax(ok))       # walk the lap from a measured point
        i = 0
        while i < n:
            j = (start + i) % n
            if ok[j]:
                i += 1
                continue
            k = i
            while k < n and not ok[(start + k) % n]:
                k += 1
            run = (start + np.arange(i, k)) % n
            if len(run) * step <= GAP_BRIDGE:
                a, b = (start + i - 1) % n, (start + k) % n
                t = ((np.arange(len(run)) + 1.0) / (len(run) + 1.0))[:, None]
                measured[run] = (1.0 - t) * measured[a] + t * measured[b]
                keep[run] = True
            i = k
    weight = _cyclic_box(_cyclic_window_min(keep.astype(float), BLEND_POINTS), BLEND_POINTS)
    weight = np.where(keep, weight, 0.0) if not keep.all() else np.ones(n)
    measured = np.where(keep[:, None], measured, analytic)
    xsec = weight[:, None] * measured + (1.0 - weight[:, None]) * analytic
    # Mean cross slope (least squares through the section) -> bank, + = left edge higher.
    lc = lat - lat.mean(1, keepdims=True)
    slope = (lc * (xsec - xsec.mean(1, keepdims=True))).sum(1) / np.maximum((lc * lc).sum(1), 1e-9)
    fbank = -np.arctan(slope)
    # Never dip more than TERRAIN_ROOM under the bank plane, which the terrain corridor follows.
    xsec = np.maximum(xsec, -lat * np.sin(fbank)[:, None] - TERRAIN_ROOM)
    # The mesh columns; what the mesh shows at every sampled column (straight between them).
    mesh = np.round(xsec[:, ::MESH_EVERY], 3)
    shown = np.repeat(mesh[:, :-1], MESH_EVERY, axis=1)
    frac = np.tile(np.arange(MESH_EVERY) / MESH_EVERY, mesh.shape[1] - 1)[None, :]
    shown = np.concatenate([shown + frac * (np.repeat(mesh[:, 1:], MESH_EVERY, axis=1) - shown),
                            mesh[:, -1:]], axis=1)
    resid = np.where(has, raw - shown, np.nan)
    stats = {
        "columns": int(mesh.shape[1]),
        "sampled_columns": int(len(u)),
        "measured_points": int(ok.sum()),
        "interpolated_points": int((keep & ~ok).sum()),
        "fallback_points": int((~keep).sum()),
        "coverage": round(float(has.mean()), 4),
        "rms_vs_patch_median_m": round(float(np.sqrt(np.nanmean(resid[ok] ** 2))) if ok.any() else 0.0, 4),
        "p99_vs_patch_median_m": round(float(np.nanpercentile(np.abs(resid[ok]), 99)) if ok.any() else 0.0, 4),
        "centre_clamped": int((np.abs(shift) > 1e-9).sum()),
        "bank_range": [round(float(fbank.min()), 4), round(float(fbank.max()), 4)],
    }
    return {"u": u[::MESH_EVERY], "xsec": mesh, "bank": fbank, "measured": np.where(ok, weight, 0.0), "stats": stats}
