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
Verified: host (hw pending: Dell)

**Root cause (reproduced in the offscreen harness on the owner's path Store -> STK-like installed game -> "Your activity", and via Home):** when the activity page's slide-in ends, the covered app page's slot fades to invisible, and the "Uninstall" / "Your activity" buttons of `AppDetailPage` ran `onVisibleChanged: if (!visible) primary.forceActiveFocus()`. That forced the focus into the covered, disabled page, and the window's active focus ended on the `Shell` root: A, D-pad, B and Esc all went nowhere until the Guide overlay ran `focusCurrent()`. The lead's WIP test failed only by timing (it checked before the fade ended). A second trap: Qt 6.10 lets a hidden item keep or receive the active focus, so `SettingsPane` put it on a hidden first row (`gameTotal`, `activityWeek`) whenever the data hid the rows.

**Built**
- `AppDetailPage.buttonHidden()`: `primary.focus = true` (only moves the page's own focus item) instead of `forceActiveFocus()`.
- `SettingsPane`: `settleFocus()` never leaves the focus on a hidden or disabled row: it moves to the nearest visible row (the one before, else the next one, `nearestRow()`), or with none it clears the stale row's `focus` so the pane holds it itself (`staleRow()`). It runs on entry, from `relayout()`, and at once when the focused row hides or is disabled (`focusedChild` + `Connections`).
- `Shell`: the page slot's `restoreFocus()` skips a hidden saved item. The safety net is narrow: `focusIsLost()` is true only with a page open, a window that is active, no app, Guide overlay, setup or visible modal-layer child (`modalShown()`), and the focus on nothing, the shell, the content item or a covered page. It is checked by a 0 ms `Timer` after each focus change, repairs with `focusCurrent()`, logs `ruya-shell: the focus fell out of page <key>` and counts `focusRepairs`. It never acts on keys.
- Docs: `shell/PATTERNS.md` (nested pages item 6, settings rows), `docs/specs/04-design-system.md` §4 ("Where the focus may be").

**Deviations**
- The lead's WIP `orphanKey()` (a Back that reaches the shell leaves the page) and its test `test_a_back_that_reaches_the_shell_leaves_the_page_when_the_focus_is_lost` are removed, as is the WIP `focusLostTest` hook. The lead asked in round 1b for a net that never acts on keys after the full run showed it firing during PIN-modal flows. The root fixes plus the focus repair cover the Dell case. Scope 2 asked for the Back handling, so this is a deviation.
- `Qt.callLater` in the net reordered the pages' own deferred focus calls (Store: after leaving a search the focus went to the "Apps" row instead of "Featured", `tst_store_ui`). The net now uses a Timer.
- Nearest row is "the one before, else the next one", the order the profile panes already relied on (`tst_profile_admin::test_remove_own_pin`).
- Pane families checked (scope 3): only ActivityGamePage and ActivityPage start with data-dependent first rows. Storage, SystemInfo, About, Bluetooth, Network and Display have a fixed first row, but their rows can hide later. The generic `SettingsPane` fix and `test_every_page_owns_the_focus` (every Settings pane entered, healthy and failing services) cover them. No per-pane file changed.

**Tests** (new): `tst_activity`: `test_the_store_path_to_a_game_page_keeps_the_focus` (the owner's path, focus asserted at each step once the page below has faded out, `focusRepairs` 0), `test_a_covered_page_that_takes_the_focus_gives_it_back`, `test_back_to_the_app_page_skips_a_button_hidden_meanwhile`, `test_the_activity_page_after_a_failed_read_holds_the_focus_and_leaves`, `test_the_safety_net_stays_out_while_a_modal_shows`. The lead's two tests now wait for the fade and assert `focusRepairs` 0. `tst_settings`: `test_a_hidden_focused_row_hands_the_focus_on`, `test_a_pane_entered_with_hidden_rows_never_focuses_a_hidden_row`. `tst_pages`: `test_every_page_owns_the_focus` (every page key of `builtinPages` from Home and over the app page, every Settings category entered; healthy and with a failed usage read plus late Bluetooth/Network/Library replies; Back leaves each; `focusRepairs` 0). Test helpers are top-level functions (the member lint).

**Revert checks** (`revert-check.ps1`; each one turned the named tests red):
- `primary.focus = true` back to `forceActiveFocus()`: the Store-path test, the Home-path test, the lead's slow/failing test, and `test_every_page_owns_the_focus` (both rows).
- `stale.focus = false` removed: the failed-read Activity test, both no-stats game tests, and both bare-pane tests.
- The `focusedChild` visibility handler emptied: the failed-read Activity test.
- Nearest row "before" branch disabled: `test_a_hidden_focused_row_hands_the_focus_on` and `tst_profile_admin::test_remove_own_pin`.
- The net's `focusCurrent()` removed: the covered-page test.
- `modalShown()` dropped from `focusIsLost()`: the modal test.
- The Timer back to `Qt.callLater`: `tst_store_ui` `test_backspace_is_back` and `test_search_replaces_rows_until_back`.
- The `restoreFocus` `.visible` check removed: the hidden-button test.
- `relayout()` settling instead of only `ensureFocusedVisible()` was checked before the `focusedChild` handler existed (bare-pane test red). The two now overlap.

Checks: `dev.ps1 test` ALL GREEN (959 QML passed, 73 skipped; 749 Rust); `dev.ps1 shots` ALL GREEN (152). I looked at `90-activity-game-en.png` and `90-activity-app-page-en.png`: no visual change, and the focus ring is on the expected row and button.

`tst_battery_cluster::test_the_chip_shrinks_to_plus_n_in_a_narrow_room` failed in one run with main's QML files too (measured on this branch with the three changed QML files restored to main), and it passed in the next full run. It is the known load flake and was not touched.

UX notes: states reached: Store -> card -> app page -> "Your activity" (no stats, loading, failed read, data), Activity page after a failed read, every page from Home and over the app page, every Settings pane. Back leaves each one (the Settings pane hands Back to its list first). Focus lands as follows: in the activity page with no rows, on the pane itself (B and Esc leave); after Back, on "Your activity", or on the primary button if "Your activity" hid meanwhile; on the Store, back on the card. What I doubted: the order "row before, else next" (chosen to keep the profile panes' behaviour). Pad B and Esc on the Dell are still unverified (hw).

Files: `shell/qml/AppDetailPage.qml`, `shell/qml/SettingsPane.qml`, `shell/qml/Shell.qml`, `shell/tests/tst_activity.qml`, `shell/tests/tst_settings.qml`, `shell/tests/tst_pages.qml`, `shell/PATTERNS.md`, `docs/specs/04-design-system.md`.
