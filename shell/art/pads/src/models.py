"""The RuyaOS controller silhouettes: one function per model, each returning (bodies, holes).
Bodies are rpoly outlines; holes are cut-outs. All drawn from the form factor only."""
from geom import (C, BTN_R, STICK_R, rpoly, mirror, circle, rrect, stadium, capsule, cross,
                  diamond, kidney, octagon)

import math

MODELS = {}


def arc(cx, cy, R, a0, a1, n):
    """rpoly vertices that round off into a circular arc of radius R around (cx, cy), from angle
    a0 to a1 (degrees, 0 = right, 90 = down, in outline order): the tangent polygon of n sides,
    each corner rounded over its whole edge. Join it with vertices on the circle at a0 and a1."""
    step = (a1 - a0) / n
    r = R / math.cos(math.radians(abs(step) / 2))
    t = R * math.tan(math.radians(abs(step) / 2))
    return [(cx + r * math.cos(math.radians(a0 + step * (i + 0.5))),
             cy + r * math.sin(math.radians(a0 + step * (i + 0.5))), t) for i in range(n)]

# Models checked with the FINE limits (geom.FINE_RIM, FINE_WEB, holes 48): their faces follow the
# real proportions, so the features are smaller (owner review 2026-11-13).
FINE = {"dualsense", "dualsense_edge", "dualshock4", "wii_remote", "wii_remote_nunchuk",
        "gamecube", "n64", "steam_controller"}


def model(name, label):
    def wrap(fn):
        MODELS[name] = (label, fn)
        return fn
    return wrap


# --- PlayStation-style: D-pad and buttons high, both sticks low and level ---------------------

def ps_features(yc=400, ys=598, sx=108):
    return [cross(C - 240, yc)] + diamond(C + 238, yc) + [circle(C - sx, ys, STICK_R),
                                                          circle(C + sx, ys, STICK_R)]


# The current pads (DualSense, DualShock 4, Xbox One/Series/Elite) use the smaller feature set,
# so the body can narrow to bumper shoulders and flare out into long grips: face buttons r 30
# on a diamond of 84, a D-pad of span 180 and arm 60, sticks r 52.
S_BTN_R, S_BTN_D, S_STICK_R, S_DPAD_H, S_DPAD_A = 30, 84, 52, 90, 60


def s_cross(cx, cy):
    return cross(cx, cy, h=S_DPAD_H, arm=S_DPAD_A, ro=16, ri=10)


def s_diamond(cx, cy):
    return diamond(cx, cy, d=S_BTN_D, r=S_BTN_R)


def ps_small(yc=400, ys=584, sx=100):
    return [s_cross(C - 200, yc)] + s_diamond(C + 196, yc) + [
        circle(C - sx, ys, S_STICK_R), circle(C + sx, ys, S_STICK_R)]


# Bumper tabs on the top corners, shoulders narrower than the grips, grips that flare down and
# out, and a high arch between them that rises right under the sticks.
# The PlayStation pads (owner review 2026-11-13) come from measured outline points of reference
# icons, joined with our own curves. Their faces are the densest (touchpad, D-pad, buttons and
# two sticks), so the band between the buttons and the bottom edge is stretched where our larger
# features need the rim; the top and the grips keep the measured shape.
#
# DualSense (FINE; from the PS5 reference, not stretched): about 1.52 wide to 1 high; a gently
# arched top with bumpers on the corners; a large touchpad that narrows toward its bottom and
# fills the top between the wings; the D-pad and buttons on the wings level with the touchpad;
# the sticks tucked under it with the home button between; a high flat bottom edge; the wings'
# outer edge bowing out and down into long grips with round tips.
DUALSENSE_BODY = [
    (161, 157, 40), (290, 144, 40), (352, 188, 30), (414, 326, None), (456, 574, None),
    (440, 688, None), (387, 741, 30), (330, 749, 30), (289, 634, None), (232, 556, None),
    (170, 546, 30)]


