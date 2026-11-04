# T-175 — Settings: the category list fits above the hint bar; panes supply their own hints

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

## Goal
On Settings the last category ("About") stays clear of the hint bar at every tier. Its selected pill and focus ring never cover the A/B glyphs. Each pane says which hints it shows, so a new pane can't end up with the wrong ones. The setup wizard's prose reads as body text, not a bold headline.

## Read first
- `docs/specs/04-design-system.md` §2 (Settings two-pane, Pages: content ends above the hint bar), §3.2 (type steps and weights), §5 (category item, hint bar), §8
- `shell/qml/SettingsPage.qml` (the category list at about lines 40–75 and the hints special case at about line 46), `SettingsPane.qml` (whole-row scrolling, T-170), `Setup.qml` (the multi-line copy at about lines 515, 551, 587)
- `shell/tests/tst_settings.qml`, `tst_hints.qml`, `tst_setup.qml`
- Screenshot `27-settings-storage.png` (About touches the hint bar)

## Scope
1. **Category list fits:** at 1920x1080 the list is 9 x 72 + 8 x 8 = 712 px with `clip: false` and runs about 10 px into the hint bar. Make it fit the content area above the bar at every tier, preferably by scrolling it in whole rows like `SettingsPane` (T-170) when it doesn't fit. Shrinking items is the fallback; any new size must be an existing token.
2. **Pane hints:** each pane exposes `hints` (default `A Select`, `B Back`). About and any pane with nothing to select set `B Back` only. `SettingsPage` shows `currentPane.hints` while the pane has focus, replacing the `aboutPane.activeFocus` special case.
3. **Setup prose:** the wizard's multi-line explanatory copy uses `typeBody` (Regular) and keeps `typeHeadline` for step titles only (04 §3.2). Re-check that the wizard steps still fit.

## Out of scope
- New panes (Accessibility stays "Coming soon").
- New tokens or components.

## Acceptance criteria
- [ ] At the default and the Performance tier, the last category's bottom (with its selected pill) lies above the hint bar's top (`mapToItem` property test in `tst_settings.qml`, at 1920x1080 and at the test size). The test fails with the old list.
- [ ] With About selected and focused, its pill doesn't overlap any hint glyph (same test or `tst_hints.qml`).
- [ ] About shows `B Back` only and the Profiles pane shows `A Select|B Back`, both through the panes' own `hints` (`tst_hints.qml`). A pane that sets no hints gets the default.
- [ ] Screenshots reviewed: `27-settings-storage.png` and a Settings shot with About focused (new); a setup step with prose (`12-setup-admin.png` or the welcome step).
- [ ] `dev.ps1 test` ALL GREEN; `shots` ALL GREEN.

## Docs to update
- `04` §2 (Settings list scrolls when it doesn't fit), §5 (pane `hints`); `shell/PATTERNS.md` (how a pane sets its hints).

## Hints
- `SettingsPane`'s whole-row logic (`laidOutRows`, `ensureFocusedVisible`, `viewport`) is the pattern to copy for the category list. Don't duplicate it if it can be shared cleanly; if sharing is a refactor, copy it and say so.

## Outcome
_Filled in by the implementer._
