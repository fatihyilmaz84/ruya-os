# T-462 — `shots` you can run once: refuse a sleeping display, fix the two flaky screenshot tests

Status: todo · Phase: 2 · Depends: — · Area: scripts (dev.ps1), shell (tests) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
One `dev.ps1 shots` run is enough evidence (owner, 2026-11-10: the review process took too long; builders re-ran `shots` 3 to 9 times per task).

## Found (lead-10, T-460)
- With the display asleep (an idle desktop past its screen timeout) the window presents no frames: `frameSwapped` never fires, only `grabImage` renders. Anything waiting on a frame stalls and tests fail for no code reason (T-460).
- `Wallpaper::test_zz_sheet_after_an_app` fails only in full `shots` runs (max channel diff 13-16 > 12), passes alone and in the Wallpaper zz set, red on main with or without T-460: leftover state from an earlier function (T-430 item 5).
- `Glass::test_zz_screenshots_card_glare_and_placeholder:519`: `tryVerify(scale < 0.96)` polls every 50 ms and can miss the 70 ms pulse dip (about 1 in 9).

## Scope
1. `dev.ps1 shots` checks before running that the window presents frames (a probe window that must see `frameSwapped` within 2 s, or the display's power state): if not, it stops with "The display is asleep: wake it and run shots again." and a non-zero exit; never a red test list.
2. Find the leftover state behind `test_zz_sheet_after_an_app` and fix it (in the test's setup, or in the product if it is a product leak); do not raise the threshold.
3. The Glass pulse test asserts the dip by a property that holds (a counter or the animation's `running`), not by polling a 70 ms window.
4. `shell/CLAUDE.md` (Tests): one line on the sleeping-display check, merged into the T-460 line.

## Acceptance criteria
- [ ] A sleeping display (simulated: the probe sees no frames) stops `shots` with the message and exit 1 (test of the script's probe path, e.g. a `-NoFramesProbe` switch for the self-test)
- [ ] Three full `shots` runs in a row ALL GREEN on an awake, undisturbed desktop (logs in the Outcome)
- [ ] `test_zz_sheet_after_an_app` passes in full runs with the threshold unchanged; the cause named
- [ ] `dev.ps1 test` ALL GREEN

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/dev-setup.md` (shots), `shell/CLAUDE.md` (Tests).

## Hints
- Planned by lead-10 on 2026-11-10 with the owner's review-cost changes. Other builders' test windows disturb `shots`: check `tasklist | findstr tst_ruyashell` first; never kill them.

## Outcome
_Filled in by the implementer._
