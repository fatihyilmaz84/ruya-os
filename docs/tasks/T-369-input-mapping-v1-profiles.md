# T-369 - Mapping v1: button layout, remapping, dead zones, curves; global profiles with import and export

Status: todo · Phase: 2 · Depends: T-368 · Area: api, services (input), shell (Controllers pane) · Size: M · Owner: builder · Complexity: complex · Developer surface: public-format

## Goal
The player can swap to a Nintendo layout, remap any button, set stick dead zones and a response curve per controller, and the settings survive reboots and can be exported and imported. Requirements §5.1-5.2, §9 (global level), Phase 2.

## Read first
- ADR-024, `docs/specs/06-input.md` (mapping model, schema v1), `docs/specs/schemas/input-profile-v1.json`; T-368's pane; `docs/developers/api-surface.md` (public-format)

## Scope
1. Mapping engine: button to button, axis inversion and scaling, inner/outer/anti dead zone, Linear/Precise/Aggressive curves, trigger threshold; no smoothing by default; applied to the virtual pad of T-367 (navigation keeps the shell's fixed meaning: the shell's A is always the shell's A after a layout swap, decided in `06`).
2. Profiles: a global profile per controller identity and console profile, stored as schema-v1 JSON by the service (root-only state, as other services do), validated on load; reset; export to and import from a USB drive (untrusted: validated, size-capped).
3. Pane: Button layout, Remap (press the button to change, then the new one), Dead zones and curve per stick with a live preview from the T-368 stream, Reset, Export, Import.

## Out of scope
- Game and platform profiles (T-370), keyboard/mouse targets, layers, chords (T-372).

## Acceptance criteria
- [ ] Rust tests: each mapping type, dead-zone and curve maths (table tests), schema validation (bad files refused with a reason), inheritance from the built-in default, import size cap; red when removed.
- [ ] QML tests for every new row and the remap flow, focus asserted; screenshots en/tr reviewed; `UX notes:` line.
- [ ] Public format: the schema, a paragraph in `docs/developers/`, a sample profile, a conformance test (ADR-022).
- [ ] VM (lead run) in `vm-input-check.sh`: a remap changes the virtual pad's output; hw on the Dell.

## Outcome
_Filled in by the implementer._
