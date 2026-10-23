# T-121 — Audio in the VM: a sound device, PipeWire up, UI cues load without errors

Status: done · Phase: 2 · Depends: T-120 (VM screenshot/keys scripts, monitor port) · Area: image, scripts, shell · Size: S

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
**Result: the sound path works in the VM. Nothing in the image or the shell needed fixing.** The image was `0.0.5-t107d` (no image change in this task); a second image with stereo cues (`0.0.5-t121`) was built to test a hypothesis, did not change the result, and was dropped (the wavs are as committed).

**Built:**
- `smoke-test.ps1 -Audio` adds an Intel HDA card; `-AudioBackend dsound` (default, host speakers) or `wav` (records what the guest plays to `output\vm-audio.wav`, so no ears are needed). It still prints `RUYA_BOOT_OK` with the card (`RUYA_BOOT_OK 0.0.5-t107d` and `0.0.5-t121`).
- `scripts/vm-audio-check.sh` (guest): sound card, the shell user's PipeWire units and processes, `wpctl status`, default sink, the shell's audio log lines. `scripts/vm-audio-bursts.py` (host): lists the sounds in the recording (QEMU leaves the wav header sizes at zero, so `wave` cannot open it). Docs: `dev-setup.md` ("Audio in the VM"), `image/CLAUDE.md`, spec 01 §8 row 5.

**PipeWire runs for `ruya-shell` and exposes the HDA sink** (`vm-audio-check.sh`, abridged):
```
 0 [Intel          ]: HDA-Intel - HDA Intel                  (kernel sound card)
user@972.service: active      /run/user/972 (ruya-shell)     (pam_systemd gives the compositor session a user manager)
pipewire-pulse.service / pipewire.service / wireplumber.service  loaded active running
1223 /usr/bin/pipewire   1224 /usr/bin/wireplumber   1225 /usr/bin/pipewire-pulse
Audio
 ├─ Devices:  49. Built-in Audio                      [alsa]
 ├─ Sinks:    * 56. Built-in Audio Analog Stereo      [vol: 0.40]
 └─ Streams:  57. ruya-shell
                 58. output_FL > Generic Analog:playback_FL   [init] / [paused]
default sink: node.name = "alsa_output.pci-0000_00_04.0.analog-stereo", media.class = "Audio/Sink"
```
No unit wiring was needed: the user units (`pipewire`, `wireplumber`, `pipewire-pulse`) start through the user manager that pam_systemd creates.

**The cues are played.** With `-Audio -AudioBackend wav`, six arrow keys in the picker (1.2 s apart) gave six 45 ms bursts at 0.06, 1.22, 2.43, 3.63, 4.84 and 6.06 s (peak 4393). On the fresh disk, `ret`, `right`, `left`, `esc`, `ret` in the wizard gave five bursts of 120, 45, 45, 110 and 120 ms: the select (about 0.12 s), navigate (0.04 s) and back (0.11 s) cues, matching the wav lengths. The shell's stream is visible in `wpctl status` as above. The stream is persistent (it flips between `[init]`, `[paused]` and streaming), so no polling of a short-lived stream was needed.

**One warning, explained:** the shell's journal has three `QSoundEffect: playback of this format is not supported on the selected audio device` lines (one per cue) right after Qt's `Ignoring dummy output`, at the first shell start of a session. It is a **start-up race**: the shell loads the cues before WirePlumber has created the HDA sink, so Qt sees only PipeWire's dummy output. Evidence: (1) when the compositor was restarted in the same session (sink already present) the lines did not appear; (2) the cues are played in both cases (recordings above). The wav format is not the cause: I converted the cues from mono to stereo (the sink is stereo) in a test image and the warning stayed, so that change was reverted. Left as it is (Inbox line); nothing waits for audio before showing the shell, which is right.

**Other findings:** the image has no `pw-cli`, `pw-top`, `pw-dump` or `pw-mon` (`pipewire-utils` is not installed), so the task's suggested stream view is `wpctl status`. A first version of `vm-audio-check.sh` used `pw-mon` and was replaced.

**Found outside this task's scope and fixed:** three lone `0xA7` bytes (a `§` written in the wrong encoding by my Python edit in T-107: two specs and a comment in `Shell.qml`) had reached `main`. Python on this host writes cp1252 by default. Repaired to UTF-8; the pitfall is now in the root `CLAUDE.md`, and a scan of every tracked text file as UTF-8 is clean.

**Verification:** `.\scripts\dev.ps1 test` → ALL GREEN (also after the stereo test; run again at the end). The VM boot is `RUYA_BOOT_OK` with and without `-Audio`. **Unverified:** how it sounds, a real HDMI/analog output, Bluetooth, volume control reaching PipeWire (the `Audio` singleton is still a mock until T-114).
