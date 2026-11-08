# T-290 — ruya-session hardening: adopt running apps after a restart, exec failures, unit security

Status: in-progress · Phase: 2 · Depends: — · Area: services (ruya-session), scripts (vm-session-check) · Size: M · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
