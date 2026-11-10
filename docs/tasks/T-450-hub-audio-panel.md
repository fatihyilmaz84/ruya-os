# T-450 — Hub Audio panel and the microphone tile

Status: todo · Phase: 2 · Depends: T-448, T-449 · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
From the Hub over a game the player sets the volume, mutes, picks the output (TV, headset, speaker) and mutes the microphone without leaving the game.

## Read first
- ADR-033; `02` §1.6 (T-447's Audio panel); `04` §3, §4, §8
- `QuickMenu.qml` (the Quick Hub, T-448), the Settings audio pane (reuse its rows)

## Scope
1. The Audio panel of `02` §1.6: master volume, mute, the current output and output selection (`ListOutputs`/`SetOutput`), the microphone list and mute (T-449).
2. The microphone tile on the Quick Hub, present only when `ListInputs` is not empty.

## Out of scope
- Media controls (07 §5.4 needs the app's media info: T-306).

## Acceptance criteria
- [ ] Each control changes the mock's state and shows it (one test each); without a microphone: no mic row and no tile (test)
- [ ] UX: Back from the panel lands on its entry in the Quick Hub; readable at 10 ft; `UX notes:` line
- [ ] `dev.ps1 test` ALL GREEN; `shots` of the panel reviewed

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
