# T-429 - Test harness: say when the window lost activation; the status-clock test near midnight

Status: in-progress · Phase: 2 · Depends: — · Area: shell (tests, WindowGuard), scripts · Size: S · Owner: builder · Complexity: simple · Developer surface: none

## Goal
A red `shots` run caused by the desktop says so in its own words, and `tst_timezone` does not fail because of the time of day.

## Read first
- `docs/tasks/T-379-*.md` (the four `shots` reds that did not reproduce), the `WindowGuard` helper in `shell/tests`, `tst_timezone.qml` (status-clock test), `scripts/dev.ps1` (`shots`, the `ruya-qmltest.txt` log)

## Scope
1. `WindowGuard` checks activation also after each test (or on `Window.activeChanged`), and when the window lost activation mid-test and did not regain it, the test fails with `TEST WINDOW LOST ACTIVATION` instead of a random `activeFocus` line.
2. `dev.ps1 shots` keeps the `build-win` `ruya-qmltest.txt` log of a red run under `output/` (one file per run, the last 5 kept).
3. Find why `tst_timezone`'s status-clock test failed once near 23:00 (day rollover, a 12/24 h edge, a timezone offset crossing midnight) and fix the test or the code, with a test that pins the edge time (an injected clock, never the wall clock).

4. `tst_settings::test_a_hidden_focused_row_hands_the_focus_on` failed once in a full `test` on a loaded host (lead-9, 2026-11-10: line 448, `tryCompare(r(4), "activeFocus", true)` after `r(4).visible = true`; 3 of 3 green alone): find the race (the hand-on runs on a timer or a `callLater`?) and fix the cause, not the timeout.

5. `tst_timezone::test_the_status_clock_follows_a_zone_change_at_once` (line 154, a 2 s `tryVerify`) flaked once in a full run right after `shots` (T-147 review, 2026-11-10); probably the same cause as item 3.

## Out of scope
- Rewriting the screenshot harness.

## Acceptance criteria
- [ ] A fixture test that deactivates the window mid-test shows the new message (Outcome names it; the fixture is not part of the normal run if it must fail).
- [ ] The clock test pinned at 23:00-00:00 passes, and is red against the old code if the cause was the code (Outcome says which).
- [ ] `dev.ps1 test` and `shots` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/dev-setup.md` if the kept log location is new.

## Hints
- From the STATUS Inbox (T-379 and T-387 reviews, lead-8), triaged by lead-9 on 2026-11-10. Never edit a test to suit the desktop (root `CLAUDE.md`).

## Outcome
Verified: host (`dev.ps1 test` ALL GREEN; `shots` green on the third run, see below).

- **Activation loss (1).** `WindowGuard` (`shell/tests/tst_main.cpp`) already warned when the window lost focus; it now also starts a 1.5 s timer and, if no window has focus when it ends, fails the running test with `TEST WINDOW LOST ACTIVATION: ...` (`QTest::qFail`). Fixture: `shell/tests/tst_window_lost_fixture.qml` simulates a loss that is never repaired; it is skipped in a normal run and shown with `$env:RUYA_ACTIVATION_FIXTURE = "1"; .\scripts\dev.ps1 qml tst_window_lost_fixture` (ran: `FAIL! ... TEST WINDOW LOST ACTIVATION: the desktop took focus mid-test ...`). The real-desktop path was not exercised (offscreen host run), only the simulated one.
- **Kept log (2).** A red `shots` run copies the runner log to `output/shots-logs/ruya-qmltest-<time>.txt`, last 5 kept (`dev.ps1`, `docs/dev-setup.md`). Not exercised on a red run.
- **Clock (3, 5).** Cause was in the code: `TimeZone` refreshed `clockText` on a fixed 10 s timer, so after a minute change the text could lag up to 10 s, longer than the test's 2 s `tryVerify` against `Date.now()` (not midnight-specific; it fails at any minute change). Now the timer is a single shot aimed at the next minute start (`msToNextTick`, +20 ms) and re-armed on every update. `mockSetNow(ms)` injects the clock (stops the tick; `mockReset` restores it). `test_the_status_clock_follows_a_zone_change_at_once` now runs on a pinned instant; new `test_the_clock_crosses_midnight` pins 23:59:59.9 UTC -> 00:00 and Honolulu 23:59:59 -> 00:00. Revert check: `msToNextTick` returning 10000 -> `test_the_clock_crosses_midnight` red (CAUGHT). The old behaviour in the status-clock test itself is no longer observable because it is pinned.
- **Settings hand-on (4).** Cause (reasoned from the code, not reproduced): a pane that holds the focus itself (no row can) only handed it on when the Column's height changed (`relayout`, needs a frame) or the focused row toggled. If the column's pending polish lands after `r(3)` hidden / `r(4)` shown, the height is the same and nothing triggers `settleFocus`. `SettingsPane` now has `focusableCount` (bound to every row's visible/enabled) and settles when it goes from 0 to more while the pane has the focus (a first version that settled on every change took the first row instead of the neighbour of a removed one and turned `tst_bluetooth` and `tst_storage` red; caught by the tests). Revert check: removing `onFocusableCountChanged` left `tst_settings` green (NOT CAUGHT): the race needs a pending polish and cannot be forced from a test, so there is no new test for it; the existing test stays.
- No test removed.

Files: `shell/tests/tst_main.cpp`, `shell/tests/tst_window_lost_fixture.qml`, `shell/tests/tst_timezone.qml`, `shell/src/time/TimeZone.{h,cpp}`, `shell/qml/SettingsPane.qml`, `scripts/dev.ps1`, `docs/dev-setup.md`.

`shots`: the first two runs were red on 2-4 `test_zz_screenshots` focus lines (Display, StoreUi, SystemInfo, Wallpaper) while another builder used the desktop (the guard logged `TEST WINDOW LOST ACTIVATION` in the second run; the red runs' logs were kept by item 2); a run of `main` was green and the third run of this branch was green (172 passed). Screenshots were not reviewed: no visual change.
