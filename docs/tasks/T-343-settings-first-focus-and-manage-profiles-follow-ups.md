# T-343 - Settings follow-ups: first focus skips disabled rows, read-only rows in the spec, Manage profiles result and Guest

Status: todo · Phase: 2 · Depends: — · Area: shell (SettingsPane, ManageProfilesPane, MyProfilePane), docs (04) · Size: S · Owner: builder

## Goal
Review findings of T-293 and T-324 that a player can hit: the first focus can land on a row that is disabled, a read-only row (the identity row of My profile) is a pattern that exists but is not in the design system, and in Manage profiles the result message of an action sits below the fold while the Add form is open and Guest has no line of its own.

## Read first
- The Inbox lines tagged T-293 and T-324 in `docs/STATUS-parked.md`, "Inbox triage 2026-11-08 (lead-5)" (verbatim)
- `shell/qml/SettingsPane.qml` (`settleFocus`, `focusableRows`, around line 135-165), `ManageProfilesPane.qml`, `MyProfilePane.qml` (the identity row: a focusable row with no action and a hints override), `ProfilePaneBase.qml`, `SettingRow.qml`/`SettingControl.qml`
- `docs/specs/04-design-system.md` §3 and §5 (Settings rows), §7 (accessibility); `shell/PATTERNS.md` (settings rows); `docs/tasks/T-324-settings-my-profile-and-manage-profiles.md` Outcome

## Scope
1. **First focus skips disabled rows:** `SettingsPane.focusableRows()`/`settleFocus()` never choose a row with `enabled === false` (for example "Sleep is not available" before an enabled row); a pane whose rows are all disabled keeps focus on the pane and the hint bar says Back only. Same rule when the remembered row becomes disabled.
2. **The read-only row, written down:** add to `04` §5 (Settings rows) the pattern T-324 built, with no new component: "a read-only row is a `SettingRow` without `onActivated`; it takes focus (so the row is read by a screen reader and scrolled to), A does nothing, and while it holds focus the pane sets the hint bar to `B Back`". Add its accessible-name rule to §7 (name = label + value). Point `MyProfilePane.qml` and the rows of T-293 (Sleep not available, Keeping awake, Bluetooth is off) at the same pattern if they differ. A flatter look for these rows is a design call, not part of this task (parked).
3. **Manage profiles:** the result message of an action (renamed, deleted, PIN set...) shows directly under the profile list, visible while the Add form is open (scroll it into view or place it above the form); Guest gets one line saying what it is ("Guest: no saved data, always available" or the spec's wording; check `02`) instead of an empty row.
4. Strings via `qsTr()`, Turkish translated.

## Out of scope
- A flatter or muted style for info rows (needs a design token, `04` §8: Inbox line), auto-reflow of unlaid columns (T-288), the last-admin guard (defence in depth, unreachable from the UI).

## Acceptance criteria
- [ ] `tst_settings.qml::test_first_focus_skips_disabled_rows`, `::test_all_rows_disabled_keeps_focus_on_the_pane`, `::test_focus_moves_off_a_row_that_becomes_disabled` (revert: drop the `enabled` check, the first goes red).
- [ ] `tst_profile_admin.qml::test_result_message_is_visible_with_the_add_form_open` (the message item's `y` plus `height` within the visible area of the pane), `::test_guest_has_a_line`; `tst_settings.qml::test_read_only_row_shows_back_only_hint` (the identity row and one T-293 row).
- [ ] `04` §5 and §7 carry the rule (`scripts/lint-spec-components.ps1` stays green; no new component).
- [ ] Screenshots (`dev.ps1 shots`): Manage profiles with the Add form open and a result message, English and Turkish; read against `04` §8.
- [ ] UX: from every new state Back leaves; focus lands sensibly after open/close/error; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/04-design-system.md` §5, §7; `docs/specs/02-shell.md` (Manage profiles); `shell/PATTERNS.md` if the read-only row becomes a copyable recipe.

## Hints
- Overlaps T-288 (it also edits `SettingsPane.qml` for the reflow): run after it or merge carefully; this task changes `settleFocus` only.
- Per-pane `reflow()` flakes show only in real-window shots; do not "fix" them here.

## Outcome
_Filled in by the implementer._
