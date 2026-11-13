"""Sample the first subpath of a reference icon path (the outline we measure, never copy).
Usage: python -I -B measure.py <svg> <path index>  -> points scaled to the 960 box."""
import re, sys


def outline(file, idx):
    src = open(file, encoding="utf-8").read()
    d = re.findall(r'<path[^>]*?\sd="([^"]+)"', src)[idx]
    toks = re.findall(r'[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?', d)
    pts = []
    st = {"i": 0}
    cx = cy = 0.0
    cmd = None
    lastc = None
    started = False

    def num():
        v = float(toks[st["i"]]); st["i"] += 1
        return v

    while st["i"] < len(toks):
        t = toks[st["i"]]
        if re.match(r'[A-Za-z]', t):
            cmd = t; st["i"] += 1
            if cmd in 'Zz' or (cmd in 'Mm' and started):
                break
        rel = cmd.islower()
        K = cmd.upper()
        if K == 'M':
            x, y = num(), num()
            if rel: x += cx; y += cy
            cx, cy = x, y; pts.append((x, y)); started = True
            cmd = 'l' if rel else 'L'
        elif K == 'L':
            x, y = num(), num()
            if rel: x += cx; y += cy
            cx, cy = x, y; pts.append((x, y))
        elif K == 'H':
            x = num(); cx = x + cx if rel else x; pts.append((cx, cy))
        elif K == 'V':
            y = num(); cy = y + cy if rel else y; pts.append((cx, cy))
        elif K in 'CS':
            if K == 'C':
                x1, y1 = num(), num()
                if rel: x1 += cx; y1 += cy
            else:
                x1, y1 = (2 * cx - lastc[0], 2 * cy - lastc[1]) if lastc else (cx, cy)
            x2, y2, x, y = num(), num(), num(), num()
            if rel: x2 += cx; y2 += cy; x += cx; y += cy
            for k in range(1, 9):
                u = k / 8
                a = (1 - u) ** 3; b = 3 * (1 - u) ** 2 * u; c = 3 * (1 - u) * u * u; e = u ** 3
                pts.append((a * cx + b * x1 + c * x2 + e * x, a * cy + b * y1 + c * y2 + e * y))
            lastc = (x2, y2); cx, cy = x, y
            continue
        elif K == 'A':
            for _ in range(5): num()
            x, y = num(), num()
            if rel: x += cx; y += cy
            cx, cy = x, y; pts.append((x, y))
        lastc = None
    return pts


def fit(pts, box):
    """Scale pts uniformly into box (x0, y0, x1, y1), centred."""
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    s = min((box[2] - box[0]) / w, (box[3] - box[1]) / h)
    ox = (box[0] + box[2]) / 2 - (min(xs) + max(xs)) / 2 * s
    oy = (box[1] + box[3]) / 2 - (min(ys) + max(ys)) / 2 * s
    return [(x * s + ox, y * s + oy) for x, y in pts]


if __name__ == '__main__':
    pts = outline(sys.argv[1], int(sys.argv[2]))
    out = fit(pts, (30, 30, 930, 930))
    print(" ".join("%d,%d" % p for p in out[::max(1, len(out) // 90)]))
