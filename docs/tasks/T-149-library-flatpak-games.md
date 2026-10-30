# T-149 — ruya-library: Flatpak games are games

Status: done · Phase: 5 · Depends: T-112 · Area: services, api · Size: S

## Goal
A game installed from the Store as a Flatpak (e.g. SuperTux) has `kind` `game` in `Library1.ListItems`, so it appears on the Games page (T-113). Today every Flatpak item is an `app`.

## Read first
- `docs/specs/03-services-and-apps.md` §5 (Library row); ADR-005 in `00-overview.md` (AppStream categories)
- `api/dbus/org.ruyaos.Library1.xml`; `services/ruya-library/src/flatpak.rs`, `src/catalog.rs`
- `docs/tasks/T-112-library-service-core.md` Outcome

## Scope
1. Classify each installed Flatpak app by the `Categories` key of its exported desktop entry (`<installation>/exports/share/applications/<id>.desktop`; the system installation is `/var/lib/flatpak`): `Game` among the categories makes it a game, anything else (or no file) an app. Parse the desktop file in the pure core (`[Desktop Entry]` group only, `;`-separated list, localized keys ignored); reading the file stays behind the existing `AppLister` side-effect trait or a sibling trait with a fixture implementation.
2. Fixtures and unit tests; the `--session` demo list gets one game and one app.
3. Contract comment: say how `kind` is decided for each source.

## Out of scope
- Artwork (`art` stays empty), user installations of Flatpak, the image unit (after `ruya-session`, T-130).

## Acceptance criteria
- [ ] Unit tests: `Categories=Game;ArcadeGame;` → game; `Categories=AudioVideo;` → app; no desktop file → app; a malformed file → app without panicking; `Game` only in a non-`[Desktop Entry]` group → app.
- [ ] The merged catalogue test includes a Flatpak game.
- [ ] `.\scripts\dev.ps1 rust` green (clippy for the Linux target included); `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 rust
.\scripts\dev.ps1 test
```

## Docs to update
- Spec 03 §5 Library row; the `Library1.xml` header comment.

## Hints
- `ruya-library` is not in the image yet, so there is no VM criterion; say "D-Bus serving unverified" in the Outcome as T-112 did.

## Outcome
Verified: host (`dev.ps1 rust` and `dev.ps1 test` ALL GREEN). D-Bus serving and the real desktop-file read on Linux unverified (`ruya-library` is not in the image yet; the Linux code type-checks under clippy for the Linux target).

Built: a Flatpak item is a `game` when `Game` is in `Categories` of the `[Desktop Entry]` group of `/var/lib/flatpak/exports/share/applications/<id>.desktop`, else an `app` (no file, malformed file, `Game` only in another group, localized `Categories[xx]` keys all give `app`). `is_game` is pure; reading the file is a second method `AppLister::desktop_entry` (default `None`), so no new trait. `parse_list` now takes the lister. `FixtureLister` became a struct (`new`, `with_desktop`) instead of a tuple struct. The `--session` demo list has a game (Turbo Racer) and an app (Notes, replacing Block Puzzle). Contract comment (`Library1.xml`) and spec 03 §5 say how `kind` is decided.

Files: `services/ruya-library/src/{flatpak,catalog,main}.rs`, `api/dbus/org.ruyaos.Library1.xml`, `docs/specs/03-services-and-apps.md`.

Deviations: none. Only the system installation is read (user installations are out of scope).