def dualsense_holes(home=True):
    pad = rpoly([(C - 150, 206, 26), (C + 150, 206, 26), (C + 110, 356, 26), (C - 110, 356, 26)],
                0.5523)
    holes = [pad, cross(C - 262, 330, h=80, arm=52, ro=14, ri=9)] + \
        diamond(C + 262, 330, d=68, r=26) + [circle(C - 143, 450, 48), circle(C + 143, 450, 48)]
    return holes + ([circle(C, 474, 24)] if home else [])


@model("dualsense", "DualSense")
def dualsense():
    return [rpoly(mirror(DUALSENSE_BODY))], dualsense_holes()


@model("dualsense_edge", "DualSense Edge")
def dualsense_edge():
    holes = dualsense_holes(home=False) + [circle(C - 332, 508, 24), circle(C + 332, 508, 24)]
    return [rpoly(mirror(DUALSENSE_BODY))], holes


@model("dualshock4", "DualShock 4")
def dualshock4():
    # DualShock 4 (FINE; from the PS4 reference, not stretched): about 1.58 wide to 1 high; a
    # flat top over a large rectangular touchpad with bumper humps on the shoulders; an outer
    # edge that curls down from the shoulder and widens into round grip lobes; the D-pad and
    # buttons level with the touchpad; the sticks under it with the home button between; a
    # bottom edge that dips under each stick; an inner edge rising to meet it beside the stick.
    body = rpoly(mirror([
        (200, 190, 14), (283, 146, 40), (340, 178, 20), (387, 255, None), (446, 440, None),
        (455, 646, None), (423, 702, None), (363, 728, 30), (268, 644, None), (206, 510, 30),
        (148, 568, 50), (103, 532, 30)]))
    holes = [rrect(C - 124, 238, C + 124, 335, 20), cross(C - 262, 326, h=80, arm=52, ro=14, ri=9)] + \
        diamond(C + 262, 326, d=68, r=26) + [circle(C - 148, 440, 48), circle(C + 148, 440, 48),
                                             circle(C, 448, 24)]
    return [body], holes


@model("dualshock3", "DualShock 3")
def dualshock3():
    # DualShock 3: a flat top edge between round wing lobes that carry the D-pad and the
    # buttons, bumpers on the lobes, a straight outer edge leaning out to round grip tips, a
    # straight inner edge, and the bottom edge curving under each stick; the home button above
    # and between the sticks. Select and Start are left out (size and clutter at 24 u).
    body = rpoly(mirror([
        (140, 239, 20), (170, 160, 30), (345, 155, 40), (356, 224, 30), (416, 320, 40),
        (456, 670, None), (440, 750, None), (358, 785, 40), (279, 742, None), (206, 623, 40),
        (140, 676, 60), (40, 608, 40)]))
    holes = [s_cross(C - 244, 360)] + diamond(C + 244, 360, d=80, r=28) + [
        circle(C - 140, 532, S_STICK_R), circle(C + 140, 532, S_STICK_R), circle(C, 399, 28)]
    return [body], holes


# --- Xbox-style: left stick high, D-pad low, buttons high, right stick low --------------------

def xbox_features(dpad_shape=None, ys=600, yt=370, sx=130):
    d = dpad_shape if dpad_shape is not None else cross(C - sx, ys)
    return [circle(C - 236, yt, STICK_R), d] + diamond(C + 228, yt) + [circle(C + sx, ys, STICK_R)]


def xbox_small(dpad_shape=None, yt=380, ys=572):
    d = dpad_shape if dpad_shape is not None else s_cross(C - 110, ys)
    return [circle(C - 200, yt, S_STICK_R), d] + s_diamond(C + 206, yt) + [
        circle(C + 110, ys, S_STICK_R)]


