# RuyaOS — Design system ("Dreamglass")

Status: **v1.1, Accepted (owner, 2026-10-28; ADR-012)** · Parent: [00-overview](00-overview.md) · Applies to: [02-shell](02-shell.md)

The shell's visual language: what it looks like, which tokens exist, which components exist, and how the system may change. `02-shell.md` says how the shell **behaves**; this file says how it **looks**. Like every spec it describes what is built and what is planned, and says which is which (**built** = in `Theme.qml` / `shell/qml` today; **planned (T-nnn)** = agreed, a task builds it; **proposed** = drawn, no task yet, don't build).

Visual reference: the owner's design canvas "RuyaOS Design Language" (claude.ai artifact, private to the owner; boards: Foundations, Type/space/shape, Focus/depth/motion, Home (art-led), Quick menu over a full-screen game, Launch/play/return flow, Settings, system components, art and play components). **This file wins** when the two disagree; whoever changes one updates the other in the same session (§8).

## 1. Principles

Rüya is Turkish for *dream*: a dark room lit by the thing you are about to play. The game's art fills the screen, the chrome floats over it on Gaussian-blurred glass, and one bright white ring says where you are. When a game runs, it owns the whole screen.

1. **Read from the sofa.** 3 m from a 1080p TV: body text 30 px, nothing under 24 px (badges excepted, §3.2). Text scale (100–200 %) multiplies every type step.
2. **Focus is never ambiguous.** The focused item always has the white ring (and the 1.08 scale for cards), at every quality tier and under reduced motion.
3. **Art first.** Large key art is the main visual (Home hero, art cards, launch splash). Chrome is white text on blurred glass over it; colour comes from art, avatars and the category tints, never from buttons or text.
4. **Apps own the screen.** Apps and games run full screen with no shell chrome; the Guide button is the one way back (§5.1). Motion is ease-out, under 300 ms for anything the user waits on (launch excepted), and off under reduced motion.
5. **Degrade, never break.** The Performance tier swaps blur for opaque glass; layout, sizes and focus are identical on every tier.

## 2. Units and layout

- **Design pixels:** every size is written at 1080p and multiplied by `u` (`height / 1080`), so the same numbers serve 720p and 4K (`shell/CLAUDE.md`).
- **Safe area:** the outer margin is `Theme.safeArea` (overscan, default 5 % = 96 × 54 px at 1080p), never a spacing token. Nothing focusable or readable sits outside it; backdrops and scrims fill the whole screen.
- **Home (art-led, planned T-146):** full-bleed hero art of the focused game (L0) with a left legibility scrim (`heroScrim`) and a bottom fade; top bar in the safe area: section nav (Home, Games, Media, Store, Settings icon) left, status cluster (controller battery, clock, profile) right, both glass pills; hero block left (eyebrow, title `typeHero` Bold, meta, Play + Details); the Recent row of art cards along the bottom; hint bar under it.
- **Pages** (Settings, Store, …): top bar as on Home, page title `typeTitle`, content, hint bar. The backdrop stays the last hero art, blurred and dimmed. Two-pane pages (Settings): list 520 px, gap `spaceXxl`, pane on a `radiusL` glass panel with `spaceXl` padding.
- **Running app:** nothing of the shell is drawn except the quick menu (Guide), the volume OSD and critical toasts (§5.1).

## 3. Tokens (`shell/qml/Theme.qml`)

Components use tokens only; `scripts/lint-tokens.ps1` fails on literal colours and durations (font sizes too, since T-142; spacing and radii: T-143). Names below are the `Theme` property names.

### 3.1 Colour (built)

