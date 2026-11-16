"""Size report of a built track: what build_track.py --report prints.

Reads the files of a track folder (track.json, and road_profile.json / build_info.json when
they are there) and writes nothing. One row per turn and per straight between two turns, with
the figures a reference (circuit map, FIA documents, onboard footage with a gradient overlay)
can be checked against:

    s range and length, minimum radius, road width, bank, gradient, and the height at the
    entry, at the apex (the middle of a straight) and at the exit

then the lap totals, the OSM width tags (a hint, see lib/centreline.py) and the build's
warnings. Heights are metres above the finish line; gradients and bank are in per cent
(bank + = left edge higher); widths are the built ones (road_profile.json) when the road step
has run, else those of track.json.
"""
import json
import math
import os

from .net import BuildError

TURN_SHARE = 0.2          # a turn lasts while the curvature stays above this share of its peak
TURN_K_MIN = 1.0 / 800.0  # 1/m: straighter than this is not part of a turn
TURN_REACH = 150.0        # m: a turn never reaches further than this from its apex
STRAIGHT_MIN = 40.0       # m: shorter gaps between two turns get no row of their own
# Centreline wiggles on banked road. The banked surface is swept along the centreline, so where
# the centreline's heading wiggles the surface twists under a car that drives a smoother line:
# the tyre load swings by about v^2 sin(bank) times the curvature's back-and-forth (at 250 km/h
# on 18 deg, 0.005 1/m is 1 g). A low-downforce car leaves the road (a stock car on Chicagoland
# and Michigan before [layout] plan_sigma_m). A warning only: steady ramps into a turn are not
# counted, but a short slow track can carry a wiggle that does no harm.
WIGGLE_WINDOW = 30.0      # m: stretch over which the curvature's back-and-forth is measured
WIGGLE_SWING = 0.002      # 1/m: back-and-forth (half the total variation beyond the net change) to warn about
WIGGLE_BANK = 0.1         # rad: banked stretches only
WIGGLE_SPEED = 250.0 / 3.6   # m/s: speed at which the warning quotes the tyre-load swing


def _load(folder, name, required=False):
    path = os.path.join(folder, name)
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except OSError:
        if required:
            raise BuildError(f"{name} is missing in {folder}: build the track first") from None
        return {}


def _turn_extents(turns, curv, step, length):
    """[first point, last point] (not wrapped: first may be negative) of every turn: while the
    road keeps curving the turn's way, and never past the midpoint to the next apex."""
    n = len(curv)
    out = []
    for q, t in enumerate(turns):
        sgn = -1.0 if t["direction"] == "right" else 1.0      # curvature is + = left
        ia = int(round(t["s_apex"] / step)) % n
        peak = max(curv[(ia + j) % n] * sgn for j in range(-4, 5))
        thr = max(TURN_K_MIN, TURN_SHARE * peak)
        prev_gap = (t["s_apex"] - turns[q - 1]["s_apex"]) % length or length
        next_gap = (turns[(q + 1) % len(turns)]["s_apex"] - t["s_apex"]) % length or length
        back = fwd = 0
        while (back + 1) * step <= min(TURN_REACH, 0.5 * prev_gap) and curv[(ia - back - 1) % n] * sgn > thr:
            back += 1
        while (fwd + 1) * step <= min(TURN_REACH, 0.5 * next_gap) and curv[(ia + fwd + 1) % n] * sgn > thr:
            fwd += 1
        out.append((ia - back, ia + fwd, ia))
    return out


def banked_wiggles(curv, bank, step, window=WIGGLE_WINDOW, swing=WIGGLE_SWING, bank_min=WIGGLE_BANK):
    """Stretches of banked road whose centreline curvature goes back and forth: for every
    ``window`` of road banked at least ``bank_min`` rad all along, half the total variation of
    the curvature beyond its net change (0 on a steady ramp; the amplitude of a wiggle). Windows
    above ``swing`` are merged into stretches: [{"s": [from, to], "swing", "bank"}] (s may wrap
    past the lap length; bank in rad, the largest on the stretch)."""
    n = len(curv)
    w = max(2, int(round(window / step)))
    if n <= w:
        return []
    hits = []
    for i in range(n):
        idx = [(i + j) % n for j in range(w + 1)]
        if min(abs(bank[j]) for j in idx) < bank_min:
            continue
        tv = sum(abs(curv[idx[j + 1]] - curv[idx[j]]) for j in range(w))
        amp = 0.5 * (tv - abs(curv[idx[-1]] - curv[idx[0]]))
        if amp > swing:
            hits.append((i, amp))
    runs = []
    for i, amp in hits:
        if runs and i - runs[-1][1] <= 1:
            runs[-1][1], runs[-1][2] = i, max(runs[-1][2], amp)
        else:
            runs.append([i, i, amp])
    if len(runs) > 1 and runs[0][0] == 0 and runs[-1][1] == n - 1:   # one stretch across the line
        last = runs.pop()
        runs[0] = [last[0], runs[0][1] + n, max(last[2], runs[0][2])]
    return [{"s": [round(a * step, 1), round((b + w) * step, 1)], "swing": round(amp, 5),
             "bank": round(max(abs(bank[(a + j) % n]) for j in range(b - a + w + 1)), 4)}
            for a, b, amp in runs]


