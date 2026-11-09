# T-371 - Ownership modes: direct passthrough and Steam-managed controllers

Status: todo · Phase: 3 · Depends: T-367 · Area: services (input, session), shell (app settings) · Size: M · Owner: lead · Complexity: complex · Developer surface: internal

## Goal
Steam Input (and any app that needs the real controller) works without fighting Ruya: for such an app the profile's user gets the physical pad's nodes for that run and Ruya creates no virtual pad; afterwards everything is as before. Requirements §6.1, §6.3.

## Read first
- ADR-024, `docs/specs/06-input.md` (routing state machine), T-367 Outcome; `services/ruya-session` (launch, run end); Steam on RuyaOS (`docs/specs/03-services-and-apps.md` §4.1)

## Scope
1. A per-app ownership mode (Ruya-managed, Passthrough, Steam-managed), Steam's app id defaulting to Steam-managed; stored by the input service.
2. Passthrough/Steam: for the run, the physical evdev and hidraw nodes of the pads get an ACL for the profile's user (removed at the run's end, crash, lock or switch); no virtual pads; navigation keys stop while the app has the focus; Guide still goes to the shell.
3. A per-game override in the game page (T-370's entry) once T-370 exists; until then in the app's options.

## Out of scope
- Writing Steam's configuration (never), Steam's Big Picture inside our session (its own task).

## Acceptance criteria
- [ ] Rust tests: ACLs granted and revoked on every end of the run (normal, crash, lock, switch); no virtual pad in passthrough; restore of the previous routing.
- [ ] VM (lead run): `vm-input-check.sh passthrough`; hw: Steam sees the DualSense with its own glyphs on the Dell.

## Outcome
_Filled in by the implementer._
