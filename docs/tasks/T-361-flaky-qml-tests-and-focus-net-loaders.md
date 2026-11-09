# T-361 - Test reliability: two load-flaky QML tests, a faster page-focus test, the focus net with lazy panes

Status: in-progress · Phase: 2 · Depends: — · Area: shell (tests, Shell.qml, Settings) · Size: S · Owner: builder · Developer surface: none

## Goal
`dev.ps1 test` is green every run, not most runs, and the focus safety net still works now that Settings panes are lazy Loaders.

## Read first
- `shell/CLAUDE.md`, `shell/PATTERNS.md` (tests), `docs/specs/04-design-system.md` §4 (focus rule)
- `shell/tests/tst_battery_cluster.qml` (`test_the_chip_shrinks_to_plus_n_in_a_narrow_room`), `tst_settings.qml` (`test_a_hidden_focused_row_hands_the_focus_on`), `tst_pages.qml` (`test_every_page_owns_the_focus`), `tst_settings_lazy.qml`, `tst_profile_admin.qml`
- `shell/qml/Shell.qml` (`modalShown()`), `SettingsPage.qml`, `StoragePane.qml` lines 130-145

## Scope
1. **Battery chip test:** the narrow-room check fails under load (gap 23-25 px against 24). Find the real margin and make the check independent of font metrics (compare against the measured item widths, or wait until the layout settled); never just loosen the number.
2. **Hidden focused row test:** find why it fails under load (timer, fade, lazy pane) and make it deterministic.
3. **`test_every_page_owns_the_focus`** (about 35 s): a short-fade switch for tests; also cover the admin-only `profiles` category and assert the requested category opened (SettingsPage falls back silently).
4. **Focus net and Loaders:** `Shell.modalShown()` skips Loaders without a visible item; a net test with a Settings pane loaded.
5. Small ones: a test of the `topSettled()` gate of `reapIfDone`; `tst_profile_admin` stops setting `modalsBuilt = true` by hand if a real path exists; the stale "created then, hidden" comment in `StoragePane.qml`.

## Out of scope
- New features; any assertion weakened (CLAUDE.md, Hard rules).

## Acceptance criteria
- [ ] The two flaky tests pass 20 runs in a row under load (`dev.ps1 test` with a parallel CPU load; how is in the Outcome) and each still fails when its behaviour is removed.
- [ ] `test_every_page_owns_the_focus` under 10 s, covers `profiles`, red when a category falls back.
- [ ] `tst_*`: `test_the_focus_net_works_with_a_settings_pane_loaded`, `test_reap_waits_for_the_top_to_settle` (red without the fix/gate).
- [ ] `dev.ps1 test` ALL GREEN; test-time before/after in the Outcome.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `shell/PATTERNS.md` if a test helper is added.

## Hints
- Inbox lines (lead-5, T-356, T-349 reviews) are verbatim in `STATUS-parked.md`, "Inbox triage 2026-11-09 (lead-7)".

## Outcome
Verified: host

**Honest first.** Neither flaky test could be made to fail here: `test_the_chip_shrinks_to_plus_n_in_a_narrow_room` and `test_a_hidden_focused_row_hands_the_focus_on` each ran 30 times alone and their whole files (tst_battery_cluster, tst_settings) 12 times, with 24 busy-loop PowerShell processes on 16 cores (about 14 s per single-test run instead of 0.6 s): 0 failures. The fixes below are for the causes the code shows, not for a reproduced failure; the load recipe is `output\loop.ps1` (scratch, not committed): start 24 `powershell -Command "while($true){}"`, run `tst_ruyashell.exe -o <log>,txt -input <file> <TestCase>::<function>` N times (the class prefix is needed to name one function), stop the load.

