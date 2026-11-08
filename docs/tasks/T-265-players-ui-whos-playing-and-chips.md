# T-265 — Players UI: "Who's playing?" dialog, player chips, Settings > Players

Status: todo · Phase: 2 · Depends: T-264, T-223 · Area: shell · Size: M · Owner: builder · Developer surface: none

## Goal
A second person can pick up a pad and join: a non-blocking "Who's playing?" dialog on that pad (profile list, Guest, Skip), player chips (P1/P2 + avatar) in the top-right cluster, a disconnect toast, and a Settings page to manage slots. Part of epic ADR-017 (T-263).

## Read first
- ADR-017, the shell UX section written by T-263 (`02-shell.md`), `04-design-system.md` §5 components, §8 review list
- T-223 battery chips (`shell/qml`), T-260 onboarding and `DeviceIcons`, `shell/PATTERNS.md` (modals, settings rows), `shell/CLAUDE.md`

## Scope
1. Dialog shown when an unassigned pad is used (first button or connect) while a session is active **and** the running app supports several players, or when opened from Settings. Never nag for a spare paired pad. Any pad may navigate it (ADR-017). Assigning needs no PIN.
2. Player chips next to the battery chips (same icon family; `fitChips()` rules), disconnect toast "Controller 2 disconnected" with a pause hint, reassign dialog on reconnect.
3. Settings > Bluetooth & controllers > Players: slots, change/clear, per-pad default owner, "Guest sessions: ask / allow / off". Existing components only; Turkish strings.
4. Focus is correct after the dialog closes; non-slot-1 pads never reach admin pages.

## Out of scope
- Virtual pads (T-266), default owner at login (T-267), guest lifecycle (T-268).

## Acceptance criteria
- [ ] `tst_players.qml`: dialog appears only under the conditions above; assign, skip, Guest; chips reflect slots; toast on disconnect; focus after close.
- [ ] Screenshots of the dialog, the chips with two players and the Players page, read against `04` §8.
- [ ] UX line in the Outcome (see PLANNING.md): 10-ft readability, the dead-end check (Back leaves every state).
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `02-shell.md`, `04-design-system.md` if a component was added (not expected).

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
