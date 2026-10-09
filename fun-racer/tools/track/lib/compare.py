"""Compares two builds of one track (e.g. a rebuild against the committed assets).

    python3 tools/track/lib/compare.py <dir A> <dir B>

A build "matches" when every position differs by less than TOL (1 cm), the turn and sector
tables are identical and the metadata agrees. Byte-identical files are reported as such.
"""
import hashlib
import json
import os
import struct
import sys

TOL = 0.01            # m: positions, heights, widths
TOL_ANGLE = 1e-4      # rad: bank
FILES = ("track.json", "road_profile.json", "road_mesh.glb", "terrain.json", "terrain_height.bin",
         "terrain_far.bin", "terrain_dist.bin", "track_info.json", "trackside_profiles.json",
         "road_tarmac_albedo.png", "road_grass_albedo.png")
# The surroundings step is optional: its files are compared when both builds have them and
# are not "missing" when only one does.
OPTIONAL_FILES = ("landcover.png", "landcover_far.png", "scenery.glb", "scenery_points.bin", "scenery.json")


def _sha(path):
    with open(path, "rb") as f:
        return hashlib.sha1(f.read()).hexdigest()


def _json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _max_diff(a, b):
    return max((abs(x - y) for x, y in zip(a, b)), default=0.0)


def _floats(path, fmt):
    with open(path, "rb") as f:
        raw = f.read()
    size = struct.calcsize(fmt)
    return struct.unpack(f"<{len(raw) // size}{fmt}", raw)


def _glb_positions(path):
    """All POSITION vertices of a .glb, in file order, as a flat tuple of floats."""
    with open(path, "rb") as f:
        raw = f.read()
    jlen = struct.unpack_from("<I", raw, 12)[0]
    gltf = json.loads(raw[20:20 + jlen])
    bin_start = 20 + jlen + 8
    out = []
    for mesh in gltf["meshes"]:
        for prim in mesh["primitives"]:
            acc = gltf["accessors"][prim["attributes"]["POSITION"]]
            view = gltf["bufferViews"][acc["bufferView"]]
            off = bin_start + view.get("byteOffset", 0) + acc.get("byteOffset", 0)
            out += struct.unpack_from(f"<{acc['count'] * 3}f", raw, off)
    return out, [m["name"] for m in gltf["meshes"]]


