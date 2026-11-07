# T-190 — Settings panes: look-ahead survives relayout, Tab scrolls, peek text readable

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

## Goal
Three loose ends of the T-185 scroll cue: when rows are inserted or a message appears below the focused row the pane doesn't re-run look-ahead (the cue on that side disappears); Tab moves focus between rows without scrolling or updating the peek rows; and the dimmed peek text over a light backdrop blob has low contrast.

## Read first
- `docs/tasks/T-185-scroll-affordance.md` Outcome and review notes (peek rows, look-ahead `place()`); `shell/qml/SettingsPane.qml` (`relayout()`, `ensureFocusedVisible`), `shell/qml/controls/SettingControl.qml` (`activeFocusOnTab`)
- `docs/specs/04-design-system.md` §3.1 ("Peek"), §5 (Settings pane), §8

## Scope
1. `relayout()` (rows inserted, a message appearing, a pane resizing) runs the same look-ahead as `ensureFocusedVisible` while the pane has active focus, so the focused row is never the last visible row with rows beyond it.
2. Tab/Backtab: either handled in `SettingsPane` like Down/Up (same scrolling and peek update), or drop `activeFocusOnTab` from rows (a controller never sends Tab; pick the smaller change and say why).
3. Peek legibility: measure the contrast of a peek row's text over the lightest backdrop blob in the screenshots (28b); if it falls below the 04 contrast rule for dim text, raise `peekOpacity` or dim only the row's fill and keep the text at higher alpha; the Outcome gives the numbers before and after.

## Out of scope
- Store grid and Games peek (needs a shared helper first: separate task when wanted), new tokens beyond adjusting `peekOpacity`.

## Acceptance criteria
- [ ] `tst_settings.qml`: inserting rows below the focused row (Bluetooth discovery adds devices) restores a whole row beyond the focused one; Tab/Backtab (or its absence) keeps the focused row whole and the peek rows right. Revert checks noted.
- [ ] Screenshot 28b read again; contrast numbers in the Outcome.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN; `.\scripts\dev.ps1 shots` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `04-design-system.md` §3.1/§5 if the token value or rule changes.

## Outcome
Verified: host (`dev.ps1 test` ALL GREEN: 550 QML + 50 skips, 70 Rust; `dev.ps1 shots` ALL GREEN: 105; the new screenshots read).

**1. Look-ahead survives a relayout.** `SettingsPane.relayout()` (run when the column height or the pane height changes: rows shown or hidden, a message appearing, devices listed, a resize) now ends with `ensureFocusedVisible()` while the pane has active focus (`if (activeFocus)`). Without focus the view is left as the snap gave it, as before. Tests: `test_rows_inserted_below_the_focus_keep_the_look_ahead` (a bare four-row pane, focus on the last row, a fifth then a sixth row appear below), `test_a_shorter_pane_keeps_the_look_ahead` (the pane loses a row of height), `test_bluetooth_discovery_keeps_the_focused_row_and_the_row_below_whole` (the real pane, a scan lists devices below "Add a device"; this one passes without the fix too, because the mock lists the devices where the next row already was: it is there for the criterion, the two bare-pane tests carry the revert check). Revert check: deleting the call in `relayout()` makes the first two fail (`peekAbove` stays null; "r4 is whole again after the resize").

