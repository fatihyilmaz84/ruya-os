# T-114 — Audio: Devices contract (audio part) and Settings → Audio

Status: done · Phase: 2 · Depends: T-103, T-108 · Area: api, shell · Size: M

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
- The Rust `ruya-devices` service and PipeWire integration (blocker B-007: waits for a lead decision on whose PipeWire owns the outputs).
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
- `docs/STATUS.md`: blocker B-007 already covers the `ruya-devices` service; add anything this task learns about it there.

## Hints
- Copy the pattern of `DisplayPane.qml` (a `SettingsPane` with controls kept in sync through `Binding`) and register the pane in `SettingsPage.qml`; `ProfilesPane.qml` shows how messages and focus restoration are handled.
- **UI rules since T-117:** colours and durations come from `Theme` tokens; the token lint in `dev.ps1 shell` fails on literals. The OSD and toasts already use tokens.
- The PipeWire side is only checkable in the VM (T-121 checks that the sound path exists at all); this task stays on the mock.

## Outcome

**Built**
- **Contract** `api/dbus/org.ruyaos.Devices1.xml`: interface `org.ruyaos.Devices1.Audio` on `/org/ruyaos/Devices1` with `ListSinks() -> aa{sv}` (`id`, `name`, `kind`, `is_default`), `SetDefaultSink(id) -> status`, `SetChannelVolume(channel, value) -> status`, properties `MasterVolume` (u, read/write), `Muted` (b, read/write), `ChannelVolumes` (a{su}, read) and signals `SinksChanged`, `DefaultSinkChanged(id)`. Status strings: `ok`, `unknown-sink`, `invalid`, `failed`. **Why one interface per device class:** the bus name and object stay `Devices1`, and network and Bluetooth arrive later as `org.ruyaos.Devices1.Network` / `.Bluetooth` next to `.Audio`. Existing clients (and their `PropertiesChanged` filters, which match the interface name) are untouched, and each class can be mocked, implemented and versioned on its own. Master volume and mute are plain read/write properties (no `SetMasterVolume` method); the channels need a method because writing one key of a dictionary property is not expressible.
- **Shell** (`shell/src/audio/`): `AudioBackend` now has `setChannelVolume`, `setDefaultSink`, a `stateChanged(volume, muted, channels)` and a `sinksListed` signal; `MockAudioBackend` (HDMI default + Analog, policy of 03 §2.3, test hooks `plug`/`unplug`/`reset`) and the new `DBusAudioBackend` (hand-parsed `a{sv}`, `aa{sv}`, `a{su}`; `Properties.Set` followed by a re-read so every command reports); `Audio` facade with `channelVolumes`, `sinks`, `defaultSink`, `defaultSinkName`, `setMuted`, `setChannelVolume`, `setDefaultSink`, `outputSwitched()` and the `mock*` test hooks.
- **UI:** `AudioPane.qml` (output rows kept in a `ListModel` that is updated in place by id, so focus stays on the row when the list is re-published; Master, UI sounds, Ambient, Media sliders; Mute switch), registered in `SettingsPage.qml` and `CMakeLists.txt`; the "Audio output: <name>" toast is a `Connections` in `Shell.qml`; `Sfx.gain` follows the `ui` channel.
- Docs: spec 02 section 1 table, 5.1 and a new 5.2; spec 03 section 2.3.

**Decisions / deviations**
- *Volume keys while muted:* Up unmutes and raises; Down stays muted and changes neither level nor mute (the OSD still shows "Muted"); Mute toggles only the mute. The task said "stays muted"; leaving the level alone is my reading.
- *`adjusted()` (the OSD trigger) only fires for master changes:* before, any state report fired it, which would have made the Volume OSD pop up when a channel slider moves. A master command still reports even when nothing changed (Up at 100).
- *Backend default:* `Audio.create()` uses the mock unless `RUYA_SERVICES=dbus`, on Linux too. The other services default to D-Bus on Linux, but `ruya-devices` does not exist, so a D-Bus default would silence the volume keys in the VM. Flip it when the service lands (noted on B-007).
- *Existing test touched:* `tst_settings.qml::test_two_pane_navigation` used Audio as its "category with no content"; Audio has a pane now, so it uses Storage (index 5). Same assertions, different category.
- The initial read of the sink list and state is not a "change": no toast, no OSD at start-up.

**Verification**
- `dev.ps1 test` -> ALL GREEN (114 passed offscreen; Rust and lint unchanged). New `shell/tests/tst_audio.qml` (11 tests): initial state, `test_hotplug_policy`, previous-default fallback, unknown sink refused, `test_select_output` (focus stays on the row), pane follows hot-plug (row appears and disappears, focus survives), sliders and Mute in the pane, `test_ui_channel_drives_sfx` (direct and through the slider), `test_volumes_clamp`, `test_volume_keys_while_muted`, a channel change does not show the OSD.
- `dev.ps1 shots` -> 124 passed on the second run; `22-settings-audio.png` reviewed (output rows with "Default" on the USB headset, four sliders, focus ring on Master; the Mute row is below the fold and scrolls into view when focused, like other long panes). The first run had one red `Power::test_guide_long_press` (a timer-based test under a real window); it passed on the re-run and is unrelated to audio.
- **Unverified:** `DBusAudioBackend` (compiles, never run: there is no service and no bus on this host), and everything PipeWire. That `Sfx` follows the channel is checked as a property value; how it sounds is unchecked (no audio output verification here).
