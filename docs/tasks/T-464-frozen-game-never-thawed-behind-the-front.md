# T-464 — A frozen game is never thawed behind another game

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
A game the Hub froze stays frozen until the player resumes it. Today a frozen game can be thawed by accident and then runs unseen behind the game in front, at full CPU and GPU.

## Found (lead-11 study on the Dell, 0.0.64, 2026-11-11)
- BombSquad frozen (Hub, then Home). Launching Asteroid Shooter: pygame closes its first window and opens a second. When the first window went, `Shell.qml` `dropRecord()` made the last shown app (the frozen BombSquad) the focused app; `HubPause` thawed it (it thaws the focused app); the new Asteroid Shooter window then took the front, and BombSquad ran on unseen at 116 % of a core.
- The same fallback runs when a just-launched game crashes at start (Superfluous Returnz segfaults on 0.0.64).
- Reproduced with a D-Bus `Launch`; the Play button path (with the launch splash) is not checked yet.
- Also seen: a thawed SuperTuxKart left off-screen kept 33 % of a core.

## Read first
- `02` §1.6 (the Hub freezes the app; Home leaves it frozen; Switch to thaws the chosen app and leaves the old one frozen); T-457's Outcome (HubPause, the sweep); T-459 (instances by process)
- `shell/qml/Shell.qml` (`dropRecord`, the focused-app fallback, `addApp`/`removeApp`), `shell/qml/HubPause.qml`

## Scope
1. When the front app's window goes, the shell never makes a frozen app the front app by itself: it shows Home (or the launch splash while a launch is in flight) instead. Only the player's Resume / Switch to thaws a frozen app.
2. Belt and braces: an app that is not in front and was frozen by the Hub (HubPause's `asked` list) is frozen again if anything thaws it while another app is in front (decide where this belongs, HubPause or Shell, and say why).
3. Check the Play path with the splash and the crash-at-start path (mock: an app whose first window closes before a second opens; an app that exits during launch).

## Acceptance criteria
- [ ] Frozen A behind Home, launch B whose first window closes and a second opens: A stays frozen, B is in front (test)
- [ ] Frozen A, launch B that exits during launch: A stays frozen, Home shows with the crash toast (test)
- [ ] The player's Resume of A from Home or Switch to A from the Hub still thaws it (existing tests stay green)
- [ ] VM (lead run): extend `scripts/vm-session-check.sh` (or `vm-app-check.sh`) with frozen A + a B whose window is recreated; `Verified: host (vm pending: <check>)`
- [ ] `dev.ps1 test` ALL GREEN

## Hints
- Planned by lead-11 from the frozen-game study (`output\frozen-study\` on the lead's checkout, not tracked). The mock session backend already has stop delays and stubborn stops (T-458); add what a recreated first window needs.

## Outcome
_Filled in by the implementer._
