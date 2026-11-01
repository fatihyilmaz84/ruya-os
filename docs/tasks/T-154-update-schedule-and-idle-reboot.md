# T-154 — `ruya-update`: daily check, automatic download, reboot when idle

Status: todo · Phase: 2 · Depends: T-153 · Area: services, image, shell · Size: M · Owner: builder

## Goal
Updates arrive without anyone opening Settings: the service checks once a day, downloads what it finds, and the console restarts into it at a moment nobody is playing, or when the user accepts.

## Read first
- `docs/specs/01-platform.md` §4 ("checks daily … reboots when idle or when the user accepts")
- `api/dbus/org.ruyaos.Update1.xml`, `services/ruya-update/src/service.rs`, `main.rs`
- `shell/src/update/` and the staged toast in Settings → System (T-135)
- `services/CLAUDE.md`, `image/CLAUDE.md`

## Scope
1. **Schedule** in the pure core: a check when the service starts (after the startup `refresh`, at most once per 24 h using `last_check`) and then every 24 h; skipped while a job runs. Time comes through a trait so tests use a fake clock.
2. **Automatic download** after a scheduled check finds an update (not after a manual check: the user pressed Check and gets the Download button).
3. **Idle reboot:** when an update is staged, reboot only if the console has been idle (no input) for at least 30 minutes and no app is running, between 03:00 and 05:00 local time, or never if the owner turned automatic restarts off. Idle comes from the shell: extend the contract (for example a `ReportActivity()` call the shell makes at most once a minute while input arrives, or a property the shell sets); the service decides. Until `ruya-session` reports running apps, "no app running" is the shell's view (its app layer is empty).
4. **Setting:** Settings → System → Updates gets "Restart automatically for updates" (on by default), stored by the service (`/var/lib/ruya-update/`), admin-only to change (same `forbidden` rule as `SetChannel`).
5. Contract first: XML, Rust service and tests, mock, D-Bus client, Settings row, Turkish.

## Out of scope
- Telling the user before an automatic restart (a later toast/countdown task; record it in the Inbox).
- Delta-size measurement, signing, `ghcr.io` publishing.

## Acceptance criteria
- [ ] Fake clock: a check runs at start when `last_check` is older than 24 h, not when newer, and again 24 h later (Rust tests).
- [ ] A scheduled check that finds an update downloads it; a manual one does not (Rust tests).
- [ ] Reboot is requested only inside the window, after 30 idle minutes, with no app, and with the setting on; any activity resets the idle time (Rust tests with a fake reboot).
- [ ] The setting row toggles through the mock and is refused for a Standard profile (QML tests).
- [ ] VM: image built, `RUYA_BOOT_OK`, `vm-update-check.sh` ALL PASSED and extended with the new call(s) and the setting round trip. The real 03:00 reboot is **unverified** unless the builder sets the VM clock; say which.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```
Then the image recipe in `docs/dev-setup.md` and `vm-update-check.sh`.

## Docs to update
- `docs/specs/01-platform.md` §4, `docs/specs/02-shell.md` (Settings → System), the Update1 XML header.

## Hints
- Copy the `ruya-devices` pattern for a timer task next to the D-Bus server; keep the decisions in the pure core.
- Reboot with `systemctl reboot` (needs the unit to allow it; check the hardening, and record any change and why).

## Outcome
_Filled in by the implementer._