| Role | Token | Value | Use |
|---|---|---|---|
| Ground | `background` | `#05070d` | Behind everything |
| Panel | `panel` | `#1a1d26` | Opaque cards (Guide overlay, dialogs) |
| Glass | `glass` / `glassOpaque` / `glassBorder` | white 12 % / `#182033` at 90 % / white 20 % | Shelf, rows, panes. `glassOpaque` when `blurMax` is 0 |
| Scrim | `scrim` / `scrimOverlay` | black 82 % / 85 % | Behind PIN pad and keyboard / behind the Guide overlay |
| Text | `text` / `textDim` | `#f2f4f8` / `#a3abbd` | Primary / secondary text |
| Focus | `focusRing`, `focusFill`, `selectedFill` | white, white 20 %, white 10 % | §4 |
| Keys | `keyFocusFill`, `entryKeyFocusFill`, `entryKeyActiveFill` | white 22 %, 24 %, 30 % | PIN pad, on-screen keyboard |
| Status | `toastInfo`, `toastSuccess`, `toastWarning`, `toastError`, `errorText`, `warningText` | `#6ea8ff`, `#4cc38a`, `#ffb74d`, `#ff6b6b`, `#ff8a80`, `#ffb74d` | Toast bars, messages |
| Danger | `dangerFill` | `#8f2d2d` | Confirm button of destructive actions only |
| Primary (planned, T-146) | `primaryFill` / `onPrimary` | `#f2f4f8` / `#05070d` | The one main verb per screen (Play, Install, Resume) |
| Art scrims (planned, T-146) | `heroScrim` / `artCaptionFade` | night at 75 % → 0 over 75 % width / night 85 % → 0, bottom up | Legibility over art; text on art is always `text` |
| Tints | `defaultTint`, `tileAccent(key)` | games `#3a5bd9` (Ruya indigo), media `#d9483a`, store `#2fa37a`, settings `#7a5bd9`, other `#5a6478` | Backdrop tint, tiles, fallback avatar |

Contrast (WCAG, measured): `text` on `background` 18.3:1, on `panel` 15.3:1; `textDim` 8.7:1 on `background`, 7.3:1 on `panel`; `errorText` 8.8:1. **`textDim` only on opaque surfaces** (`background`, `panel`, `glassOpaque`, scrims): on glass over a bright tint it falls to about 2.8:1, so text on the shelf or over the backdrop is `text`. Status colours are never the only signal: a toast has a title word, a row has a message.

### 3.2 Type (built, T-142)

Typeface: **Inter** (OFL-1.1), bundled as a Qt resource (owner, 2026-10-28; T-145); until T-145 lands the system sans is used. Game titles in the hero use `typeHero` at Bold with -2 % tracking. Seven steps replace the twelve sizes that were in use (20, 26, 28, 30, 32, 34, 36, 38, 44, 56, 64, 96). Sizes outside the table were mapped to the nearest step in T-142: 40 (the keyboard entry text) and 36 (key caps) to `typeHeadline`, 52 to `typeTitle`, 84 (wizard glyphs) to `typeDisplay`. Tokens: `typeHero`..`typeMicro`, `weightLight`/`weightRegular`/`weightDemiBold`/`weightBold`, `fontFamily` (empty until T-145). Call sites write `Theme.typeBody * u`; the weights are not applied at call sites yet.

| Token | px / weight | Use | Replaces |
|---|---|---|---|
| `typeHero` | 96 / Light | Avatar initials | 96 |
| `typeDisplay` | 64 / Light | Home section name, page hero | 64 |
| `typeTitle` | 48 / DemiBold | Page and dialog titles | 44, 56 |
| `typeHeadline` | 34 / DemiBold | Tile titles, profile names, header, overlay actions, toast glyph | 32, 34, 36, 38 |
| `typeBody` | 30 / Regular | Rows, messages, toast and OSD text | 28, 30 |
| `typeCaption` | 24 / Regular | Secondary lines, hints | 26 |
| `typeMicro` | 20 / DemiBold, caps | Badges of one or two words, dev flags | 18, 20 |

Turkish runs about 30 % longer than English: rows elide on the right (`Text.ElideRight`), titles never wrap to more than two lines.

### 3.3 Spacing, shape, size (planned, T-143)

- **Spacing** (8 px grid): `spaceXxs` 4, `spaceXs` 8, `spaceS` 16, `spaceM` 24, `spaceL` 36, `spaceXl` 48, `spaceXxl` 64, `spaceXxxl` 96. Rows in a list `spaceS`; tiles in a row `spaceL`; panel padding `spaceXl`; between sections `spaceXxl`.
- **Radius:** `radiusS` 12 (keys, badges), `radiusM` 18 (tiles, art), `radiusL` 32 (panels, dialogs); pills are `height / 2` (rows, buttons, toasts, OSD).
- **Sizes:** `rowHeight` 84, `buttonHeight` 76, `tileWidth` 400 × `tileHeight` 260, `avatarSize` 200, `focusRingWidth` 4, `focusRingOffset` 7, `hairline` 1 (`Math.max(1, u)`).

### 3.4 Motion (built)

