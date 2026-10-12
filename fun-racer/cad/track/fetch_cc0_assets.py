"""Downloads the CC0 assets of the "detailed" track look and derives what the game ships.

Sources (both CC0 1.0, no attribution required; every asset is still listed in
assets/tracks/_shared/look_detailed/CREDITS.md, written by this script):
  * Poly Haven  https://polyhaven.com  (API: https://api.polyhaven.com)
  * ambientCG   https://ambientcg.com

Originals are cached in ~/.cache/fun-racer/cc0/ (downloaded once); only the files the game
uses are written to the repository, at the resolution it needs.

HDRIs (sky, ambient light and reflections, see scripts/track/track_look.gd) go to
look_detailed/sky/<id>.hdr. The sun of each HDRI is located here (brightest region of the
panorama) and written to look_detailed/sky/skies.json, so the game can turn the sky to the
track's sun azimuth and aim its DirectionalLight at the sun painted in the sky:
  {"<id>": {"file": "res://...hdr", "sun_azimuth_deg": a, "sun_elevation_deg": e,
            "sun_color": [r, g, b]}}
  azimuth in the game's compass convention (0 = -Z north, 90 = +X east) for the panorama as
  Godot shows it with sky_rotation 0: a texel at u (0..1 across) is seen at azimuth
  90 - 360 u degrees, v (0..1 down) at elevation 90 - 180 v. Checked in game: a free camera
  aimed at the computed azimuth / elevation sees the sun at the image centre (+-5 degrees).

Photo-scanned materials go to look_detailed/photo/ as lossy WebP (Godot re-encodes them for
the GPU on import; WebP only keeps the repository small), packed for the shaders:
  <name>_detail.webp  RGBA: R luminance scaled to a mean of 0.25 (the shaders multiply the
                      track's own colour by R / 0.25), G roughness, B ambient occlusion, A 1
  <name>_albedo.webp  RGBA: colour, A roughness (materials that keep the photo's colour)
  <name>_normal.webp  RGB tangent-space normal map, OpenGL convention (+Y up)
and their real-world tile size (metres per texture tile) and mean colour (as stored, 0..1) are
written to photo/materials.json.

Run: .venv/bin/python cad/track/fetch_cc0_assets.py
"""

from __future__ import annotations

import hashlib
import json
import math
import sys
import urllib.request
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "assets" / "tracks" / "_shared" / "look_detailed"
CACHE = Path.home() / ".cache" / "fun-racer" / "cc0"
UA = {"User-Agent": "fun-racer asset fetcher (CC0 assets, one-off download)"}

# Sky panoramas: Poly Haven "puresky" HDRIs (sky only, the track is the ground).
HDRIS = [
    {"id": "qwantani_late_afternoon_puresky", "res": "2k",
     "why": "clear late-afternoon sky, low sun (sun at 19 degrees): an alternative"},
    {"id": "kloofendal_48d_partly_cloudy_puresky", "res": "2k",
     "why": "partly cloudy, sun at 48 degrees: the default sky (TrackLook.DEFAULT_HDRI)"},
    {"id": "syferfontein_18d_clear_puresky", "res": "2k",
     "why": "clear, sun at 18 degrees: evening alternative"},
]


# Photo-scanned PBR materials. kind "detail" = luminance-only pack (the shader keeps the
# track's colour), "albedo" = the photo's colour. tile_m = metres covered by one texture.
MATERIALS = [
    {"name": "asphalt", "source": "polyhaven", "id": "asphalt_track", "res": "2k", "out": 2048,
     "kind": "detail", "why": "road surface (racing line, marks, patches and paint drawn on top)"},
    {"name": "grass", "source": "ambientcg", "id": "Grass001", "res": "2K-JPG", "out": 2048,
     "kind": "albedo", "tile_m": 1.4, "why": "grass verges and terrain near the camera"},
    {"name": "gravel", "source": "ambientcg", "id": "Gravel023", "res": "1K-JPG", "out": 1024,
     "kind": "albedo", "why": "gravel traps"},
    {"name": "concrete", "source": "ambientcg", "id": "Concrete034", "res": "1K-JPG", "out": 1024,
     "kind": "albedo", "why": "concrete walls, kerb surface texture"},
    {"name": "metal", "source": "ambientcg", "id": "Metal032", "res": "1K-JPG", "out": 1024,
     "kind": "albedo", "why": "armco barriers"},
]


