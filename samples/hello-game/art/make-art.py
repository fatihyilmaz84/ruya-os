# SPDX-License-Identifier: CC0-1.0
"""Draws hero.png (1920x1080) and logo.png (640x360, opaque) with the Python standard library.

    python3 make-art.py

screenshot.png is not drawn here: it is the game itself, written by
`hello-game --screenshot screenshot.png` (see ../README.md).
"""
import struct
import zlib


def write_png(path, width, height, pixel):
    rows = bytearray()
    for y in range(height):
        rows.append(0)  # filter type: none
        for x in range(width):
            rows.extend(pixel(x, y))
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def hero(x, y):
    # Night-blue gradient, a gold coin at the right, the blue player square at the left.
    t = y / 1080
    r, g, b = int(14 + 18 * t), int(18 + 24 * t), int(36 + 50 * t)
    if (x - 1380) ** 2 + (y - 430) ** 2 < 170 ** 2:
        r, g, b = 255, 205, 60
    if 520 <= x < 760 and 480 <= y < 720:
        r, g, b = 90, 190, 255
    return bytes((r, g, b, 255))


def logo(x, y):
    # The Store draws x-ruya-logo as the card picture today: an opaque 16:9 image.
    if (x - 470) ** 2 + (y - 130) ** 2 < 90 ** 2:
        return bytes((255, 205, 60, 255))
    if 170 <= x < 330 and 150 <= y < 310:
        return bytes((90, 190, 255, 255))
    return bytes((14, 18, 36, 255))


if __name__ == "__main__":
    write_png("hero.png", 1920, 1080, hero)
    write_png("logo.png", 640, 360, logo)
