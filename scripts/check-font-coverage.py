#!/usr/bin/env python3
"""Fails when a character used in the shell's text is missing from a bundled Inter cut (T-145).

Reads every character in shell/qml, shell/src and shell/i18n/*.ts (entities decoded) and checks
it against the cmap of each shell/fonts/Inter-*.ttf, so a new string cannot silently fall back
to another typeface. Pure standard library (reads cmap formats 4 and 12 itself), so it runs on
the Windows host, in WSL and in CI:   python -I scripts/check-font-coverage.py [repo root]

It also checks the two icon cuts (shell/fonts/MaterialSymbolsRounded*.ttf, T-206): no glyph may hold
two contours with the same points. The variable font draws the filled gear as two coincident
contours of opposite direction, which renders speckled on Windows; scripts/subset-icons.sh merges
overlaps and this fails if a cut is made without it. Every code point in shell/fonts/icons.txt must
also have a glyph in both cuts (T-223): a name in the Icon.qml table without a glyph draws an empty box.
No glyph may hold two contours of the same winding that overlap either (T-297): there the non-zero
fill and the even-odd fill differ (a hole or speckles on a rasteriser that uses even-odd). The
geometry (flattened outlines, pure Python) has a self-test that needs no font:
python -I scripts/check-font-coverage.py --self-test   (the normal run does it first, too).
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


def glyph_contours(path):
    """Yields (glyph id, [contour, ...]) for every simple glyph with two or more contours; a contour is
    a list of (x, y, on_curve) points in the font's units."""
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
        contours, start = [], 0
        for e in ends:
            contours.append([(coords[0][i], coords[1][i], bool(flags[i] & 1)) for i in range(start, e + 1)])
            start = e + 1
        yield gid, contours


def coincident_contours(path):
    """[(glyph id, contour a, contour b)] where two contours of one simple glyph have the same points."""
    found = []
    for gid, contours in glyph_contours(path):
        points = [frozenset((x, y) for x, y, _ in c) for c in contours]
        for a in range(len(points)):
            for b in range(a + 1, len(points)):
                if points[a] == points[b]:
                    found.append((gid, a, b))
    return found


def flatten(contour, steps=8):
    """A TrueType contour [(x, y, on_curve)] as a polygon [(x, y)]: quadratic curves in `steps` pieces,
    the on-curve point between two off-curve ones implied."""
    pts = list(contour)
    if not any(on for _, _, on in pts):                 # all off-curve: start at the first midpoint
        (x0, y0, _), (x1, y1, _) = pts[0], pts[1]
        pts = [((x0 + x1) / 2.0, (y0 + y1) / 2.0, True)] + pts[1:] + [pts[0]]
    k = next(i for i, p in enumerate(pts) if p[2])
    pts = pts[k:] + pts[:k]
    poly = [(float(pts[0][0]), float(pts[0][1]))]
    ctrl = None
    for x, y, on in pts[1:] + [pts[0]]:
        if on:
            if ctrl is None:
                poly.append((float(x), float(y)))
            else:
                _bezier(poly, ctrl, (x, y), steps)
                ctrl = None
        elif ctrl is None:
            ctrl = (x, y)
        else:
            mid = ((ctrl[0] + x) / 2.0, (ctrl[1] + y) / 2.0)
            _bezier(poly, ctrl, mid, steps)
            ctrl = (x, y)
    if poly[-1] == poly[0]:
        poly.pop()
    return poly


def _bezier(poly, ctrl, end, steps):
    x0, y0 = poly[-1]
    for i in range(1, steps + 1):
        t = i / float(steps)
        u = 1.0 - t
        poly.append((u * u * x0 + 2 * u * t * ctrl[0] + t * t * end[0],
                     u * u * y0 + 2 * u * t * ctrl[1] + t * t * end[1]))


def _area(poly):
    return sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
               for i in range(len(poly))) / 2.0


def _side(a, b, p):
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])


