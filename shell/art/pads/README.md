# Controller silhouettes

One SVG per controller model, drawn for RuyaOS: the outline of the pad seen from the front, with
the sticks, the D-pad and the face buttons as cut-outs. They replaced the jagged family glyphs
(RUY-491): `scripts/add-pad-glyphs.py` adds every file here to the icon font as `pad_<model>`
(`scripts/subset-icons.sh`), `DeviceIcons.iconFor(kind, family, model)` draws it, and the
services report the `model` from the table in `services/ruya-pads`. `scripts/lint-icons.ps1`
and the table's own test list this folder, so a drawing needs a glyph line in
`shell/fonts/icons.txt`, an entry in `shell/qml/Icon.qml` and `DeviceIcons.padModels`, and an
entry in `services/ruya-pads/src/lib.rs`.

Design canvas (Claude Design, on the RuyaOS Dreamglass system): "RuyaOS Controller
Silhouettes", every model at 160, 40, 32 and 24 u on glass and on the panel, in the Dreamglass
and the Daylight theme.

## Our own drawings

Every silhouette is built in code (`src/models.py`) from rounded polygons, circles, crosses and
capsules; none is traced from a photo, a render or vendor artwork, and none carries a logo, a
wordmark or a button symbol (the four face buttons are plain dots). A model is recognisable by
its form factor only: where the grips go, where the sticks sit, a touchpad, two trackpads, a
screen. This follows `04` §3.7 and `06` §11.4. The wider question of drawing recognisable
products at all (pad art, owner-decision RUY-387 / T-199) is still open; the file names use
product names only to say which device a drawing is for.

## Drawing rules

- `viewBox="0 0 960 960"` like Material Symbols, one `<path>`, `fill="currentColor"`,
  `fill-rule="evenodd"`, no stroke, no transform, no style, about 2 KB at most (2100 bytes;
  the largest, the GameCube, is 2002). Coordinates are whole units; each command is written
  absolute or relative, whichever is shorter (the points are the same either way).
- The body winds clockwise and every cut-out counter-clockwise, so the path fills the same under
  the evenodd and the nonzero rule (a font glyph is nonzero).
- Smooth outlines: every corner is a cubic Bézier arc; the bodies are fully curved.
- The glyph's box is centred on 480, 480; wide pads span about 900 of the 960.
- Sizes at 24 u (1 u = 40 units), checked by `src/build.py` for every model:
  - **rim** (body edge to any cut-out) at least 64 units = **1.6 u**;
  - **cut-outs** at least 56 units across = 1.4 u;
  - **webs** between two cut-outs at least 56 units = 1.4 u;
  - two separate bodies (a Joy-Con pair, a remote and its Nunchuk) at least 64 apart.
  At 24 u the four face buttons read as one diamond and each stick as a dot; the outline and the
  layout carry the model.
- **Fine models** (`FINE` in `src/models.py`: DualSense, DualSense Edge, DualShock 4, Wii
  Remote, Wii Remote with Nunchuk, GameCube, N64, Steam Controller; owner review 2026-11-13):
  their faces follow the real proportions without stretching, so the features are smaller and
  the checks are rim **1.2 u** (48), webs **1.1 u** (44) and holes **1.2 u** (48). The
  DualSense and DualShock 4 get their big touchpads (the DualSense's narrowing toward its
  bottom), face buttons r 26 on a diamond of 68, a D-pad of span 160 and arm 52, sticks r 48
  tucked under the touchpad, and the home button between them.
  - **GameCube** (about 1.29 to 1): a broad arched top, long grips, and between them two round
    housings hanging from a high bottom edge, one for the D-pad and one for the C-stick, meeting
    the grips and the bottom edge in sharp cusps. The left stick sits in an octagonal gate top
    left; the big A has the X and Y kidneys curling round it and the small B below and left.
  - **N64** (about as wide as high): an arched top between shoulder caps that stand out over
    the bulging sides, two outer grips and a longer centre prong with narrow slots between
    them. The D-pad is on the left wing, Start in the middle, the stick at the top of the centre
    prong, B and A on the right wing below the four C buttons (r 24 on a diamond of 66).
  - **Steam Controller** (about 1.41 to 1): a flat top, sides leaning out to wide grips, a
    straight bottom edge between them; the two big round trackpads high on the wings, the Steam
    button between them, the stick and the four buttons close to the middle below the pads. The
    Back and Start bars are left out (no room at 1.2 u).
