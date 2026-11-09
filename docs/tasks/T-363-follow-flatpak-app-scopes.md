# T-363 - ruya-session follows a Flatpak game's own scope (usage, limits, stop)

Status: todo · Phase: 2 · Depends: T-340 · Area: services (ruya-session), scripts · Size: M · Owner: builder · Developer surface: none

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
_Filled in by the implementer._
