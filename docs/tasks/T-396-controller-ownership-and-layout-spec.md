# T-396 - Spec: who owns the UI, the family's confirm button, action glyphs (ADR-027 into 02, 04, 06 and T-263)

Status: todo · Phase: 2 · Depends: T-366 · Area: docs (02, 04, 06-input, T-263) · Size: S · Owner: lead · Developer surface: none

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Runs after T-366 (it edits `06-input.md`, which T-366 creates, and needs the engine decision). It fixes for every later task: one owner pad set (not "slot 1"), the action vocabulary (one list of names for the shell, T-374 and T-418), the action-to-glyph table, where family is decided (the shared table of T-261, per event in the input service, built by T-398), and one Settings home (`Settings > Controllers`). Takeover: ADR-027 allows it only when every owner pad is gone (disconnected, battery dead); an idle timeout is not in the ADR and would let any pad take a signed-in profile, so it is out unless the owner asks, and a takeover never enters a PIN-protected profile without the PIN. Replace the criterion "T-397..T-399 and T-263 rewritten" with the list of sections each of them reads.

## Goal
ADR-027 is written into the specs the builders read, so T-397..T-399 can be built without new decisions, and it fits ADR-017 (players and slots) and ADR-024 (Ruya Input owns the pads).

## Read first
- `docs/specs/00-overview.md` ADR-017, ADR-024, ADR-027; `docs/specs/02-shell.md` §4.2-4.3; `docs/specs/04-design-system.md` §3.7 (`ButtonGlyph`); `docs/specs/06-input-requirements.md` §4, §10 (semantic actions, glyphs, recoverability); T-263, T-264, T-265, T-267; `services/ruya-inputd` (where pad buttons become shell keys today)

## Scope
1. **Ownership states** in 02 §4.3: picker (any pad), signed in (owner pads only), owner pads gone (takeover prompt), Guide on a foreign pad ("Switch to <profile>?" / "Who's playing?"), the keyboard; what a foreign pad's press shows (nothing, or a one-time hint toast); how this sits with ADR-017 slots (owner pads = the active profile's slots) before T-264 exists (the pad that signed in).
2. **Family table** in 02 §4.2: Accept/Back/Options/Guide/tab per family (Xbox, PlayStation, Nintendo, generic, keyboard), the JP Circle option and the "Confirm button" Settings row; which layer maps it (`ruya-inputd` now, Ruya Input later).
3. **Action glyphs** in 04 §3.7: the action list, one glyph set per family, drawn by us (shapes for PlayStation), the generic fallback, the active-input rule, the no-flicker rule (switch glyphs on the first input of another device, not on connect).
4. Rewrite T-397..T-399 and amend T-263's scope to include ownership.

## Acceptance criteria
- [ ] 02, 04, 06 updated; T-397..T-399 and T-263 rewritten; `dev.ps1 docs` ALL GREEN.

## Outcome
_Filled in by the implementer._
