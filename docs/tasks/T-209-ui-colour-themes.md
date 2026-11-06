# T-209 — UI colour themes

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder

## Goal
The owner can choose a colour theme in Settings; the whole shell changes with it at runtime, and every theme keeps the accessibility rules (legible text, an unmistakable focus ring). Owner request, 2026-11-06. Today `Theme.qml` is one fixed dark "Dreamglass" palette (plus the high-contrast variant, if built under Accessibility).

## Read first
- `docs/specs/04-design-system.md` §3.1 colour tokens, §3.6 glass, §3.8 (new glass layers and shadows use tokens too), §4 focus (the ring is white and never colour alone), §7 accessibility (contrast, high-contrast theme), §8
- `shell/qml/Theme.qml` (every `readonly property color`), where hard-coded colours might still hide in QML (`grep` for `#` colours and `Qt.rgba` outside Theme), `DeviceSettings`, the category tints / `defaultTint`, `tst_theme*`, the token lint (`lint-tokens`)

## Scope
1. **Theme as data:** a `ThemeSet` (QML object or JSON resource) per theme holding every colour token that may change: `background`, `text`, `textDim`, glass fills and borders, `glassOpaque`, `panel`, `scrim`s, `defaultTint` and the blob colours, `primaryFill`/`onPrimary`, `dangerFill`, `warningText`, `errorText`. Not themeable: the focus ring colour (white, plus its width), sizes, type, motion, and the rule "focus is never colour alone". `Theme.qml` exposes the same property names as now, driven by the current set, so no screen changes.
2. **Built-in themes (start with five):** **Dreamglass** (today's, the default), **Midnight** (true black background for OLED, neutral glass), **Aurora** (deep teal and violet tints), **Ember** (warm dark red/orange tints), **Daylight** (a light theme: dark text on frosted white glass over a light backdrop; the biggest change: check every component, the ring needs a dark outline variant here and the rule becomes "ring colour with a 2 px opposite-lightness halo"). If Daylight cannot meet the rules in this task, ship four and open a follow-up, saying why.
3. **Runtime switching:** change in Settings applies at once with a cross-fade (`tintMs`, off under reduced motion), persists in `DeviceSettings.theme`, per device (per profile later: Inbox, same limits as T-208); the first-boot wizard and the picker use the stored device theme.
4. **Accessibility gate:** a test computes, for each theme, the contrast of `text` and `textDim` against the darkest and the lightest backdrop it can sit on (glass over the lightest hero/wallpaper) and requires >= 4.5:1 (>= 3:1 for large text and the ring against the glass and the backdrop); the high-contrast mode stays above every theme and keeps working with each of them.
5. **Settings UI:** a Theme row (preview chips showing background, glass and tint) in Display & motion or an Appearance pane shared with T-208's wallpaper rows; names and `qsTr`, Turkish.
6. **Lint:** extend `lint-tokens` so a hard-coded colour in QML outside `Theme`/theme sets fails (existing exceptions listed), keeping themes switchable everywhere.

## Out of scope
- User-editable themes or an accent picker (Inbox), per-profile themes, colour matching from a wallpaper or the running game (compare the study's extraction in `04` §3.8), time-of-day automatic switching, theming apps.

## Acceptance criteria
- [ ] Tests: every theme defines every themeable token; switching theme changes `Theme.*` and the screens that read it update in place with focus kept; the non-themeable tokens are identical in all themes; the contrast gate passes for every theme (fails for a deliberately bad fixture theme: the self-check); `DeviceSettings.theme` persists; reduced motion switches without a fade.
- [ ] Screenshots: Home, a Settings pane, the Guide overlay and a modal in each theme, plus the high-contrast mode over one theme; read against `04` §8 (legibility, ring visible).
- [ ] `lint-tokens` fails on a hard-coded colour fixture and passes on the tree.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN. Hardware (lead): the owner looks at each theme on the real screen.

## Docs to update
- `04` §3.1 (the theme list and the non-themeable tokens), §7, `02-shell.md` (Settings), the canvas boards note (Inbox: stale).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