`focusMs` 140, `pageMs` 300 (slide `pageSlide` 60), `overlayMs` 200, `tintMs` 700 (also the hero art cross-fade), `launchMs` 400 (planned, T-147), pulse 0.94 over 70 + 180 ms, wrong-PIN shake 18 px over 45 / 90 ms, ambient drift 18–29 s periods. Easing: `OutCubic` for focus, pages and overlays, `InOutQuad` for tints, `InOutSine` for drift, `OutQuad`/`OutBack` for the pulse. Reduced motion: every duration 0, no pulse, no shake, no drift (`02-shell.md` §3.2). Only `opacity`, `scale`, `x`/`y` and colour animate.

### 3.5 Depth

| Layer | z | Contents | Rule |
|---|---|---|---|
| L0 | backdrop / app | Hero art (Home), blurred hero art (pages), tinted blobs when there is no art, or **the running app** | One shared blur, never stacked |
| L1 | 0 | Home shelf, pages, panes (glass) | |
| L2 | 10 | Toasts | Never take focus |
| L3 | 20 | Modals: picker, setup, PIN pad, keyboard, Guide overlay (scrim + `panel`) | Accept every key |
| L4 | 30 | Volume OSD | Never takes focus |

### 3.6 Glass and blur

Glass is translucent white over a **Gaussian blur** of what is behind it (`MultiEffect`, `blurMax` per tier: High 64, Balanced 32, Performance 0). Rules: glass always comes with blur, or it turns opaque (`glassOpaque`): never translucent glass over sharp art. One shared blurred copy of L0 (downscaled), sampled by every glass panel; never a second fullscreen blur. `glassStrong` (planned, T-146: white 12 % plus a slight saturation boost) is for the top bar and the quick menu. Glass over a **running app** blurs a downscaled copy of the app surface; until that is measured on a GPU (B-003) the quick menu uses `glassOpaque` on every tier.

## 4. Focus

| Item kind | Focused look |
|---|---|
| Cards (tile, profile, later app art) | `focusScale` 1.08, white ring `focusRingWidth` at `focusRingOffset` outside, ring radius = shape radius + offset, z above neighbours |
| Rows and buttons | No scale; fill `focusFill`, border 1 → 4 px `focusRing` |
| Keys (PIN pad, keyboard) | Fill only (`keyFocusFill` / `entryKeyFocusFill`) plus the ring; the grid never moves |
| List selection without focus | `selectedFill`, text `text` and DemiBold |

The ring never fades out during a move (it may fade in), is never hidden by a quality tier, and focus is never shown by colour alone. Unavailable items use `disabledOpacity` (0.4) and are skipped or say why ("Not available").

## 5. Components

Each entry: file, status, and the rules a change must keep. A new component gets a row here before it is built (§8).

