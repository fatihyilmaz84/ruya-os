# T-313 — The shell's own ambient sound must not count as "something is playing"

Status: done · Phase: 2 · Depends: — · Area: services (ruya-devices pipewire), shell (ambient loop, power saving), scripts (vm-power-saving-check) · Size: S · Owner: builder

## Goal
With the ambient sound theme on, the screen saver, display-off and sleep stages still start on Home. Today the shell's own ambient loop is a `Stream/Output/Audio` node in state `running`, so `Devices1.Audio.Playing` is true while the console sits at Home and the idle clock never advances (T-293 review, an old bug that the old `Audio/Sink` filter had as well).

## Read first
- T-293 Outcome and review (Inbox line "ambient bed"); `services/ruya-devices/src/pipewire.rs` (`parse_playing`, ~line 63), `docs/specs/03-services-and-apps.md` (Devices1 `Playing`), `api/dbus/org.ruyaos.Devices1.xml`
- the shell's ambient loop (`shell/src/sound/`, `main.cpp`, `AmbientLoop` in QML) and how it names its stream (`application.name`, `application.process.binary`, `media.role`)
- `shell/qml/IdleClock.qml` (how `Playing` holds the stages), `scripts/vm-power-saving-check.sh` (`audio` part)

## Scope
1. **Decide and implement** one rule, recorded in spec 03: the shell's own streams do not count. Preferred: the shell gives its streams a property (`media.role` = `Notification`/`Ambient` or a fixed `application.name`) and `parse_playing` skips nodes with that marker; an app's stream still counts. If the shell cannot set the property from Qt Multimedia, skip nodes whose `application.process.binary` is the shell's binary.
2. **Tests (Rust):** `parse_playing` hand-made dumps: an ambient shell stream running alone is false; the same plus a game stream running is true; a shell stream marked by the fallback property is skipped; the game stream corked next to the ambient one is false.
3. **Shell test:** with the ambient theme mocked on and `Audio.playing` false (the service answer after the fix), the idle clock reaches the saver stage.
4. **VM check:** `vm-power-saving-check.sh audio` first assertion passes with the ambient bed on (the script turns the ambient theme on first); Outcome `Verified: host (vm pending: vm-power-saving-check.sh audio)`.

## Out of scope
- A level or peak check for a player that streams silence; muting apps; T-164.

## Acceptance criteria
- [ ] The Rust tests above pass and fail when the skip rule is removed (revert check).
- [ ] Shell test: ambient on, no app: the saver stage is reached on the idle clock.
- [ ] Spec 03 states the rule; `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/03-services-and-apps.md` (Devices1 `Playing`), `api/dbus/org.ruyaos.Devices1.xml` comment.

## Hints
- No contract signature change should be needed. Linux-only pieces (Qt Multimedia stream properties) are unverified on this host: say so and keep the fallback rule.

## Outcome
Verified: host (vm pending: vm-power-saving-check.sh audio)

VM 0.0.54 (lead): `vm-power-saving-check.sh audio`: Playing is false with the ambient bed in the graph and true for a running app-like stream.

Rule (spec 03, Devices1 `Playing`; XML comment): the shell's own streams do not count. `pipewire::parse_playing` skips a `Stream/Output/Audio` node whose `application.process.binary` is `ruya-shell` (`SHELL_BINARY`); an app's stream, and the corked/paused rules, are as before. This is the task's fallback rule, not the preferred one: Qt Multimedia (`MediaPlayer`/`AudioOutput`, `SoundEffect`) has no API for a stream's `media.role`, and libpulse fills `application.process.binary` in from the process by itself (the shell's executable is `ruya-shell`). Unverified on this host: that the real stream carries that property in the VM (the `audio` check prints `UNVERIFIED:` if no `ruya-shell` stream shows in `pw-dump`). Because the rule is by process, the shell's UI-sound streams are skipped too (they are not playback an app does; no contract change).

Tests: five Rust tests in `pipewire.rs` (ambient alone false; plus a game stream true; a corked or paused game beside the bed false; only the exact binary is skipped, an imposter `application.name` and a stream with no property count). Shell: `test_the_ambient_bed_does_not_hold_the_saver` in `tst_power_saving.qml` (bed on and wanted, `Audio.playing` false after a true -> no `audio` hold, saver at 10 min, display off at 30).
Revert checks: removing `&& !shells_own(...)` fails `the_shells_ambient_bed_alone_does_not_play` and `a_corked_game_beside_the_ambient_bed_does_not` (done by hand with `cargo test`: `revert-check.ps1` runs only the shell tests). For the shell test, `IdleClock.syncHolds` holding `audio` with `Audio.playing || DeviceSettings.ambientSound` (the old bug's effect) fails the new test and `test_audio_playing_prevents_idling`. The shell test is a model of the service answer (the mock does not run PipeWire); the real proof is the VM check.

VM check: `scripts/vm-power-saving-check.sh audio` now makes sure the ambient switch is on (a conf with `ambient=false` is put right and the compositor restarted; the default is on), waits for a `ruya-shell` stream in `pw-dump`, and asserts `Playing` is false with it running. Not run (no image build, lead run).

Files: `services/ruya-devices/src/pipewire.rs`, `shell/tests/tst_power_saving.qml`, `scripts/vm-power-saving-check.sh`, `docs/specs/03-services-and-apps.md`, `api/dbus/org.ruyaos.Devices1.xml`. Also removed the claim in the XML that a UI sound makes `Playing` true for a few seconds (no longer true).
