# T-167 — Test isolation: the Store UI flake and a language leak

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
