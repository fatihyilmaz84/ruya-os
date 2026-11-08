# T-344 - Sound theme delete and confirm dialogs: handle a refused delete, test the guard, wrap long details

Status: todo · Phase: 2 · Depends: — · Area: shell (AudioPane, PowerConfirm and its callers, sound theme library) · Size: S · Owner: builder

## Goal
Findings of the T-294 reviews: deleting a sound theme while a copy is in progress silently resets the setting and deletes nothing, the path-traversal guard is tested only with ids whose `..` target does not exist, and `PowerConfirm` sizes its card from the title and buttons only, so a long detail line can overrun.

## Read first
- The Inbox line tagged T-294 in `docs/STATUS-parked.md`, "Inbox triage 2026-11-08 (lead-5)" (verbatim); `docs/tasks/T-294-*.md` Outcome
- `shell/qml/AudioPane.qml` (~line 304: `SoundThemes.removeTheme(deleteConfirm.pendingId)`), the sound theme library (`shell/src/sound/`: `removeTheme`, the id/path guard), `shell/qml/PowerConfirm.qml` (`detail`, card width), its callers `ProfileManageFlow.qml` (~line 53), `SystemPane.qml` (~line 271), `ActivityPage.qml` (~line 281)
- `docs/specs/04-design-system.md` §5 (confirmation dialog), §8; shell test tips in `shell/PATTERNS.md`

## Scope
1. `AudioPane`: `removeTheme` returns false when it deleted nothing (a copy in progress, a missing id, the active theme): the pane keeps the setting as it was, keeps the row, and shows a toast "Could not delete <name>" with the reason; the Delete row stays reachable.
2. Test the traversal guard with an id such as `../real-theme` where the target directory exists (a scratch fixture), asserting nothing outside the themes directory is removed.
3. `PowerConfirm`: the detail text wraps at the card width (one place, not per caller), and the card height follows; check the three callers' long details (Turkish and English, a long profile or app name) for overrun and fix the card, not the callers.
4. Shell test tip (T-294): keep fields taken from a `QVariantList` as strings (note in `shell/PATTERNS.md` if not there).

## Out of scope
- Value elision in `SettingControl` (parked), stored toast text keeping its language, a Delete row for themes other than the chosen one, T-284's dialog-card work (one dialog card for all confirms): if T-284 has started, do item 3 there instead and say so.

## Acceptance criteria
- [ ] `tst_audio.qml` (or the pane's test): `test_delete_refused_keeps_setting_and_row`, `test_delete_refused_shows_a_toast`, `test_traversal_id_with_an_existing_target_deletes_nothing` (revert: drop the guard, red).
- [ ] `tst_power.qml::test_long_detail_wraps_inside_the_card` at the real card size for each of the three callers' longest Turkish detail (geometry: detail bottom within the card, card inside the window).
- [ ] Screenshots (`dev.ps1 shots`): the confirm with a long detail, English and Turkish, read against `04` §8.
- [ ] UX: from every new state Back leaves; focus lands sensibly after open/close/error; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/04-design-system.md` §5 (the detail wraps), `shell/PATTERNS.md` (QVariantList tip).

## Hints
- Overlap: `PowerConfirm.qml` is also touched by T-284 (dialog card follow-ups) and T-333 (format confirm): take the order in `STATUS-backlog.md`.

## Outcome
_Filled in by the implementer._