# Xbox One and Series (owner review 2026-11-13, from measured outline points of reference icons,
# joined with our own curves; the band under the buttons is stretched a little where our larger
# D-pad and right stick need the rim). Series: about 1.43 wide to 1 high, a flat top between
# bumper humps, an outer edge that bows out to its widest low on the grip, round tips, a long
# diagonal inner edge up to a flat bottom edge. The One is a little wider at the shoulders, its
# sides straighter.
XBOX_BODY = [
    (138, 168, 30), (181, 150, 30), (288, 183, 50), (342, 250, 40), (410, 412, None),
    (448, 583, None), (455, 698, 40), (392, 781, 40), (352, 776, 30), (262, 690, 60),
    (170, 646, 40)]

XBOX_ONE_BODY = [
    (125, 172, 30), (185, 150, 30), (300, 178, 50), (356, 242, 40), (420, 400, None),
    (454, 580, None), (447, 709, 40), (389, 767, 30), (351, 759, 30), (273, 715, 50),
    (170, 650, 40)]


def xbox_ref(dpad_shape=None):
    d = dpad_shape if dpad_shape is not None else s_cross(C - 130, 490)
    return [circle(C - 240, 320, S_STICK_R), d] + diamond(C + 204, 356, d=80, r=28) + [
        circle(C + 100, 530, S_STICK_R)]


@model("xbox_series", "Xbox Series X|S")
def xbox_series():
    body = rpoly(mirror(XBOX_BODY))
    holes = [circle(C, 270, 36), circle(C, 390, 28)] + xbox_ref()
    return [body], holes


@model("xbox_one", "Xbox One")
def xbox_one():
    body = rpoly(mirror(XBOX_ONE_BODY))
    holes = [circle(C, 276, 36)] + xbox_ref()
    return [body], holes


@model("xbox_elite", "Xbox Elite")
def xbox_elite():
    body = rpoly(mirror(XBOX_BODY))
    holes = [circle(C, 276, 36), stadium(C, 404, 80, 56)] + xbox_ref(
        dpad_shape=octagon(C - 130, 500, 60))
    return [body], holes


@model("xbox_360", "Xbox 360")
def xbox_360():
    # Xbox 360 proportions (owner review 2026-11-13, from about twenty measured outline points of
    # a reference icon, joined with our own curves): about 1.53 wide to 1 high; a short flat top
    # between bumper humps, an outer edge that widens steadily to its widest low on the grip,
    # round grip tips, and a wide shallow arch rising to about 70 % of the height. Left stick
    # high and outboard, the D-pad and right stick close together low in the middle, the
    # buttons high on the right, the guide button at the top centre.
    body = rpoly(mirror([
        (111, 219, 30), (190, 168, 30), (300, 158, 40), (350, 214, 50), (420, 420, None),
        (458, 660, None), (420, 770, None), (330, 770, None), (250, 690, None), (0, 640, 120)]))
    holes = [circle(C, 320, 36), circle(C - 240, 330, S_STICK_R), s_cross(C - 110, 470)] + \
        diamond(C + 206, 360, d=80, r=28) + [circle(C + 95, 520, S_STICK_R)]
    return [body], holes


@model("xbox_adaptive", "Xbox Adaptive Controller")
def xbox_adaptive():
    body = rrect(28, 280, 932, 680, 110)
    holes = [cross(218, 480), circle(488, 480, 98), circle(748, 480, 98)]
    return [body], holes


# --- Nintendo ----------------------------------------------------------------------------------

@model("switch_pro", "Switch Pro Controller")
def switch_pro():
    # Switch Pro proportions (owner review 2026-11-13, from measured outline points of a
    # reference icon, joined with our own curves): about 1.43 wide to 1 high; a gentle wide arc
    # on top with big rounded shoulders, an outer edge widest low on the grip, round grip tips,
    # an inner edge climbing to a flat bottom edge. Xbox-style layout; only Home fits in the
    # middle beside the buttons (Capture, + and - are left out).
    body = rpoly(mirror([
        (0, 168, None), (260, 186, 100), (380, 218, 60), (414, 330, 80), (440, 512, None),
        (458, 690, None), (430, 760, 40), (372, 792, 40), (286, 702, 60), (206, 642, 40)]))
    holes = [circle(C - 258, 344, S_STICK_R), s_cross(C - 130, 480)] + \
        diamond(C + 236, 370, d=80, r=28) + [circle(C + 110, 520, S_STICK_R), circle(C + 50, 330, 28)]
    return [body], holes


