# T-135 — OS updates: `Update1` contract, mock, and Settings → System updates

Status: done · Phase: 2 · Depends: — · Area: api, shell · Size: M

## Goal
In Settings → System the user sees the OS version and channel, checks for an update, watches it download, and gets "Restart to finish" when it is staged; an admin can roll back to the previous image. All of it runs against a mock now; `ruya-update` (the service over `bootc`) is a later task.

## Read first
- `docs/specs/01-platform.md` §4 (updates, rollback, channels) and §5.4 (recovery)
- `docs/specs/02-shell.md` §3 (Settings panes, System/About as built) and §5.1 (toasts: update-ready prompt)
- `api/dbus/org.ruyaos.Store1.xml` and `shell/src/store/` (**the pattern**: contract, `StoreBackend`, mock with `RUYA_MOCK_FAST`, D-Bus client, facade singleton)
- `shell/qml/SystemPane.qml`, `shell/qml/ProfileManageFlow.qml` (admin PIN, then the action) and `shell/qml/PowerConfirm.qml` (confirm dialog)
- `shell/CLAUDE.md` (backend pattern) and `shell/PATTERNS.md` (controls, modals from pages)

## Scope
1. **Contract first:** `api/dbus/org.ruyaos.Update1.xml`, object `/org/ruyaos/Update1`. Cover: a state (`idle | checking | downloading | staged | up-to-date | failed`) with `current` and `staged` versions, `channel`, `last_check` (unix seconds, 0 = never), download progress (0..100), `rollback_available`, and the last error text; methods `Check()`, `Download()` (stage), `Rollback()` (admin), `SetChannel(channel)` (admin); a `StatusChanged` signal. Status strings (`ok`, `busy`, `unavailable`, `invalid`, `failed`) listed in the XML header. Rebooting is **not** here: the shell uses `Power.restart()` (T-107). Extend the contract rather than working around it (`CLAUDE.md` step 4).
2. **Shell `Update` singleton** in `shell/src/update/` with a mock backend (deterministic and asynchronous; the mock simulates check, download progress and staging; `RUYA_MOCK_FAST` shortens the delays) and a D-Bus client (compiled only: mark it **unverified**).
3. **Settings → System** gets an "Updates" group: version and channel row, "Check for updates", progress while downloading, "Restart to finish" once staged (opens the existing power confirm for restart), "Roll back to the previous version" (only when `rollback_available`; asks for the admin PIN first, like T-131, then a confirm). A change of channel is a `ChoiceRow` (stable, beta), admin only.
4. **Update-ready toast** when the state becomes `staged` (existing `Notifications`).
5. Mock mirrors the service rules it can know now: no `Download` unless an update was found, `busy` while a check or download runs, `Rollback` only with `rollback_available`.

## Out of scope
- `ruya-update` service, `bootc` calls, greenboot's rollback event display (follow-up), scheduled daily checks, idle-time automatic reboot, app (Flatpak) updates (the Store task owns them), the GRUB rollback path.
- Verifying the admin PIN inside the service (the shell checks it, as in T-131; the bus policy restricts callers to `ruya-shell` and root). Put the question of enforcing it service-side in the Outcome.

## Acceptance criteria
- [ ] `Update1.xml` exists and is well-formed XML; the mock backend and the D-Bus client use the same method, signal and status names (a test over the mock covers every status string).
- [ ] Check finds an update, Download shows progress, then "Restart to finish" is focusable and Accept opens the restart confirm (test in a new `tst_update.qml`, keys only; focus asserted after each step).
- [ ] Roll back: hidden without `rollback_available`; with it, Accept asks for the admin PIN, a wrong PIN shows the lockout/attempts message, the right PIN then a confirm, then the mock records the rollback (test).
- [ ] A Standard (non-admin) profile does not see the rollback or channel rows (test).
- [ ] The staged toast appears once (test); reduced-motion and token lint stay clean.
- [ ] Screenshot `25-settings-updates.png` (add to `test_zz_screenshots`) shows the Updates group with an update downloading; reviewed.
- [ ] `dev.ps1 test` ALL GREEN, `dev.ps1 shots` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/01-platform.md` §4 (what is built: shell side only), `docs/specs/02-shell.md` (System pane), `shell/CLAUDE.md` only if a new pattern appeared, `api/dbus` XML header.

## Hints
- Copy `Store`'s job-progress handling for the download. Keep strings in `qsTr()` and refresh the translations (`shell/CLAUDE.md`, Translations); the Turkish text needs a real translation.
- A model must not change with the language: keep the group's rows as bindings, not a model rebuilt per language.

## Outcome
Verified: host (`dev.ps1 test` ALL GREEN: 195 QML + Rust; `shots` ALL GREEN, `25-settings-updates.png` reviewed). The D-Bus client (`DBusUpdateBackend`) and the new `VerifyAdmin` over the real bus are **unverified** (no `ruya-update`; `ruya-profiles` not rebuilt into an image).

Built:
- `api/dbus/org.ruyaos.Update1.xml`: `GetStatus` (a{sv}: state, current, available, staged, channel, last_check, progress, rollback_available, error), `Check`, `Download`, `Rollback`, `SetChannel`, `StatusChanged`; status strings in the header. Extension to the task text: an `available` version (a found update waits in state `idle`, so no extra state was needed).
- `shell/src/update/`: `UpdateBackend`, `MockUpdateBackend` (steps of 100 ms, 10 ms with `RUYA_MOCK_FAST`; a check finds 0.0.19 once, a download stages it in 10 % steps, a rollback stages 0.0.17; `busy`/`unavailable`/`invalid`/`failed` as the XML says; test hooks), `DBusUpdateBackend` (unverified), facade `Update` (adds `stagedReady`).
- Settings -> System: Version, channel (admin), one update row that follows the state, rollback row (admin, only with `rollback_available`: PIN, confirm, then `Update.rollback()`), message line. Toast "Update ready. Restart to finish." from `Shell.qml` on `stagedReady`.
- **Contract extension (CLAUDE.md step 4):** the shell had no way to check an admin PIN without side effects, so `Profiles1.VerifyAdmin(admin_id, admin_pin)` was added: XML, `ruya-profiles` (`verify_admin` + a test, D-Bus method), mock, D-Bus client, `Profiles` facade.
- `tests/tst_update.qml` (mock rules, check/download/restart, progress, rollback with wrong then right PIN, standard profile, channel, screenshot); Turkish translations written (AI, for the native review).

Deviations: `tst_profile_admin.qml` found `powerCancel`/`powerConfirm` by name in the whole shell; with a second `PowerConfirm` in the System pane the name is ambiguous, so those two lookups are now scoped to `profileDeleteConfirm` (same assertions). The mock replies `failed` to a check that fails (and sets state `failed`) so every status string is covered. No progress bar, only the percentage in the row (no token for one).

Open question for the owner/lead: should `ruya-update` verify the admin PIN itself (it would need to call `Profiles1.VerifyAdmin` or be handed the PIN)? Today the shell checks and the bus policy limits callers to `ruya-shell` and root, as for `AddRemote`.
