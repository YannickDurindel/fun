"""Detail textures of the opt-in "detailed" track look (environment.json "look": "detailed").

Written to assets/tracks/_shared/look_detailed/ and shared by every track that opts in;
the per-track road_textures.py output is untouched, so tracks without the flag stay
byte-identical. Everything is procedural (fixed seeds, periodic frequency-domain noise), so
the textures tile without seams and regenerate byte for byte.

* asphalt_detail.png  1024^2 RGBA, one tile = 1.6 m of road (a second scale at 4.3 m breaks the repeat):
      R albedo of the aggregate (stones of several tones in dark binder)
      G roughness (polished stone tops smoother than the binder)
      B cavity (dark pores between stones, ambient occlusion-like)
      A height (unused by the shader, kept for the normal map and future parallax)
* asphalt_normal.png  1024^2 RGB tangent-space normal map of that height (OpenGL, +Y up).
* asphalt_macro.png   512^2 RGB, one tile = 160 m (world XZ):
      R large blotches (colour drift, old / new surfacing)
      G mid streaks (stretched 8:1 along U: tyre marks, wear lanes)
      B fine mottling (binder bleeding, stains)
  (also the large-scale variation of the realistic grass, terrain and run-off)

* boards.png          1280x1024 RGB atlas of 16 advertising boards (2 columns x 8 rows of
                      640x128, a 5 m x 1 m board each) for FICTIONAL brands: colour blocks,
                      the name in Barlow Condensed (assets/ui/fonts, SIL OFL) and simple
                      graphic marks. Used by TrackDressing (realistic style).
* distance_boards.png 768x256 RGB: the 300 / 200 / 100 m braking boards (256x256 each).

Run: .venv/bin/python cad/track/look_textures.py
"""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "assets" / "tracks" / "_shared" / "look_detailed"


def _band_noise(rng: np.random.Generator, n: int, f_lo: float, f_hi: float,
                stretch: float = 1.0) -> np.ndarray:
    """Periodic noise with energy between f_lo..f_hi cycles per tile; `stretch` > 1 makes
    the features that many times longer along axis 1 (U) than along axis 0 (V)."""
    white = rng.standard_normal((n, n))
    f = np.fft.fftfreq(n) * n
    r = np.hypot(f[:, None], f[None, :] * stretch)
    mid = 0.5 * (f_lo + f_hi)
    mask = np.exp(-0.5 * ((r - mid) / max(0.5 * (f_hi - f_lo), 1.0)) ** 2)
    out = np.real(np.fft.ifft2(np.fft.fft2(white) * mask))
    return (out - out.mean()) / (out.std() + 1e-12)