- Feature sets of the other models:
  - **Small** (DualShock 3, Xbox One, Series, Elite, 360, Switch Pro, Wii U Pro; owner review
    2026-11-13): face buttons r 30 on a diamond of 84, a D-pad of span 180 and arm 60, sticks
    r 52. Smaller features leave room for the shape a real pad has: bumper tabs on narrow
    shoulders, grips that flare down and out and are the widest part, and a high arch between
    them that rises right under the sticks. The DualSense pair is wider (about 1.45 to 1): a
    flat top over a large touchpad, the sticks tucked under it, a straight bottom edge just
    under the sticks and long grips hanging from the wings. The DualShock 4 is flatter (about
    1.6 to 1) with round grip lobes and the home button between the sticks. The DualShock 3
    has no touchpad: round wing lobes carry the D-pad and buttons, narrow grips lean far out,
    and the bottom edge curves under the sticks. The Xbox 360 (about 1.53 to 1) widens
    steadily to round grip tips under a wide, shallow arch; its buttons are a tighter diamond
    (r 28 on 80) to fit beside the right stick. The Switch Pro (about 1.43 to 1) has a gentle
    arc on top, big round shoulders and a flat bottom edge; only Home fits in the middle. The
    Wii U Pro (about 1.48 to 1) has both sticks high and outboard, the D-pad and buttons level
    below them, and a smooth round arch between flared grips.
  - **Proportion references.** The owner supplied reference icons for these pads (SVG Repo,
    Noun Project, CC BY). Ten to twenty points of each outline were measured and scaled into
    the 960 box; no path was copied or traced, and every curve here is built by
    `src/models.py` from those points. The PlayStation, Xbox, Switch Pro, Wii U Pro, Wii,
    GameCube, N64 and Steam Controller pads follow their measured outlines. The DualShock 3 is stretched a little between its
    buttons and its bottom edge because its larger features keep the 1.6 u rim; the DualSense
    and DualShock 4 are fine models and keep the references' proportions (about 1.52 and 1.58
    to 1).
  - **Large** (the first pass, still on the Joy-Cons, the three 8BitDo pads, the retro pad,
    Steam Deck, Stadia, the generic pad, the arcade stick, the keyboard and the Xbox Adaptive):
    face buttons r 36 on a diamond of 100, a D-pad of span 216 and arm 72, sticks r 60, rim
    2 u. These bodies are fuller (shorter grips, a shallow arch) and were not drawn from
    references. Redrawing them with the method below is open work.

## Inventory

Family = what the services report today (`services/ruya-inputd/src/identity.rs` `family`:
vendor id, then driver; `services/ruya-devices/src/families.rs`: Bluetooth modalias vendor,
then the name). Ids are USB vendor:product from the public Linux driver tables (`hid-ids.h`,
`xpad`, `hid-nintendo`, `hid-wiimote`, `hid-steam`) and SDL; **none was checked on hardware
here** except what the owner's Dell already showed (a DualSense over Bluetooth).

