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
5. **Degrade, never break.** Blur and shadows are the default look wherever the GPU supports them (owner, 2026-11-06): richer depth is a goal, not something to trade away early. The tiers are the fallback for hardware that can't carry them: the Performance tier swaps blur for opaque glass and drops shadows; layout, sizes and focus are identical on every tier.

## 2. Units and layout

- **Design pixels:** every size is written at 1080p and multiplied by `u` (`height / 1080`), so the same numbers serve 720p and 4K (`shell/CLAUDE.md`).
- **Safe area:** the outer margin is `Theme.safeArea` (overscan, default 5 % = 96 × 54 px at 1080p), never a spacing token. Nothing focusable or readable sits outside it; backdrops and scrims fill the whole screen.
- **Home (art-led, built T-146):** full-bleed hero art of the focused game (L0) with a left legibility scrim (`heroScrim`) and a bottom fade; top bar in the safe area: section nav (Home, Games, Media, Store, Settings icon) left, status cluster (controller battery, clock, profile) right, both glass pills; the same top bar stays on the four section pages (T-168, lead decision 2026-11-03) and is hidden on detail pages, modals, the picker and the wizard; hero block left (eyebrow, title `typeHero` Bold, meta, Play + Details); the Recent row of art cards along the bottom; hint bar under it (built, T-158; the Recent row sits above it, both inside the safe area). As built: the status cluster is the controller battery (T-161: a battery icon from the bundled font and the lowest controller's level, in the warning colour at 15 % or less while discharging, hidden without a controller), the profile and the clock, and the Settings pill is the `settings` icon from the bundled font (T-157), outlined, filled while Settings is the current section.
- **Pages** (Settings, Store, …): top bar as on Home, page title `typeTitle`, content, hint bar. Content ends above the hint bar: `Page.qml` keeps a bottom margin of the safe area plus `glyphSize + spaceM`, reserved even when `hints` is empty. The backdrop stays the last hero art, blurred and dimmed. Two-pane pages (Settings): the category list shows whole rows only: when the nine categories (72 px + `spaceXs`) don't fit above the hint bar it ends at the last row that does and scrolls by rows with the selection (T-175); list 520 px, gap `spaceXxl`, pane on a `radiusL` glass panel with `spaceXl` padding.
- **Running app:** nothing of the shell is drawn except the quick menu (Guide), the volume OSD and critical toasts (§5.1).

## 3. Tokens (`shell/qml/Theme.qml`)

Components use tokens only; `scripts/lint-tokens.ps1` fails on literal colours and durations (font sizes too, since T-142; spacing and radii: T-143). Names below are the `Theme` property names.

### 3.1 Colour (built)

| Role | Token | Value | Use |
|---|---|---|---|
| Ground | `background` | `#05070d` | Behind everything |
| Panel | `panel` | `#1a1d26` | Opaque cards (Guide overlay, dialogs) |
| Glass | `glass` / `glassStrong` / `glassOpaque` / `glassBorder` | white 12 % / white 12 % (same value for now; the difference is the blur's saturation boost, §3.6) / `#182033` at 90 % / white 20 % | Shelf, rows, panes. `glassOpaque` when `blurMax` is 0 |
| Scrim | `scrim` / `scrimOverlay` | black 82 % / 85 % | Behind PIN pad and keyboard / behind the Guide overlay |
| Text | `text` / `textDim` | `#f2f4f8` / `#a3abbd` | Primary / secondary text |
| Focus | `focusRing`, `focusFill`, `selectedFill` | white, white 20 %, white 10 % | §4 |
| Keys | `keyFocusFill`, `entryKeyFocusFill`, `entryKeyActiveFill` | white 22 %, 24 %, 30 % | PIN pad, on-screen keyboard |
| Status | `toastInfo`, `toastSuccess`, `toastWarning`, `toastError`, `errorText`, `warningText` | `#6ea8ff`, `#4cc38a`, `#ffb74d`, `#ff6b6b`, `#ff8a80`, `#ffb74d` | Toast bars, messages |
| Danger | `dangerFill` | `#8f2d2d` | Confirm button of destructive actions only |
| Primary (built, T-146) | `primaryFill` / `onPrimary` | `#f2f4f8` / `#05070d` | The one main verb per screen (Play, Install, Resume) |
| Art scrims (built, T-146) | `heroScrim` / `artCaptionFade` | night `#05070d` at 75 % → 0 over 75 % width / night 85 % → 0, bottom up (Home bottom fade, Art card caption) | Legibility over art; text on art is always `text` |
| Peek (built, T-185) | `peekOpacity` | 0.5 | Scroll cue: the first / last visible row of a Settings pane while more rows exist beyond it is drawn at this opacity. Not `disabledOpacity` (unavailable) |
| Tints | `defaultTint`, `tileAccent(key)` | games `#3a5bd9` (Ruya indigo), media `#d9483a`, store `#2fa37a`, settings `#7a5bd9`, other `#5a6478` | Backdrop tint, tiles, fallback avatar |

Contrast (WCAG, measured): `text` on `background` 18.3:1, on `panel` 15.3:1; `textDim` 8.7:1 on `background`, 7.3:1 on `panel`; `errorText` 8.8:1. **`textDim` only on opaque surfaces** (`background`, `panel`, `glassOpaque`, scrims): on glass over a bright tint it falls to about 2.8:1, so text on the shelf or over the backdrop is `text`. Status colours are never the only signal: a toast has a title word, a row has a message.

### 3.2 Type (built, T-142)

Typeface: **Inter** (OFL-1.1), bundled as a Qt resource (owner, 2026-10-28; T-145): static Regular, Light, SemiBold and Bold of Inter 4.1, subset to Latin + Latin Extended-A (`shell/fonts/Inter-*.ttf`, licence `OFL-Inter.txt`, cut by `scripts/fetch-inter.sh` from the pinned release zip, SHA-256 checked). `main.cpp` and the test host register them and make Inter the application font, so every Text inherits it; `scripts/check-font-coverage.py` (part of `dev.ps1 test`, and run by the cut script) fails when a character in `shell/qml`, `shell/src` or `shell/i18n` is missing from a cut, so a new string cannot fall back to another typeface silently; add the range to `scripts/fetch-inter.sh` and re-cut. Game titles in the hero use `typeHero` at Bold with -2 % tracking. Seven steps replace the twelve sizes that were in use (20, 26, 28, 30, 32, 34, 36, 38, 44, 56, 64, 96). Sizes outside the table were mapped to the nearest step in T-142: 40 (the keyboard entry text) and 36 (key caps) to `typeHeadline`, 52 to `typeTitle`, 84 (wizard glyphs) to `typeDisplay`. Tokens: `typeHero`..`typeMicro`, `weightLight`/`weightRegular`/`weightDemiBold`/`weightBold`, `fontFamily` (`"Inter"`). Call sites write `Theme.typeBody * u` and set `font.weight` themselves (Light for Hero and Display, DemiBold for Title, Headline and Micro; T-144); `scripts/lint-tokens.ps1` fails on a `Theme.typeHero/Display/Title/Headline/Micro` size in a block with no `font.weight` of its own: a `font.weight` in a nested child item or in a comment does not count, and a `font.pixelSize:` whose `Theme.type*` is on the next line is checked too (the self-check in `dev.ps1 test` has a fixture for each). De-emphasis is by weight or size, never a dimmer colour on glass. `google-noto-sans-fonts` stays in the image (lead, 2026-11-05) as the fallback for Flatpak apps and scripts that Inter's Latin cut does not cover; the shell itself never relies on it.

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

### 3.3 Spacing, shape, size (built, T-143)

- **Spacing** (8 px grid): `spaceXxs` 4, `spaceXs` 8, `spaceS` 16, `spaceM` 24, `spaceL` 36, `spaceXl` 48, `spaceXxl` 64, `spaceXxxl` 96. Rows in a list `spaceS`; tiles in a row `spaceL`; panel padding `spaceXl`; between sections `spaceXxl`.
- **Radius:** `radiusS` 12 (keys), `radiusM` 18 (tiles, art, toasts, the text-entry field), `radiusL` 32 (panels, dialogs); pills are `height / 2` (rows, buttons, badges, OSD).
- **Sizes:** `rowHeight` 84, `buttonHeight` 76, `tileWidth` 400 × `tileHeight` 260, `avatarSize` 200, `glyphSize` 40, `focusRingWidth` 4, `focusRingOffset` 7, `hairline` 1 (use `Theme.hairlineAt(u)`, never thinner than a pixel: unfocused glass, buttons and neutral badges).

### 3.4 Motion (built)

`focusMs` 140, `pageMs` 300 (slide `pageSlide` 60), `overlayMs` 200, `tintMs` 700 (also the hero art cross-fade), `launchMs` 400 (planned, T-147), pulse 0.94 over 70 + 180 ms, wrong-PIN shake 18 px over 45 / 90 ms, ambient drift 18–29 s periods. Easing: `OutCubic` for focus, pages and overlays, `InOutQuad` for tints, `InOutSine` for drift, `OutQuad`/`OutBack` for the pulse. Reduced motion: every duration 0, no pulse, no shake, no drift (`02-shell.md` §3.2). Only `opacity`, `scale`, `x`/`y` and colour animate.

### 3.5 Depth

Shadows belong to depth (focused and raised elements, glass panels, modals) and are on at the High and Balanced tiers, off at Performance (the same switch as blur); the shadow tokens are decided in §3.8 and planned, none are built yet. Effects are never removed on hardware that supports them just to keep the implementation simple.

| Layer | z | Contents | Rule |
|---|---|---|---|
| L0 | backdrop / app | Hero art (Home), blurred hero art (pages), tinted blobs when there is no art, or **the running app** | One shared blur, never stacked |
| L1 | 0 | Home shelf, pages, panes (glass) | |
| L2 | 10 | Toasts | Never take focus |
| L3 | 20 | Modals: picker, setup, PIN pad, keyboard, Guide overlay (scrim + `panel`) | Accept every key |
| L4 | 30 | Volume OSD | Never takes focus |

### 3.6 Glass and blur

Glass is translucent white over a **Gaussian blur** of what is behind it (`MultiEffect`, `blurMax` per tier: High 64, Balanced 32, Performance 0). Rules: glass always comes with blur, or it turns opaque (`glassOpaque`): never translucent glass over sharp art. One shared blurred copy of L0 (downscaled), sampled by every glass panel; never a second fullscreen blur. `glassStrong` (built, T-146: white 12 %, with a saturation boost of 0.3 on the blur) is for the top bar and the quick menu. As built, each glass pill (`GlassPill.qml`: section nav, status cluster) blurs its own quarter-resolution crop of L0 through a rounded mask, not one shared texture; both are small, never fullscreen. Glass over a **running app** blurs a downscaled copy of the app surface; until that is measured on a GPU (B-003) the quick menu uses `glassOpaque` on every tier.

### 3.8 Material and motion v2 (decided, lead, 2026-11-06; all planned, built by T-204 / T-205)

Owner, 2026-11-06: "I like the animations and the glass effect" of an open-source native TV app for LG webOS (GPL-3.0, written in C on SDL2/OpenGL). It cannot be ported (C and raw GL, not QML), and no code or assets are taken: its *techniques and parameters* were studied and are re-built here in Qt Quick on our tokens (its glass look credits the MIT `liquid-glass-react`; credit as inspiration, never its name or brand in the UI). What we adopt, with the numbers (px at the 1080p design unit):

| What | Decision | Tiers |
|---|---|---|
| **Glass layers** (on top of the blur of §3.6) | `glassSheen`: white 6 % fading to 0 over the top 35 % of the panel. `glassRim`: 1 px ring, white 15 % (30 % on the top-left half, a light from 135 deg) instead of one flat border. `glassTint`: dark neutral `#121018` at 44 % for sheets and modals over bright art (keeps white text legible). Optional edge accent: the page tint at 5 % in a band 30 % wide at the sides | sheen, rim and tint on every tier (cheap gradients; also on opaque glass); accent High and Balanced |
| **Grain** | `glassGrain`: one 128x128 noise tile (alpha noise, white 2 % and black 2.4 % overlays) over every blurred surface. Purpose: break the banding of a blurred gradient on 8-bit TV panels | High and Balanced |
| **Shadows** (the planned tokens of §3.5) | `shadowLift` (focused card): offset y 14, blur 34, black 60 %. `shadowPanel` (glass panels, modals): offset y 10, blur 30, black 35 %. `shadowPill` (top bar, pills): offset y 0.18 x height, blur min(0.6 x height, 40), black 27 %. Reduced motion does not remove them | High and Balanced (Performance: none, as before) |
| **Card focus** | On top of the 1.08 scale and the ring: `shadowLift` and a white top sheen (9 % over the top third); a one-time **glare** sweep (a soft white diagonal band crossing the card in 550 ms, alpha peak 0.6, `InOutQuad`) that plays when focus *enters* a card and not again if focus moves on within 300 ms (so fast scrolling stays calm); no resting glare. The ring never fades (§4) | lift shadow and glare: High and Balanced; sheen: all |
| **Easing** | Add `easeGlide` = cubic-bezier (0.25, 1, 0.5, 1) for positions, lifts and the gliding highlight; `easeSnap` = (0.23, 1, 0.32, 1) for pages and overlays; keep `OutCubic` where it already is until each screen is revisited. Pops (badges, the PIN-key pulse) use `OutBack` with overshoot 0.94 (about 3 %). One global `motionScale` (default 1.0, 0 under reduced motion) multiplies every duration; the study ran everything at 0.83 | all |
| **Gliding highlight** (T-205) | For the section nav, the Settings category list and other single-row selectors: one highlight that **glides** between rows in 280 ms with `easeGlide` instead of each row fading its own fill, and **stretches** with speed (length factor from |dx|/dt normalised by 2600 units/s, clamped 0..1, smoothed at 14 per s) so a fast scroll reads as a stroke. Grids of cards keep the per-card ring (§4) | all (stretch off under reduced motion) |
| **Liquid pill** (T-205) | The top-bar pills get an optional refraction at their edges (bend min(0.5 x height, 30)) and a slow-moving specular (three sine periods 9, 15, 23 s). A shader on one small texture per pill, **High tier only**, behind a measured frame-time budget on real hardware (B-002/B-003); every other tier shows the plain `glassStrong` pill | High only |
| **Loading placeholders** | Art placeholders get a shimmer: a gleam peaking at 8.5 % white moving at 760 units/s, drawn from one cached strip, none under reduced motion | all but Performance |
| **Bake, don't redraw** | Sheets and modals blur their backdrop once when they open (downscaled to 1/4, then 1/8 for the blur; result kept at half size, width capped at 1024) and draw one textured quad per frame. This is the same rule as §3.6 (one shared blurred copy, never a second fullscreen blur) | all with blur |

Not adopted: a per-frame blur, chromatic aberration (not in the study either), glass over a running app before B-003 is measured, resting glare, replacing the per-card ring by a gliding one on grids. The study's artwork-colour extraction (19 hue bins, vibrant / dark / light / muted swatches, a score favouring lightness 0.5 and saturation) is an Inbox item to compare with our own tint extraction, not part of this change.

### 3.7 Icons (decided ADR-013; built, T-157)

- **Set:** Material Symbols Rounded (Apache-2.0), a subset font in the Qt resources (`shell/fonts/`), family names `Theme.iconFamily` (outlined) and `Theme.iconFamilyFilled`, registered by `main.cpp` (and the test host) with `QFontDatabase::addApplicationFont`. The licence ships next to the fonts (`LICENSE-MaterialSymbols.txt`) and in the image (`/usr/share/licenses/ruyaos/`); the About pane's licence line names the icon font.
- **Drawing:** `Icon.qml` by name (`Icon { name: "settings" }`): a name → code point table inside the component, never ligatures and never a raw code point in a page; an unknown name draws nothing and warns once. The table is `Icon.codePoints`; `shell/fonts/icons.txt` lists the same pairs and feeds `scripts/subset-icons.sh`, and `scripts/lint-icons.ps1` (in `dev.ps1 shell` and CI) fails if they differ. Adding an icon = one line in `icons.txt`, the same pair in the table, then re-running the subset script in WSL (`docs/dev-setup.md`). As built: `Icon` takes `u`, `size` (default `Theme.iconM`), `color` (default `text`) and `filled`, and is `Accessible.ignored`.
- **Style:** weight 400, grade 0, optical size 40: two static cuts of the variable font, outlined (FILL 0) normally and filled (FILL 1) for the current or selected state (static cuts render the same on every Qt ≥ 6.8; no variable-axis API needed). Colour from the text tokens (`text`, `onPrimary`, `textDim`, the toast kind colours), never a category tint.
- **Sizes:** `iconM` 40 (pills, rows, toasts, OSD), `iconL` 64 (empty states). An icon in a pill or button is centred like its label would be.
- **Controller glyphs** are not icons: `ButtonGlyph.qml` draws the button's letter (A, B, X, Y, LB, RB, Start) in `typeMicro` on a `primaryFill` circle (`glyphSize` 40) with `onPrimary` text (hint bar, T-158).

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
| Art card | `ArtCard.qml` | built (T-113), reused by T-146; caption fade uses `artCaptionFade` (T-146); Home's Recent row reuses it; `pulse()` (the art shrinks to `pulseScale`; skipped under reduced motion) is run by the owner on Accept (T-155) | 16:9 key art edge to edge, `radiusM`, title on `artCaptionFade`, state pills in words (Running, Installing n %), card focus; no art: app icon on a tint from the id hash |
| App art | `AppArt.qml` | built (T-111) | The art fill of Store cards and the app detail page, and of Art card (T-113 wraps it, no second version): the record's picture cropped to fill, else a two-stop tint from the id hash (`Qt.hsla`, light 0.42 → dark 0.18) with the name's initial `typeHero` Light (`monogram: false` for the full-screen Home hero, which shows the tint alone); `radiusM` |
| Progress bar | inline in `AppDetailPage.qml` (T-111) | built | Pill track `glass` + `glassBorder`, height `spaceS`; fill `text` (white, as the volume OSD bar), width animates over `focusMs`; percentage in words beside it. Extract to `ProgressBar.qml` when a second screen needs one (updates, launch). A second use, T-196: `StoragePane.qml` draws the same pill track inline as a usage bar inside a settings row (between the label and the value, 260 px wide; fill `text`, `warningText` below 10 % free); the extraction is still open (Inbox) |
| Cover card | `CoverCard.qml` | proposed | 2:3 cover for the Library grid; falls back to the 16:9 art cropped centre |
| Hero block | `HeroBlock.qml` | built (T-146) | Eyebrow `typeCaption` caps, title `typeHero` Bold, meta `typeBody`, Play (primary) + Details (secondary); follows the focused card, art cross-fades over `tintMs` |
| Buttons | `PrimaryButton.qml`, `SecondaryButton.qml` | built (T-146) | Pill `rowHeight`; primary `primaryFill`/`onPrimary`, focused = dark gap + white ring; secondary = glass, row focus |
| Section nav | `SectionNav.qml` (glass: `GlassPill.qml`) | built (T-146) | Glass pill of section pills; current = `primaryFill`, focus = ring (outside the current pill, `focusRingOffset`); LB/RB switch sections; one instance in the shell's top layer, shown on Home and the section pages (T-168); the Settings pill is an `Icon` (`settings`), filled while Settings is the current section |
| Glass pill | `GlassPill.qml` | built (T-146) | Pill of `glassStrong` over its own quarter-resolution blur of L0 (§3.6), `glassBorder` hairline; `glassOpaque` when `blurMax` is 0. Section nav and status cluster |
| Quick menu | `QuickMenu.qml` | planned (T-147) | Left panel 640 px over the live app on `glassStrong` (opaque until B-003): app header, Resume (focused first), Home, Close game, Switch to, volume, profile, Power; replaces the centred Guide card |
| Launch splash | `LaunchSplash.qml` | planned (T-147) | Blurred hero art, title, spinner until the app's first frame; "Still starting" + Close after 20 s |
| Profile card | `ProfileCard.qml` | built | Avatar circle in the profile colour, initial `typeHero`, name `text`, DemiBold when focused and Regular otherwise, PIN badge |
| Setting rows | `controls/SettingControl.qml` + `SettingRow`, `ToggleRow`, `ChoiceRow`, `SliderRow` | built | Pill `rowHeight`, label left `typeBody`, value right; optional swatch dot; row focus |
| Category item | `SettingsPage.qml` | built | Pill (list scrolls in whole rows when it doesn't fit, T-175), `text`, `selectedFill` when chosen, row focus |
| Settings pane | `SettingsPane.qml` | built | Rows in a column that scrolls with focus in whole rows: the top edge is always the top of a row and the clip ends at the bottom of the last row that fits, so no row is drawn cut or under the header (T-170); `hints` (default `A Select`, `B Back`) is what the hint bar shows while the pane has focus, About sets `B Back` only (T-175); **scroll cue (T-185):** focus scrolls with look-ahead, so the row above and the row below the focused one are whole in view when there are such rows (the focused row touches the pane edge only as the first or last row). While rows exist beyond the first / last visible row, that peek row is drawn at `peekOpacity` (`SettingsPane.peekAbove` / `peekBelow`, never the focused row; nothing is dimmed when everything fits), so the backdrop shows through whatever its tint. No overlay, no icon. A row eases its opacity with `focusMs` (`SettingControl`; `0` under reduced motion: it just changes). Built into every pane; a pane author does nothing |
| Dialog buttons | `PowerConfirm.qml` | built | Pills `buttonHeight`; the safe choice has focus first; only the destructive confirm uses `dangerFill` |
| Heat mark | inline in `SystemPane.qml` (health rows) and `SettingsPage.qml` (category) (T-200) | built | A round mark `spaceM` across in `warningText` (warm) or `errorText` (hot, critical), only while the level is not normal; the word ("Warm", "Hot", "Critical") sits next to it in the same colour, so colour is never the only signal. Normal shows nothing. `ThermalText.qml` has the words and colours |
| Heat notice | `ThermalNotice.qml` (T-200) | built | Modal card like Dialog buttons, title `typeTitle` in `errorText`, one "OK" pill (focused first) that only hides it; a seconds countdown in the text; accepts every key |
| PIN pad | `PinPad.qml` | built | 3 × 4 grid of `radiusS` keys, digit dots, message in `errorText` below; the grid stays left to right in RTL |
| On-screen keyboard | `TextEntry.qml` | built | Key fills rest 8 % / focused / latched (`entryKeyActiveFill`) |
| Toast | `ToastLayer.qml` | built | `toastBackground` card `radiusM` (20 today), status bar in the status colour + title word + one line; a sticky one (no timer, `Notifications.showSticky`, T-159) for a state that lasts, such as the pending automatic restart |
| Volume OSD | `VolumeOsd.qml` | built (icon: T-157) | Bottom centre, pill, `volume_up` / `volume_off` icon + bar + number; muted: `volume_off` and "Muted" in words in `toastWarning` |
| Guide overlay | `Shell.qml` | built | `scrimOverlay` + `panel` card `radiusL`, title `typeTitle`, actions as rows |
| Backdrop | `Backdrop.qml` | built | Tint from focus, three drifting blobs, `tintMs` cross-fade |
| Badge | `Badge.qml` | built (T-143) | `typeMicro` DemiBold caps, pill (`text`, `kind` neutral/success/info/warning); neutral = `background` fill, `glassBorder` outline, `textDim`; the others `badgeFill()` (kind colour at `badgeFillAlpha` 18 %) and text in the kind colour; used for PIN and mock services; source badges Official (success colour), Community (info), Dev (warning) on a 18 % fill of their colour |
| Hint bar | `HintBar.qml` | built (T-158) | Bottom-left in the safe area, one `ButtonGlyph` + verb (`typeCaption`, `text`) per action the focused screen accepts, `spaceS` between glyph and verb, `spaceL` between hints, no background over art (the bottom fade carries it); at most four hints; a hint may carry two buttons with one verb (`{ buttons: ["LB", "RB"], text }`, drawn as two `ButtonGlyph`s: Home's "LB RB Sections"); the mock-services badge is not on the bar (bottom right, left of the version tag); letters until pad-type glyphs (B-006) |
| Icon | `Icon.qml` | built (T-157) | A Material Symbols glyph by name, `iconM`/`iconL`, colour from text tokens, `filled` for the current state (§3.7) |
| Button glyph | `ButtonGlyph.qml` | built (T-158) | Controller button letter on a `primaryFill` circle, `glyphSize`, `typeMicro`, `onPrimary` (§3.7) |

### 5.1 Full-screen apps (look; behaviour in `02-shell.md` §1.5)

Launch: Accept on Play → art takes the screen (chrome fades, hero art scales 1.0 → 1.04 and blurs in, `launchMs`) → splash until the first frame → cross-fade to the app. Guide over an app opens the quick menu (slides in from the left, `overlayMs`; the app keeps running behind it). Home from the quick menu shrinks the app into its Running card (`pageMs`). Reduced motion turns each step into a cut; the Performance tier skips every blur.

## 6. Writing

- Sentence case everywhere ("Reduced motion", not "Reduced Motion"); the brand "RuyaOS" and language names are never translated.
- Buttons and actions are verbs ("Restart", "Add profile"); a confirm repeats the verb of the question ("Restart now?" → Restart / Cancel).
- Errors say what happened and what the user can do, in at most two short sentences ("Wrong PIN. 2 tries left."). No "please", no codes, no blame.
- Row labels stay under about 28 characters in English so the Turkish fits.

## 7. Accessibility

- Text contrast ≥ 4.5:1 against the surface it actually sits on, worst case (backdrop at its brightest tint); the focus ring ≥ 3:1 against both the item and its surroundings (white on any tint passes).
- High-contrast theme, text scale and focus-ring size (`02-shell.md` §7) will be token sets over the same names, so components need no change: never compute a colour in a component (`Qt.lighter` of a token for a gradient is the one allowed exception, as in `Backdrop.qml`).
- Every interactive item has `Accessible.name`; decoration has none. Done in T-144 and checked by `tst_accessibility.qml`, which walks the focus chain of the picker, the PIN pad, Home, every Settings pane, the Guide overlay, Games (grid, filter, empty page), Store (toolbar, rows, results), the Store keyboard, an app's detail page, the power confirmation buttons, the first-run wizard including its name-and-PIN step (T-176, T-186) and the Settings -> Profiles add and manage flows (T-186), and asserts a non-empty `Accessible.name` on each focused item. The Confirm button of `PowerConfirm` is named after the action while its visible label stays "Confirm": "Suspend now", "Restart now", "Power off now", and for `custom` the caller's `customConfirmName` ("Delete Ada", "Roll back now"); Cancel stays "Cancel". The wizard's key sink is named after the step ("Welcome to RuyaOS", "Network", "You're all set"); the other steps focus their own rows. Lists that hold focus (a ListView or GridView whose delegates are not items of their own) name themselves after the current delegate; setting rows read `label, value` (`SettingControl.accessibleValue`), toggles are `CheckBox` with `checked`, choice rows `ComboBox`, sliders `Slider`; buttons, tiles, profile cards ("Name, PIN protected" when a PIN is set), category items, PIN keys and keyboard keys are `Button`/`ListItem` with their visible text.

## 8. Changing the design system

- **Builders use what exists.** Pick the closest token and component. If the task truly needs a new value or component, use the closest existing one, add an Inbox line `(T-nnn) design: needs <token/component> because <reason>`, and say so in the Outcome. Never add a one-off literal (`// token-ok` is for non-visual numbers only).
- **The lead (or a task that says so) changes the system.** A new or changed token or component is one commit that updates `Theme.qml`, this file (table and status), the screenshots that changed, and names the canvas board to update. Mark the commit `design:` in its summary (area `shell` or `docs`).
- **Owner-level:** a new typeface or icon set (licence), a new brand colour, or anything that changes the five principles; ask, as a *Proposed* ADR.
- **Screenshot review** (every UI task, `dev.ps1 shots`): focus visible on every screen; nothing outside the safe area; type only from §3.2; `textDim` only on opaque surfaces; Turkish fits without clipping; Performance tier (`--effects performance`) keeps the layout.
