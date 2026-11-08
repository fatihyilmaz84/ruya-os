# T-324 — Settings: "My profile" and "Manage profiles" are two categories

> Renumbered 2026-11-08: called T-315 in its commits and in the shell/spec comments (`MyProfilePane`, `ManageProfilesPane`), until the RetroAchievements spike took T-315.

Status: done · Phase: 2 · Depends: — · Area: shell (SettingsPage, ProfilesPane, a new pane, tests, spec 02 and 03 §1.1) · Size: M · Owner: builder

## Goal
The owner (2026-11-08) wants user management and a person's own profile options kept apart in Settings. Today **Settings -> Profiles** is one pane that mixes both: the list of every profile with Rename and Delete for the selected one, the admin's Add profile form, and the signed-in person's own PIN rows plus the Activity row. After this task there are two categories:

- **My profile** (every signed-in profile, guest included where it applies): who I am (name and role, read-only here), **Set / Change / Remove my PIN**, **Rename me** (if the profile may rename itself today), **Activity**; the place where profile customisation (T-210: avatar, colour) and the parental limits view (T-212) will land.
- **Manage profiles** (admins only): the list of all profiles, **Add profile**, **Rename / Delete** another profile, and where roles and parental controls (T-211/T-212) will be set. For a non-admin the category is not listed (not greyed out).

## Read first
- `shell/qml/ProfilesPane.qml` (391 lines: the profile list, `rowRename`, `rowDelete`, `rowAdd` form, `rowChangePin`, `rowRemovePin`, flows `ProfileAddFlow`, `ProfileManageFlow`), `shell/qml/SettingsPage.qml` (category list near line 17, the `currentPane` switch near line 37, the pane at ~line 162)
- `docs/specs/02-shell.md` Settings section (the category list; "Profiles (T-105)"; "Activity (T-247)": the Activity row moves to My profile); `docs/specs/03-services-and-apps.md` §1.1 "UI flows"; `shell/PATTERNS.md` (settings rows, panes, modals)
- Tests that name the Profiles pane: `grep -rn "profiles" shell/tests` (tst_profiles, tst_settings, tst_navigation, screenshots)

## Scope
1. **Two panes, one component each.** `MyProfilePane.qml` and `ManageProfilesPane.qml` (split `ProfilesPane.qml`; share the flows and helper properties through the existing flow components, no copy-paste; delete `ProfilesPane.qml` when empty). New files go in `shell/CMakeLists.txt` and are named in `04-design-system.md` (lint-spec-components).
2. **Categories.** `SettingsPage` lists "My profile" first and "Manage profiles" second (admins only, hidden otherwise; the hidden category is skipped by Up/Down and by the nav keys). Keys: `myprofile` and `profiles` (keep `profiles` for Manage so existing deep links such as `vm-goto.ps1 settings-profiles` and the first-boot flow still land on the list). Update every place that names the old pane (setup, deep links, tests, screenshots).
3. **Focus and Back** as before: entering a pane lands on its first row; Back leaves the pane to the category list; after Add/Delete/Rename/PIN flows focus returns to the row it came from. If the admin deletes the signed-in profile's neighbour, the list keeps a sensible focus; deleting oneself stays impossible as today.
4. **Copy and translations** (en and tr): "My profile" / "Profilim", "Manage profiles" / "Profilleri yönet". Existing row labels keep their strings so translations are reused.
5. **Specs:** 02 (category list, panes), 03 §1.1 UI flows, `docs/dev-setup.md` if `vm-goto` targets change.

## Out of scope
- New profile features (avatar, colour, roles change, parental controls: T-210/T-211/T-212), changing the profile model or the service, the guest profile's behaviour.

