"""Build every silhouette: orient, centre, check, write the SVGs, render contact sheets.

    python -I shell/art/pads/src/build.py shell/art/pads <render dir> [model ...]

Needs Pillow for the contact sheets (160, 40, 32 and 24 u, light and dark, and 24 u and 16 px
blown up 5x). Prints one line per model: its size and every rule it breaks (README "Drawing
rules"); a model that breaks one is still written, so fix it before committing.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from geom import RIM, WEB, FINE_RIM, FINE_WEB, GAP, flatten, orient, area, to_d, svg  # noqa: E402
from models import MODELS, FINE  # noqa: E402
from PIL import Image, ImageDraw, ImageChops, ImageFont  # noqa: E402


def seg_dist(p, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    t = 0 if L == 0 else max(0, min(1, ((p[0] - ax) * dx + (p[1] - ay) * dy) / L))
    return math.hypot(p[0] - ax - t * dx, p[1] - ay - t * dy)


def poly_dist(A, B):
    best = 1e9
    for P, Q in ((A, B), (B, A)):
        for p in P[::1]:
            for i in range(len(Q)):
                d = seg_dist(p, Q[i], Q[(i + 1) % len(Q)])
                if d < best:
                    best = d
    return best


def inside(p, poly):
    x, y = p
    c = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
            c = not c
    return c


def self_intersects(poly):
    n = len(poly)

    def ccw(a, b, c):
        return (c[1] - a[1]) * (b[0] - a[0]) - (b[1] - a[1]) * (c[0] - a[0])
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        for j in range(i + 2, n):
            if i == 0 and j == n - 1:
                continue
            c, d = poly[j], poly[(j + 1) % n]
            if (ccw(a, b, c) > 0) != (ccw(a, b, d) > 0) and (ccw(c, d, a) > 0) != (ccw(c, d, b) > 0):
                return True
    return False


def build(name):
    label, fn = MODELS[name][:2]
    fine = name in FINE
    rim_min, web_min = (FINE_RIM, FINE_WEB) if fine else (RIM, WEB)
    bodies, holes = fn()
    bodies = [orient(b, True) for b in bodies]
    holes = [orient(h, False) for h in holes]
    # centre the glyph's box on the 960 box, as Material's glyphs are (geometry moved, no transform)
    pts = [p for b in bodies for p in flatten(b, 16)]
    dx = round(480 - (min(p[0] for p in pts) + max(p[0] for p in pts)) / 2)
    dy = round(480 - (min(p[1] for p in pts) + max(p[1] for p in pts)) / 2)

    def shift(sub):
        return [(s[0],) + tuple((q[0] + dx, q[1] + dy) for q in s[1:]) for s in sub]
    bodies = [shift(b) for b in bodies]
    holes = [shift(h) for h in holes]
    problems = []
    fb = [flatten(b, 10) for b in bodies]
    fh = [flatten(h, 10) for h in holes]
    for i, p in enumerate(fb):
        if self_intersects(p):
            problems.append(f"body{i} crosses itself")
        xs = [q[0] for q in p]
        ys = [q[1] for q in p]
        if min(xs) < 8 or max(xs) > 952 or min(ys) < 8 or max(ys) > 952:
            problems.append(f"body{i} leaves the box {min(xs):.0f}..{max(xs):.0f} x {min(ys):.0f}..{max(ys):.0f}")
    for i in range(len(fb)):
        for j in range(i + 1, len(fb)):
            d = poly_dist(fb[i], fb[j])
            if d < GAP:
                problems.append(f"body{i}-body{j} gap {d:.0f}")
    for i, h in enumerate(fh):
        owner = [k for k, b in enumerate(fb) if inside(h[0], b)]
        if not owner:
            problems.append(f"hole{i} outside every body")
            continue
        d = poly_dist(h, fb[owner[0]])
        if d < rim_min:
            problems.append(f"hole{i} rim {d:.0f}")
    for i in range(len(fh)):
        for j in range(i + 1, len(fh)):
            d = poly_dist(fh[i], fh[j])
            if d < web_min:
                problems.append(f"hole{i}-hole{j} web {d:.0f}")
    d = to_d(bodies + holes)
    text = svg(d)
    return label, text, bodies + holes, problems


def mask(subs, size, ss=4):
    S = size * ss
    k = S / 960
    acc = Image.new('1', (S, S), 0)
    for sub in subs:
        im = Image.new('1', (S, S), 0)
        ImageDraw.Draw(im).polygon([(x * k, y * k) for x, y in flatten(sub, 24)], fill=1)
        acc = ImageChops.logical_xor(acc, im)
    return acc.convert('L').resize((size, size), Image.BOX)


def tile(subs, size, fg, bg):
    m = mask(subs, size)
    im = Image.new('RGB', (size, size), bg)
    im.paste(Image.new('RGB', (size, size), fg), (0, 0), m)
    return im


def sheet(entries, path):
    dark, light = (13, 18, 32), (238, 241, 247)
    tx_d, tx_l = (242, 244, 248), (20, 24, 36)
    W, rowh = 1040, 200
    im = Image.new('RGB', (W, rowh * len(entries)), (40, 40, 48))
    dr = ImageDraw.Draw(im)
    for r, (name, label, subs) in enumerate(entries):
        y = r * rowh
        im.paste(tile(subs, 160, tx_d, dark), (10, y + 20))
        im.paste(tile(subs, 160, tx_l, light), (180, y + 20))
        x = 350
        for s in (40, 32, 24):
            im.paste(tile(subs, s, tx_d, dark), (x, y + 60))
            im.paste(tile(subs, s, tx_l, light), (x, y + 110))
            x += s + 12
        # 24 u at 1:1, blown up 5x with nearest neighbour to see the pixels
        big = tile(subs, 24, tx_d, dark).resize((120, 120), Image.NEAREST)
        im.paste(big, (x + 10, y + 40))
        big = tile(subs, 16, tx_d, dark).resize((120, 120), Image.NEAREST)
        im.paste(big, (x + 140, y + 40))
        dr.text((x + 280, y + 80), f"{name}\n{label}", fill=(255, 255, 255))
    im.save(path)


def main():
    out, renders = sys.argv[1], sys.argv[2]
    names = sys.argv[3:] or list(MODELS)
    os.makedirs(out, exist_ok=True)
    os.makedirs(renders, exist_ok=True)
    entries = []
    bad = 0
    for name in names:
        label, text, subs, problems = build(name)
        with open(os.path.join(out, name + '.svg'), 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        size = len(text.encode('utf-8'))
        flag = '' if size <= 2100 else '  OVER 2 KB'   # "about 2 KB"
        print(f"{name:20s} {size:5d} B{flag}  {'; '.join(problems) if problems else 'ok'}")
        bad += bool(problems) or size > 2100
        entries.append((name, label, subs))
    for i in range(0, len(entries), 7):
        sheet(entries[i:i + 7], os.path.join(renders, f"sheet{i // 7 + 1}.png"))
    print(f"{len(entries)} models, {bad} with problems")


if __name__ == '__main__':
    main()
