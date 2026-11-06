# T-189 — Test gate: catch assertions that cannot fail (undefined reads, NaN waits)

Status: in-progress · Phase: 2 · Depends: — · Area: shell, scripts · Size: M · Owner: builder

## Goal
Three reviews in a row found shell tests that could not fail: `wait(Storage.groupWindowMs + 200)` waited nothing because `groupWindowMs` was `undefined` in QML (T-184); similar cases in T-167 and T-176. Add an automatic check so the next one fails the gate, then close the small test gaps the reviews listed.

## Read first
- `docs/tasks/T-176-test-gate-hardening.md` Outcome (what the gate checks today), `scripts/lint-tests.ps1`, `scripts/dev.ps1` (qmllint step and how it builds its module path), `shell/tests/tst_main.cpp`
- `shell/tests/tst_storage.qml` (the `groupWindowMs` case, T-184 Outcome) and `shell/CLAUDE.md` (test rules)

## Scope
1. **Find the cheapest check that fails on "read of a member QML cannot see":**
   - try qmllint on `shell/tests/*.qml` with the module response file `dev.ps1` already uses (unqualified access, missing properties on singletons), and fix or justify what it reports;
   - and/or a runtime guard in the test harness: a helper or `TestCase` wrapper that fails a test when `wait()`, `tryCompare` or `tryVerify` receives `NaN`/`undefined`, and when a spy `count` check runs with no wait since the last signal in the tests that declare a window (pick what is feasible; say which in the Outcome).
2. Put the check in `dev.ps1 test` (and CI if it is a script); it must run in seconds. A **self-check fixture** proves it catches a deliberately broken test (`dev.ps1` already has this pattern for `lint-tokens`).
3. Close the small gaps from the reviews: `tst_accessibility.qml` `checkFocused` also asserts a non-`NoRole` role (it passes today on every walked item); a test that the System pane's rollback confirmation is named "Roll back now"; a Backspace test for the Guide overlay (`Shell.qml` power mode back to the actions, then close the overlay).

## Out of scope
- Rewriting existing tests beyond what the new check flags; screenshot tests.

## Acceptance criteria
- [ ] The new check fails on a fixture test that reads an unexposed member / waits on `NaN` (the self-check shows it, and the Outcome shows the check failing on the T-184 round-1 code by `git stash`-free reproduction: write the broken snippet into the fixture).
- [ ] The check passes on the whole tree (or every finding is fixed in this task, each noted in the Outcome with the test it was about).
- [ ] The three small tests exist and fail when their feature is undone (revert check noted).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN, and its added time is under 10 s (record it).

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `shell/CLAUDE.md` (one line: what the check is and what to do when it fails); `docs/tasks/PLANNING.md` Lessons only if you add a rule.

## Hints
- Never weaken an existing assertion to satisfy the check (`CLAUDE.md`, Hard rules): fix the test.

## Outcome
Verified: host (`dev.ps1 test` ALL GREEN on Windows; the CI step `scripts/lint-test-members.sh` ran here under Git Bash with the Windows qmllint, not on the Fedora container, so the CI step itself is unverified until the next push).

**Chosen check: qmllint over `shell/tests/*.qml`, not a runtime guard.** `QuickTestResult::wait` takes an `int`, so `undefined`/`NaN` is converted to 0 inside C++ where a wrapper cannot see it, and a runtime guard would mean replacing `TestCase` in all 30 files. qmllint with the shell's module context already knows every member of the singletons and of `Shell`, and reports `[missing-property]` for exactly the T-184 mistake. A runtime guard for spy `count` checks without a wait was not built (not feasible without the same wrapper); it stays an inbox line.

