# T-452 — Hub Performance panel

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
From the Hub over a game the player opens Performance and reads FPS, frame time, CPU, GPU, RAM, VRAM, temperatures and power, with each unsupported value said plainly.

## Read first
- ADR-033; `02` §1.6 (T-447's Performance panel); `04` §3, §4, §8; T-451's Outcome

## Scope
0. First (T-450 review): replace the per-key switch functions in `QuickMenu.qml` (panelKeys, panelTitle, labelOf, rowValue, rowChoices, isChoiceRow, rowActivate, the hints branch) with one row-descriptor table per panel (`{ key, label, kind: toggle|choice|slider|info, value(), choices(), activate() }`; hints, the delegate and Left/Right derive from `kind`); the Audio panel's tests stay green unchanged. Also step choice rows from a pending target until Set*Finished answers.
1. The Performance panel of `02` §1.6 over the T-451 client; numbers update at the chosen interval only while the panel is open.
2. Never show held numbers as live (T-451 review): on a failed GetPerformance and on the first open after idle, mark the held metrics unavailable until a fresh answer arrives (fix in `Performance.cpp` with a test). States: unsupported shows "Not available on this console", unavailable and stale say so; no dashes that look like zero.
3. The interval as a row in the panel or in Settings (as T-447 decides).

## Out of scope
- A permanent on-screen counter over the game (a later task if the owner wants it); tuning controls (07 §5.3, excluded).

## Acceptance criteria
- [ ] Each metric state renders its text (one test per state, mock)
- [ ] Polling starts on open and stops on close (test)
- [ ] UX: Back lands on the Performance entry; readable at 10 ft; `UX notes:` line
- [ ] `dev.ps1 test` ALL GREEN; `shots` of the panel with all states reviewed

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
Verified: host
`dev.ps1 test` ALL GREEN (1197 QML passed, 99 skipped; Rust all passed); `dev.ps1 shots` ALL GREEN (188 screenshot tests, once per round of the QuickMenu change: the first run showed the one-line rows cutting "Not available on this console" and the sentence short, so the readings became two-line rows and `shots` ran again); the four `hub-performance-*.png` read. Hardware: the panel over a real compositor, the FPS numbers on the Dell and a live GetPerformance over D-Bus were not run here (T-455 measures there).

**Built.**
- **Scope 0, `QuickMenu.qml`:** the per-key switches (`panelKeys`, `panelTitle`, `labelOf` for panel rows, `rowValue`, `rowChoices`, `isChoiceRow`, `rowStep`, `rowActivate`, the hints branch) are one table per panel, `panelDef(id)` = `{ title, rows: [descriptor] }`, a descriptor `{ key, label, kind: toggle|choice|slider|info, value(), dim(), activate(), adjust(delta), choices(), select(id), async }`; `rowOf(key)` finds it (the Hub's Volume row is `volumeRow()`, also the Audio panel's first row). Hints, the delegate (`isPanelRow`, `isChoice`, `isInfo`, value, arrows, colour), Accept and Left/Right all derive from `kind`. Adding a panel is one entry in `panelIds` and one table. The Audio panel's tests pass unchanged. **Pending target:** a choice row that asks the service (`async`: output, microphone) keeps the target of the last press in `pendingChoice` until `Set*Finished` for that id and the list show it (a refusal drops it, so does leaving the panel); the next press steps from there, not from the old default.
- **Scope 1, the Performance panel:** rows Frames, CPU, GPU, RAM, VRAM, CPU temperature, GPU temperature, Power, then Update every (0.5/1/2/5 s, written to `DeviceSettings.performanceIntervalMs`: scope 3 as a row in the panel). `PerformanceConsumer { active: menu.open && menu.panelId === "performance" }` is the only consumer: Back, Guide and closing the Hub stop the polling and the frame meter. Texts: number; `Not available on this console` (`textDim`); `Measuring...`; `<number> (last reading)`; RAM and VRAM take the worse state of used and total. Rows read `Performance.metrics`, so they follow every answer.
- **Scope 2, `Performance.cpp`:** `PerformanceBackend::failed()` (a failed newest request; the D-Bus client and the mock use it), `Performance.fresh`, `markUnavailable()`: a failed `GetPerformance` and the first open after idle set every held entry to `unavailable`/0 until a fresh answer; `unsupported` stays. `Performance.mockFail(bool)` for tests.
- Translations (Turkish and English) for the 20 new strings; 02 §1.6 (built marks, panel mechanism, the Performance paragraph, focus), 04 §5 (the two-line reading row).

**Tests.** New `tst_hub_performance.qml` (17 + 1 screenshot): entry/Back/focus, entry order, polling starts on open and stops on Back, Guide and Hub close (`pollCount`, `polling`, `consumers`), frames counted only while open, one test per state (supported, unsupported + textDim + not truncated, unavailable "Measuring...", frames "Measuring...", stale), the 60 FPS line, a failed request and a first open after idle at the panel, the interval row, readings take focus and Accept is silent, every row reachable clear of the fade. `tst_performance.qml`: `test_a_failed_request_marks_the_held_numbers_unavailable`, `test_the_first_open_after_idle_does_not_hold_the_numbers_of_the_visit_before`. `tst_hub_audio.qml`: `test_presses_before_the_answer_step_from_the_pending_target`.
Revert checks (`revert-check.ps1`, each caught): no `pendingChoice` (`if (row.async)` -> `if (false)`) fails the audio test; `markUnavailable()` out of `setRunning` fails both first-open tests; the `failed` connection removed fails both failed-request tests; the consumer `active: menu.open` fails the polling, frame and first-open tests; `dim` false fails the unsupported test; no "Not available" text, no "(last reading)", the info hint `[back]` made `Select`, and the info column a third of the width (truncation) each fail their test.

**Changed existing tests (said, not weakened):** `tst_quickmenu.qml` expected key lists gain `"panel:performance"` (the Hub has the new entry; every other assertion is as it was). `tst_performance.qml::test_the_mock_answer_holds_every_state` waits for `Performance.fresh` instead of `valid` (with held numbers marked unavailable on open, `valid` was already true from the test before and the compare ran before the first answer; the assertions are the same). No test was removed (`lost-tests.sh` is empty).

UX notes: states reached: the Hub's new Performance entry (after Audio, before Power); the panel (title, nine rows: eight readings and the interval choice row); each reading in the four states. Back in the panel returns to the Hub with focus on the Performance entry (test); Guide closes the whole Hub. Focus lands on the first row, Frames: the spec said "first actionable row", but the readings take focus (Up/Down walk and scroll them, as SystemInfoPage does) and the only control, the interval, is at the end, so landing there would hide the numbers; the hint bar offers `B Back` only on a reading and `A Next`, `Left/Right Change`, `B Back` on the interval. Readings are two lines (label `typeCaption` over the value `typeBody`) because one line cut "Not available on this console" and the frames line; at 1080p the panel holds about seven rows and scrolls with the fade (the focused row is kept clear of it, tested). Doubted: (1) with no app in front the Frames row says "Measuring..." for ever (the spec's word); a "No game in front" text would be more honest (Inbox). (2) The interval row lives in the panel only, not in Settings. (3) "(last reading)" is my wording for a stale value.

