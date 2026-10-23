# T-128 — `ruya-devices`: the audio part of `org.ruyaos.Devices1` over PipeWire, in the VM

Status: todo · Phase: 2 · Depends: T-114, T-121 · Area: services, image, shell · Size: M

## Goal
Settings → Audio and the volume keys control real PipeWire outputs in the VM: the new Rust service `ruya-devices` implements `org.ruyaos.Devices1.Audio` (contract from T-114), and the shell uses it over D-Bus on Linux instead of the mock.

## Read first
- `docs/specs/00-overview.md` ADR-010 (**who owns PipeWire and how this service runs: a user unit of `ruya-shell`**), ADR-004
- `docs/specs/03-services-and-apps.md` §2.3 (audio policy), `docs/specs/02-shell.md` §5 (channels)
- `api/dbus/org.ruyaos.Devices1.xml` (the contract; extend it if needed, `CLAUDE.md` step 4)
- `services/CLAUDE.md` (crate structure, the ADR-010 exception), `services/ruya-profiles/` (reference: pure core, injected side-effect trait, thin zbus adapter, `--session` dev mode)
- `shell/src/audio/` (`MockAudioBackend` is the behaviour to mirror; `DBusAudioBackend` is the client; `Audio::create` picks the backend)
- `docs/tasks/T-121-vm-audio.md` Outcome and `docs/dev-setup.md` "Audio in the VM" (`smoke-test.ps1 -Audio`, `vm-audio-check.sh`)

## Scope
1. **Crate `services/ruya-devices`** following `ruya-profiles`:
   - a pure core (`audio.rs`): the sink list, the default, the "previous default" stack and the hot-plug policy of 03 §2.3 (a new usb/bluetooth sink becomes the default; when the default goes, the previous one returns), master volume and mute, the three channel levels (clamped 0–100), status strings from the XML header. Every rule unit-tested on Windows;
   - a side-effect trait (`PipeWire`-like: list sinks, set default, set volume/mute, a stream of sink-added/removed events) with a fake for tests and a Linux implementation. Talking to PipeWire through `wpctl`/`pw-dump` (JSON) as child processes is acceptable for this task; say in the commit why, if you add a crate instead;
   - channel levels are stored by the service (persist them under the service's state directory, atomic write) and reported; applying `ambient`/`media` to app streams is out of scope (the shell already applies `ui` to its own sounds, T-114);
   - a thin zbus adapter emitting `SinksChanged`, `DefaultSinkChanged` and `PropertiesChanged`; `--session` dev mode with the fake backend.
2. **Image** (ADR-010): a user unit `image/rootfs/usr/lib/systemd/user/ruya-devices.service` (`ConditionUser=ruya-shell`, after `wireplumber.service`, `Type=dbus`, all hardening a user manager accepts), enabled globally for user sessions; D-Bus policy `org.ruyaos.Devices1.conf` (only `ruya-shell` owns the name; only `ruya-shell` and root call it); binary built in the `services-build` stage. Add `pipewire-utils` if you use `wpctl`/`pw-dump` (also wanted for debugging, B-007).
3. **Shell:** `Audio::create` defaults to D-Bus on Linux, like `Profiles` (B-007 asked for this). Defer `Sfx` sound loading until the backend reports a default sink, if that removes the start-up `QSoundEffect ... not supported` warnings seen in T-121 (say in the Outcome whether it did).
4. A guest-side check script `scripts/vm-devices-check.sh` (copy `vm-profiles-check.sh`): service active, name owned, `ListSinks` shows the HDA sink as default, a `MasterVolume` write is visible in `wpctl get-volume @DEFAULT_AUDIO_SINK@`, a call from another user is refused.

## Out of scope
- Network and Bluetooth interfaces (T-129 adds the network contract and mock; its service is later).
- Exposing PipeWire to profile apps (`ruya-session`, ADR-010), ducking, HDMI passthrough.
- Real hot-plug in the VM beyond what QEMU can do; the policy is proven by unit tests.

## Acceptance criteria
- [ ] Core rules (policy, clamping, unknown sink, unknown channel, previous-default fallback, channel persistence) have unit tests (`dev.ps1 rust` green on both targets).
- [ ] VM (`smoke-test.ps1 -Audio`, image built from this commit): `RUYA_BOOT_OK`, and `vm-devices-check.sh` passes every check above (output pasted in the Outcome).
- [ ] VM: in the running shell, Settings → Audio lists the VM's output, and moving the Master slider changes the `wpctl` volume (screenshot via `vm-screenshot.ps1` + `wpctl` output in the Outcome).
- [ ] `systemctl --user -M ruya-shell@ status ruya-devices` (or equivalent) shows the unit active; `systemd-analyze --user security ruya-devices` result recorded in the Outcome.
- [ ] `dev.ps1 test` ALL GREEN; the mock path (Windows) is unchanged.

## Verification
```powershell
.\scripts\dev.ps1 test
# WSL: scripts/build.sh, make-disk.sh qcow2; then
.\scripts\smoke-test.ps1 -Audio
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §2.3 (what is built), `docs/specs/01-platform.md` (the new unit), `docs/dev-setup.md` (`vm-devices-check.sh`), STATUS blocker B-007 (audio part done; network/Bluetooth left).

## Hints
- `wpctl status`/`pw-dump` need `XDG_RUNTIME_DIR` of `ruya-shell`; a user unit has it. Use `wpctl inspect` / `pw-dump` JSON `node.name` as the sink `id` (stable across reboots), `node.description` as `name`.
- The kind (`hdmi`/`analog`/`usb`/`bluetooth`) comes from the device's `device.bus` / `api.alsa.pcm.*` / `device.api` properties; default to `analog` when unsure and say so in the Outcome.
- Owning a system-bus name from a user unit: `Type=dbus` + `BusName=` work in user units only for the *user* bus; for the system bus use `Type=simple` (or `notify`) and request the name in code, or `Type=exec` and let the shell retry. Check which you need and record it.

## Outcome
_Filled in by the implementer: what was built, files, how it was verified, deviations, follow-ups._
