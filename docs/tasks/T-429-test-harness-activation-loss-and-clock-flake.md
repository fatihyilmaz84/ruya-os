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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
