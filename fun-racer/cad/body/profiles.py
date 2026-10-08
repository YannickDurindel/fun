"""2D/3D profile helpers for the F1 body: superellipse body sections and airfoils.

CAD frame used by all body modules (converted to Godot on export):
    x = backward (Godot +Z), y = right (Godot +X), z = up (Godot +Y)
This is a cyclic permutation of the Godot car-local axes, so handedness and
triangle winding are preserved.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from build123d import Edge, Face, Vector, Wire

N_SECTION_POINTS = 36


def _spow(v: float, e: float) -> float:
    """Signed power used by superellipses."""
    return math.copysign(abs(v) ** e, v)


@dataclass(frozen=True)
class Section:
    """A closed body cross-section lying in a YZ plane at station ``x``.

    The outline is a superellipse whose upper and lower halves can have
    different heights and squareness, and whose top can be narrower than the
    bottom (tumblehome), which is how F1 tubs and sidepods are shaped.
    """

    x: float
    width: float
    z_bot: float
    z_top: float
    y_center: float = 0.0
    n_top: float = 2.6
    n_bot: float = 4.0
    taper: float = 0.72  # top width / bottom width
    z_split: float | None = None  # height of the widest line (default: middle)

    def points(self, n: int = N_SECTION_POINTS) -> list[Vector]:
        zs = self.z_split if self.z_split is not None else 0.5 * (self.z_bot + self.z_top)
        half = 0.5 * self.width
        pts = []
        for i in range(n):
            t = 2.0 * math.pi * i / n
            c, s = math.cos(t), math.sin(t)
            if s >= 0.0:
                e = 2.0 / self.n_top
                y = half * _spow(c, e) * (1.0 - (1.0 - self.taper) * s * s)
                z = zs + (self.z_top - zs) * _spow(s, e)
            else:
                e = 2.0 / self.n_bot
                y = half * _spow(c, e)
                z = zs + (zs - self.z_bot) * _spow(s, e)
            pts.append(Vector(self.x, self.y_center + y, z))
        return pts

    def wire(self) -> Wire:
        return Wire([Edge.make_spline(self.points(), periodic=True)])


def airfoil_points(
    chord: float,
    camber: float = 0.06,
    camber_pos: float = 0.4,
    thickness: float = 0.10,
    n: int = 28,
) -> tuple[list[tuple[float, float]], list[tuple[float, float]]]:
    """NACA 4-digit style airfoil, inverted (suction side down) for downforce.

    Returns (upper, lower) point lists in chord coordinates (dx backward, dz up),
    both running from leading edge to trailing edge.
    """
    upper, lower = [], []
    for i in range(n + 1):
        # cosine spacing clusters points at the leading edge
        xc = 0.5 * (1.0 - math.cos(math.pi * i / n))
        yt = 5.0 * thickness * (
            0.2969 * math.sqrt(xc) - 0.1260 * xc - 0.3516 * xc**2 + 0.2843 * xc**3 - 0.1015 * xc**4
        )
        if xc < camber_pos:
            yc = camber / camber_pos**2 * (2 * camber_pos * xc - xc**2)
            dyc = 2 * camber / camber_pos**2 * (camber_pos - xc)
        else:
            yc = camber / (1 - camber_pos) ** 2 * ((1 - 2 * camber_pos) + 2 * camber_pos * xc - xc**2)
            dyc = 2 * camber / (1 - camber_pos) ** 2 * (camber_pos - xc)
        th = math.atan(dyc)
        # keep a minimum trailing-edge thickness (~2 mm on a 0.2 m chord)
        if xc > 0.5:
            yt = max(yt, 0.005)
        # invert camber: downforce wing (suction side underneath)
        xu, zu = xc - yt * math.sin(th), -yc + yt * math.cos(th)
        xl, zl = xc + yt * math.sin(th), -yc - yt * math.cos(th)
        upper.append((xu * chord, zu * chord))
        lower.append((xl * chord, zl * chord))
    return upper, lower


def airfoil_face(
    le_x: float,
    le_z: float,
    y: float,
    chord: float,
    aoa_deg: float,
    camber: float = 0.06,
    thickness: float = 0.10,
) -> Face:
    """Airfoil face in the XZ plane at lateral position ``y``.

    ``aoa_deg`` > 0 raises the trailing edge (downforce orientation).
    """
    upper, lower = airfoil_points(chord, camber=camber, thickness=thickness)
    a = math.radians(aoa_deg)
    ca, sa = math.cos(a), math.sin(a)

    def tr(p: tuple[float, float]) -> Vector:
        dx, dz = p
        return Vector(le_x + dx * ca - dz * sa, y, le_z + dx * sa + dz * ca)

    # TE(upper) -> LE -> TE(lower): one smooth spline around the nose,
    # closed by a short straight trailing edge.
    loop = [tr(p) for p in reversed(upper)] + [tr(p) for p in lower[1:]]
    nose = Edge.make_spline(loop)
    te = Edge.make_line(loop[-1], loop[0])
    return Face(Wire([nose, te]))
