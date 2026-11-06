#!/usr/bin/env python3
"""Generate the bundled wallpapers in shell/assets/wallpapers/ (T-208).

Six 1920x1080 JPEGs in the Dreamglass look (04 section 1): dark rooms lit by soft colour
fields and a few feathered discs, plus one bright one ("Daybreak") that exercises the
legibility rule. Everything is computed from formulas here (gradients, gaussians, smoothstep
discs) and a seeded pseudo-random dither; no photograph, stock image or third-party asset is
used, so the pictures are the project's own work and are released as CC0 1.0 (see
shell/assets/wallpapers/LICENSE-Wallpapers.txt).

Also writes catalog.json: for each wallpaper its id, file, `peak` and `floor`, the 95th and 5th
percentile of the relative luminance (0..1, linear light) of a 64x36 reduction. The shell raises
the dim layer (the theme's background colour) over a picture until the theme's text keeps 4.5:1
over the peak (dark themes) or over the floor (Daylight): Wallpapers::requiredDim, 04 section 3.5.

Needs Pillow and numpy. The output depends on the libjpeg that Pillow bundles, so the committed
files are what one version of Pillow made; a different version may differ in a few bytes.

Usage:  python -I scripts/make-wallpapers.py
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

W, H = 1920, 1080
OUT = Path(__file__).resolve().parent.parent / "shell" / "assets" / "wallpapers"
YY, XX = np.mgrid[0:H, 0:W].astype(np.float32)
NX = XX / W            # 0..1 across
NY = YY / H            # 0..1 down
ASPECT = W / H


def rgb(hexcode):
    h = hexcode.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], dtype=np.float32)


def gradient(c0, c1, angle_deg):
    """Linear gradient from c0 to c1 along a direction (0 = left to right, 90 = top to bottom)."""
    a = np.deg2rad(angle_deg)
    t = (NX - 0.5) * np.cos(a) * ASPECT + (NY - 0.5) * np.sin(a)
    t = (t - t.min()) / (t.max() - t.min())
    return c0[None, None, :] * (1 - t[..., None]) + c1[None, None, :] * t[..., None]


def gaussian(cx, cy, rx, ry):
    """A soft elliptical field, 1 at the centre; radii in units of the screen height."""
    dx = (NX - cx) * ASPECT / rx
    dy = (NY - cy) / ry
    return np.exp(-0.5 * (dx * dx + dy * dy)).astype(np.float32)


def disc(cx, cy, r, feather):
    """A disc of radius r (screen heights) with a feathered edge."""
    d = np.sqrt(((NX - cx) * ASPECT) ** 2 + (NY - cy) ** 2)
    t = np.clip((r + feather - d) / (2 * feather), 0, 1)
    return (t * t * (3 - 2 * t)).astype(np.float32)


def over(img, colour, alpha):
    return img * (1 - alpha[..., None]) + colour[None, None, :] * alpha[..., None]


def vignette(img, strength):
    d = np.sqrt(((NX - 0.5) * ASPECT) ** 2 + (NY - 0.5) ** 2)
    v = 1 - strength * np.clip(d / 1.1, 0, 1) ** 2
    return img * v[..., None]


def finish(img, seed):
    """Dither with a seeded sequence (breaks 8-bit banding of the gradients), quantise."""
    rng = np.random.default_rng(seed)
    noise = rng.random((H, W, 1), dtype=np.float32) - 0.5
    out = np.clip(img * 255.0 + noise * 1.6, 0, 255)
    return np.rint(out).astype(np.uint8)


def dusk():
    img = gradient(rgb("#0b0a22"), rgb("#2a1250"), 70)
    img = over(img, rgb("#8a2c9a"), 0.55 * gaussian(0.78, 0.92, 0.55, 0.42))
    img = over(img, rgb("#3a4fd0"), 0.40 * gaussian(0.12, 0.10, 0.50, 0.40))
    img = over(img, rgb("#ff7fb0"), 0.16 * disc(0.70, 0.30, 0.18, 0.10))
    img = over(img, rgb("#9fb4ff"), 0.10 * disc(0.30, 0.72, 0.11, 0.07))
    return vignette(img, 0.35)


def aurora():
    img = gradient(rgb("#04101c"), rgb("#071f2e"), 90)
    ribbon = gaussian(0.5, 0.42, 0.9, 0.10) * (0.65 + 0.35 * np.sin(NX * 7.0 + NY * 3.0))
    img = over(img, rgb("#1fd1a1"), 0.42 * ribbon)
    ribbon2 = gaussian(0.38, 0.62, 0.8, 0.09) * (0.6 + 0.4 * np.sin(NX * 5.0 - 1.0))
    img = over(img, rgb("#3a7bff"), 0.34 * ribbon2)
    img = over(img, rgb("#b46bff"), 0.18 * gaussian(0.88, 0.2, 0.30, 0.25))
    img = over(img, rgb("#d6fff3"), 0.07 * disc(0.2, 0.25, 0.06, 0.05))
    return vignette(img, 0.40)


def ember():
    img = gradient(rgb("#120c0c"), rgb("#2a1410"), 60)
    img = over(img, rgb("#ff7a2a"), 0.50 * gaussian(0.22, 0.95, 0.55, 0.36))
    img = over(img, rgb("#d13a3a"), 0.34 * gaussian(0.85, 0.80, 0.45, 0.35))
    img = over(img, rgb("#ffc36b"), 0.15 * disc(0.62, 0.40, 0.13, 0.09))
    img = over(img, rgb("#ff9a5a"), 0.09 * disc(0.80, 0.18, 0.07, 0.05))
    return vignette(img, 0.45)


def lagoon():
    img = gradient(rgb("#031428"), rgb("#06405a"), 120)
    img = over(img, rgb("#19b8d6"), 0.40 * gaussian(0.18, 0.80, 0.50, 0.40))
    img = over(img, rgb("#2457d6"), 0.35 * gaussian(0.80, 0.20, 0.55, 0.40))
    for cx, cy, r, a in ((0.64, 0.58, 0.20, 0.10), (0.30, 0.30, 0.12, 0.08), (0.84, 0.80, 0.09, 0.09),
                         (0.12, 0.60, 0.07, 0.07)):
        img = over(img, rgb("#a6f1ff"), a * disc(cx, cy, r, 0.08))
    return vignette(img, 0.35)


def orchid():
    img = gradient(rgb("#1a0b1f"), rgb("#3a1038"), 100)
    img = over(img, rgb("#d83f9c"), 0.45 * gaussian(0.30, 0.20, 0.55, 0.40))
    img = over(img, rgb("#7a3fd8"), 0.38 * gaussian(0.80, 0.85, 0.50, 0.40))
    img = over(img, rgb("#ffb3e6"), 0.12 * disc(0.55, 0.62, 0.16, 0.10))
    img = over(img, rgb("#ffd6f2"), 0.09 * disc(0.15, 0.80, 0.08, 0.06))
    return vignette(img, 0.38)


def daybreak():
    img = gradient(rgb("#bfe0ff"), rgb("#ffe6cf"), 80)
    img = over(img, rgb("#ffb48a"), 0.45 * gaussian(0.80, 0.95, 0.60, 0.40))
    img = over(img, rgb("#ffffff"), 0.55 * gaussian(0.25, 0.15, 0.50, 0.35))
    img = over(img, rgb("#ffd1e0"), 0.30 * disc(0.65, 0.35, 0.15, 0.10))
    return vignette(img, 0.10)


WALLPAPERS = [
    ("dusk", dusk, 101),
    ("aurora", aurora, 102),
    ("ember", ember, 103),
    ("lagoon", lagoon, 104),
    ("orchid", orchid, 105),
    ("daybreak", daybreak, 106),
]


def luminance_extremes(pixels):
    """(floor, peak): the 5th and 95th percentile of the relative luminance of a 64x36 box reduction (linear light)."""
    small = Image.fromarray(pixels).resize((64, 36), Image.BOX)
    s = np.asarray(small, dtype=np.float32) / 255.0
    lin = np.where(s <= 0.04045, s / 12.92, ((s + 0.055) / 1.055) ** 2.4)
    y = 0.2126 * lin[..., 0] + 0.7152 * lin[..., 1] + 0.0722 * lin[..., 2]
    return float(np.percentile(y, 5)), float(np.percentile(y, 95))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    catalog = []
    for wid, make, seed in WALLPAPERS:
        pixels = finish(make(), seed)
        path = OUT / f"{wid}.jpg"
        Image.fromarray(pixels).save(path, "JPEG", quality=86, optimize=True, subsampling=0)
        floor, peak = (round(v, 4) for v in luminance_extremes(pixels))
        catalog.append({"id": wid, "file": f"{wid}.jpg", "peak": peak, "floor": floor})
        print(f"{wid}: {path.stat().st_size // 1024} KiB, floor {floor}, peak {peak}")
    with open(OUT / "catalog.json", "w", encoding="utf-8", newline="\n") as f:   # LF on every host
        f.write(json.dumps(catalog, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
