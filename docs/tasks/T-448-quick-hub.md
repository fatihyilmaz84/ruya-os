# T-448 — The Quick Hub: status row, quick tiles, running and recent games

Status: todo · Phase: 2 · Depends: T-447 · Area: shell · Size: M · Owner: builder · Complexity: normal · Developer surface: none

## Goal
Guide opens Ruya Hub's first level: the time, network and battery at the top, the running game and Resume, the other running and recent games, a row of quick tiles and the entries to the panels, all with a controller.

## Read first
- ADR-033 (`00-overview.md`); `02` §1.4 as written by T-447; `04` §3, §4, §5, §8 (new tokens or components allowed: only those T-447 specified)
- `shell/qml/QuickMenu.qml`, the status cluster (T-223), `shell/PATTERNS.md`

## Scope
1. Restructure `QuickMenu.qml` into the Quick Hub of `02` §1.4: status row (reuse the status cluster), the app header with Resume first, Switch to <app> per other running app, up to 4 recent games (`Library.recent`; Accept launches through `Shell.launchApp`), the tiles row and the panel entries.
2. Tiles that already have a backend: Wi-Fi (on/off and the network name), Bluetooth (on/off), mute. A tile whose backend is not built yet (microphone, brightness) is absent.
3. A panel entry appears only when its panel exists (Volume and Power today; the others arrive with their tasks).
4. Keep T-147's behaviour: Resume, Home, Close game, Switch profile, Power; T-147's tests stay green unchanged.

## Out of scope
- The Audio, Performance and Controllers panels (T-450, T-452, T-453); display tiles (T-454); per-pad Guide (T-456).

## Acceptance criteria
- [ ] Guide over an app focuses Resume; Down reaches the tiles and entries in the order of `02` §1.4 (test: `tst_quickmenu.qml::test_quick_hub_order`)
- [ ] A recent game launches from the Hub and the Hub closes (test)
- [ ] The Wi-Fi, Bluetooth and mute tiles change the mock's state and show it (one test per tile)
- [ ] Without an app: the same Hub minus the app part (test)
- [ ] UX: from every new state Back leaves; focus lands on Resume or the first row after open; readable at 10 ft; Outcome has a `UX notes:` line
- [ ] `dev.ps1 test` ALL GREEN; `shots` of the Hub over an app and without one reviewed

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `02` §1.4 built marks.

## Hints
- Planned by lead-10 (ADR-033). `vm-app-check.sh flow` counts `focus quickMenuItem_resume`: keep that objectName or update the check in the same commit.

## Outcome
_Filled in by the implementer._
