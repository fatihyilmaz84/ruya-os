# T-144 — Design review pass: text contrast over the backdrop, accessible names

Status: done · Phase: 2 · Depends: T-143 · Area: shell · Size: M

## Goal
No text in the shell falls below 4.5:1 against what it actually sits on, and every focusable item has an accessible name, so the Orca spike (`02-shell.md` §7) starts from a clean base.

## Read first
- `docs/specs/04-design-system.md` §3.1 (the `textDim` rule), §7
- `shell/qml/ProfileCard.qml`, `shell/qml/ProfilePicker.qml`, `shell/qml/Shell.qml` (home header and shelf)

## Scope
1. Find every `Theme.textDim` that sits on glass or directly on the backdrop (not on `background`, `panel`, `glassOpaque` or a scrim) and switch it to `Theme.text` (for de-emphasis use weight or size, not a dimmer colour). Known case: unfocused profile names on the picker.
2. Apply the type weights of `04` §3.2 at every `Theme.type*` call site (`font.weight: Theme.weightDemiBold` for Title, Headline and Micro; Light for Hero and Display; Regular is the default). T-142 added the tokens but no call site uses them (lead review, 2026-10-28).
3. Set `Accessible.role` and `Accessible.name` on every focusable item: tiles, profile cards, setting rows (label plus value), category items, dialog buttons, PIN keys, keyboard keys, overlay actions.

## Out of scope
- Screen-reader output itself (the Orca spike), high-contrast theme, text scale.

## Acceptance criteria
- [ ] `tst_accessibility.qml`: walks the focus chain of home, the picker, Settings (each pane) and the Guide overlay with the controller keys and asserts a non-empty `Accessible.name` on every focused item.
- [ ] Screenshots: the picker and home show no `textDim` text over the backdrop (reviewed; named in the Outcome).
- [ ] Weights: `lint-tokens.ps1` fails on a `Text` block that uses `Theme.typeTitle`, `typeHeadline`, `typeMicro`, `typeHero` or `typeDisplay` without a `font.weight` (self-check fixture in `dev.ps1`, like the font-size rule); the migrated tree passes; title and toast screenshots reviewed.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `04-design-system.md` §7: drop "Not done anywhere yet".

## Hints
- In QML tests, `item.Accessible.name` is readable as an attached property.

## Outcome
Verified: host (`dev.ps1 test` ALL GREEN, `dev.ps1 shots` ALL GREEN; screen-reader output itself is out of scope).

**Contrast.** Every `Theme.textDim` text that sat on glass or the backdrop is now `Theme.text`: unfocused profile names (ProfileCard, which dims by weight now: DemiBold focused, Regular otherwise), the picker's waiting line, hint-bar verbs, the version tag, Settings category items and rows' values (SettingRow, SystemPane heading), Games/Store empty and name lines, AppDetailPage lines, Setup copy, ComingSoon. Kept `textDim` where the surface is opaque: Badge neutral (`background` fill), the PowerConfirm detail and the System panel version and FPS lines (`panel`), and two ring colours (`border.color`, not text). Reviewed `output\shell-shotseview-picker.png`, `3-home.png`, `5c-settings-nav-focus.png`: no dim text over the backdrop.

**Weights.** Every `Theme.typeHero/Display/Title/Headline/Micro` site has a `font.weight` (Light for Hero and Display, DemiBold for Title, Headline and Micro; the hero game title keeps Bold; key caps are DemiBold for single characters, Regular for the Body-size ones); `Font.Light` literals became `Theme.weightLight`. The Settings "coming soon" heading was Light at Title size and is DemiBold now. `scripts\lint-tokens.ps1` fails on a block that sizes text with one of those steps and has no `font.weight` (a `// token-ok:` line opts out); `dev.ps1` self-checks it with a fixture that must be rejected and a fixed one that must pass. Reviewed `14-toast-and-osd.png` and the home and picker shots.

**Accessible names.** `SettingControl` has `accessibleValue` and names itself `label, value` (Button; ToggleRow CheckBox with `checked`; ChoiceRow ComboBox; SliderRow Slider). Added to ArtCard-less items: ProfileCard, Settings category delegates, Guide overlay actions (MenuItem), PIN keys, TextEntry keys (and the entry itself, which keeps focus: `title, focused key`), PowerConfirm buttons, Store AppCard, Setup's key sink, the ComingSoon placeholder. A ListView/GridView that holds focus (profileList, recentRow, categoryList, systemActions, gamesGrid, storeCards_*, storeResults, pinKeys) is `Accessible.List` named after its current item. `tst_accessibility.qml` walks the picker and PIN pad, Home (hero, shelf, nav), all eight Settings panes (Accessibility has no pane yet) and the Guide overlay with controller keys, asserting a name on every focused item. Revert test: removing `Accessible.name` from `SettingControl` made `test_settings_every_pane` fail at "pane 0".

Five new strings (Keypad, Profiles in the picker, Setup, Recent, Search results) are in the en and tr `.ts`. `TextEntry` guards `focusedKey` (it is undefined for a moment when the layout changes).

Not covered by the walk: the profile add/manage flows and wizard steps beyond the key sink (their rows are SettingControls, so named, but not walked).

Files: shell/qml (controls/*, AppDetailPage, ComingSoon, GamesPage, HintBar, PinPad, PowerConfirm, ProfileCard, ProfilePicker, SettingsPage, Setup, Shell, StorePage, SystemPane, TextEntry, ToastLayer, AppArt, Page), shell/tests/tst_accessibility.qml, shell/i18n/*.ts, scripts/lint-tokens.ps1, scripts/dev.ps1, docs/specs/04-design-system.md.
