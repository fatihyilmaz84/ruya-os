# T-152 — Store: admin PIN before a Standard profile installs a high-risk app

Status: todo · Phase: 3 · Depends: T-111 · Area: shell · Size: S

## Goal
A Standard profile that presses Install on an app with a high-risk permission (`all-devices`, `host-files`, `session-bus`) is asked for an admin's PIN first; the install starts only after the right PIN. Admins install as before. Spec 03 §4.4 asks for this; T-111 left it out.

## Read first
- `docs/specs/03-services-and-apps.md` §4.4 (permissions, high risk); `api/dbus/org.ruyaos.Store1.xml` header (the shell checks the admin PIN via Profiles1; the bus lets only the shell call Store1) and `org.ruyaos.Profiles1.xml` `VerifyAdmin`
- `docs/specs/04-design-system.md` §5 (PIN pad, Dialog buttons); new tokens or components: none
- `shell/qml/AppDetailPage.qml`, `shell/qml/SystemPane.qml` (**the pattern**: T-135's rollback asks for the admin PIN with `PinPad` and `Profiles.verifyAdmin`, then acts), `shell/PATTERNS.md` (modals from pages, PIN pad modes)
- `shell/tests/tst_store_ui.qml`, `shell/tests/tst_update.qml` (rollback PIN tests to copy)

## Scope
1. In `AppDetailPage`, Install (Install only; Update is out of scope) on an app with any high-risk permission, while the active profile is not an admin: open the admin PIN pad (choose the admin as the rollback flow does), verify with `Profiles.verifyAdmin`, and start `Store.install` only on `ok`. Wrong PIN and lockout show the existing PIN pad messages; Back cancels and returns focus to the Install button.
2. A line under the High risk permissions for Standard profiles: "An admin's PIN is needed to install this app." (`qsTr`, Turkish translated).
3. The mock catalogue already has a high-risk app (Game Streamer); add none.

## Out of scope
- Enforcing it in `ruya-store` (the bus policy limits callers to the shell; recorded in the Store1 header).
- Permission review or overrides per app (a later Flatseal-like view).

## Acceptance criteria
- [ ] `tst_store_ui.qml::test_high_risk_needs_admin_pin`: as Ada (Standard), Install on Game Streamer opens the PIN pad (focus asserted on it); a wrong PIN shows the attempts message and no job starts; Player One's PIN (1234) starts the install and focus returns to the detail page.
- [ ] `test_high_risk_back_cancels`: Back from the PIN pad starts no job, focus on the Install button.
- [ ] `test_high_risk_admin_installs_directly`: as Player One (admin), Install starts at once.
- [ ] Screenshot `20-store-admin-pin.png` (PIN pad over the detail page) reviewed.
- [ ] `dev.ps1 test` ALL GREEN, `dev.ps1 shots` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §4.4 "As built" (remove "not enforced yet").

## Hints
- `tst_store_ui.qml` signs in as a profile in its setup: check which one, and keep the existing tests on it.
- Lockout state leaks between tests: if a test runs into the lockout, give the lockout case its own file (`shell/CLAUDE.md`, Tests).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
