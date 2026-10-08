#!/usr/bin/env python3
"""Generates the synthetic test track tests/fixtures/tracks/test_oval/ (track.json +
track_info.json): a ~615 m clockwise kidney-shaped oval on a gentle hillside.

The folder deliberately has NOTHING else (no road_mesh.glb, road_profile.json, terrain.json,
trackside_profiles.json, hand-made trackside table), so the generic track scene has to use
every runtime fallback. See tests/test_generic_track.gd.

Layout (start/finish on the top straight, heading east; x = east, z = -north):
  T1  right 180 deg, R 40   (end of the longest straight -> heavy braking)
  T2  right  30 deg, R 40   \
  T3  left   60 deg, R 40    > the dent of the kidney on the back straight
  T4  right  30 deg, R 40   /
  T5  right  90 deg, R 22   (tight: sausage kerb)
  T6  right  90 deg, R 22

Usage: python3 tests/fixtures/tracks/make_test_oval.py
"""
import json
import math
import os

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_oval")
WIDTH = 12.0
START_S = 30.0

# (length m, signed curvature 1/m: + = right turn, turn name or None)
R_END, R_DENT, R_TIGHT = 40.0, 40.0, 22.0
SEGMENTS = [
    (80.0, 0.0, None),
    (math.pi * R_END, 1.0 / R_END, "East Loop"),
    (60.0, 0.0, None),
    (math.radians(30.0) * R_DENT, 1.0 / R_DENT, "Dent In"),
    (math.radians(60.0) * R_DENT, -1.0 / R_DENT, "Dent"),
    (math.radians(30.0) * R_DENT, 1.0 / R_DENT, "Dent Out"),
    (50.0, 0.0, None),
    (math.pi / 2.0 * R_TIGHT, 1.0 / R_TIGHT, "West One"),
    (2.0 * R_END - 2.0 * R_TIGHT, 0.0, None),
    (math.pi / 2.0 * R_TIGHT, 1.0 / R_TIGHT, "West Two"),
    (110.0, 0.0, None),
]


def height(x: float, z: float) -> float:
    """A tilted hillside with a soft roll; 0 at the finish line (origin)."""
    return 0.03 * x - 0.015 * z + 1.5 * math.sin(x / 45.0) * math.cos(z / 60.0)


def plan_at(s: float):
    """(x, z, heading, curvature) at distance s; heading 0 = east, + = turning right."""
    x = z = h = 0.0
    for length, k, _name in SEGMENTS:
        d = min(s, length)
        if abs(k) < 1e-12:
            x += d * math.cos(h)
            z += d * math.sin(h)
        else:
            x += (math.sin(h + k * d) - math.sin(h)) / k
            z += (math.cos(h) - math.cos(h + k * d)) / k
            h += k * d
        if s <= length:
            return x, z, h, k
        s -= length
    return x, z, h, 0.0


def main() -> None:
    total = sum(seg[0] for seg in SEGMENTS)
    ex, ez, eh, _ = plan_at(total)
    assert math.hypot(ex, ez) < 1e-6 and abs(eh - 2.0 * math.pi) < 1e-9, "the lap does not close"
    n = round(total / 2.0)
    step = total / n
    points = []
    for i in range(n):
        s = i * step
        x, z, h, k = plan_at(s)
        x2, z2, _, _ = plan_at((s + 0.5) % total)
        x1, z1, _, _ = plan_at((s - 0.5) % total)
        points.append({
            "s": round(s, 3),
            "p": [round(x, 3), round(height(x, z), 3), round(z, 3)],
            "width": WIDTH,
            "bank": 0.0,
            "grade": round(height(x2, z2) - height(x1, z1), 4),
            "curvature": round(k, 5),
        })
    turns = []
    s0 = 0.0
    for length, k, name in SEGMENTS:
        if name is not None:
            turns.append({"id": "T%d" % (len(turns) + 1), "name": name,
                          "direction": "right" if k > 0.0 else "left",
                          "s_apex": round(s0 + 0.5 * length, 1), "min_radius": round(1.0 / abs(k), 1)})
        s0 += length
    ys = [p["p"][1] for p in points]
    track = {
        "name": "Test Oval (synthetic fixture)",
        "length": round(total, 3),
        "closed": True,
        "direction": "clockwise",
        "frame": "Godot metres: x=east, y=up (relative to finish line), z=-north; origin at finish line",
        "step": step,
        "start_s": START_S,
        "finish_s": 0.0,
        "sectors": [0.0, round(total / 3.0, 1), round(2.0 * total / 3.0, 1)],
        "turns": turns,
        "elevation_range": round(max(ys) - min(ys), 2),
        "points": points,
        "attribution": "Synthetic: tests/fixtures/tracks/make_test_oval.py",
    }
    info = {
        "id": "test_oval",
        "name": "Test Oval",
        "grand_prix": "Fixture Grand Prix",
        "country": "Nowhere",
        "country_code": "",
        "city": "",
        "length_m": round(total),
        "turns": len(turns),
        "available": True,
    }
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "track.json"), "w") as f:
        json.dump(track, f, separators=(",", ":"))
        f.write("\n")
    with open(os.path.join(OUT_DIR, "track_info.json"), "w") as f:
        json.dump(info, f, indent=2)
        f.write("\n")
    print("test_oval: %.1f m, %d points, step %.4f m, %d turns, elevation range %.1f m"
          % (total, n, step, len(turns), track["elevation_range"]))


if __name__ == "__main__":
    main()
