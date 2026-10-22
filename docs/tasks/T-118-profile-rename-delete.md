# T-118 — Profiles1: RenameProfile and DeleteProfile (contract, service, mock, shell backend)

Status: todo · Phase: 2 · Depends: T-115 · Area: api, services, shell · Size: M

## Goal
An admin can rename and delete profiles through `org.ruyaos.Profiles1`, with the safety rules enforced by the service, and the mock and the shell backend follow the same contract. This task has no UI: the Settings → Profiles screens for it come from a later planning session, once this lands.

## Read first
- `docs/specs/03-services-and-apps.md` §1.1 (model: one Unix user per profile, ids never reused, admin-only actions include create/delete profiles) and §1.2
- `api/dbus/org.ruyaos.Profiles1.xml` and `docs/tasks/T-115-profiles-attempts-in-replies.md` (the reply shape: status, attempts_left, retry_after_secs)
- `services/ruya-profiles/src/{service,store,accounts,dbus}.rs` and `services/CLAUDE.md`
- `shell/src/profiles/` (`MockProfilesBackend` mirrors `service.rs`; copy that approach) and `docs/tasks/T-105-profile-management.md` Outcome

## Scope
1. **Contract first** (`Profiles1.xml`):
   - `RenameProfile(actor_id, actor_pin, id, name) → (status, attempts_left, retry_after_secs)`. The actor must be an admin or the profile itself; the name follows the same rules as create (trimmed, 1–32 characters, no control characters).
   - `DeleteProfile(admin_id, admin_pin, id) → (status, attempts_left, retry_after_secs)`. Admin only. Refused with `not-allowed` for: the last remaining admin, and the currently active profile. Unknown id → `unknown-profile`.
   - Reuse the existing status strings; document the rules in the header.
2. **Service core** (`service.rs`, `store.rs`, `accounts.rs`): implement both with the shared `authenticate()` (so failures count towards the one lockout counter). `Accounts` gains `remove(profile_id)`; `NoAccounts` is a no-op, the Linux implementation runs `userdel --remove` (**unverified on this host**). Deleting also drops the profile's lockout state. Ids are never reused (a profile created after a delete gets a fresh id). The store write stays atomic; if removing the Unix user fails, report `failed` and leave the store unchanged.
3. **D-Bus adapter** (`dbus.rs`): thin wrappers that emit `ProfilesChanged` on success (and `ActiveProfile` changes nothing here, since the active profile cannot be deleted).
4. **Mock** (`MockProfilesBackend`) mirrors every rule above, including the shared lockout. **Backend interface, `DBusProfilesBackend` and the `Profiles` facade** get `renameProfile(...)` / `deleteProfile(...)` with result signals shaped like `createFinished`.
5. Docs: spec 03 §1.1 lists the two methods and their rules.

## Out of scope
- Any QML UI, including confirmation dialogs (next planning session).
- Creating additional admins or changing roles. The overview's MVP says "one admin"; see "Open owner decisions" in `docs/STATUS.md`.
- Deleting data selectively (a deleted profile loses its home directory; there is no "keep data" option).

## Acceptance criteria
- [ ] Rename: blank, over-long and control-character names are `invalid`; a non-admin renaming someone else is `not-allowed`; renaming yourself works with your own PIN; a wrong PIN returns `wrong-pin` with attempts left; the name is stored trimmed (tests in `service.rs`).
- [ ] Delete: deleting the last admin, the active profile, or an unknown id is refused with the right status; a wrong admin PIN counts towards lockout; success removes the profile, calls `Accounts::remove` once (a recording fake in the test), and a profile created afterwards gets a never-used id; the change survives a restart (tests in `service.rs`).
- [ ] A failing `Accounts::remove` returns `failed` and the profile is still listed (test with a failing fake).
- [ ] The mock gives the same status for the same inputs (test `tst_profile_admin.qml::test_mock_lifecycle_rules_match_service`, mirroring the Rust cases).
- [ ] `.\scripts\dev.ps1 rust` and `.\scripts\dev.ps1 test` are green; the D-Bus client compiles and its method names match the XML (list them side by side in the Outcome).

## Verification
```powershell
.\scripts\dev.ps1 rust
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §1.1.
- `docs/STATUS.md`: `userdel` and the D-Bus runtime **unverified**.

## Hints
- Order the checks like `create_profile`: validate input, then actor rights, then authenticate, then act. Keep every rule in the pure core; `dbus.rs` stays thin.
- Add a `remove` method to `Store` rather than editing the list from outside.
- Never `unwrap()` on D-Bus-reachable paths (`services/CLAUDE.md`).

## Outcome
_Filled in by the implementer: what was built, files, how it was verified, deviations, follow-ups._
