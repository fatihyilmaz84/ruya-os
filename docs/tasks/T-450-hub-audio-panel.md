# T-450 — Hub Audio panel and the microphone tile

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
From the Hub over a game the player sets the volume, mutes, picks the output (TV, headset, speaker) and mutes the microphone without leaving the game.

## Read first
- ADR-033; `02` §1.6 (T-447's Audio panel); `04` §3, §4, §8
- `QuickMenu.qml` (the Quick Hub, T-448), the Settings audio pane (reuse its rows)

## Scope
1. The Audio panel of `02` §1.6: master volume, mute, the current output and output selection (`ListOutputs`/`SetOutput`), the microphone list and mute (T-449).
2. The microphone tile on the Quick Hub, present only when `ListInputs` is not empty.
3. Keep the focused row clear of the Hub list's edge fade (T-448 review: list top and bottom margins equal to the fade height; hub-4 shows a faded tile).
4. "Adjust" with Left/Right as the Volume row's hint (T-448 left it out).

## Out of scope
- Media controls (07 §5.4 needs the app's media info: T-306).

## Acceptance criteria
- [ ] Each control changes the mock's state and shows it (one test each); without a microphone: no mic row and no tile (test)
- [ ] UX: Back from the panel lands on its entry in the Quick Hub; readable at 10 ft; `UX notes:` line
- [ ] `dev.ps1 test` ALL GREEN; `shots` of the panel reviewed

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `02` §1.6 built marks.

## Hints
- Planned by lead-10 (ADR-033).

## Outcome

Verified: host (`dev.ps1 test` ALL GREEN; `dev.ps1 shots`: the hub-audio shots and every Hub shot are fine and were read; the only reds are the known Display, StoreUi, SystemInfo and Wallpaper screenshot tests on focus, which main has too (one earlier run of this tree had only Display and StoreUi red, another had all 183 green); no VM needed: shell logic over the mock Audio backend).

UX notes: states reached: the Quick Hub (new `Audio` entry row before Power; new `Mute mic` tile on its own second line when a microphone exists), the Audio panel (title row, Volume, Mute, Output, Microphone, Mute microphone; the last two only with a microphone). Back in the panel returns to the Quick Hub with the focus on the `Audio` entry (the Hub stays open); Back in the Hub resumes the game (hint `B Resume`/`B Close`); Guide inside the panel closes the whole Hub; the next open starts at Resume, never in the panel. Focus lands on Volume when the panel opens and always stays on the list (a microphone unplugged under the focus moves it to a neighbour). Hint bar per row: Volume `A Mute`, `Left/Right Adjust`; toggle rows `A Toggle`; choice rows `A Next`, `Left/Right Change` (only `B` when there is nothing to choose, e.g. one microphone); `B Back`. Doubted: (1) Output and Microphone are choice rows that apply at once on Left/Right, as Settings' `ChoiceRow` does: moving through the list switches the output under the player (no preview); the alternative is a sub-list opened with A, left to the owner. (2) Rapid Left/Right presses before the service answers all step from the old default. (3) The panel is shorter than the Quick Hub and re-centres vertically when it opens; it cross-fades over `focusMs`. (4) "Built-in microphone" (the mock's name) elides in the value of the Microphone row at 1080p; the arrows stay, the full name is the accessible name.

What was built (`shell/qml/QuickMenu.qml`):
- **Panel mechanism (for T-452/T-453/T-454):** `panelId` ("" = the Quick Hub). A panel is the same `ListView` with other keys, so focus, Back, the edge fade, the hint bar and Guide need nothing new. To add a panel: add its id to `panelIds` (this adds the entry row `panel:<id>` before Power; list it only when the panel is built), return its rows from `panelKeys(id)` (keys `<id>:<row>`; the shared `volume` row can be reused), a title in `panelTitle`, labels in `labelOf`, and per row `rowValue` (text at the right), `rowChoices`/`isChoiceRow` (a Left/Right choice row; `rowStep`), `rowActivate` (A) and the `hints` branch. A row kind that is not "label and value" (read-only metric rows, a button) adds a case to the delegate. `openPanel`/`closePanel` do the focus (first row / the entry) and the cross-fade (`swap`, `focusMs`, `pageSlide`, a cut under reduced motion). The `hints` list moved from `Shell.qml` into `QuickMenu.hints` (Shell uses it).
- **Audio panel** and **Mute mic tile** as in `02` §1.6 (updated). New icons `mic` (U+E31D) and `mic_off` (U+E02B) in the subset font (`icons.txt`, `Icon.qml`, both TTFs re-cut with `scripts/subset-icons.sh` in WSL).
- **Edge fade (scope 3):** `ListView.reveal()` puts the current row at least one fade's height (`spaceL`) from the edge that shows a fade, and runs again when the list's height or content height changes (the screenshot showed the mic tile under the fade after "Paused" had made the header taller).
- **"Adjust" hint (scope 4):** `Left/Right Adjust` on the Volume row, and `A Mute` (Accept mutes).
- Tests: new `shell/tests/tst_hub_audio.qml` (19 functions, 1 screenshot); `tst_quickmenu.qml` updated for the new rows (`tiles:1`, `panel:audio`; the long-list test goes to `close` with `goTo`).
- Docs: `02` §1.6 (panels, Audio, tile, hints, fade), `04` §5 (Quick menu, Quick tile, icon list).

Revert checks (each undone with `revert-check.ps1`, caught by `tst_hub_audio`): `Audio.setOutput(next.id)` -> first option (output tests); the mic tile filter `Audio.inputs.length > 0` -> always (no-microphone tests); the `panel:` entries removed from the Hub's keys (13 tests); the two edge branches of `reveal()` (upper and lower fade test); the `onHeightChanged`/`onContentHeightChanged` hooks (shorter-list test).

Deviations: (1) the tile is labelled "Mute mic" (not "Microphone") so its on-state ("Mute mic, on") means muted like "Mute, on" does; (2) in the Output row "current one first" is not applied: the row steps through the service's order (a reordering list would bounce between two outputs); the current one is the row's value. (3) Output choices skip an output whose route says "no" (empty headphone jack).

Files: shell/qml/QuickMenu.qml, shell/qml/Shell.qml, shell/qml/Icon.qml, shell/fonts/icons.txt + both MaterialSymbols TTFs, shell/i18n/ruyashell_{en,tr}.ts (new strings translated; the Shell-context entries that moved to QuickMenu removed), shell/tests/tst_hub_audio.qml (new), shell/tests/tst_quickmenu.qml, docs/specs/02-shell.md, docs/specs/04-design-system.md. Screenshots: `hub-audio-1-mic-tile.png` .. `hub-audio-4-mic-muted.png`.

Binding-loop warnings seen in the log: `QuickMenu.qml` listBox height in `tst_hub_pause` persists with the old height expression put back (so it is not from the new header and title terms; not investigated further), and `hintList` in `tst_timezone` (not investigated; there the Hub is closed).
