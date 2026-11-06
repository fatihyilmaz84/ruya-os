# T-197 — The shell crashes when a Bluetooth headset disconnects

Status: in-progress · Phase: 2 · Depends: — · Area: shell, image · Size: S · Owner: lead

## Goal
Switching a Bluetooth headset off, or out of range, never takes the shell down. Owner report, 2026-11-06 (Dell, Sony WH-1000XM4 paired as an A2DP sink): "disconnecting a bluetooth headset seems to crash the shell".

## Evidence (Dell, `0.0.44-t162`)
- `coredumpctl`: `ruya-shell` SIGSEGV at 14:25:17, systemd restarted the compositor at once (`NRestarts=1`). WirePlumber logged one second earlier: `spa.bluez5.sink.media: ... (/org/bluez/hci0/dev_AC_80_0A_1A_D1_F2/sep3/fd0) terminated unexpectedly`.
- Crashing thread 1383 (`QAudioContext`, kernel: `segfault at 1c`): `on_remote_data` in `libpipewire-module-protocol-native.so` <- `loop_iterate` <- `do_loop` (libpipewire). The main thread was in the render loop. Not our code: the PipeWire client thread that Qt Multimedia 6.11.2 (its native PipeWire audio backend, `QAudioContext`) runs inside the shell, for the UI cues (`Sfx.qml`, three `SoundEffect`s), faults when the sink node disappears.
- `libQt6Multimedia` has the env switches `QT_AUDIO_BACKEND` and `QT_MEDIA_BACKEND`; the ffmpeg plugin also links `libpulse` (PulseAudio protocol, served by `pipewire-pulse`).

## Scope
1. Reproduce on the Dell: connect the headset, play cues (navigate in the shell), switch the headset off; confirm a core dump each time or note the rate.
2. Pick the least invasive fix and prove it with the same steps (at least 5 connect/disconnect cycles, with and without a cue playing at the moment of the disconnect): first try `QT_AUDIO_BACKEND=pulseaudio` in `ruya-compositor@.service` (the shell then speaks the PulseAudio protocol to `pipewire-pulse` instead of linking the native PipeWire client). If that does not hold, route the cues another way (for example recreate the `SoundEffect`s when the default sink changes, or play them through the PulseAudio backend only), or isolate audio in a helper process so a fault cannot take the compositor with it.
3. Whatever the fix is, the compositor must restart without losing the session when the shell does die for any reason (check `Restart=` and that a crash shows the picker again within seconds; report what the user sees).

## Progress (lead, 2026-11-06)
- Dell, `QT_AUDIO_BACKEND=pulseaudio` set by a drop-in in `/etc`: the `QAudioContext` thread is gone (`QPulseAudioEngine` instead) and the owner reports the crash no longer happens on headset disconnects. The setting is now in `ruya-compositor@.service` in the repo; it reaches the image with the next build. Left: the 5-cycle count, `vm-audio-check.sh` with the new image (cues still play), the Outcome.

## Out of scope
- Fixing Qt or PipeWire upstream (file a report if the fault is theirs: version, backtrace); changes to the audio device list (`ruya-devices`).

## Acceptance criteria
- [ ] The five cycles above end without `coredumpctl` listing a new `ruya-shell` dump; the Outcome states the Qt/PipeWire versions and the exact setting.
- [ ] The fix is in the image (`ruya-compositor@.service` or the shell), not only on the Dell; `vm-audio-check.sh`/`vm-devices-check.sh` (with `-Audio`) still pass (cues still play: the wav recording shows one burst per cue).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Docs to update
- `docs/specs/00-overview.md` ADR-010 (how the shell reaches PipeWire), `docs/dev-setup.md` (if a check changes), `image/CLAUDE.md` known quirks (one line).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
