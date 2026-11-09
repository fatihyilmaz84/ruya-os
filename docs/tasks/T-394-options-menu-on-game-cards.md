# T-394 - Options menu on game and app cards: Details, Activity, Uninstall and the rest of T-393's list

Status: todo · Phase: 3 · Depends: T-393, T-386 · Area: shell (OptionsMenu, Home, Games, Library), services (ruya-session usage per game, if T-393 needs it) · Size: M · Owner: builder · Complexity: normal · Developer surface: none

## Goal
On any game or app card in Home, Games and Library, the Menu/Options button (or a long press on A) opens the Options menu of T-393 and every row works: Play, Details, Activity for this game, Open in Store, Uninstall (with the admin PIN and the "delete saved data" choice), and the rows T-393 lists.

## Read first
- T-393's Outcome (component spec, the exact rows), `docs/specs/04-design-system.md` §5 (`OptionsMenu`), `shell/PATTERNS.md` (modals, focus), `shell/qml/GamesPage.qml`, Home's cards, `ActivityPage`, the Store client (`Uninstall`), PinPad (admin gate)

## Scope
1. `OptionsMenu.qml` per 04 (new component, in `shell/CMakeLists.txt`), opened by Menu/Options and by long-press A with the progress ring.
2. The rows of T-393 for game and app cards, each wired; Uninstall runs through the existing Store job and its toast; Activity opens the per-game view (the ledger already has per-app totals: add a filtered view if T-393 asks for it).
3. Focus returns to the card after the menu closes, to the next card after an uninstall.

## Acceptance criteria
- [ ] QML: Menu and long-press open it; each row's action (mock calls asserted); Uninstall needs the admin PIN and passes `delete_data`; Back and Menu close it; focus after close and after uninstall (red without each).
- [ ] Screenshots (en, tr): the menu on a game card at Home and in Games, the Uninstall confirm, a long title; reviewed; `UX notes:` line.
- [ ] `dev.ps1 test` and `shots` ALL GREEN.

## Outcome
_Filled in by the implementer._
