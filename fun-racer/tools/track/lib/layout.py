"""Plan-view corrections of the centreline: [[layout.shift]] and the ``separation`` of a
[[road.pair]].

OSM draws a road as one line somewhere near its middle. That is good to a few metres, which is
plenty for a lap on its own but not where two stretches of the lap run side by side: the two
carriageways of one avenue (Baku: Turn 6 to Turn 7 beside the main straight) come out 10 m
apart where the real ones, each 11 to 12 m wide with a wall between them, need 14 m. Both
corrections move the centreline sideways before the lap is scaled to its official length:

    [[layout.shift]]              a stretch moved bodily to one side
    s = [1200.0, 1500.0]          metres from the finish line (may wrap around it)
    lateral_m = 2.5               + = to the right in race direction
    blend = 60.0                  metres over which the shift fades in and out (default 60)

    [[road.pair]]                 two stretches that are the two halves of one road
    a = [2175.0, 2530.0]
    b = [4725.0, 5085.0]
    separation = 14.0             distance between the two centrelines: each is pushed away
                                  from the other, by the same amount, until they are this far
                                  apart (never pulled together)
    blend = 60.0                  metres over which the push fades in and out (default 60)

Plain Python floats like lib/geom.py; a recipe with neither builds exactly as before.
"""
import math

from . import geom

SHIFT_BLEND = 60.0     # m, default blend of a shift / a pair's separation
SHIFT_SIGMA = 10.0     # m, smoothing of the lateral offset along the lap (no kinks)
PAIR_REACH = 80.0      # m: a pair is "side by side" where the other stretch is this near


def _window(s, a, b, blend, length):
    """1 inside the cyclic range [a, b], falling smoothly to 0 ``blend`` metres outside it."""
    span = (b - a) % length
    t = (s - a) % length
    if t <= span:
        return 1.0
    d = min(t - span, length - t)
    if d >= blend:
        return 0.0
    u = 1.0 - d / blend
    return u * u * (3.0 - 2.0 * u)


def _rights(samples):
    """Unit vector to the right of the lap at every sample, (x, z) in the Godot frame."""
    n = len(samples)
    out = []
    for k in range(n):
        a, b = samples[k - 1], samples[(k + 1) % n]
        tx, tz = b[0] - a[0], b[1] - a[1]
        d = math.hypot(tx, tz) or 1.0
        out.append((-tz / d, tx / d))
    return out


def _stretch_indices(a, b, pad, step, n):
    length = n * step
    first = int(math.floor((a - pad) / step))
    count = int(math.ceil(((b - a) % length + 2.0 * pad) / step)) + 1
    return [(first + q) % n for q in range(min(count, n))]


def pair_offsets(samples, step, pairs):
    """Lateral offset (m, + = right) per sample that brings the two stretches of every pair
    with a ``separation`` that far apart."""
    n = len(samples)
    length = n * step
    right = _rights(samples)
    lat = [0.0] * n
    for p in pairs:
        if p.get("separation") is None:
            continue
        sep = float(p["separation"])
        blend = float(p.get("blend", SHIFT_BLEND))
        # Two stretches that follow each other closely along the lap (the legs of a hairpin):
        # the blends must not reach into each other, or a point would be measured against
        # its own road.
        between = min((p["b"][0] - p["a"][1]) % length, (p["a"][0] - p["b"][1]) % length)
        blend = min(blend, 0.4 * between)
        for own, other in ((p["a"], p["b"]), (p["b"], p["a"])):
            near = _stretch_indices(float(other[0]), float(other[1]), blend, step, n)
            for i in _stretch_indices(float(own[0]), float(own[1]), blend, step, n):
                q = samples[i]
                dist, foot = min((geom.seg_dist(samples[j], samples[(j + 1) % n], q) for j in near),
                                 key=lambda r: r[0])
                if dist >= sep or dist > PAIR_REACH or dist < 1e-6:
                    continue
                # Away from the other stretch, along this one's own normal.
                away = (q[0] - foot[0]) * right[i][0] + (q[1] - foot[1]) * right[i][1]
                w = _window(i * step, float(own[0]), float(own[1]), max(blend, 1e-6), length)
                lat[i] += math.copysign(0.5 * (sep - dist), away) * w
    return lat


def shift_offsets(n, step, shifts):
    """Lateral offset (m, + = right) per sample of the [[layout.shift]] entries."""
    length = n * step
    lat = [0.0] * n
    for o in shifts:
        a, b = float(o["s"][0]), float(o["s"][1])
        blend = float(o.get("blend", SHIFT_BLEND))
        for i in range(n):
            lat[i] += float(o["lateral_m"]) * _window(i * step, a, b, blend, length)
    return lat


def apply(samples, step, shifts, pairs, k_scale):
    """``samples`` (evenly spaced, unscaled) moved sideways by the recipe's shifts and pair
    separations, whose distances are in final lap metres (``k_scale`` = final / unscaled)."""
    n = len(samples)

    def unscale(v):
        return [x / k_scale for x in v]

    shifts = [{**o, "s": unscale(o["s"]), "blend": o.get("blend", SHIFT_BLEND) / k_scale,
               "lateral_m": o["lateral_m"] / k_scale} for o in shifts]
    pairs = [{**p, "a": unscale(p["a"]), "b": unscale(p["b"]), "blend": p.get("blend", SHIFT_BLEND) / k_scale,
              "separation": p["separation"] / k_scale} for p in pairs if p.get("separation") is not None]
    lat = [u + v for u, v in zip(shift_offsets(n, step, shifts), pair_offsets(samples, step, pairs))]
    if not any(lat):
        return samples, 0.0
    # The push of a pair stops abruptly where the stretches part. Carry it on for a little
    # (a running maximum) before rounding it off, so that the smoothing eats into the road
    # beyond the stretch and not into the stretch itself, which must reach its separation.
    r = int(round(2.5 * SHIFT_SIGMA / step))
    grown = []
    for i in range(n):
        near = [lat[(i + q) % n] for q in range(-r, r + 1)]
        grown.append(max(max(near), 0.0) + min(min(near), 0.0))
    lat = geom.gauss_periodic(grown, sigma=SHIFT_SIGMA / step)
    right = _rights(samples)
    moved = [(p[0] + r[0] * v, p[1] + r[1] * v) for p, r, v in zip(samples, right, lat)]
    return moved, max(abs(v) for v in lat) * k_scale