def _get(url: str) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def _json(url: str) -> dict:
    return json.loads(_get(url).decode("utf-8"))


def _cached(url: str, md5: str | None = None) -> Path:
    dst = CACHE / url.split("/")[-1]
    if dst.exists() and (md5 is None or hashlib.md5(dst.read_bytes()).hexdigest() == md5):
        return dst
    CACHE.mkdir(parents=True, exist_ok=True)
    print(f"  downloading {url}")
    data = _get(url)
    if md5 is not None and hashlib.md5(data).hexdigest() != md5:
        raise RuntimeError(f"md5 mismatch for {url}")
    dst.write_bytes(data)
    return dst


# ----------------------------------------------------------------------------- Radiance HDR
def read_hdr(path: Path) -> np.ndarray:
    """Radiance RGBE file -> float32 (h, w, 3). Handles flat and new-style RLE scanlines."""
    data = path.read_bytes()
    pos = 0
    w = h = 0
    while True:
        end = data.index(b"\n", pos)
        line = data[pos:end].decode("ascii", "replace").strip()
        pos = end + 1
        if line.startswith("-Y"):
            parts = line.split()
            h, w = int(parts[1]), int(parts[3])
            break
    buf = np.frombuffer(data, dtype=np.uint8, offset=pos)
    out = np.zeros((h, w, 4), np.uint8)
    i = 0
    for y in range(h):
        if w >= 8 and w < 32768 and buf[i] == 2 and buf[i + 1] == 2 and (buf[i + 2] & 0x80) == 0:
            i += 4
            for c in range(4):
                x = 0
                row = out[y, :, c]
                while x < w:
                    n = int(buf[i])
                    i += 1
                    if n > 128:
                        n -= 128
                        row[x:x + n] = buf[i]
                        i += 1
                    else:
                        row[x:x + n] = buf[i:i + n]
                        i += n
                    x += n
        else:
            out[y] = buf[i:i + 4 * w].reshape(w, 4)
            i += 4 * w
    e = out[..., 3].astype(np.int32)
    scale = np.where(e > 0, np.ldexp(1.0, e - 136), 0.0).astype(np.float32)
    return out[..., :3].astype(np.float32) * scale[..., None]


