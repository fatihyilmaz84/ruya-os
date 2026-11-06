#!/usr/bin/env python3
"""Generate shell/assets/glass-grain.png: the 128x128 noise tile of the glass grain (04 section 3.8, T-204).

Each pixel is white with an alpha of 2 %, black with an alpha of 2.4 %, or clear (a fixed
pseudo-random sequence, so the file is reproducible). Laid over a blurred surface it breaks the
banding of the blurred gradient on 8-bit panels. The tile is made here from nothing (no source
image), so it carries no licence of its own; the script and the PNG are part of the project.

Usage:  python -I scripts/make-grain.py          (rewrites the PNG)
        python -I scripts/make-grain.py --check  (exit 1 when the PNG differs from what this makes)
"""
import struct
import sys
import zlib
from pathlib import Path

SIZE = 128
WHITE_ALPHA = round(0.020 * 255)   # 5
BLACK_ALPHA = round(0.024 * 255)   # 6
OUT = Path(__file__).resolve().parent.parent / "shell" / "assets" / "glass-grain.png"


def pixels():
    state = 0x2545F491
    rows = []
    for _ in range(SIZE):
        row = bytearray()
        for _ in range(SIZE):
            # xorshift32
            state ^= (state << 13) & 0xFFFFFFFF
            state ^= state >> 17
            state ^= (state << 5) & 0xFFFFFFFF
            r = state % 10
            if r < 4:
                row += bytes((255, 255, 255, WHITE_ALPHA))
            elif r < 8:
                row += bytes((0, 0, 0, BLACK_ALPHA))
            else:
                row += bytes((0, 0, 0, 0))
        rows.append(bytes(row))
    return rows


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def png_bytes():
    raw = b"".join(b"\x00" + row for row in pixels())   # filter type 0 per scanline
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)   # 8 bit RGBA
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def main():
    data = png_bytes()
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_bytes() != data:
            print("glass-grain.png differs from scripts/make-grain.py")
            return 1
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(data)
    print("wrote", OUT, len(data), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