| Component | File | Status | Rules |
|---|---|---|---|
| Tile | `Tile.qml` | built; replaced on Home by Section nav + Art cards (T-146) | `radiusM`, gradient from `tileAccent`, title `typeHeadline` bottom-left, card focus |
| Art card | `ArtCard.qml` | planned (T-113, reused by T-146) | 16:9 key art edge to edge, `radiusM`, title on `artCaptionFade`, state pills in words (Running, Installing n %), card focus; no art: app icon on a tint from the id hash |
| Cover card | `CoverCard.qml` | proposed | 2:3 cover for the Library grid; falls back to the 16:9 art cropped centre |
| Hero block | `HeroBlock.qml` | planned (T-146) | Eyebrow `typeCaption` caps, title `typeHero` Bold, meta `typeBody`, Play (primary) + Details (secondary); follows the focused card, art cross-fades over `tintMs` |
| Buttons | `PrimaryButton.qml`, `SecondaryButton.qml` | planned (T-146) | Pill `rowHeight`; primary `primaryFill`/`onPrimary`, focused = dark gap + white ring; secondary = glass, row focus |
| Section nav | `SectionNav.qml` | planned (T-146) | Glass pill of section pills; current = `primaryFill`, focus = ring; LB/RB switch sections |
| Quick menu | `QuickMenu.qml` | planned (T-147) | Left panel 640 px over the live app on `glassStrong` (opaque until B-003): app header, Resume (focused first), Home, Close game, Switch to, volume, profile, Power; replaces the centred Guide card |
| Launch splash | `LaunchSplash.qml` | planned (T-147) | Blurred hero art, title, spinner until the app's first frame; "Still starting" + Close after 20 s |
| Profile card | `ProfileCard.qml` | built | Avatar circle in the profile colour, initial `typeHero`, name dims to `textDim` when unfocused, PIN badge |
| Setting rows | `controls/SettingControl.qml` + `SettingRow`, `ToggleRow`, `ChoiceRow`, `SliderRow` | built | Pill `rowHeight`, label left `typeBody`, value right; optional swatch dot; row focus |
| Category item | `SettingsPage.qml` | built | Pill, `textDim` at rest, `selectedFill` when chosen, row focus |
| Dialog buttons | `PowerConfirm.qml` | built | Pills `buttonHeight`; the safe choice has focus first; only the destructive confirm uses `dangerFill` |
| PIN pad | `PinPad.qml` | built | 3 × 4 grid of `radiusS` keys, digit dots, message in `errorText` below; the grid stays left to right in RTL |
| On-screen keyboard | `TextEntry.qml` | built | Key fills rest 8 % / focused / latched (`entryKeyActiveFill`) |
| Toast | `ToastLayer.qml` | built | `toastBackground` card `radiusM` (20 today), status bar in the status colour + title word + one line |
| Volume OSD | `VolumeOsd.qml` | built | Bottom centre, pill, icon + bar + number, "Muted" in words |
| Guide overlay | `Shell.qml` | built | `scrimOverlay` + `panel` card `radiusL`, title `typeTitle`, actions as rows |
| Backdrop | `Backdrop.qml` | built | Tint from focus, three drifting blobs, `tintMs` cross-fade |
| Badge | (inline today) | planned (T-143) | `typeMicro`, pill; source badges Official (success colour), Community (info), Dev (warning) on a 18 % fill of their colour |
| Hint bar | — | proposed | Bottom-left, controller glyph + verb for the actions the focused item accepts; needs pad-type glyphs (B-006) |

### 5.1 Full-screen apps (look; behaviour in `02-shell.md` §1.5)

Launch: Accept on Play → art takes the screen (chrome fades, hero art scales 1.0 → 1.04 and blurs in, `launchMs`) → splash until the first frame → cross-fade to the app. Guide over an app opens the quick menu (slides in from the left, `overlayMs`; the app keeps running behind it). Home from the quick menu shrinks the app into its Running card (`pageMs`). Reduced motion turns each step into a cut; the Performance tier skips every blur.

## 6. Writing

- Sentence case everywhere ("Reduced motion", not "Reduced Motion"); the brand "RuyaOS" and language names are never translated.
- Buttons and actions are verbs ("Restart", "Add profile"); a confirm repeats the verb of the question ("Restart now?" → Restart / Cancel).
- Errors say what happened and what the user can do, in at most two short sentences ("Wrong PIN. 2 tries left."). No "please", no codes, no blame.
- Row labels stay under about 28 characters in English so the Turkish fits.

## 7. Accessibility

- Text contrast ≥ 4.5:1 against the surface it actually sits on, worst case (backdrop at its brightest tint); the focus ring ≥ 3:1 against both the item and its surroundings (white on any tint passes).
- High-contrast theme, text scale and focus-ring size (`02-shell.md` §7) will be token sets over the same names, so components need no change: never compute a colour in a component (`Qt.lighter` of a token for a gradient is the one allowed exception, as in `Tile.qml`).
- Every interactive item has `Accessible.name`; decoration has none. **Not done anywhere yet** (Inbox): needed before the Orca spike (`02-shell.md` §7).

## 8. Changing the design system

- **Builders use what exists.** Pick the closest token and component. If the task truly needs a new value or component, use the closest existing one, add an Inbox line `(T-nnn) design: needs <token/component> because <reason>`, and say so in the Outcome. Never add a one-off literal (`// token-ok` is for non-visual numbers only).
- **The lead (or a task that says so) changes the system.** A new or changed token or component is one commit that updates `Theme.qml`, this file (table and status), the screenshots that changed, and names the canvas board to update. Mark the commit `design:` in its summary (area `shell` or `docs`).
- **Owner-level:** a new typeface or icon set (licence), a new brand colour, or anything that changes the five principles; ask, as a *Proposed* ADR.
- **Screenshot review** (every UI task, `dev.ps1 shots`): focus visible on every screen; nothing outside the safe area; type only from §3.2; `textDim` only on opaque surfaces; Turkish fits without clipping; Performance tier (`--effects performance`) keeps the layout.
