# T-190 — Settings panes: look-ahead survives relayout, Tab scrolls, peek text readable

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
