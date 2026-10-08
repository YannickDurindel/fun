"""Plan-view and periodic-signal helpers shared by the centreline and turn code.

These are the numerics the Red Bull Ring was first built with; they are kept in plain Python
floats, in the same operation order, so that rebuilding that track reproduces its files
bit for bit. Do not "optimise" them without re-running tools/track/tests.
"""
import math

EARTH_M_PER_DEG = 111320.0


def seg_dist(a, b, p):
    """Distance from p to segment a-b and the closest point on it (2D)."""
    ax, az = a
    bx, bz = b
    dx, dz = bx - ax, bz - az
    t = max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - az) * dz) / max(1e-9, dx * dx + dz * dz)))
    q = (ax + dx * t, az + dz * t)
    return math.dist(q, p), q


def catmull(p0, p1, p2, p3, t):
    t2, t3 = t * t, t * t * t
    return tuple(0.5 * (2 * p1[i] + (-p0[i] + p2[i]) * t + (2 * p0[i] - 5 * p1[i] + 4 * p2[i] - p3[i]) * t2
                        + (-p0[i] + 3 * p1[i] - 3 * p2[i] + p3[i]) * t3) for i in range(2))


def catmull_centripetal(p0, p1, p2, p3, t):
    """Centripetal Catmull-Rom (Barry-Goldman) point between p1 and p2, t in [0, 1]. Unlike the
    uniform form it does not overshoot where a long segment meets short ones, which is what
    OSM ways look like: two nodes for a straight, then a dense corner."""
    def knot(a, b):
        return max(math.dist(a, b), 1e-6) ** 0.5
    t0 = 0.0
    t1 = t0 + knot(p0, p1)
    t2 = t1 + knot(p1, p2)
    t3 = t2 + knot(p2, p3)
    u = t1 + (t2 - t1) * t

    def mix(a, b, ta, tb):
        w = (u - ta) / (tb - ta)
        return (a[0] + (b[0] - a[0]) * w, a[1] + (b[1] - a[1]) * w)
    a1, a2, a3 = mix(p0, p1, t0, t1), mix(p1, p2, t1, t2), mix(p2, p3, t2, t3)
    b1, b2 = mix(a1, a2, t0, t2), mix(a2, a3, t1, t3)
    return mix(b1, b2, t1, t2)


def closest_index(samples, p):
    return min(range(len(samples)), key=lambda i: math.dist(samples[i], p))


def gauss_periodic(v, sigma):
    """Gaussian smoothing of a periodic sequence; sigma in samples."""
    n, r = len(v), int(3 * sigma) + 1
    w = [math.exp(-0.5 * (i / sigma) ** 2) for i in range(-r, r + 1)]
    sw = sum(w)
    return [sum(w[i + r] * v[(k + i) % n] for i in range(-r, r + 1)) / sw for k in range(n)]


def smooth_loop_xy(pts, sigma):
    xs = gauss_periodic([p[0] for p in pts], sigma)
    zs = gauss_periodic([p[1] for p in pts], sigma)
    return list(zip(xs, zs))


def loop_length(pts):
    return sum(math.dist(a, b) for a, b in zip(pts, pts[1:] + pts[:1]))


def catmull_resample(pts, labels, target_step, spline="centripetal"):
    """Evenly spaced Catmull-Rom samples of the closed polyline ``pts``. Returns
    (samples, labels per sample, step, polyline length). ``spline`` is "centripetal" or
    "uniform" (the original form, kept for the Red Bull Ring)."""
    curve = catmull if spline == "uniform" else catmull_centripetal
    raw_s = [0.0]
    for a, b in zip(pts, pts[1:] + pts[:1]):
        raw_s.append(raw_s[-1] + math.dist(a, b))
    length = raw_s[-1]
    n = int(round(length / target_step))
    step = length / n
    samples, sample_labels = [], []
    j = 0
    N = len(pts)
    for k in range(n):
        s = k * step
        while raw_s[j + 1] < s:
            j += 1
        t = (s - raw_s[j]) / max(1e-9, raw_s[j + 1] - raw_s[j])
        p0, p1, p2, p3 = pts[(j - 1) % N], pts[j % N], pts[(j + 1) % N], pts[(j + 2) % N]
        samples.append(curve(p0, p1, p2, p3, t))
        sample_labels.append(labels[j % N])
    return samples, sample_labels, step, length


def respace(pts, target_step):
    """Re-measure a closed polyline and re-space it evenly (linear). Returns
    (points, step, length)."""
    cum = [0.0]
    for a, b in zip(pts, pts[1:] + pts[:1]):
        cum.append(cum[-1] + math.dist(a, b))
    length = cum[-1]
    n = int(round(length / target_step))
    step = length / n
    out, j = [], 0
    for k in range(n):
        s = k * step
        while cum[j + 1] < s:
            j += 1
        t = (s - cum[j]) / max(1e-9, cum[j + 1] - cum[j])
        a, b = pts[j], pts[(j + 1) % len(pts)]
        out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out, step, length


def periodic_interp(xs, ys, q, period):
    """Linear interpolation of periodic samples (xs ascending in [0, period)) at ascending q."""
    out, j, m = [], 0, len(xs)
    for s in q:
        while j + 1 < m and xs[j + 1] <= s:
            j += 1
        x0, y0 = xs[j], ys[j]
        x1, y1 = (xs[j + 1], ys[j + 1]) if j + 1 < m else (period, ys[0])
        out.append(y0 + (y1 - y0) * (s - x0) / max(1e-9, x1 - x0))
    return out


def signed_area(pts):
    """Shoelace area of a closed (x, z) loop in the Godot frame (z = -north): positive means
    clockwise seen from above."""
    a = 0.0
    for (x0, z0), (x1, z1) in zip(pts, pts[1:] + pts[:1]):
        a += x0 * z1 - x1 * z0
    return 0.5 * a


def curvature(samples, step):
    """Signed plan curvature per sample (+ = left), central differences on the closed loop."""
    n = len(samples)
    heading = []
    for k in range(n):
        a, b = samples[k - 1], samples[(k + 1) % n]
        heading.append(math.atan2(-(b[1] - a[1]), b[0] - a[0]))  # angle in the east/north plane
    curv = []
    for k in range(n):
        d = heading[(k + 1) % n] - heading[k - 1]
        d = (d + math.pi) % (2 * math.pi) - math.pi
        curv.append(d / (2 * step))
    return curv
