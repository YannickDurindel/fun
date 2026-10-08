"""Cross-section profiles for the Red Bull Ring trackside: kerbs, armco and walls.

Regenerate with one command (from the repo root):

    .venv/bin/python cad/track/trackside_profiles.py

The profiles are modelled as build123d 2D faces in a (u, h) plane and written to
``assets/tracks/red_bull_ring/trackside_profiles.json``. Godot sweeps them along
the centreline-derived edge curves at runtime (``scripts/track/trackside.gd``),
so the geometry follows whatever road widths / banking TrackData reports.

Profile frame (metres):
    u = lateral distance measured OUTWARD, away from the racing surface
        (kerbs: u = 0 is the road edge; barriers: u = 0 is the barrier line,
        the face that the cars hit)
    h = height above the road surface plane (extended sideways)

Kerb design rules (so kerbs never launch the car):
    * the driving-side edge starts flush (h <= 5 mm) and ramps up smoothly,
    * no face steeper than ~30 deg is taller than 3 cm on the driving side,
    * the peak height stays within 2-5 cm.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

from build123d import (
    BuildSketch,
    Face,
    GeomType,
    Locations,
    Mode,
    Polyline,
    Rectangle,
    Spline,
    Vector,
    fillet,
    make_face,
    BuildLine,
)

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "tracks" / "red_bull_ring" / "trackside_profiles.json"

BASE = -0.05  # bottom of the closed kerb faces; dropped from the exported top polyline


# ----------------------------------------------------------------------------- helpers
def _face_from_points(pts: list[tuple[float, float]], fillet_r: float = 0.0,
                      fillet_min_h: float = 0.0) -> Face:
    """Closed polygon face in the XY plane (x = u, y = h), optional top fillets."""
    with BuildSketch() as sk:
        with BuildLine():
            Polyline(*pts, close=True)
        make_face()
        if fillet_r > 0.0:
            verts = [v for v in sk.vertices() if v.Y > fillet_min_h]
            fillet(verts, fillet_r)
    return sk.sketch.faces()[0]


def _outline(face: Face, arc_segments: int = 6) -> list[tuple[float, float]]:
    """Discretise a face's outer wire into (u, h) points (arcs/splines sampled)."""
    out: list[tuple[float, float]] = []
    for e in face.outer_wire().order_edges():
        if e.geom_type == GeomType.LINE:
            ts = [0.0]
        else:
            ts = [i / arc_segments for i in range(arc_segments)]
        for t in ts:
            p = e.position_at(t)
            out.append((round(p.X, 4), round(p.Y, 4)))
    return out


def _top(face: Face, arc_segments: int = 6) -> list[list[float]]:
    """Upper surface of a kerb face, sorted from the road side outward."""
    pts = [p for p in _outline(face, arc_segments) if p[1] > BASE + 1e-4]
    out: list[list[float]] = []
    for u, h in sorted(set(pts)):
        if out and u - out[-1][0] < 0.01:  # merge near-duplicate fillet points
            continue
        out.append([u, h])
    return out


def _check_kerb(name: str, top: list[list[float]]) -> None:
    assert top[0][1] <= 0.006, f"{name}: driving-side edge must start flush"
    peak = max(h for _, h in top)
    assert 0.02 <= peak <= 0.055, f"{name}: peak {peak:.3f} m outside 2-5 cm"
    for (u0, h0), (u1, h1) in zip(top, top[1:]):
        rise = h1 - h0
        if rise > 0.0 and u1 - u0 < 1e-6:
            raise AssertionError(f"{name}: vertical rise at u={u0}")
        if rise > 0.0 and math.degrees(math.atan2(rise, u1 - u0)) > 30.0:
            assert rise <= 0.03, f"{name}: steep face {rise:.3f} m at u={u0}"


# ----------------------------------------------------------------------------- kerbs
def kerb_flat() -> dict:
    """Plain red/white kerb, 1.5 m wide, 2.5 cm high with a 25 cm lead-in ramp."""
    pts = [(-0.05, BASE), (-0.05, 0.004), (0.25, 0.025), (1.30, 0.025),
           (1.50, 0.004), (1.50, BASE)]
    f = _face_from_points(pts)
    top = _top(f)
    _check_kerb("kerb_flat", top)
    return {"top": top, "width": 1.5, "ripple_amp": 0.0, "ripple_period": 2.0,
            "stripe": 1.0, "area_m2": round(f.area, 5)}


