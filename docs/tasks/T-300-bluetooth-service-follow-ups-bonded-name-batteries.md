# T-300 — Bluetooth service follow-ups: `bonded` and the device's own name in ListDevices, Batteries re-announce, one format-character list

Status: in-progress · Phase: 2 · Depends: — · Area: api, services (ruya-devices bluetooth, battery, pairing, families), shell (backend, mock, client) · Size: M · Owner: builder

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
Verified: host (vm pending: vm-devices-check.sh bluetooth batteries). `dev.ps1 test` ALL GREEN (891 QML passed, 67 skipped screenshot tests; 344 `ruya-devices` lib tests plus the other crates). No UI changed, so no `shots`.

**Built**
- **Contract** (`api/dbus/org.ruyaos.Devices1.xml`): `ListDevices` gained `bonded` (b) and `device_name` (s); missing keys read as bonded=true / device_name="". `BatteriesChanged` is documented as also sent for a family-only change.
- **Service**: `bluez.rs` reads `Bonded` and `Name`; `bluetooth.rs` `RawDevice`/`Device` carry `name`/`device_name` and `bonded`; `families::family_of_device(modalias, device_name, alias)` (modalias, else the device's own name, else the alias); `dbus.rs` sends both keys.
- **Batteries re-announce**: `Batteries` keeps `read` (UPower) and `shown` (what clients last saw, families resolved against Bluetooth). `refresh_with(&bluetooth)` (UPower watcher, now given the Bluetooth core) and `recheck(&bluetooth)` (called from `BluetoothIface::emit` whenever `DevicesChanged` goes out, which covers the watcher, the notifier and every method) return true when that list differs, and `BatteriesChanged` is sent. Both event orders and the forget case are tested in the core. The startup baseline is taken after the first Bluetooth read (`main.rs`).
- **UPower serial**: the mapping from `Serial`/`NativePath` to the Bluetooth address already existed (`address_in`); a table test with real-looking records (hid-playstation `ps-controller-battery-<address>`, a serial, a BlueZ path, records with no address) now checks that a renamed DualSense gets the same family as `ListDevices`. No code change was needed.
- **One format-character list**: `services/ruya-devices/tests/fixtures/format-chars.txt`; `pairing.rs` test and `tst_bluetooth.qml::test_format_characters_are_the_services_fixture` compare every BMP code point (controls excluded, both sides strip them as a class) with it. The comparison found a real drift: QML stripped U+2065 (it hides `0x2060-0x206f`), Rust did not; Rust now strips `2060-206F`.
- **Shell**: `BtDevice.bonded/deviceName`, `Bluetooth.devices` entries `bonded` and `deviceName`, D-Bus client defaults, mock (`mockSetBonded`, forget unbonds, pair bonds, `deviceName` = the original name and a rename keeps it).
- **VM check**: `vm-devices-check.sh bluetooth` (and the full run) now also starts `ruya-devices --session` on a private bus (`dbus-run-session`, as ruya-shell) and parses `ListDevices` JSON: the session fake has a third pad (`FakeBluez::with_old_pad`: alias "Living room pad", Name "DualSense Wireless Controller", paired, not bonded, no modalias) and the check requires bonded=false, device_name, name and family playstation, and bonded=true for the normal pad. `batteries` is unchanged.

**Tests and revert checks** (each undone temporarily, test went red, file restored): `battery.rs` `recheck` made a no-op -> `a_pad_that_bonds_after_upower_listed_it_is_announced_with_its_family`; `refresh_with` resolving against `&[]` -> that test and `a_battery_upower_lists_after_the_pad_bonded_has_the_family_at_once`; `bonded: d.bonded` -> `true` -> `a_paired_device_that_is_not_bonded_says_so`; `family_for(.., &d.name, &d.alias)` -> alias twice -> `a_renamed_dualsense_without_a_modalias_still_gets_playstation`; `device_name: d.name` -> alias -> `the_device_name_is_bluezs_name_...`; `family_of_device` ignoring `device_name` -> the renamed-pad table in `families.rs`; `pairing.rs` range `2060-206F` -> `2060-2064` -> the fixture test (names U+2065). QML (`revert-check.ps1 -Test`): `Bluetooth.cpp` `bonded` -> `true` -> `test_bonded_flag_from_mock`; `DeviceIcons.qml` `0x206f` -> `0x2064` -> `test_format_characters_are_the_services_fixture`; `Batteries.cpp` family -> `QString()` -> `test_family_after_late_bond`.

**Files**: `api/dbus/org.ruyaos.Devices1.xml`, `services/ruya-devices/src/{battery,bluetooth,bluez,dbus,families,main,pairing}.rs`, `services/ruya-devices/tests/fixtures/format-chars.txt`, `shell/src/bluetooth/{Bluetooth.h,Bluetooth.cpp,BluetoothBackend.h,DBusBluetoothBackend.cpp,MockBluetoothBackend.h,MockBluetoothBackend.cpp}`, `shell/tests/{tst_bluetooth,tst_battery_cluster}.qml`, `scripts/vm-devices-check.sh`, `docs/specs/03-services-and-apps.md` (one new bullet in 2.1).

**Notes and limits**
- `test_family_after_late_bond` covers the shell side only: the mock re-announces the battery with a family and the chip's glyph follows. The wiring that sends `BatteriesChanged` from `BluetoothIface::emit` is a thin adapter on Linux; its rule (`recheck`) is unit-tested, the signal itself is not (unverified here; the VM check does not exercise it either, as the VM has no adapter and no controller).
- The mock key is `deviceName` (QML naming); the wire key is `device_name`.
- The "D-Bus client reads a missing key as true / empty" defaults are in `DBusBluetoothBackend.cpp` and have no test (no D-Bus off Linux).
- `docs/developers/controller-input.md` lists no `ListDevices` fields, so it is unchanged.

**Follow-ups** (also in the HANDOFF inbox): T-301 can use `bonded` for "Pair again" and `deviceName` for the model line; a Bluetooth-side `DevicesChanged` now also costs one cheap `recheck` (a lock and a list compare).
