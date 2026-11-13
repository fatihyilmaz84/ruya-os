"""Geometry kit for the RuyaOS controller silhouettes.

A shape is a list of closed subpaths; a subpath is a list of segments, each ('L', p0, p1) or
('C', p0, c1, c2, p3). Bodies wind positive (clockwise on screen), holes negative, so the path
fills the same under the evenodd and the nonzero rule.
"""
import math

C = 480          # the vertical axis of the 960 box
RIM = 64         # body edge to any hole (1.6 u at 24 u)
WEB = 56         # hole to hole (1.4 u at 24 u)
HOLE = 48        # the smallest hole across: 1.4 u (56) normally, 1.2 u (48) on FINE models
FINE_RIM = 48    # FINE models (models.FINE, owner review 2026-11-13): rim 1.2 u,
FINE_WEB = 44    # webs 1.1 u, so the face fits the real proportions
GAP = 64         # between two separate bodies

BTN_R = 36       # a face button
BTN_D = 100      # diamond offset: adjacent buttons 141 apart, web 69
STICK_R = 60
DPAD_H = 108     # half span of the D-pad cross
DPAD_A = 72      # arm width
KAPPA = 0.5523


def _sub(a, b): return (a[0] - b[0], a[1] - b[1])
def _add(a, b): return (a[0] + b[0], a[1] + b[1])
def _mul(a, k): return (a[0] * k, a[1] * k)
def _len(a): return math.hypot(a[0], a[1])
def _unit(a):
    n = _len(a)
    return (a[0] / n, a[1] / n)


def rpoly(verts, k=0.56):
    """A polygon whose corners are cubic arcs. verts: (x, y, d), d = how far from the corner the
    arc starts on both edges (None = as far as it can). Neighbouring arcs that would overlap are
    scaled down to meet, so d=None everywhere gives a fully curved, G1-smooth outline."""
    n = len(verts)
    pts = [(float(v[0]), float(v[1])) for v in verts]
    big = 1e9
    d = [big if v[2] is None else float(v[2]) for v in verts]
    for i in range(n):
        d[i] = min(d[i], _len(_sub(pts[i], pts[i - 1])) / 2 if verts[i][2] is None else d[i],
                   _len(_sub(pts[i], pts[(i + 1) % n])) / 2 if verts[i][2] is None else d[i])
    # scale pairs that overflow an edge
    s = [1.0] * n
    for i in range(n):
        j = (i + 1) % n
        L = _len(_sub(pts[j], pts[i]))
        if d[i] + d[j] > L:
            f = L / (d[i] + d[j])
            s[i] = min(s[i], f)
            s[j] = min(s[j], f)
    d = [d[i] * s[i] for i in range(n)]
    A, B = [], []
    for i in range(n):
        V, P, N = pts[i], pts[i - 1], pts[(i + 1) % n]
        A.append(_add(V, _mul(_unit(_sub(P, V)), d[i])))
        B.append(_add(V, _mul(_unit(_sub(N, V)), d[i])))
    segs = []
    for i in range(n):
        V = pts[i]
        kk = k if len(verts[i]) < 4 else verts[i][3]
        c1 = _add(A[i], _mul(_sub(V, A[i]), kk))
        c2 = _add(B[i], _mul(_sub(V, B[i]), kk))
        segs.append(('C', A[i], c1, c2, B[i]))
        nxt = A[(i + 1) % n]
        if _len(_sub(nxt, B[i])) > 0.5:
            segs.append(('L', B[i], nxt))
    return segs


def mirror(right):
    """Right half (dx from the axis, y, d), listed clockwise from the top: the whole outline.
    A vertex with dx == 0 sits on the axis and is used once."""
    out = [(C + dx, y, *rest) for dx, y, *rest in right]
    for dx, y, *rest in reversed(right):
        if dx != 0:
            out.append((C - dx, y, *rest))
    # an axis vertex at the end of the right half is followed by the mirrored ones already
    return out


def circle(cx, cy, r):
    assert 2 * r >= HOLE - 1e-6, f"circle r={r} under the smallest hole"
    k = KAPPA * r
    p = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
    c = [((cx + k, cy - r), (cx + r, cy - k)), ((cx + r, cy + k), (cx + k, cy + r)),
         ((cx - k, cy + r), (cx - r, cy + k)), ((cx - r, cy - k), (cx - k, cy - r))]
    return [('C', p[i], c[i][0], c[i][1], p[(i + 1) % 4]) for i in range(4)]


def rrect(x0, y0, x1, y1, r):
    assert min(x1 - x0, y1 - y0) >= HOLE - 1e-6
    return rpoly([(x0, y0, r), (x1, y0, r), (x1, y1, r), (x0, y1, r)], KAPPA)


def stadium(cx, cy, w, h):
    r = min(w, h) / 2
    return rrect(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, r)


def capsule(cx, cy, length, width, angle_deg):
    """A stadium of this length and width, its long axis turned by angle (degrees)."""
    a = math.radians(angle_deg)
    ux, uy = math.cos(a), math.sin(a)
    vx, vy = -uy, ux
    hl, hw = length / 2, width / 2
    pts = [(cx - ux * hl - vx * hw, cy - uy * hl - vy * hw), (cx + ux * hl - vx * hw, cy + uy * hl - vy * hw),
           (cx + ux * hl + vx * hw, cy + uy * hl + vy * hw), (cx - ux * hl + vx * hw, cy - uy * hl + vy * hw)]
    return rpoly([(x, y, hw) for x, y in pts], KAPPA)


