# T-333 - Settings > Storage > "Format drive...": choose, confirm, PIN, progress, result

Status: todo · Phase: 2 · Depends: T-331, T-332 · Area: shell (StoragePane, a format flow, mock) · Size: M · Owner: builder

## Goal
A player formats a USB stick from the couch: Settings > Storage > the drive > "Format drive...", picks a filesystem (one is recommended), optionally names it, sees exactly what will be lost, confirms with a button that names the action, enters the admin PIN if there is one, waits with a clear "do not remove" message and gets a plain result. A failed format says why and leaves the drive unmounted.

## Read first
- `docs/tasks/T-332-format-removable-drive-service.md` (the contract and statuses), `docs/tasks/T-331-removable-drive-recognised-data-scan.md` (the scan the "lost data" line uses)
- `docs/specs/04-design-system.md` §3, §5 (confirmation dialog, list rows, modal), §7 (accessible names), §8; `shell/PATTERNS.md` (modals, settings rows, text input)
- `shell/qml/PowerConfirm.qml` (T-194: the confirm button is the action, `customConfirmName`), `ProfileManageFlow.qml` (a flow with a confirm), `SystemPane.qml` (the rollback asks the admin PIN with `Profiles.verifyAdmin`; admin-only rows), `ModalLayer.qml`, `TextEntry.qml`, `StoragePane.qml`
- New components allowed: none (a progress modal uses the existing modal and busy indicator; a missing one is an Inbox line, `04` §8)

## Scope
1. **Entry:** a "Format drive..." row below the Eject row of each removable volume (one per drive when it has several partitions: it formats the whole drive and says so). Shown to admins; for other profiles the row is absent with the reason in the pane's hint ("Only an admin can format a drive") - copy how `SystemPane` treats admin-only rows. Not shown for a volume the service reports as not formattable.
2. **Choose:** a page/modal listing `Storage.formatOptions` (name + one plain line each: exFAT "Works on Windows, Mac and this console" (recommended), ext4 "Only for this console and Linux", FAT32 "Works everywhere; files up to 4 GB", NTFS "For Windows; slow on this console"), a Name row (on-screen keyboard through `TextEntry`, default = the current label or "RuyaOS", the filesystem's limit enforced), an Erase row (Quick / Full "can take hours"), and "Continue". Back leaves without a change.
3. **Confirm:** `PowerConfirm` with the confirm button "Erase and format <drive name>" (long names elide, `Accessible.name` equals the text), Cancel is the default focus; the detail line shows the size and what will be lost: from the scan "12 GB of games, 2 GB of backups and 3 GB of other files" (or "Checking what is on this drive..." while the scan runs, or just the used size if there is no scan), and that it cannot be undone.
4. **PIN:** if the active admin has a PIN, ask it with the existing PIN pad flow (`Profiles.verifyAdmin` pattern); a wrong PIN shows the attempts left inline and stays on the pad; a lock-out shows the wait. The PIN is passed to `Storage.format` and never stored or logged.
5. **Progress:** a modal "Formatting <name>..." with the busy indicator, elapsed time, and the line "Do not remove the drive. This cannot be stopped." Back does nothing while it runs (the hint bar says so); the screen saver and sleep rules are unchanged. If the drive disappears the modal ends in the failure result.
6. **Result:** success: a toast "<name> is ready" and the pane shows the new volume; focus lands on the new drive's row. Failure: a dialog with the reason by status (`busy` "Something is using this drive. Close it and try again", `changed` "This is a different drive than the one you chose. Nothing was changed", `wrong-pin`, `locked-out`, `not-removable` "This drive cannot be formatted", default "The drive could not be formatted. It was not mounted again"); OK returns to the Storage pane with focus on the drive.
7. **Mock and tests:** use T-332's mock hooks; Turkish and English strings; `docs/specs/02-shell.md` (Storage pane) updated.

## Out of scope
- Anything service-side (T-332), partition editing, "format the console's own storage", a progress percentage, formatting several drives at once, a Store "Install from USB" shortcut (T-236).

## Acceptance criteria
- [ ] `tst_storage_format.qml`: `test_row_only_for_admins`, `test_options_listed_with_recommended_first`, `test_name_limit_per_filesystem`, `test_confirm_button_names_the_action_and_matches_accessible_name`, `test_detail_shows_lost_data_from_the_scan` (and the "checking" and "no scan" variants), `test_pin_asked_only_when_the_admin_has_one`, `test_wrong_pin_stays_on_pad`, `test_back_does_nothing_while_formatting`, `test_result_success_focus_on_new_drive`, one test per failure status text, `test_cancel_at_every_step_changes_nothing` (the mock records no `format` call). Each names the revert that turns it red (for example: confirm text back to "Confirm").
- [ ] Geometry test at the real dialog size for the longest Turkish drive name and the longest detail line (no overflow, the button elides).
- [ ] Screenshots (`dev.ps1 shots`): choose page, confirm dialog with lost data, progress, failure dialog; English and Turkish; read against `04` §8.
- [ ] UX: from every new state Back leaves (except while formatting, with the hint saying why); focus lands sensibly after open/close/error; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] VM (lead run): with the real service, `scripts/vm-goto.ps1` (or the shell's own test hook) drives the flow on the VM's virtual USB disk once: the stick ends exFAT and mounted. Outcome `Verified: host (vm pending: vm-storage-check.sh fmtservice, one VM screenshot of the confirm dialog)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` (Settings > Storage), `docs/specs/04-design-system.md` §5 only if a component is used in a new way, `shell/PATTERNS.md` if the flow is a reusable pattern.

## Hints
- Copy the flow structure of `ProfileManageFlow.qml` (steps in one component, Back per step) and the PIN handling of `SystemPane.qml` rollback.
- The "recognised data" text uses the category names of T-331; if the scan is `partial` say "at least".
- Depends on T-332 only through the mock until the service lands; keep the mock honest (same statuses, a delay) so the flow is tested against realistic timing.

## Outcome
_Filled in by the implementer._