def wiggle_warning(wiggles, speed=WIGGLE_SPEED):
    """One warning line for banked_wiggles(), or None."""
    if not wiggles:
        return None
    def load_g(x):
        return speed * speed * math.sin(x["bank"]) * x["swing"] / 9.81
    worst = sorted(wiggles, key=load_g, reverse=True)[:3]
    return (f"the centreline wiggles on banked road ({len(wiggles)} stretch(es) where the curvature goes "
            f"back and forth by more than {WIGGLE_SWING:g} 1/m within {WIGGLE_WINDOW:g} m); worst: "
            + ", ".join(f"s = {x['s'][0]:.0f}..{x['s'][1]:.0f} {x['swing']:.4f} 1/m on "
                        f"{math.degrees(x['bank']):.0f} deg (tyre load swings ~{load_g(x):.1f} g at "
                        f"{speed * 3.6:.0f} km/h)" for x in worst)
            + ". The banked surface twists under the car; if a fast car gets light there, smooth "
            "the plan view ([layout] plan_sigma_m)")


def build(folder):
    """The report of the track in ``folder`` as a dict (see format_text for the layout)."""
    track = _load(folder, "track.json", required=True)
    profile = _load(folder, "road_profile.json")
    binfo = _load(folder, "build_info.json")
    pts = track["points"]
    n, step, length = len(pts), float(track["step"]), float(track["length"])
    y = [p["p"][1] for p in pts]
    grade = [p.get("grade", 0.0) for p in pts]
    curv = [p.get("curvature", 0.0) for p in pts]
    built = len(profile.get("width", [])) == n
    width = profile["width"] if built else [p.get("width", 13.0) for p in pts]
    bank = profile["bank"] if built else [p.get("bank", 0.0) for p in pts]

    def row(kind, ident, name, first, last, mid, radius):
        idx = [k % n for k in range(first, last + 1)]
        g = [grade[k] for k in idx]
        w = [width[k] for k in idx]
        b = [bank[k] for k in idx]
        k_max = max(abs(curv[k]) for k in idx)
        return {
            "kind": kind, "id": ident, "name": name,
            "s": [round((first % n) * step, 1), round((last % n) * step, 1)],
            "length": round((last - first) * step, 1),
            "min_radius": radius if radius is not None else (round(1.0 / k_max, 1) if k_max > 1e-5 else None),
            "width": [round(min(w), 2), round(max(w), 2)],
            "bank_pct": [round(100.0 * min(b), 2), round(100.0 * max(b), 2)],
            "grade_pct": [round(100.0 * min(g), 2), round(100.0 * max(g), 2)],
            "y": [round(y[first % n], 2), round(y[mid % n], 2), round(y[last % n], 2)],
        }

    turns = track.get("turns", [])
    rows = []
    if turns:
        ext = _turn_extents(turns, curv, step, length)
        for q, t in enumerate(turns):
            first, last, apex = ext[q]
            rows.append(row("turn", t["id"], t.get("name", ""), first, last, apex, t.get("min_radius")))
            nxt = ext[(q + 1) % len(turns)][0] + (n if q + 1 == len(turns) else 0)
            if (nxt - last) * step >= STRAIGHT_MIN:
                rows.append(row("straight", "", f"{t['id']} to {turns[(q + 1) % len(turns)]['id']}",
                                last, nxt, (last + nxt) // 2, None))
    else:
        rows.append(row("lap", "", "whole lap (no turn table)", 0, n - 1, n // 2, None))

    lo, hi = min(range(n), key=y.__getitem__), max(range(n), key=y.__getitem__)
    g_lo, g_hi = min(range(n), key=grade.__getitem__), max(range(n), key=grade.__getitem__)
    climb = sum(max(0.0, y[(k + 1) % n] - y[k]) for k in range(n))
    totals = {
        "length": length,
        "official_length": track.get("official_length", length),
        "direction": track.get("direction", ""),
        "turns": len(turns),
        "origin_elevation_m": track.get("origin_elevation_m"),
        "elevation_range": round(y[hi] - y[lo], 2),
        "lowest": {"y": round(y[lo], 2), "s": round(lo * step, 1)},
        "highest": {"y": round(y[hi], 2), "s": round(hi * step, 1)},
        "climb": round(climb, 1),
        "max_grade_pct": {"value": round(100.0 * grade[g_hi], 2), "s": round(g_hi * step, 1)},
        "min_grade_pct": {"value": round(100.0 * grade[g_lo], 2), "s": round(g_lo * step, 1)},
        "width": [round(min(width), 2), round(max(width), 2)],
        "width_source": "road_profile.json" if built else "track.json",
        "track_json_width": [round(min(p.get("width", 13.0) for p in pts), 2),
                             round(max(p.get("width", 13.0) for p in pts), 2)],
    }
    warnings = list(binfo.get("warnings", []))
    wiggles = banked_wiggles(curv, bank, step)
    if wiggle_warning(wiggles):
        warnings.append(wiggle_warning(wiggles))
    tj = totals["track_json_width"]
    if built and (abs(tj[0] - totals["width"][0]) > 0.05 or abs(tj[1] - totals["width"][1]) > 0.05):
        warnings.append(f"track.json says the road is {tj[0]:g} to {tj[1]:g} m wide, the road that is "
                        f"built is {totals['width'][0]:g} to {totals['width'][1]:g} m: the drivers plan "
                        "on the track.json widths (see [road] track_json_widths)")
    return {
        "id": binfo.get("id") or os.path.basename(os.path.normpath(folder)),
        "name": track.get("name", ""),
        "totals": totals,
        "rows": rows,
        "osm_width_tags": binfo.get("osm", {}).get("width_tags", []),
        "pairs": profile.get("pairs", []),
        "crossings": track.get("crossings", []),
        "banked_wiggles": wiggles,
        "warnings": warnings,
    }


def _span(v, fmt):
    lo, hi = fmt.format(v[0]), fmt.format(v[1])
    return lo if lo == hi else f"{lo}..{hi}"


def format_text(rep):
    """The report as a fixed-width table (plain text, pastes into a recipe comment or notes)."""
    t = rep["totals"]
    out = [f"{rep['id']}: {rep['name']}",
           f"lap {t['length']:.1f} m (official {t['official_length']:.0f} m), {t['direction']}, "
           f"{t['turns']} turns; finish line {t['origin_elevation_m']} m above sea level",
           f"elevation: range {t['elevation_range']:.2f} m (lowest {t['lowest']['y']:+.2f} m at s = "
           f"{t['lowest']['s']:.0f}, highest {t['highest']['y']:+.2f} m at s = {t['highest']['s']:.0f}), "
           f"total climb {t['climb']:.1f} m",
           f"gradient: steepest climb {t['max_grade_pct']['value']:+.1f} % at s = {t['max_grade_pct']['s']:.0f}, "
           f"steepest descent {t['min_grade_pct']['value']:+.1f} % at s = {t['min_grade_pct']['s']:.0f}",
           f"width: {_span(t['width'], '{:.1f}')} m ({t['width_source']}); track.json "
           f"{_span(t['track_json_width'], '{:.1f}')} m",
           "",
           f"{'':4} {'name':<24} {'s from':>7} {'s to':>7} {'len':>6} {'R min':>6} {'width m':>10} "
           f"{'bank %':>11} {'grade %':>12} {'y in':>7} {'y apex':>7} {'y out':>7}"]
    for r in rep["rows"]:
        radius = f"{r['min_radius']:.0f}" if r["min_radius"] is not None and r["min_radius"] < 9999 else "-"
        if r["kind"] == "straight":
            radius = "-" if r["min_radius"] is None or r["min_radius"] > 800 else radius
        out.append(f"{r['id']:<4} {r['name'][:24]:<24} {r['s'][0]:7.0f} {r['s'][1]:7.0f} {r['length']:6.0f} "
                   f"{radius:>6} {_span(r['width'], '{:.1f}'):>10} {_span(r['bank_pct'], '{:+.1f}'):>11} "
                   f"{_span(r['grade_pct'], '{:+.1f}'):>12} {r['y'][0]:+7.1f} {r['y'][1]:+7.1f} {r['y'][2]:+7.1f}")
    out.append("")
    if rep["osm_width_tags"]:
        for w in rep["osm_width_tags"]:
            out.append(f"OSM width tag: {w['width']:g} m from s = {w['s'][0]:.0f} to {w['s'][1]:.0f} "
                       f"({len(w['ways'])} way(s)); a hint, not applied")
    else:
        out.append("OSM width tags: none on the loop's ways (or the track was built before they were recorded)")
    for p in rep["pairs"]:
        out.append(f"pair: s = {p['a'][0]:.0f}..{p['a'][1]:.0f} beside s = {p['b'][0]:.0f}..{p['b'][1]:.0f}: "
                   f"centrelines {_span(p['separation'], '{:.1f}')} m apart, "
                   f"{_span(p['gap'], '{:.1f}')} m between the tarmac edges")
    for c in rep["crossings"]:
        out.append(f"crossover: s = {c['s_upper']:.0f} passes {c['clearance']:.1f} m above s = {c['s_lower']:.0f}")
    for w in rep["warnings"]:
        out.append(f"WARNING: {w}")
    return "\n".join(out)
