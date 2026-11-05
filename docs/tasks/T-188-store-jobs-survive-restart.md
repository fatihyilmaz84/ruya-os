# T-188 — Store: the shell finds its running installs again after `ruya-store` restarts

Status: todo · Phase: 2 · Depends: T-182 (same crate) · Area: services, shell · Size: M · Owner: builder

## Goal
If `ruya-store` restarts (crash, update) while an install is running, the shell today loses the job: the progress bar hangs. After a restart the shell asks the service which jobs exist and shows their real state.

## Read first
- `docs/tasks/T-171-store-facade-robustness.md` Outcome (what the facade does when the service goes away; the restart-mid-install VM check)
- `api/dbus/org.ruyaos.Store1.xml`; `services/ruya-store/src/` (job table, `Install`/`Remove`); `shell/src/store/` (`DBusStoreBackend`, mock, job model); `scripts/vm-store-check.sh`
- `services/CLAUDE.md`, `shell/CLAUDE.md`

## Scope
1. **Contract:** add `ListJobs() -> a(...)` (or a dictionary list in the style the XML already uses): id, app id, kind (install/remove), state, progress. Extend the XML first; service, mock and D-Bus client follow.
2. **Service:** answers from its job table. A job that was running when the service died is, after the restart, reported as `failed` with a reason (`interrupted`) unless Flatpak finished it (re-check the installed state), because the service cannot resume Flatpak's transaction.
3. **Shell:** when the Store backend reconnects (service owner changed), call `ListJobs`, replace the job list, and show the reconciled state (a hung "installing" becomes "failed, retry" or "installed"). A late reply to an old request must not overwrite newer data (use the guard from T-177/T-181 if merged, else the battery pattern).

## Out of scope
- Resuming a half-done Flatpak transaction, new Store UI.

## Acceptance criteria
- [ ] Rust tests for `ListJobs` and the post-restart mapping (running becomes `failed`/`interrupted`, or `installed` when the app is present); revert check noted.
- [ ] `tst_store_backend.qml`/`tst_store_ui.qml`: after a simulated service restart (name owner lost and regained) the job model matches `ListJobs`, not the stale list.
- [ ] Contract, mock, D-Bus client and service agree (names, argument order, state strings).
- [ ] VM (lead run): extend `scripts/vm-store-check.sh`'s restart-mid-install step to assert `ListJobs` after the restart. Outcome: `Verified: host (vm pending: vm-store-check.sh)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `03-services-and-apps.md` Store section; the XML doc comments.

## Hints
- Don't build an image.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
