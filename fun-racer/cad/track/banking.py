"""Road cross-section along the lap: per-s width and bank (crossfall / corner camber).

``profile()`` gives the ``bank`` and ``width`` the road mesh is built with. track.json keeps
``bank = 0`` and a nominal ``width``; the CAD road reads THESE values, and
``cad/track/road.py`` writes the expanded per-point result to
``assets/tracks/<id>/road_profile.json`` so Godot code (``scripts/track/road.gd``) can query
the exact surface.

Where the numbers come from, in this order:
  1. Key tables in the track's recipe (``[road] bank_keys`` / ``width_keys``): a surveyed or
     hand-estimated table replaces the automatic values completely. The Red Bull Ring uses
     this (tools/track/tracks/red_bull_ring.toml, which also carries the notes on its sources).
  2. Otherwise automatic defaults from the centreline curvature (below).
  3. ``[[road.override]]`` entries of the recipe then replace width and/or bank on single
     s ranges, blended in over ``blend`` metres.

Sign convention (same as the doc comment in scripts/track/track_data.gd):
    bank > 0  ->  the road rolls so its LEFT edge is higher (in race direction).
                  This is positive camber for a RIGHT-hand corner, and on a straight it
                  means the surface drains towards the right-hand edge.
    bank < 0  ->  right edge higher (positive camber for a left-hander).
Units: radians. For these small angles, radians == slope fraction (0.02 rad ~ 2 %).
The roll pivots about the centreline, so the centreline keeps the track.json height and
the edges move by +/- (width/2) * sin(bank).

Automatic defaults (estimates, NOT surveyed values)
---------------------------------------------------
* Crossfall on straights, 1.5 %: FIA International Sporting Code, Appendix O ("Circuit
  Regulations", Grade 1) requires a crossfall for drainage, typically 1.5 %-3 % on
  straights. A single slope (not a crown) is used so the racing surface has no ridge; it
  leans the way of the nearest corner, so it never has to flip in a braking zone.
* Corner camber: proportional to the curvature (CAMBER_GAIN: 2.5 % at a 100 m radius),
  capped at MAX_BANK. Real banked corners (Zandvoort's 18 degrees, ovals) are far steeper
  and cannot be represented yet, see "Hard limit".
* The grid drains LEFT (bank < 0): the pole slot is on the left (lateral -2.5 m) and
  Track.spawn_transform() uses the unbanked track.json frame, so a left side that is lower
  than the centreline lets the car drop a few cm onto the grid instead of starting with its
  left wheels inside the tarmac.
* Hard limit |bank| <= 0.03 rad: the terrain step places terrain at road-centre height
  - 0.3 m, so the low road edge (half width <= 8 m) must stay above -0.24 m.
* Widths: FIA Appendix O minimum is 12 m, and >= 15 m on the start straight for the grid.
  OSM rarely carries width tags for circuits, so the default is 13 m, widening to 15 m
  around the grid. Use ``[road] base_width`` / ``grid_width`` or overrides to change it.
"""

from __future__ import annotations

import numpy as np

MAX_BANK = 0.03          # rad, hard limit (see above)
BASE_WIDTH = 13.0        # m
GRID_WIDTH = 15.0        # m, start / finish straight
CROSSFALL = 0.015        # rad on straights
CAMBER_GAIN = 2.5        # rad of bank per 1/m of curvature (0.025 at R = 100 m)
CORNER_CURVATURE = 1.0 / 400.0   # above this the bank leans into the corner
GRID_BEHIND = 230.0      # m before the start line that is "the grid" (20 slots = 168 m)
GRID_AHEAD = 150.0       # m after it
GRID_BLEND = 80.0        # m


def interp_keys(keys: list, s: np.ndarray, length: float) -> np.ndarray:
    """Cyclic smoothstep interpolation of (s, value[, note]) keys at positions ``s``."""
    ks = np.array([k[0] for k in keys], dtype=float)
    kv = np.array([k[1] for k in keys], dtype=float)
    assert np.all(np.diff(ks) > 0.0) and ks[0] >= 0.0 and ks[-1] < length
    # Append the first key one lap later so the last span wraps.
    ks = np.append(ks, ks[0] + length)
    kv = np.append(kv, kv[0])
    u = np.mod(np.asarray(s, dtype=float) - ks[0], length) + ks[0]
    j = np.clip(np.searchsorted(ks, u, side="right") - 1, 0, len(ks) - 2)
    t = (u - ks[j]) / (ks[j + 1] - ks[j])
    t = t * t * (3.0 - 2.0 * t)
    return kv[j] + (kv[j + 1] - kv[j]) * t