**What was built**
- `scripts/lint-test-members.ps1` (`dev.ps1 shell` and `test`, step "test member lint") and `scripts/lint-test-members.sh` (CI step "Test member lint" in the `shell` job; the Fedora container has no pwsh, so the same two checks are written twice). 1. qmllint `--max-warnings 0 --unqualified disable` over the tests; `--unqualified disable` only because `windowGuard` and `shotsDir` (context properties from `tst_main.cpp`) are invisible to qmllint (a typo in them fails at run time). 2. A **canary**: a copy of every test gets `function ruya_canary() { return Storage.ruyaCanaryNoSuchMember }` after its `name:` line and qmllint must report it in every file.
- Why the canary: qmllint **goes silently blind** on a whole file when a local (`const`, `let`, `for (const ..)`) is declared inside a nested function or a block-bodied arrow function inside a test function. Minimal case found by bisection: `function t() { const run = (id) => { const s = 1 } }`. This is what had hidden `Storage.groupWindowMs` in `tst_storage.qml`; 4 files were blind (`tst_bluetooth`, `tst_hints`, `tst_storage`, `tst_store_backend`) and had no member checking at all until I fixed them.
- Self-check in `dev.ps1` (`Test-TestMembers`, pattern of `lint-tokens`): fixtures with an unexposed singleton member (`wait(Storage.noSuchWindowMs + 200)`), a misspelled `property Shell shell` member and a nested function with a local are each rejected; a fixture reading existing members plus `windowGuard`/`shotsDir` is accepted.
- Tests typed `property Item shell` are now `property Shell shell` (22 files; `property var app` in `tst_compositor_layers.qml`), otherwise qmllint cannot see reads on the shell (it reported 48 `[missing-property]` on `QQuickItem` before).

**Reproduction of the T-184 round-1 code (criterion 1):** I deleted the `Q_PROPERTY(int groupWindowMs ...)` line from `Storage.h`, rebuilt, and ran the lint on the real tree: it failed with 7 findings, `tst_storage.qml:154/157/171/179/195/205/217: Member "groupWindowMs" not found on type "Storage" [missing-property]` (after the blindness fix below; before the fix it reported nothing, which is how the blindness was found). Restored with `git checkout`.

**Findings on the tree, all fixed (criterion 2)**
- `tst_hints.qml` `test_home_and_page`: `verify(tc.shell.activeFocusItem !== find("hintBar"))` read a member `Shell` does not have, so it was `undefined !== ...`, always true. Now `tc.shell.Window.window.activeFocusItem`. (A genuinely vacuous assertion, the same class as T-184.)
- Blind files: nested functions with locals lifted or reduced without changing what the tests check: `tst_bluetooth` and `tst_storage` `test_contract_statuses` (`run` became the top-level `runCommand`/`ejectStatus`, `run` is a one-line arrow calling it), `tst_hints` (`collect` became top-level `collectGlyphs`), `tst_store_backend` `test_install_lifecycle` (`onJobs` has no local), `tst_settings` (`onRowTop` as arrow).
- Everything else qmllint reported was the untyped shell (above) or the two context properties.

**Small tests (criterion 3)**, revert checks run together (one rebuild, then the three tests): 
- `tst_accessibility.qml` `checkFocused` asserts `Accessible.role !== Accessible.NoRole`; it passed on every walked item. Revert: `PrimaryButton.qml` role set to `NoRole` made `Accessibility::test_home` fail with "Play: focused item without Accessible.role: homePlay [0]".
- `tst_update.qml` `test_rollback_asks_for_the_admin_pin`: after Right, the confirm button has focus and its `Accessible.name` is "Roll back now". Revert: `SystemPane.qml` `customConfirmName` set to "Confirm" failed it ("the confirmation says what it does").
- `tst_power.qml` `test_overlay_backspace_is_back`: Guide, Power, Backspace returns to the actions (index 1, overlay still open), second Backspace closes it and Play regains focus. Revert: both `BackKey.isBackOrBackspace` calls in the `Shell.qml` overlay changed to `isBack` failed it at `powerMode`.
All reverted files restored from git.

**Time (criterion 4):** `dev.ps1 test` ALL GREEN, 382 passed, 30 skipped (screenshot tests without `RUYA_SHOTS_DIR`) in the QML run, Rust unchanged. The new step costs about 3 s: 1.6 s for the tree (two qmllint runs) and a fraction of a second for each of the four self-check fixtures (measured with `Measure-Command`, not a before/after of the whole run, which varies by tens of seconds).

**Docs:** `shell/CLAUDE.md` (Tests: what the lint is and what to do), `docs/dev-setup.md` (test row and a row for the script).

**Limits, honestly:** qmllint cannot check `var`-typed objects (`tc.app.keys` in `tst_compositor_layers.qml`, `Store.jobs[id].percent`, objects returned from `find()`), so a wrong member read there is still `undefined`. A `wait(data.delayMs)` with a typo in a row of test data is not caught. The canary proves a file is checked, not every construct in it.
