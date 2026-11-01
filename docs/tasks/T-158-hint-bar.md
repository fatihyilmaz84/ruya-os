# T-158 — Hint bar with controller button glyphs

Status: todo · Phase: 2 · Depends: T-157 · Area: shell · Size: M · Owner: builder

## Goal
The bottom of every screen says what the buttons do right now ("A Select · B Back"), so a new player never has to guess.

## Read first
- `docs/specs/04-design-system.md` §2 (Home and Pages layout: hint bar under the Recent row, safe area), §3.7 (controller glyphs), §5 rows Hint bar and Button glyph, §6 (writing: verbs)
- `docs/specs/02-shell.md` §4.2 (controller mapping)
- `shell/CLAUDE.md` (focus rules), `shell/PATTERNS.md` (adding a page)
- `shell/qml/Shell.qml` (Home layout, Recent row, overlay, modals), `shell/qml/Page.qml`
- Tokens this task may add: `glyphSize` 40. Components: `ButtonGlyph.qml`, `HintBar.qml`.

## Scope
1. **`ButtonGlyph.qml`:** a button letter (`A`, `B`, `X`, `Y`, `LB`, `RB`, `Start`) in `typeMicro` on a `primaryFill` circle (a pill for two-letter names), `glyphSize`, `onPrimary` text.
2. **`HintBar.qml`:** a row of up to four `{ button, text }` hints, laid out as 04 §5 says, bottom-left inside the safe area, never focusable, hidden while an app is focused (the app owns the screen, 04 §1 principle 4).
3. **Where hints come from:** the screen on top supplies them. A default on `Page` (`A` Select, `B` Back), Home (`A` Select; `LB`/`RB` Sections), the Guide overlay (`A` Select, `B` Close), the PIN pad and other modals (`B` Cancel). Pages may override (a page with nothing to select shows only Back). Keep the verbs short (04 §6) and translated, with Turkish.
4. **Home layout:** the hint bar sits under the Recent row; move the row up if needed so nothing overlaps and the bar stays inside the safe area at every tier.
5. Specs: rows become *built*; 02 gets one paragraph on where hints come from.

## Out of scope
- Pad-type glyphs (PlayStation shapes, Switch layout): B-006.
- Hints for actions that don't exist yet (context menu on Y/Start).

## Acceptance criteria
- [ ] Home shows `A` Select and `LB`/`RB` Sections; a page shows `A` Select and `B` Back; the overlay shows `B` Close; the PIN pad shows `B` Cancel (tests, by `objectName` and the hints' texts).
- [ ] The hint bar never takes focus: focus is unchanged after every step above (test).
- [ ] Home: the hint bar's top is below the Recent row's bottom and its bottom inside the safe area, at the default and the Performance tier (property test, not pixels).
- [ ] With an app focused (stand-in app item, as in `tst_compositor_layers.qml`) the hint bar is hidden (test).
- [ ] Turkish hints fit (screenshot `01-home-tr.png`); screenshots `01-home.png`, a page and the PIN pad reviewed against 04 §8.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `04-design-system.md` §2 and §5 (built), `02-shell.md` (hints), `shell/PATTERNS.md` (a page's hints, one line in "adding a page").

## Outcome
_Filled in by the implementer. Start with a `Verified:` line._
