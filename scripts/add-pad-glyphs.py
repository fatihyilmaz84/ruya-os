#!/usr/bin/env python3
"""Adds RuyaOS's own controller silhouettes to a Material Symbols cut (T-199, 04 §3.7).

Called by scripts/subset-icons.sh after a static cut is made:

    python add-pad-glyphs.py <font in> <fill 0|1> <font out> <icons.txt>

The names and code points come from the lines of icons.txt that end in the word `ruya` (the glyphs
that are not Material's): pad_playstation, pad_xbox and pad_switch. Each is a plain pad outline in
the line style of Material's `sports_esports` (a rounded body, sticks and buttons as discs, a
cross for the D-pad), drawn here from rounded polygons and discs. They are layouts, not logos:
no vendor mark, no button symbol, no wordmark (04 §3.7, owner decision on brand art).

    pad_playstation   two grips that splay out, a bar for the touchpad, both sticks low and
                      level, the D-pad left and four buttons right (the DualShock/DualSense layout)
    pad_xbox          one stick top left, the D-pad low in the middle, four buttons top right, the
                      second stick low right, a round button on top (the Xbox layout)
    pad_switch        a landscape body with a screen between two rails; stick over D-pad on the
                      left, buttons over stick on the right (the Switch's Joy-Con layout)

`fill` 0 draws the outline (a ring for the body and the screen); 1 draws the body solid with the
sticks, buttons and screen cut out, as Material's filled cut does. The geometry is in font units
(960 per em, like Material) and uses skia-pathops for the unions, so overlaps are merged.
"""
import math
import sys

import pathops
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

STROKE = 54             # the line weight of the outlined cut (Material's at opsz 40, wght 400)
CY = 480                # the vertical centre of Material's glyph box


# --- shapes -------------------------------------------------------------------------------------

def poly(points):
    path = pathops.Path()
    path.moveTo(*points[0])
    for p in points[1:]:
        path.lineTo(*p)
    path.close()
    return path


