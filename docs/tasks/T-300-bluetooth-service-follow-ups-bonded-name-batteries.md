# T-300 — Bluetooth service follow-ups: `bonded` and the device's own name in ListDevices, Batteries re-announce, one format-character list

Status: todo · Phase: 2 · Depends: — · Area: api, services (ruya-devices bluetooth, battery, pairing, families), shell (backend, mock, client) · Size: M · Owner: builder

## Goal
The service tells the shell whether a paired device is actually bonded and what the device calls itself, announces a controller's battery as soon as it bonds even if UPower listed it earlier, and the QML and Rust format-character lists cannot drift apart. This is the base of T-301's "Pair again".

## Read first
- `docs/specs/03-services-and-apps.md` §2.1 (Bluetooth), `api/dbus/org.ruyaos.Devices1.xml` (`Bluetooth.ListDevices`, `Batteries.ListBatteries` with its `family` key)
- `services/CLAUDE.md`; `services/ruya-devices/src/bluetooth.rs` (device records, `Bonded` comment ~line 224), `bluez.rs`, `families.rs` (`family_of(modalias, name)`), `battery.rs`, `upower.rs`, `pairing.rs` (`is_format_char`, `clean_name`)
- `shell/src/bluetooth/`, `shell/src/battery/` (mock, D-Bus client), `shell/qml/DeviceIcons.qml` (`plain`)
- T-203, T-260, T-199, T-223 Outcomes; STATUS-parked.md "Inbox triage 2026-11-07", bullets T-300

## Scope
1. **Contract first** (XML, then service with tests, mock, D-Bus client): `ListDevices` entries get `bonded` (b: BlueZ `Device1.Bonded`; a device paired before the pairing fix is `Paired: yes, Bonded: no` and only reconnects in pairing mode) and `device_name` (BlueZ `Name`, the model as it advertises, while `name` stays the user's Alias). Clients treat a missing key as bonded=true / device_name="".
2. **Family from the device's own name:** `families.rs` uses `device_name` first, then the alias, so a renamed pad ("Living room pad") keeps its family; table test.
3. **Batteries re-announce:** when a controller bonds or connects after UPower already listed its battery device (or the other way round), `ListBatteries` consumers get a `BatteriesChanged` with the right `family`; test with fake UPower/BlueZ event order both ways.
4. **UPower serial:** map a DualSense's UPower `Serial`/`NativePath` to the Bluetooth address (as `family` already does) so the chip, Settings > Bluetooth and the pairing picker agree on the icon; table test with a real-looking UPower record.
5. **One format-character list:** the characters `DeviceIcons.plain` (QML) and `pairing::is_format_char` (Rust) strip come from one fixture file (`services/ruya-devices/tests/fixtures/format-chars.txt`) that a Rust test and a `tst_battery_cluster.qml`/`tst_bluetooth.qml` test both read.

## Out of scope
- The "Pair again" UI and the other shell follow-ups (T-301), polling versus a udev source for `InputPresent` (B-006), the PairableTimeout (T-299), a Bluetooth keyboard announcement (T-301).

## Acceptance criteria
- [ ] Rust tests: `bonded=false` for a fake paired-not-bonded device; `device_name` carries BlueZ `Name` while `name` is the Alias; a renamed DualSense still gets `playstation`; event-order tests for Scope 3 (each red when its logic is removed).
- [ ] `tst_bluetooth.qml::test_bonded_flag_from_mock` and `tst_battery_cluster.qml::test_family_after_late_bond`; the shared-fixture test fails when a character is added to only one side.
- [ ] XML, Rust service, mock and client agree (names, types, defaults for a missing key).
- [ ] VM (lead run): `vm-devices-check.sh bluetooth` prints `bonded` and `device_name` for a fake device; `batteries` still passes. Outcome `Verified: host (vm pending: vm-devices-check.sh bluetooth batteries)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 rust
```

## Docs to update
- 03 §2.1, the XML comments, `docs/developers/controller-input.md` if it lists the fields.

## Hints
- Reference: how `family` was added to both lists in T-199/T-223 (same files). Parse JSON, never key order, in the VM check.
- Overlaps T-301 (depends on this), T-264 (registry; epic, not started).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
