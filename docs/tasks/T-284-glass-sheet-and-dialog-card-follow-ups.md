# T-284 — Glass sheet follow-ups and one dialog card for the confirm dialogs

Status: todo · Phase: 2 · Depends: T-282 · Area: shell (GlassSheet, dialogs, wallpaper picker, tests) · Size: M · Owner: builder

## Goal
`GlassSheet` re-bakes when the wallpaper behind it changes, its shadow and fallback behave as 04 says (pinned by tests), and the confirm dialogs (power, display mode, thermal, uninstall, controller onboarding) share one dialog-card component in the style T-282 decided instead of repeating `Shell.u` literals.

## Read first
- `docs/specs/04-design-system.md` §3.5/§3.6 (glass, opaque fallback), §5 (GlassSheet, dialogs), §8; T-282's decision on item 7 (glass or flat dialogs)
- T-272 Outcome (`GlassSheet`, `WallpaperPicker`); `shell/qml/GlassSheet.qml`, `GlassPill.qml`, `PowerConfirm.qml`, `ModeConfirm.qml`, `ThermalNotice.qml`, `WallpaperPicker.qml`
- `shell/tests/tst_glass.qml`, `tst_wallpaper.qml`; STATUS-parked.md "Inbox triage 2026-11-07", bullets T-284

## Scope
1. **Re-bake:** while a `GlassSheet` is open and layer L0 changes (a wallpaper set after a USB copy, a theme change), it bakes again; `bakeCount` increases once, not per frame.
2. **Shadow vs opaque fallback:** the code and the 04 table disagree on whether the opaque fallback keeps its shadow. Pick what 04 says (change the code) or fix 04 if the code is right; pin it with a test per tier.
3. **Token for the shared blur literals** of `GlassPill` and `GlassSheet` (radius, downsample): one `Theme` token set, both use it.
4. **One dialog card** (`DialogCard.qml`, new, listed in `shell/CMakeLists.txt`, named in 04 §5): PowerConfirm, ModeConfirm, ThermalNotice, the uninstall dialog and ControllerOnboarding use it; the `120/96/1100` literals (the width and margins) live inside it, derived from `Shell.u`. Glass or flat as T-282 item 7 decided.
5. **Wallpaper picker:** the "Current" badge is blue on blue over the default tile (readable on every tile); its hint bar says what Delete does (hint text, not a new key); `tst_wallpaper` measures the ring against the glass sheet it sits on, not `Theme.panel`; a screenshot of a failed USB copy; the Daylight shot waits until all tile images are decoded (the third row showed undecoded images).
6. **Test race:** `tst_wallpaper::test_zz_screenshots` waits for `Qt.callLater` before reading `sheet.bakeCount`.

## Out of scope
- New dialog designs, text changes of the dialogs, the contrast rows for GlassSheet text (T-283), the contrast decision itself (T-282).

## Acceptance criteria
- [ ] `tst_glass.qml::test_rebake_on_l0_change`: changing the wallpaper while the sheet is open raises `bakeCount` by exactly 1 (fails with the re-bake removed).
- [ ] `tst_glass.qml::test_sheet_shadow_per_tier`: High, Balanced and Performance each match the 04 row (shadow present or absent).
- [ ] `tst_accessibility.qml` and `tst_shell.qml` still pass for all five dialogs; a test per dialog asserts it is a `DialogCard` and keeps its initial focus (Cancel/Back for destructive ones).
- [ ] Screenshots reviewed (`output/shell-shots/review/`): power dialog, mode confirm, thermal notice, wallpaper picker with the Current badge on the default tile and a failed copy, Daylight picker with every tile decoded.
- [ ] UX: from every new state Back leaves; focus lands sensibly after open/close/error; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- 04 §5 (DialogCard), §3.6 (fallback shadow row).

## Hints
- Overlaps T-283 (`GlassSheet.qml` text rows, `Theme.qml`) and T-281 (Theme tokens): do not run beside them.
- Copy `PowerConfirm.qml` as the reference dialog; keep focus handling and `ModalLayer` registration unchanged.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
