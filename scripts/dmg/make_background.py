#!/usr/bin/env python3
"""Draws the picture behind the icons in the disk image window (arrow + instructions).

Run by hand when the artwork changes; the PNGs it writes are committed, so building the app
does not need Python imaging libraries.

    python3 scripts/dmg/make_background.py
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

W, H = 660, 400                      # window size in points
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "Resources", "dmg")

FONTS = [
    "/System/Library/Fonts/SFNS.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
]
BOLD = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
] + FONTS


def font(candidates, size):
    for path in candidates:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    sys.exit("no usable font found")


def draw(scale):
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h))
    px = img.load()
    # A mid-tone gradient: icon names stay readable in both light and dark Finder appearances.
    top, bottom = (112, 126, 146), (92, 104, 122)
    for y in range(h):
        t = y / (h - 1)
        row = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = row
    d = ImageDraw.Draw(img)

    def centered(text, y, f, fill):
        box = d.textbbox((0, 0), text, font=f)
        d.text(((w - (box[2] - box[0])) / 2 - box[0], y - box[1]), text, font=f, fill=fill)

    centered("Drag Mac Action Recorder onto Applications", 36 * scale, font(BOLD, 24 * scale), (255, 255, 255))

    # Arrow between the two icon positions (icons sit at x=165 and x=495, y=190).
    y = 190 * scale
    x0, x1 = 255 * scale, 405 * scale
    thick = 8 * scale
    head = 26 * scale
    color = (255, 255, 255)
    d.rounded_rectangle([x0, y - thick // 2, x1 - head + 2 * scale, y + thick // 2], radius=thick // 2, fill=color)
    d.polygon([(x1 - head, y - head * 0.75), (x1, y), (x1 - head, y + head * 0.75)], fill=color)

    # Red warning box: tells people what macOS will say the first time, before it happens.
    red = (200, 38, 38)
    d.rounded_rectangle([40 * scale, 292 * scale, 620 * scale, 384 * scale], radius=10 * scale, fill=red)
    bold = font(BOLD, 14 * scale)
    small = font(FONTS, 13 * scale)
    white = (255, 255, 255)
    centered("macOS will say: \u201cApple could not verify Mac Action Recorder\u2026\u201d", 302 * scale, bold, white)
    centered("This is expected: the app is not notarized by Apple. Click Done (NOT Move to Trash),", 328 * scale, small, white)
    centered("then open System Settings > Privacy & Security and click Open Anyway.", 348 * scale, small, white)
    centered("Or in Terminal: xattr -dr com.apple.quarantine \"/Applications/Mac Action Recorder.app\"", 366 * scale, small, white)
    return img


os.makedirs(OUT, exist_ok=True)
draw(1).save(os.path.join(OUT, "background.png"), dpi=(72, 72))
draw(2).save(os.path.join(OUT, "background@2x.png"), dpi=(144, 144))
print("wrote", os.path.normpath(OUT))