def _cross(a, b, c, d, eps):
    """The segments ab and cd cross at a point inside both (touching and collinear overlap do not count)."""
    d1, d2, d3, d4 = _side(a, b, c), _side(a, b, d), _side(c, d, a), _side(c, d, b)
    return ((d1 > eps and d2 < -eps) or (d1 < -eps and d2 > eps)) and \
           ((d3 > eps and d4 < -eps) or (d3 < -eps and d4 > eps))


def _winding(poly, p, eps):
    """The winding number of the polygon around p (counter-clockwise is positive), or None when p is on
    its boundary."""
    wn = 0
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        s = _side(a, b, p)
        if abs(s) <= eps and min(a[0], b[0]) - 1e-9 <= p[0] <= max(a[0], b[0]) + 1e-9 \
                and min(a[1], b[1]) - 1e-9 <= p[1] <= max(a[1], b[1]) + 1e-9:
            return None
        if a[1] <= p[1]:
            if b[1] > p[1] and s > 0:
                wn += 1
        elif b[1] <= p[1] and s < 0:
            wn -= 1
    return wn


def _samples(poly):
    """The vertices and edge midpoints of a polygon."""
    n = len(poly)
    return list(poly) + [((poly[i][0] + poly[(i + 1) % n][0]) / 2.0, (poly[i][1] + poly[(i + 1) % n][1]) / 2.0)
                         for i in range(n)]


def overlapping_contours(polys, eps=1e-6):
    """[(a, b)] for pairs of polygons of one glyph with the same winding direction whose areas overlap:
    their edges cross, or a boundary point of one lies inside the other while the rest of the glyph winds
    the same way around it. Where that happens the non-zero fill and the even-odd fill differ. Shapes that
    only touch, a hole (opposite winding) in a shape, and an island inside a hole are fine."""
    boxes = [(min(x for x, _ in p), min(y for _, y in p), max(x for x, _ in p), max(y for _, y in p)) for p in polys]
    sign = [1 if _area(p) > 0 else -1 for p in polys]
    found = []
    for a in range(len(polys)):
        for b in range(a + 1, len(polys)):
            if sign[a] != sign[b] or abs(_area(polys[a])) < 1.0 or abs(_area(polys[b])) < 1.0:
                continue                                # opposite winding, or a zero-area sliver (draws nothing)
            ba, bb = boxes[a], boxes[b]
            if ba[2] < bb[0] or bb[2] < ba[0] or ba[3] < bb[1] or bb[3] < ba[1]:
                continue
            pa, pb = polys[a], polys[b]
            hit = any(_cross(pa[i], pa[(i + 1) % len(pa)], pb[j], pb[(j + 1) % len(pb)], eps)
                      for i in range(len(pa)) for j in range(len(pb)))
            for inner, outer in ((a, b), (b, a)):       # no crossing: is one wholly inside the other?
                if hit:
                    break
                for p in _samples(polys[inner]):
                    if not _winding(polys[outer], p, eps):
                        continue                        # outside, or on the outer's boundary
                    rest = [_winding(polys[k], p, eps) for k in range(len(polys)) if k != inner]
                    if None not in rest and sum(rest) * sign[inner] > 0:
                        hit = True
                        break
            if hit:
                found.append((a, b))
    return found


def overlapping_glyph_contours(path):
    """[(glyph id, contour a, contour b)] where two contours of one glyph overlap with the same winding."""
    found = []
    for gid, contours in glyph_contours(path):
        for a, b in overlapping_contours([flatten(c) for c in contours]):
            found.append((gid, a, b))
    return found


