# T-368 - Settings > Controllers: connected pads, capabilities and a live button test

Status: todo · Phase: 2 · Depends: T-367 · Area: api, services (input), shell (pane, mock, client) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

## Goal
The player sees every connected controller (name, connection, battery, player number, what it can do) and can test every button and stick live, with the pad alone. Requirements §3.3, §11.1; T-217 scope 2c/2d.

## Read first
- ADR-024, `docs/specs/06-input.md` (capability descriptor, `Input1`), `docs/specs/02-shell.md` (Settings), `docs/specs/04-design-system.md` §5, §8, `shell/PATTERNS.md`
- The Bluetooth pane and battery cluster (names and the like-pad tie-break, T-359), `shell/src/network` (newest backend pattern)

## Scope
1. `Input1`: `ListControllers` (id, name, family, connection, player, capabilities as separate flags with hardware/driver/available), a `ControllersChanged` signal, and a live state stream for one controller while the test page is open (XML first; service, mock, client).
2. **Settings > Controllers** pane: one row per controller with icon, name, connection, battery, player; opening a row shows its capabilities and **Button test**.
3. **Button test** page: a drawn pad (existing components and tokens; a missing glyph or drawing is an Inbox line) whose buttons, sticks and triggers light up live, the raw values beside it; B held 1 s or pressed twice leaves (the test must be able to show B).

## Out of scope
- Changing anything (T-369), vibration settings (T-373).

## Acceptance criteria
- [ ] Rust tests for capabilities (rumble never implies adaptive triggers; a missing node means not available) and the live stream (starts on open, stops on close).
- [ ] QML tests: the list with three mock pads, the capability rows, the button test lights the pressed control, leaving with B twice and with a 1 s hold; focus asserted after each step.
- [ ] UX: Back leaves every state (except the test's own rule); screenshots of the pane, a row and the button test in en and tr, reviewed; `UX notes:` line.
- [ ] VM (lead run): `vm-input-check.sh` lists the uinput pad with its capabilities; Outcome `Verified: host (vm pending: vm-input-check.sh)`; hw on the Dell.

## Outcome
_Filled in by the implementer._
