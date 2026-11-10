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
_Filled in by the implementer._
