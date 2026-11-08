# T-293 — Power saving follow-ups: monotonic idle clock, honest Sleep row, audio inhibit, wake input gap, backdrop pause

Status: in-progress · Phase: 2 · Depends: — · Area: shell (IdleClock, PowerSavingPane, Backdrop, power/audio backends), services (ruya-devices audio) · Size: M · Owner: builder

## Goal
The idle clock survives a wall-clock change and a resume, the Power saving pane is honest about sleep and the screen, a paused stream no longer keeps the console awake, a wake from a dark screen does not eat the first button press as a command, and the animated backdrop stops costing GPU while an app is in front.

## Read first
- `docs/specs/02-shell.md` (power saving, saver), `04-design-system.md` (saver tokens)
- T-202 Outcome; `shell/qml/IdleClock.qml`, `UsagePresence.qml`, `PowerSavingPane.qml`, `ScreenSaver.qml`, `Backdrop.qml`, `shell/src/power/`, `shell/src/audio/`; `services/ruya-devices/src/audio.rs`, `idle_pads.rs`
- `scripts/vm-power-saving-check.sh`; STATUS-parked.md "Inbox triage 2026-11-07", bullets T-293

## Scope
1. **Monotonic idle clock:** `IdleClock` measures elapsed time from a monotonic source (a `QElapsedTimer`-backed helper exposed to QML) instead of the wall clock; a jump of the wall clock (NTP, time zone) changes nothing; after a resume from sleep the clock restarts from "active".
2. **Sleep row honesty:** the Sleep timeout row shows "Sleep is not available on this console yet" and is disabled until `/usr/share/ruyaos/suspend-verified` exists (T-166 creates it); the row works as today when it exists (mock sets it).
3. **Copy:** the PowerSavingPane note "The screen is not turned off" says the console sleeps instead when sleep is the chosen stage.
4. **Audio inhibit:** `Audio.Playing` (the idle inhibit reason) counts only streams that are running and not corked; paused or silent streams do not hold the console awake. Contract extended if needed (XML first, mock and client after).
5. **Wake input gap:** input arriving within 1 s after the screen comes back from off is swallowed (it wakes only); the value is a `Theme`-free constant in `IdleClock`, tuned on the Dell later.
6. **Backdrop pause:** `Backdrop` stops its drift animations while an app has focus (Home hidden behind an app) and resumes on return; reduced motion unchanged.

## Out of scope
- Power profiles daemon and a "Power mode" row (needs the Dell's numbers; parked), pads that `ruya-inputd` does not report (B-006), the compositor idle-inhibit per surface (T-164), the Qt 6.8 build question (T-298).

## Acceptance criteria
- [ ] `tst_power_saving.qml::test_wall_clock_jump_does_not_change_stage` (fake wall clock jumps an hour: stage unchanged) and `::test_resume_restarts_idle`.
- [ ] `tst_power_saving.qml::test_sleep_row_disabled_without_marker` and `::test_sleep_row_enabled_with_marker`.
- [ ] Rust: a paused/corked stream does not set `Playing`; a running one does (red when the filter is removed). `tst_audio.qml` follows the contract.
- [ ] `tst_power_saving.qml::test_input_swallowed_for_1s_after_wake` (fake clock) and `::test_input_after_1s_passes`.
- [ ] `tst_shell.qml::test_backdrop_stops_while_app_focused` (the animation's `running` is false with an app focused, true after return).
- [ ] UX: from every new state Back leaves; focus lands sensibly; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] VM (lead run): `scripts/vm-power-saving-check.sh audio` shows a paused stream not inhibiting; Outcome `Verified: host (vm pending: vm-power-saving-check.sh audio)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- 02 (power saving: sleep availability, wake gap, backdrop pause), the audio interface text in the XML.

## Hints
- Reference: `IdleClock.qml` stages and however `tst_power_saving.qml` fakes time today (keep that hook working; add the monotonic source behind it).
- Overlaps T-283/T-284 only through `Theme.qml`; none through the files above.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
