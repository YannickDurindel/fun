#!/usr/bin/env python3
"""Builds assets/tracks/red_bull_ring/track.json from open data.

Sources (fetched once, raw responses cached in assets/tracks/red_bull_ring/raw/):
  * Centreline: OpenStreetMap relation 5309181 "Red Bull Ring" (type=circuit), (c) OpenStreetMap
    contributors, ODbL 1.0.
  * Elevation: EU-DEM 25 m via api.opentopodata.org (Copernicus, (c) European Union).

Output frame (Godot): x = east, y = elevation above the finish line, z = -north, metres,
in a local tangent plane centred on the finish-line node. Lap direction = race direction
(clockwise seen from above). s = distance along the centreline from the finish line.

Usage: python3 tools/track/fetch_red_bull_ring.py [--offline]
"""
import hashlib, json, math, os, sys, time, urllib.request, xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(ROOT, "assets", "tracks", "red_bull_ring")
RAW = os.path.join(OUT_DIR, "raw")
UA = {"User-Agent": "fun-racer/0.1 (track builder)"}
REL = 5309181
# GP loop ways in driving order (relation member order; the pit lane / MotoGP ways are excluded).
LOOP_WAYS = [347958266, 822592398, 822592399, 822592400, 822592401, 822592402, 822592405,
             822592406, 822592407, 822592408, 822592409, 822592410, 822592403, 822592404]
STEP = 2.0            # resample spacing, m
DEM_STEP = 10.0       # DEM sampling spacing, m
DEFAULT_WIDTH = 13.0
ELEV_SIGMA = 45.0     # m, Gaussian smoothing of DEM elevation along the lap
OFFICIAL_LENGTH = 4318.0

# Official F1 corner numbering (10 turns). `search` = window (m) of s around the detected
# curvature peak inside the named OSM way (or between neighbours for unnamed kinks).
TURNS = [
    ("T1", "Niki Lauda Kurve", "right"),
    ("T2", "Turn 2 (kink)", "right"),
    ("T3", "Remus", "right"),
    ("T4", "Schlossgold", "right"),
    ("T5", "Turn 5 (kink)", "left"),
    ("T6", "Rauch", "left"),
    ("T7", "Würth Kurve", "left"),
    ("T8", "Rindt", "right"),
    ("T9", "Red Bull Mobile", "right"),
    ("T10", "Turn 10", "right"),
]

def fetch(url, cache, data=None):
    path = os.path.join(RAW, cache)
    if os.path.exists(path):
        return open(path, "rb").read()
    if "--offline" in sys.argv:
        sys.exit(f"missing cached {cache} and --offline given")
    req = urllib.request.Request(url, headers=UA)
    body = urllib.request.urlopen(req, timeout=60).read()
    os.makedirs(RAW, exist_ok=True)
    open(path, "wb").write(body)
    return body

