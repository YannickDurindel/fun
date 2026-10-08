"""Red Bull Ring road cross-section: per-s width and bank (crossfall / corner camber).

This table is the ``bank`` (and ``width``) override for the road mesh. track.json keeps
``bank = 0`` and ``width = 13`` (another unit owns it); the CAD road reads THESE values,
and ``cad/track/road.py`` writes the expanded per-point result to
``assets/tracks/red_bull_ring/road_profile.json`` so Godot code (``scripts/track/road.gd``)
can query the exact surface.

Sign convention (same as the doc comment in scripts/track/track_data.gd):
    bank > 0  ->  the road rolls so its LEFT edge is higher (in race direction).
                  This is positive camber for a RIGHT-hand corner, and on a straight it
                  means the surface drains towards the right-hand edge.
    bank < 0  ->  right edge higher (positive camber for a left-hander).
Units: radians. For these small angles, radians == slope fraction (0.02 rad ~ 2 %).
The roll pivots about the centreline, so the centreline keeps the track.json height and
the edges move by +/- (width/2) * sin(bank).

Values and sources
------------------
* Crossfall on straights, 1.5-2 %: FIA International Sporting Code, Appendix O
  ("Circuit Regulations", Grade 1) requires a crossfall for drainage, typically
  1.5 %-3 % on straights; modern Tilke-rebuilt circuits (the A1-Ring was rebuilt into the
  Red Bull Ring in 2010/11 and resurfaced in 2016) use about 1.5-2 % single-slope crossfall.
  Single slope (not a crown) is used so that the racing surface has no ridge.
* Start/finish straight drains LEFT (bank < 0): the pole slot is on the left (lateral
  -2.5 m) and Track.spawn_transform() uses the unbanked track.json frame, so a left side
  that is lower than the centreline lets the car drop a few cm onto the grid instead of
  starting with its left wheels inside the tarmac.
* Corner camber: the Red Bull Ring corners are essentially flat; there is no true banking
  anywhere on the lap (public descriptions only mention the elevation: about 63-65 m total,
  max +12 % up the hill to Remus and -9.3 % down; de.wikipedia.org/wiki/Red_Bull_Ring,
  motogp.com circuit guide, global.honda/en/F1/circuit/red-bull-ring/). We therefore model
  only a small positive camber of 2-3 % in T1, T4, Rindt (T8) and T9, keep the hairpin on the
  Remus crest nearly flat (2 %), and give the left-handers (T5/T6 Rauch, T7 Wuerth) the same with
  opposite sign. No public source gives exact per-corner camber, so these are realistic
  estimates within the Appendix O range, NOT surveyed values.
* Hard limit |bank| <= 0.03 rad: the terrain unit places terrain at road-centre height
  - 0.3 m, so the low road edge (half width <= 8 m) must stay above -0.24 m.
* Widths: FIA Appendix O minimum is 12 m, and >= 15 m on the start straight for the grid.
  OSM carries no width tags for the circuit and no public source lists per-section widths,
  so these are estimates within the FIA rules and the commonly quoted 12-15 m range:
  15 m on the start/finish straight, opening to 16 m through T1 and 15 m at Remus (T3)
  (the overtaking corners), 13-14.5 m on the climb and the T3-T4 straight, and 12.5-13 m
  through the twisty back section (T5-T7, described in previews as "flat but narrow").

Turn s-positions (apex, from track.json): T1 454, T2 749, T3 Remus 1395, T4 2202,
T5 2674, T6 Rauch 2814, T7 Wuerth 3100, T8 Rindt 3762, T9 3999, T10 4077. Lap 4318 m.
"""

from __future__ import annotations

import numpy as np

MAX_BANK = 0.03

# (s [m], bank [rad], note). Smoothstep-interpolated between consecutive keys, cyclic.
BANK_KEYS: list[tuple[float, float, str]] = [
    (0.0, -0.015, "start/finish straight + grid: 1.5 % crossfall draining left (see note)"),
    (340.0, -0.015, "braking for T1"),
    (430.0, 0.025, "T1 Niki Lauda: slight positive camber, uphill right"),
    (500.0, 0.025, "T1 exit"),
    (570.0, 0.018, "climb to Remus (T2 kink is flat out on crossfall)"),
    (1330.0, 0.018, "braking for Remus"),
    (1375.0, 0.020, "T3 Remus: hairpin on the crest, nearly flat"),
    (1420.0, 0.020, "Remus exit"),
    (1480.0, 0.018, "downhill straight to Schlossgold"),
    (2140.0, 0.018, "braking for T4"),
    (2185.0, 0.025, "T4 Schlossgold: positive camber, downhill right"),
    (2240.0, 0.025, "T4 exit"),
    (2300.0, 0.015, "gentle right towards T5"),
    (2500.0, 0.015, ""),
    (2610.0, -0.018, "crossfall flips to drain left for the left-hand section"),
    (2650.0, -0.025, "T5 kink / T6 Rauch: left-handers, positive camber"),
    (2830.0, -0.025, "Rauch exit"),
    (2900.0, -0.018, "short straight"),
    (2960.0, -0.025, "T7 Wuerth Kurve: long left"),
    (3110.0, -0.025, "Wuerth exit"),
    (3170.0, 0.015, "crossfall flips back: gentle right"),
    (3300.0, 0.018, "downhill run to Rindt"),
    (3700.0, 0.018, "approach to Rindt"),
    (3745.0, 0.030, "T8 Rindt: fast right, the most cambered corner"),
    (3830.0, 0.030, "Rindt exit"),
    (3890.0, 0.018, "short straight"),
    (3960.0, 0.025, "T9 Red Bull Mobile: positive camber"),
    (4020.0, 0.025, "T9 exit"),
    (4130.0, -0.015, "T10 onto the start/finish straight"),
]

# (s [m], full road width [m], note). Same interpolation.
WIDTH_KEYS: list[tuple[float, float, str]] = [
    (0.0, 15.0, "start/finish straight and grid"),
    (330.0, 15.0, "braking zone T1"),
    (420.0, 16.0, "T1 Niki Lauda opens up"),
    (500.0, 16.0, ""),
    (620.0, 13.5, "climb to Remus"),
    (1280.0, 13.5, ""),
    (1360.0, 15.0, "T3 Remus hairpin"),
    (1440.0, 15.0, ""),
    (1540.0, 13.5, "straight to Schlossgold"),
    (2120.0, 13.5, ""),
    (2180.0, 14.5, "T4 Schlossgold"),
    (2260.0, 14.5, ""),
    (2350.0, 13.0, "back section"),
    (2620.0, 12.5, "T5-T7: fast but narrow"),
    (3150.0, 12.5, ""),
    (3300.0, 13.0, "run to Rindt"),
    (3930.0, 13.0, ""),
    (3990.0, 14.0, "T9 Red Bull Mobile"),
    (4060.0, 14.0, ""),
    (4160.0, 15.0, "start/finish straight"),
]


def _interp(keys: list[tuple[float, float, str]], s: np.ndarray, length: float) -> np.ndarray:
    """Cyclic smoothstep interpolation of (s, value) keys at positions ``s``."""
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


def bank_at(s: np.ndarray, length: float) -> np.ndarray:
    """Bank in radians (+ = left edge higher) at distances ``s``."""
    b = _interp(BANK_KEYS, s, length)
    assert np.all(np.abs(b) <= MAX_BANK + 1e-9)
    return b


def width_at(s: np.ndarray, length: float) -> np.ndarray:
    """Full road width in metres at distances ``s``."""
    return _interp(WIDTH_KEYS, s, length)
