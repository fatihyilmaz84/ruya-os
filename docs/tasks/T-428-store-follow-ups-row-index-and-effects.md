# T-428 - Store follow-ups: a row remembers its card, a scrolled shot, card effects only where needed

Status: in-progress · Phase: 2 · Depends: — · Area: shell (Store page) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
The Store keeps T-377's fast open and loses its rough edges: a row built late still lands on the card the player left, and each card draws only the effects it needs.

## Read first
- `docs/tasks/T-377-*.md` (Outcome and review notes), `docs/specs/04-design-system.md` §3.6, §5 (cards, lift), principle 5
- The Store page QML (`rowIds`, `slotY`, the lazy rows), the card component with its lift shadow, halo and glare `MultiEffect`s; `scripts/page-open-bench.py`

## Scope
1. A Store row not built yet keeps its remembered card index: a `pendingIndex` applied when its model fills (test: leave row 3 at card 2, rebuild, return: card 2 focused).
2. `slotY` is not recomputed for every row on each `rowIds` change (only rows whose position changed), with a test that counts recomputes.
3. Make each card's halo and glare `MultiEffect` exist only on the focused card, keep the lift shadow's fade-in (test: one halo/glare instance on the page; focus move keeps it on the focused card).
4. A `shots` case of the Store scrolled to "Apps & media".

## Out of scope
- New Store content or layout.

## Acceptance criteria
- [ ] Items 1-3 tested (named in the Outcome); item 3's test is red without the change.
- [ ] The host offscreen open bench (`page-open-bench.py` or the existing timing test) is not worse than T-377's 31-49 ms max frame.
- [ ] hw (lead run): on the Dell, `page-open-bench.py` Store, 5 opens, max frame under 50 ms; mark `unverified` until the lead runs it.
- [ ] UI tasks - UX: focus lands on the remembered card after Back; Outcome has a `UX notes:` line.
- [ ] `dev.ps1 test` and `shots` ALL GREEN; the new Store shot reviewed.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/04-design-system.md` §5 if the card's effects are described there.

## Hints
- From the STATUS Inbox (T-377, lead-8), triaged by lead-9 on 2026-11-10. Offscreen draws no `MultiEffect` pixels: assert instances and properties.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
