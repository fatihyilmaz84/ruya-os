# T-103 — Settings screen and reusable controller controls

Status: todo · Phase: 1 · Depends: T-101, T-102 · Area: shell · Size: M

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
- [ ] Navigating categories with Up/Down updates the right pane; Right enters, Left exits (test `tst_settings.qml::test_two_pane_navigation`).
- [ ] ToggleRow/ChoiceRow/SliderRow change their value only with the expected keys, clamp at the bounds, and play the navigate sound path (test `test_controls`; instantiate the controls standalone).
- [ ] On a ChoiceRow, Left/Right cycles the value and focus stays in the pane (test `test_choice_row_keeps_focus`).
- [ ] Changing effects quality in Settings changes `DeviceSettings.effectsQuality` and the shelf blur immediately (test `test_display_settings_apply_live`).
- [ ] The About pane shows the version string passed to Shell (test `test_about_shows_version`).
- [ ] Screenshots `7-settings-display.png` and `8-settings-about.png`: both panes readable, focus ring visible, nothing clipped at 1280×720.

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
_Filled in by the implementer._