def cyclic_smooth(a: np.ndarray, sigma_pts: float) -> np.ndarray:
    """Gaussian smoothing of a periodic array (sigma in samples); also used by road.py."""
    n = len(a)
    r = min(int(4 * sigma_pts), (n - 1) // 2)
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma_pts) ** 2)
    k /= k.sum()
    kk = np.zeros(n)
    kk[: r + 1] = k[r:]
    kk[-r:] = k[:r]
    return np.real(np.fft.ifft(np.fft.fft(a) * np.fft.fft(kk)))


def window(s: np.ndarray, a: float, b: float, blend: float, length: float) -> np.ndarray:
    """1 inside the cyclic range [a, b], falling smoothly to 0 ``blend`` metres outside it."""
    span = (b - a) % length if (b - a) % length > 0.0 else length
    mid = a + 0.5 * span
    d = np.abs(np.mod(np.asarray(s, dtype=float) - mid + 0.5 * length, length) - 0.5 * length) - 0.5 * span
    t = np.clip(1.0 - d / max(blend, 1e-6), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def default_width(s: np.ndarray, length: float, start_s: float, cfg: dict) -> np.ndarray:
    base = float(cfg.get("base_width", BASE_WIDTH))
    grid = float(cfg.get("grid_width", max(GRID_WIDTH, base)))
    return base + (grid - base) * window(s, start_s - GRID_BEHIND, start_s + GRID_AHEAD, GRID_BLEND, length)


def default_bank(s: np.ndarray, length: float, curvature: np.ndarray, start_s: float,
                 cfg: dict) -> np.ndarray:
    """Crossfall on straights, camber into corners (``curvature`` is + = left, per point)."""
    n = len(s)
    step = length / n
    crossfall = min(float(cfg.get("crossfall", CROSSFALL)), MAX_BANK)
    gain = float(cfg.get("camber_gain", CAMBER_GAIN))
    ks = cyclic_smooth(np.asarray(curvature, dtype=float), 15.0 / step)
    corner = np.abs(ks) >= CORNER_CURVATURE
    sign = np.where(ks < 0.0, 1.0, -1.0)          # right-hander: left edge higher
    if corner.any():
        # Straights lean the way of the nearest corner (cyclic nearest-neighbour fill).
        idx = np.flatnonzero(corner)
        pos = np.arange(n)
        j = np.searchsorted(idx, pos)
        before = idx[(j - 1) % len(idx)]
        after = idx[j % len(idx)]
        d_before = (pos - before) % n
        d_after = (after - pos) % n
        sign = np.where(corner, sign, np.where(d_before <= d_after, sign[before], sign[after]))
    else:
        sign = np.ones(n)
    bank = sign * np.clip(np.abs(ks) * gain, crossfall, MAX_BANK)
    # The grid drains left (see the module docstring).
    g = window(s, start_s - GRID_BEHIND, start_s + 40.0, 1.0, length) > 0.5
    bank = np.where(g, -crossfall, bank)
    return np.clip(cyclic_smooth(bank, 12.0 / step), -MAX_BANK, MAX_BANK)


def profile(s: np.ndarray, length: float, curvature: np.ndarray, start_s: float,
            cfg: dict | None = None) -> tuple[np.ndarray, np.ndarray]:
    """(bank [rad, + = left edge higher], full width [m]) at the distances ``s``."""
    cfg = cfg or {}
    s = np.asarray(s, dtype=float)
    if cfg.get("bank_keys"):
        bank = interp_keys(cfg["bank_keys"], s, length)
    else:
        bank = default_bank(s, length, curvature, start_s, cfg)
    if cfg.get("width_keys"):
        width = interp_keys(cfg["width_keys"], s, length)
    else:
        width = default_width(s, length, start_s, cfg)
    for o in cfg.get("override", []):
        w = window(s, float(o["s"][0]), float(o["s"][1]), float(o.get("blend", 40.0)), length)
        if "width" in o:
            width = width + (float(o["width"]) - width) * w
        if "bank" in o:
            bank = bank + (float(o["bank"]) - bank) * w
    if np.any(np.abs(bank) > MAX_BANK + 1e-9):
        raise ValueError(f"bank exceeds the hard limit of {MAX_BANK} rad (see cad/track/banking.py); "
                         "the terrain under the road is only 0.3 m below the centreline")
    if np.any(width < 6.0) or np.any(width > 30.0):
        raise ValueError("road width must stay within 6-30 m")
    return bank, width
