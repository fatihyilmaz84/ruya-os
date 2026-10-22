# T-114 — Audio: Devices contract (audio part) and Settings → Audio

Status: todo · Phase: 2 · Depends: T-103, T-108 · Area: api, shell · Size: M

## Goal
Settings → Audio lists the output devices (HDMI, headset, Bluetooth…), lets the user pick the default and set the per-channel volumes, and reacts when devices appear or disappear. It is defined by a contract, so the future Rust `ruya-devices` service (PipeWire) can implement it.

## Read first
- `docs/specs/03-services-and-apps.md` §2.3 (audio policy), `docs/specs/02-shell.md` §5 (channels: UI, Ambient, Media; ducking)
- T-108 Outcome (the `Audio` singleton and its mock already exist; extend it, don't duplicate it)

## Scope
1. `api/dbus/org.ruyaos.Devices1.xml`, **audio part only**, designed so network and Bluetooth can be added later as separate interfaces on the same object:
   - interface `org.ruyaos.Devices1.Audio`:
     - `ListSinks() → aa{sv}` (id, name, kind `hdmi|analog|usb|bluetooth`, is_default);
     - `SetDefaultSink(s id) → s status`;
     - properties `MasterVolume` (u 0–100), `Muted` (b) and `ChannelVolumes` (`a{su}` with keys `ui`, `ambient`, `media`);
     - `SetChannelVolume(s channel, u value) → s status`;
     - signals `SinksChanged()`, `DefaultSinkChanged(s id)`.
2. Extend the shell `Audio` backend (mock + new D-Bus client) to this contract.
   - The mock starts with HDMI (default) and Analog. Test-only invokables simulate plugging in or removing a "USB headset" and a "BT headphones".
   - Mock policy, mirroring spec §2.3: a newly connected headset or BT device becomes the default. When the default disappears, fall back to the previous default.
3. Volume keys while muted: Volume Up unmutes and raises; Volume Down while muted stays muted (decided here; today a step while muted changes the level but not the mute). Mute toggles only mute.
4. Settings → Audio pane (copy `DisplayPane.qml`; the Audio category is still "Coming soon", so add `AudioPane.qml` and register it in `SettingsPage.qml`):
   - an output device list (Accept sets the default; the current default is marked);
   - SliderRows for Master, UI sounds, Ambient and Media;
   - a "Mute" ToggleRow.
   Changes apply live.
5. Toast on sink changes: "Audio output: <name>" (T-108).
6. `Sfx` volume follows the `ui` channel volume (`SoundEffect.volume`).

## Out of scope
- The Rust `ruya-devices` service and PipeWire integration (needs Linux; add it to the blocked list if it isn't there).
- Ducking (handled in WirePlumber policy later).
- HDMI passthrough settings.

## Acceptance criteria
- [ ] `Devices1.xml` exists with the audio interface above; the Outcome justifies the interface split for future network/Bluetooth.
- [ ] Plugging in the mock USB headset makes it the default and shows a toast; unplugging restores HDMI (test `tst_audio.qml::test_hotplug_policy`).
- [ ] Selecting Analog in Settings sets it as default (test `test_select_output`).
- [ ] The UI sounds slider changes `Sfx` volume (test `test_ui_channel_drives_sfx`).
- [ ] Volumes clamp at 0–100 (test).
- [ ] Volume Up while muted unmutes; Volume Down while muted does not (test `test_volume_keys_while_muted`, in `tst_system_ui.qml` or `tst_audio.qml`).
- [ ] Screenshot `22-settings-audio.png`.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §2.3: reference the contract.
- `docs/STATUS.md`: add or confirm blocked item "ruya-devices (PipeWire) service".

## Hints
- Copy the pattern of `DisplayPane.qml` (a `SettingsPane` with controls kept in sync through `Binding`) and register the pane in `SettingsPage.qml`; `ProfilesPane.qml` shows how messages and focus restoration are handled.
- **UI rules since T-117:** colours and durations come from `Theme` tokens; the token lint in `dev.ps1 shell` fails on literals. The OSD and toasts already use tokens.
- The PipeWire side is only checkable in the VM (T-121 checks that the sound path exists at all); this task stays on the mock.

## Outcome
_Filled in by the implementer._