def compare_dirs(a, b, files=FILES):
    """Report dict: {"ok": bool, "checks": [(name, ok, detail)], "identical": [...], "missing": [...]}."""
    checks, identical, missing = [], [], []

    def check(name, ok, detail):
        checks.append((name, bool(ok), detail))

    def both(name):
        pa, pb = os.path.join(a, name), os.path.join(b, name)
        if not (os.path.exists(pa) and os.path.exists(pb)):
            if os.path.exists(pa) != os.path.exists(pb):
                missing.append(name)
            return None
        if _sha(pa) == _sha(pb):
            identical.append(name)
        return pa, pb

    p = both("track.json")
    if p:
        ta, tb = _json(p[0]), _json(p[1])
        same_n = len(ta["points"]) == len(tb["points"])
        check("track.json point count", same_n, f"{len(ta['points'])} vs {len(tb['points'])}")
        if same_n:
            d = max(max(abs(x - y) for x, y in zip(pa["p"], pb["p"])) for pa, pb in zip(ta["points"], tb["points"]))
            check("track.json positions", d < TOL, f"max difference {d * 1000:.3f} mm")
            for key, tol in (("s", TOL), ("grade", 1e-4), ("curvature", 1e-5), ("width", TOL), ("bank", TOL_ANGLE)):
                d = _max_diff([q[key] for q in ta["points"]], [q[key] for q in tb["points"]])
                check(f"track.json {key}", d <= tol, f"max difference {d:.2e}")
        check("track.json turns", ta["turns"] == tb["turns"],
              "identical" if ta["turns"] == tb["turns"] else f"{ta['turns']} vs {tb['turns']}")
        check("track.json sectors", ta["sectors"] == tb["sectors"], f"{ta['sectors']} vs {tb['sectors']}")
        for key in ("name", "length", "official_length", "direction", "origin_latlon", "origin_elevation_m",
                    "start_s", "finish_s", "elevation_range", "attribution", "frame", "closed"):
            check(f"track.json {key}", ta.get(key) == tb.get(key), f"{ta.get(key)!r} vs {tb.get(key)!r}"[:120])
        check("track.json step", abs(ta["step"] - tb["step"]) < 1e-9, f"{ta['step']} vs {tb['step']}")
    p = both("road_profile.json")
    if p:
        ra, rb = _json(p[0]), _json(p[1])
        for key, tol in (("width", TOL), ("bank", TOL_ANGLE), ("verge_left", TOL), ("verge_right", TOL),
                         ("racing_line", TOL)):
            ok = len(ra[key]) == len(rb[key])
            d = _max_diff(ra[key], rb[key]) if ok else float("inf")
            check(f"road_profile.json {key}", ok and d <= tol, f"max difference {d:.2e}")
        check("road_profile.json chunks", ra["chunks"] == rb["chunks"], f"{len(ra['chunks'])} vs {len(rb['chunks'])} chunks")
    p = both("road_mesh.glb")
    if p:
        (va, na), (vb, nb) = _glb_positions(p[0]), _glb_positions(p[1])
        ok = len(va) == len(vb) and na == nb
        d = _max_diff(va, vb) if ok else float("inf")
        check("road_mesh.glb vertices", ok and d < TOL, f"{len(va) // 3} vertices, max difference {d * 1000:.3f} mm")
    p = both("terrain.json")
    if p:
        ma, mb = _json(p[0]), _json(p[1])
        ka, kb = ma.pop("plan_scale"), mb.pop("plan_scale")
        check("terrain.json metadata", ma == mb, "identical" if ma == mb else "differs")
        check("terrain.json plan_scale", abs(ka - kb) < 1e-9, f"{ka} vs {kb}")
    for name, fmt, tol, unit in (("terrain_height.bin", "f", TOL, "m"), ("terrain_far.bin", "f", TOL, "m"),
                                 ("terrain_dist.bin", "H", 1, "dm")):
        p = both(name)
        if p:
            fa, fb = _floats(p[0], fmt), _floats(p[1], fmt)
            ok = len(fa) == len(fb)
            d = _max_diff(fa, fb) if ok else float("inf")
            check(name, ok and d <= tol, f"{len(fa)} values, max difference {d:.4g} {unit}")
    p = both("track_info.json")
    if p:
        ia, ib = _json(p[0]), _json(p[1])
        check("track_info.json", ia == ib, "identical" if ia == ib else f"{ia} vs {ib}"[:200])
    for name in files:
        if name not in ("track.json", "road_profile.json", "road_mesh.glb", "terrain.json", "terrain_height.bin",
                        "terrain_far.bin", "terrain_dist.bin", "track_info.json"):
            p = both(name)
            if p:
                check(name, name in identical, "byte-identical" if name in identical else "differs")
    for name in OPTIONAL_FILES:
        pa, pb = os.path.join(a, name), os.path.join(b, name)
        if os.path.exists(pa) and os.path.exists(pb):
            same = _sha(pa) == _sha(pb)
            if same:
                identical.append(name)
            check(name, same, "byte-identical" if same else "differs")
    for name in missing:
        check(name, False, "present in only one of the two folders")
    return {"ok": bool(checks) and all(ok for _, ok, _ in checks), "checks": checks,
            "identical": identical, "missing": missing}


def format_report(report):
    lines = [f"  {'ok  ' if ok else 'FAIL'}  {name}: {detail}" for name, ok, detail in report["checks"]]
    lines.append(f"  byte-identical files: {', '.join(report['identical']) or 'none'}")
    lines.append("compare: " + ("MATCH (all differences below 1 cm, tables identical)" if report["ok"]
                                else "MISMATCH"))
    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rep = compare_dirs(sys.argv[1], sys.argv[2])
    print(format_report(rep))
    sys.exit(0 if rep["ok"] else 1)
