# T-356 - Focus falls out of a page: neither the pad's B nor Esc leaves it (found on the Dell)

Status: in-progress · Phase: 2 · Depends: — · Area: shell (Shell.qml focus, SettingsPane, ActivityGamePage, Page) · Size: M · Owner: builder (Opus recommended) · Developer surface: none

## Goal
Owner report (Dell, image 0.0.56, 2026-11-09, reproducible): on SuperTuxKart's activity screen (app page -> "Your activity" -> `ActivityGamePage`, STK has no stats) neither the pad's B nor the keyboard's Esc goes back; the hint bar says "B Back"; the Guide key works, and Esc works again after opening and closing the Guide overlay. A raw capture on the Dell proved the pad's B arrives as KEY_ESC from `ruya-inputd` exactly like the keyboard's Esc: the shell receives the key and no item takes it, i.e. **the window's active focus is not in the page** (it sits on the `Shell` root; the Guide key works because `Shell` handles it itself; closing the overlay runs `focusCurrent()`).

## What is known (lead-5)
- Reproduced in the offscreen harness with the mock: `tst_activity.qml::test_the_game_page_leaves_with_back_while_the_usage_service_is_slow_or_failing` (added in the WIP commit on this branch) fails at "and after a failed read": app page -> `Usage.mockFailNextRefresh("failed")` -> Return on `detailActivity` -> `activityGame`: `Window.activeFocusItem` is the `Shell` root (not `gameBody`), `Usage.ready` false, page `activityGame`. The same path with healthy data, an empty-stats game and a slow read passes.
- Likely mechanism (unproven): `SettingsPane.Component.onCompleted` sets `row.focus = true` on the FIRST `SettingControl` even if it is invisible (`gameTotal` is `visible: Usage.ready && page.played`), and/or a focused row hidden by a failed read (`Usage.ready` false) drops the whole focus chain to the root; `Qt.callLater(settleFocus)` cannot help once the chain is gone. `Shell.restoreFocus()` then calls `page.forceActiveFocus()` but the pane's subFocusItem is a hidden row.
- The WIP commit already contains: `Shell.focusLost` (active focus item is null, the shell or the window content item while a page is open and nothing else is modal), an `onActiveFocusItemChanged` monitor that calls `focusCurrent()` through `Qt.callLater`, `orphanKey()` (a Back key that reaches the shell leaves the page when the focus is lost, and is logged: `ruya-shell: Back reached the shell; focus on <item>`), and the tests `test_a_back_that_reaches_the_shell_leaves_the_page_when_the_focus_is_lost` (passes) and the failing one above. The monitor did NOT fix the failing test: find out why (the focus change signal may not fire, or `focusCurrent()` does not land inside the page because the pane's remembered row is hidden). Keep what is useful, drop what is not.

## Scope
1. Find the root cause with the failing test (print `Window.activeFocusItem` and the chain; try the variants: hidden first row, a focused row hidden later, `Usage.ready` flipping) and fix it where it belongs: `SettingsPane` must never leave the focus chain pointing at a row that cannot hold it (initial focus only on a visible, enabled row; when the focused row hides, the pane takes the focus itself and, if rows exist, moves to the nearest visible one); `Page`/`Shell.restoreFocus` must land inside the page whatever the data.
2. Keep one generic safety net in `Shell` if it is simple and does not disturb page changes or modals (run the whole suite): focus lost to nobody/the shell/the content item while a page is open and no modal or overlay is up is repaired; a Back key that still reaches the shell leaves the page (never on auto-repeat) and is logged.
3. Check every other `SettingsPane` page with data-dependent rows for the same trap (grep `visible:` on the first row of panes: ActivityGamePage, ActivityPage, StoragePane, SystemInfo/About, BluetoothPane, NetworkPane, DisplayPane); add one test per pane family that hides the focused row or starts with all rows hidden and asserts Back leaves.

## Acceptance criteria
- [ ] `test_the_game_page_leaves_with_back_while_the_usage_service_is_slow_or_failing` passes without weakening it, and a new test per other affected pane (the revert of the fix turns each red; say how in the Outcome).
- [ ] A generic test: after `openPage` of every page key reachable from Home/Settings in the mock (iterate the page table), `Window.activeFocusItem` is inside the page, whatever the mock data (including failed reads).
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN (screenshots of the changed pages unchanged). UX line: Back leaves from every state; the Outcome has `UX notes:`.
- [ ] Dell (lead run, hw): STK Activity screen: pad B and Esc go back. The Outcome says `Verified: host (hw pending: Dell)`.

## Out of scope
- `ruya-inputd` (proven innocent), the Guide overlay, T-349 (lazy panes: it touches the same SettingsPane; the branch merged second resolves).

## Docs to update
- `shell/PATTERNS.md` (a pane's first focusable row must be visible; what the shell repairs), `docs/specs/04-design-system.md` §7 focus rules if a rule changes.

## Outcome
_Filled in by the implementer._