**2. Tab: handled in the pane, `activeFocusOnTab` dropped from `SettingControl`.** Both are needed, which is not what the task text suggested ("either / or"): with `activeFocusOnTab: true` the window moves focus along its tab chain itself and the key never reaches the pane (a probe showed `Keys.onPressed` on the pane never fires for Tab, while it does once the rows are out of the chain), so focus moved without any scrolling or peek update (the focused row stayed dimmed and out of view). Now `SettingsPane` treats Tab like Down and Shift+Tab / Backtab like Up (clamped, no wrap, `Sfx.navigate`), which keeps desktop keyboard use working; dropping the attribute alone would have sent Tab to whatever else is in the tab chain. A controller never sends Tab, so nothing changes there. Tests: `test_tab_moves_like_down_and_scrolls` (a full walk down with Tab, clamp at the end, up with Backtab, then one Shift+Tab, checking the focused row is whole and undimmed, the next/previous row whole and every row's settled opacity), and `test_longer_panes_keep_the_look_ahead_with_down_and_tab` (Display & motion with Theme/Wallpaper rows and System with the thermal rows, each squeezed to four rows, Down and Tab). Revert check: putting `activeFocusOnTab: true` back fails the Tab test ("tab 5: the focused row is not dimmed", opacity 0.7 at row 5, the first that needs a scroll).

**3. Peek legibility: `peekOpacity` 0.5 -> 0.7.** The text of a peek row is `text` at the peek alpha over the backdrop, next to glass at the same alpha. Measured with the shell's own arithmetic (`ThemeMath`, same samples as the contrast gate, minimum over the gradient and each blob; "overlap" = the white highlight blob on top of both):

| theme | 0.5 min / overlap | 0.7 min / overlap |
|---|---|---|
| Dreamglass | 2.81 / 2.07 | 4.16 / 2.77 |
| Midnight | 3.67 / 3.07 | 5.86 / 4.59 |
| Aurora | 2.45 / 1.84 | 3.47 / 2.36 |
| Ember | 2.83 / 2.15 | 4.25 / 2.94 |
| Daylight | 3.52 / 3.60 | 6.38 / 6.46 |

(`textDim` is not the issue: the 04 rule is that it only sits on opaque surfaces, 4.5:1; a peek row is `text` on glass, which has no 4.5:1 guarantee over bright blobs even at full opacity in the overlap, where the gate holds it to 3:1.) Measured on real renders (`28d-settings-scroll-middle-aurora/daylight`, label of the top peek row, darkest/brightest pixel against the median of the label area): Aurora 3.01:1 at 0.5, 4.22:1 at 0.7; Daylight 3.11:1 at 0.5, 5.81:1 at 0.7 (the same row when whole: 6.46 and 15.05). I did **not** reach 4.5:1 everywhere: that would need about 0.9 on Aurora, where there would be hardly any cue left. The new rule (04 §7, `tst_theme_contrast.qml`): the label of a peek row must be >= 3:1 over the gradient and each blob (row labels are 30 px body text: large text at the 1080p design size), and >= 2:1 where the blobs overlap (Aurora 2.36 is the worst; the row is whole once focused). The alternative in the task (dim only the fill, keep the text at a higher alpha) was not taken: the glass fill is a faint white, so the visible cue *is* the text dimming; it would also have meant a different mechanism than the row's `opacity` that the T-185 tests assert.

Gate: `tst_theme_contrast.qml` gets "text in a peek row over backdrop 0..4" rows for every theme (at 0.5 Dreamglass, Aurora and Ember fall below the 3:1 floor: 2.81, 2.45, 2.83; Midnight and Daylight pass it) and `test_peek_rows_are_legible_at_the_token_but_not_at_the_old_value` (Aurora at the first blob: >= 3 at the token, < 3 at 0.5; every theme >= 4.5 on the plain ground). Screenshot 28b read again (Dreamglass tint): the top and bottom peek rows are clearly dimmer than the whole rows and read well; 28d (Aurora, Daylight) added to `test_zz_screenshots_scroll_cue`, both read: the cue is still visible and the labels are legible.

**Checks.** `dev.ps1 test` ALL GREEN. `dev.ps1 shots` was first red on 6 timing / animation tests unrelated to this task (`Glass` glare, `Glide` x2, `GlideSettings`, `Lockout` countdown, `Wallpaper` cover) while the desktop was in use (`TEST WINDOW LOST ACTIVATION`; the same two tests I tried also failed with the main checkout's own `tst_ruyashell.exe`); on an undisturbed desktop the whole run is green. Screenshots read: `28b` (before the 0.7 change too), `28d-...-aurora`, `28d-...-daylight`.

Files: `shell/qml/SettingsPane.qml`, `shell/qml/controls/SettingControl.qml`, `shell/qml/Theme.qml`, `shell/tests/tst_settings.qml`, `shell/tests/tst_theme_contrast.qml`, `docs/specs/04-design-system.md`.

Deviations: Tab is both handled and dropped from the tab chain (see 2); the contrast floor is 3:1 / 2:1, not 4.5:1 (see 3), the owner may want to call that. No existing assertion was changed (the peek tests compare against `Theme.peekOpacity`, not 0.5).

Follow-ups (Inbox): the Settings rows have no pixel-level contrast test (only the arithmetic gate and screenshots); a peek row over a wallpaper (T-208) is not measured; the store grid and Games peek is still the separate task.