def joycon(x0, x1, y0, y1, rail_right, top_stick, d=100, r=BTN_R):
    rb, rs = 196, 40      # the round outer corners, the squarer rail corners
    if rail_right:
        body = rpoly([(x0, y0, rb), (x1, y0, rs), (x1, y1, rs), (x0, y1, rb)])
    else:
        body = rpoly([(x0, y0, rs), (x1, y0, rb), (x1, y1, rb), (x0, y1, rs)])
    cx = (x0 + x1) / 2
    h = y1 - y0
    ya, yb = y0 + h * 0.30, y0 + h * 0.66
    if top_stick:
        holes = [circle(cx, ya, STICK_R)] + diamond(cx, yb, d, r)
    else:
        holes = diamond(cx, ya, d, r) + [circle(cx, yb, STICK_R)]
    return body, holes


@model("joycon_left", "Joy-Con (L)")
def joycon_left():
    b, h = joycon(C - 216, C + 216, 52, 908, rail_right=True, top_stick=True)
    return [b], h


@model("joycon_right", "Joy-Con (R)")
def joycon_right():
    b, h = joycon(C - 216, C + 216, 52, 908, rail_right=False, top_stick=False)
    return [b], h


@model("joycon_pair", "Joy-Con pair")
def joycon_pair():
    b1, h1 = joycon(28, 448, 80, 880, rail_right=True, top_stick=True, d=96, r=34)
    b2, h2 = joycon(512, 932, 80, 880, rail_right=False, top_stick=False, d=96, r=34)
    return [b1, b2], h1 + h2


@model("wiiu_pro", "Wii U Pro Controller")
def wiiu_pro():
    # Wii U Pro proportions (owner review 2026-11-13, from measured outline points of a
    # reference icon, joined with our own curves): about 1.48 wide to 1 high; a slight dip in
    # the top centre between shoulder humps, sides almost straight down to grips that flare out
    # to round tips, a smooth round arch between them. Both sticks high and outboard, the D-pad
    # and the buttons level below them, home on the centre line.
    body = rpoly(mirror([
        (0, 178, None), (150, 162, None), (290, 150, 70), (380, 214, 70), (434, 423, None),
        (456, 650, None), (450, 720, 40), (412, 790, 40), (350, 790, 40), (300, 740, 60),
        (172, 650, 60), (0, 612, 110)]))
    holes = [circle(C - 282, 300, S_STICK_R), circle(C + 282, 300, S_STICK_R),
             s_cross(C - 180, 474)] + diamond(C + 180, 474, d=80, r=28) + [circle(C, 348, 28)]
    return [body], holes


# Wii Remote and Nunchuk (owner review 2026-11-13, measured from a reference icon; FINE): the
# remote is a slim bar about 4 times as tall as it is wide, D-pad near the top, the big A under
# it, Home in the middle, 1 and 2 near the bottom (power, - and + do not fit at 1.2 u). The
# Nunchuk is an egg: a round top that holds the stick in its octagonal gate, sides that converge
# to a rounded tip, set beside the remote and lower, as it is held.
def wii_remote_parts(cx):
    body = rrect(cx - 108, 40, cx + 108, 920, 56)
    holes = [cross(cx, 175, h=58, arm=48, ro=12, ri=8), circle(cx, 315, 36), circle(cx, 461, 24),
             circle(cx, 676, 26), circle(cx, 772, 26)]
    return body, holes


@model("wii_remote", "Wii Remote")
def wii_remote():
    b, h = wii_remote_parts(C)
    return [b], h


