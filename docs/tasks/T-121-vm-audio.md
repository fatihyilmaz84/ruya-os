# T-121 — Audio in the VM: a sound device, PipeWire up, UI cues load without errors

Status: todo · Phase: 2 · Depends: T-120 (VM screenshot/keys scripts, monitor port) · Area: image, scripts, shell · Size: S

## Goal
The sound path that was never run on Linux is checked in the booted image: the VM has a sound card, PipeWire and WirePlumber run for the shell's session and expose an output, and the shell's UI cues (`Sfx`, T-108's volume OSD) load and play without errors. This does not prove how it sounds; it proves nothing in the chain is missing or broken.

## Read first
- `scripts/run-vm.ps1` (already has `-audiodev dsound,id=snd0 -device intel-hda -device hda-output,audiodev=snd0`), `scripts/smoke-test.ps1` (headless, has no audio device)
- `image/build/20-base.sh` (PipeWire, WirePlumber, `pipewire-pulseaudio`, `pipewire-alsa` are installed)
- `shell/qml/Sfx.qml` (`SoundEffect`, the wav files in `shell/sounds/`), `shell/CLAUDE.md`
- `docs/specs/03-services-and-apps.md` §2.3 (audio policy), `docs/specs/01-platform.md` (session units)
- `docs/tasks/T-108-toasts-and-volume-osd.md` Outcome (what is unverified about audio)

## Scope
1. Add an optional audio device to `smoke-test.ps1` (`-Audio`: dsound, same options as `run-vm.ps1`), so the headless check can run with a sound card.
2. In the VM (over SSH, a script copied with `scp`), find out and record whether PipeWire and WirePlumber run **for the `ruya-shell` session user**: `systemctl --user -M ruya-shell@ …` or `loginctl`/`XDG_RUNTIME_DIR` based checks; the compositor session is started through pam_systemd (see `image/CLAUDE.md`). If they do not start, fix it in the image (enable the user units for that user via `preset`/`/usr/lib/systemd/user` wiring, not a login hack), keeping the service hardening rules in `image/CLAUDE.md`.
3. `wpctl status` as that user lists an output (the HDA device) and a default sink.
4. The shell side: the shell log has no `QSoundEffect`/multimedia errors about the cue files (decoder or format problems), and a cue request produces a playback stream: trigger a few Sfx cues with `vm-keys.ps1` (arrow keys in the picker), and show a stream with `pw-top`/`pw-dump` or `wpctl` while it plays.
5. Fix what breaks (image packages, units, or the cue format: for example convert the wavs to a format Qt's FFmpeg backend decodes without a warning). Each finding goes in the Outcome.

## Out of scope
- Listening tests, mixing, ducking, per-channel volumes (T-114 and later).
- The `ruya-devices` service (blocker B-007).
- Bluetooth and HDMI audio on real hardware.

## Acceptance criteria
- [ ] `smoke-test.ps1 -Audio` boots with a sound card and still prints `RUYA_BOOT_OK`.
- [ ] The Outcome shows PipeWire and WirePlumber running for `ruya-shell` and `wpctl status` listing a sink (pasted output).
- [ ] After a few navigation keys the shell's journal has no audio warnings, and a stream from the shell is visible (pasted output), or the Outcome explains what stops it and what was changed.
- [ ] `.\scripts\dev.ps1 test` is ALL GREEN; if the image changed, `smoke-test.ps1` prints `RUYA_BOOT_OK` on the rebuilt image.
- [ ] The STATUS note "audio unverified" is updated to say what is now verified (**vm**) and what still needs hardware or ears.

## Verification
```powershell
.\scripts\smoke-test.ps1 -Audio -Keep
ssh -i $env:USERPROFILE\.ssh\ruyaos_dev -p 2222 root@127.0.0.1 "sh /root/audio-check.sh"
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/dev-setup.md` (`-Audio`), `image/CLAUDE.md` (the VM now has audio when asked), `docs/STATUS.md`.

## Hints
- With the `dsound` backend the VM plays on the host's default output, so the owner can also listen; do not rely on it for the result.
- A per-user PipeWire needs `XDG_RUNTIME_DIR` of that user. From root over SSH, use `runuser -u ruya-shell -- env XDG_RUNTIME_DIR=/run/user/$(id -u ruya-shell) wpctl status`.
- Keep the check in a script file (quoting through PowerShell to ssh breaks `$` and pipes).

## Outcome
_Filled in by the implementer: what was built, files, how it was verified, deviations, follow-ups._
