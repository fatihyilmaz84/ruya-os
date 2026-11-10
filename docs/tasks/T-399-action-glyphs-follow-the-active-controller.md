# T-399 - Glyphs follow the active controller: action glyphs for Xbox, PlayStation, Nintendo, keyboard and a generic pad

Status: todo · Phase: 2 · Depends: T-396, T-398 · Area: shell (ButtonGlyph, HintBar, every glyph site), services (ruya-inputd: device family per event) · Size: M · Owner: builder · Complexity: normal · Developer surface: none

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Builds the one action-to-glyph table (T-396); T-374 exposes the same table to apps. Family per event comes from T-398.

## Goal
The hint bar and every on-screen button hint show the buttons of the controller the player is holding: Cross/Circle shapes on a PlayStation pad, A/B in Nintendo positions on a Switch pad, letters on Xbox, key caps on the keyboard. Today every glyph is an Xbox letter.

## Read first
- ADR-027, T-396's Outcome (action list, glyph sets, active-input rule), `docs/specs/04-design-system.md` §3.7, `shell/qml/ButtonGlyph.qml`, `HintBar.qml`, every `ButtonGlyph` user (grep), T-398 (the family per event), the owner question on pad art (STATUS: our own drawings only)

## Scope
1. `ActiveInput` singleton: the family of the owner pad that sent the last input, or "keyboard"; changes only on input, never on connect.
2. `ButtonGlyph { action: "accept" }` (an action, not a letter) draws the active family's glyph: our own vector shapes for PlayStation (no vendor artwork), letters for Xbox and Nintendo (Nintendo's A/B follow T-398's mapping), key caps for the keyboard, a generic set; tokens only (a new token or icon is a 04 §8 change in the same commit).
3. Every glyph site in the shell moves from letters to actions (lint: `ButtonGlyph` with a `button:` letter fails `lint-qml-members` or a new lint).

## Acceptance criteria
- [ ] QML: the glyph per family and action; the active input switches on input of another device, not on connect; the keyboard shows key caps (red without each).
- [ ] A lint that refuses letter glyphs.
- [ ] Screenshots of Home's and Settings' hint bars for each family (en), reviewed against 04 §8; `dev.ps1 test` and `shots` ALL GREEN.

## Outcome
_Filled in by the implementer._