def kerb_sawtooth() -> dict:
    """Red Bull Ring style serrated kerb: a lead-in ramp then three rounded ridges
    (the 'sausage-style' rumble) and a 1 m along-track ripple that matches the
    stripe length, so the car feels a bump per stripe."""
    pts = [(-0.05, BASE), (-0.05, 0.004), (0.30, 0.028)]
    u = 0.30
    for _ in range(3):  # ridges
        pts += [(u + 0.12, 0.042), (u + 0.24, 0.042), (u + 0.36, 0.028)]
        u += 0.36
    pts += [(1.55, 0.030), (1.80, 0.004), (1.80, BASE)]
    f = _face_from_points(pts)
    top = _top(f)
    _check_kerb("kerb_sawtooth", top)
    return {"top": top, "width": 1.8, "ripple_amp": 0.008, "ripple_period": 1.0,
            "stripe": 1.0, "area_m2": round(f.area, 5)}


def kerb_sausage() -> dict:
    """Yellow 'sausage' kerb laid behind exit/apex kerbs to stop corner cutting.
    Kept within the 5 cm limit and fully ramped so it rattles but never launches."""
    pts = [(0.0, BASE), (0.0, 0.003), (0.22, 0.05), (0.48, 0.05),
           (0.70, 0.003), (0.70, BASE)]
    f = _face_from_points(pts, fillet_r=0.08, fillet_min_h=0.04)
    top = _top(f, arc_segments=4)
    _check_kerb("kerb_sausage", top)
    return {"top": top, "width": 0.7, "ripple_amp": 0.0, "ripple_period": 2.0,
            "stripe": 0.0, "area_m2": round(f.area, 5)}


# ----------------------------------------------------------------------------- barriers
def armco() -> dict:
    """Double-rail-height W-beam (310 mm deep, 83 mm projection) on C-posts
    with a 150 mm spacer block. u = 0 is the front crest of the beam."""
    depth, proj, h0 = 0.31, 0.083, 0.40
    ctrl = []
    n = 16
    for i in range(n + 1):
        t = i / n
        ctrl.append(Vector(proj * (0.5 + 0.5 * math.cos(4.0 * math.pi * t)), h0 + depth * t))
    with BuildLine() as bl:
        Spline(*ctrl)
    edge = bl.line.edges()[0]
    beam = [[round(edge.position_at(i / 24).X, 4), round(edge.position_at(i / 24).Y, 4)]
            for i in range(25)]
    # C-channel post (150 x 100 mm, 6 mm wall), seen from above in (u, v) where
    # v runs along the barrier.
    with BuildSketch() as post:
        Rectangle(0.10, 0.15)
        with Locations((0.006, 0.0)):
            Rectangle(0.10, 0.15 - 2 * 0.006, mode=Mode.SUBTRACT)
    pf = post.sketch.faces()[0]
    footprint = [[round(u + proj + 0.15 + 0.05, 4), v] for u, v in _outline(pf)]
    return {
        "beam": beam,
        "beam_thickness": 0.003,
        "post": {"footprint": footprint, "top": 0.75, "bottom": -0.8, "spacing": 4.0,
                 "area_m2": round(pf.area, 6)},
        "collision": {"u0": -0.02, "u1": 0.40, "top": 1.0, "bottom": -1.5},
    }


def concrete_wall() -> dict:
    """F-shape concrete safety wall, 1.0 m tall, with a 3 m debris fence on top."""
    pts = [(0.0, -0.6), (0.0, 0.08), (0.05, 0.33), (0.18, 1.0), (0.38, 1.0),
           (0.52, 0.33), (0.58, 0.08), (0.58, -0.6)]
    f = _face_from_points(pts)
    section = [[u, h] for u, h in _outline(f)]
    return {
        "section": section,
        "fence": {"u": 0.28, "bottom": 1.0, "top": 4.0, "post_spacing": 4.0,
                  "mesh": 0.10, "post_size": 0.08},
        "collision": {"u0": 0.0, "u1": 0.58, "top": 1.2, "bottom": -1.5},
        "area_m2": round(f.area, 5),
    }


def main() -> None:
    data = {
        "_doc": __doc__.strip().splitlines()[0],
        "frame": "u = metres outward from the road edge / barrier line; h = metres above the road plane",
        "generator": "cad/track/trackside_profiles.py",
        "kerb_flat": kerb_flat(),
        "kerb_sawtooth": kerb_sawtooth(),
        "kerb_sausage": kerb_sausage(),
        "armco": armco(),
        "concrete": concrete_wall(),
        "edge_line": {"width": 0.2, "lift": 0.012},
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, indent=1) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}")
    for k in ("kerb_flat", "kerb_sawtooth", "kerb_sausage"):
        print(f"  {k}: {len(data[k]['top'])} top points, peak "
              f"{max(h for _, h in data[k]['top']) * 100:.1f} cm")


if __name__ == "__main__":
    main()