def find_sun(img: np.ndarray) -> dict:
    """Sun direction (game compass convention, unrotated Godot panorama) and colour."""
    h, w, _ = img.shape
    lum = img @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    lum[h // 2:] = 0.0                                  # the sun is above the horizon
    peak = float(lum.max())
    mask = lum > peak * 0.5
    ys, xs = np.nonzero(mask)
    wts = lum[ys, xs]
    # Average as unit vectors (the sun may straddle u = 0 / 1), in the game's frame.
    elev = (0.5 - (ys + 0.5) / h) * math.pi
    azim = math.pi * 0.5 - (xs + 0.5) / w * 2.0 * math.pi
    x = np.sum(wts * np.sin(azim) * np.cos(elev))
    z = np.sum(wts * -np.cos(azim) * np.cos(elev))
    y = np.sum(wts * np.sin(elev))
    n = math.sqrt(x * x + y * y + z * z)
    x, y, z = x / n, y / n, z / n
    az = math.degrees(math.atan2(x, -z)) % 360.0
    el = math.degrees(math.asin(max(-1.0, min(1.0, y))))
    col = (img[ys, xs] * wts[:, None]).sum(0) / wts.sum()
    col = col / col.max()
    return {"sun_azimuth_deg": round(az, 2), "sun_elevation_deg": round(el, 2),
            "sun_color": [round(float(c), 3) for c in col], "sun_peak": round(peak, 1)}


# ----------------------------------------------------------------------------- assets
def fetch_hdris(credits: list[dict]) -> dict:
    sky_dir = OUT_DIR / "sky"
    sky_dir.mkdir(parents=True, exist_ok=True)
    skies = {}
    for a in HDRIS:
        aid = a["id"]
        info = _json(f"https://api.polyhaven.com/info/{aid}")
        files = _json(f"https://api.polyhaven.com/files/{aid}")
        f = files["hdri"][a["res"]]["hdr"]
        src = _cached(f["url"], f.get("md5"))
        dst = sky_dir / f"{aid}.hdr"
        if not dst.exists() or dst.read_bytes() != src.read_bytes():
            dst.write_bytes(src.read_bytes())
        sun = find_sun(read_hdr(src))
        skies[aid] = {"file": f"res://{dst.relative_to(ROOT).as_posix()}", **sun}
        print(f"  {aid}: sun az {sun['sun_azimuth_deg']} el {sun['sun_elevation_deg']}")
        credits.append({"name": info.get("name", aid), "file": dst.relative_to(OUT_DIR).as_posix(),
                        "url": f"https://polyhaven.com/a/{aid}", "author": ", ".join(info.get("authors", {})),
                        "licence": "CC0 1.0", "source": "Poly Haven", "note": a["why"]})
    (sky_dir / "skies.json").write_text(json.dumps(skies, indent=2) + "\n")
    return skies


def _maps_polyhaven(m: dict) -> tuple[dict, dict]:
    aid = m["id"]
    info = _json(f"https://api.polyhaven.com/info/{aid}")
    files = _json(f"https://api.polyhaven.com/files/{aid}")
    want = {"color": "Diffuse", "normal": "nor_gl", "arm": "arm"}
    paths = {}
    for key, name in want.items():
        f = files[name][m["res"]]["jpg"]
        paths[key] = _cached(f["url"], f.get("md5"))
    dims = info.get("dimensions") or [2000, 2000]
    meta = {"name": info.get("name", aid), "author": ", ".join(info.get("authors", {})),
            "url": f"https://polyhaven.com/a/{aid}", "source": "Poly Haven",
            "tile_m": float(dims[0]) / 1000.0}
    return paths, meta


def _maps_ambientcg(m: dict) -> tuple[dict, dict]:
    import zipfile
    aid = m["id"]
    a = _json(f"https://ambientcg.com/api/v2/full_json?type=Material&id={aid}"
              "&include=downloadData,dimensionsData")["foundAssets"][0]
    url = next(d["fullDownloadPath"] for d in
               a["downloadFolders"]["default"]["downloadFiletypeCategories"]["zip"]["downloads"]
               if d["attribute"] == m["res"])
    zpath = _cached(url) if (CACHE / url.split("/")[-1]).exists() else None
    if zpath is None:
        dst = CACHE / f"{aid}_{m['res']}.zip"
        if not dst.exists():
            print(f"  downloading {url}")
            CACHE.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(_get(url))
        zpath = dst
    out = CACHE / f"{aid}_{m['res']}"
    out.mkdir(exist_ok=True)
    paths = {}
    with zipfile.ZipFile(zpath) as z:
        for n in z.namelist():
            base = Path(n).name                      # never trust the paths inside the zip
            for key, tag in (("color", "_Color."), ("normal", "_NormalGL."), ("rough", "_Roughness."),
                             ("ao", "_AmbientOcclusion.")):
                if tag in base and base.lower().endswith((".jpg", ".png")):
                    dst = out / base
                    if not dst.exists():
                        dst.write_bytes(z.read(n))
                    paths[key] = dst
    tile = m.get("tile_m") or (float(a.get("dimensionX") or 200) / 100.0)
    meta = {"name": aid, "author": "Lennart Demes (ambientCG)", "url": f"https://ambientcg.com/a/{aid}",
            "source": "ambientCG", "tile_m": tile}
    return paths, meta


def fetch_materials(credits: list[dict]) -> dict:
    from PIL import Image
    pdir = OUT_DIR / "photo"
    pdir.mkdir(parents=True, exist_ok=True)
    table = {}
    for m in MATERIALS:
        paths, meta = (_maps_polyhaven if m["source"] == "polyhaven" else _maps_ambientcg)(m)
        n = m["out"]

        def load(key: str, mode: str) -> np.ndarray:
            im = Image.open(paths[key]).convert(mode)
            if im.size != (n, n):
                im = im.resize((n, n), Image.LANCZOS)
            return np.asarray(im).astype(np.float32) / 255.0

        color = load("color", "RGB")
        if "arm" in paths:
            arm = load("arm", "RGB")
            ao, rough = arm[..., 0], arm[..., 1]
        else:
            rough = load("rough", "L") if "rough" in paths else np.full((n, n), 0.8, np.float32)
            ao = load("ao", "L") if "ao" in paths else np.ones((n, n), np.float32)
        written = []
        if m["kind"] == "detail":
            lin = color ** 2.2
            lum = lin @ np.array([0.2126, 0.7152, 0.0722], np.float32)
            lum = lum * (0.25 / max(float(lum.mean()), 1e-4))
            pack = np.stack([np.clip(lum, 0, 1), rough, ao, np.ones_like(ao)], axis=-1)
            name = f"{m['name']}_detail.webp"
        else:
            pack = np.concatenate([color, rough[..., None]], axis=-1)
            name = f"{m['name']}_albedo.webp"
        Image.fromarray((pack * 255.0 + 0.5).astype(np.uint8), "RGBA").save(pdir / name, quality=90, method=6)
        written.append(name)
        nrm = load("normal", "RGB")
        Image.fromarray((nrm * 255.0 + 0.5).astype(np.uint8), "RGB").save(
            pdir / f"{m['name']}_normal.webp", quality=92, method=6)
        written.append(f"{m['name']}_normal.webp")
        table[m["name"]] = {"tile_m": meta["tile_m"], "files": written, "kind": m["kind"],
                            "mean_rgb": [round(float(c), 4) for c in color.reshape(-1, 3).mean(0)]}
        for w in written:
            credits.append({"name": meta["name"], "file": f"photo/{w}", "url": meta["url"],
                            "author": meta["author"], "licence": "CC0 1.0", "source": meta["source"],
                            "note": m["why"]})
        print(f"  {m['name']}: {m['id']} tile {meta['tile_m']} m -> {', '.join(written)}")
    (pdir / "materials.json").write_text(json.dumps(table, indent=2) + "\n")
    return table


def write_credits(credits: list[dict]) -> None:
    lines = ["# Credits of the detailed-look assets", "",
             "Every file below is CC0 1.0 (public domain dedication): no attribution is required,",
             "the list is kept so each file can be traced to its source. Generated by",
             "cad/track/fetch_cc0_assets.py; originals in ~/.cache/fun-racer/cc0/.",
             "The procedural textures of this folder (asphalt_*.png, the \"generated\" style) are",
             "original work generated by cad/track/look_textures.py.", "",
             "| File | Asset | Author | Source | Licence | Use |", "|---|---|---|---|---|---|"]
    for c in credits:
        lines.append(f"| {c['file']} | [{c['name']}]({c['url']}) | {c['author']} | {c['source']} "
                     f"| {c['licence']} | {c['note']} |")
    (OUT_DIR / "CREDITS.md").write_text("\n".join(lines) + "\n")


def main() -> int:
    credits: list[dict] = []
    fetch_hdris(credits)
    fetch_materials(credits)
    write_credits(credits)
    return 0


if __name__ == "__main__":
    sys.exit(main())
