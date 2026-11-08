# T-321 — The shell's own sounds never start on real hardware: "QAudioSink::start: QAudioFormat not valid"

Status: done · Phase: 2 · Depends: — · Area: shell (AmbientLoop, Sfx, main.cpp audio), image (compositor unit env) · Size: M · Owner: lead

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
Verified: host (vm pending: `scripts/vm-sounds-check.sh` on the next image, VM booted with `-Audio`); on the Dell (0.0.53) the fixed file was tried at runtime through an overlay, results below. Listening is still the owner's.

**Correction to the Goal (owner, at the Dell):** the cues always played. Only the ambient bed was silent.

**Cause: the bundled `ambient.flac`, not the device, the backend or the unit.** Qt 6.11.2 (the image's `qt6-qtmultimedia`, FFmpeg 8.1.3) opens its output at 0 Hz for that file: `QFFmpegResampler ... to: [sample format:s16, sample rate:0 ...]`, then `QAudioSink::start: QAudioFormat not valid` and a retry about 6 times a second. `scripts/make-sounds.py` wrote frame headers with sample-rate code 0 ("as in STREAMINFO"). That is valid FLAC, and FFmpeg decodes it, but Qt then takes 0 as the output rate. Found on the Dell with the `ruya-shell --load` probe (as `ruya-shell`, `QT_FORCE_STDERR_LOGGING=1`, `QT_LOGGING_RULES=qt.multimedia*=true`):
- `AudioOutput.device` is the analog sink, valid and default, both by default and when set explicitly from `MediaDevices.defaultAudioOutput`. Neither changes anything, so binding the device is not the fix.
- The same MediaPlayer plays without one error line: a cue WAV, 24 kHz mono WAV, 24 kHz mono or stereo FLAC, 48 kHz FLAC, and an `ffmpeg` re-encode of the whole `ambient.flac`. Only our encoder's file fails.
- Our file with the rate code in every frame header (7 = 24 kHz) also plays clean. Nothing else changed: same size, 1760 bytes differ (440 frames x (rate code, CRC-8, CRC-16)).
- The broken file cannot be seen from QML: `playbackState` is Playing and `position` moves (probe: `playing=true position=5802`). So no `AmbientLoop` property such as `sinkReady` can tell. The tests guard the file and the checker instead (below).

**Fix**
- `scripts/make-sounds.py`: every frame header names its rate (`FLAC_RATE_CODES`). Its decoder (used by `--verify`, which `dev.ps1 test` runs) now asserts the code, so the old file fails `--verify`. Both `shell/sounds/dreamglass/ambient.flac` and `samples/sound-theme-example/ambient.flac` (16 kHz, code 5) were regenerated. The samples are unchanged and the WAV cues are byte-identical.
- `SoundThemeCheck.cpp` `parseFlac`: walks the metadata blocks in the file (bounded: the offset only grows and stops at the file size) to the first frame header. It refuses rate code 0 or 15 ("the FLAC frames do not name their sample rate ...") and a file with no frame ("the FLAC file has no audio frames"). This way no theme, bundled or from a drive, can bring the silent bed and its retry storm back. Both messages contain "FLAC", so `SoundThemeText` shows "A sound file is not in a format that can be played" (no new string). Fixtures: `makeFlacHeader` now writes a frame header, optionally after an 8 KB PADDING block. New cases: `bad-flac-frame-rate`, `bad-flac-no-frames`, and `ok-flac-padding` (the first frame lies past the 4 KB head, so the walk is tested).
- No change to `AmbientLoop.qml`, `Sfx.qml`, `main.cpp` or the compositor unit: none of them is the cause.

**Tests:** `tst_sounds.qml` `test_flac_frames_must_name_their_sample_rate` (new). The existing `test_the_bundled_theme_passes` now also covers the bundled file's frames. Revert checks:
- (1) `revert-check.ps1` on `SoundThemeCheck.cpp`, `if (rateCode == 0 || rateCode == 15) {` changed to `if (false) {`: CAUGHT, 3 failures (the new test, `test_every_fixture_ends_as_expected`, `test_every_refused_fixture_gets_a_specific_message`).
- (2) The old `ambient.flac` from HEAD put back by hand, then `dev.ps1 qml tst_sounds`: `test_the_bundled_theme_passes` fails (plus 4 cue tests, because the whole bundled theme is refused). `make-sounds.py --verify` fails with `AssertionError: frame header`. The file was then restored and `--verify` passed.

**VM/Dell check:** `scripts/vm-sounds-check.sh` changes:
- The probe now runs with `QT_FORCE_STDERR_LOGGING=1` and `QT_AUDIO_BACKEND=pulseaudio`. Without the first, Fedora's Qt sends `console.warn` to the journal, which is probably also why the 0.0.53 probe "failed". The script fails on `QAudioFormat not valid` or `Requested output sample rate 0` in the probe log.
- New: the same two lines must be absent from the journal of the running shell (`_PID` = the compositor unit's MainPID).
- With a sound device (an `Audio/Sink` other than `auto_null`; otherwise SKIP), a ruya-shell `Stream/Output/Audio` node must stay `running` in `pw-dump` for 3 s, sampled every 0.5 s. A cue such as the startup cue runs for at most 1.5 s, so it does not count. If no such node is found, the script restarts `ruya-compositor@*` once (the screen saver pauses the bed) and looks again.

Dell runs:
- Old file in the shell and the probe: FAIL. Probe 36x `QAudioFormat not valid` + 1x `sample rate 0`. Journal 292 lines. After the restart: "no ruya-shell output stream is running", with the stream node `idle`. An earlier version of the script without the 3 s rule passed here because of the startup cue; that is why the rule exists.
- Fixed file: every T-321 line PASS (probe valid format, loaded, 75093 ms, PlayingState; journal clean; ambient stream running).
- The only FAIL left is the existing T-294 line "embeds a second copy". 0.0.53 predates T-294's change.

**On the Dell after the fix (overlay):** `pw-dump` showed `48 ruya-shell idle` (the cues' stream) and `50 ruya-shell running` (the bed). The new shell (pid 6694, later 9992) logged no `QAudioFormat not valid` lines. A 4 s `pw-record` of the analog sink's monitor read peak 0.157 (-16.1 dBFS), RMS 0.052 (-25.7 dBFS): the bed reaches the sink. The new shell also logged `idle inhibit +audio`: 0.0.53 predates T-313, so on this image the running bed keeps the screen saver away. 0.0.54+ has the fix.

**What the bed is and how loud:** Dreamglass `ambient.flac`, mono 24 kHz, 75.09 s loop: a slow pad, a D chord with a ninth (73, 110, 147, 185, 220, 330 Hz, each layer detuned twice, levels drifting). The loudest sample is 0.35 (-9.1 dBFS). The theme gain is 0.7 (-3.1 dB) and the Ambient slider defaults to 100 %, so the bed peaks near 0.245 (-12.2 dBFS) before the sink volume. At the Dell's sink volume of 0.40 (wpctl's cubic scale, about -24 dB) it is quiet. Most of its energy is at 73 to 150 Hz, which a small internal speaker barely reproduces.

**Dell changes (all runtime, gone on reboot):**
- Drop-in `/run/systemd/system/ruya-compositor@tty1.service.d/90-t321-ambient.conf` (`BindReadOnlyPaths=/run/t321/ambient.flac:/usr/share/ruyaos/sounds/dreamglass/ambient.flac`) and `daemon-reload`.
- `mount --bind` of the same file over `/usr/share/ruyaos/sounds/dreamglass/ambient.flac` in the root namespace (for the probe).
- `/run/t321/` (the fixed `ambient.flac`, `rms.py`, `since`).
- `ruya-compositor@tty1` restarted 5 times. One restart was without the overlay, for the negative run. The overlay is in place now, so the owner can listen on Home.
- `/root/vm-sounds-check.sh` and `/root/vm-sounds-probe.qml` (this branch's version) copied to the Dell. `/tmp` scratch removed. No reboot.

**Files:** `scripts/make-sounds.py`, `shell/sounds/dreamglass/ambient.flac`, `samples/sound-theme-example/ambient.flac`, `shell/src/sound/SoundThemeCheck.cpp`, `shell/tests/tst_sounds.qml`, `scripts/vm-sounds-check.sh`, `docs/specs/02-shell.md` (5.3 checker), `docs/developers/sound-themes.md` (ambient limits).

**Deviations:**
- No `AmbientLoop.sinkReady` and no "player is playing" shell test. Qt reports Playing with a moving position for the broken file, so such a test would stay green on the bug. The checker and generator tests above are the ones that fail when the bug comes back.
- The fix is in the data and the checker, not in AmbientLoop or the unit env.

**Unverified:** the owner listening on the Dell. A VM image with the new file (lead run).
