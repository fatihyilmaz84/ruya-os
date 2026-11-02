# T-159 — `ruya-update`: notice before the automatic restart; retry a failed download

Status: todo · Phase: 2 · Depends: T-154 · Area: api, services, shell · Size: M · Owner: builder

## Goal
Nobody loses a session to the nightly update restart: the console announces it two minutes ahead on screen, any button press calls it off, and a scheduled download that failed is tried again within the hour instead of a day later.

## Read first
- `docs/specs/01-platform.md` §4 (the "Schedule" paragraph), `02-shell.md` §5.1 (toasts)
- `api/dbus/org.ruyaos.Update1.xml`, `services/ruya-update/src/schedule.rs`, `service.rs` (`tick`, `scheduled_check`, `scheduled_restart`), `main.rs`
- `shell/src/update/`, `shell/qml/SystemPane.qml` (the staged toast), `Notifications` usage in `Shell.qml`
- UI: `04-design-system.md` §5 (Toast), §7 (copy); new tokens or components: none
- `services/CLAUDE.md`, `shell/CLAUDE.md`

## Scope
1. **Grace period** (pure core): when the restart rules first hold (T-154: window, 30 idle minutes, no app, setting on, image staged), the service does not reboot at once; it sets a pending restart time `now + 120 s` and reports it. At a tick at or after that time, if the rules still hold, it reboots. Any `ReportActivity`, the setting turned off, or the image no longer staged clears the pending time (then the usual 30 idle minutes start again).
2. **Contract first:** a record key, for example `restart_at` (x, unix seconds, 0 = none), with `StatusChanged` when it is set or cleared; XML header text. Mock, D-Bus client and `Update` (`restartAt`) follow.
3. **Shell:** while `restart_at` is set, a `warning` toast "Restarting to finish the update in 2 minutes. Press any button to wait." stays up (no auto-dismiss) and goes when it clears. Input already reaches the service through `Update.noteActivity`; make sure the press that should cancel is not swallowed by the once-a-minute limit (report at once while a restart is pending).
4. **Retry:** a download started by the schedule that fails is tried again after `RETRY_SECS` (one hour), as a failed scheduled check is; a manual download is not retried.
5. Turkish for the new strings; spec 01 §4 and 02 §5.1.

## Out of scope
- A "Restart now" or "Postpone until tomorrow" button, a countdown that ticks every second, a toast after the restart ("Updated to …").
- Changing the window, the idle time or the grace length into settings.

## Acceptance criteria
- [ ] Fake clock: quiet → `restart_at` = now + 120 and no reboot; a tick at + 119 s no reboot; at + 120 s one reboot (Rust test).
- [ ] Activity, setting off, or nothing staged during the grace clears `restart_at` and no reboot follows; quiet again only after 30 more idle minutes (Rust tests).
- [ ] A failed scheduled download is retried after an hour, not before; a failed manual download is not retried (Rust tests).
- [ ] Mock: `restart_at` set → the toast is visible with the text above; cleared → gone; a key press while pending reports activity at once even inside the minute (QML tests in `tst_update.qml`).
- [ ] Screenshot of Home with the pending-restart toast, reviewed against `04` §8.
- [ ] VM: image built, `RUYA_BOOT_OK`; `scripts/vm-update-check.sh reboot` extended: with an image staged and the guest clock at 03:10, `GetStatus` shows `restart_at`, a `ReportActivity` as `ruya-shell` clears it and no reboot follows; a second run without activity reboots after the grace and boots the staged image.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```
Then the image recipe in `docs/dev-setup.md` and `vm-update-check.sh` over SSH.

## Docs to update
- `docs/specs/01-platform.md` §4, `02-shell.md` §5.1, the Update1 XML header.

## Hints
- Keep the decision in `Schedule` (`pending_restart: Option<i64>`); `scheduled_restart` only reads it. `main.rs` ticks every 60 s, so the reboot lands 120–180 s after the notice; that is fine.
- T-154's `vm-update-check.sh reboot` mode already sets the guest clock; copy it.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
