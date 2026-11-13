"""Overlay a reference outline (red, scaled to our body's bounding box) on our silhouette, to
compare the proportions while a model is being drawn. Nothing from the reference is written to
the SVGs: the red line is only drawn into this preview.

Usage: python -I -B overlay.py <out.png> <model>=<reference.svg>:<path index>[:<inset>] ...
  path index  which <path> of the reference holds the body outline (its first subpath is used)
  inset       for a stroked (line) reference, half its stroke width in our units, negative
              (the drawn line is the stroke's centre, our body is its outer edge), e.g. -15
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageChops, ImageDraw  # noqa: E402
import build  # noqa: E402
from geom import flatten  # noqa: E402
from measure import outline, fit  # noqa: E402

S = 480


def parse(ref):
    parts = ref.rsplit(':', 2)
    if len(parts) == 3 and not parts[1].lstrip('-').isdigit():
        parts = ref.rsplit(':', 1)          # a drive letter, no inset
    f, idx = parts[0], int(parts[1])
    return f, idx, float(parts[2]) if len(parts) > 2 else 0.0


def main():
    items = sys.argv[2:]
    im = Image.new('RGB', (S * len(items), S + 20), (20, 24, 36))
    dr = ImageDraw.Draw(im)
    k = S / 960
    for n, item in enumerate(items):
        name, ref = item.split('=', 1)
        f, idx, inset = parse(ref)
        label, text, subs, problems = build.build(name)
        print(f"{name} {len(text.encode())} B {'; '.join(problems) or 'ok'}")
        acc = None
        for sub in subs:
            m = Image.new('1', (S * 2, S * 2), 0)
            ImageDraw.Draw(m).polygon([(x * k * 2, y * k * 2) for x, y in flatten(sub, 24)], fill=1)
            acc = m if acc is None else ImageChops.logical_xor(acc, m)
        im.paste(Image.new('RGB', (S, S), (200, 205, 215)), (n * S, 0),
                 acc.convert('L').resize((S, S), Image.BOX))
        body = flatten(subs[0], 24)
        xs = [p[0] for p in body]
        ys = [p[1] for p in body]
        box = (min(xs) - inset, min(ys) - inset, max(xs) + inset, max(ys) + inset)
        pts = fit(outline(f, idx), box)
        dr.line([(n * S + x * k, y * k) for x, y in pts + pts[:1]], fill=(255, 60, 60), width=2)
        dr.text((n * S + 6, S + 4), name, fill=(255, 255, 255))
    im.save(sys.argv[1])


if __name__ == '__main__':
    main()
