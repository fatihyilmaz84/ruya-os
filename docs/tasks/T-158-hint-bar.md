# T-158 — Hint bar with controller button glyphs

Status: done · Phase: 2 · Depends: T-157 · Area: shell · Size: M · Owner: builder

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
Verified: host

Built `ButtonGlyph.qml` (letter on a `primaryFill` circle, a pill for `LB`/`RB`/`Start`; new token `glyphSize` 40) and `HintBar.qml` (a row of up to four `{ button, text }`, bottom-left in the safe area, `enabled: false` so it never takes focus). One bar sits in `Shell.qml`'s top layer (z 30); `hintList` decides what it says: the Guide overlay (`A` Select, `B` Close; `B` Back in the power choices), an app focused (hidden), a modal (focus inside `modalLayer`, or the picker's PIN pad via `ProfilePicker.pinPadItem`) `B` Cancel, the picker `A` Select, a page `Page.hints` (default `A` Select, `B` Back, overridable), Home `A` Select, `LB`/`RB` Sections. Home's Recent row moved up by the bar's height plus `spaceM`; `Page`'s content area also ends above the bar (not in the Scope, needed so the Settings list does not run into it). Turkish and English strings added (Seç, Bölümler, İptal, Geri, Kapat).

Tests: `tests/tst_hints.qml` (home, page, overlay, modal PIN pad, picker PIN pad, layout at "high" and "performance" tiers, hidden with a stand-in app; focus unchanged throughout). Revert test: undoing the Recent-row move made `test_home_layout` fail. `dev.ps1 test` ALL GREEN; `shots` ALL GREEN, reviewed `01-home.png`, `01-home-tr.png`, `2-pin.png`, new `hints-page.png`.

Deviations: LB and RB are two hints (so Home shows three, not "LB/RB" as one). On Home the hint bar overlaps the dev-only "MOCK SERVICES" badge at the bottom left (mock builds only). The setup wizard shows no hints. Files: ButtonGlyph.qml, HintBar.qml, Shell.qml, Page.qml, ProfilePicker.qml, Theme.qml, CMakeLists.txt, tests/tst_hints.qml, i18n, specs 02/04, PATTERNS.md.
