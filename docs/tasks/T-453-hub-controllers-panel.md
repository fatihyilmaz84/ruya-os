# T-453 — Hub Controllers panel

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
From the Hub over a game the player sees every connected controller, its battery and how it is connected, and can jump to the controller settings.

## Read first
- ADR-033; `02` §1.6 (T-447's Controllers panel); `04` §3, §4, §8
- `Devices1.Bluetooth`, `Devices1.Batteries`, `InputPresent` in `api/dbus/org.ruyaos.Devices1.xml`; the status cluster (T-223) and the Settings controllers pane

## Scope
1. The Controllers panel: one row per connected pad (name, family glyph where we have one, battery level and charging where reported, USB or Bluetooth).
2. "Controller settings" opens the Settings pane (leaving the Hub: level 3 of ADR-033).
3. Mapping, profiles and player slots are not here (Ruya Input, T-366..T-374): the panel shows no control for them.

## Acceptance criteria
- [ ] Two pads on the mock show two rows with their battery and connection (test); none connected: one line that says so (test)
- [ ] A pad that disconnects while the panel is open leaves it without moving the focus out of the panel (test)
- [ ] UX: Back lands on the Controllers entry; readable at 10 ft; `UX notes:` line
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
