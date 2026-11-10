# T-363 - ruya-session follows a Flatpak game's own scope (usage, limits, stop)

Status: done · Phase: 2 · Depends: T-340 · Area: services (ruya-session), scripts · Size: M · Owner: builder · Developer surface: none

## Goal
A Flatpak game runs in its own `app-flatpak-<id>-<n>.scope`, outside our `ruya-app-*` unit: on the Dell a 45-minute SuperTuxKart run was accounted as 28 ms of CPU. After this task usage, limits, the stop/kill path and (later) freezing follow the process where it really runs.

## Read first
- `docs/specs/03-services-and-apps.md` (launching apps, usage, ADR-023), `services/CLAUDE.md`
- `services/ruya-session/src/session.rs`, `systemd.rs`, `spawner.rs`, `usage_tracker.rs`; T-340's Outcome (how adopted units are followed)
- `docs/tasks/T-355-*.md` (the Dell evidence)

## Scope
1. When a launched unit's main process is `flatpak run`, find the `app-flatpak-<appid>-*.scope` it creates in the same user manager (by app id and start time, or the scope's `cgroup.procs` ancestry) and attach it to the run.
2. Usage/CPU accounting and the run's end read the scope (the run ends when both are gone); Stop and the kill path stop the scope too.
3. Say in `03` what T-165 (freeze on profile switch) must freeze.

## Out of scope
- Freezing itself (T-165/T-275), non-Flatpak launchers.

## Acceptance criteria
- [ ] Rust tests (fake manager): `a_flatpak_scope_is_attached_to_its_run`, `usage_counts_the_scope_cpu`, `the_run_ends_only_when_the_scope_is_gone`, `stop_also_stops_the_scope`; red when removed.
- [ ] VM (lead run): `vm-app-check.sh` (or `vm-session-check.sh`) launches the sample Flatpak and sees the scope attached and stopped; Outcome `Verified: host (vm pending: <check>)`. hw: the lead repeats the STK run on the Dell (T-355).

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `03` launching apps and usage.

## Hints
- Inbox line T-355 item 4 is verbatim in `STATUS-parked.md`, "Inbox triage 2026-11-09 (lead-7)".

## Outcome
Verified: vm (0.0.61, lead-8: `vm-session-check.sh check` ALL CHECKS PASSED with the scope attach and gone lines; `restart` passed) + hw pending (Dell STK repeat: journal `scope gone, cpu N ms`)

Builder: Sonnet 5.5, effort high, round 1, tokens not measurable from inside the session (about 150 tool turns).

**What was built.** `services/ruya-session/src/scope.rs` (new, pure, host-tested): `RunScopes` knows every run the spawner started or adopted. It finds the run's `app-flatpak-<id>-<digits>.scope` (live, entered no earlier than the unit, one second of slack; looked for every second for 60 s, then given up so a non-sandbox launcher is never held), reads the CPU of unit and scope (`cpu_nsec`, the sum, never lowered by a smaller reading), **holds the unit's end while the attached scope lives and hands it on when the scope is gone** (the run ends when both are gone; 5 failed looks in a row count as gone), and names the attached scope for Stop and the kill (`scope_of`). One round = `plan` (a `Query` per profile manager) -> the caller's `systemctl show` -> `apply`. `spawner.rs`: `ShowUnit.cpu_nsec` (`CPUUsageNSec`, `[not set]` and u64::MAX read as no value), `is_app_scope`, `scope_target` (exact attached scope, else the pattern), `control_command` (the pure `systemctl stop|kill` argument list, user validated). `systemd.rs`: a `Gate` carries every unit event (Job, `follow_user`) through `RunScopes`; a `scopes` thread asks each manager at most once a second with one `systemctl show` (`show_many`); the registry entry of a unit is removed only when its end is handed on, so Stop/kill and `already-running` still work while the scope lives. `03` (the real spawner paragraph) documents it, including **what T-165 must freeze: the scope (`scope_of`), not `ruya-app-*.service`**. No D-Bus contract change.

**Tests** (`scope::tests`, fake manager = `FakeManager` answering `systemctl show` with names and the `-*.scope` glob): `a_flatpak_scope_is_attached_to_its_run`, `usage_counts_the_scope_cpu`, `the_run_ends_only_when_the_scope_is_gone`, `stop_also_stops_the_scope`, plus giving up after the window, a silent manager, a scope already gone, the scope-name grammar and the `CPUUsageNSec` parsing.

**Revert checks** (hand-made, each on a fresh `cargo test` build, file restored): attach without `is_app_scope` -> `a_flatpak_scope_is_attached_to_its_run` red; `cpu_nsec` without the scope term -> `usage_counts_the_scope_cpu` red; `on_unit_event` never holding (`if false`) -> `the_run_ends_only_when_the_scope_is_gone` red; `control_command` without the scope argument -> `stop_also_stops_the_scope` red. (`revert-check.ps1` runs the Qt tests, so it does not fit Rust.)

**VM (lead run).** `vm-session-check.sh check` now waits for the journal line `<unit>: attached app-flatpak-<sleeper>-N.scope` after Launch, and after Stop for `<unit>: scope gone` and no active `app-flatpak-<sleeper>-*.scope` left. The Dell STK repeat (T-355 item 4: the journal's `scope gone, cpu N ms` should be about 45 min x 15 %) is for the lead.

**Deviations / limits.** The ledger stores no CPU (no format change); CPU is in the journal and `RunScopes::cpu_nsec` only. A unit that ends before its scope was seen (inside the first second) is not held (accepted race, in `03`). The attach rule uses app id + start time, not `MainPID`/cgroup ancestry (the scope name's number is `flatpak run`'s PID, usable later if two scopes of one app per user ever matter). `dev.ps1 test`: ALL GREEN on the second run (1012 QML passed, 79 skips, Rust all ok); the first run failed only `tst_battery_cluster::test_the_chip_shrinks_to_plus_n_in_a_narrow_room`, the known load flake from the parked Inbox (no shell file is in this diff).

