# T-336 - Bluetooth with more than one adapter: every device is operated through its own adapter

Status: in-progress · Phase: 2 · Depends: — · Area: api, services (ruya-devices), shell (Bluetooth backend, mock) · Size: M · Owner: builder

## Goal
The Dell has two Bluetooth adapters (`hci0` 00:E0:4C:23:99:87 and `hci1` 34:2E:B7:CE:C3:9E: presumably the built-in Realtek and a USB dongle). `bluez.rs` merges the devices of all adapters into one list but builds every device path (`Pair`, `Trust`, `Connect`, `Disconnect`, `Remove`, rename) and the pairing window from the first adapter only. A pad bonded on `hci1`, or an `hci0`/`hci1` order that flips between boots, is listed but cannot be connected or forgotten and looks "gone". After this task a listed device always works, and there is one deliberate rule for which adapter new pairings use.

## Read first
- `docs/LEAD-NOTES.md` "Owner report the second DualSense overrides the first", item (3)
- `services/ruya-devices/src/bluez.rs` (`read` keeps only the first adapter; `adapter_path`, `device_path`; every method calls `adapter_path()` then `device_path(&adapter, address)`), `bluetooth.rs` (`Raw`, `RawAdapter`, `RawDevice`, `Bluez` trait, `FakeBluez`, `secure_adapter`, `open_window`), `pairing.rs`
- `api/dbus/org.ruyaos.Devices1.xml` interface `Devices1.Bluetooth`; `shell/src/bluetooth/*` (backend, mock, `Bluetooth` facade); `docs/specs/03-services-and-apps.md` Bluetooth paragraphs (pairing must bond, window)
- `docs/tasks/T-289-system-information-follow-ups.md` (reads the adapter address from BlueZ: use the same "primary adapter" function, do not write a second one)
- `docs/tasks/T-264-controller-registry-and-slots-service.md` (the registry will list controllers by id: keep the device id = address; if the registry needs the adapter, it reads the new field)

## Scope
1. **Contract first (`Devices1.Bluetooth`):** each `ListDevices` dictionary gets `adapter` s (the adapter's name, `hci0`, so a log or a bug report can say which). The adapter-wide state (`Powered`, `Discovering`, pairable) stays one value: those of the primary adapter. A new method or property that lists adapters is allowed only if the shell needs it; justify in the Outcome. Update the XML header, the shell mock and the D-Bus client in the same commit.
2. **Per-device routing (`bluez.rs`, `bluetooth.rs`):** `RawDevice` carries its adapter object path; the `Bluez` trait calls for one device (`pair`, `set_trusted`, `connect`, `disconnect`, `remove`, `set_alias`) resolve the device path from that adapter, not from the first one. A device that is no longer in the last snapshot is looked up again before the call fails with `unknown-device`. Devices of every adapter appear in the list (as today).
3. **One rule for new pairings, scanning and the window (the "primary adapter"):** the adapter that has the most paired devices; ties go to a USB-attached one (sysfs path contains `/usb`), then to the lowest `hciN`. Powered/scan/pairable/window act on the primary only. Record the rule in `03`. If the builder finds a better rule, change it and say why in the Outcome. Do not build an adapter chooser screen.
4. **Power:** `set_powered(off)` switches off every adapter, `on` every adapter that is not rfkill-blocked, so a pad bonded on the second adapter does not keep working while Bluetooth looks off; `Powered` reported = any adapter on. (If this is wrong for a reason you find, say so.)
5. **Fake:** `FakeBluez::with_two_adapters()` (two adapters with their own devices, a pad bonded on the second) and `--session` serves it with an env switch so the VM check can use it.

## Out of scope
- An adapter chooser in Settings, per-adapter power switches, LE/audio routing between adapters, BlueZ plugin or `main.conf` changes, why the Dell has two adapters (answer it in the Outcome from `hciconfig -a`/`btmgmt info` on the Dell if the lead has run T-338, else leave it).

## Acceptance criteria
- [ ] Rust tests (two-adapter fake): `a_device_on_the_second_adapter_connects_through_the_second_adapter`, `forget_removes_from_the_adapter_that_holds_the_device`, `rename_and_trust_use_the_devices_adapter`, `the_primary_adapter_has_the_most_paired_devices_then_usb_then_lowest_number`, `the_window_and_scan_use_the_primary_adapter_only`, `the_order_of_adapters_flipping_changes_nothing_for_a_bonded_pad`, `power_off_switches_every_adapter`, `a_device_in_the_list_is_never_unreachable` (every listed device accepts connect through the fake). Revert check: building the path from the first adapter again turns the first, second and sixth red.
- [ ] D-Bus client and mock carry `adapter`; `tst_bluetooth.qml::test_adapter_field_reaches_the_model` (no visible change).
- [ ] Optional if cheap: the missing test of T-300's review, `BatteriesChanged` from `BluetoothIface::emit`, with a fake UPower beside this fake BlueZ (Inbox line parked in `STATUS-parked.md`, "Inbox triage 2026-11-08", tag T-300).
- [ ] VM (lead run): `vm-devices-check.sh` `bluetooth_fake_check` with the two-adapter fake: a pad on `hci1` is listed with `adapter hci1`, `Connect` and `Forget` of it succeed. The real two-adapter hardware is checked on the Dell by the lead (hw). Outcome `Verified: host (vm pending: vm-devices-check.sh bluetooth)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `api/dbus/org.ruyaos.Devices1.xml`, `docs/specs/03-services-and-apps.md` (Bluetooth: the primary adapter rule), `docs/dev-setup.md`.

## Hints
- BlueZ object paths: `/org/bluez/hci1/dev_34_2E_...`; a device exists under each adapter that has seen it, so key by (adapter, address) internally and by address for the list: if one address is under two adapters prefer the one that is paired/connected.
- Overlaps T-334 (same files, tests) and T-335 (log lines gain the adapter name): sequence them, do not run in parallel.

## Outcome
_Filled in by the implementer._
