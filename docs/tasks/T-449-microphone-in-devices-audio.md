# T-449 — Microphone in `Devices1.Audio`: list inputs, default input, mute

Status: in-progress · Phase: 2 · Depends: — · Area: api, services (ruya-devices), shell (client and mock) · Size: S · Owner: builder · Complexity: normal · Developer surface: internal

## Goal
The shell can list the console's microphones (USB headset, Bluetooth headset, a pad's mic where PipeWire shows one), pick the default one and mute it, so the Hub's Audio panel and its microphone tile have a real backend.

## Read first
- `api/dbus/org.ruyaos.Devices1.xml` (Audio: `ListOutputs`, `SetOutput`, `Muted`); `docs/specs/03-services-and-apps.md` (ruya-devices audio, ADR-010); `services/CLAUDE.md`
- the shell's audio client and mock (`shell/src/network` is the newest complete reference)

## Scope
1. Contract first: `ListInputs` (id, name, kind, available), `SetInput(id)`, a read/write property `InputMuted` with its change signal; status strings like the outputs'.
2. `ruya-devices`: implement over PipeWire/WirePlumber the way the outputs are; a console without a microphone returns an empty list, never an error.
3. Mock and shell client; no UI in this task.

## Out of scope
- Input levels, noise suppression, a per-app microphone permission (T-220).

## Acceptance criteria
- [ ] XML, Rust service, mock and client agree; Rust tests for list, set and mute, with no source and with an unknown id (test names in the Outcome)
- [ ] Trust boundary: an id that is not a listed source is refused (test)
- [ ] VM (lead run): `vm-audio-check.sh` extended: the VM's capture source is listed and mute round-trips; Outcome `Verified: host (vm pending: vm-audio-check)`
- [ ] `dev.ps1 test` ALL GREEN

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `03` (Devices1.Audio), the XML docs.

## Hints
- Planned by lead-10 (ADR-033). QEMU's `-Audio` gives the VM a capture device.

## Outcome
Verified: host (vm pending: vm-audio-check)

`dev.ps1 test` ALL GREEN (1079 QML passed, 90 skipped; Rust: 478 ruya-devices tests, 12 of them new).

Built the microphone half of `Devices1.Audio`; no UI (T-450).

- **Contract** (`api/dbus/org.ruyaos.Devices1.xml`): `ListInputs` (`id`, `name`, `kind` analog|usb|bluetooth, `available` yes|no|unknown like the outputs, `is_default`), `SetInput(id)`, read/write property `InputMuted` (EmitsChangedSignal), signal `InputsChanged`, new status `unknown-input`. Header lists the status; "failed" now also covers writing `InputMuted` with no microphone. Contract is `internal` (shell and root only by the bus policy), not tagged experimental.
- **Service** (`services/ruya-devices`): `pipewire::parse_sources` (only `media.class == Audio/Source`: a monitor, a virtual source and a stream are not listed; `available` from the card's input `Route` in use), `Audio::{list_inputs,set_input,set_input_muted}`, `Source`/`SourceKind`, the `PipeWire` trait got `set_default_source` and `set_source_muted` (`WpCtl`: `wpctl set-default <id>` with the id looked up among `Audio/Source` nodes only, `wpctl set-mute @DEFAULT_AUDIO_SOURCE@`), `Snapshot`/`View`/`Changes` carry sources, default source, input mute (watcher announces `InputsChanged` and `InputMuted`). No microphone is an empty list, never an error. The service saves nothing: WirePlumber keeps the default source.
- **Shell client and mock**: `AudioBackend` (`InputInfo`, `inputsListed`, `inputMutedReported`, `setInputFinished`), `DBusAudioBackend`, `MockAudioBackend` (one built-in `mic-0`; `plugInput`/`unplugInput` for tests; the mute is per microphone as in PipeWire), `Audio` singleton (`inputs`, `defaultInput`, `inputMuted`, `setInput`, `setInputMuted`, `toggleInputMute`, `mockPlugInput`, `mockUnplugInput`).
- **VM**: `scripts/vm-audio-check.sh` extended (ListInputs lists a default microphone, `SetInput` refuses an unknown id and a sink name, accepts the default, `InputMuted` round-trips and matches `wpctl`; prints `AUDIO_INPUT_OK`/`AUDIO_INPUT_FAIL`). Needs the VM booted with `-Audio`. Not run (lead run).

Tests (Rust, `ruya-devices`): `audio::tests::inputs_list_the_microphones_and_mark_the_default`, `a_console_without_a_microphone_lists_nothing_and_has_no_error` (empty list, unknown id, mute fails, nothing written), `set_input_moves_the_default_microphone_and_is_idempotent`, `an_id_that_is_not_a_listed_microphone_is_refused_before_pipewire` (trust boundary: unknown id, a sink id, empty, `@DEFAULT_AUDIO_SOURCE@`; zero writes), `a_failing_pipewire_changes_no_microphone_state`, `input_mute_reaches_pipewire_and_the_view`, `microphone_changes_from_outside_are_reported_once`, `a_default_that_names_no_listed_microphone_is_not_a_default`; `pipewire::tests::a_dump_lists_only_real_microphones_with_kind_availability_and_default`, `a_dump_without_microphones_is_an_empty_list_not_an_error`. QML: `shell/tests/tst_audio_input.qml` (9 tests: list, plug, set, refusal, mute round trip and separation from the output mute, mute per microphone, none present, unplug the default).

Revert checks: removing the list check in `Audio::set_input` fails `an_id_that_is_not_a_listed_microphone_is_refused_before_pipewire` and `a_console_without_a_microphone_...`; widening the `Audio/Source` match in `parse_sources` fails the dump test; deleting the `input_props` detection in `apply` fails `microphone_changes_from_outside_are_reported_once`; muting every mock microphone instead of the default (`revert-check.ps1`, `-Test tst_audio_input`) fails `test_the_mute_belongs_to_the_microphone`.

Round 2 (review): `tst_audio_input.qml` waits on `tryVerify(() => Audio.inputs.length === N)` (a QVariantList copy cannot be polled with `tryCompare`). `AudioIface::set_input_muted` now returns `fdo::Result<()>` and answers `Failed` when the write is refused (no microphone, PipeWire refused), so Properties.Set fails as the XML says (test `dbus::tests::writing_input_muted_without_a_microphone_is_a_bus_error`). `Audio::set_input` reads the new default's mute from PipeWire at once and `SetInput` announces `InputMuted` when it changed (test `audio::tests::set_input_reads_the_new_defaults_mute`; the fake now keeps a mute per microphone). `MockAudioBackend::publishInputs` is counted in `pendingReplies()`, so `tst_audio.qml` `test_an_older_reply_arriving_late_is_dropped` now expects 4 pending replies instead of 3: the input list is a fourth kind of reply, not a weakened assertion; new `test_a_late_input_list_is_dropped` in `tst_audio_input.qml`. Revert checks: not forwarding the new default's mute (`audio.rs`) fails the first new Rust test; returning `Ok(())` from the setter (`dbus.rs`) fails the second.

Deviations / notes: `available` is a string (yes/no/unknown) to match `ListOutputs`, not a bool. The D-Bus client (`DBusAudioBackend`) cannot run on this host; it follows the existing output code and is covered only by compilation until the VM run.
