# T-452 — Hub Performance panel

Status: todo · Phase: 2 · Depends: T-448, T-451 · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
From the Hub over a game the player opens Performance and reads FPS, frame time, CPU, GPU, RAM, VRAM, temperatures and power, with each unsupported value said plainly.

## Read first
- ADR-033; `02` §1.6 (T-447's Performance panel); `04` §3, §4, §8; T-451's Outcome

## Scope
1. The Performance panel of `02` §1.6 over the T-451 client; numbers update at the chosen interval only while the panel is open.
2. States: unsupported shows "Not available on this console", unavailable and stale say so; no dashes that look like zero.
3. The interval as a row in the panel or in Settings (as T-447 decides).

## Out of scope
- A permanent on-screen counter over the game (a later task if the owner wants it); tuning controls (07 §5.3, excluded).

## Acceptance criteria
- [ ] Each metric state renders its text (one test per state, mock)
- [ ] Polling starts on open and stops on close (test)
- [ ] UX: Back lands on the Performance entry; readable at 10 ft; `UX notes:` line
- [ ] `dev.ps1 test` ALL GREEN; `shots` of the panel with all states reviewed

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `02` §1.6 built marks.

## Hints
- Planned by lead-10 (ADR-033).

## Outcome
_Filled in by the implementer._
