#!/usr/bin/env python3
"""Draws the images of the Plymouth theme "ruyaos" (T-269) into
image/rootfs/usr/share/plymouth/themes/ruyaos/.

    python -I scripts/make-boot-assets.py          (needs Pillow; run from the repository root)

The PNGs are committed, so the image build needs neither Pillow nor a font: the wordmark is
the name "RuyaOS" set in Inter SemiBold (shell/fonts), "Ruya" in the text colour and "OS" in
the lightened Ruya indigo (Theme.defaultTint #3a5bd9). There is no logo yet (owner decision,
Inbox: design: needs logo); when there is one, replace wordmark.png and nothing else changes.
The output is deterministic, so a re-run leaves no diff.
"""
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "image", "rootfs", "usr", "share", "plymouth", "themes", "ruyaos")
FONT = os.path.join(ROOT, "shell", "fonts", "Inter-SemiBold.ttf")

# Dreamglass (04 section 3.1): ground #05070d, text #f2f4f8, indigo tint #3a5bd9, settings violet #7a5bd9.
GROUND = (5, 7, 13)
TOP = (11, 16, 30)
TEXT = (242, 244, 248)
ACCENT = (112, 136, 236)  # defaultTint lightened so it reads on the ground
INDIGO = (58, 91, 217)
VIOLET = (122, 91, 217)


def background(w=1280, h=720):
    """A vertical gradient with two faint blobs (the shell's backdrop look), dithered."""
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        c = tuple(round(TOP[i] + (GROUND[i] - TOP[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c
    for (cx, cy, rx, ry, color, alpha) in (
        (0.30, 0.36, 0.42, 0.55, INDIGO, 0.16),
        (0.74, 0.72, 0.36, 0.48, VIOLET, 0.10),
    ):
        layer = Image.new("L", (w, h), 0)
        d = ImageDraw.Draw(layer)
        d.ellipse([w * (cx - rx / 2), h * (cy - ry / 2), w * (cx + rx / 2), h * (cy + ry / 2)], fill=round(255 * alpha))
        layer = layer.filter(ImageFilter.GaussianBlur(h * 0.16))
        img = Image.composite(Image.new("RGB", (w, h), color), img, layer)
    # Dither: +-1 level of noise hides banding in the dark gradient.
    rnd = random.Random(269)
    noise = Image.new("L", (w, h))
    noise.putdata([rnd.choice((0, 1, 1, 2)) for _ in range(w * h)])
    shift = Image.merge("RGB", (noise, noise, noise))
    img = ImageChops.add(img, shift, scale=1.0, offset=-1)
    return img


def wordmark():
    """RuyaOS at twice the size it has on a 1080p screen (the theme scales by height / 1080)."""
    size = 176
    font = ImageFont.truetype(FONT, size)
    a, b = "Ruya", "OS"
    wa = font.getlength(a)
    wb = font.getlength(b)
    ascent, descent = font.getmetrics()
    pad = 24
    img = Image.new("RGBA", (round(wa + wb) + 2 * pad, ascent + descent + 2 * pad), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.text((pad, pad), a, font=font, fill=TEXT + (255,))
    d.text((pad + wa, pad), b, font=font, fill=ACCENT + (255,))
    return img.crop(img.getbbox())


def bar(w=512, h=8):
    """A white pill: the track of the progress indicator (drawn faint)."""
    big = Image.new("L", (w * 4, h * 4), 0)
    ImageDraw.Draw(big).rounded_rectangle([0, 0, w * 4 - 1, h * 4 - 1], radius=h * 2, fill=255)
    mask = big.resize((w, h), Image.LANCZOS)
    img = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    img.putalpha(mask)
    return img


def glow(w=256, h=8):
    """The moving part: a pill whose ends fade out, so it slides without hard edges."""
    img = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    px = img.load()
    for x in range(w):
        t = x / (w - 1)
        a = 1.0 - abs(2 * t - 1) ** 2.2
        for y in range(h):
            vy = 1.0 - abs((y + 0.5) / h * 2 - 1) ** 4
            px[x, y] = (255, 255, 255, round(255 * a * vy))
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    background().save(os.path.join(OUT, "bg.png"), optimize=True)
    wordmark().save(os.path.join(OUT, "wordmark.png"), optimize=True)
    bar().save(os.path.join(OUT, "bar.png"), optimize=True)
    glow().save(os.path.join(OUT, "glow.png"), optimize=True)
    for n in sorted(os.listdir(OUT)):
        if n.endswith(".png"):
            print(n, os.path.getsize(os.path.join(OUT, n)), "bytes")


if __name__ == "__main__":
    sys.exit(main())
