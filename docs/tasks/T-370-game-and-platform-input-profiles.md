# T-370 - Game and platform controller profiles: inheritance, applied on focus, a Controller entry on the game page

Status: todo · Phase: 3 · Depends: T-369 · Area: services (input), shell (game page, Controllers pane) · Size: M · Owner: builder · Complexity: complex · Developer surface: none

## Goal
A game can have its own controller setup (or its launcher's, such as Heroic or RPCS3), it is applied when the game takes the focus and dropped when it leaves, and the player reaches it from the game's page. Requirements §9.1-9.4, §11.3.

## Read first
- ADR-024, `docs/specs/06-input.md` (profile hierarchy), T-369 Outcome; the library's stable game ids (`docs/specs/03-services-and-apps.md`), the game page QML

## Scope
1. Profiles keyed by the stable game id and by platform (launcher app id); game over platform over global over built-in; a child stores only its overrides.
2. The active profile switches with the focused app (T-367's routing), without stuck inputs.
3. Game page: **Controller** entry showing the active profile with Change, Customize (the T-369 editor scoped to the game), Reset to default; Duplicate and Delete in the Controllers pane's profile list.

## Out of scope
- Community profiles (owner-level, later), Steam's own configuration.

## Acceptance criteria
- [ ] Rust tests: precedence, overrides-only storage, switch on focus with neutral state, deleting a parent.
- [ ] QML tests for the game page entry and the profile list; screenshots en/tr; `UX notes:` line.
- [ ] VM (lead run): `vm-input-check.sh` applies a game profile when the test app takes the focus.

## Outcome
_Filled in by the implementer._
