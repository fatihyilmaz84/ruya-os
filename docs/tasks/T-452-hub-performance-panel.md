# T-452 — Hub Performance panel

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
From the Hub over a game the player opens Performance and reads FPS, frame time, CPU, GPU, RAM, VRAM, temperatures and power, with each unsupported value said plainly.

## Read first
- ADR-033; `02` §1.6 (T-447's Performance panel); `04` §3, §4, §8; T-451's Outcome

## Scope
0. First (T-450 review): replace the per-key switch functions in `QuickMenu.qml` (panelKeys, panelTitle, labelOf, rowValue, rowChoices, isChoiceRow, rowActivate, the hints branch) with one row-descriptor table per panel (`{ key, label, kind: toggle|choice|slider|info, value(), choices(), activate() }`; hints, the delegate and Left/Right derive from `kind`); the Audio panel's tests stay green unchanged. Also step choice rows from a pending target until Set*Finished answers.
1. The Performance panel of `02` §1.6 over the T-451 client; numbers update at the chosen interval only while the panel is open.
2. Never show held numbers as live (T-451 review): on a failed GetPerformance and on the first open after idle, mark the held metrics unavailable until a fresh answer arrives (fix in `Performance.cpp` with a test). States: unsupported shows "Not available on this console", unavailable and stale say so; no dashes that look like zero.
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
