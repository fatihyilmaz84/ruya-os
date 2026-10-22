# T-105 — Manage profiles from Settings

Status: done · Phase: 2 · Depends: T-103, T-104 · Area: shell · Size: M

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
- [x] The mock's `createProfile` rejects exactly what `service.rs` rejects. Mirror the cases from `service.rs::tests::creating_more_profiles_needs_admin_credentials` and `first_profile_must_be_admin_with_pin` (test `tst_profile_admin.qml::test_mock_rules_match_service`).
- [x] An admin adds "Kid" (standard, no PIN) entirely by controller; the picker then lists 4 profiles (test `test_add_profile_flow`).
- [x] A wrong admin PIN shows "attempt(s) left" and creates nothing (test `test_add_profile_wrong_admin_pin`).
- [x] A Standard profile does not see "Add profile" (test `test_add_hidden_for_standard`).
- [x] Changing a PIN with a mismatched confirmation restarts collection; a matching one calls `setPin` and the new PIN works at the picker (test `test_change_pin`).
- [x] Existing PinPad tests still pass unmodified.
- [x] Screenshot `10-settings-profiles.png`.

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
Settings -> Profiles works end to end against the mock; the D-Bus path is written but unverified.

- **Backend API** (`ProfilesBackend`, `MockProfilesBackend`, `DBusProfilesBackend`, `Profiles`): `createProfile(adminId, adminPin, name, role, pin)` and `setPin(id, oldPin, newPin)`; signals `createFinished(status, id, attemptsLeft, retryAfterSecs)` and `setPinFinished(id, status, attemptsLeft, retryAfterSecs)`. The XML contract is unchanged.
- **Mock rules** now mirror `service.rs`/`lockout.rs`: one `authenticate()` used by sign-in, admin authorisation and PIN change; name trimmed and 1-32 characters without control characters; role must be admin/standard/guest; PIN 4-6 digits; admins need a PIN, guests never have one; first-boot creation needs an admin with a PIN and no credentials; otherwise the admin id must be an admin and authenticate; ids are never reused; the lockout back-off doubles (30 s, 60 s, ... capped at 1 h) and is shared. `resetForTests("seeded"|"empty")` (exposed as `Profiles.resetMockForTests`) gives tests a known state and is also what T-106 will need for first boot.
- **PinPad modes**: `verify` (unchanged), `collect`, `collect-confirm`, with `collected(pin)` and `cancelled()`. The existing PinPad tests pass unmodified.
- **Settings -> Profiles** (`ProfilesPane.qml`, `ProfileAddFlow.qml`, `ChangePinFlow.qml`): profile list (new `swatch` colour dot on `SettingControl`), inline Add form, Change/Set/Remove my PIN, one status message per contract status plus a success toast. Add is hidden unless the active profile is an admin; Remove is hidden for admins and for profiles without a PIN; Change is hidden for guests.
- **Shell plumbing**: `Page.overlay` and a `modalLayer` in `Shell` (z 15) for page-owned modals; `SettingsPane` is now scrollable (Flickable that follows focus) and repairs focus when the focused row disappears; Settings panes fill the pane area.
- **Tests**: `tst_profile_admin.qml` (15): `test_mock_rules_match_service`, `test_mock_set_pin_rules_match_service`, `test_add_profile_flow` (all with D-pad keys: keyboard, PIN pad; the picker then lists 4 profiles), `test_add_profile_with_pin`, `test_add_profile_wrong_admin_pin`, `test_add_profile_locked_out_message`, `test_add_needs_a_name`, `test_cancel_pin_pad_aborts_the_flow`, `test_add_hidden_for_standard`, `test_admin_cannot_remove_pin`, `test_change_pin` (mismatch restarts; the new PIN works at the picker), `test_change_pin_wrong_current_pin`, `test_remove_own_pin`, `test_zz_screenshots` (`10-settings-profiles.png`). `tst_settings.qml::test_two_pane_navigation` was updated because Profiles is no longer a "Coming soon" category (the Coming-soon check now uses Network).
- **Docs**: 03 §1.1 "UI flows", 02 §1 and §1.2, `shell/CLAUDE.md` ("Modals from pages"), `dev-setup.md`.

Verification: `dev.ps1 test` → ALL GREEN (77 passed, 7 screenshot tests skipped without `RUYA_SHOTS_DIR`); `dev.ps1 shots` → 84 passed. `10-settings-profiles.png` reviewed: profile rows with avatar dots and role/PIN values, the Add form open with the focus ring on Role, readable, and the pane stops at the safe-area edge while scrolling follows focus. Unverified: the D-Bus `createProfile`/`setPin` and the `SwitchTo` probe (need a live bus). A mid-session run was red only because the Windows session was locked (QML timers stall without rendering); after unlocking, the same code was green.

Deviations and notes:
- **Signals carry attempt counts.** The task lists `createFinished(status, id)` / `setPinFinished(id, status)`, but it also wants "attempt(s) left" and seconds in the messages, and the contract replies have no such numbers. I added `attemptsLeft` and `retryAfterSecs` to both signals; the mock fills them in, and the D-Bus backend probes `SwitchTo(id, "")` after `wrong-pin`/`locked-out` (unverified: needs a live bus). No contract change.
- Role choices in the form are Standard and Guest only (as the task says); creating more admins is not offered.
- Found while testing: the pane's deferred focus settling stole focus from a PIN pad that reopened for the next step (fixed: it does nothing unless the pane still has focus), and focus was lost when the focused row (Remove my PIN) disappeared (fixed, with a test).
