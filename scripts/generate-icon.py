#!/usr/bin/env python3
"""Generate the supacode-linux app icon (white "SC" on a charcoal tile).

Writes images/gnome/<size>.png at every size the Zig build installs into the
hicolor icon theme (see src/build/GhosttyResources.zig). The mark matches the
macOS supacode icon: a bold white "SC" monogram on a dark charcoal tile that
vignettes toward near-black at the edges, with rounded (squircle-ish) corners.

Rendered at 8x supersample then downscaled with Lanczos for crisp small sizes.

Usage:
    python3 scripts/generate-icon.py
"""
from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont, ImageFilter
except ImportError:
    sys.exit("Pillow is required: pip install Pillow")

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "images" / "gnome"
SIZES = [16, 32, 64, 128, 256, 512, 1024, 2048]
SS = 4  # supersample factor (2048 master -> 8192 would be huge; 4x is plenty)

# Pick a bold sans font; fall back across common locations.
FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]

# Match the macOS supacode icon.
BG_CENTER = (32, 32, 33)   # charcoal (dominant tone)
BG_EDGE = (10, 10, 11)     # near-black edges / vignette
TEXT = (255, 255, 255)     # white monogram


def font_path() -> str:
    for p in FONT_CANDIDATES:
        if Path(p).exists():
            return p
    sys.exit("no bold sans font found; edit FONT_CANDIDATES")


def render_master(px: int) -> Image.Image:
    S = px * SS
    radius = int(S * 0.22)  # rounded-square (macOS squircle-ish)

    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=radius, fill=255)

    # Radial vignette: charcoal center -> near-black edges. Built small then
    # upscaled (per-pixel at full supersample would be too slow).
    tile = Image.new("RGBA", (S, S), BG_EDGE + (255,))
    g = 256
    grad_s = Image.new("L", (g, g), 0)
    gpx = grad_s.load()
    gc = (g - 1) / 2
    gmax = (gc ** 2 + gc ** 2) ** 0.5
    for y in range(g):
        for x in range(g):
            dist = ((x - gc) ** 2 + (y - gc) ** 2) ** 0.5 / gmax
            gpx[x, y] = max(0, min(255, int(255 * (1 - dist ** 1.4))))
    grad = grad_s.resize((S, S), Image.BILINEAR)
    center = Image.new("RGBA", (S, S), BG_CENTER + (255,))
    center.putalpha(grad)
    tile = Image.alpha_composite(tile, center)

    text = "SC"
    font = ImageFont.truetype(font_path(), int(S * 0.44))
    spacing = int(S * 0.010)

    widths, bboxes = [], []
    for ch in text:
        bb = font.getbbox(ch)
        bboxes.append(bb)
        widths.append(bb[2] - bb[0])
    total_w = sum(widths) + spacing * (len(text) - 1)

    # Vertically center on glyph ink, nudged a hair above middle (macOS look).
    ink_top = min(bb[1] for bb in bboxes)
    ink_bot = max(bb[3] for bb in bboxes)
    ink_h = ink_bot - ink_top
    start_x = (S - total_w) / 2
    y = (S - ink_h) / 2 - ink_top - S * 0.015

    # Soft drop shadow for depth on the charcoal.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow)
    x = start_x
    for ch, w, bb in zip(text, widths, bboxes):
        sdraw.text((x - bb[0], y + S * 0.008), ch, font=font, fill=(0, 0, 0, 130))
        x += w + spacing
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.010))
    tile = Image.alpha_composite(tile, shadow)

    d = ImageDraw.Draw(tile)
    x = start_x
    for ch, w, bb in zip(text, widths, bboxes):
        d.text((x - bb[0], y), ch, font=font, fill=TEXT)
        x += w + spacing

    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(tile, (0, 0), mask)
    return out


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    master = render_master(max(SIZES))
    for s in SIZES:
        img = master.resize((s, s), Image.LANCZOS)
        img.save(OUT / f"{s}.png")
        print(f"wrote images/gnome/{s}.png")
    print("done")


if __name__ == "__main__":
    main()
