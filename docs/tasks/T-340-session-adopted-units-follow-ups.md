# T-340 - ruya-session: follow adopted apps cheaply and never relaunch into a taken unit name

Status: in-progress · Phase: 2 · Depends: — · Area: services (ruya-session), scripts · Size: M · Owner: builder

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
Verified: host (vm pending: vm-session-check.sh restart)

**Built.** `services/ruya-session/src/follow.rs` (new): `Follower` follows the adopted units of one profile manager through a `ManagerLink` (wait for a signal, reconnect, probe one unit, "does it still exist"). Events: `PropertiesChanged` (`ActiveState`, `ExecMainStatus`, `ExecMainCode`) and `UnitRemoved`; the real status is kept by `UnitWatch::apply` (non-zero exit = `crashed`, 0 = `quit`, signal = `killed` in the core). A lost connection falls back to a probe per unit every 2 s with a reconnect attempt each round and one look at every unit after it; 5 failed looks in a row ask `exists` first and only a "no" (or no manager for that user) ends the watch, "cannot tell" keeps the unit. `systemd.rs`: `UserLink` (zbus peer-to-peer connection to `/run/user/<uid>/systemd/private`, `Subscribe`, bus `GetUnit`/`GetAll` for probes), `follow_user` (one thread per manager instead of one per unit), the per-unit `Watcher` is gone. `session.rs`/`dbus.rs`: `Launch` waits (`wait_while_stopping`, `LAUNCH_WAIT` 8 s, lock not held) while an instance of the same app is stopping; the core answers `already-running` only for an instance that is not stopping, and `failed` (no second unit on the taken name) if the old one is still there after the wait. I chose "wait", not "rename": a deterministic unit name stays the instance name the shell and the ledger know. `Cargo.toml`: zbus feature `p2p` (the lock gains one `getrandom` edge for `uuid`).

**Which transport and why:** the manager's own D-Bus socket with signals (the task's first option), because it is the only one that keeps the real exit status (`cgroup.events` only says "empty").

**Open point (important, not verified):** `ruya-session.service` has `ProtectHome=yes` (hides `/run/user`) and an empty capability set (no access to the users' 0700 directories). The private socket is therefore probably refused on the image and only the fallback runs, which is the old polling (still with no drop on 5 misses, a real improvement but not acceptance 2 on the image). I did not touch the unit (out of this task's risk class; it is a hardening decision). `vm-session-check.sh restart` now fails its "no systemctl process while following" check if that is so and prints the journal line. Fix options for the lead: `ProtectHome=read-only` plus `CAP_DAC_READ_SEARCH` (and SELinux), or follow the user bus through a bridge process.

**Tests (all in `cargo test -p ruya-session`):** `follow::adopted_unit_exit_is_seen_without_polling`, `a_signal_kill_keeps_the_signal_number`, `no_process_is_started_while_following_three_units_for_ten_seconds` (fake spawn counter stays 0), `a_lost_connection_falls_back_to_polling_and_recovers`, `an_adopted_unit_is_kept_when_polls_fail_but_the_unit_exists`, `a_dropped_unit_is_checked_before_it_is_forgotten`, `events_for_other_units_change_nothing`, `unit_paths_round_trip`, `the_signals_of_the_manager_are_read` (real zbus messages); `session::launch_after_stop_does_not_answer_already_running`; `dbus::launch_into_a_taken_unit_name_waits_or_renames`. The old `a_manager_that_stays_unreachable_ends_the_watch` was removed on purpose: it tested the behaviour this task replaces (drop after 5 misses without asking); its successors are the two follower tests above.

**Revert checks** (hand mutation, tests rerun, file restored): `Some(true) => None` to `Some(true) => Some(ended)` in `follow.rs` turns `an_adopted_unit_is_kept_when_polls_fail_but_the_unit_exists` red (the 5-polls drop); `.any(|i| i.state != State::Stopping)` to `.any(|_| true)` in `session.rs` turns `launch_after_stop_...` and the dbus test red; making `wait_while_stopping` never wait turns the dbus test red.

**VM script:** `scripts/vm-session-check.sh`: outdated comment fixed; `restart` mode gained "Stop, then Launch at once" (must be `ok`, not `already-running`), "no `systemctl` process for 6 s while an adopted app runs", and the killed adopted app must not be reported as a clean `quit` (a NOTE, not a failure, if it is: the exact status of a scope SIGKILL on the image is not known).

**Files:** `services/ruya-session/src/{follow,systemd,spawner,session,dbus,lib}.rs`, `services/ruya-session/Cargo.toml`, `services/Cargo.lock`, `scripts/vm-session-check.sh`, `docs/specs/03-services-and-apps.md`.
