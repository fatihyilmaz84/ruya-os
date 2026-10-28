# T-113 — Library client and Games page with art cards

Status: todo · Phase: 5 · Depends: T-101, T-112, T-143 · Area: shell · Size: M

## Goal
The Games tile opens a grid of installed games drawn as art cards, from `org.ruyaos.Library1` (mock on Windows); launching records a request. The art card is built here as the shared component the art-led Home (T-146) reuses.

## Read first
- `api/dbus/org.ruyaos.Library1.xml` (from T-112) and the T-112 Outcome
- `docs/specs/02-shell.md` §1 (Home, Library rows), §6 (art loading rules); `docs/specs/04-design-system.md` §3–§5 (tiles, focus, tokens; new components allowed: none without the lead)
- `shell/src/profiles/` (backend pattern)

## Scope
1. `shell/src/library/`: `LibraryBackend`, `MockLibraryBackend` (about 10 items, mixed Steam/Flatpak games and apps, varied `last_played`), `DBusLibraryBackend`, and a `Library` singleton exposing `items`, `games`, `recent` (top 8 by `last_played`), `rescan()` and `launch(id)`.
   - `launch` only emits `launchRequested(id, launchSpec)` in this task; the mock records it. Actual launching belongs to the future session service.
2. `GamesPage.qml`:
   - a grid of `ArtCard.qml` (04 §5: 16:9, title on the caption fade, card focus, state pills; no art yet, so the fallback: initials on a tint from the id hash), 4 columns at 1080p, D-pad navigation, and a filter ChoiceRow (All / Steam / Flatpak);
   - Accept on a tile → `Library.launch(id)` plus a toast "Starting <title>…" (`Notifications.show`, T-108 is done).
3. `Library.recent` is exposed and tested here; showing it on Home is T-146 (the art-led Home), not this task.
4. Empty states: no games → "No games yet — visit the Store" with a button that opens the Store page.

## Out of scope
- Real launching, running-app tracking, the "close game" overlay action.
- Fetching real art (Steam CDN etc.) — later, via the asset pipeline (spec §6).

## Acceptance criteria
- [ ] The Games grid shows only `kind == game` items; the Steam/Flatpak filter works (test `tst_games.qml::test_grid_and_filter`).
- [ ] Accept on a game emits `launchRequested` with that id (test `test_launch_request`).
- [ ] `Library.recent` is sorted by `last_played` and limited to 8 (test `test_recent`).
- [ ] `ArtCard` shows the fallback art, the title and a Running/Installing pill when set (test `tst_artcard.qml`).
- [ ] An empty library shows the empty state, and its button opens the Store (test `test_empty_state`; give `Library` a test-only `resetMockForTests("empty")` like `Profiles` has).
- [ ] Screenshot `21-games-grid.png` reviewed against `04` §8.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` §1: Home and Library rows reflect what exists.

## Hints
- **UI rules since T-117:** colours and durations come from `Theme` tokens (the token lint in `dev.ps1 shell` fails on quoted hex colours, `Qt.rgba(` and literal non-zero `duration:`). Generated tile colours can use `Qt.hsla(hash, …)`, which the lint does not flag.
- The home `Tile` takes its accent from `Theme.tileAccent(key)` (since T-117), so it is not a fit for game tiles; build a small game-tile component (copy the focus ring and scale from `Tile.qml`, and respect `Theme.reducedMotion` for any pulse).
- Home focus is routed by `Shell.focusCurrent()`/`routeFocus()`; adding a second row means extending that single place, not adding another `forceActiveFocus` elsewhere.

## Outcome
_Filled in by the implementer._
