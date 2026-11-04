# T-167 — Test isolation: the Store UI flake and a language leak

Status: done · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder

## Goal
`dev.ps1 test` and CI never fail at random. `tst_store_ui.qml::test_update_adding_high_risk_*` failed once in a full run (`Store.jobs` length 1 instead of 0) and passed on every rerun (T-157); CI's shell job also failed once on a docs-only commit (`18a342a`, 2026-11-02), likely the same test.

## Read first
- `shell/tests/tst_store_ui.qml` (the two `test_update_adding_high_risk_*` functions and whatever runs before them), `shell/src/store/MockStoreBackend.*`, `shell/src/store/Store.*`
- `shell/CLAUDE.md` (Tests: `tryCompare`, never on a list's `length`)

## Scope
1. Reproduce: run `tst_store_ui` alone in a loop (at least 30 runs; say how in the Outcome) and inside the full suite; find which earlier test or timer leaves a job behind, or which assertion races the mock's asynchronous job updates.
2. Fix the cause: in the test (wait for the state the next step needs, reset the mock between tests) or in the mock (deterministic job completion), not by adding sleeps or longer timeouts alone. Never weaken an assertion (`CLAUDE.md` Hard rules); if an assertion was wrong, say why.
3. **Language leak (T-159 Inbox):** in `tst_update.qml` a `Key_Right` right after signing in as Ada (p2) changed `DeviceSettings.language` to `tr` for the rest of the process (the builder switched that test to `Key_Up`). Find which item had focus and why a Right reached a language control; fix the cause (focus after sign-in, or the setting leaking between profiles) with a test, and say whether other test files were exposed.
4. If the cause is in `Store` or the mock and could also hit the real D-Bus backend (a job signal handled out of order), add an Inbox line for the service side.

## Out of scope
- Other flakes, unless they are the same cause (then fix and name them).

## Acceptance criteria
- [ ] The Outcome names the cause, with the evidence (the failing interleaving).
- [ ] The language leak: a test that sends `Key_Right` right after Ada signs in and asserts the language is unchanged and focus is where spec 02 §1 says (fails before the fix).
- [ ] `tst_store_ui` passes 30 runs in a row after the fix (the loop command and the count in the Outcome); it failed at least once in the same loop before the fix, or the Outcome explains why the race could not be reproduced and what was fixed by reading the code.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- None, unless the mock's behaviour changed (`03-services-and-apps.md` §4.3 mentions the mock).

## Hints
- The test binary takes a test-function filter (`-functions`, or `tst_store_ui::test_name` as an argument); `dev.ps1` shows how it runs the Qt Quick tests.

## Outcome
Verified: host (`dev.ps1 test` ALL GREEN, 274 QML + 22 skips, Rust unchanged; offscreen). No UI change, so no `shots`.

**Cause of the Store flake.** `Store.mockReset()` reset the mock backend (timer stopped, its job list cleared) but not the facade: `Store.jobs` (the `m_jobs` map in `Store.cpp`) keeps every job that has had a `jobProgress` and loses it only on `jobFinished`, which a reset never sends. `test_low_risk_needs_no_pin` (alphabetically the only test that ends with its install still running) starts the Racer install and returns at once. The test binary runs the mock at 10 ms per step (`RUYA_MOCK_FAST`). If the first tick fires before the next `init()` calls `mockReset()` (a few ms of event processing, load-dependent), `Store.jobs` holds `org.example.Racer` for the rest of the file; if not, nothing is left behind. The first later test that asserts "no jobs" is `test_update_adding_high_risk_back_cancels` (Qt Quick sorts test functions by name: ... low_risk, rows_follow, search, uninstall_*, update_adding_high_risk_back_cancels), then `..._needs_admin_pin`: `Store.jobs` length 1 instead of 0. CI's one-off failure on `18a342a` was most likely the same (the CI log is not available here; a loaded runner makes an early tick more likely).

**Evidence.** The race cannot be hit on demand: 30 runs of `tst_store_ui` alone (0 failures), the same 30 with 16 CPU-burner processes running (0), 10 runs of just `test_low_risk_needs_no_pin` + `test_update_adding_high_risk_back_cancels` (0). Forcing the interleaving, by making `test_low_risk_needs_no_pin` wait for the first progress before it ends, failed `test_update_adding_high_risk_back_cancels` and `..._needs_admin_pin` (`Actual: 1, Expected: 0`) on every run (3 of 3). That is the failing interleaving, made deterministic; that edit became part of the fix (below).

**Fix.** `Store::mockReset()` also clears `m_jobs` and emits `jobsChanged` (the facade now follows the mock's reset). Tests: `tst_store_ui` `init()` asserts no job survives the reset; `test_low_risk_needs_no_pin` now ends with its job running on purpose (waits for the first progress), so the old race is hit on every run; `tst_store_backend::test_reset_drops_a_running_job`. Before the `Store.cpp` change (old binary, new tests) both failed: `test_rows_follow_the_catalogue` (first test after low_risk: "no job survives the reset", 1 vs 0) and `test_reset_drops_a_running_job` (1 vs 0). After: `tst_store_ui` alone 30 of 30 green (PowerShell loop over `tst_ruyashell.exe -input shell\tests\tst_store_ui.qml`, offscreen, 2.7 s each), then 30 of 30 again while `dev.ps1 test` ran in parallel; `tst_store_backend` and `tst_update` 3 of 3. It was never seen failing in a 30-run loop before the fix (see above), so the proof is the forced interleaving.

**Language leak.** Nothing in the shell sends a `Right` to a language control by accident: after sign-in the focus is on Play (`Right` goes to Details, tested). The T-159 `Key_Right` came after `openSystemPane`, and the System pane enters on its first row, the Language `ChoiceRow`, which consumes Left/Right (02 §1.2): that is the specified behaviour, and `DeviceSettings.language` (process-wide: the installed translator) then stayed `tr` for the rest of `tst_update.qml`, whose later tests compare English text. Fix is in the test file: `init()` and `cleanup()` put `en` back. New tests in `tst_update.qml`: `test_a_press_in_the_system_pane_reaches_the_language_row` (focus on `rowLanguage`, Right gives `tr`, focus stays) and `test_a_press_right_after_sign_in_stays_on_home` (Right after Ada signs in: `homeDetails` has focus, language `en`). With the two reset lines removed the second one fails (`tr` vs `en`, run after the first) and so does `test_a_refused_setting_says_so`; with them it passes. Other files: only `tst_i18n.qml`, `tst_setup.qml` and `tst_home.qml` touch the language, and they already reset it in `init`/`cleanup`; the engine and its `DeviceSettings` are fresh per file, so nothing leaks into the next file.

**Fresh-worktree note.** In a new worktree `dev.ps1 test` fails `translation lint` ("lupdate project not found") until `cmake --build shell\build-win --config Release --target update_translations` has run once (it makes the lupdate project file). Inbox line.

Files: `shell/src/store/Store.cpp`, `shell/tests/tst_store_ui.qml`, `shell/tests/tst_store_backend.qml`, `shell/tests/tst_update.qml`. No spec change (the mock's observable behaviour is unchanged).
