# T-154 — `ruya-update`: daily check, automatic download, reboot when idle

Status: done · Phase: 2 · Depends: T-153 · Area: services, image, shell · Size: M · Owner: builder

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
Verified: host (`dev.ps1 test` ALL GREEN: 254 QML, 56 Rust in the crate; `shots` ALL GREEN, 25 reviewed) and vm (image `0.0.24-t154` then `0.0.25-t154` over a dev registry; `RUYA_BOOT_OK`). The shell's D-Bus client (`SetAutoRestart`, `ReportActivity`) and the shell reporting real input are **unverified** (no shell-over-D-Bus run; the VM check calls the same methods with `busctl` as `ruya-shell`).

**Built.**
- Contract (`Update1.xml`): record key `auto_restart` (b); `SetAutoRestart(b)` (admin, `forbidden` otherwise); `ReportActivity(b app_running)` (no reply); header text for the schedule. `last_check` is now kept over restarts (`/var/lib/ruya-update/last_check`) so "at most once per 24 h" holds across boots.
- `services/ruya-update/src/schedule.rs` (new, pure): `Clock` and `Reboot` traits, `Schedule` (24 h check, one-hour retry after an attempt, quiet = 03:00-05:00 local + 30 min idle + no app), `SystemClock` (`localtime_r` through `libc`, Linux only; UTC elsewhere), `SystemctlReboot`, `LogReboot` for `--session`, fakes for tests. `service.rs`: `tick()` (check, then download when the scheduled check found something, then restart), `set_auto_restart`, `report_activity`, state file `auto_restart` (`on`/`off`; anything else means on). `main.rs`: the start-up thread loops `tick` every 60 s after the first `refresh`. `dbus.rs`: the two methods.
- Shell: `UpdateBackend`/mock/D-Bus client/`Update` (`autoRestart`, `setAutoRestart`, `noteActivity` limited to once a minute), `KeyRouter::activity()` for key, mouse, wheel and touch input, wired in `Shell.qml` (`appRunning` = an app item is focused). Settings -> System: admin-only "Restart automatically for updates" switch; a refused change shows "Only an admin can do this." and the switch goes back. Turkish added.
- `vm-update-check.sh`: settings round trip, `forbidden` for the shell, `ReportActivity`, new modes `settings` and `reboot`.
- Specs: `01` §4, `02` System, `dev-setup.md`, the XML header. New dependency: `libc` (already in the tree) for the local hour.

**Tests.** 15 new Rust tests in `service.rs` with a fake clock and fake reboot (check at start old/new/never, every 24 h, retry after an hour, scheduled downloads and manual does not, no check while busy or staged, restart only in the window / after 30 idle minutes / without an app / with the setting on / after a failed restart, activity resets idle, setting admin-only and persisted) and 7 in `schedule.rs`; 7 QML tests (setting round trip, forbidden, row hidden for Standard, row toggles for an admin, refusal message, once-a-minute limit, shell input is reported).

**VM.** `vm-update-check.sh check`: everything passed except the new `auto_restart` lines, which failed on a script bug (Python prints `True`, the script compared `true`); the schedule did its start-up check by itself (state `up-to-date` before any call). After fixing the script, `settings` ALL PASSED. `systemd-analyze security` still 4.8 OK; the unit needed no change for `systemctl reboot` (root over the bus). Real restart: `vm-update-check.sh reboot` moved the guest clock to 03:10 (UTC) with an update staged; the service logged "the console is idle, restarting into the staged image" at 03:10:51, the guest went through `reboot.target`, and a cold start booted `0.0.25-t154`. That run uses the service-start baseline for idle (no input reports in the VM), so "activity resets idle" and "app running" are covered by Rust tests only.

**Deviations / notes.** (1) `last_check` persistence and the one-hour retry are additions the criteria need ("again 24 h later", offline start). (2) A scheduled download that fails is not retried until the next check (24 h); filed in the Inbox. (3) A staged rollback is restarted into the same way. (4) The setting row is hidden for Standard profiles like the channel row; the refusal itself is tested through the mock.