| File | Model | Family today | Ids (vendor:product) and names | Notes |
|---|---|---|---|---|
| `dualsense.svg` | DualSense | playstation | 054C:0CE6 | Touchpad narrowing toward its bottom, home button between the sticks. On the Dell |
| `dualsense_edge.svg` | DualSense Edge | playstation | 054C:0DF2 | DualSense body with two Fn buttons on the wings in place of the home button |
| `dualshock4.svg` | DualShock 4 | playstation | 054C:05C4 (v1), 054C:09CC (v2), 054C:0BA0 (USB adaptor) | Round grip lobes, home button between the sticks |
| `dualshock3.svg` | DualShock 3 | playstation | 054C:0268 | No touchpad, round wing lobes, grips leaning far out; home button above the sticks |
| `xbox_series.svg` | Xbox Series X\|S | xbox | 045E:0B12 (USB), 045E:0B13 (BT) | Guide on top, Share dot below it |
| `xbox_one.svg` | Xbox One | xbox | 045E:02D1, 02DD, 02EA (One S USB), 02E0, 02FD, 0B20 (One S BT) | Guide only |
| `xbox_elite.svg` | Xbox Elite / Elite Series 2 | xbox | 045E:02E3 (Elite), 0B00 (Series 2 USB), 0B05, 0B22 (Series 2 BT) | Faceted dish D-pad, profile switch |
| `xbox_360.svg` | Xbox 360 | xbox | 045E:028E (wired), 045E:0719 and 0291 (wireless receiver) | Wide and round, shallow arch, round grip tips, guide at the top centre. Many third-party pads in X-input mode report 045E:028E too |
| `xbox_adaptive.svg` | Xbox Adaptive Controller | xbox | 045E:0B0A (USB); Bluetooth id unknown | Slab with two large buttons |
| `switch_pro.svg` | Switch Pro Controller | nintendo | 057E:2009 | Xbox-like layout, flat bottom edge, one home dot, no top guide |
| `joycon_left.svg` | Joy-Con (L) | nintendo | 057E:2006 | Rail on the right, stick over four buttons |
| `joycon_right.svg` | Joy-Con (R) | nintendo | 057E:2007 | Rail on the left, buttons over stick |
| `joycon_pair.svg` | Joy-Con pair | nintendo | 057E:200E (charging grip); the kernel's combined Joy-Con device | Two Joy-Cons side by side |
| `wiiu_pro.svg` | Wii U Pro Controller | nintendo (by vendor; driver `wiimote`) | 057E:0330, name "Nintendo RVL-CNT-01-UC" | Both sticks above the D-pad and buttons. On the Dell. 0330 is shared with the Wii Remote Plus: only the name tells them apart |
| `wii_remote.svg` | Wii Remote | nintendo (by vendor) | 057E:0306 ("Nintendo RVL-CNT-01"), 057E:0330 ("Nintendo RVL-CNT-01-TR", Remote Plus) | Slim bar: D-pad, A, Home, 1 and 2 (power, - and + left out) |
| `wii_remote_nunchuk.svg` | Wii Remote with Nunchuk | nintendo | as the Wii Remote, with the Nunchuk extension attached | Egg-shaped Nunchuk with its stick in an octagonal gate, beside and lower than the remote. The extension is reported by `hid-wiimote`, not by an id |
| `gamecube.svg` | GameCube-style pad | nintendo | 057E:0337 (the four-port adapter) | Stick and D-pad housings between the grips, large A, kidney X and Y, octagonal stick gate |
| `n64.svg` | N64-style three-grip pad | nintendo | 057E:2019 (Switch Online N64 pad) | Three grips, stick on the middle one |
| `retro_pad.svg` | Retro pad (no sticks) | nintendo or 8bitdo or generic | 057E:2017 (Switch Online SNES pad); 8BitDo SN30 and other pads without sticks, by name | Two slanted Select/Start slots |
| `8bitdo_pro2.svg` | 8BitDo Pro 2 | 8bitdo (D-input) or xbox (X-input: 045E:028E) | 2DC8 ids vary by mode, firmware and revision (2DC8:3106 is reported for the Pro 2 wired and for the Ultimate dongle alike); name "8BitDo Pro 2" | PlayStation-style stick layout under a SNES-style top |
| `8bitdo_sn30pro.svg` | 8BitDo SN30 Pro / SN30 Pro+ | 8bitdo or xbox | 2DC8 ids vary by mode and firmware; name "8BitDo SN30 Pro" | Rounded oblong, no grips |
| `8bitdo_ultimate.svg` | 8BitDo Ultimate | 8bitdo or xbox | 2DC8:3106 / 3109 (2.4 GHz dongle states, shared); name "8BitDo Ultimate" | Xbox-style layout, round body |
| `steam_controller.svg` | Steam Controller (2015) | generic (Valve 28DE is in no table) | 28DE:1102 (USB), 28DE:1142 (dongle), 28DE:1106 (BT) | Two round trackpads |
| `steam_deck.svg` | Steam Deck-style handheld | generic | 28DE:1205 (built-in controls) | Screen between sticks and trackpads; D-pad and buttons left out |
| `stadia.svg` | Stadia-style pad | generic (Google 18D1 is in no table) | 18D1:9400 | Large centre button |
| `generic_pad.svg` | Generic gamepad | generic | anything else that is a gamepad | Replaces Material's `sports_esports` |
| `arcade_stick.svg` | Arcade stick | generic | no ids; by name ("fight stick", "arcade") or a later capability check | Ball-top lever and six buttons |
| `keyboard.svg` | Keyboard | (kind `keyboard`) | any keyboard | Same family look as the pads; Material's `keyboard` is the alternative |

