# T-103 — Settings screen and reusable controller controls

Status: done · Phase: 1 · Depends: T-101, T-102 · Area: shell · Size: M

## Goal
The Settings page has a two-pane layout: categories on the left, the selected category's options on the right. A set of reusable controller-friendly controls covers every later settings page. "Display & motion" and "About" are fully working.

## Read first
- `docs/specs/02-shell.md` §1 (Settings row), §4.3, §7
- `docs/tasks/T-101-page-navigation.md` and `T-102-motion-and-quality.md` Outcomes (what actually exists)
- `shell/CLAUDE.md`

## Scope
1. `SettingsPage.qml` replaces the placeholder:
   - Left: a vertical category list. Categories: Profiles, Network, Bluetooth & controllers, Display & motion, Audio, Storage, Accessibility, System, About.
   - Categories without content yet show a "Coming soon" pane.
   - Up/Down moves within the list, Right/Accept enters the pane, Left/Back returns to the list.
   - Back on the list closes the page (T-101 behaviour).
2. Reusable controls in `qml/controls/` (add to CMake). Each is focusable, shows the focus ring and uses Theme tokens:
   - `SettingRow`: label plus value text. Accept emits `activated()`.
   - `ToggleRow`: label plus switch. Accept toggles it. Exposes `checked`.
   - `ChoiceRow`: label plus `‹ value ›`. Left/Right cycles through `options` (a list of `{value, label}`). Exposes `value`. Left/Right **must not** leave the pane while on a ChoiceRow.
   - `SliderRow`: label plus bar. Left/Right step by `stepSize` within `from`/`to`. Exposes `value`.
3. **Display & motion** pane, bound to `DeviceSettings` from T-102:
   - Effects quality (ChoiceRow: High/Balanced/Performance);
   - Reduced motion (ToggleRow);
   - Screen edge / overscan (SliderRow 0–10 %, step 1 %).
   Changes apply live.
4. **About** pane, read-only SettingRows: image version (the `version` property already passed to Shell), Qt version (expose from C++, or use `Qt.platform`/a context property), services mode (mock / D-Bus), licence line "GPL-3.0-or-later; see LICENSE.md".
5. The pane's first row takes focus when entering the pane. Leaving and re-entering a category restores the last focused row in that pane.

## Out of scope
- Content for Profiles (T-105), Audio (T-113), Power (T-107), Network/Bluetooth/Storage.
- Per-profile settings.

## Acceptance criteria
- [x] Navigating categories with Up/Down updates the right pane; Right enters, Left exits (test `tst_settings.qml::test_two_pane_navigation`).
- [x] ToggleRow/ChoiceRow/SliderRow change their value only with the expected keys, clamp at the bounds, and play the navigate sound path (test `test_controls`; instantiate the controls standalone).
- [x] On a ChoiceRow, Left/Right cycles the value and focus stays in the pane (test `test_choice_row_keeps_focus`).
- [x] Changing effects quality in Settings changes `DeviceSettings.effectsQuality` and the shelf blur immediately (test `test_display_settings_apply_live`).
- [x] The About pane shows the version string passed to Shell (test `test_about_shows_version`).
- [x] Screenshots `7-settings-display.png` and `8-settings-about.png`: both panes readable, focus ring visible, nothing clipped at 1280×720.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` §1 Settings: the list of categories and which ones exist.
- `shell/CLAUDE.md`: a short "Controls" section listing the reusable controls and their key behaviour.

## Hints
- Make the controls generic and token-driven; T-105, T-107 and T-113 reuse them.
- A pane is a `FocusScope` holding a vertical `ListView` or `Column` of rows. With `Column`, wire `KeyNavigation.up/down` or handle Up/Down yourself.

## Outcome
Built the Settings page, the reusable controls and the Display & motion and About panes.

- `qml/SettingsPage.qml`: category list (9 entries) plus panes. Panes are created once and shown/hidden, so each keeps its last focused row. Categories with no pane show "Coming soon" and Right/Accept does nothing there.
- `qml/SettingsPane.qml`: row container (Up/Down clamped, Left/Back emit `exitRequested`, Right swallowed). It is a `FocusScope`, so `forceActiveFocus()` on it re-enters at the remembered row.
- `qml/controls/`: `SettingControl` (base), `SettingRow`, `ToggleRow`, `ChoiceRow` (wraps), `SliderRow` (clamps, no signal at a bound).
- `qml/DisplayPane.qml`: effects quality, reduced motion, screen edge, bound to `DeviceSettings`. `qml/AboutPane.qml`: image version, Qt version, services mode, licence.
- `src/system/SystemInfo.{h,cpp}`: `QML_SINGLETON` exposing the runtime `qtVersion` (the task allowed C++ or a context property).
- `Page.qml` gained a `version` property that `Shell` binds for every page (so About reads the version passed to Shell). `Sfx.qml` gained cue counters.
- `tests/tst_settings.qml` (11 tests): `test_two_pane_navigation`, `test_pane_rows_navigate_and_clamp`, `test_pane_remembers_last_row`, `test_controls` (standalone controls), `test_choice_row_keeps_focus`, `test_display_settings_apply_live`, `test_rows_follow_external_changes`, `test_about_shows_version`, `test_guide_overlay_over_settings_pane`, `test_zz_screenshots` (`7-settings-display.png`, `8-settings-about.png`).
- Docs: `02-shell.md` §1 and new §1.2; `shell/CLAUDE.md` "Controls" section.

Verification: `dev.ps1 test` → ALL GREEN (49 passed, 5 screenshot tests skipped without `RUYA_SHOTS_DIR`); `dev.ps1 shots` → 54 passed, three runs in a row. Both screenshots reviewed: focus ring visible, text readable, nothing clipped at the 1280x720 test window; the About category sits just above the bottom safe-area edge.

Changes to existing tests (explained, nothing weakened):
- `tst_pages.qml`: Settings is no longer a placeholder, so the generic "page focuses its first element" check takes a per-page `focusName` (`categoryList` for Settings, `pagePlaceholder` for the rest). `test_back_restores_tile_focus` and the screenshot test used the Settings tile only because it was a placeholder; they now use the Media tile, and the shot is `5-page-placeholder.png` (was `5-page-settings.png`). Same assertions otherwise.

Deviations and notes:
- The "navigate sound path" is asserted through new `Sfx` cue counters (real playback can't be observed): ChoiceRow/SliderRow changes count a navigate cue, Accept on a toggle/row a select cue.
- Left on a ChoiceRow or SliderRow cycles/steps the value; it does not leave the pane (required by the task). The first Display row is a ChoiceRow, so Back is the way out there; Left leaves from ToggleRow/SettingRow rows (e.g. About).
- ChoiceRow wraps at the ends (the task says "cycles"); SliderRow clamps.
- One run of `tst_system_ui.qml::test_toast_queue` (the final `verify(tiles.activeFocus)`, T-108) failed right after a rebuild on a loaded machine and passed in 8 later runs; not reproduced, logged in the Inbox.
- The "SystemInfo is not defined" first-build failure happened again (see `shell/CLAUDE.md`).
