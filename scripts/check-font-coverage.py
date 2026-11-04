#!/usr/bin/env python3
"""Fails when a character used in the shell's text is missing from a bundled Inter cut (T-145).

Reads every character in shell/qml, shell/src and shell/i18n/*.ts (entities decoded) and checks
it against the cmap of each shell/fonts/Inter-*.ttf, so a new string cannot silently fall back
to another typeface. Pure standard library (reads cmap formats 4 and 12 itself), so it runs on
the Windows host, in WSL and in CI:   python -I scripts/check-font-coverage.py [repo root]
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
    if bad:
        print("check-font-coverage: FAILED, %d missing; add the range to scripts/fetch-inter.sh and re-cut" % bad)
        return 1
    print("check-font-coverage: ok (%d characters, %d fonts)" % (len(used), len(fonts)))
    return 0


sys.exit(main())
