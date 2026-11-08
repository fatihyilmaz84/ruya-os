# T-293 — Power saving follow-ups: monotonic idle clock, honest Sleep row, audio inhibit, wake input gap, backdrop pause

Status: done · Phase: 2 · Depends: — · Area: shell (IdleClock, PowerSavingPane, Backdrop, power/audio backends), services (ruya-devices audio) · Size: M · Owner: builder

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
Verified: host (vm pending: vm-power-saving-check.sh audio)

VM 0.0.54 (lead): `vm-power-saving-check.sh` service PASS, audio PASS (Playing true for a running pw-cat stream, false after; the SIGSTOP pause stays UNVERIFIED: PipeWire keeps the node running), timeline: display off by DPMS, a key brings it back with 95 page flips in 4 s; journal showed 3 x `Could not queue DRM page flip (Invalid argument)` around the wake (virtio-gpu; Dell to confirm). Fixed in the script: the stopped player was never killed (hang).

UX notes: new states: the Sleep row disabled (logind allows suspend, no marker): it reads "Sleep is not available on this console yet", has no value, takes no focus (Up/Down pass over it, like a hidden row; focus on entering the pane stays on the first row), Back leaves the pane and the page as before; with the marker it is the old ChoiceRow. The order note reads "The screen is not turned off: The console sleeps instead". The disabled row is not dimmed (a dim at `disabledOpacity` 0.4 would make the one sentence it carries hard to read at 10 ft; same as the "Bluetooth is off" information row). Wake gap and backdrop pause have no visible state. Screenshot reviewed: `92-power-saving-no-sleep-en.png`.

What was built:
1. `MonotonicClock` (C++ singleton, `shell/src/power/`): `ms()` from a `QElapsedTimer` and `sleptMs()` (Linux: CLOCK_BOOTTIME minus CLOCK_MONOTONIC, i.e. the time suspended; 0 elsewhere), with test hooks `mockAdvance`/`mockSleep`. `IdleClock.now` defaults to `MonotonicClock.ms()`; `IdleClock.slept` reads `sleptMs()`; a jump of `slept` above 1 s is a resume (`noteInput()`, in every stage). The old gap test on `now` stays (a clock that counts the sleep). The screen saver's time of day comes from the new `IdleClock.wallNow` (the wall clock, only for display).
2. Sleep row: `Power.suspendVerified` (marker or `RUYA_SUSPEND_VERIFIED=1`; mock flag with `mockSetSuspendVerified`) and `Power.sleepAllowed = canSuspend && suspendVerified`. `rowSleep` is visible when `Power.canSuspend`, enabled when `sleepAllowed`. Without `CanSuspend` it stays hidden (existing test kept).
3. Copy: order note value "The console sleeps instead" (en + tr). I changed the assertion of `test_a_later_step_at_or_before_an_earlier_one_gets_a_note` accordingly (it asserted the old text).
4. Audio: `parse_playing` now means a `Stream/Output/Audio` node in state `running` and not `pulse.corked`; a sink that stays "running" after its stream paused no longer counts. XML text updated (no signature change); mock and `tst_audio.qml` unchanged (the property is the same). `vm-power-saving-check.sh audio` plays a silent `pw-cat` stream, expects Playing true, SIGSTOPs it (prints UNVERIFIED if PipeWire keeps the node running, since SIGSTOP is not a real cork), and expects false after it ends.
5. Wake gap: `IdleClock.wakeGapMs` = 1000, `wakeGuard` set by `wake()` from `off`/`sleep` (also on a resume), `IdleClock.swallowInput = covered || wakeGuard` feeds `KeyRouter.swallowInput`; ended by the clock (evaluate) and by `guardTimer`.
6. `Backdrop.paused` (set by Shell while `focusedApp` is set) stops the six drift animations.

Revert checks (each change undone with `revert-check.ps1`, test red, restored): `now` back to `Date.now` -> `test_wall_clock_jump_does_not_change_stage`; `resumed ||` removed -> `test_resume_restarts_idle`, `test_a_resume_from_sleep_opens_the_gap_too`; `enabled: Power.sleepAllowed` -> `true` -> `test_sleep_row_disabled_without_marker`, `test_marker_appearing_later...`; `visible: Power.canSuspend` -> `sleepAllowed` -> `test_sleep_row_disabled_without_marker`; `swallowInput: covered || wakeGuard` -> `covered` -> `test_input_swallowed_for_1s_after_wake`; guard never ends (`if (false)`) -> `test_input_after_1s_passes`; `paused: false` -> `tst_shell::test_backdrop_stops_while_app_focused`. Rust (manual mutation of `pipewire.rs`, restored): filter on `Audio/Sink` instead of the stream -> 3 tests red; corked filter removed -> `a_corked_stream_does_not_count_even_when_running` red.

Files: `shell/src/power/MonotonicClock.{h,cpp}` (new), `Power.{h,cpp}`, `shell/CMakeLists.txt`, `shell/qml/{IdleClock,PowerSavingPane,ScreenSaver,Backdrop,Shell}.qml`, `shell/i18n/*.ts`, `shell/tests/{tst_power_saving,tst_shell,tst_activity,tst_sound_ui}.qml` (the last two: their cleanup restores the monotonic default), `services/ruya-devices/src/pipewire.rs`, `api/dbus/org.ruyaos.Devices1.xml`, `scripts/vm-power-saving-check.sh`, specs 01 and 02.

Deviations / readings: the wake gap follows the Guide's "wake from off": it also applies after `sleep` and after a resume, not after the saver. The Sleep row stays hidden when logind does not allow suspend (the task only names the missing marker). Unverified here: `sleptMs()` on Linux (compiled only on the image; the logic is the two `clock_gettime` calls), that PipeWire marks a paused stream idle/`pulse.corked` (parse tested on hand-made dumps), the 1 s gap on a real TV (Dell).
