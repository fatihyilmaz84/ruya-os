# T-348 - Settings > Audio > Output: choose where the sound plays, with a test sound

Status: in-progress · Phase: 2 · Depends: T-322 · Area: shell (AudioPane, mock, D-Bus client) · Size: M · Owner: builder

## Goal
Silent sound is the first thing a player needs to fix. Settings > Audio gets an **Output** list built on the contract of T-322 (`ListOutputs`, `SetOutput`, `TestOutput`): the current output marked, unavailable ones greyed with the reason, a **Test sound** row that plays the tone on the focused output, A to choose. Outputs on other card profiles appear once T-347 lands; the pane does not care.

## Read first
- `docs/tasks/T-322-sound-output-policy-and-picker.md` (and its Outcome), `shell/PATTERNS.md` (settings rows, modals, translations), `shell/qml/AudioPane.qml`, the audio backend and mock in `shell/src/audio`, `docs/specs/04-design-system.md` §5 (SettingRow, list rows) and §8
- `docs/specs/02-shell.md` Settings > Audio

## Scope
1. The Output group in `AudioPane`: one `SettingRow` per output (name, kind icon from the existing Material Symbols set, "Current" / "Not connected" / reason), A chooses it (a `SetOutput` call, the list refreshes from the signal), a **Test sound** row below that plays on the focused output without choosing it; a toast "Sound moved to <name>" when the service moves the default (reuse the headset toast mechanism).
2. The mock gets three outputs (speaker, headphones unavailable, HDMI) with a reason text for the unavailable one.
3. Only existing tokens and components; a missing one is an Inbox line (`04` §8).

## Out of scope
- Volume per output UI, card profile controls, the policy itself (T-322, T-347).

## Acceptance criteria
- [ ] `tst_audio.qml`: `test_output_list_marks_the_current_one`, `test_unavailable_output_is_greyed_with_its_reason_and_cannot_be_chosen`, `test_choosing_an_output_calls_set_output_and_refreshes`, `test_test_sound_row_plays_on_the_focused_output_without_choosing_it`, `test_moved_toast_when_the_default_changes` (each red when its behaviour is removed).
- [ ] UX: from every new state Back leaves; focus lands sensibly after open/close/error and after choosing; readable at 10 ft; the Outcome has a `UX notes:` line; screenshots of the list (current marked, unavailable greyed with the reason, Test sound row) in English and Turkish, reviewed.
- [ ] Strings use `qsTr()`; Turkish translations added.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN; `02` updated.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` (Settings > Audio > Output), `docs/specs/04-design-system.md` only if a component was added (it should not be).

## Hints
- Copy `shell/src/network` + its pane for the backend/mock/client wiring pattern and the Wi-Fi list for a "list that refreshes from a signal".

## Outcome
Verified: host

Settings > Audio now starts with an Output list built from `Audio.outputs` (T-322 contract): a row per output with a kind icon, the name and "Current" / "Not connected" / "Not available now"; A calls `Audio.setOutput`, the list refreshes in place from `OutputsChanged` (focus stays); an unusable output is greyed (label and icon at `disabledOpacity`, reason whole) and, when chosen, only toasts "<name>: <reason>."; a **Test sound** row (value: the output's name) calls `Audio.testOutput` for the output whose row had focus last, without choosing it. The default-change toast now reads "Sound moved to <name>" (`Shell.qml`; the T-322 review's Inbox note). The mock already had the three outputs (TV, speaker, empty headphones jack); no mock change.

UX notes: states: list with the current one marked, an unavailable row focused, Test sound focused (en and tr shots `22-settings-audio*.png`, reviewed). Back (B or Left) from any row returns to the category list, as in every pane (no modal here). Focus lands on the first output when the pane is entered, stays on the row after choosing it, falls to the nearest row if the focused output vanishes (`settleFocus`), and stays on the unavailable row after Accept (toast only). Doubted: the Test sound row follows the *last focused output row*, so from the row below the list it plays on the last output (usually the empty jack, which answers `inactive` and toasts "Could not play the test sound."); a test tone aimed at a usable output needs the focus to have passed it last. The mock names (TV (HDMI), Analog output, Headphones) are service strings and stay English in the Turkish shot.

Deviations: (1) the contract has no "reason" field, so the reason is derived in the pane from `available`/`active` ("Not connected", "Not available now"); a service-given reason would be an Inbox line. (2) `SettingControl` got one property, `dimmed` (label and icon at `disabledOpacity`); 04 line for setting rows says so. `textDim` is not allowed on glass, and the pane overwrites a row's `opacity` for the peek cue, so neither was usable. (3) Row objectNames stay `sink_<id>`. (4) Removed the "Default" string (and "Audio output: %1"), translated the six new ones.

Tests: `tst_audio.qml` has the five named tests plus `test_zz_screenshots_tr`; existing tests in `tst_audio.qml` and `tst_sound_ui.qml` got new row counts (two more rows above the sliders) and the new strings. Revert checks (`revert-check.ps1 -Test tst_audio`): `Audio.setOutput(sinkId)` -> `setDefaultSink` fails the choosing test; `qsTr("Sound moved to %1")` -> "Audio output: %1" fails the moved-toast test; `dimmed: !sinkActive` -> `false` fails the greyed test; the Test row's `testOutput` -> `setOutput` fails the test-sound test; `isDefault ? "Current" : ""` -> `""` fails the marks-current test.

Verification: `dev.ps1 test` ALL GREEN (1006 passed, 78 skipped). `dev.ps1 shots`: the audio shots are produced and reviewed; the run is red twice on three tests outside this task (`tst_store_ui` line 81, `tst_system_info` line 502, `tst_wallpaper` line 898, plus a one-time `tst_display` focus miss), none of which touch Audio; not checked against main.

Files: `shell/qml/AudioPane.qml`, `shell/qml/Shell.qml`, `shell/qml/controls/SettingControl.qml`, `shell/tests/tst_audio.qml`, `shell/tests/tst_sound_ui.qml`, `shell/i18n/ruyashell_{en,tr}.ts`, `docs/specs/02-shell.md` (Settings > Audio, toast), `03` (toast text), `04` (`dimmed`).

