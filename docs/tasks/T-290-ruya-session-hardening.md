# T-290 — ruya-session hardening: adopt running apps after a restart, exec failures, unit security

Status: done · Phase: 2 · Depends: — · Area: services (ruya-session), scripts (vm-session-check) · Size: M · Owner: builder

## Goal
Restarting `ruya-session` no longer loses track of the apps that keep running (a relaunch works, `ListRunning` is right, usage time keeps counting), and an app whose binary cannot be executed reports `launch-failed`, not `crashed`.

## Read first
- `docs/specs/03-services-and-apps.md` (Session1), `api/dbus/org.ruyaos.Session1.xml`
- `services/CLAUDE.md`; `services/ruya-session/src/session.rs` (`Session`, `list`, `on_event`), `spawner.rs` (`parse_run_line`, exec 203 test ~line 566), `systemd.rs`, `usage_tracker.rs`
- T-162 Outcome (units `ruya-app-*`, `systemd-run --machine=`, status file); `scripts/vm-session-check.sh`
- STATUS-parked.md "Inbox triage 2026-11-07", bullets T-290

## Scope
1. **Adopt on start:** at start the service lists the `ruya-app-*` units of every profile manager (the same machines it launches into), rebuilds its instance table (app id, profile, instance id, start time) from unit names/properties, emits `AppStarted` for none (shell asks `ListRunning`), and keeps watching them so a later exit emits `AppExited` with the right reason. Units of profiles that no longer exist are stopped.
2. **Exec failure:** exit status 203 (EXEC) maps to `launch-failed`, not `crashed` (Session1.xml, `AppExited`: "launch-failed" means never reached running, exit code -1); T-147 shows it to the player.
3. **Usage across the restart:** a session already running when the service restarts keeps counting; no duplicate row is written when it ends (T-247 `usage_tracker`).
4. **Unit security:** after the unit change of T-247 re-run `systemd-analyze security ruya-session` and record the exposure in the Outcome (the 1.1 of T-162 must not worsen); the SELinux label of `/var/lib/ruya-session` is checked in the VM (script prints it).

## Out of scope
- Per-profile Wayland sockets (T-164), freezing (T-275), changing the Session1 contract beyond what Scope 1 forces (if it forces one, XML first, mock and client after).

## Acceptance criteria
- [ ] Rust tests with the fake spawner: start with two pre-existing units, `list()` returns both; a relaunch of one answers `already-running`; their exit emits `AppExited` once; a unit of an unknown profile is stopped (each red when the adoption is removed).
- [ ] `spawner.rs` test: status 203 maps to the `launch-failed` result; other non-zero stays `crashed`.
- [ ] Usage test: restart mid-session does not double count or lose the open session.
- [ ] VM (lead run): `scripts/vm-session-check.sh` gains `restart`: launch an app, `systemctl restart ruya-session`, `ListRunning` still lists it, `Stop` works; prints `systemd-analyze security` and `ls -Z /var/lib/ruya-session`. Outcome `Verified: host (vm pending: vm-session-check.sh restart)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN (Rust included).

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 rust
```
VM (lead): `vm-session-check.sh restart` on the next image.

## Docs to update
- 03 (Session1: restart behaviour), the T-162 note in `image/CLAUDE.md` if a quirk appears.

## Hints
- Reference: `ruya-profiles` for the table-from-system pattern; units are named so the profile and app can be parsed back (check `spawner.rs` unit naming and add the instance id to a property if the name does not carry it).
- No overlap with other open tasks except T-164 (compositor side) and T-165/T-275 later.

## Outcome
Verified: host (vm pending: vm-session-check.sh restart)

VM 0.0.54 (lead): `vm-session-check.sh` 37 PASS and `restart` 22 PASS (adopted after a restart, relaunch already-running, Stop quit, a second restart plus SIGKILL gives AppExited); `systemd-analyze security` exposure 1.1 (not worse than T-162); label of /var/lib/ruya-session and /usage: var_lib_t. The check script needed fixes (pgrep user, wait for the registry after a Stop); `vm-usage-check.sh` power cut now kills the app too (33 PASS).

