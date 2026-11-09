# T-372 - Keyboard and mouse output, action layers, chords and controller shortcuts

Status: todo · Phase: 3 · Depends: T-369 · Area: services (input), shell (Controllers pane, shortcuts) · Size: M · Owner: builder · Complexity: complex · Developer surface: public-format

## Goal
Games without controller support are playable with the pad (WASD, mouse camera, clicks), a modifier can switch to another layer, and Guide chords (Guide + X screenshot, Guide + B back to the shell) are configurable without breaking games. Requirements §5.1 (keyboard/mouse targets, long/double press, toggle, hold, turbo), §5.3-5.4, §7.2, §11.4.

## Read first
- ADR-024, `docs/specs/06-input.md`, the schema v1, T-369 Outcome; `shell` Guide handling (`KeyRouter`), `docs/specs/02-shell.md` §4.3

## Scope
1. Virtual keyboard and mouse per profile (ACL as in T-367), mapping targets for keys, mouse buttons, mouse motion from an axis, scroll.
2. Layers (momentary, toggle, priorities) and chords; long/double press, toggle, hold, turbo with rate limits; macros as data (sequence, delays, cancel, limits); no stuck keys on a layer change.
3. Controller shortcuts with conflict handling (a per-game "pass Guide chords to the game" switch); the shell's own Guide meaning is never lost.

## Acceptance criteria
- [ ] Rust tests per behaviour (table tests), including "layer change releases held outputs" and macro rate limits.
- [ ] QML tests for the layer and shortcut rows; screenshots en/tr; `UX notes:` line; schema and docs updated (public format).
- [ ] VM (lead run): `vm-input-check.sh` drives the virtual mouse from a stick.

## Outcome
_Filled in by the implementer._
