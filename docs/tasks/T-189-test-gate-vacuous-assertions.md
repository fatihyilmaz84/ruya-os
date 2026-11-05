# T-189 — Test gate: catch assertions that cannot fail (undefined reads, NaN waits)

Status: todo · Phase: 2 · Depends: — · Area: shell, scripts · Size: M · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
