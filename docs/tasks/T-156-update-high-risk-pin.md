# T-156 — Admin PIN before an app update that adds a high-risk permission

Status: done · Phase: 3 · Depends: T-152 · Area: api, services, shell · Size: M · Owner: builder

## Goal
A Standard profile can't widen an installed app's access by updating it: if the new version asks for a high-risk permission the installed one doesn't have, Update asks for an admin's PIN, as Install does since T-152.

## Read first
- `docs/specs/03-services-and-apps.md` §4.4 (permissions, the T-152 gate; today "Update is not gated")
- `api/dbus/org.ruyaos.Store1.xml` (`permissions`, `GetApp`, `Update`)
- `services/ruya-store/src/appstream.rs` `permissions()`, `flatpak_cli.rs` (the `remote-info` / `info --show-metadata` fallback), `service.rs` `get_app`
- `shell/qml/AppDetailPage.qml` (`highRisk`, `needsAdminPin`, the PIN step), `shell/tests/tst_store_admin.qml`
- UI: `04-design-system.md` §5 (Badge, the note under the permissions); new tokens or components: none

## Scope
1. **Service:** for an installed app with an update, `GetApp` also reads the installed version's metadata (`flatpak info --system --show-metadata`) and reports the permissions the update adds (for example `new_permissions as`, empty when none or no update). Pure diff function in the core with unit tests. Extend the XML first.
2. **Mock and D-Bus client** carry the field; the mock gets one installed app whose update adds `all-devices`.
3. **Shell:** `needsAdminPin` also holds for Update when a new permission is high-risk and the profile isn't an admin; the note under the permissions says which permission is new ("The update adds: Accesses all devices"). Same PIN flow as Install (`Profiles.verifyAdmin`), same wrong-PIN behaviour.
4. Turkish for the new strings; spec 03 §4.4 updated.

## Out of scope
- Gating ordinary updates, or "Update all" (none exists yet).
- Changing which permissions count as high-risk.

## Acceptance criteria
- [ ] Diff: added high-risk, added harmless, removed, unchanged (Rust tests).
- [ ] Standard profile: Update of the mock app opens the PIN pad; a wrong PIN starts no job; a right one starts `Update` (QML tests, focus asserted on the pad and back on the button).
- [ ] Admin profile: Update starts at once (QML test).
- [ ] An update without new permissions is not gated (QML test).
- [ ] Screenshot of the detail page with the "update adds" note, reviewed.
- [ ] VM: image built, `RUYA_BOOT_OK`, `scripts/vm-store-check.sh` ALL PASSED and extended to assert `GetApp` returns the new field (empty for an ordinary installed app). Building a real update that adds a permission is **unverified** unless done with a local repo; say which.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```
Then the image recipe in `docs/dev-setup.md` and `vm-store-check.sh`.

## Docs to update
- `docs/specs/03-services-and-apps.md` §4.4, the Store1 XML header.

## Outcome
Verified: vm for the service and the contract (image `0.0.23-t156` booted with `RUYA_BOOT_OK`; `vm-store-check.sh` ALL CHECKS PASSED, 43 checks, now including `GetApp` returning an empty `new_permissions`); host for the shell (`dev.ps1 test` ALL GREEN, 247 QML tests and 46 in the store crate; `shots` ALL GREEN, `56-store-update-adds.png` reviewed). **Unverified:** a real update that adds a permission (no local repo with two versions was built), and the shell's `GetApp` client against the real bus (written as a thin translation of the XML; the VM check calls `GetApp` with `busctl`, not through the shell).

What was built:
- **Contract:** App record key `new_permissions as` (what the update adds; empty without an update; only `GetApp` fills it); `GetApp` doc says the shell calls it when an app page opens.
- **Service:** `appstream::added_permissions` (pure, tested), `Flatpak::installed_metadata` (`flatpak info --system --show-metadata`), `Store::get_app` compares the installed version with the remote's metadata, read again each time for an app with an update (the cache could hide a newer version that asks for more; a test covers it). An unreadable installed version counts as having no permissions, so everything the update asks for is reported (fail closed). An unreadable remote reports nothing new. 6 new Rust tests.
- **Shell:** `AppInfo.newPermissions`, `StoreBackend::getApp` (D-Bus client and mock), `Store.loadApp` with `appLoaded`/`appLoadFailed`. The Store keeps what each update adds across search refreshes and drops it when the update flag goes. `AppDetailPage`: `needsAdminPin` also holds for Update when an added permission is high-risk, the note "The update adds: ..." (`detailUpdateAdds`) and the PIN note for updates, the same PIN flow as Install. Turkish added.
- **Mock:** Open Chess's update adds `all-devices`; Text Editor now has an update that adds nothing (used by the not-gated test). The lists carry no `newPermissions`, as the service.
- **Tests:** `tst_store_ui` (wrong PIN, right PIN, Back, update that adds nothing, screenshot function), `tst_store_admin` (admin updates directly), `openApp` waits for `detailsReady`.

Deviation, needed to make the gate work over the real bus: the shell never called `GetApp`, so a record from `Search` has no permissions until something reads them. The T-152 Install gate therefore could not fire against the real service either. The page now calls `Store.loadApp` when it opens, and a press of Install/Update before the answer is queued until it arrives (a failed read retries on the next press), so the gate is never skipped. On the mock this is invisible.

Files: `api/dbus/org.ruyaos.Store1.xml`, `services/ruya-store/src/{app,appstream,flatpak,flatpak_cli,service,dbus}.rs`, `shell/src/store/*`, `shell/qml/AppDetailPage.qml`, `shell/tests/tst_store_ui.qml`, `tst_store_admin.qml`, `shell/i18n/*.ts`, `scripts/vm-store-check.sh`, `docs/specs/03-services-and-apps.md` §4.4, `docs/dev-setup.md`.
