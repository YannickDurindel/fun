"""Seamless tiling textures for the road, generated in code (no external images).

* road_tarmac_albedo.png: 512x512 greyscale asphalt aggregate (fine stones + binder blotches).
* road_grass_albedo.png:  256x256 greyscale grass mottling (tinted green in the shader).

All noise is built in the frequency domain on a periodic grid, so every texture tiles
without seams. Seeds are fixed so regeneration is byte-for-byte reproducible.
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

import numpy as np


def _band_noise(rng: np.random.Generator, n: int, f_lo: float, f_hi: float) -> np.ndarray:
    """Periodic noise with energy between spatial frequencies f_lo..f_hi (cycles per tile)."""
    white = rng.standard_normal((n, n))
    f = np.fft.fftfreq(n) * n
    r = np.hypot(f[:, None], f[None, :])
    mask = np.exp(-0.5 * ((r - 0.5 * (f_lo + f_hi)) / max(0.5 * (f_hi - f_lo), 1.0)) ** 2)
    out = np.real(np.fft.ifft2(np.fft.fft2(white) * mask))
    return (out - out.mean()) / (out.std() + 1e-12)


def _write_png_gray(path: Path, img: np.ndarray) -> None:
    a = np.clip(img * 255.0 + 0.5, 0, 255).astype(np.uint8)
    h, w = a.shape
    raw = b"".join(b"\x00" + a[y].tobytes() for y in range(h))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def tarmac(n: int = 512) -> np.ndarray:
    rng = np.random.default_rng(1918)
    stones = _band_noise(rng, n, 60, 160)          # aggregate, ~3-8 px stones
    grit = rng.standard_normal((n, n))              # per-pixel sparkle
    blotch = _band_noise(rng, n, 2, 8)              # binder / wear variation
    v = 0.5 + 0.10 * stones + 0.05 * grit + 0.06 * blotch
    # A few bright quartz chips.
    v += 0.25 * (rng.random((n, n)) > 0.996)
    return np.clip(v, 0.0, 1.0)


def grass(n: int = 256) -> np.ndarray:
    rng = np.random.default_rng(2011)
    v = 0.55 + 0.12 * _band_noise(rng, n, 30, 90) + 0.10 * _band_noise(rng, n, 2, 6)
    v += 0.06 * rng.standard_normal((n, n))
    return np.clip(v, 0.0, 1.0)


def write_all(out_dir: Path) -> list[Path]:
    paths = [out_dir / "road_tarmac_albedo.png", out_dir / "road_grass_albedo.png"]
    _write_png_gray(paths[0], tarmac())
    _write_png_gray(paths[1], grass())
    return paths
