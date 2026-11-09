# T-407 - Ruya Web: library and game details, custom artwork and metadata (stored by the Library, not the web)

Status: todo · Phase: 6 · Depends: T-406, T-401 · Area: services (ruya-library: overrides store), services (ruya-web), web front end · Size: M · Owner: builder · Developer surface: internal

## Goal
From a laptop the player browses, searches and filters the library, opens a game's details (installations, size, location, saves summary) and replaces its artwork or title; the TV shows the change.

## Read first
- ADR-029, ADR-028 (installations), T-401, `api/dbus/org.ruyaos.Library1.xml`, the proposal §8 (library, details, artwork)

## Scope
1. The missing platform capability first: per-game metadata and artwork overrides in `ruya-library` (contract, root-only store, size and type checks on images, re-encoded like T-232's vetting), used by the shell too.
2. Web pages: library grid and list, search, filters, details, artwork upload and reset.
3. Remove from library versus delete files: two clearly different actions (delete goes through the Store's uninstall with the admin PIN).

## Acceptance criteria
- [ ] Rust: override store, image vetting, refusal of oversize or non-image files (red without each).
- [ ] Web tests for the pages; VM (lead run): `vm-web-check.sh artwork`; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
