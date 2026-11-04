# T-176 — Test-gate hardening: a locked session, the weight lint, weak assertions, more accessibility walks

Status: in-progress · Phase: 2 · Depends: — · Area: scripts, shell · Size: M · Owner: builder

## Goal
The gates fail for the right reason and only then. `shots` says "session locked" instead of hanging or failing misleadingly. The weight lint can't be satisfied by a child item or a comment. Tests named in recent reviews fail by a clear margin when their feature breaks. The accessibility walk covers the screens it skips today.

## Read first
- `scripts/dev.ps1` (the `shots` path: LogonUI check, the shots lock, the test log), `scripts/lint-tokens.ps1` (the weight rule, about lines 27–86) and its self-check fixture in `dev.ps1`
- `shell/tests/tst_settings.qml::test_last_category_clears_the_hint_bar`, `shell/tests/tst_accessibility.qml`
- `docs/specs/04-design-system.md` §3.2 (weights), §7 (accessibility)
- `CLAUDE.md` "Tests are the spec's teeth" (never weaken; strengthen only)

## Scope
1. **Locked session during `shots`:** re-check `LogonUI` while waiting for the shots lock and after a failed run. When it is running, stop with "The Windows session is locked" (red) and a non-zero result, instead of waiting or reporting test failures. Don't change what `shots` runs when unlocked.
2. **Weight lint:** a `font.weight` in a nested child item or in a comment must not satisfy the parent `Text`. A `font.pixelSize:` whose `Theme.type*` sits on the next line is still checked. Add both cases to the self-check fixture (each must be rejected), and keep the accept case.
3. **Stronger assertions:** in `test_last_category_clears_the_hint_bar`, also assert that the last category's pill ends inside the page content area (above `Page.qml`'s bottom margin), and replace `if (glyph)` with `verify(glyph)`.
4. **Accessibility walks:** extend `tst_accessibility.qml` to Games (grid), Store (rows, results, toolbar), AppDetail, the PowerConfirm buttons and the TextEntry keyboard keys. Give Setup's key sink per-step names (it is just "Setup" now) and walk the wizard steps. ProfileCard's name says "PIN protected" when a PIN is set (translated).

## Out of scope
- Screen-reader output (the Orca spike), the profile add/manage flows (separate if needed), new lints.

## Acceptance criteria
- [ ] With `LogonUI` simulated (a test hook or an env override such as `RUYA_ASSUME_LOCKED=1` that only `dev.ps1` reads), `dev.ps1 shots` stops within seconds with the locked message; without it, `shots` behaves as before (Outcome: both runs).
- [ ] The lint self-check rejects the nested-child and the comment cases and the two-line `pixelSize`, and accepts a correct block; the tree passes the lint.
- [ ] The strengthened `test_last_category_clears_the_hint_bar` fails by more than 20 px at 1920x1080 with main's pre-T-175 `SettingsPage.qml` (revert check in the Outcome), and passes on the branch.
- [ ] `tst_accessibility` walks the new screens and asserts a non-empty, item-specific name on each focused item (for lists and grids, the name changes as the index moves); a revert check on at least one new name fails it.
- [ ] `dev.ps1 test` ALL GREEN; `shots` ALL GREEN (unlocked desktop).

## Docs to update
- `docs/dev-setup.md` (the locked-session behaviour), `04` §3.2 (what the weight lint checks), §7.

## Hints
- `dev.ps1` already stops at once when the session is locked at start (`Get-Process LogonUI`): reuse that check.
- `lint-tokens.ps1` works on the innermost brace block: strip comments and nested `{ … }` child blocks from the block before looking for `font.weight`.

## Outcome
Verified: host

Built all four Scope items.

1. **Locked session.** `dev.ps1` has `Test-SessionLocked` (LogonUI running, or `RUYA_ASSUME_LOCKED=1`, read only by `dev.ps1`). `shots` checks it before building, again every 2 s while it waits for the shots lock (the wait is now a poll), and after a failed run (a desktop that locked mid-run is reported as locked, not as test failures). It prints the red "The Windows session is locked" line and exits 1. Run with `RUYA_ASSUME_LOCKED=1`: stopped in 0.03 s, `FAILED: shots (session locked)`, exit 1. Run without it on the unlocked desktop: unchanged, `shots` ALL GREEN (69 passed). The mid-run and waiting branches share the helper but were not exercised (needs a real lock).
2. **Weight lint.** `lint-tokens.ps1` blanks comments (strings respected), drops nested `{ }` child blocks before looking for `font.weight`, and matches a `font.pixelSize:` whose `Theme.type*` is on the next line. `dev.ps1` self-check: four rejected fixtures (nested child, `//` comment, `/* */` comment, two-line size) plus an accepted two-line size with its own weight; the old accept/reject checks stay. Revert check: the pre-change lint (`git show HEAD:scripts/lint-tokens.ps1`) accepts all four bad fixtures (exit 0); the new one rejects them (exit 1). The tree passes.
3. **`test_last_category_clears_the_hint_bar`** now also asserts the pill ends inside the page content area (`list.parent`, i.e. above Page.qml's bottom margin) and `verify(glyph)` replaces `if (glyph)`. Revert check with `SettingsPage.qml` from `6d6b4f2^` (pre-T-175): the old `barTop` assertion fails only by 2 px at 1920x1080 (988 vs 986) and by under 1 px at 1280x720; with that one temporarily commented out (and only 1920x1080 run) the new assertion fails: pill bottom 988 vs content area 962, 26 px. Restored; passes on the branch.
4. **Accessibility walks** (`tst_accessibility.qml`, 6 new tests, same file keeps its mock cleanup): Games grid (names follow the index; filter), Games empty page, Store (featured row, rows below, toolbar search/show-all, keyboard keys: the dialog name carries the focused key and must change, results: names follow the index), AppDetail focus steps, PowerConfirm Cancel/Confirm, Setup wizard steps. `ProfileCard` says "Name, PIN protected" with a PIN (en + tr "%1, PIN korumalı"); `test_picker` asserts Player One has it and Ada and Guest do not. Setup's key sink is named per step ("Welcome to RuyaOS", "Network", "You're all set"; the language and name steps focus their own rows); the obsolete "Setup" string is gone from both .ts. Revert checks: undoing the ProfileCard change fails `test_picker`; undoing the Setup names fails `test_setup_wizard_steps` (both seen in the same run).

Deviations and limits: the wizard test jumps to step 4 by setting `step` (the create flow with name and PIN is tst_setup's). The PowerConfirm names are "Cancel" and "Confirm" (distinct from each other, not action-specific). The profile add/manage flows were out of scope. The shots pass drew no changed screenshot (no visual change), so none was reviewed.

Files: scripts/dev.ps1, scripts/lint-tokens.ps1, shell/qml/ProfileCard.qml, shell/qml/Setup.qml, shell/tests/tst_accessibility.qml, shell/tests/tst_settings.qml, shell/i18n/ruyashell_{en,tr}.ts, docs/dev-setup.md, docs/specs/04-design-system.md.

