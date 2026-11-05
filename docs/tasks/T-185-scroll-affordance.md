# T-185 — Scroll cue: a long Settings pane shows that more rows exist

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

## Goal
Since T-170 and T-175 no half-cut row hints that a Settings pane continues below the viewport. A viewer on the sofa can't tell. Add the cue the lead chose (design decision below).

## Design decision (lead, 2026-11-05; revised after the round-1 review)
**Peek and fade the row, no overlay.** Round 1 drew a near-black gradient over the pane edges. A fixed colour cannot match the tinted Settings backdrop (hard line at the clip edge, square dark corners past the pills' rounded ends) and it dimmed the focused row, which 04 §1 and §4 forbid (the ring is never faded). So:
1. **Whole-row look-ahead scrolling** (scope widened: focus scrolling may change). When focus moves down and scrolls, scroll in whole rows so the next row below the focused one is also visible (when there is one); moving up, keep the row above visible (when there is one). The focused row touches the pane edge only when it is the first or last row, and there nothing is hidden beyond it, so no cue is shown.
2. **The cue is the peek row's opacity:** the row that sits partly or fully in the peek position (the first or last visible row while rows exist beyond it) is drawn at a new `Theme.peekOpacity` (a token, not `disabledOpacity`, which means "unavailable"; start near 0.5 and judge in the screenshots), so the backdrop shows through whatever its tint. No gradient rectangle, no `edgeFade`/`edgeFadeClear` tokens (remove them again). The peek row is never the focused row. Not shown when everything fits. Reduced motion: no animation; otherwise the existing short duration token.
3. Spec 04 §5 (Settings pane) and §3.1 (the token), `shell/PATTERNS.md` (nothing for pane authors to do), and mark the commit `design:` naming the canvas board to update (04 §8).

## Read first
- `docs/specs/04-design-system.md` §5 (components), §8 (screenshot review list), the Settings scrolling text
- `shell/qml/SettingsPane.qml` (the flickable and the focus-follows scrolling), `shell/qml/Theme.qml`
- `docs/tasks/T-170-settings-pane-polish.md` and `T-175-settings-list-fits-and-pane-hints.md` Outcomes (why the cut row went away)

## Scope
1. Implement the fade in `SettingsPane` (so every pane gets it), driven by the flickable's `atYBeginning`/`atYEnd`/`contentHeight`.
2. Spec update in `04` §5, and mention in `shell/PATTERNS.md` if a pane author has anything to do (ideally nothing).

## Out of scope
- Scrollbars, chevrons, other scrolling lists (Store grid, Games). (Focus scrolling may change as in the design decision; keep T-170/T-175's whole-row and `checkRowsInside` guarantees.)

## Acceptance criteria
- [ ] `tst_settings.qml`: a pane taller than the viewport reports "more below" at the top, both cues once scrolled to the middle, "more above" only at the end; a short pane shows none. Properties asserted (`visible`/`opacity`), not pixels.
- [ ] Revert check: the test fails without the binding.
- [ ] `dev.ps1 shots`: a long pane (e.g. Audio or Storage with several rows) at top and scrolled, read against `04` §8: the fade is visible, doesn't cover the focus ring of the focused row, the last row is still fully readable when scrolled to the end.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `04-design-system.md` §5; `shell/PATTERNS.md` if needed.

## Hints
- Offscreen tests run the software renderer: assert state, not pixels.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
