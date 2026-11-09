# T-379 - `shots` reds on main: tst_store_ui:81, tst_system_info:502, tst_wallpaper:898, tst_display:101

Status: done · Phase: 2 · Depends: T-377 · Area: shell (tests) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
`dev.ps1 shots` is green on main on real GPU windows, so a red `shots` means a real regression again.

## Read first
- `shell/PATTERNS.md`, the section on reading a property right after a change (plain read after change; T-361)
- `shell/tests/tst_store_ui.qml` near line 81, `tst_system_info.qml` near 502 ("the closed page is gone"), `tst_wallpaper.qml` near 898, `tst_display.qml:101` (`test_zz_screenshots`, "category list has focus"; found by the T-377 builder, red on main too)
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
Verified: host. **No code or test change: the four reds did not reproduce on main (3662050) in any of five attempts.** Builder Sonnet 5.5 (high effort), round 1.

**Reproduction attempts** (this worktree, built fresh, real GPU windows, `QSG_RENDER_LOOP=basic` as `shots` sets it):
1. `dev.ps1 shots`, full: 158 passed, 0 failed, 249 s.
2. `dev.ps1 shots`, full, again: 158 passed, 0 failed, 249 s.
3. The four named functions alone (`StoreUi`, `SystemInfo`, `Wallpaper`, `Display` `::test_zz_screenshots`, run straight from `tst_ruyashell.exe` with `RUYA_SHOTS_DIR`) with 16 busy threads on the 16-core machine: 12 passed.
4. The same four with a borderless top-most black window over the whole screen (no activation): 12 passed.
5. The same four while a full `dev.ps1 test` (offscreen, all cores) ran in this worktree: 12 passed.
`dev.ps1 test`: ALL GREEN (1018 Qt Quick tests, 79 skips, Rust green).

**Cause.** The four assertions are not plain reads: all of them are already `tryVerify` (2 s) or `tryCompare` on the observable state (`tst_store_ui.qml:82` and `:56`, `tst_system_info.qml:502`, `tst_wallpaper.qml:898`, `tst_display.qml:101`), so the T-361 class (plain read right after a change) does not apply, and a longer wait or a retry would be exactly what the task forbids. No recent merge is implicated either: the same sources are green twice in a row here, and the T-377 builder saw `tst_display:101` red on main's own older build too. What is left is the environment of those runs. All four wait for a deferred focus (`activeFocus` after a page opens) or for a popped page to be reaped (`Shell.qml` `reap()` waits for a `frameSwapped`), and both stop when the test window is not active or draws no frame: `activeFocus` is false in an inactive window. The runner already says so when it happens: `WindowGuard` prints `TEST WINDOW LOST ACTIVATION` per test function and re-requests activation (it appeared 1-2 times in each of my full runs, always recovered). It checks activation only in `init()`, so a loss in the middle of a function that Windows then refuses to give back (foreground lock while another process holds the desktop, as with several lanes working at once) fails the next `activeFocus` check with no hint. The T-377 Outcome also notes a real-window probe on this desktop that "swapped no frame" in a scratch window, the same kind of disturbance. I could not prove this for the reviewers' runs (their logs are gone), so it is the most likely cause, not a verified one. Nothing in the product is wrong that these runs could show.

**What I did not do.** No assertion weakened, no sleep, no retry, no code change. A speculative edit to a test I could not see failing would not satisfy the revert-check criterion (no changed test, nothing to revert), so none was made.

**Acceptance.** `shots` ALL GREEN twice in a row on main's tree plus this branch (docs only): met. `dev.ps1 test` ALL GREEN: met. Revert check: not applicable, no assertion changed.

**If a red appears again:** read the `QWARN` lines in the `shots` output first. A `TEST WINDOW LOST ACTIVATION` on the failing function means the desktop, not the shell: re-run. A red without it, twice, is a real finding and needs the failing log kept (`shell\build-win\ruya-qmltest.txt`) in the report.

**Files.** This task file only. Scratch under `output\` (`hog.ps1`, `cover.ps1`, `run4.ps1`, logs), not committed.
