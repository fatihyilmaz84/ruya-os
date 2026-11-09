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
_Filled in by the implementer._
