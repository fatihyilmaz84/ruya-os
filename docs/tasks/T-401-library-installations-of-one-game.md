# T-401 - Library: one game, several installations (Flatpak, Steam, .play, ROM), a preferred one, no merging by title

Status: todo · Phase: 5 · Depends: T-302, T-400 · Area: api (Library1), services (ruya-library), shell (Library, game page) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

## Goal
A game installed twice (Steam and a `.play`, or two regions of a ROM) shows once in the Library with its installations listed on the game page; the player picks which one Play uses. Two different games with the same title never merge.

## Read first
- ADR-028, the T-400 Outcome; `api/dbus/org.ruyaos.Library1.xml`, `services/ruya-library`, `docs/specs/03-services-and-apps.md` (Library sources); the proposal §3 (game, installation, identification, duplicates)

## Scope
1. Contract first: `Library1` items become games with `installations` (source, id, location, runner, version or region, available, preferred); identification keys and confidence; `SetPreferredInstallation`, `LinkInstallations`/`UnlinkInstallations` (the player's confirmation).
2. Matching only by ids (Steam app id, Flatpak id, `GameData1.Identify` hash when it exists), never by title; a title match is offered as "Are these the same game?" at most.
3. Shell: the game page lists installations; Play uses the preferred one; the Options menu (T-394) gets "Choose installation".

## Acceptance criteria
- [ ] Rust: matching rules (same title, different ids: two games; same Steam id from two sources: one game), preference persistence, link/unlink (red without each).
- [ ] QML: the game page's installations and the preferred choice; screenshots reviewed.
- [ ] Contract, mock, client agree; VM (lead run): `vm-library-check.sh installations`; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
