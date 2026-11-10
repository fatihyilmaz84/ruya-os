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
_Filled in by the implementer._