@model("wii_remote_nunchuk", "Wii Remote with Nunchuk")
def wii_remote_nunchuk():
    b, h = wii_remote_parts(488)
    nun = rpoly([(90, 250, None), (232, 250, None), (281, 367, None), (268, 600, None),
                 (205, 800, None), (117, 800, None), (54, 600, None), (40, 367, None)])
    return [b, nun], h + [octagon(161, 362, 58)]


@model("gamecube", "GameCube-style pad")
def gamecube():
    # GameCube (FINE; from the owner's GameCube reference, about 1.29 wide to 1 high): a broad
    # arched top, the outer edge running down into long grips with round tips, and between the
    # grips two round housings hanging from a high bottom edge, one holding the D-pad and one the
    # C-stick. The left stick in its octagonal gate top left, Start in the middle, the big A
    # top right with the X and Y kidneys curling round it and the small B below and left of it.
    lx, ly, lr = 138, 543, 115
    body = rpoly(mirror([
        (0, 124, None), (240, 138, None), (385, 200, None), (430, 300, None), (450, 470, None),
        (462, 690, None), (440, 800, None), (380, 838, None), (310, 820, None), (285, 690, None),
        (lx + lr, ly, 2)] + arc(lx, ly, lr, 0, 232, 5) +
        [(lx + lr * math.cos(math.radians(232)), ly + lr * math.sin(math.radians(232)), 2),
         (0, 428, 40)]))
    ax, ay = C + 238, 362
    holes = [octagon(C - 263, 353, 66), circle(C, 344, 26), circle(ax, ay, 46),
             kidney(ax, ay, 116, -128, -78, 48, n=3), kidney(ax, ay, 116, -34, 14, 48, n=3),
             circle(C + 120, 390, 30), octagon(C + lx, ly, 50),
             cross(C - lx, ly, h=60, arm=48, ro=12, ri=8)]
    return [body], holes


@model("n64", "N64-style three-grip pad")
def n64():
    # N64 (from the owner's N64 reference, about as wide as high): an arched top between two
    # shoulder caps that stand out over the bulging sides, two outer grips and a centre prong
    # that reaches lowest, with narrow slots between them. The D-pad on the left wing, Start in
    # the middle, the stick at the top of the centre prong, B and A on the right wing below the
    # four C buttons.
    body = rpoly(mirror([
        (0, 28, None), (165, 52, 40), (290, 58, 40), (330, 92, 30), (328, 122, 14),
        (400, 160, None), (440, 260, None), (452, 470, None), (444, 640, None), (410, 724, None),
        (355, 738, None), (298, 716, None), (272, 640, None), (256, 540, None), (238, 468, 30),
        (190, 462, 30), (150, 532, None), (134, 660, None), (118, 800, None), (80, 900, None),
        (0, 936, None)]))
    holes = [cross(190, 291, h=70, arm=52, ro=14, ri=9), circle(C, 335, 26), circle(C, 509, 72),
             circle(585, 300, 34), circle(668, 384, 32)] + diamond(755, 262, d=66, r=24)
    return [body], holes


# --- 8BitDo-style ------------------------------------------------------------------------------

@model("8bitdo_pro2", "8BitDo Pro 2")
def eightbitdo_pro2():
    body = rpoly(mirror([
        (0, 210, None), (170, 180, 90), (372, 172, 120), (462, 310, 100), (458, 580, 120),
        (426, 840, 100), (320, 892, 70), (214, 800, 70), (0, 742, 170)]))
    holes = ps_features() + [circle(C, 400, BTN_R)]
    return [body], holes


@model("8bitdo_sn30pro", "8BitDo SN30 Pro")
def eightbitdo_sn30pro():
    body = rpoly(mirror([
        (0, 206, 120), (210, 168, None), (420, 206, None), (466, 400, None), (424, 680, None),
        (230, 760, None), (0, 760, 120)]))
    holes = ps_features(ys=596) + [circle(C, 400, BTN_R)]
    return [body], holes