**What was built (tests plus two comments; no behaviour change in `shell/qml`):**
1. **Battery chip:** the gap check read the pill's edge before the pill had caught up. The chips are budgeted at once from the fonts, but the `Row` (and so the pill) is laid out one frame later, and the clock text (`HH:mm`, proportional digits) changes width every minute, so the gap read 23-25 px against 24 (the fonts differ by a pixel or two). `checkCluster` now waits until the pill is as wide as its row plus padding (measured widths only) and then re-reads `clusterProblem()` for up to 2 s; a real overlap still fails with its numbers. The 24 and the 0.5 stayed.
2. **Hidden focused row:** plain `verify(r(2).activeFocus)` after two key clicks and no check that the window is active (`activeFocus` is false everywhere then, the only way found for this to fail). The test now calls `windowGuard.ensureActive()` first and waits with `tryVerify` (5 s). The assertions on what the pane does are untouched.
3. **`test_every_page_owns_the_focus`:** 32.0 s to 7.0 s for both data rows (measured with the runner, single test). `Theme.motionFactor = 0.03` (fades of 9 ms, real, not reduced motion; reset in `cleanup()`), the "late replies" delays 100 to 40 ms, and Player One (`Profiles.switchTo("p1", "1234")`) for the Settings categories so `profiles` is covered; every category asserts `page_settings.current.key === category` ("the requested category opened"). A near-zero fade (0.001) is a different situation: the covered page hides in the same step it grabs the focus and the net repairs it (`focusRepairs` 1), so 0.03 is the shortest that keeps the test's meaning. `checkFocusOnTop` re-reads `focusProblem()` for up to 2 s instead of one `verify` right after the fade (the old test relied on the 300 ms fade to cover a pane's deferred `settleFocus`; at 0.001 the Activity page showed it).
4. **Focus net and Loaders:** `Shell.modalShown()` already skipped Loaders without an item (T-349). New `test_the_focus_net_works_with_a_settings_pane_loaded` (tst_settings_lazy): opens the rename keyboard of My profile through the keys so the modal Loaders hold hidden items, asserts `modalShown()` is false, opens Power over Settings, lets the covered Settings take the focus and asserts the net gives it to Power (`focusRepairs` +1), and Back works.
5. `test_reap_waits_for_the_top_to_settle` (tst_settings_lazy, `motionFactor = 4`): Store, then Settings opened over it and popped at once, so the popped slot is at opacity 0 and only `topSettled()` keeps it; asserts it stays for 5 drawn frames while the Store has not settled, and is destroyed after. `tst_profile_admin` calls `beginModal()` (the real path) instead of setting `modalsBuilt`. `StoragePane.qml`: the stale "created then, hidden" comment now says what happens (read when shown, each time its category is selected).

**Revert checks** (`revert-check.ps1 ... -Test`, all caught, files restored): `Shell.qml` `modalShown` Loader branch disabled -> both Loader tests red; `reapIfDone` without `!root.topSettled()` -> `test_reap_waits_for_the_top_to_settle` red ("the popped page is still there"); `SettingsPage` ignoring `params.category` -> `test_every_page_owns_the_focus` red on both rows; `SettingsPane.settleFocus` not handing the focus on -> `test_a_hidden_focused_row_hands_the_focus_on` red. Battery: `fitChips` with `room + 30` stayed green (the chip counts are discrete, 30 px changes no choice at these widths; that is how the suite was before too); with `room + 400` five tests are red, including the narrow-room one.

**Test time:** `test_every_page_owns_the_focus` 32.0 s to 7.0 s. Whole `dev.ps1 test` 429 s, Qt Quick tests 274 s (1012 passed, 79 skipped), Rust 834 passed; no earlier full-run time was taken in this worktree (a saving of about 25 s in the Qt part is expected from the page test).

**Files:** `shell/tests/tst_battery_cluster.qml`, `tst_settings.qml`, `tst_pages.qml`, `tst_settings_lazy.qml`, `tst_profile_admin.qml`, `shell/qml/StoragePane.qml` (comment), `shell/PATTERNS.md` (new section on waiting for geometry/focus and short fades).

**Inbox:** the `shots` reds seen on main for two reviewers (tst_store_ui:81, tst_system_info:502, tst_wallpaper:898) and green for another builder look like the same class (a plain check right after a change against real GPU windows under load); not in scope and not touched. Worth one pass with the pattern in PATTERNS.md.
