# T-460 — Closed pages are never destroyed in a real GPU window since T-448 (4 `shots` tests red on main)

Status: in-progress · Phase: 2 · Depends: — · Area: shell (Shell.qml page slots, QuickMenu.qml) · Size: S · Owner: builder · Complexity: complex · Developer surface: none

## Goal
A closed page is destroyed in a real GPU window as it is offscreen, so `dev.ps1 shots` is green on main again and the console does not keep hidden pages alive.

## Found (lead-10, 2026-11-10, bisect)
- `shots` on main fails `Display`, `StoreUi`, `SystemInfo` and `Wallpaper::test_zz_screenshots` (3 of 4 runs); `test` (offscreen) is green. First bad commit: `fccf558` "Merge T-448: the Quick Hub"; `b217591` (T-435) and `abfdce4` (T-451) pass 12 of 12.
- Symptom: after Escape, Escape, `wait(600)`, the popped page slot is still in `Shell.qml` `closingSlots` (hidden), so `find("categoryList")` / `find("page_systemInfo")` return the old page (`tst_display.qml:101` second `openDisplayPane` at :748; `tst_system_info.qml:433/502/512`).
- Reaping: `pageSlot.reapIfDone()` -> `reapPending` -> `win.update()` -> `onFrameSwapped` -> `reap()`, with `topSettled()` and `onSettledChanged -> reapClosed`. In a GPU window with `QSG_RENDER_LOOP=basic` one of these stalls (no swap after `update()`, or `settled` stays false). T-448's Shell.qml diff is small (quickMenuRecent, bottomReserve, hints, onLaunchRequested); QuickMenu.qml/QuickTile.qml are new in the same window.

## Scope
1. Find which step stalls (log `reapIfDone`, `onFrameSwapped`, `settled`) in a `shots` run, and why T-448 set it off.
2. Fix the cause. A timer fallback alone hides the bug: only as a second line of defence, with the cause fixed.
3. A test that fails without the fix in the mode where it shows (a `shots`-mode function, or an offscreen test if the cause can be reproduced there).

## Acceptance criteria
- [ ] The cause named with evidence in the Outcome
- [ ] `dev.ps1 shots` ALL GREEN on the branch, three runs in a row on an undisturbed desktop
- [ ] A test red without the fix (test: named in the Outcome)
- [ ] `dev.ps1 test` ALL GREEN
- [ ] hw (lead run): on the Dell, open and close Settings panes ten times; the shell's QML item count (or memory) does not grow

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `02` §1.1 (page model) if the reaping rule changes; `shell/CLAUDE.md` if a test rule follows.

## Hints
- Planned by lead-10. Run one `shots` function alone: `tst_ruyashell.exe -o log,txt "Case::test_zz_name"` with `QSG_RENDER_LOOP=basic` and `RUYA_SHOTS_DIR` set, no `QT_QPA_PLATFORM` (LEAD-NOTES host facts). Other builders' test windows disturb `shots`: check `tasklist | findstr tst_ruyashell` first.

## Outcome
Verified: host (hw pending: Dell open/close Settings ten times, lead run)

**Cause (with evidence).** The reap waits for `frameSwapped` after `win.update()`, and the `shots` test window presented **no frame at all**. Logged in a `shots` run of `SystemInfo::test_zz_screenshots` (temporary `console.log`s, removed): `reapIfDone` reached `topSettled true`, opacity 0, `update requested`, window `visible`, `Windowed`, `active`, and C++ `isExposed() == true`; yet over the whole test the window emitted **0 `frameSwapped` and 0 `afterAnimating`**, and `beforeSynchronizing`/`afterRendering` fired exactly once per `grabImage` (3 and 3): only the grabs rendered. `Activity::test_zz_screenshots` showed the same (0 frames, 12 grabs); it passes only because it never checks the reap. So `update()` never turns into a frame, the `Connections` never fires, the slot stays in `closingSlots` and `find()` returns the old page. Why no frames: the desktop's display was asleep (no input for 72 min, display timeout 300 s on AC, both `Win32_DesktopMonitor` entries `Availability 8` = off line); animations, timers and `grabImage` still run, but Windows delivers no update request. **T-448 is not the cause:** with the whole `shell/` tree checked out at T-448's first parent (`fccf558^1`) the same function failed the same way on the same desktop. The lead's bisect (old commits 12/12, main 3 of 4 red) was most likely confounded by the display going to sleep during the runs; I could not reproduce the display state of that bisect, so this part is inference.

**Fix (`Shell.qml` page slot).** The wait for one more frame exists to keep the teardown out of a glide that is on screen (T-349). The slot now listens to `frameSwapped` from the moment it starts closing (`framesWhileClosing`); `reapIfDone` waits for a frame only if the window showed one while the slot closed, else destroys it as soon as the page on top has settled. A presenting window draws frames throughout the fade (pageMs), so its behaviour is unchanged (`test_a_replaced_page_goes_after_the_glide` still asserts reap after the settled frame). No timer fallback: a window that stops presenting after the reap became pending reaps on its next presented frame (the `Connections` stays attached), which is self-healing. One behaviour change: a page popped before any frame was drawn (closed in the same instant it opened, nothing below it) now goes at once instead of after one frame.

**Test.** `tst_settings_lazy.qml::test_a_window_that_shows_no_frames_still_destroys_a_closed_page` (offscreen): opens the Store, hides the window (a hidden window draws no frames, standing in for the sleeping display), closes the page and asserts it is destroyed with 0 frames counted; `cleanup()` shows the window again if the test fails while it is hidden. Revert check: `revert-check.ps1 -File shell\qml\Shell.qml -Old 'if (!win || !framesWhileClosing) {' -New 'if (!win) {' -Test tst_settings_lazy` -> CAUGHT, only this test fails ("the closed page is destroyed").

**Checks.** `dev.ps1 test` ALL GREEN (1168 QML passed + 96 skips, 190 Rust). The four functions red on main (`Display`, `StoreUi`, `SystemInfo`, `Wallpaper::test_zz_screenshots`) each passed alone in a real window with the display still asleep. `shots`: nine full runs with the fix; the four functions red on main passed in all nine. Not three green in a row: series 1 green, green, then `Glass::test_zz_screenshots_card_glare_and_placeholder` red once (line 519, `tryVerify(rightArt.scale < 0.96)`: the pulse is under 0.96 for only a few tens of ms, the 50 ms poll can miss it; passed 3 of 3 alone); series 2 green, green, then `Wallpaper::test_zz_sheet_after_an_app` red after three TEST WINDOW LOST ACTIVATION warnings; series 3 (display awake by then: input 3 min before) red three times, each only `Wallpaper::test_zz_sheet_after_an_app` (max channel difference 13-16 > 12). That failure is not this change: a full `shots` run **without the fix** (Shell.qml at HEAD), display awake, failed the same function (difference 16) while the four reap functions passed there, which also confirms the cause (with frames presented, the old reap works). The function passes alone and with the other Wallpaper `test_zz_*` functions (2 of 2); it fails only in the full run. `lost-tests.sh`: none.

**Files.** `shell/qml/Shell.qml`, `shell/tests/tst_settings_lazy.qml`, `docs/specs/02-shell.md` §1.1 (the reaping rule), `shell/CLAUDE.md` (a `shots` window may present no frames).
