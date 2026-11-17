# SPDX-License-Identifier: CC0-1.0
"""Draws package/art/icon.png (512x512, RGBA) and package/art/hero.png (1920x1080) with the Python
standard library only. The output is the same bytes on every run.

    python3 make-art.py

The hero follows the composition guide of docs/developers/play-packages.md: the planets sit in the
right two thirds and the upper three quarters; the left third and the bottom strip stay calm, because
the shell puts its title block and its row of cards there.
"""
import math
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
SKY_TOP = (48, 18, 38)
SKY_BOTTOM = (120, 60, 70)


def write_png(path, width, height, row_at, alpha):
    channels = 4 if alpha else 3
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type: none
        raw.extend(row_at(y))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6 if alpha else 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    assert len(raw) == height * (1 + width * channels)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def scene(width, height, circles, alpha):
    """A vertical gradient with flat circles painted over it, one row at a time."""
    channels = 4 if alpha else 3

    def px(rgb):
        return bytes(rgb) + (b"\xff" if alpha else b"")

    def row_at(y):
        row = bytearray(px(lerp(SKY_TOP, SKY_BOTTOM, y / (height - 1))) * width)
        for cx, cy, r, rgb in circles:
            dy = y - cy
            if abs(dy) > r:
                continue
            dx = int(math.isqrt(r * r - dy * dy))
            lo, hi = max(0, cx - dx), min(width, cx + dx + 1)
            if lo < hi:
                row[lo * channels:hi * channels] = px(rgb) * (hi - lo)
        return bytes(row)

    return row_at


def main():
    # Icon: full bleed, the subject (one planet and its moon) inside the centre 80 percent.
    icon = [(256, 256, 150, (70, 160, 150)), (256, 256, 118, (130, 215, 190)), (365, 150, 36, (235, 240, 250))]
    write_png(os.path.join(HERE, "package", "art", "icon.png"), 512, 512, scene(512, 512, icon, True), True)
    # Hero: right two thirds, upper three quarters.
    hero = [
        (1380, 430, 330, (70, 160, 150)),
        (1380, 430, 270, (130, 215, 190)),
        (950, 250, 70, (150, 210, 235)),
        (1750, 220, 46, (235, 240, 250)),
        (1180, 700, 38, (120, 180, 160)),
    ]
    write_png(os.path.join(HERE, "package", "art", "hero.png"), 1920, 1080, scene(1920, 1080, hero, False), False)


if __name__ == "__main__":
    main()
