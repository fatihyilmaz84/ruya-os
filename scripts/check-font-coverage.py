#!/usr/bin/env python3
"""Fails when a character used in the shell's text is missing from a bundled Inter cut (T-145).

Reads every character in shell/qml, shell/src and shell/i18n/*.ts (entities decoded) and checks
it against the cmap of each shell/fonts/Inter-*.ttf, so a new string cannot silently fall back
to another typeface. Pure standard library (reads cmap formats 4 and 12 itself), so it runs on
the Windows host, in WSL and in CI:   python -I scripts/check-font-coverage.py [repo root]

It also checks the two icon cuts (shell/fonts/MaterialSymbolsRounded*.ttf, T-206): no glyph may hold
two contours with the same points. The variable font draws the filled gear as two coincident
contours of opposite direction, which renders speckled on Windows; scripts/subset-icons.sh merges
overlaps and this fails if a cut is made without it.
"""
import glob
import html
import os
import struct
import sys


def cmap_of(path):
    data = open(path, "rb").read()
    num = struct.unpack(">H", data[4:6])[0]
    cmap_off = None
    for i in range(num):
        tag, _, off, _ = struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i])
        if tag == b"cmap":
            cmap_off = off
    if cmap_off is None:
        raise SystemExit("%s: no cmap table" % path)
    n = struct.unpack(">H", data[cmap_off + 2:cmap_off + 4])[0]
    chars = set()
    for i in range(n):
        pid, eid, off = struct.unpack(">HHI", data[cmap_off + 4 + 8 * i:cmap_off + 12 + 8 * i])
        if (pid, eid) not in ((3, 1), (3, 10), (0, 3), (0, 4)):
            continue
        t = cmap_off + off
        fmt = struct.unpack(">H", data[t:t + 2])[0]
        if fmt == 4:
            segx2 = struct.unpack(">H", data[t + 6:t + 8])[0]
            seg = segx2 // 2
            ends = struct.unpack(">%dH" % seg, data[t + 14:t + 14 + segx2])
            starts = struct.unpack(">%dH" % seg, data[t + 16 + segx2:t + 16 + 2 * segx2])
            for s, e in zip(starts, ends):
                if s != 0xFFFF:
                    chars.update(range(s, e + 1))
        elif fmt == 12:
            groups = struct.unpack(">I", data[t + 12:t + 16])[0]
            for g in range(groups):
                s, e, _ = struct.unpack(">III", data[t + 16 + 12 * g:t + 28 + 12 * g])
                chars.update(range(s, e + 1))
    return chars


def coincident_contours(path):
    """[(glyph id, contour a, contour b)] where two contours of one simple glyph have the same points."""
    data = open(path, "rb").read()
    tables = {}
    for i in range(struct.unpack(">H", data[4:6])[0]):
        tag, _, off, length = struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i])
        tables[tag] = (off, length)
    long_loca = struct.unpack(">h", data[tables[b"head"][0] + 50:tables[b"head"][0] + 52])[0]
    n_glyphs = struct.unpack(">H", data[tables[b"maxp"][0] + 4:tables[b"maxp"][0] + 6])[0]
    loca_off, glyf_off = tables[b"loca"][0], tables[b"glyf"][0]
    if long_loca:
        loca = struct.unpack(">%dI" % (n_glyphs + 1), data[loca_off:loca_off + 4 * (n_glyphs + 1)])
    else:
        loca = [2 * v for v in struct.unpack(">%dH" % (n_glyphs + 1), data[loca_off:loca_off + 2 * (n_glyphs + 1)])]
    found = []
    for gid in range(n_glyphs):
        if loca[gid + 1] <= loca[gid]:
            continue
        g = glyf_off + loca[gid]
        n_contours = struct.unpack(">h", data[g:g + 2])[0]
        if n_contours < 2:
            continue                                   # empty, one contour, or a composite
        p = g + 10
        ends = struct.unpack(">%dH" % n_contours, data[p:p + 2 * n_contours])
        p += 2 * n_contours
        p += 2 + struct.unpack(">H", data[p:p + 2])[0]  # instructions
        n_points = ends[-1] + 1
        flags = []
        while len(flags) < n_points:
            f = data[p]
            p += 1
            flags.append(f)
            if f & 8:
                flags.extend([f] * data[p])
                p += 1
        coords = []
        for short_bit, same_bit in ((2, 16), (4, 32)):
            v, out = 0, []
            for f in flags:
                if f & short_bit:
                    d = data[p]
                    p += 1
                    v += d if f & same_bit else -d
                elif not f & same_bit:
                    v += struct.unpack(">h", data[p:p + 2])[0]
                    p += 2
                out.append(v)
            coords.append(out)
        points, start = [], 0
        for e in ends:
            points.append(frozenset(zip(coords[0][start:e + 1], coords[1][start:e + 1])))
            start = e + 1
        for a in range(len(points)):
            for b in range(a + 1, len(points)):
                if points[a] == points[b]:
                    found.append((gid, a, b))
    return found


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    used = {}
    for pat in ("shell/qml/**/*.qml", "shell/qml/**/*.js", "shell/i18n/*.ts", "shell/src/**/*.cpp", "shell/src/**/*.h"):
        for f in sorted(glob.glob(os.path.join(root, pat), recursive=True)):
            text = open(f, encoding="utf-8").read()
            if f.endswith(".ts"):
                text = html.unescape(text)
            for c in text:
                if ord(c) >= 0x20 and c not in used:
                    used[c] = os.path.relpath(f, root).replace("\\", "/")
    fonts = sorted(glob.glob(os.path.join(root, "shell/fonts/Inter-*.ttf")))
    if not fonts:
        raise SystemExit("check-font-coverage: no shell/fonts/Inter-*.ttf")
    bad = 0
    for font in fonts:
        cmap = cmap_of(font)
        for c in sorted(used):
            if ord(c) not in cmap:
                bad += 1
                print("%s lacks U+%04X %r (first used in %s)" % (os.path.basename(font), ord(c), c, used[c]))
    icon_fonts = sorted(glob.glob(os.path.join(root, "shell/fonts/MaterialSymbolsRounded*.ttf")))
    if not icon_fonts:
        raise SystemExit("check-font-coverage: no shell/fonts/MaterialSymbolsRounded*.ttf")
    for font in icon_fonts:
        for gid, a, b in coincident_contours(font):
            bad += 1
            print("%s: glyph %d has coincident contours %d and %d; re-cut with scripts/subset-icons.sh (overlaps are merged there)"
                  % (os.path.basename(font), gid, a, b))
    if bad:
        print("check-font-coverage: FAILED, %d problems; add a missing range to scripts/fetch-inter.sh and re-cut, or re-cut the icons with scripts/subset-icons.sh" % bad)
        return 1
    print("check-font-coverage: ok (%d characters, %d fonts, %d icon fonts)" % (len(used), len(fonts), len(icon_fonts)))
    return 0


sys.exit(main())
