#!/usr/bin/env python3
"""Adds RuyaOS's own controller silhouettes to a Material Symbols cut (T-199, RUY-491, 04 §3.7).

Called by scripts/subset-icons.sh after a static cut is made:

    python add-pad-glyphs.py <font in> <fill 0|1> <font out> <icons.txt> <pads dir>

The names and code points come from the lines of icons.txt that end in the word `ruya` (the glyphs
that are not Material's): `pad_<model>`, one for every `<model>.svg` in the pads directory
(`shell/art/pads/`). The script fails when the two lists differ, so a drawing without a glyph and a
glyph without a drawing are both caught here.

Each SVG is one `<path>` in a 960 x 960 box (Claude Design's drawing rules, shell/art/pads/README.md):
the pad's outline with the sticks, the D-pad and the buttons cut out, filled with the evenodd rule.
The path is read with fontTools, flipped to the font's y-up axis (the box is the em: 960 per em, like
Material, so a glyph is centred at 480), and simplified with skia-pathops under the evenodd rule, which
gives the contours the winding a font fills with the nonzero rule. They are shapes, not logos: no
vendor mark, no wordmark, no button symbols (04 §3.7).

`fill` is Material's FILL axis (0 outlined, 1 filled). A silhouette is the same in both cuts: it is a
solid shape with cut-outs, the one look of the pad, whatever state the icon is in.
"""
import re
import sys
from pathlib import Path

import pathops
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path
from fontTools.ttLib import TTFont

EM = 960
PATH_D = re.compile(r'<path\b[^>]*?\sd="([^"]+)"')


def silhouette(svg):
    """The SVG's path as a pathops.Path in font units (y up), contours wound for the nonzero rule."""
    text = svg.read_text(encoding="utf-8")
    found = PATH_D.findall(text)
    if len(found) != 1 or 'viewBox="0 0 960 960"' not in text:
        raise SystemExit("%s: expected one <path> in a 0 0 960 960 box" % svg.name)
    path = pathops.Path()
    # (x, y) -> (x, 960 - y): the SVG's y runs down, the font's up.
    parse_path(found[0], TransformPen(path.getPen(), (1, 0, 0, -1, 0, EM)))
    path.fillType = pathops.FillType.EVEN_ODD
    return pathops.simplify(path, fix_winding=True)


def to_ttglyph(path):
    path.convertConicsToQuads(0.25)
    pen = TTGlyphPen(None)
    path.draw(Cu2QuPen(pen, max_err=0.6, reverse_direction=True))
    return pen.glyph()


def main(src, fill, dst, listing, pads_dir):
    names = {}
    for line in open(listing, encoding="utf-8"):
        parts = line.split()
        if len(parts) == 3 and parts[2] == "ruya":
            names[parts[0]] = int(parts[1], 16)
    drawings = {"pad_" + svg.stem: svg for svg in Path(pads_dir).glob("*.svg")}
    if set(names) != set(drawings):
        raise SystemExit(
            "icons.txt lists these ruya glyphs only: %s; the pads directory has these drawings only: %s"
            % (sorted(set(names) - set(drawings)), sorted(set(drawings) - set(names)))
        )
    font = TTFont(src)
    glyf, hmtx = font["glyf"], font["hmtx"]
    order = list(font.getGlyphOrder())
    cmap = font.getBestCmap()
    font.setGlyphOrder(order + [n for n in sorted(names) if n not in order])
    for name in sorted(names):
        code = names[name]
        if code in cmap:
            raise SystemExit("%s: U+%04X is already in the font (%s)" % (name, code, cmap[code]))
        glyph = to_ttglyph(silhouette(drawings[name]))
        glyph.recalcBounds(glyf)
        glyf[name] = glyph
        hmtx[name] = (EM, glyph.xMin)
        for table in font["cmap"].tables:
            if table.isUnicode():
                table.cmap[code] = name
    font.save(dst)


if __name__ == "__main__":
    if len(sys.argv) != 6:
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
