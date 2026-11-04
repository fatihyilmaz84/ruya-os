# T-175 — Settings: the category list fits above the hint bar; panes supply their own hints

Status: done · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

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
Verified: host

- **List fits:** `categoryList` in `SettingsPage.qml` now ends at the last whole row that fits the content area (`fitRows`), clips only when it overflows, and scrolls by rows with the selection (`positionViewAtIndex(..., Contain)`; row tops stay aligned because the height is n x stride - spacing). Not shared with `SettingsPane` (a ListView needed far less); no new token or size.
- **Pane hints:** `SettingsPane.hints` (default A Select, B Back); `AboutPane` sets B Back only; `SettingsPage.hints` = `currentPane.hints` while the pane has focus, else the list hints, B Back only for a category with no pane. The `aboutPane.activeFocus` special case is gone.
- **Setup prose:** the three explanatory texts (welcome, profile, done) use `typeBody`, no weight; step titles stay Display and the pill stays Headline.
- Tests: `tst_settings::test_last_category_clears_the_hint_bar` (1280x720 and 1920x1080, tiers high and performance: About pill bottom vs hint bar top and glyphs, whole rows); `tst_hints::test_panes_supply_their_own_hints` (Profiles, About, a bare pane gets the default). Revert test: with the old list height/no scrolling the new test fails at 1280x720 ("658 vs 657.33"); the reviewer's revert at 1920x1080 fails with "988 vs 986", 2 px past the bar top (26 px past the content area). Translations refreshed (3 new strings, Turkish done).
- Screenshots: new `8b-settings-about-category.png` (About selected, pill clear of the hint bar) and `11-setup-welcome.png` read. The builder's `shots` run failed (`Lockout::test_wrong_pins_lock_the_profile`, the picker in `27-settings-storage.png`) because the Windows session was locked during it, not because of main or this task.
- **Lead re-shoot after unlock (2026-11-04):** `shots` in the worktree ALL GREEN (69); `27-settings-storage.png` shows the Storage pane with the list ending at System, clear of the hint bar; `8b` shows About focused, clear of A/B.
- `test` ALL GREEN (329 passed, 28 skipped); `shots` ALL GREEN (69).

