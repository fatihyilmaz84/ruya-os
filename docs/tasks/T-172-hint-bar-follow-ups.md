# T-172 — Hint bar follow-ups: one Sections hint, wizard hints, per-page overrides

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

## Goal
The hint bar tells the truth on every screen. Home shows "LB RB Sections" as one hint, the setup wizard shows its own hints, and a page with nothing to select shows only Back. The dev badge no longer crowds the bar.

## Read first
- `docs/specs/04-design-system.md` §2 (Pages), §5 (Hint bar, Button glyph), §6 (verbs), §8; `docs/specs/02-shell.md` §4.3 (where hints come from)
- `shell/qml/HintBar.qml`, `ButtonGlyph.qml`, `Shell.qml` (the hints binding, about lines 860–880), `Page.qml` (`hints`, bottom margin), `SetupWizard.qml`
- `shell/tests/tst_hints.qml`, `tst_pages.qml`

## Scope
1. **One Sections hint:** a hint can carry two buttons (`LB`, `RB`) with one verb, drawn as two glyphs. Home uses one slot for it.
2. **Wizard hints:** each setup step shows what A and B do there (A Select or Next, B Back where Back applies, none where it doesn't).
3. **Per-page overrides:** pages with nothing to select (for example the placeholder page and About) show only "B Back".
4. **Dev badge:** move the mock-only "MOCK SERVICES" badge off the hint bar (for example bottom right, next to the version text).
5. **Spec:** 04 §2 Pages says content ends above the hint bar (`Page.qml` bottom margin, reserved even when `hints` is empty).
6. **Home nav focused:** a screenshot of Home with focus on the nav, so the ring on the filled Home pill gets reviewed.
7. **Shot numbering:** renumber so no two screenshots share a prefix (`26-settings-bluetooth`, `26-restart-notice`).

## Out of scope
- Hints over a running app (T-147 decides the quick menu).
- New tokens; a glyph pair uses `ButtonGlyph` twice.

## Acceptance criteria
- [ ] Home's hint bar has one `Sections` hint with two glyphs (`tst_hints`).
- [ ] Each wizard step shows the expected hints; a step without Back shows none for B (`tst_hints` or `tst_setup`).
- [ ] The placeholder page and About show only `B Back` (`tst_hints`).
- [ ] Screenshots reviewed: `01-home.png` (one Sections hint, badge away from the bar), a wizard step, and the new Home nav-focus shot (ring outside the filled Home pill).
- [ ] `dev.ps1 test` ALL GREEN; `shots` ALL GREEN.

## Docs to update
- `04` §2 and §5, `02` §4.3, `shell/PATTERNS.md` (how a page sets `hints`, and Page's `upFromTop`/`stepRequested`: Up at a page's top row reaches the nav, LB/RB switch sections, a page swallows unaccepted Up/PageUp/PageDown).

## Outcome
Verified: host

Built: `HintBar` accepts `{ buttons: ["LB", "RB"], text }` (two `ButtonGlyph`s, one verb; delegate objectName `hint_LBRB`); Home uses it. `Setup.hints` gives each wizard step its hints (A Next, A Select on the profile step, B Back except first and last step, B Cancel over the keyboard or PIN pad) and Shell shows them; the wizard's own old "B  Back" text is removed. `Page.backOnlyHints` is used by `MediaPage` and `LibraryDetailsPage` (placeholders) and by Settings while About has focus or a category has no pane. The mock-services badge moved bottom right, left of the version tag (`mockBadge`, `versionTag`). `04` section 2 states the bottom margin; `04` section 5, `02` section 4.3 and `shell/PATTERNS.md` updated. New screenshot `01-home-nav.png` (tst_home); the restart-notice shot is now `28-restart-notice.png` (tst_update).

Tests: `tst_hints` (one LB RB Sections hint with glyphs LB,RB; placeholder page and About show only B Back; badge bottom right), `tst_setup::test_hints_follow_the_step`. Screenshots reviewed: 01-home, 01-home-nav (ring outside the filled Home pill), 12-setup-admin.

Deviations: no existing `tst_*` checked hint names, so `tst_hints.shown()` now lists `LBRB`. Other shared screenshot prefixes (`01-home-*`, `15-*`) were left as they are.

