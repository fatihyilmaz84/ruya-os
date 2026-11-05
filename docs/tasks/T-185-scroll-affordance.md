# T-185 — Scroll cue: a long Settings pane shows that more rows exist

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

## Goal
Since T-170 and T-175 no half-cut row hints that a Settings pane continues below the viewport. A viewer on the sofa can't tell. Add the cue the lead chose (design decision below).

## Design decision (lead, 2026-11-05)
**An edge fade, no new icon:** while rows exist below the viewport, the bottom edge of the pane fades into the page background over one `Theme` spacing step (about 1.5 rows of fade is too much; keep it to the height of the focus ring's margin plus half a row), and likewise at the top once the pane has scrolled. The fade is in the page colour, so it is a gradient `Rectangle`, not `MultiEffect` (which draws nothing under the offscreen renderer). It follows the scrolled state in both directions and is not shown when everything fits. Reduced motion: it only appears/disappears, no animation (it fades in with the existing short duration token otherwise). Add the pattern to `04-design-system.md` §5 as one built component or rule, with its tokens; add a new token only if no spacing/colour token fits (and put it in `Theme.qml` and the spec in the same commit).

## Read first
- `docs/specs/04-design-system.md` §5 (components), §8 (screenshot review list), the Settings scrolling text
- `shell/qml/SettingsPane.qml` (the flickable and the focus-follows scrolling), `shell/qml/Theme.qml`
- `docs/tasks/T-170-settings-pane-polish.md` and `T-175-settings-list-fits-and-pane-hints.md` Outcomes (why the cut row went away)

## Scope
1. Implement the fade in `SettingsPane` (so every pane gets it), driven by the flickable's `atYBeginning`/`atYEnd`/`contentHeight`.
2. Spec update in `04` §5, and mention in `shell/PATTERNS.md` if a pane author has anything to do (ideally nothing).

## Out of scope
- Scrollbars, chevrons, other scrolling lists (Store grid, Games), any change to focus scrolling.

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
Verified: host (`dev.ps1 test` ALL GREEN; `dev.ps1 shots` ALL GREEN, screenshots read). No VM needed.

Round 2 (after the round-1 review and the revised design decision). Built:
- **Look-ahead scrolling** in `SettingsPane.ensureFocusedVisible()`: it scrolls, in whole rows and as little as possible, so the row above and the row below the focused one are whole in view when such rows exist; when the pane cannot show three rows it falls back to the focused row alone. The focused row therefore touches the pane edge only as the first or last row.
- **The cue is the peek row's opacity.** `updatePeek()` (called from `updateView()`) sets `peekAbove` / `peekBelow` (the first / last visible row while rows exist beyond it; never the focused row) and sets every column child's opacity to `Theme.peekOpacity` (new token, 0.5) for those and 1 for the rest. `SettingControl` has `Behavior on opacity` with `Theme.focusMs` (0 under reduced motion: no animation). Nothing is dimmed when everything fits. A pane must not bind `opacity` on a row (noted in PATTERNS).
- Removed round 1's gradient rectangles, `moreAbove`/`moreBelow` and the `edgeFade`/`edgeFadeClear` tokens.

Screenshots read (`output/shell-shots/review/28a-, 28b-, 28c-settings-scroll-*.png`, Bluetooth pane filled): top (the focused first row is clear, the last visible row is dimmed), middle (the focused row is one row above the dimmed bottom peek row, its ring fully white, the top peek row dimmed), end (focused last row clear, only the top peek row dimmed). 0.5 reads as a clear "more" cue and the peek text is still legible, so the start value stayed. The backdrop shows through, no hard line, no square corners.

Tests (`tst_settings.qml`): `test_scroll_cue_walks_down_and_up` walks Down then Up through the filled Bluetooth pane and at every step asserts the focused row's opacity is 1, that it is not a peek row, that it lies whole inside the viewport, that the row below (down) / above (up) is whole in view too, and that every row's opacity is `peekOpacity` for the peek rows and 1 otherwise; at the first row there is no top peek, at the last no bottom peek. `test_scroll_cue_hidden_when_everything_fits` (Display pane, walked), `test_scroll_cue_has_no_animation_under_reduced_motion`, `test_look_ahead_keeps_whole_rows_and_the_first_and_last_row_reachable` (reuses `checkRowsInside`), `test_zz_screenshots_scroll_cue`. Revert checks: (a) the dimming line set to `opacity = 1` fails the walk test and the reduced-motion test; (b) look-ahead reduced to the old minimal scrolling (`place(i, i)`) fails the walk test at "down 5: the next row below is visible too". Both restored. No existing test needed changing: the T-170/T-175 whole-row tests (`checkRowsInside`) pass unchanged with look-ahead.

Files: `shell/qml/SettingsPane.qml`, `shell/qml/controls/SettingControl.qml`, `shell/qml/Theme.qml`, `shell/tests/tst_settings.qml`, `docs/specs/04-design-system.md` (3.1 token row "Peek", 5 Settings pane row), `shell/PATTERNS.md`.

Deviations from the first design (round 1, the near-black gradient overlay): replaced by peek-row opacity and look-ahead scrolling as the revised decision says; the overlay hid the focused row's ring and did not match the tinted backdrop. The old "Known limit" (ring dimmed at the edge) no longer exists: the focused row is never under the cue. Peek rows are chosen over laid-out rows (any visible child of the column), not only focusable ones.

Canvas: this changes the design system, so the owner's design canvas board "Settings" needs the peek-row cue (first / last visible row of a long pane at `peekOpacity` 0.5, look-ahead focus scrolling); 04 section 8.
