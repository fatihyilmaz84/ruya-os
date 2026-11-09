# T-285 — Hint bar and focus follow-ups: Accept hints, keyboard hints, Tab, missing tests

Status: in-progress · Phase: 2 · Depends: — · Area: shell (Shell.hintList, Setup, pickers, tests) · Size: S · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
