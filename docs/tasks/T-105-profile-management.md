# T-105 — Manage profiles from Settings

Status: todo · Phase: 2 · Depends: T-103, T-104 · Area: shell · Size: M

## Goal
From Settings → Profiles, an admin can add a profile (name, role, optional PIN). Any profile can change its own PIN. Everything goes through `org.ruyaos.Profiles1`, using the existing contract.

## Read first
- `api/dbus/org.ruyaos.Profiles1.xml`: `CreateProfile` and `SetPin` exist; **do not change the contract**
- `services/ruya-profiles/src/service.rs`: the rules the UI must reflect (admin PIN required, guests have no PIN, admins must keep one)
- `shell/src/profiles/*`, `shell/qml/PinPad.qml`, `docs/specs/03-services-and-apps.md` §1

## Scope
1. Backend API, mirroring the XML:
   - add `createProfile(adminId, adminPin, name, role, pin)` and `setPin(id, oldPin, newPin)` to `ProfilesBackend`, `MockProfilesBackend`, `DBusProfilesBackend` and the `Profiles` facade;
   - add result signals `createFinished(status, id)` and `setPinFinished(id, status)`;
   - the mock enforces the **same rules** as `service.rs` (name 1–32 chars, role validity, PIN rules, admin check, shared lockout counter) and emits `profilesChanged` after a successful create.
2. `PinPad` gets modes:
   - `verify` (today's behaviour, calls `switchTo`);
   - `collect`: returns the entered PIN via a signal without calling any service;
   - `collect-confirm`: asks twice, and shows "PINs don't match" and restarts on mismatch.
   The existing behaviour and tests stay unchanged.
3. Settings → Profiles pane:
   - list the profiles (avatar, name, role, PIN yes/no);
   - "Add profile" row, visible only when the active profile is an admin: name via `TextEntry` → role via ChoiceRow (Standard/Guest) → "Set a PIN?" toggle → PIN via `collect-confirm` → admin PIN via `collect` → `createProfile`;
   - "Change my PIN" row: current PIN (`collect`), then new PIN (`collect-confirm`), then `setPin`. A Standard profile may also remove its PIN; an Admin may not, and the option is hidden.
4. Every status string from the contract maps to a user message: `wrong-pin` (with attempts left), `locked-out` (with seconds), `invalid`, `not-allowed`, `failed`. Show it in the pane.

## Out of scope
- Deleting or renaming profiles (not in the contract yet; write a follow-up task with a contract change if you think it's needed).
- Avatar picking (the service assigns colours).
- polkit (Phase 2 service work).

## Acceptance criteria
- [ ] The mock's `createProfile` rejects exactly what `service.rs` rejects. Mirror the cases from `service.rs::tests::creating_more_profiles_needs_admin_credentials` and `first_profile_must_be_admin_with_pin` (test `tst_profile_admin.qml::test_mock_rules_match_service`).
- [ ] An admin adds "Kid" (standard, no PIN) entirely by controller; the picker then lists 4 profiles (test `test_add_profile_flow`).
- [ ] A wrong admin PIN shows "attempt(s) left" and creates nothing (test `test_add_profile_wrong_admin_pin`).
- [ ] A Standard profile does not see "Add profile" (test `test_add_hidden_for_standard`).
- [ ] Changing a PIN with a mismatched confirmation restarts collection; a matching one calls `setPin` and the new PIN works at the picker (test `test_change_pin`).
- [ ] Existing PinPad tests still pass unmodified.
- [ ] Screenshot `10-settings-profiles.png`.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §1.1: describe the UI flows briefly.
- `docs/specs/02-shell.md` §1: Settings → Profiles exists.

## Hints
- Keep the multi-step flow as a small state machine in one QML file (`ProfileAddFlow.qml`) rather than nested callbacks.
- The D-Bus backend reply for `CreateProfile` is `(s status, s id)`; for `SetPin` it is `s status`.

## Outcome
_Filled in by the implementer._
