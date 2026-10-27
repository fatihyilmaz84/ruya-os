# T-131 — Settings → Profiles: rename and delete a profile

Status: done · Phase: 2 · Depends: T-118, T-105 · Area: shell · Size: M

## Goal
From Settings → Profiles an admin can rename any profile and delete any other profile; a standard profile can rename itself. Each action is confirmed with the actor's PIN, and the list updates at once. Verified against the mock on the host and against the real `ruya-profiles` in the VM.

## Read first
- `docs/specs/03-services-and-apps.md` §1.1 (rename/delete rules, "UI flows (as built, T-105)")
- `api/dbus/org.ruyaos.Profiles1.xml` (`RenameProfile`, `DeleteProfile`, status strings)
- `shell/qml/ProfilesPane.qml`, `ProfileAddFlow.qml`, `ChangePinFlow.qml`, `ProfileStatus.qml`, `PowerConfirm.qml` (the confirm pattern), `PinPad.qml` collect modes
- `shell/src/profiles/Profiles.{h,cpp}` (`renameProfile`, `deleteProfile` facade from T-118), `MockProfilesBackend.cpp`
- `shell/tests/tst_profile_admin.qml` (existing tests; copy their style)
- `shell/PATTERNS.md` ("Modals from pages"), `shell/CLAUDE.md` (focus rules, translations)
- `docs/dev-setup.md` "Seeing and driving the VM", `scripts/vm-profiles-check.sh`

## Scope
1. **Selecting a profile.** Accept on a profile row opens its actions (an inline row of choices under it, or a small menu; follow what `ProfilesPane` already does for its other actions): **Rename** (admin, or the profile itself) and **Delete** (admin only, never on the active profile, never on the last admin; hide the choice when the rule forbids it, and still map a `not-allowed` reply to its message).
2. **Rename:** `TextEntry` pre-filled with the current name → the actor's PIN (skip the pad when the actor has no PIN, as `SetPin` flows do) → `renameProfile`. The list shows the new name without a restart.
3. **Delete:** a confirmation that says plainly what happens ("Delete <name>? Their saved data and settings are removed. This can't be undone.", `PowerConfirm`-style, focus on **Cancel** by default) → admin PIN → `deleteProfile`. Focus then goes to the row that took the deleted one's place (or the previous row at the end of the list).
4. Every reply status goes through the existing single status-to-text mapping (`ProfileStatus`), including `wrong-pin` counts and `locked-out` seconds from the reply.

## Out of scope
- Creating extra admins (owner decision "one admin or several" is open), avatars, a "keep data" option (the service has none), Guest handling beyond hiding Rename/Delete for the Guest entry if the list shows one.

## Acceptance criteria
- [ ] Admin renames a standard profile by keys only; the list shows the new name and focus stays on that row (test `tst_profile_admin.qml::test_rename_other`).
- [ ] A standard profile renames itself with its own PIN; it sees no Delete (test `test_rename_self_standard`).
- [ ] Delete: Cancel is focused first and Cancel changes nothing; confirm + admin PIN removes the row and focus lands as in scope item 3 (tests `test_delete_cancel`, `test_delete_confirm`).
- [ ] Delete is not offered for the active profile or the last admin (test `test_delete_not_offered`); a wrong admin PIN shows the attempts-left message (test `test_delete_wrong_pin`).
- [ ] New strings translated (Turkish entries added, translation lint green).
- [ ] Screenshot `24-profile-delete-confirm.png` shows the confirmation with the focus ring on Cancel; reviewed.
- [ ] **VM** (image from this commit, `smoke-test.ps1 -Keep`): rename and delete a profile through the running shell by keys (`vm-keys.ps1`), then `vm-profiles-check.sh state` shows the new name, the deleted profile gone, and its `ruya-p*` user and home removed (output and a `vm-screenshot.ps1` image in the Outcome). This is the first runtime check of `DBusProfilesBackend::renameProfile/deleteProfile`.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
# WSL: scripts/build.sh, make-disk.sh qcow2; then smoke-test.ps1 -Keep and the VM drive scripts
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §1.1 ("UI flows": add rename and delete; drop "the UI comes later").

## Hints
- The mock already mirrors the service's rename/delete rules (`test_mock_lifecycle_rules_match_service`); don't re-implement them in QML.
- `tryCompare` on a list's `length` polls a frozen copy (`shell/CLAUDE.md`); use `tryVerify(() => ...)`.
- In the VM, create the profile to delete first with `vm-profiles-check.sh create` (it makes a standard profile over the bus), so the shell has something to delete.

## Outcome
**Built.** Accept on a profile row selects it and shows two rows after the list (`rowRename`, `rowDelete`, labelled with the name). Rename: `TextEntry` pre-filled -> actor PIN (skipped without a PIN) -> `renameProfile`. Delete: `PowerConfirm` in a new `custom` mode (title and detail set by the caller; Cancel focused first) -> admin PIN -> `deleteProfile`. The flow is `qml/ProfileManageFlow.qml`; the pane (`qml/ProfilesPane.qml`) owns the rows, a second `TextEntry` for rename (the add form's entry writes `newName`), and the post-reply focus (`pendingFocus`, applied once the list shows the outcome, so reply and list may arrive in either order). Rules hidden in the UI: no Rename/Delete for the Guest entry; Delete not for the active profile or the last admin; Rename only for admins or the profile itself. Statuses go through `ProfileStatus`.

**Files.** `shell/qml/ProfileManageFlow.qml` (new, in CMake), `ProfilesPane.qml`, `PowerConfirm.qml`, `tests/tst_profile_admin.qml`, `i18n/*.ts` (Turkish added), `docs/specs/03-services-and-apps.md` §1.1.

**Verified (host).** `dev.ps1 test` ALL GREEN (144 passed); `shots` ALL GREEN (156). New tests: `test_rename_other`, `test_rename_self_standard`, `test_delete_cancel`, `test_delete_confirm`, `test_delete_not_offered`, `test_delete_wrong_pin`, plus `test_zz_screenshots_delete` (`24-profile-delete-confirm.png`, focus ring on Cancel, reviewed).

**Unverified: the VM criterion.** Not run. Image builds failed three times because the Fedora WSL `ext4` disk remounts read-only (`ext4_dirblock_csum_verify ... Directory block failed checksum`, then `Aborting journal`), so no image with this commit exists. Whether `DBusProfilesBackend::renameProfile/deleteProfile` work at runtime is therefore still unknown. See the Inbox.

**Deviations.** The action rows sit after the whole list, not directly under the selected row (rows are siblings in the pane's column). Guest entries get neither action (the task allowed this). The screenshot test is a separate `test_zz_screenshots_delete`.
