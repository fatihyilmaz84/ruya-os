# T-389 - Store1 jobs v2: bytes, rate, ETA, queue order; cancel, pause, resume, move

Status: todo · Phase: 3 · Depends: T-388 · Area: api, services (ruya-store), shell (Store client, mock) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

## Goal
Every Store job reports real bytes, a smoothed rate and an ETA (or says they are unknown), and the shell can cancel, pause, resume and reorder queued and running jobs.

## Read first
- ADR-026 and the T-388 Outcome (the chosen byte source, pause semantics, the draft XML), `api/dbus/org.ruyaos.Store1.xml`, `services/ruya-store`, `services/CLAUDE.md`, the shell's Store client and mock (`shell/src/store/`)

## Scope
1. Implement the v2 record and the actions of T-388's draft in the pure core (queue order, state machine with `paused`/`cancelled`, rate smoothing, ETA) and the adapters; the draft XML becomes the contract.
2. Mock and D-Bus client carry the new fields and calls; existing Store screens keep working (their percent comes from bytes when known).
3. A job of a removed app, a service restart while paused (state comes back `paused`, not `interrupted`), and a cancel during install (not download) are defined and tested.

## Acceptance criteria
- [ ] Rust: state machine (every transition and refusal), rate smoothing with a fake clock, ETA unknown when the total is unknown, queue `MoveJob` order, restart persistence (red without each change).
- [ ] VM (this task): `vm-store-check.sh` gets `downloads`: install the local test app with a throttled local remote (or a large fixture), see bytes and rate move, pause, resume to completion, cancel another; `RUYA_BOOT_OK`.
- [ ] Contract, mock and client agree; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
