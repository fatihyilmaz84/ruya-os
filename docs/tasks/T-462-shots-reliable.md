# T-462 — `shots` you can run once: refuse a sleeping display, fix the two flaky screenshot tests

Status: in-progress · Phase: 2 · Depends: — · Area: scripts (dev.ps1), shell (tests) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

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
Verified: host

**Probe (scope 1).** `tst_main.cpp` (`applicationAvailable`): with `RUYA_PROBE_FRAMES=1` the runner shows one 200x200 window, waits up to 2 s for `frameSwapped`, and exits 0 (a frame came) or 3 (none) without running a test. `dev.ps1 shots` runs it (`Test-DisplayPresentsFrames`, basic render loop like the tests) after the lock check and before the tests; no frame stops it with red "The display is asleep: wake it and run shots again." and exit 1 (`FAILED: shots (display asleep)`). `-NoFramesProbe` (sets `RUYA_PROBE_NO_FRAMES=1`: the window is never shown, as on a sleeping display) exercises that path: `dev.ps1 shots -NoFramesProbe` ended with the message, exit 1, in 8 s. `dev.ps1 test` runs the same probe offscreen with no-frames set as a self-check ("display probe self-check (a window that presents no frames is reported)"), and by hand the probe on this awake desktop exits 0 (GPU window and offscreen).

**Cause of `test_zz_sheet_after_an_app` (scope 2).** Not leftover state from an earlier function: it is red alone too (5 of 8 runs here, one of the two data rows each time, max channel difference 13-14, "after" always [72,75,83] and "fresh" a different darker value per run). `GlassSheet` captures L0 once, when the picker opens. The test opens the Settings page and, within a few milliseconds of key presses, the picker; the page's blur of the wallpaper (`wallpaperBlur`, `pageMs` 300 ms) was still fading in (measured opacity 0.71-0.93 at the capture), so the capture held a half-blurred L0, by a different amount each run (and in the full run by whatever the machine was doing). The second opening happens on a settled page, so it is always the same. Fix in the test: `openPicker()` waits until `wallpaperBlur` has finished fading (`blurSettled()`) before it presses Accept. Threshold unchanged (12). After: 10 of 10 alone green. Revert check: the unchanged test (the file as on main) was red 5 of 8 in the same loop; `revert-check.ps1` cannot show it because the function skips offscreen (it needs `RUYA_SHOTS_DIR`), so the before/after loops of the function alone in a real window are the evidence.

**Glass pulse (scope 3).** `test_zz_screenshots_card_glare_and_placeholder`: no polling for the 70 ms dip. The art's `scaleChanged` is the sensor: the first value under 0.96 sets a counter (`pulseDips`) and pauses the pulse animation there, the test waits on the counter (`tryCompare`), verifies `paused`, takes the screenshot, then resumes and waits for scale 1. The picture is now always the dip (the ring is visibly smaller than in `glass-card-focus.png`). 12 of 12 runs of the function alone green.

**Docs (scope 4).** `shell/CLAUDE.md` (Tests): the T-460 line now ends with the probe sentence; `docs/dev-setup.md` (shots): the probe, the message, `-NoFramesProbe`.

**Checks.** `dev.ps1 test` ALL GREEN (1173 QML passed + 97 skips; Rust 921 tests over all crates). Three full `shots` runs in a row on an awake desktop, each `ALL GREEN (shots)`, 184 passed, 0 failed, about 305 s, 285 s, 285 s (each started after `tasklist` showed no other test window). The `Wallpaper::test_zz_sheet_after_an_app(reopened/app)` rows passed in all three. A `TEST WINDOW LOST ACTIVATION` warning appeared once in runs 1 and 2 (Activity, Bluetooth functions) without a failure. Screenshots read: `glass-card-pulse.png` and `glass-card-focus.png` (the changed ones). `lost-tests.sh`: none.

**Files.** `scripts/dev.ps1`, `shell/tests/tst_main.cpp`, `shell/tests/tst_glass.qml`, `shell/tests/tst_wallpaper.qml`, `shell/CLAUDE.md`, `docs/dev-setup.md`.

**Product note (not changed).** A user who opens the wallpaper picker within 300 ms of opening a page gets a sheet captured over the half-faded blur until it is closed. Inbox line in the HANDOFF.

