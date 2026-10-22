# T-113 — Games page and home "recent" row from the Library service

Status: todo · Phase: 5 · Depends: T-101, T-112 · Area: shell · Size: M

## Goal
The Games tile opens a grid of installed games, and home gains a "Recently played" row. Both come from `org.ruyaos.Library1` (mock on Windows), and launching records a request.

## Read first
- `api/dbus/org.ruyaos.Library1.xml` (from T-112) and the T-112 Outcome
- `docs/specs/02-shell.md` §1 (Home, Library rows), §6 (art loading rules)
- `shell/src/profiles/` (backend pattern)

## Scope
1. `shell/src/library/`: `LibraryBackend`, `MockLibraryBackend` (about 10 items, mixed Steam/Flatpak games and apps, varied `last_played`), `DBusLibraryBackend`, and a `Library` singleton exposing `items`, `games`, `recent` (top 8 by `last_played`), `rescan()` and `launch(id)`.
   - `launch` only emits `launchRequested(id, launchSpec)` in this task; the mock records it. Actual launching belongs to the future session service.
2. `GamesPage.qml`:
   - a grid of game tiles with generated art (title initials plus a colour from the id hash), 5 columns at 1080p, D-pad navigation, and a filter ChoiceRow (All / Steam / Flatpak);
   - Accept on a tile → `Library.launch(id)` plus a toast "Starting <title>…" if T-108 is done.
3. Home: add a "Recently played" row above the section tiles. Up/Down moves between the two rows, and focus restoration covers both rows.
   - Keep the existing section tiles and the T-101 behaviour intact.
4. Empty states: no games → "No games yet — visit the Store" with a button that opens the Store page.

## Out of scope
- Real launching, running-app tracking, the "close game" overlay action.
- Fetching real art (Steam CDN etc.) — later, via the asset pipeline (spec §6).

## Acceptance criteria
- [ ] The Games grid shows only `kind == game` items; the Steam/Flatpak filter works (test `tst_games.qml::test_grid_and_filter`).
- [ ] Accept on a game emits `launchRequested` with that id (test `test_launch_request`).
- [ ] The home recent row is sorted by `last_played` and limited to 8 (test `test_recent_row`).
- [ ] Up/Down moves between the recent row and the section tiles; Back from a page restores focus to the row and item it came from (test `test_home_two_rows_focus`).
- [ ] An empty library shows the empty state, and its button opens the Store (test `test_empty_state`; use a test-only mock reset).
- [ ] Screenshots `20-home-recent.png` and `21-games-grid.png`.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` §1: Home and Library rows reflect what exists.

## Outcome
_Filled in by the implementer._