def rounded(points, radius):
    """The polygon grown by `radius`: its corners become arcs."""
    fat = poly(points)
    fat.stroke(2 * radius, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
    fat.convertConicsToQuads(0.25)
    return union([poly(points), fat])


def disc(cx, cy, r):
    k = 0.5522847498 * r
    path = pathops.Path()
    path.moveTo(cx + r, cy)
    path.cubicTo(cx + r, cy + k, cx + k, cy + r, cx, cy + r)
    path.cubicTo(cx - k, cy + r, cx - r, cy + k, cx - r, cy)
    path.cubicTo(cx - r, cy - k, cx - k, cy - r, cx, cy - r)
    path.cubicTo(cx + k, cy - r, cx + r, cy - k, cx + r, cy)
    path.close()
    return path


def cross(cx, cy, arm, half):
    """A plus: arms `arm` long from the centre, `half` is half the arm's width."""
    return poly([
        (cx - half, cy + arm), (cx + half, cy + arm), (cx + half, cy + half), (cx + arm, cy + half),
        (cx + arm, cy - half), (cx + half, cy - half), (cx + half, cy - arm), (cx - half, cy - arm),
        (cx - half, cy - half), (cx - arm, cy - half), (cx - arm, cy + half), (cx - half, cy + half)])


def bar(cx, cy, w, h):
    """A rounded bar: a line with round caps."""
    path = pathops.Path()
    path.moveTo(cx - w / 2 + h / 2, cy)
    path.lineTo(cx + w / 2 - h / 2, cy)
    path.stroke(h, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
    path.convertConicsToQuads(0.25)
    return path


def union(parts):
    builder = pathops.OpBuilder(fix_winding=True)
    for part in parts:
        builder.add(part, pathops.PathOp.UNION)
    return builder.resolve()


def mirror_x(points):
    return [(960 - x, y) for x, y in points]


def diamond(cx, cy, step, r):
    """Four buttons on a diamond."""
    return [disc(cx, cy + step, r), disc(cx, cy - step, r), disc(cx - step, cy, r), disc(cx + step, cy, r)]


def ring(body, width):
    """The inner `width` of the body's edge: the outlined cut's line."""
    edge = pathops.Path(body)
    edge.stroke(2 * width, pathops.LineCap.BUTT_CAP, pathops.LineJoin.ROUND_JOIN, 4)
    edge.convertConicsToQuads(0.25)
    return pathops.op(body, edge, pathops.PathOp.INTERSECTION)


# --- the three pads -------------------------------------------------------------------------------

def playstation():
    # The body: a wide top and a grip hanging from each side, splayed outwards.
    r = 78
    top = rounded([(300, 680), (660, 680), (760, 470), (200, 470)], r)
    left = rounded([(215, 520), (305, 520), (250, 292), (176, 292)], r)
    right = rounded(mirror_x([(215, 520), (305, 520), (250, 292), (176, 292)]), r)
    body = union([top, left, right])
    parts = [disc(385, 505, 46), disc(575, 505, 46), bar(480, 650, 150, 36)]
    parts.append(cross(292, 585, 56, 19))
    parts += diamond(668, 585, 46, 22)
    return body, parts, []


def xbox():
    r = 78
    top = rounded([(300, 680), (660, 680), (770, 470), (190, 470)], r)
    left = rounded([(215, 520), (305, 520), (262, 292), (190, 292)], r)
    right = rounded(mirror_x([(215, 520), (305, 520), (262, 292), (190, 292)]), r)
    body = union([top, left, right])
    parts = [disc(334, 598, 44), disc(580, 516, 44), disc(480, 650, 30)]
    parts.append(cross(404, 516, 50, 18))
    parts += diamond(650, 604, 44, 21)
    return body, parts, []


def switch():
    r = 90
    body = rounded([(170, 650), (790, 650), (790, 310), (170, 310)], r)
    screen = rounded([(350, 570), (610, 570), (610, 390), (350, 390)], 10)
    parts = [disc(238, 570, 40), cross(238, 410, 48, 17), disc(722, 410, 40)]
    parts += diamond(722, 570, 40, 20)
    return body, parts, [screen]


PADS = {"pad_playstation": playstation, "pad_xbox": xbox, "pad_switch": switch}


def glyph_path(name, fill):
    body, parts, cutouts = PADS[name]()
    features = union(parts)
    if fill:
        # solid body, features and screen knocked out
        holes = union([features] + cutouts)
        return pathops.op(body, holes, pathops.PathOp.DIFFERENCE)
    # outline: the body's edge as a line, the screen's edge as a line, features solid
    line = ring(body, STROKE)
    pieces = [line, features]
    for c in cutouts:
        pieces.append(ring(c, STROKE * 0.8))
    return union(pieces)


def to_ttglyph(path):
    path.convertConicsToQuads(0.25)
    pen = TTGlyphPen(None)
    path.draw(Cu2QuPen(pen, max_err=0.6, reverse_direction=True))
    return pen.glyph()


def main(src, fill, dst, listing):
    names = {}
    for line in open(listing, encoding="utf-8"):
        parts = line.split()
        if len(parts) == 3 and parts[2] == "ruya":
            names[parts[0]] = int(parts[1], 16)
    if set(names) != set(PADS):
        raise SystemExit("icons.txt lists %s as ruya glyphs, this script draws %s" % (sorted(names), sorted(PADS)))
    font = TTFont(src)
    glyf, hmtx = font["glyf"], font["hmtx"]
    order = list(font.getGlyphOrder())
    cmap = font.getBestCmap()
    font.setGlyphOrder(order + [n for n in names if n not in order])
    for name, code in names.items():
        if code in cmap:
            raise SystemExit("%s: U+%04X is already in the font (%s)" % (name, code, cmap[code]))
        glyph = to_ttglyph(glyph_path(name, int(fill)))
        glyph.recalcBounds(glyf)
        glyf[name] = glyph
        hmtx[name] = (960, glyph.xMin)
        for table in font["cmap"].tables:
            if table.isUnicode():
                table.cmap[code] = name
    font.save(dst)


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
