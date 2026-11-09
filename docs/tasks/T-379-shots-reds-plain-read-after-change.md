# T-379 - `shots` reds on main: tst_store_ui:81, tst_system_info:502, tst_wallpaper:898

Status: todo · Phase: 2 · Depends: T-377 · Area: shell (tests) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
`dev.ps1 shots` is green on main on real GPU windows, so a red `shots` means a real regression again.

## Read first
- `shell/PATTERNS.md`, the section on reading a property right after a change (plain read after change; T-361)
- `shell/tests/tst_store_ui.qml` near line 81, `tst_system_info.qml` near 502 ("the closed page is gone"), `tst_wallpaper.qml` near 898
- `shell/CLAUDE.md`; the T-361 Outcome (deterministic focus/layout tests)

## Scope
1. Reproduce each red with `dev.ps1 shots` (an unlocked desktop; re-run on `TEST WINDOW LOST ACTIVATION`). Two reviewers saw them on 9b48ef1; one builder saw them green.
2. Find the cause of each: a plain read right after a change that only settles a frame later on the GPU renderer (the T-361 class), or a real regression from a recent merge (candidates: T-349/T-356 lazy panes, T-376 hidden L0). Say which in the Outcome, with the commit for a regression.
3. Fix the test with the PATTERNS.md waiting rule (`tryCompare`/`tryVerify` on the observable state), never a longer sleep, a retry or a weaker assertion; fix the code if it is a regression.

## Out of scope
- New screenshots, other flaky tests (one Inbox line each).

## Acceptance criteria
- [ ] `dev.ps1 shots` ALL GREEN twice in a row on main's tree plus this branch.
- [ ] `dev.ps1 test` ALL GREEN; each changed assertion still checks the same state (Outcome lists old and new line).
- [ ] `scripts/revert-check.ps1` (or a manual revert) shows each changed test still red when its feature is broken.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `shell/PATTERNS.md` if the cause is a new class.

## Hints
- After T-377, which touches the Store page that `tst_store_ui` drives.

## Outcome
_Filled in by the implementer._
