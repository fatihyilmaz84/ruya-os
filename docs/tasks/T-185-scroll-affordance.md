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

Built: `SettingsPane` gets two public read-only properties, `moreAbove` (`!flick.atYBeginning`) and `moreBelow` (`contentY + viewport.height < column.height`; computed against the viewport, not `atYEnd`, because the clip ends above the pane's bottom when a row is cut off), and two gradient rectangles inside the clip (`fadeAbove`, `fadeBelow`, an inline `EdgeFade` component). Height `Theme.spaceXl * u` (48 design px = the focus ring's 7 px margin plus half a row). Opacity follows the property through a `Behavior` with `Theme.focusMs` (0 under reduced motion), `visible` is `opacity > 0`; the rectangles take no input. Colours: two new tokens in `Theme.qml`, `edgeFade` (`#9905070d`, page colour at 60 %) and `edgeFadeClear` (`#0005070d`); no existing token fit (`artCaptionFade` is 85 % and the gradient's far end must keep the hue). I started at 85 % and the screenshots showed a heavy black band over the tinted backdrop and the top row's text muffled, so it is 60 %.

Screenshots (`output/shell-shots/review/28a-, 28b-, 28c-settings-scroll-*.png`, Bluetooth pane filled): top (fade at the bottom only), middle (both), end (fade at the top only, last row clean). The focused row's ring stays visible at the faded bottom edge, text is readable, and the end screen shows no fade under the last row.

Tests (`tst_settings.qml`): `test_scroll_cue_follows_the_scroll_position` (top: below only; middle: both; end: above only; back at the top; the fade sits on the viewport's bottom edge), `test_scroll_cue_hidden_when_everything_fits` (Display pane), `test_scroll_cue_has_no_animation_under_reduced_motion` (opacity changes at once), `test_zz_screenshots_scroll_cue`. Revert check: with `moreAbove`/`moreBelow` bound to `false` the first and third tests fail (the "fits" test passes by design, it guards the opposite mistake).

Files: `shell/qml/SettingsPane.qml`, `shell/qml/Theme.qml`, `shell/tests/tst_settings.qml`, `docs/specs/04-design-system.md` (3.1 colour row, 5 Settings pane row), `shell/PATTERNS.md`.

Deviations: none. Known limit: the fade is drawn over the focused row when that row is the first or last visible one, and dims the ring's outer edge there (at most 60 % at the very edge); the ring stays clearly visible in the screenshots.
