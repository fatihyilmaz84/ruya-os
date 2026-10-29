# T-149 — ruya-library: Flatpak games are games

Status: todo · Phase: 5 · Depends: T-112 · Area: services, api · Size: S

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
