# T-285 — Hint bar and focus follow-ups: Accept hints, keyboard hints, Tab, missing tests

Status: done · Phase: 2 · Depends: — · Area: shell (Shell.hintList, Setup, pickers, tests) · Size: S · Owner: builder

## Goal
The hint bar tells the truth in every state review rounds found wrong or silent, and three tests that could not fail now can.

## Read first
- `docs/specs/02-shell.md` §4.2 (keys) and the hint-bar rules; `docs/specs/04-design-system.md` §5 (HintBar)
- `shell/qml/Shell.qml` (`hintList`, ~line 1080), `shell/qml/Setup.qml` (`hints`, ~line 70), `shell/qml/HintBar.qml`, `TextEntry.qml`
- `shell/tests/tst_hints.qml`, `tst_setup.qml`, `tst_bluetooth.qml`, `tst_accessibility.qml`; STATUS-parked.md "Inbox triage 2026-11-07", bullets T-285

## Scope
1. **Setup.hints:** drop the `nameEntry.shown` half of its `B Cancel` branch (the keyboard's own hint wins in `Shell.hintList`, so it is dead code).
2. **Keyboard hint bar** (on-screen keyboard open): add `A Type` and `Start Done` where the keyboard has those keys.
3. **Accept hints:** modals and pickers that take Accept show "A Select" (T-208: the wallpaper and theme pickers, the zone chooser; walk every `ModalLayer` user; the Delete text of the wallpaper picker is T-284's); `ChoiceRow` panes (Power saving) show `Left/Right Change`; the Activity pages show the D-pad glyph hint (T-247).
4. **Tab:** on non-pane row lists (Power, Setup, filters, App detail) Tab is unmapped, as T-282 item 8 recommends: add the sentence to 02 §4.2 (if T-282 decided Tab = Down instead, implement that and test it).
5. **Tests that could not fail:** the Bluetooth-discovery focus test passes without its fix (use a pane height where the next row is out of view); add `ModePicker` and `ModeConfirm` to `tst_accessibility.qml` (name, role, initial focus).

## Out of scope
- New keys, a context menu (B-006), the Delete hint inside the wallpaper picker (T-284), remapping.

## Acceptance criteria
- [ ] `tst_hints.qml` cases: keyboard open shows `A Type` and `Start Done`; each modal of Scope 3 shows "A Select"; the Power saving pane shows `Left/Right Change`; Activity shows the D-pad glyph hint.
- [ ] `tst_setup.qml`: the cancel hint of the name step comes from the keyboard, not `Setup.hints` (fails if the dead branch is put back and changes the text).
- [ ] `tst_bluetooth.qml::test_discovery_focus_scrolls`: red when the focus-follow fix is reverted (revert check noted in the Outcome).
- [ ] `tst_accessibility.qml` has `ModePicker` and `ModeConfirm` rows.
- [ ] 02 §4.2 states what Tab does on non-pane lists.
- [ ] UX: from every new state Back leaves; focus lands sensibly; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `02-shell.md` §4.2; `shell/PATTERNS.md` if hints change how a modal declares them.

## Hints
- Copy how `PowerConfirm` declares its own hints and how `Shell.hintList` picks the topmost layer's.
- Overlaps T-284 (WallpaperPicker) only on that picker's Delete text; leave it to T-284.

## Outcome
Verified: host (`dev.ps1 test` ALL GREEN: 1001 QML + 77 skips, Rust ok; `shots` ALL GREEN).

UX notes: states reached: the on-screen keyboard (A Type, B Delete/Cancel, Start Done; after a physical key A goes), PowerConfirm and the uninstall confirmation (A Select, B Cancel), Power saving (Left/Right Change, B Back), Activity chart row (Left/Right Browse, B Back; other rows unchanged). Back leaves each as before (nothing about keys changed). Focus is untouched. The new glyph is a pill reading "Left/Right" (the bar has no D-pad glyph), checked in `92-power-saving-settings-en.png` and `90-activity-week-en.png`: readable, same height as the others. I doubted that word as a glyph; a real D-pad glyph is an inbox line.

Built:
- `Setup.hints`: the `nameEntry.shown` half dropped. `TextEntry.entryHints` adds `A Type` and `Start Done` (no A after typing on a physical keyboard, where Enter finishes).
- `modalHints` (A Select, B Cancel) on `PowerConfirm` and the uninstall confirmation. The wallpaper and mode pickers and the zone chooser already had them; ModeConfirm already followed its button. PinPad keeps `B Cancel` only (its keys are digits, not a choice), a call I made.
- Power saving: `Left/Right Change`. Activity and the game page: `Left/Right Browse` while the chart has focus (the game page's strip, `ActivityGamePage.hints` now follows its body).
- 02 section 4.2: Tab is unmapped on non-pane row lists (T-282 recommendation, no decision needed). Hint-bar rules updated. `ruyashell_*.ts` refreshed (Gez, Degistir, Yaz).
- Tests: `tst_hints` (keyboard, the three modals, Power saving, Activity), `tst_setup` (the keyboard, not `Setup.hints`, says Cancel), `tst_textentry` strings, `tst_accessibility::test_mode_picker_and_mode_confirm_rows` (list name/role, initial focus, ModeConfirm buttons name/role, focus on Revert).

Revert checks: restoring `nameEntry.shown ||` in `Setup.hints` fails `tst_setup::test_hints_follow_the_step`; setting Power saving's hint back to `A Select` fails `tst_hints::test_choice_row_pane_says_left_right`.

Round 2: `tst_store_ui::test_uninstall_confirm` asserts `A Select|B Cancel` (revert: the uninstall confirmation's `modalHints` without A fails it), `tst_hints::test_mode_picker_says_select` (revert: ModePicker's `modalHints` without A), `tst_activity::test_most_played_in_order_and_the_game_page` asserts the strip's `Left/Right Browse` and `B Back` on a fact row (revert: the strip hint set to `false ?`). A TimeZone clock test failed once in a full run and passed alone and in the next full run (timing, unrelated); a `hintList` binding loop warning in tst_timezone is on main too.

Unmet: the Bluetooth discovery test. The task names `tst_bluetooth.qml::test_discovery_focus_scrolls`, which does not exist; the test is `tst_settings.qml::test_bluetooth_discovery_keeps_the_focused_row_and_the_row_below_whole`. I could not make it go red: in the mock the row below "Add a device" (Pair a new controller) exists before and after the scan and the new devices land further down, after existing device rows, so reverting `settleFocus()` in `relayout()` changes nothing there at any pane height (tried 6 and 3 rows; reverting it fails three other tests, so that fix is covered). The test is left as is. A red case needs a mock where the scan inserts rows right under the focused row.
