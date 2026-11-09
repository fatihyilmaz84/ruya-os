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
_Filled in by the implementer._
