"""Turn detection and sector split from the smoothed centreline curvature.

Automatic detection (``detect``):
  1. Cut the lap into *lobes*: stretches where the curvature keeps one sign and stays above
     K_ON (radius < 667 m).
  2. Split a lobe in two where the curvature dips to about a third of the smaller of two
     peaks at least MIN_SEP apart and both halves are real corners (two corners joined by a
     gentle bend). A long sweeper whose radius merely wobbles stays one turn.
  3. Merge neighbouring same-direction *kinks* (each under KINK_MERGE_ANGLE, at most
     KINK_MERGE_GAP apart): a gentle bend drawn with few OSM nodes shows up as several bumps.
  4. Classify by the angle turned: >= CORNER_ANGLE is a corner, >= MIN_ANGLE a kink, less is
     noise. Corners always count. Kinks are added, biggest first, until the official turn
     count is reached (official numbering includes some flat-out kinks but not others, and no
     geometric rule can tell which; without an official count kinks of >= DEFAULT_KINK_ANGLE
     count).
  5. Number T1..Tn in lap order from the finish line; the apex is the curvature peak.

A recipe can name the detected turns, or pin the whole table (``pinned``).
"""
import math

K_ON = 0.0015             # 1/m: curvature that starts / ends a lobe
MIN_SEP = 60.0            # m between two apexes of one lobe for a split
SPLIT_RATIO = 0.35        # valley / lower peak below this splits a lobe
SPLIT_MIN_ANGLE = 25.0    # deg: both halves of a split must turn at least this much
KINK_MERGE_ANGLE = 12.0   # deg
KINK_MERGE_GAP = 80.0     # m
CORNER_ANGLE = 15.0       # deg
MIN_ANGLE = 4.0           # deg
DEFAULT_KINK_ANGLE = 10.0  # deg: kinks counted when there is no official turn count
PIN_WINDOW = 12.0         # m: a pinned turn's apex is the curvature peak this close to its `s`


def _lobes(curv):
    n = len(curv)
    start = next((i for i in range(n) if abs(curv[i]) < K_ON), 0)
    out, i = [], 0
    while i < n:
        j = (start + i) % n
        if abs(curv[j]) < K_ON:
            i += 1
            continue
        sgn = 1.0 if curv[j] > 0.0 else -1.0
        a = i
        while i < n and curv[(start + i) % n] * sgn >= K_ON:
            i += 1
        out.append([(start + q) % n for q in range(a, i)])
    return out


def _split(idx, curv, step):
    """Splits a lobe (list of sample indices) at pronounced curvature valleys."""
    if len(idx) * step < 2 * MIN_SEP:
        return [idx]
    v = [abs(curv[k]) for k in idx]
    sep = int(MIN_SEP / step)
    p = max(range(len(v)), key=lambda q: v[q])
    best = None
    for lo, hi in ((0, p - sep), (p + sep, len(v))):
        if hi - lo < 2:
            continue
        q = max(range(lo, hi), key=lambda t: v[t])
        a, b = (q, p) if q < p else (p, q)
        valley = min(range(a, b + 1), key=lambda t: v[t])
        if v[valley] <= SPLIT_RATIO * v[q] and (best is None or v[valley] / v[q] < best[0]):
            best = (v[valley] / v[q], valley)
    if best is None:
        return [idx]
    cut = best[1]
    left, right = idx[:cut], idx[cut:]
    deg = math.degrees(step)
    if sum(abs(curv[k]) for k in left) * deg < SPLIT_MIN_ANGLE or sum(abs(curv[k]) for k in right) * deg < SPLIT_MIN_ANGLE:
        return [idx]
    return _split(left, curv, step) + _split(right, curv, step)


def _describe(idx, curv, step, n):
    peak = max(idx, key=lambda k: abs(curv[k]))
    return {
        "first": idx[0], "last": idx[-1], "peak": peak,
        "sign": 1.0 if curv[peak] > 0.0 else -1.0,
        "angle": sum(abs(curv[k]) for k in idx) * math.degrees(step),
        "length": len(idx) * step,
    }