def _cells(rng: np.random.Generator, n: int, count: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Periodic Voronoi per pixel: (distance to the nearest seed, distance to the cell border
    estimate = second - nearest, id of the nearest seed), in pixels."""
    from scipy.spatial import cKDTree
    pts = rng.random((count, 2)) * n
    yy, xx = np.mgrid[0:n, 0:n]
    q = np.stack([yy.ravel() + 0.5, xx.ravel() + 0.5], axis=-1)
    d, i = cKDTree(pts, boxsize=n).query(q, k=2)
    best = d[:, 0].reshape(n, n).astype(np.float32)
    second = d[:, 1].reshape(n, n).astype(np.float32)
    ident = i[:, 0].reshape(n, n)
    return best, second - best, ident


def asphalt_detail(n: int = 1024) -> tuple[np.ndarray, np.ndarray]:
    """(RGBA float image, height) of the aggregate tile."""
    rng = np.random.default_rng(2401)
    # Stones: Voronoi cells (~10 px = 1.6 cm apart at 1.6 m / 1024 px); each a tone of its own,
    # rounded tops (height from the distance to the cell border).
    count = int(n * n / 95.0)
    _, edge, ident = _cells(rng, n, count)
    tone = rng.random(count).astype(np.float32)[ident]
    exposed = rng.random(count).astype(np.float32)[ident]        # stone sticks out or sunk in binder
    rise = np.clip((edge - 2.2) / 3.0, 0.0, 1.0)                   # binder gap ~2 px, then a rounded stone
    stone = np.where(exposed > 0.25, rise, rise * 0.35)
    fine = _band_noise(rng, n, 180, 400)                           # sand in the binder
    blotch = _band_noise(rng, n, 3, 10)
    height = 0.65 * stone ** 0.6 + 0.08 * fine
    height = (height - height.min()) / (height.max() - height.min())
    # Albedo: binder dark, stones grey with a spread of tones, a few bright quartz chips.
    quartz = (tone > 0.988).astype(np.float32)
    stone_alb = 0.34 + 0.20 * tone + 0.30 * quartz
    binder = 0.17 + 0.03 * fine
    alb = binder + (stone_alb - binder) * np.clip(stone * 1.2, 0.0, 1.0) ** 0.8
    alb *= 1.0 + 0.05 * blotch
    # Roughness: binder matte, stone tops worn smoother by tyres.
    rough = 0.94 - 0.22 * np.clip(stone, 0, 1) * (exposed > 0.25) + 0.03 * fine
    cavity = np.clip(0.55 + 0.6 * rise + 0.05 * fine, 0.0, 1.0)
    img = np.stack([np.clip(alb, 0, 1), np.clip(rough, 0, 1), cavity, height], axis=-1)
    return img, height


def normal_from_height(h: np.ndarray, strength: float) -> np.ndarray:
    """Tangent-space normal map (OpenGL convention, rows go down = -V) of a periodic height."""
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5 * strength
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5 * strength
    nx, ny, nz = -dx, dy, np.ones_like(h)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    return np.stack([nx * inv * 0.5 + 0.5, ny * inv * 0.5 + 0.5, nz * inv * 0.5 + 0.5], axis=-1)


def asphalt_macro(n: int = 512) -> np.ndarray:
    rng = np.random.default_rng(1923)
    big = _band_noise(rng, n, 1, 5) * 0.7 + _band_noise(rng, n, 5, 14) * 0.3
    streak = _band_noise(rng, n, 20, 90, stretch=8.0)
    mottle = _band_noise(rng, n, 40, 140) * 0.7 + _band_noise(rng, n, 10, 30) * 0.3
    to01 = lambda a: np.clip(0.5 + 0.18 * a, 0, 1)  # noqa: E731
    return np.stack([to01(big), to01(streak), to01(mottle)], axis=-1)


def _write_png(path: Path, img: np.ndarray) -> None:
    a = np.clip(img * 255.0 + 0.5, 0, 255).astype(np.uint8)
    h, w = a.shape[:2]
    ch = 1 if a.ndim == 2 else a.shape[2]
    ctype = {1: 0, 3: 2, 4: 6}[ch]
    rows = a.reshape(h, w * ch)
    raw = b"".join(b"\x00" + rows[y].tobytes() for y in range(h))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


BRANDS = [
    # name, background, text colour, accent colour
    ("VELOCITA", (200, 20, 30), (255, 255, 255), (255, 210, 0)),
    ("NORDLUX", (10, 40, 110), (255, 255, 255), (90, 200, 255)),
    ("ARCTURA TYRES", (250, 205, 0), (20, 20, 20), (20, 20, 20)),
    ("KESTREL OIL", (0, 110, 70), (255, 255, 255), (250, 200, 40)),
    ("SOLARIS", (255, 120, 0), (255, 255, 255), (40, 40, 40)),
    ("MERIDIAN BANK", (240, 240, 240), (10, 40, 90), (200, 30, 40)),
    ("BLUEFIN", (0, 150, 210), (255, 255, 255), (0, 60, 120)),
    ("HALCYON WATCHES", (20, 60, 40), (230, 200, 120), (230, 200, 120)),
    ("TORQUE ENERGY", (30, 30, 30), (120, 230, 40), (120, 230, 40)),
    ("OCTAVE", (120, 20, 120), (255, 255, 255), (255, 170, 230)),
    ("GRANITE", (90, 95, 100), (255, 255, 255), (255, 90, 40)),
    ("PELICAN AIR", (255, 255, 255), (0, 90, 170), (0, 170, 200)),
    ("RAPIDO", (230, 0, 80), (255, 255, 255), (255, 255, 255)),
    ("ALPENGLOW", (0, 70, 140), (255, 210, 60), (255, 210, 60)),
    ("CIRRUS", (210, 230, 245), (20, 60, 120), (20, 120, 200)),
    ("FORGE MOTORS", (15, 15, 20), (230, 30, 30), (200, 200, 200)),
]
FONT = ROOT / "assets" / "ui" / "fonts" / "BarlowCondensed-BoldItalic.ttf"


def boards() -> "object":
    from PIL import Image, ImageDraw, ImageFont
    cw, ch = 640, 128
    atlas = Image.new("RGB", (cw * 2, ch * 8))
    rng = np.random.default_rng(1923)
    for i, (name, bg, fg, acc) in enumerate(BRANDS):
        cell = Image.new("RGB", (cw, ch), bg)
        d = ImageDraw.Draw(cell)
        style = i % 4
        if style == 1:                      # diagonal accent band on the left
            d.polygon([(0, 0), (150, 0), (110, ch), (0, ch)], fill=acc)
        elif style == 2:                    # stripes at the bottom
            d.rectangle([0, ch - 22, cw, ch - 14], fill=acc)
            d.rectangle([0, ch - 10, cw, ch - 4], fill=acc)
        elif style == 3:                    # a round mark
            d.ellipse([20, 20, 108, 108], fill=acc)
            d.ellipse([44, 44, 84, 84], fill=bg)
        size = 92 if len(name) < 10 else 74
        font = ImageFont.truetype(str(FONT), size)
        tw = d.textlength(name, font=font)
        x0 = (cw - tw) / 2 + (55 if style in (1, 3) else 0)
        d.text((x0, (ch - size) / 2 - 8), name, font=font, fill=fg)
        # A little dirt and sun fading.
        arr = np.asarray(cell).astype(np.float32)
        arr *= 0.93 + 0.07 * rng.random((ch, cw, 1))
        cell = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
        atlas.paste(cell, ((i % 2) * cw, (i // 2) * ch))
    return atlas


def distance_boards() -> "object":
    from PIL import Image, ImageDraw, ImageFont
    img = Image.new("RGB", (768, 256), (255, 255, 255))
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(str(FONT), 170)
    for i, txt in enumerate(("300", "200", "100")):
        x = i * 256
        d.rectangle([x + 6, 6, x + 249, 249], outline=(20, 20, 20), width=10)
        tw = d.textlength(txt, font=font)
        d.text((x + (256 - tw) / 2, 18), txt, font=font, fill=(15, 15, 15))
    return img


def write_all(out_dir: Path = OUT_DIR) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    detail, height = asphalt_detail()
    paths = [out_dir / "asphalt_detail.png", out_dir / "asphalt_normal.png", out_dir / "asphalt_macro.png"]
    _write_png(paths[0], detail)
    _write_png(paths[1], normal_from_height(height, strength=6.0))
    _write_png(paths[2], asphalt_macro())
    paths += [out_dir / "boards.png", out_dir / "distance_boards.png"]
    boards().save(paths[3], optimize=True)
    distance_boards().save(paths[4], optimize=True)
    return paths


if __name__ == "__main__":
    for p in write_all(Path(sys.argv[1]) if len(sys.argv) > 1 else OUT_DIR):
        print(p.relative_to(ROOT) if p.is_relative_to(ROOT) else p)
