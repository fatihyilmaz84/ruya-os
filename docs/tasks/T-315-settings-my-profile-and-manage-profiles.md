# T-315 — Settings: "My profile" and "Manage profiles" are two categories

Status: in-progress · Phase: 2 · Depends: — · Area: shell (SettingsPage, ProfilesPane, a new pane, tests, spec 02 and 03 §1.1) · Size: M · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