## Mapping (built, RUY-491)

`services/ruya-pads` (`model_of(vendor, product, name)`) picks the file from the first rule that
matches; the services report it as the `model` key (`Devices1`, `Input1`):

1. **Names that beat ids** (8BitDo pads, whose ids vary with the mode and are Microsoft's in
   X-input mode; "Combined Joy-Cons"; arcade sticks).
2. **(vendor, product)** from the table above. For 057E:0330 the device name decides
   (`-UC` -> `wiiu_pro`, `-TR` -> `wii_remote`, neither -> no model).
3. **Name fragments** of the pad's own maker (or any name when no vendor id is known).
4. No model: the shell draws the **family's** silhouette (playstation -> `dualsense`, xbox ->
   `xbox_series`, nintendo -> `switch_pro`), then Material's `sports_esports`.

Left without a rule: `keyboard` (a kind, Material's glyph stays), `wii_remote_nunchuk` (the
extension is reported by `hid-wiimote`, not by an id). The 8BitDo family and `generic` pads still
fall back to `sports_esports` when no model is named.

## Drawing a new model (the method, owner 2026-11-13)

Every new or redrawn silhouette is made this way, the way the PlayStation, Xbox, Nintendo, Wii,
GameCube, N64 and Steam pads were. The first-pass models listed under **Large** get redrawn
this way as soon as references for them arrive.

1. **A reference.** The owner supplies a reference icon whose licence allows using it as a
   reference (for example a Noun Project or SVG Repo icon, CC BY). It stays outside the repo and
   is never committed. Its source and licence go in the commit message.
2. **Measure, never copy.** `python -I -B shell/art/pads/src/measure.py <ref.svg> <path index>`
   prints about 90 points of the reference's outline (the first subpath of that `<path>`),
   scaled into the 960 box. Read the button and stick centres off the reference the same way.
   The reference's path data never goes into a file here: no paste, no conversion, no tracing.
3. **Build our own curves.** Write the body in `src/models.py` as `rpoly` vertices chosen from
   those points: 10 to 20 for the right half (dx from the axis 480, y), listed clockwise from the
   top, mirrored with `mirror()` when the pad is symmetric. Use `d=None` for a free curve, a
   number for a tighter corner, `arc()` for a round housing, and `d=2` (never 0) for a sharp
   cusp. Add the features from the measured centres, with the shape kit in `src/geom.py`.
4. **Keep the proportions.** If the face does not fit the size checks, add the model to `FINE`
   (rim 1.2 u, webs 1.1 u, holes 1.2 u) and make the features smaller. Never stretch the body
   or go under the fine limits. Leave out what still does not fit, such as small Select and
   Start bars, and say so in the model's comment and below.
5. **Compare.** `python -I -B shell/art/pads/src/overlay.py <out.png> <model>=<ref.svg>:<path
   index>[:<inset>]` draws the reference outline in red over our silhouette. For a stroked
   (line) reference, give minus half its stroke width as the inset. Adjust the vertices until
   the red line lies on our edge.
6. **Check.** Run `build.py` (next section): 0 problems and at most 2100 bytes. Read the model's
   contact sheet at 160, 40, 32 and 24 u, and at 24 and 16 px blown up.
7. **Record.** Describe the model under **Drawing rules** (its ratio, what it shows and what it
   leaves out), add or update its inventory row, refresh the canvas if one is in use, and
   commit the SVG and the source together.

## Regenerating

```bash
python -I shell/art/pads/src/build.py shell/art/pads <scratch dir>
```

`src/geom.py` holds the shape kit and the size limits, `src/models.py` one function per
model, `src/build.py` orients, centres and checks every model, writes the SVGs and renders
contact sheets into the scratch dir (Pillow needed). `src/measure.py` and `src/overlay.py` are
the drawing aids of the method above. A model name after the scratch dir builds only that
model. Change a model, re-run, read its sheet, commit the SVG and
the source together.