@model("8bitdo_ultimate", "8BitDo Ultimate")
def eightbitdo_ultimate():
    body = rpoly(mirror([
        (0, 172, None), (270, 140, 140), (432, 214, 100), (464, 420, 130), (430, 720, 120),
        (340, 874, 70), (244, 846, 70), (186, 790, 60), (0, 796, 160)]))
    holes = [circle(C, 436, BTN_R)] + xbox_features()
    return [body], holes


@model("retro_pad", "Retro pad (no sticks)")
def retro_pad():
    body = rpoly(mirror([
        (0, 290, 120), (200, 246, None), (420, 266, None), (466, 470, None), (420, 690, None),
        (200, 728, None), (0, 760, 120)]))
    holes = [cross(C - 262, 470)] + diamond(C + 234, 470) + [
        capsule(C - 44, 540, 110, 64, -40), capsule(C + 72, 610, 110, 64, -40)]
    return [body], holes


# --- Others ------------------------------------------------------------------------------------

@model("steam_controller", "Steam Controller")
def steam_controller():
    # Steam Controller (FINE; from the owner's Steam Controller reference, about 1.41 wide to 1
    # high): a flat top, rounded shoulders, sides that lean out to wide grips with round tips, and
    # a straight bottom edge between them. The two big round trackpads high on the wings, the
    # Steam button between them, the stick below the left pad and the four buttons below the right
    # one, both close to the middle. The Back and Start bars are left out (no room at 24 u).
    body = rpoly(mirror([
        (230, 150, 120), (335, 182, 90), (400, 340, None), (448, 560, None), (462, 650, None),
        (440, 760, None), (375, 812, 70), (300, 812, 50), (245, 750, None), (190, 640, None),
        (130, 614, 40)]))
    holes = [circle(C - 244, 332, 90), circle(C + 244, 332, 90), circle(C, 318, 32),
             circle(C - 102, 476, 50)] + diamond(C + 102, 476, d=66, r=24)
    return [body], holes


@model("steam_deck", "Steam Deck-style handheld")
def steam_deck():
    body = rpoly([(28, 226, 190), (932, 226, 190), (932, 734, 190), (28, 734, 190)])
    holes = [rrect(300, 306, 660, 654, 26), circle(178, 380, 56), rrect(124, 506, 236, 618, 26),
             circle(782, 380, 56), rrect(724, 506, 836, 618, 26)]
    return [body], holes


@model("stadia", "Stadia-style pad")
def stadia():
    body = rpoly(mirror([
        (0, 156, None), (250, 160, 160), (436, 236, 100), (466, 460, 140), (430, 760, 120),
        (330, 884, 80), (226, 818, 70), (0, 774, 170)]))
    holes = ps_features() + [circle(C, 448, 44)]
    return [body], holes


@model("generic_pad", "Generic gamepad")
def generic_pad():
    body = rpoly(mirror([
        (0, 196, None), (300, 164, 160), (452, 276, 100), (466, 520, 140), (420, 800, 110),
        (306, 862, 80), (214, 780, 70), (0, 744, 170)]))
    holes = ps_features()
    return [body], holes


@model("arcade_stick", "Arcade stick")
def arcade_stick():
    body = rrect(32, 270, 928, 690, 90)
    holes = [circle(232, 480, 92)]
    for x, y in [(500, 416), (640, 390), (780, 390), (476, 566), (616, 540), (756, 540)]:
        holes.append(circle(x, y, 38))
    return [body], holes


@model("keyboard", "Keyboard")
def keyboard():
    body = rrect(32, 222, 928, 738, 64)
    holes = []
    pitch = 140
    for row, y in enumerate([302, 442]):
        off = 0 if row == 0 else 40
        for i in range(6):
            x = 112 + off + i * pitch
            if x + 76 > 928 - 80:
                continue
            holes.append(rrect(x, y, x + 76, y + 76, 14))
    holes.append(rrect(112, 582, 188, 658, 14))
    holes.append(rrect(252, 582, 708, 658, 14))
    holes.append(rrect(772, 582, 848, 658, 14))
    return [body], holes