**Built.**
- **Adoption (Scope 1).** `Spawner::adopt_running()` (new trait method, default empty; `FakeSpawner::with_running`) lists the app units that run already; `Session::adopt(unix, now, profiles_known)` rebuilds the registry from them (state `running`, no `AppStarted`, original start time), so `list()` returns them, a relaunch is `already-running`, and `Stop`/kill work. A unit of a profile `ListProfiles` no longer knows is stopped, hidden (never listed, its end not reported) and killed by `tick` after the grace time; if `ListProfiles` is unreadable nothing is stopped. The real one (`SystemdSpawner::adopt_running`, `systemd.rs`): `loginctl list-users` -> `ruya-*` users -> `systemctl --user -M <user>@.host show 'ruya-app-*.service'` (`--timestamp=unix`), app id from the unit name given the user (`unit_app_id`, no guess where profile and app ids both contain `-`), then one thread per unit reads `systemctl show <unit>` every 2 s (`UnitWatch`, pure) and sends `UnitEvent::Exited` once when the unit is gone (also after 5 failed calls, e.g. a deleted profile's manager). `dbus::adopt_running` runs it in `main.rs` after the object is served but **before** `request_name`, so the shell's first `ListRunning` already sees the apps.
- **Exec failure (Scope 2).** `parse_run_line` reads `status=203/EXEC` as `RunLine::ExecFailed` -> `UnitEvent::ExecFailed` -> `Notice::Exited { -1, launch-failed }` (stopping: `quit`). A bare 203 or any other non-zero status stays `crashed`. This changed the existing `run_lines_as_systemd_run_prints_them` assertion for `203/EXEC` (it expected `Ended(203)`); that was the old behaviour being replaced.
- **Usage (Scope 3).** `Tracker::recover_with(unix, live, now)` (`recover` calls it with none): a leftover heartbeat of a live app (same profile, app, instance in the key) is taken over (time so far, start, version, same file), so the end writes one row and removes the file; a live app without a heartbeat gets `app_started` dated from the unit's start; other leftovers end `crashed` as before. `main.rs` no longer calls `recover` before the bus: `dbus::adopt_running` does it after adoption.
- **Contract.** `Session1.xml` comments only (ListRunning after a restart, `launch-failed` for 203/EXEC); no signature changed, so mock and D-Bus client are untouched.
- **VM check.** `scripts/vm-session-check.sh restart` (launch, `systemctl restart ruya-session`, `ListRunning` still lists it, journal says `adopted`, relaunch `already-running`, `Stop` -> `quit` and the process is gone, a second restart plus a SIGKILL to the scope still gives `AppExited`, then `systemd-analyze security` and `ls -Zd /var/lib/ruya-session{,/usage}`); `security` prints the `ls -Z` too.

**Scope 4 (unit security) is not done on this machine:** it needs the VM. The unit file is unchanged by this task (the `StateDirectory` change was T-247's); the new code runs only `loginctl` and `systemctl` (as `ensure_manager` already did) with the same hardening. The exposure number and the SELinux label go into the lead's VM run of `restart` (T-162 had 1.1; compare).

**Tests (Rust, `cargo test`, all in `ruya-session`).** session.rs: adopted units listed with start time, relaunch `already-running`, end reported once with reason, stop/kill of an adopted app, unit of an unknown profile stopped + unseen, nothing stopped when profiles unknown, foreign users/ids skipped, double adopt, missing start time, exec failure (and stopping). spawner.rs: `203/EXEC` parse, follower event, `unit_app_id`, `parse_profile_users`, `parse_show`, `UnitWatch` end/misses, fake. usage_tracker.rs: restart mid-session = one row of 100 s with the original start, same restart without adoption splits (documents the old behaviour), live app without heartbeat, non-live leftovers still `crashed`, other profile does not take the leftover.
**Revert checks** (Rust, `output/mutate.py`, file restored each time, `dev.ps1 rust` green afterwards): `adopt` loop emptied -> 8 tests fail; `orphan = false` -> 1; the `203/EXEC` match arm removed -> 2; `recover_with` never taking a leftover over -> 2; `UnitWatch` never ending on a dead unit -> 1.

**Known limits / unverified.** (1) The exit code of an adopted app is the last status seen while it ran (normally 0): a `--collect`ed unit vanishes the moment it ends, so a crash after a restart reads `quit` (documented in spec 03 and the XML). (2) `systemctl show` output is read through a pipe (`Command::output`); `--machine=` once refused a pipe that was handed to PID 1 (`systemd-run`), `show` should not pass it on, but only the VM tells. (3) `loginctl list-users --no-legend` and `show --timestamp=unix` (systemd >= 246) are as documented, not run here. (4) A leftover heartbeat of an *older* run with the same unit name would be taken over by a live app of the same name; only possible if the app ran outside the service meanwhile.

**Files.** `api/dbus/org.ruyaos.Session1.xml`, `docs/specs/03-services-and-apps.md`, `docs/dev-setup.md`, `scripts/vm-session-check.sh`, `services/ruya-session/src/{dbus,main,session,spawner,systemd,usage_tracker}.rs`.