## Acceptance criteria
- [ ] Settings shows "My profile" for everyone and "Manage profiles" only for an admin (test as admin, standard, guest).
- [ ] Every row of the old pane is in exactly one new pane: PIN rows, Activity, Rename-me in My profile; the list, Add profile, Rename/Delete in Manage profiles (a test lists the rows of each pane).
- [ ] Non-admin cannot reach Manage profiles by any key path (test), and a profile switched to a standard one while the pane is open leaves it cleanly (focus lands on the category list).
- [ ] Back, focus after each flow and the first-boot path still work (existing tests adapted, none weakened; say which ones changed and why in the Outcome).
- [ ] Screenshots of both panes at 1080p (admin) and of the category list for a standard profile, reviewed.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN, `shots` ALL GREEN; 02, 03 and 04 updated.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md`, `docs/specs/03-services-and-apps.md` §1.1, `docs/specs/04-design-system.md` (component names), `docs/dev-setup.md` (`vm-goto` targets if they change).

## Hints
- If the owner meant a different split (for example a separate "Users" top-level for admin tools only), the same two panes still hold: only the names and the visibility rule change. Do not ask; implement this reading and record it in the Outcome.
- Overlaps T-285 (hint bar), T-210/T-212 (they add rows here later): leave a clear place for them.

## Outcome
Verified: host

Settings has two categories where there was one. **My profile** (`myprofile`, first, everyone) and **Manage profiles** (`profiles`, second, admins only, not in the list at all for anyone else).

Built:
- `ProfilePaneBase.qml` (a `SettingsPane`) holds what the two panes share: `me`/`isAdmin`, the PIN pad, name keyboard and delete confirmation in the shell's modal layer, the `ProfileManageFlow`, the result message and the focus return after a modal (`restoreFocus`/`keepFocus`, with a per-pane `fallbackRow`). The modals take their objectNames from `namePrefix`, so the two live panes never share one (`profilesPinPad` / `myProfilePinPad`, `profilesRenameEntry` / `myProfileRenameEntry`, `profilesDeleteConfirm` / `myProfileDeleteConfirm`).
- `MyProfilePane.qml`: `rowWho` (swatch, name, "Admin / Standard / Guest" and "PIN"; read-only), `rowRenameMe` (admin and standard), `rowChangePin` ("Set a PIN" / "Change my PIN"), `rowRemovePin` (standard with a PIN), `rowActivity`. Guest: `rowWho` and `rowActivity` only. Rename of oneself uses the existing flow (keyboard, then the actor's PIN if there is one), and focus returns to Rename once the list shows the new name.
- `ManageProfilesPane.qml`: the profile list, Rename / Delete of the selected profile, Add profile with its form. Reading of the task: "Rename / Delete another profile", so selecting your own row shows neither and the pane says "Your own profile is under My profile." (new string, translated). Delete rules (not the last admin, not a guest) are unchanged.
- `SettingsPage`: `categories` is assigned, not bound, and only `refreshCategories()` rebuilds it (on open, and when the signed-in profile becomes or stops being an admin). The selected category stays selected by key; if the focus was in the vanished Manage pane it goes to the category list, which then shows My profile. `current` falls back to the first entry so a bound read never sees an out-of-range index. `params.category` "profiles" lands on Manage for an admin and on My profile for anyone else.
- `ProfilesPane.qml` deleted. Translations: "My profile" / "Profilim", "Manage profiles" / "Profilleri yönet", "Your own profile is under My profile." / "Kendi profiliniz Profilim bölümünde."; the old ProfilesPane context was removed from both .ts files, the shared labels were reused. `scripts/vm-goto.ps1` gains `settings-myprofile`; `settings-profiles` and the targets after it get one more Down (the VM profile is an admin); `settings-system` was one Down short of System since Power saving was added, now correct. Specs 02, 03 §1.1, 04 (row "Profile panes"), `docs/dev-setup.md`, `shell/PATTERNS.md` updated; `ProfilesPane.qml` left the spec lint baseline.

Where later tasks land (also in the pane headers and spec 02): T-210 rows (avatar, colour) in My profile between Rename and the PIN rows; T-212 limits view in My profile after the PIN rows; T-211 roles and T-212 parental controls in Manage profiles beside Rename / Delete.

Tests (existing ones adapted, none weakened):
- `tst_profile_admin`: `openProfilesPane` now goes Down to Manage profiles; new `openMyProfilePane`; the PIN-change, remove-PIN and rename-self tests (standard profile Ada) now run in My profile with `myProfile*` names; `test_add_hidden_for_standard` became "Manage profiles is not listed for a standard profile" plus the My profile rows and the skipped hidden rows; `test_admin_cannot_remove_pin` checks My profile; `test_delete_not_offered` selects the own row and expects no Rename/Delete plus the message (own rename moved to My profile); `profileRenameEntry`/`profileDeleteConfirm` renamed to `profilesRenameEntry`/`profilesDeleteConfirm`.
- `tst_settings` (pane names after the split), `tst_hints` (the pane with the hints is My profile), `tst_activity` (Activity is in My profile), `tst_accessibility` (an admin reaches Manage profiles with one more Down; renamed modals), `tst_glide_settings` (a standard profile's first category is `category_myprofile`), `tst_plain_text` (the hostile name is checked in My profile for Ada, and a new test checks Manage profiles as an admin), `tst_timezone`, `tst_update`, `tst_i18n` (select System by its key; an admin has one category more, the fixed index 8 would have been Power saving).
- New in `tst_profile_admin`: categories for admin (11, order), standard (10, no Manage) and guest (rows of My profile); a test that lists the rows of each pane (My profile and Manage profiles, each row in exactly one); Manage unreachable for a standard profile (Up/Down over every category, Right, deep link `profiles` lands on My profile); the admin deep link; a profile switched to a standard one while Manage is open leaves it (focus on the category list, My profile shown, enterable); the selected category stays selected when the list shrinks; rename of oneself as admin in My profile with focus return; Back from each pane to the category list; two screenshot tests.

Checks: `dev.ps1 test` ALL GREEN (930 QML passed, 73 skips = screenshot tests, 705 Rust); `dev.ps1 shots` ALL GREEN. Screenshots read: `output/shell-shots/review/11-settings-my-profile.png` (admin), `10-settings-profiles.png` (Manage profiles with the add form), `12-settings-categories-standard.png` (standard profile: no Manage profiles; list starts My profile, Network, ...). The delete confirmation (24) was re-shot unchanged.

Revert checks (`revert-check.ps1 -Test tst_profile_admin`): all four caught (tests failed, file restored and rebuilt). (1) `SettingsPage`: `if (withManage)` -> `if (true)` (Manage profiles listed for everyone): six tests failed (standard, guest, key paths, role switches). (2) `SettingsPage`: `if (hadPaneFocus && current.key !== key)` -> `if (false)` (no `leavePane()` after the role change): `test_role_switch_while_manage_is_open_leaves_it` failed on "focus lands on the category list". (3) `ManageProfilesPane`: `other` without `selectedId !== Profiles.activeProfile` (Rename for your own row in Manage): `test_delete_not_offered` failed. (4) `MyProfilePane`: `canRename: true`: `test_guest_has_a_small_my_profile` failed (a guest was offered Rename).

UX notes: states reached: category list (focus on My profile), My profile pane (focus on the identity row; Back or Left to the list), Manage profiles pane (focus on the first profile row; Back to the list), the modals (PIN pad, keyboard, delete confirmation) with Back returning focus to the row they came from (Add, Delete, Rename, Change PIN all tested), selecting your own row in Manage (message, focus stays). The identity row is focusable and read-only (a `SettingRow` without a handler), so the pane opens on it; I doubted whether a focusable row that does nothing is right, but there is no non-focusable info row in the design system (inbox line). Not verified on a controller or in the VM.

Inbox (also in the HANDOFF): a non-focusable read-only info row in the design system would suit the identity row; the "Rename <name>" row of My profile repeats the name already shown in the row above.

### Round 2 (review findings)
- **Hints on the identity row.** `MyProfilePane.hints` shows `B Back` only while `rowWho` has focus (A does nothing there) and `A Select | B Back` on every other row, the `AboutPane` pattern (04 Settings pane rule). `tst_hints.test_panes_supply_their_own_hints` now asserts `B Back` on `rowWho` (both the shown hints and the pane's) and `A Select|B Back` after Down to `rowRenameMe`; it had locked in the wrong behaviour. Revert check: `hints: whoRow.activeFocus ?` -> `hints: false ?` makes that test fail. Translations: "Select" and "Back" got entries for the MyProfilePane context (en copy, tr "Seç" / "Geri", reused).
- **Layout flake found by the re-shot.** With the hints binding the real-window screenshot of My profile showed only the first row (the column unlaid and the viewport one row high, the case `SettingsPane.reflow` documents); offscreen it was fine and the first-round shot had been fine, so it is timing. `MyProfilePane` now calls `reflow()` (via `Qt.callLater`) on completion and when the signed-in profile or its role changes; the re-shot shows all four rows and the `B Back` bar (`11-settings-my-profile.png`, read).
- **PATTERNS.md:46** now points to `ProfilePaneBase.qml`.
- **Last-admin guard.** New `test_second_admin_is_deletable_in_manage`: a second admin created through the mock is offered Delete in Manage (admin A signed in) and the delete goes through (confirmation, PIN, row gone); afterwards the signed-in admin's own row offers no Delete. Honest note: the `adminCount <= 1` clause of `canDelete` can no longer be reached from the UI (the only admin who can open Manage is the signed-in one, who is never offered Delete for themselves), so no UI test can fail it; the service and the mock still enforce it and `test_delete_rules` (mock level, last admin refused) covers that. I kept the clause as defence in depth rather than remove behaviour not asked for. The test fails if Delete is wrongly hidden for another admin; it does not exercise the dead clause.
- Checks: `test` ALL GREEN (931 QML + 73 skips, 705 Rust), `shots` ALL GREEN (the first shots run of this round hit `TEST WINDOW LOST ACTIVATION` in ArtGlow and was re-run, per the rule).

