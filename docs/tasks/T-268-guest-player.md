# T-268 — Guest as a temporary player

Status: todo · Phase: 2 · Depends: T-264, T-265, T-211 · Area: services, shell · Size: S · Owner: builder · Developer surface: internal

## Goal
Someone without a profile can play in a running session as "Guest player": nothing is persisted for them, a banner says so, and the assignment ends by itself. Part of epic ADR-017 (T-263).

## Read first
- ADR-017 (Guest = no attribution; strictest age limit applies), T-211 (device-level Guest policy), the Guest profile in the mocks and in `ruya-profiles`, T-264/T-265

## Scope
1. Reuse the Guest profile; a guest slot persists nothing (no achievements, no play time, no registry default owner).
2. Banner "Guest player" in the player chip and in the dialog; auto-release at session end, on "Leave" and after an idle time (a constant, documented).
3. Interplay with T-211: if the device policy turns Guests off, the dialog offers no Guest and the Settings option reads "off" (T-211 may not be built yet: read the policy through a stub that defaults to "allow", and file an Inbox line).

## Out of scope
- Guest save data, guest sign-in as the session owner.

## Acceptance criteria
- [ ] Rust or shell tests as fits the layer: guest slot is wiped at session end, at Leave and after idle (fake clock); nothing written to the ledger/registry.
- [ ] `tst_players.qml`: banner visible, "off" hides the Guest entry.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Docs to update
- `02-shell.md`, `03-services-and-apps.md`.

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
