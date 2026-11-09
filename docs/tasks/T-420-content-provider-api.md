# T-420 - Content provider API: apps put their items into Continue watching and the console search

Status: todo · Phase: 7 · Depends: T-352, T-351 · Area: api (a `Platform1` interface), services (ruya-platform, ruya-library), shell (Home row, search), docs/developers, samples · Size: M · Owner: builder · Complexity: complex · Developer surface: public-API

## Goal
A media or game app registers its own items (an episode with its progress, an album, a save slot) and the console shows them in Home's "Continue watching" and in search; choosing one opens the app at that item. Owner decision 2026-11-10 (ADR-031): a new line on ADR-022's tier-B list.

## Read first
- ADR-022, ADR-031, `docs/developers/api-surface.md` (tier-B list, Definition of done for public APIs), T-352 (`ruya-platform`: caller identity), T-306 (now playing: the closest existing pattern), the proposal `docs/archive/research/ai-first-developer-platform-proposal.md` §8, §13.2

## Scope
1. Contract (experimental, `org.ruyaos.Stability`): `PublishItems(kind, items)` (bounded count and size, the app's own items only), `RemoveItems`, `SetProgress`; an `open` action that launches the app with an item id; per profile, keyed by the calling app's identity (never an argument).
2. Library stores them per profile and app; Home gets a "Continue watching" row; search includes them; an uninstalled app's items vanish.
3. Docs chapter, sample (a tiny media app), mock for off-console tests, conformance tests with abuse cases (oversize items, another app's id, spam rate).

## Acceptance criteria
- [ ] Rust and QML tests for each rule above (red without each); the public-API items of `docs/tasks/TEMPLATE.md`.
- [ ] `ruya-api-reviewer` finds no blocking item; VM (lead run): `vm-platform-check.sh content`; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
