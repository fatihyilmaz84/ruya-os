# T-118 — Profiles1: RenameProfile and DeleteProfile (contract, service, mock, shell backend)

Status: done · Phase: 2 · Depends: T-115, T-126 · Area: api, services, shell · Size: M

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
- [ ] In the VM (rebuilt image, `RUYA_BOOT_OK`): after `scripts/vm-profiles-check.sh create`, rename and delete the standard profile with `busctl` as root; `state` shows the new name, then no profile, no `ruya-p2` Unix user and the home handled as the Outcome describes (output in the Outcome). Extend the script with `rename`/`delete` modes if that is simpler. The unit is hardened since T-126: if `userdel` needs a capability the unit lacks, add it and say so.

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
**Built.** `RenameProfile` and `DeleteProfile` in the contract, the service core, the D-Bus adapter, the mock, and the shell backend interface, `DBusProfilesBackend` and `Profiles` facade (no UI).

- Contract: `api/dbus/org.ruyaos.Profiles1.xml` (both methods return `status, attempts_left, retry_after_secs`; rules in the comments).
- Service: `service.rs` (`rename_profile`, `delete_profile`), `store.rs` (`remove`, `restore`), `accounts.rs` (`Accounts::remove`; Linux runs `userdel --remove`, exit 6 "no such user" counts as removed), `dbus.rs` (thin wrappers, `ProfilesChanged` on success).
- Shell: `ProfilesBackend.h`, `MockProfilesBackend`, `DBusProfilesBackend`, `Profiles` (`renameProfile`/`deleteProfile`, signals `renameFinished`/`deleteFinished(id, status, attemptsLeft, retryAfterSecs)`).
- Docs: spec 03 §1.1; `scripts/vm-profiles-check.sh lifecycle`.

Method names, side by side (XML / Rust / D-Bus client): `RenameProfile` / `rename_profile` / `"RenameProfile"`; `DeleteProfile` / `delete_profile` / `"DeleteProfile"`; argument order `actor_id, actor_pin, id, name` and `admin_id, admin_pin, id`.

**Order of checks.** Rename: unknown id, name, actor rights, authenticate. Delete: unknown id, admin role, authenticate, then the last-admin / active-profile rule (so a wrong PIN counts before the rule is revealed). A successful PIN check resets the counter, as everywhere.

**Failure handling.** `Accounts::remove` runs before the store changes; if it fails the answer is `failed` and nothing changed. If the store write fails after the Unix user is gone, the profile is restored in memory and `failed` returned; the user is already deleted then (cannot be rolled back). Recorded as a known gap, not a task: the next start would list a profile whose user is missing.

**Verified.**
- host: `dev.ps1 rust` green (6 new service tests: rename rules, rename lockout, delete rules and effects with a recording fake, delete lockout, second admin deletable, failing fake leaves the profile); `dev.ps1 test` ALL GREEN, 133 QML tests including the new `tst_profile_admin.qml::test_mock_lifecycle_rules_match_service`.
- vm (image `0.0.9-t118`, fresh disk copy): `RUYA_BOOT_OK 0.0.9-t118`. After `vm-profiles-check.sh create` then `lifecycle`: `RenameProfile p1 1234 p2 "Renamed Kid"` -> `ok`, `ListProfiles` shows the new name; `DeleteProfile` of the last admin -> `not-allowed`; `DeleteProfile p2` -> `ok`; `ListProfiles` has only `p1`; `profiles.toml` keeps `next_id = 2` (so the next profile is `p3`); `getent passwd` shows only `ruya-p1`, `/var/home/ruya-p2` is gone (home removed by `userdel --remove`; the journal shows `userdel` removing the group, and a harmless "mail spool not found"); `/etc/passwd` 644, `/etc/shadow` 0. The hardened unit needed no extra capability for `userdel`.
- Not verified: the shell's `DBusProfilesBackend` calls (compiled in the image build, never exercised); no UI exists yet.

**Deviations.** None. The mock test asserts attempts-left 4 (not 3) in one place because a successful PIN check resets the counter, same as the service.
