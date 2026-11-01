# T-156 — Admin PIN before an app update that adds a high-risk permission

Status: todo · Phase: 3 · Depends: T-152 · Area: api, services, shell · Size: M · Owner: builder

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
_Filled in by the implementer._