def main():
    xml = fetch(f"https://api.openstreetmap.org/api/0.6/relation/{REL}/full", "osm_relation.xml")
    r = ET.fromstring(xml)
    nodes = {n.get("id"): (float(n.get("lat")), float(n.get("lon"))) for n in r.iter("node")}
    ways = {}
    for w in r.iter("way"):
        tags = {t.get("k"): t.get("v") for t in w.iter("tag")}
        ways[int(w.get("id"))] = ([x.get("ref") for x in w.iter("nd")], tags.get("name", ""))
    rel = [x for x in r.iter("relation") if x.get("id") == str(REL)][0]
    roles = {m.get("role"): m.get("ref") for m in rel.iter("member") if m.get("type") == "node"}

    # Chain the loop, remembering which named way each node came from.
    chain, names = [], []
    for wid in LOOP_WAYS:
        ids, name = ways[wid]
        if chain:
            assert ids[0] == chain[-1], f"way {wid} does not continue the chain"
            ids = ids[1:]
        chain += ids
        names += [name] * len(ids)
    assert chain[0] == chain[-1], "loop not closed"
    chain, names = chain[:-1], names[:-1]

    lat0, lon0 = nodes[roles["finish"]]
    kx = 111320.0 * math.cos(math.radians(lat0))
    ky = 111320.0
    def to_xz(lat, lon):
        return ((lon - lon0) * kx, -(lat - lat0) * ky)

    pts = [to_xz(*nodes[i]) for i in chain]
    # Rotate the loop so it starts at the vertex nearest the finish node, then insert the exact
    # projection of the finish node as s = 0.
    fx, fz = 0.0, 0.0
    best = min(range(len(pts)), key=lambda i: _seg_dist(pts[i], pts[(i + 1) % len(pts)], (fx, fz))[0])
    _, proj = _seg_dist(pts[best], pts[(best + 1) % len(pts)], (fx, fz))
    pts = [proj] + pts[best + 1:] + pts[:best + 1]
    names = [names[best]] + names[best + 1:] + names[:best + 1]

    # Cumulative distance and closed-loop resampling (Catmull-Rom for smoothness).
    raw_s = [0.0]
    for a, b in zip(pts, pts[1:] + pts[:1]):
        raw_s.append(raw_s[-1] + math.dist(a, b))
    length = raw_s[-1]
    n = int(round(length / STEP))
    step = length / n
    samples, sample_names = [], []
    j = 0
    N = len(pts)
    for k in range(n):
        s = k * step
        while raw_s[j + 1] < s:
            j += 1
        t = (s - raw_s[j]) / max(1e-9, raw_s[j + 1] - raw_s[j])
        p0, p1, p2, p3 = pts[(j - 1) % N], pts[j % N], pts[(j + 1) % N], pts[(j + 2) % N]
        samples.append(_catmull(p0, p1, p2, p3, t))
        sample_names.append(names[j % N])

    # Light plan-view smoothing (sigma 4 m) removes vertex kinks from the sparse OSM polyline
    # without moving corners meaningfully, then re-measure and re-space evenly.
    samples = _smooth_loop_xy(samples, sigma=4.0 / step)
    samples, step, length = _respace(samples)
    # OSM ways are drawn ~0.4 % short of the official lap; scale the plan view uniformly so the
    # lap is exactly the official length (sub-metre change per straight).
    k_scale = OFFICIAL_LENGTH / length
    true_samples = samples  # unscaled, used for DEM lookups at real lat/lon
    samples = [(x * k_scale, z * k_scale) for x, z in samples]
    step *= k_scale
    length = OFFICIAL_LENGTH
    n = len(samples)
    sample_names = [sample_names[min(len(sample_names) - 1, int(k * len(sample_names) / n))] for k in range(n)]

    start_xz = to_xz(*nodes[roles["start"]])
    start_s = _closest_s(samples, step, start_xz)

    # Elevation: sample the DEM every DEM_STEP m along the loop, then smooth.
    dem_idx = list(range(0, n, int(DEM_STEP / step)))
    latlon = [(lat0 - true_samples[i][1] / ky, lon0 + true_samples[i][0] / kx) for i in dem_idx]
    elev = []
    for c in range(0, len(latlon), 100):
        chunk = latlon[c:c + 100]
        locs = "|".join(f"{la:.7f},{lo:.7f}" for la, lo in chunk)
        key = f"dem_{hashlib.sha1(locs.encode()).hexdigest()[:12]}.json"
        cached = os.path.exists(os.path.join(RAW, key))
        body = fetch(f"https://api.opentopodata.org/v1/eudem25m?locations={locs}", key)
        res = json.loads(body)["results"]
        elev += [x["elevation"] for x in res]
        if not cached:
            time.sleep(1.1)  # OpenTopoData public rate limit: 1 request/s
    dem_s = [i * step for i in dem_idx]
    # Interpolate to every sample (periodic), then Gaussian-smooth (sigma 30 m) to remove
    # embankment / tree noise in the DEM while keeping real gradients.
    y = _periodic_interp(dem_s, elev, [k * step for k in range(n)], length)
    y = _gauss_periodic(y, sigma=ELEV_SIGMA / step)
    base = y[0]
    y = [v - base for v in y]

    # Curvature (signed, + = left) for turn detection.
    heading = []
    for k in range(n):
        a, b = samples[k - 1], samples[(k + 1) % n]
        heading.append(math.atan2(-(b[1] - a[1]), b[0] - a[0]))  # angle in east/north plane
    curv = []
    for k in range(n):
        d = heading[(k + 1) % n] - heading[k - 1]
        d = (d + math.pi) % (2 * math.pi) - math.pi
        curv.append(d / (2 * step))
    curv_s = _gauss_periodic(curv, sigma=6.0 / step)

    turns = _detect_turns(curv_s, sample_names, step, n)

    pts_out = []
    for k in range(n):
        g = (y[(k + 1) % n] - y[k - 1]) / (2 * step)
        pts_out.append({
            "s": round(k * step, 3),
            "p": [round(samples[k][0], 3), round(y[k], 3), round(samples[k][1], 3)],
            "width": DEFAULT_WIDTH,
            "bank": 0.0,
            "grade": round(g, 4),
            "curvature": round(curv_s[k], 5),
        })

    s1 = next(t["s_apex"] for t in turns if t["id"] == "T4") + 150.0
    s2 = next(t["s_apex"] for t in turns if t["id"] == "T7") + 120.0
    data = {
        "name": "Red Bull Ring (Grand Prix circuit)",
        "length": round(length, 3),
        "official_length": OFFICIAL_LENGTH,
        "closed": True,
        "direction": "clockwise",
        "frame": "Godot metres: x=east, y=up (relative to finish line), z=-north; origin at finish line",
        "origin_latlon": [lat0, lon0],
        "origin_elevation_m": round(base, 2),
        "step": step,
        "start_s": round(start_s, 3),
        "finish_s": 0.0,
        "sectors": [0.0, round(s1, 1), round(s2, 1)],
        "turns": turns,
        "elevation_range": round(max(y) - min(y), 2),
        "points": pts_out,
        "attribution": "Centreline (c) OpenStreetMap contributors (ODbL 1.0), relation 5309181. "
                       "Elevation: EU-DEM v1.1 25 m (Copernicus, (c) European Union) via OpenTopoData.",
    }
    with open(os.path.join(OUT_DIR, "track.json"), "w") as f:
        json.dump(data, f, separators=(",", ":"), ensure_ascii=False)
    grades = [p["grade"] for p in pts_out]
    print(f"length {length:.1f} m (official {OFFICIAL_LENGTH}), {n} points, start_s {start_s:.1f}")
    print(f"elevation range {data['elevation_range']} m, max climb {100*max(grades):.1f} %, max descent {100*min(grades):.1f} %")
    for t in turns:
        print(f"  {t['id']:>3} {t['name']:<20} s={t['s_apex']:7.1f}  {t['direction']:<5}  min radius {t['min_radius']:.0f} m  elev {y[int(t['s_apex']/step)]:+.1f} m")