def self_test():
    """The geometry on hand-made outlines; no font needed. Returns a list of failures."""
    def square(x, y, size, ccw=True):
        pts = [(x, y, True), (x + size, y, True), (x + size, y + size, True), (x, y + size, True)]
        return pts if ccw else pts[::-1]

    def flat(*contours):
        return [flatten(c) for c in contours]

    bad = []

    def expect(name, contours, want):
        got = overlapping_contours(flat(*contours))
        if bool(got) != want:
            bad.append("%s: expected %s, found %r" % (name, "an overlap" if want else "none", got))

    expect("two overlapping squares", [square(0, 0, 10), square(5, 5, 10)], True)
    expect("two disjoint squares", [square(0, 0, 10), square(20, 0, 10)], False)
    expect("squares that only share an edge", [square(0, 0, 10), square(10, 0, 10)], False)
    expect("squares that only share a corner", [square(0, 0, 10), square(10, 10, 10)], False)
    expect("a square inside a square, same winding", [square(0, 0, 30), square(10, 10, 5)], True)
    expect("a hole inside a square (opposite winding)", [square(0, 0, 30), square(10, 10, 5, ccw=False)], False)
    expect("overlapping squares of opposite winding", [square(0, 0, 10), square(5, 5, 10, ccw=False)], False)
    expect("an overlap with the other winding", [square(0, 0, 10, ccw=False), square(5, 5, 10, ccw=False)], True)
    expect("an island inside the hole of a ring", [square(0, 0, 40), square(5, 5, 30, ccw=False), square(15, 15, 10)], False)
    expect("a square inside a ring's solid part", [square(0, 0, 40), square(15, 15, 10, ccw=False), square(2, 2, 3)], True)
    expect("a zero-area spike inside a square", [square(0, 0, 40, ccw=False), [(5, 5, True), (9, 9, False), (12, 12, True), (9, 9, False)]], False)
    # A cross made of two bars: the bars overlap in the middle.
    bar_h = [(0, 4, True), (20, 4, True), (20, 8, True), (0, 8, True)]
    bar_v = [(8, 0, True), (12, 0, True), (12, 12, True), (8, 12, True)]
    expect("a plus made of two bars", [bar_h, bar_v], True)
    # Long bars whose vertices and edge midpoints are all outside the other bar: only the crossing shows it.
    expect("two long bars that cross off-centre", [[(0, 30, True), (40, 30, True), (40, 32, True), (0, 32, True)],
                                                   [(5, 0, True), (7, 0, True), (7, 40, True), (5, 40, True)]], True)
    # Curves: a circle (four quadratic arcs, off-curve at the corners) crossing a square.
    circle = [(10, 0, True), (20, 0, False), (20, 10, True), (20, 20, False), (10, 20, True),
              (0, 20, False), (0, 10, True), (0, 0, False)]
    expect("a circle and a square that cross", [circle, square(15, 5, 10)], True)
    expect("a circle and a square apart", [circle, square(30, 5, 10)], False)
    poly = flatten(circle)
    if not 250 < abs(_area(poly)) < 400:
        bad.append("flatten: the circle area is %.1f, expected about 330" % abs(_area(poly)))
    return bad


def main():
    failures = self_test()
    for f in failures:
        print("check-font-coverage self-test: " + f)
    if failures:
        return 1
    if "--self-test" in sys.argv[1:]:
        print("check-font-coverage self-test: ok")
        return 0
    root =sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
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
    wanted = []
    with open(os.path.join(root, "shell/fonts/icons.txt"), encoding="utf-8") as listing:
        for line in listing:
            parts = line.split()
            if len(parts) >= 2 and not parts[0].startswith("#"):
                wanted.append((parts[0], int(parts[1], 16)))
    for font in icon_fonts:
        cmap = cmap_of(font)
        for name, code in wanted:
            if code not in cmap:
                bad += 1
                print("%s lacks the glyph for %s (U+%04X); re-cut with scripts/subset-icons.sh" % (os.path.basename(font), name, code))
        for gid, a, b in coincident_contours(font):
            bad += 1
            print("%s: glyph %d has coincident contours %d and %d; re-cut with scripts/subset-icons.sh (overlaps are merged there)"
                  % (os.path.basename(font), gid, a, b))
        for gid, a, b in overlapping_glyph_contours(font):
            bad += 1
            print("%s: glyph %d has overlapping contours %d and %d with the same winding; re-cut with scripts/subset-icons.sh (overlaps are merged there)"
                  % (os.path.basename(font), gid, a, b))
    if bad:
        print("check-font-coverage: FAILED, %d problems; add a missing range to scripts/fetch-inter.sh and re-cut, or re-cut the icons with scripts/subset-icons.sh" % bad)
        return 1
    print("check-font-coverage: ok (%d characters, %d fonts, %d icon fonts)" % (len(used), len(fonts), len(icon_fonts)))
    return 0


sys.exit(main())