def detect(curv, step, names=None, official=None):
    """Automatic turn table. Returns {"turns": [...], "candidates": [...], "warnings": [...]}."""
    n = len(curv)
    length = n * step
    lobes = []
    for idx in _lobes(curv):
        for part in _split(idx, curv, step):
            lobes.append(_describe(part, curv, step, n))
    # Merge runs of neighbouring same-direction kinks.
    merged = []
    for lb in lobes:
        prev = merged[-1] if merged else None
        gap = ((lb["first"] - prev["last"]) % n) * step if prev else 1e9
        if (prev and prev["sign"] == lb["sign"] and gap <= KINK_MERGE_GAP
                and prev["angle"] < KINK_MERGE_ANGLE and lb["angle"] < KINK_MERGE_ANGLE):
            if abs(curv[lb["peak"]]) > abs(curv[prev["peak"]]):
                prev["peak"] = lb["peak"]
            prev["last"] = lb["last"]
            prev["angle"] += lb["angle"]
            prev["length"] = ((prev["last"] - prev["first"]) % n + 1) * step
            prev["merged"] = prev.get("merged", 1) + 1
        else:
            merged.append(dict(lb))
    cands = [m for m in merged if m["angle"] >= MIN_ANGLE]
    for c in cands:
        # A cluster of merged kinks has no single apex: use the middle of the bend.
        c["apex"] = (c["first"] + ((c["last"] - c["first"]) % n) // 2) % n if c.get("merged") else c["peak"]
        c["kind"] = "corner" if c["angle"] >= CORNER_ANGLE else "kink"
    corners = [c for c in cands if c["kind"] == "corner"]
    kinks = sorted((c for c in cands if c["kind"] == "kink"), key=lambda c: -c["angle"])
    warnings = []
    if official:
        chosen = corners + kinks[:max(0, official - len(corners))]
        if len(chosen) != official:
            warnings.append(
                f"turn detection found {len(chosen)} turns ({len(corners)} corners, {len(kinks)} kinks) "
                f"but the official count is {official}: check the plot and, if needed, pin the "
                "turns with [[turn]] entries (id, name, direction, s) in the recipe")
    else:
        chosen = corners + [k for k in kinks if k["angle"] >= DEFAULT_KINK_ANGLE]
    chosen.sort(key=lambda c: c["apex"])

    def summary(c):
        return {"s_apex": round(c["apex"] * step % length, 1),
                "direction": "left" if c["sign"] > 0.0 else "right",
                "angle_deg": round(c["angle"], 1), "kind": c["kind"],
                "min_radius": round(1.0 / max(abs(curv[c["peak"]]), 1e-4), 1)}

    turns = []
    for i, c in enumerate(chosen):
        name = (names[c["apex"]] if names else "") or f"Turn {i + 1}" + (" (kink)" if c["kind"] == "kink" else "")
        turns.append({"id": f"T{i + 1}", "name": name, "direction": "left" if c["sign"] > 0.0 else "right",
                      "s_apex": round(c["apex"] * step % length, 1),
                      "min_radius": round(1.0 / max(abs(curv[c["peak"]]), 1e-4), 1)})
    picked = {id(c) for c in chosen}
    return {"turns": turns, "warnings": warnings,
            "candidates": [dict(summary(c), used=id(c) in picked)
                           for c in sorted(cands, key=lambda c: c["apex"])]}


def pinned(curv, step, table):
    """Turn table from recipe entries {id, name, direction, s}: each apex is the curvature
    peak (in the turn's direction) within PIN_WINDOW of ``s``."""
    n = len(curv)
    out = []
    for t in table:
        sign = 1.0 if t["direction"] == "left" else -1.0
        lo, hi = float(t["s"]) - PIN_WINDOW, float(t["s"]) + PIN_WINDOW
        best, bs = 0.0, float(t["s"])
        for k in range(int(math.floor(lo / step)), int(hi / step) + 1):
            c = curv[k % n] * sign
            if c > best:
                best, bs = c, k * step
        out.append({"id": t["id"], "name": t.get("name") or f"Turn {t['id'][1:]}",
                    "direction": t["direction"], "s_apex": round(bs % (n * step), 1) % round(n * step, 1),
                    "min_radius": round(1.0 / max(best, 1e-4), 1)})
    return out


def apply_names(turns, table, warnings):
    """Names (and nothing else) from un-pinned recipe [[turn]] entries, matched by id."""
    by_id = {t["id"]: t for t in table}
    known = {t["id"] for t in turns}
    for tid in by_id:
        if tid not in known:
            warnings.append(f"recipe names turn {tid} but only {len(turns)} turns were detected")
    return [dict(t, name=by_id[t["id"]].get("name", t["name"])) if t["id"] in by_id else t for t in turns]


def sectors(curv, step, override=None):
    """[0, s1, s2]: where the three sectors begin. Default: 1/3 and 2/3 of the lap, moved to
    the nearest point that lies on a straight (no timing line in the middle of a corner)."""
    if override:
        return [0.0, round(float(override[0]), 1), round(float(override[1]), 1)]
    n = len(curv)
    length = n * step
    w = max(1, int(40.0 / step))
    # Worst curvature within +/- 40 m of each sample (sliding maximum on the closed lap).
    a = [abs(c) for c in curv]
    local = [max(a[(k + d) % n] for d in range(-w, w + 1)) for k in range(n)]
    out = [0.0]
    for frac in (1.0 / 3.0, 2.0 / 3.0):
        k0 = int(round(frac * n))
        reach = int(n / 8)
        span = range(k0 - reach, k0 + reach + 1)
        straight = [k for k in span if local[k % n] < 0.002]
        if straight:
            k = min(straight, key=lambda q: abs(q - k0))
        else:
            k = min(span, key=lambda q: (local[q % n], abs(q - k0)))
        out.append(round((k % n) * step, 1))
    if not out[1] < out[2]:
        out = [0.0, round(length / 3.0, 1), round(2.0 * length / 3.0, 1)]
    return out