def _seg_dist(a, b, p):
    ax, az = a; bx, bz = b
    dx, dz = bx - ax, bz - az
    t = max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - az) * dz) / max(1e-9, dx * dx + dz * dz)))
    q = (ax + dx * t, az + dz * t)
    return math.dist(q, p), q

def _catmull(p0, p1, p2, p3, t):
    t2, t3 = t * t, t * t * t
    return tuple(0.5 * (2 * p1[i] + (-p0[i] + p2[i]) * t + (2 * p0[i] - 5 * p1[i] + 4 * p2[i] - p3[i]) * t2
                        + (-p0[i] + 3 * p1[i] - 3 * p2[i] + p3[i]) * t3) for i in range(2))

def _closest_s(samples, step, p):
    k = min(range(len(samples)), key=lambda i: math.dist(samples[i], p))
    return k * step

def _smooth_loop_xy(pts, sigma):
    xs = _gauss_periodic([p[0] for p in pts], sigma)
    zs = _gauss_periodic([p[1] for p in pts], sigma)
    return list(zip(xs, zs))

def _respace(pts):
    cum = [0.0]
    for a, b in zip(pts, pts[1:] + pts[:1]):
        cum.append(cum[-1] + math.dist(a, b))
    length = cum[-1]
    n = int(round(length / STEP))
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

def _periodic_interp(xs, ys, q, period):
    out, j, m = [], 0, len(xs)
    for s in q:
        while j + 1 < m and xs[j + 1] <= s:
            j += 1
        x0, y0 = xs[j], ys[j]
        x1, y1 = (xs[j + 1], ys[j + 1]) if j + 1 < m else (period, ys[0])
        out.append(y0 + (y1 - y0) * (s - x0) / max(1e-9, x1 - x0))
    return out

def _gauss_periodic(v, sigma):
    n, r = len(v), int(3 * sigma) + 1
    w = [math.exp(-0.5 * (i / sigma) ** 2) for i in range(-r, r + 1)]
    sw = sum(w)
    return [sum(w[i + r] * v[(k + i) % n] for i in range(-r, r + 1)) / sw for k in range(n)]

def _detect_turns(curv, names, step, n):
    """Pick the 10 official turns: named OSM ways give T1,T3,T4,T6,T7,T8,T9; kinks T2,T5,T10
    are the strongest curvature peaks in the gaps between them."""
    def peak(lo, hi, sign):
        best, bs = 0.0, lo
        for k in range(int(lo / step), int(hi / step)):
            c = curv[k % n] * sign
            if c > best:
                best, bs = c, k * step
        return bs, best
    def span(name):
        ks = [k for k in range(n) if names[k] == name]
        # handle wrap-around
        if ks and ks[-1] - ks[0] > n / 2:
            ks = [k if k > n / 2 else k + n for k in ks]
        return min(ks) * step, (max(ks) + 1) * step
    named = {"T1": "Niki Lauda Kurve", "T3": "Remus", "T4": "Schlossgold", "T6": "Rauch",
             "T7": "Würth Kurve", "T8": "Rindt", "T9": "Red Bull Mobile"}
    sign = {"right": -1.0, "left": 1.0}
    apex = {}
    for tid, nm, d in TURNS:
        if tid in named:
            lo, hi = span(named[tid])
            apex[tid] = peak(lo - 20, hi + 20, sign[d])
    gaps = {"T2": ("T1", "T3"), "T5": ("T4", "T6"), "T10": ("T9", "T1")}
    for tid, (a, b) in gaps.items():
        lo, hi = apex[a][0] + 60, apex[b][0] - 60
        if hi < lo:
            hi += n * step
        d = [t for t in TURNS if t[0] == tid][0][2]
        apex[tid] = peak(lo, hi, sign[d])
    out = []
    for tid, nm, d in TURNS:
        s, c = apex[tid]
        out.append({"id": tid, "name": nm, "direction": d, "s_apex": round(s % (n * step), 1),
                    "min_radius": round(1.0 / max(c, 1e-4), 1)})
    return out

if __name__ == "__main__":
    main()
