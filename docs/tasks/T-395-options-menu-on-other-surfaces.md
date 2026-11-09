# T-395 - Options menu on the other surfaces: Store cards, Downloads rows, device rows

Status: todo · Phase: 3 · Depends: T-394 · Area: shell · Size: S · Owner: builder · Developer surface: none

## Goal
The same Options menu (T-393, built in T-394) appears everywhere T-393's table says: Store cards, Downloads rows (when T-391 exists), Bluetooth and controller rows, so the Menu button means the same thing on every screen.

## Read first
- T-393's Outcome (the table per surface), T-394's Outcome (`OptionsMenu` API), the pages named in the table

## Scope
1. Wire each remaining surface of T-393's table; a surface whose backend is not built yet (Downloads before T-391) is left out with an Inbox line.
2. A surface with no menu ignores the Menu button visibly the same way everywhere (no menu, no sound), as T-393 decides.

## Acceptance criteria
- [ ] QML: per surface, Menu opens the menu with the table's rows; focus after close (red without each).
- [ ] Screenshots of each new surface reviewed; `dev.ps1 test` and `shots` ALL GREEN.

## Outcome
_Filled in by the implementer._
