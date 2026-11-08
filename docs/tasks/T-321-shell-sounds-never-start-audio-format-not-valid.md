# T-321 — The shell's own sounds never start on real hardware: "QAudioSink::start: QAudioFormat not valid"

Status: todo · Phase: 2 · Depends: — · Area: shell (AmbientLoop, Sfx, main.cpp audio), image (compositor unit env) · Size: M · Owner: lead

## Goal
The owner hears no UI sound or ambient bed on the Dell. Diagnosis on 2026-11-08 (Dell, image 0.0.53, analog speaker as default sink, volume 0.40, speaker pin unmuted, EAPD on, a 440 Hz tone played with `pw-cat` as `ruya-shell` went out without error): the shell's own audio never starts. Its journal (`journalctl -b _UID=$(id -u ruya-shell)`) shows, from the first second and about 120 times per 20 s, `QAudioSink::start: QAudioFormat not valid`, once `[SWR @ ...] Requested output sample rate 0 is invalid` and `qt.multimedia.ffmpeg.utils: Failed to initialize audio resampler: Invalid argument`; the shell's PipeWire stream stays `idle`/`[init]` (`wpctl status`), never `running`. The same error appears in the VM probe (`vm-sounds-check.sh`: "Requested output sample rate 0"), so it is not Dell specific. Not the cause (tried on the Dell, no change): the sink (analog or HDMI), `QT_AUDIO_BACKEND` = pulseaudio, alsa or empty, pipewire-pulse being up before the shell starts.

## Read first
- `shell/qml/AmbientLoop.qml` (two `MediaPlayer` + `AudioOutput`), `shell/qml/Sfx.qml` (`SoundEffect`), `shell/src/sound/SoundThemes.cpp`, `shell/src/main.cpp` (audio setup), `image/rootfs/usr/lib/systemd/system/ruya-compositor@.service` (`QT_AUDIO_BACKEND=pulseaudio` at line ~59), `docs/specs/02-shell.md` §5 sound
- the Qt 6.10 FFmpeg backend: `QAudioDevice::preferredFormat()` of the default output; `MediaDevices.defaultAudioOutput` / `audioOutputsChanged`

## Scope
1. **Find the cause on the Dell** (the owner's standing permission: the Dell is a test machine, root over SSH with `~/.ssh/ruyaos_dev`; overlays in `/run/systemd/system/ruya-compositor@tty1.service.d/` vanish on reboot). Ideas to test, in order: print `MediaDevices.defaultAudioOutput.preferredFormat` from inside the running shell (a temporary `console.warn` in `AmbientLoop`); bind `AudioOutput.device` to `MediaDevices.defaultAudioOutput` so it follows enumeration; set an explicit `audioFormat`/sample rate; check whether `QSoundEffect` cues work (`wpctl status` should show a `running` stream while a cue sounds); whether the FFmpeg backend needs `QT_FFMPEG_...`/`pipewire` plugin env; Qt's PipeWire/pulse module versions in the image (`rpm -qa 'qt6-qtmultimedia*' pipewire*`).
2. **Fix it in the code** (and the unit env if that is the cause), with a log line or a property the shell tests can assert (`AmbientLoop.sinkReady`); after a fix the stream is `running` while Home is up and no `QAudioFormat not valid` lines appear.
3. **A VM/Dell check** that fails when this regresses: `vm-sounds-check.sh` greps the shell journal for `QAudioFormat not valid` and `Requested output sample rate 0` and requires a running ruya-shell stream with the ambient on (needs `-Audio`).

## Out of scope
- The output device choice (T-322).

## Acceptance criteria
- [ ] On the Dell with a fixed build or overlay: the owner hears the ambient bed on Home and the cues; `wpctl status` shows the ruya-shell stream `running`; the journal has no `QAudioFormat not valid`.
- [ ] `vm-sounds-check.sh` has the new journal and stream checks and passes on the new image.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
