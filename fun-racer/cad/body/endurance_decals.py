#!/usr/bin/env python3
"""Textures of the endurance car's materials and decals (Pillow only, deterministic).

    .venv/bin/python cad/body/endurance_decals.py     # -> assets/car/endurance/textures/*.png

Writes the carbon-fibre weave (albedo + roughness, tiled; the material maps it triplanar,
since body.glb has no UVs) and the decal images that scenes/car/endurance_body_visual.tscn
projects with Decal nodes: race-number roundels, sponsor panels, pinstripes. Every sponsor
name is made up; no real logo or brand is drawn.
"""

from __future__ import annotations

import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "assets" / "car" / "endurance" / "textures"
FONT = REPO / "assets" / "ui" / "fonts" / "BarlowCondensed-BoldItalic.ttf"
FONT_SEMI = REPO / "assets" / "ui" / "fonts" / "BarlowCondensed-SemiBoldItalic.ttf"

NUMBER = "50"
RED = (200, 16, 20)
YELLOW = (250, 205, 20)
WHITE = (246, 246, 242)
BLACK = (18, 18, 20)
BLUE = (24, 52, 150)


def font(size: int, semi: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONT_SEMI if semi else FONT), size)


def centred_text(d: ImageDraw.ImageDraw, box, text, f, fill, stroke=0, stroke_fill=None):
    x0, y0, x1, y1 = box
    l, t, r, b = d.textbbox((0, 0), text, font=f, stroke_width=stroke)
    d.text(((x0 + x1 - (r - l)) / 2 - l, (y0 + y1 - (b - t)) / 2 - t), text, font=f, fill=fill,
           stroke_width=stroke, stroke_fill=stroke_fill)


def fit_font(d, text, max_w, max_h, semi=False):
    size = max_h
    while size > 8:
        f = font(size, semi)
        l, t, r, b = d.textbbox((0, 0), text, font=f)
        if r - l <= max_w and b - t <= max_h:
            return f
        size -= 2
    return font(8, semi)


