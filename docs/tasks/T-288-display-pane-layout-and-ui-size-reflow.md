# T-288 — Display pane order, layout at large UI size, a Screen row, and the late-filled Column reflow

Status: todo · Phase: 2 · Depends: T-282 · Area: shell (DisplayPane, SettingsPage/Pane, Home hero, SystemInfo, tests) · Size: M · Owner: builder

## Goal
At UI size 200 % Settings and Home are still usable (no crowded nav, panes wide enough), the Display pane shows its main rows without scrolling at 720p, several outputs are listed sensibly, and panes filled after they open lay out correctly without per-pane workarounds.

## Read first
- `docs/specs/02-shell.md` (Settings layout), `04-design-system.md` §3 (u scale), §5, T-282 item 10 (percent format)
- T-198 Outcome (UI size 100-200 %, `Shell.u`); `shell/qml/DisplayPane.qml`, `SettingsPage.qml`, `SettingsPane.qml` (`reflow()`), `HeroBlock.qml`, `SystemInfoRows.qml`, `SystemInfoPage.qml`
- T-226 Outcome (the layout bug); `shell/tests/tst_display.qml`, `tst_settings.qml`, `tst_system_info.qml`
- STATUS-parked.md "Inbox triage 2026-11-07", bullets T-288

## Scope
1. **Order:** Resolution, Refresh rate and UI size are the first rows of the Display pane (today below the fold at 720p). Re-base the tests that scroll to them.
2. **Large UI size:** at UI size >= 125 % the Home hero eyebrow no longer crowds the nav, and at 200 % the Settings content pane is at least 480 design px wide (today ~280). Reflow (single-pane Settings below the width, or a collapsed nav) or cap the largest UI size offered on small outputs: pick one, record it in 02.
3. **Percent format:** one rule for "5%" / "150 %" as T-282 item 10 decided, applied to UI size, volume, battery, dim.
4. **Screen row:** with more than one connected output the Display pane starts with a "Screen" row to choose which output the Resolution and Refresh rows act on (default: the one in use); System information shows the mode in use ("1920x1080, 60 Hz") next to the display name.
5. **Late-filled Column:** find why a `Repeater` inside a `Column` filled after the pane opened is not laid out until the next repaint in a real window (T-226; `SettingsPane.reflow()` is the workaround). Fix at the source or make `SettingsPane` re-lay-out whenever a child `Repeater` count changes, and remove the per-pane `reflow()` calls.

## Out of scope
- The hot-plug signal and the real-mode check (T-287), HDR/VRR rows (T-218, T-222), per-output layouts, a Settings redesign.

## Acceptance criteria
- [ ] `tst_display.qml::test_main_rows_visible_at_720p`: Resolution, Refresh and UI size are inside the pane viewport without scrolling at 1280x720.
- [ ] `tst_settings.qml::test_pane_width_at_200_percent` (content width >= 480 design px) and `tst_home.qml::test_hero_eyebrow_clear_of_nav_at_125_and_200` (rectangles do not intersect).
- [ ] `tst_display.qml::test_screen_row_only_with_several_outputs` and `tst_system_info.qml::test_mode_in_use_row`.
- [ ] `tst_i18n.qml`: the percent strings follow the rule in en and tr.
- [ ] A `shots` case for a pane filled after open (System information) has every row positioned without `reflow()` (screenshot reviewed); the per-pane `reflow()` calls are gone (grep in the Outcome).
- [ ] Screenshots at 200 % of Home, Settings and Display (en) reviewed against 04 §8.
- [ ] UX: from every new state Back leaves; focus lands sensibly; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `02-shell.md` (Settings at large UI size), 04 (percent rule), `shell/PATTERNS.md` (the reflow note, if any remains).

## Hints
- Run after T-287 (same files: `DisplayPane.qml`, `tst_display.qml`). `shots` is the only place the Column bug shows (offscreen is the software renderer).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
