#!/usr/bin/env python3
"""Turns the PPM screendumps of scripts/vm-boot-shots.ps1 into PNGs and one contact sheet (T-269).

    python -I scripts/vm-boot-sheet.py <tag> [columns] [thumbnail width]

Reads output/boot-shots/<tag>/<elapsed ms>.ppm, writes a PNG next to every screendump that
differs from the one before it (a screen that did not change is kept once) and
output/boot-shots/<tag>/_sheet.png with the elapsed milliseconds written on each thumbnail.
Needs Pillow.
"""
import os
import sys

from PIL import Image, ImageDraw

if len(sys.argv) < 2:
    sys.exit(__doc__)
tag = sys.argv[1]
cols = int(sys.argv[2]) if len(sys.argv) > 2 else 6
tw = int(sys.argv[3]) if len(sys.argv) > 3 else 320
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
d = os.path.join(root, "output", "boot-shots", tag)
names = sorted(n for n in os.listdir(d) if n.endswith(".ppm"))
keep = []
prev = None
for n in names:
    with open(os.path.join(d, n), "rb") as f:
        b = f.read()
    if b != prev:
        keep.append(n)
    prev = b
print(len(names), "screendumps,", len(keep), "differ from the one before")
thumbs = []
for n in keep:
    im = Image.open(os.path.join(d, n)).convert("RGB")
    im.save(os.path.join(d, n[:-4] + ".png"))
    th = im.resize((tw, round(tw * im.height / im.width)))
    ImageDraw.Draw(th).text((4, 4), n[:-4] + " ms", fill=(255, 255, 0))
    thumbs.append(th)
if thumbs:
    rows = (len(thumbs) + cols - 1) // cols
    th_h = thumbs[0].height
    sheet = Image.new("RGB", (cols * tw, rows * th_h), (40, 0, 40))
    for i, th in enumerate(thumbs):
        sheet.paste(th, ((i % cols) * tw, (i // cols) * th_h))
    out = os.path.join(d, "_sheet.png")
    sheet.save(out)
    print(out, sheet.size)
print("changed at (ms):", ", ".join(n[:-4].lstrip("0") or "0" for n in keep))