def cross(cx, cy, h=DPAD_H, arm=DPAD_A, ro=18, ri=12):
    a = arm / 2
    v = [(cx - a, cy - h, ro), (cx + a, cy - h, ro), (cx + a, cy - a, ri), (cx + h, cy - a, ro),
         (cx + h, cy + a, ro), (cx + a, cy + a, ri), (cx + a, cy + h, ro), (cx - a, cy + h, ro),
         (cx - a, cy + a, ri), (cx - h, cy + a, ro), (cx - h, cy - a, ro), (cx - a, cy - a, ri)]
    return rpoly(v, KAPPA)


def kidney(cx, cy, R, a0, a1, width, n=6):
    """A capsule bent along an arc of radius R around (cx, cy), from angle a0 to a1 (degrees,
    0 = right, 90 = down): the GameCube-style curved button."""
    hw = width / 2
    outer, inner = [], []
    for i in range(n + 1):
        a = math.radians(a0 + (a1 - a0) * i / n)
        outer.append((cx + (R + hw) * math.cos(a), cy + (R + hw) * math.sin(a), None))
        inner.append((cx + (R - hw) * math.cos(a), cy + (R - hw) * math.sin(a), None))
    def cap(a):
        a = math.radians(a)
        return (cx + R * math.cos(a), cy + R * math.sin(a))
    e = math.radians(a1 + (a1 - a0) / abs(a1 - a0) * math.degrees(hw / R))
    s = math.radians(a0 - (a1 - a0) / abs(a1 - a0) * math.degrees(hw / R))
    end = (cx + R * math.cos(e), cy + R * math.sin(e), None)
    start = (cx + R * math.cos(s), cy + R * math.sin(s), None)
    return rpoly(outer + [end] + list(reversed(inner)) + [start], 0.56)


def octagon(cx, cy, r, d=None):
    """A rounded octagon of this inner radius (flat side to flat side / 2)."""
    R = r / math.cos(math.pi / 8)
    pts = []
    for i in range(8):
        a = math.pi / 8 + i * math.pi / 4
        pts.append((cx + R * math.cos(a), cy + R * math.sin(a), d if d is not None else r * 0.22))
    return rpoly(pts, KAPPA)


def diamond(cx, cy, d=BTN_D, r=BTN_R):
    return [circle(cx, cy - d, r), circle(cx + d, cy, r), circle(cx, cy + d, r), circle(cx - d, cy, r)]


# --- flattening, orientation, output ------------------------------------------------------------

def flatten(sub, steps=16):
    pts = []
    for s in sub:
        if s[0] == 'L':
            pts.append(s[1])
        else:
            p0, c1, c2, p3 = s[1:]
            for i in range(steps):
                t = i / steps
                mt = 1 - t
                pts.append((mt ** 3 * p0[0] + 3 * mt * mt * t * c1[0] + 3 * mt * t * t * c2[0] + t ** 3 * p3[0],
                            mt ** 3 * p0[1] + 3 * mt * mt * t * c1[1] + 3 * mt * t * t * c2[1] + t ** 3 * p3[1]))
    return pts


def area(sub):
    p = flatten(sub)
    return sum(p[i][0] * p[(i + 1) % len(p)][1] - p[(i + 1) % len(p)][0] * p[i][1] for i in range(len(p))) / 2


def reverse(sub):
    out = []
    for s in reversed(sub):
        if s[0] == 'L':
            out.append(('L', s[2], s[1]))
        else:
            out.append(('C', s[4], s[3], s[2], s[1]))
    return out


def orient(sub, positive):
    return sub if (area(sub) > 0) == positive else reverse(sub)


def _n(v):
    r = round(v)
    return str(int(r))


def _nums(vals):
    """Numbers joined compactly: a minus sign separates them by itself."""
    s = ""
    for v in vals:
        t = str(int(v))
        s += t if not s or t.startswith("-") else " " + t
    return s


def _cmd(letter, vals, last):
    """The shorter of the absolute command and its relative form (same rounded points)."""
    rel = [v - last[i % 2] for i, v in enumerate(vals)]
    a, r = letter + _nums(vals), letter.lower() + _nums(rel)
    return r if len(r) < len(a) else a


def to_d(subs):
    out = []
    for sub in subs:
        p0 = sub[0][1]
        last = (round(p0[0]), round(p0[1]))
        cmd = ["M" + _nums(last)]
        for s in sub:
            if s[0] == 'L':
                e = (round(s[2][0]), round(s[2][1]))
                if e == last:
                    continue
                if e[1] == last[1]:
                    a, r = "H" + _nums([e[0]]), "h" + _nums([e[0] - last[0]])
                    cmd.append(r if len(r) < len(a) else a)
                elif e[0] == last[0]:
                    a, r = "V" + _nums([e[1]]), "v" + _nums([e[1] - last[1]])
                    cmd.append(r if len(r) < len(a) else a)
                else:
                    cmd.append(_cmd("L", list(e), last))
                last = e
            else:
                pts = [round(c) for p in (s[2], s[3], s[4]) for c in p]
                cmd.append(_cmd("C", pts, last))
                last = (pts[4], pts[5])
        # the closing segment back to the start is implied by Z
        if cmd[-1][0] in 'HVLhvl' and last == (round(p0[0]), round(p0[1])):
            cmd.pop()
        cmd.append("Z")
        out.append("".join(cmd))
    return "".join(out)


def svg(d):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 960">'
            f'<path fill="currentColor" fill-rule="evenodd" d="{d}"/></svg>\n')