# --------------------------------------------------------------------------
# Carbon fibre: 2x2 twill, 8 x 8 tows per tile.
# --------------------------------------------------------------------------
def carbon(size: int = 256, tows: int = 8) -> None:
    rng = random.Random(7)
    alb = Image.new("RGB", (size, size))
    rough = Image.new("L", (size, size))
    pa, pr = alb.load(), rough.load()
    cell = size / tows
    noise = [[rng.random() for _ in range(size)] for _ in range(2)]
    for y in range(size):
        for x in range(size):
            i, j = int(x // cell), int(y // cell)
            u, v = (x % cell) / cell, (y % cell) / cell
            warp = (i + j) % 4 < 2  # tow running along v (vertical)
            across = u if warp else v  # position across the tow
            along = v if warp else u
            # Rounded tow cross-section: bright crown, dark edges, faint fibre striations.
            crown = math.sin(math.pi * across) ** 0.6
            fibre = 0.06 * noise[0][(x if warp else y) % size]
            sheen = 0.75 + 0.25 * math.cos(math.pi * (along - 0.5))
            k = (0.30 + 0.70 * crown) * sheen + fibre
            if warp:
                c = 12 + 30 * k
            else:
                c = 8 + 22 * k
            pa[x, y] = (int(c), int(c * 1.02), int(c * 1.08))
            # Anisotropy-like: tows facing one way read glossier than the crossing ones.
            r = (0.24 if warp else 0.38) + 0.10 * (1.0 - crown)
            pr[x, y] = int(255 * min(1.0, r))
    alb.save(OUT / "carbon_albedo.png")
    rough.save(OUT / "carbon_roughness.png")


# --------------------------------------------------------------------------
# Decals (RGBA; transparent outside the shape)
# --------------------------------------------------------------------------
def roundel(size: int = 512) -> None:
    """White disc, yellow ring, red race number: nose and doors."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    m = 6
    d.ellipse((m, m, size - m, size - m), fill=YELLOW + (255,))
    ring = int(size * 0.07)
    d.ellipse((m + ring, m + ring, size - m - ring, size - m - ring), fill=WHITE + (255,))
    inner = (m + ring + 40, m + ring + 40, size - m - ring - 40, size - m - ring - 40)
    f = fit_font(d, NUMBER, inner[2] - inner[0], int((inner[3] - inner[1]) * 0.70))
    centred_text(d, inner, NUMBER, f, RED + (255,))
    img.save(OUT / "decal_roundel.png")


def panel(name: str, text: str, bg, fg, w: int = 512, h: int = 128, border=None, sub: str = "") -> None:
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = h // 6
    if bg is not None:
        d.rounded_rectangle((2, 2, w - 3, h - 3), r, fill=bg + (255,),
                            outline=(border + (255,)) if border else None, width=6 if border else 0)
    pad = h // 6
    main_h = int((h - 2 * pad) * (0.70 if sub else 0.9))
    f = fit_font(d, text, w - 2 * pad, main_h)
    centred_text(d, (pad, pad, w - pad, pad + main_h), text, f, fg + (255,))
    if sub:
        fs = fit_font(d, sub, w - 2 * pad, h - 2 * pad - main_h, semi=True)
        centred_text(d, (pad, pad + main_h, w - pad, h - pad), sub, fs, fg + (255,))
    img.save(OUT / f"decal_{name}.png")


def pinstripe(w: int = 1024, h: int = 32) -> None:
    """Yellow double pinstripe with soft edges along the flanks."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle((0, 4, w, 11), fill=YELLOW + (255,))
    d.rectangle((0, 18, w, 22), fill=WHITE + (255,))
    # Taper the ends so the stripe fades in and out.
    a = img.getchannel("A")
    pa = a.load()
    for x in range(64):
        k = x / 64.0
        for y in range(h):
            pa[x, y] = int(pa[x, y] * k)
            pa[w - 1 - x, y] = int(pa[w - 1 - x, y] * k)
    img.putalpha(a.filter(ImageFilter.GaussianBlur(0.6)))
    img.save(OUT / "decal_pinstripe.png")


def sticker_sheet(w: int = 512, h: int = 256) -> None:
    """A cluster of small colourful made-up sponsor stickers (rear fenders)."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    items = [
        ((0, 0, 250, 120), WHITE, BLUE, "KESTREL"),
        ((262, 0, 512, 120), BLUE, WHITE, "ORBIQ"),
        ((0, 134, 160, 256), BLACK, YELLOW, "MX"),
        ((172, 134, 512, 256), WHITE, RED, "VELTRO"),
    ]
    for (x0, y0, x1, y1), bg, fg, text in items:
        d.rounded_rectangle((x0 + 2, y0 + 2, x1 - 2, y1 - 2), 14, fill=bg + (255,))
        f = fit_font(d, text, x1 - x0 - 28, int((y1 - y0) * 0.66))
        centred_text(d, (x0, y0, x1, y1), text, f, fg + (255,))
    img.save(OUT / "decal_stickers.png")


# Flank decal: the Mobile renderer applies at most 8 decals to one mesh (and the car's
# meshes span the whole car, so 8 for the car), so everything on a
# door (roundel, sponsor name, sticker cluster, pinstripe) is one image per side. It covers
# CAD x -0.60 .. 1.10 and z -0.115 .. 0.135 (see endurance_body_visual.tscn).
SIDE_X0, SIDE_X1, SIDE_Z0, SIDE_Z1 = -0.60, 1.10, -0.115, 0.135
SIDE_PX_PER_M = 1200


# Rear decal per side: the race number on the shark fin and a sponsor on the wing end plate,
# one image covering CAD x 1.45 .. 2.55, z 0.40 .. 0.75 (projected through from the side;
# the two never overlap in x, so nothing in between is painted).
REAR_X0, REAR_X1, REAR_Z0, REAR_Z1 = 1.45, 2.55, 0.40, 0.75


def _sheet(x0, x1, z0, z1, ppm, front_left):
    w, h = round((x1 - x0) * ppm), round((z1 - z0) * ppm)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    def place(src: Image.Image, cx: float, cz: float, sw: float, sh: float) -> None:
        pw, ph = round(sw * ppm), round(sh * ppm)
        px = (cx - x0) * ppm
        if not front_left:
            px = w - px
        py = (z1 - cz) * ppm
        im = src.resize((pw, ph), Image.LANCZOS)
        img.alpha_composite(im, (round(px - pw / 2), round(py - ph / 2)))

    return img, place


def rear(front_left: bool) -> None:
    img, place = _sheet(REAR_X0, REAR_X1, REAR_Z0, REAR_Z1, 800, front_left)
    place(Image.open(OUT / "decal_fin.png"), 1.62, 0.58, 0.24, 0.24)
    place(Image.open(OUT / "decal_veltro.png"), 2.32, 0.56, 0.44, 0.11)
    img.save(OUT / f"decal_rear_{'l' if front_left else 'r'}.png")


def flank(front_left: bool) -> None:
    img, place = _sheet(SIDE_X0, SIDE_X1, SIDE_Z0, SIDE_Z1, SIDE_PX_PER_M, front_left)
    place(Image.open(OUT / "decal_pinstripe.png"), 0.25, -0.098, 1.70, 0.030)
    place(Image.open(OUT / "decal_marlo.png"), 0.78, 0.085, 0.50, 0.094)
    place(Image.open(OUT / "decal_stickers.png"), 0.74, -0.035, 0.26, 0.13)
    place(Image.open(OUT / "decal_roundel.png"), 0.15, -0.012, 0.215, 0.215)
    img.save(OUT / f"decal_flank_{'l' if front_left else 'r'}.png")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    carbon()
    roundel()
    panel("altura", "ALTURA", WHITE, BLUE, border=BLUE, sub="AIR GROUP")
    panel("marlo", "MARLO", None, WHITE, w=512, h=96)
    panel("veltro", "VELTRO", None, WHITE, w=512, h=128)
    panel("sun", "CORSA NOVA", None, BLACK, w=1024, h=96)
    panel("fin", NUMBER, None, WHITE, w=256, h=256)
    pinstripe()
    sticker_sheet()
    flank(True)
    flank(False)
    rear(True)
    rear(False)
    for part in ("marlo", "pinstripe", "stickers", "fin", "veltro"):  # only used inside the flank images
        (OUT / f"decal_{part}.png").unlink()
    print(f"textures -> {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
