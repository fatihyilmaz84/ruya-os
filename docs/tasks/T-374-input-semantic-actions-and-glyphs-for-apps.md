# T-374 - Semantic actions and controller glyphs for native apps (Platform1)

Status: todo · Phase: 3 · Depends: T-369 · Area: api, services (input, platform), docs/developers, samples · Size: M · Owner: builder · Complexity: complex · Developer surface: public-API

## Goal
A native RuyaOS app registers actions (navigate, select, back, its own), receives them as press/release/repeat events while it has the focus, and asks which glyph to show for an action on the player's controller; the player can rebind the app's actions. Requirements §10.

## Read first
- ADR-022 and `docs/developers/api-surface.md` (Platform1, stability tags), ADR-024, `docs/specs/06-input.md`; T-199 (glyph set and licence: the owner's decision is open)

## Scope
1. `Platform1` methods for action registration, subscription and current state; events only while the app is focused and its profile signed in; capability queries; glyph lookup (family-specific with fallbacks); haptic requests with limits.
2. Rebinding an app's actions in the Controllers pane (T-369 editor).
3. Docs, a sample app, mock support, a conformance test with abuse cases (an unfocused app gets nothing; floods are limited).

## Acceptance criteria
- [ ] Rust tests for focus gating, registration limits and the glyph table; conformance test; `ruya-api-reviewer` clean.
- [ ] The sample runs against the mock (`lint-dev-docs.ps1`).
- [ ] VM (lead run): the sample receives `select` from the uinput pad only while focused.

## Outcome
_Filled in by the implementer._
