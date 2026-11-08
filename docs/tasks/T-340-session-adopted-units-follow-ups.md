# T-340 - ruya-session: follow adopted apps cheaply and never relaunch into a taken unit name

Status: todo · Phase: 2 · Depends: — · Area: services (ruya-session), scripts · Size: M · Owner: builder

## Goal
Since T-290 `ruya-session` adopts running `ruya-app-*` units after a restart, but it follows them by running `systemctl -M <user>@ --user show` for each unit every 2 s (a transient unit per call, and the real exit status is lost), and an adopted unit dropped after 5 failed polls can still hold the unit name when a relaunch is attempted. After this task the adopted apps are followed through one long-lived connection per profile manager, the exit status is the real one, and a relaunch right after a Stop or a lost poll never fails with `already-running` or a taken name for longer than the old unit's wait.

## Read first
- `services/ruya-session/` (the adoption code T-290 added, the poll loop, `launch`, `Stop`, the exit-status mapping `crashed` / `launch-failed`), `docs/tasks/T-290-*.md` Outcome and its review follow-ups
- The Inbox lines tagged T-290 and T-301 in `docs/STATUS-parked.md`, "Inbox triage 2026-11-08 (lead-5)" (verbatim)
- `docs/specs/03-services-and-apps.md` ("A restart of `ruya-session` does not split a run (T-290)"), `services/CLAUDE.md`, `api/dbus/org.ruyaos.Session1.xml`
- `scripts/vm-session-check.sh` (modes `check` and `restart`)

## Scope
1. **One connection per manager:** follow the adopted units with the user manager's D-Bus (`UnitRemoved`, `PropertiesChanged` for `ActiveState`/`ExecMainStatus`) or with `cgroup.events` of the scope, whichever the builder shows is simpler and keeps the real exit status; no `systemctl -M` poll per unit. Say in the Outcome which and why. Keep the 2 s fallback only if the connection is lost.
2. **Do not drop an adopted unit on 5 failed polls without checking:** before giving up, ask the manager whether the unit still exists; if it does, keep following it (and never let `launch` of the same app fail on the old unit's name: either wait for the old unit with a bound, or choose a new instance name).
3. **A launch right after a Stop:** `already-running` is only answered while the old unit is really active; after `Stop` returns, a launch waits at most the unit's stop time and then starts (seen in `vm-session-check.sh restart`).
4. **Fix the outdated comment** in `vm-session-check.sh` check mode ("forgets them when it restarts") and add the cases below to `restart` mode.

## Out of scope
- Per-profile Wayland sockets (T-164), freezing (T-275), changing the Session1 contract unless the exit status needs a field (then XML first and say so).

## Acceptance criteria
- [ ] Rust tests (fake manager): `adopted_unit_exit_is_seen_without_polling` (a fake event stream ends the run with the unit's real status: a non-zero `ExecMainStatus` is `crashed`, 0 is `quit`), `a_lost_connection_falls_back_to_polling_and_recovers`, `an_adopted_unit_is_kept_when_polls_fail_but_the_unit_exists`, `a_dropped_unit_is_checked_before_it_is_forgotten`, `launch_after_stop_does_not_answer_already_running`, `launch_into_a_taken_unit_name_waits_or_renames`. Revert check: restoring the 5-polls drop turns the third red.
- [ ] No `systemctl -M` per poll remains in the following path (a test greps the code path or counts fake process spawns: zero while following 3 adopted units for 10 fake seconds).
- [ ] VM (lead run): `vm-session-check.sh restart` extended: restart the service with an app running, kill the app, the exit is reported with its real status; Stop then Launch immediately works. Outcome `Verified: host (vm pending: vm-session-check.sh restart)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/03-services-and-apps.md` (the adoption paragraph), `docs/dev-setup.md` if the check changes.

## Hints
- zbus is already a dependency of the services; reuse its signal streams as `ruya-devices` does for udisks.
- Image risk is low (no unit, policy or hardening change): "VM (lead run)".

## Outcome
_Filled in by the implementer._
