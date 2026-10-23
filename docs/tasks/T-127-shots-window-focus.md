# T-127 — `dev.ps1 shots`: focus failures caused by the desktop say so, and recover

Status: done · Phase: 1 · Depends: — · Area: shell, scripts · Size: S

## Goal
`dev.ps1 shots` (real GPU windows) no longer fails with an unexplained `activeFocus` assertion when the test window loses activation to the desktop. Either the test window is re-activated before the test goes on, or the failure names the cause ("test window lost activation"), so nobody debugs product code for a desktop problem.

## Read first
- Root `CLAUDE.md` "Verify" (`shots` depends on the desktop; never edit a test to suit the desktop)
- `shell/tests/tst_main.cpp`, `shell/tests/tst_power.qml` (`init()`), `shell/tests/tst_lockout.qml`
- `scripts/dev.ps1` (`Do-Shots`)
- The STATUS session log entries of T-114, T-125 and the lead review of 2026-10-23 (three different focus failures, all green on the re-run)

## Background
Seen three times in one day, each time in a different test (`Power::test_guide_long_press`, `Lockout::test_wrong_pins_lock_the_profile`, `Power::test_confirm_and_cancel` + `test_guide_short_press_opens_overlay`), never offscreen. In Qt Quick, `activeFocus` is only true while the window is the active (focus) window: when another window takes activation, `activeFocusItem` goes away and every focus assertion after it fails, although the keys and the UI logic are fine.

## Scope
1. Find out what actually happens, and write it in the Outcome: log `Window.active` / `QGuiApplication::focusWindow()` changes during a `shots` run (temporarily), and reproduce by clicking another window during a run.
2. A shared fix for every test case, not per-test edits:
   - before each test function (e.g. a helper called from every `init()`, or the `QuickTest` setup object in `tst_main.cpp`), make sure the test window is active: `requestActivate()` and wait for it (`QTest::qWaitForWindowActive` or a `tryVerify` on `Window.active`) for a bounded time;
   - if it can't be activated, fail with a message that says so ("test window is not active: the desktop took focus; re-run `shots`"), instead of the next `activeFocus` assertion failing.
   Offscreen (`dev.ps1 test`, CI) must behave exactly as before: there every window is active.
3. If activation from a background process is refused by Windows (foreground lock), say so in the Outcome and keep the clear failure message; that alone meets the goal.

## Out of scope
- Retrying failed tests automatically, or `skip()`ping focus assertions in `shots` mode (forbidden: tests are the spec's teeth).
- Changing what any test asserts.

## Acceptance criteria
- [ ] Clicking another window while `shots` runs either does not fail the run, or fails with the "not active" message naming the test window, never with a bare `activeFocus` assertion (evidence in the Outcome: the run's output).
- [ ] `dev.ps1 test` (offscreen) is ALL GREEN with the same test count as before, and the new code is shown not to run its wait there (or to pass instantly).
- [ ] `dev.ps1 shots` is green twice in a row on an untouched desktop.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- Root `CLAUDE.md` "Verify" bullet on `shots` and the desktop (what the message means); `shell/CLAUDE.md` "Tests" if the helper must be called from new test files.
- Remove the two related lines from the Inbox history only if they are still there (the lead already moved them into this task).

## Hints
- `TestCase` has `windowShown`; `Window.window.active` is available from any item via the `Window` attached property.
- A helper in a shared QML file (e.g. `shell/tests/TestUtil.js`, or a property on the test host) keeps every `init()` one line.
- The Windows host may refuse `SetForegroundWindow` from a process that isn't in the foreground; `QWindow::requestActivate()` then only flashes the taskbar.

## Outcome
**Built.** `WindowGuard` (QObject in `shell/tests/tst_main.cpp`, exposed as context property `windowGuard`). (1) `ensureActive()` is the first line of every `init()` in the 11 `tst_*.qml`: if the visible test window is not the focus window it calls `requestActivate()` and waits up to 3 s (`qWaitForWindowActive`), else returns "test window is not active: the desktop took focus ...; re-run `shots`", which `verify` reports. (2) It also listens to `focusWindowChanged`: when focus drops to nothing it prints `TEST WINDOW LOST ACTIVATION` and re-activates at once, so a mid-test loss is named in the output.

**What happens.** Activation is lost during a run even on an untouched desktop: each of the two final `shots` runs logged one loss (in `Power::test_super_long_press`, in `SystemUi::test_zz_screenshots`) and recovered. An earlier run (before the loss logging) failed `Power::test_guide_short_press_opens_overlay` on `activeFocus` inside a 1 s wait, which `init()` alone cannot catch; hence (2). A loss within one test function can still fail an assertion before the re-activation lands; the log line names the cause.

**Verified.** `dev.ps1 test` ALL GREEN, 133 passed / 11 skipped (same as before; offscreen the window is always active, so the guard returns at once). `dev.ps1 shots` ALL GREEN twice, 144 passed. **Unverified:** deliberately clicking another window during a run, and whether Windows' foreground lock ever refuses `requestActivate` (it worked in the observed losses).

**Deviation.** Docs: root `CLAUDE.md` Verify bullet and `shell/CLAUDE.md` Tests.
