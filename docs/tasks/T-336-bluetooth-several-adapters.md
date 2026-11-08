# T-336 - Bluetooth with more than one adapter: every device is operated through its own adapter

Status: done · Phase: 2 · Depends: — · Area: api, services (ruya-devices), shell (Bluetooth backend, mock) · Size: M · Owner: builder

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
Verified: host (vm pending: vm-devices-check.sh bluetooth). Review APPROVE round 2.

**What was built.** A device is always operated through the adapter that holds it; new pairings, the scan and the window use one deliberate primary adapter.
- **Contract (`org.ruyaos.Devices1.xml`):** `ListDevices` entries gained `adapter` (`hci0`); the `Powered` text says any-adapter-on / all-adapters-off and that scan and window are the primary's. No new method or property: the shell needs nothing beyond the field (justified: no adapter chooser, no per-adapter switch).
- **`bluetooth.rs`:** `RawDevice.adapter` (object path); `Raw` now holds `adapters: Vec<AdapterInfo>` (path, usb, state) instead of one `adapter`; `Raw::adapter()` is the primary's state with `powered` = any adapter on. `primary_index` is the one primary rule (most paired devices, then USB, then lowest `hciN`, numerically); T-289 should call it. `merge_devices` lists an address two adapters have seen once (connected, paired, bonded, primary). The `Bluez` trait calls for one device take the adapter path first; the core finds it with `Bluetooth::route` (last read, else a new read, else `DoesNotExist` = `unknown-device`) at every call site, including the window's (`pump`, `window_pair`, `finish`, the agent's stranger removal) and idle disconnects.
- **`bluez.rs`:** reads every adapter (USB from `/sys/class/bluetooth/hciN` via canonicalize) and tags each device with the parent of its object path; `set_powered` goes over all adapters (off: first error is the answer; on: fails only if none could be switched, a blocked adapter is skipped and logged); the adapter-wide calls take an adapter path from the core (see round 2). No call looks the adapter up itself any more.
- **Fake:** `FakeBluez::with_two_adapters()` (hci0 non-USB: Dev Pad + Found Pad in range; hci1 USB: Second Pad, Third Pad, bonded, so hci1 is primary). Like BlueZ it only accepts a device call through the adapter that holds the device (otherwise `UnknownObject`), and records `routes()` (`"connect AA:.. /org/bluez/hci1"`). `--session` serves it when `RUYA_DEVICES_FAKE_BLUETOOTH=two-adapters`.
- **Shell:** `BtDevice.adapter`, the D-Bus client (missing key = ""), `Bluetooth.devices[].adapter`, the mock (`bt-pad-old` is on `hci1`, the rest `hci0`); no visible change.
- **VM check:** `bluetooth_two_adapters_check` in `vm-devices-check.sh` (part of `bluetooth`): lists the two-adapter fake on ruya-shell's user bus, expects `adapter hci1` for the pad, `Connect` and `Forget` of it `ok`, and the other adapter's pad still listed.

**Criteria.** All Rust tests named in the task exist (plus `the_list_says_which_adapter_holds_each_device`, `a_device_two_adapters_have_seen_is_listed_once_under_the_one_that_holds_it`, `powered_is_any_adapter_on`, `a_device_that_came_after_the_last_read_is_looked_up_again`); `tst_bluetooth.qml::test_adapter_field_reaches_the_model`. The optional `BatteriesChanged` test of T-300 was not done (it needs a fake UPower wired to `BluetoothIface::emit`, not cheap; stays in `STATUS-parked.md`).

**Revert checks** (Rust, by hand: mutate, `cargo test -p ruya-devices --lib bluetooth`, restore): `route` returning the first adapter (`HCI0`) for every device turned red the first (`a_device_on_the_second_adapter_connects_through_the_second_adapter`), second (`forget_removes_from_the_adapter_that_holds_the_device`), third (`rename_and_trust_use_the_devices_adapter`), sixth (`the_order_of_adapters_flipping_changes_nothing_for_a_bonded_pad`), `a_device_in_the_list_is_never_unreachable` and `a_device_that_came_after_the_last_read_is_looked_up_again`. `primary_index` taking only the first adapter turned red `the_primary_adapter_has_the_most_paired_devices_then_usb_then_lowest_number` and `the_window_and_scan_use_the_primary_adapter_only`. `set_powered` of the fake touching only the first adapter turned red `power_off_switches_every_adapter`. The QML test: renaming the `adapter` key in `Bluetooth.cpp`'s model map (`revert-check.ps1 -Test tst_bluetooth`) turned `test_adapter_field_reaches_the_model` red.

**Round 2 (review: Pairable and scan must be tied to the adapter that pairs).** The adapter-wide trait calls (`set_pairable`, `set_discoverable`, `start_discovery`, `stop_discovery`) take the adapter path. `Window` stores its adapter and restores Pairable and its scan there; the user's scan stores the adapter it started on (`scan_adapter`); `pair_one` opens and closes Pairable on the adapter the device is under (the window's `Pairable` is relied on only when that is the window's adapter); `pump` offers only unpaired pads under the window's adapter; `secure_adapter` closes Pairable and Discoverable on every adapter. `FakeBluez::pair` keeps the key only through a pairable adapter (`bonded = pairable`), so a wrong adapter shows as `bonded: false`. New tests: `a_manual_pairing_opens_pairable_on_the_adapter_it_pairs_through`, `a_primary_flip_mid_window_still_closes_the_adapter_that_was_opened`, `a_scan_is_stopped_on_the_adapter_it_started_on`, `the_window_pairs_only_a_pad_under_its_own_adapter`, `every_adapter_found_pairable_is_closed_once`. Hand reverts, each turned exactly the named test red: `pair_one` opening Pairable on the primary (first), `close_window` restoring Pairable on the primary (second), `close_window` stopping the scan on the primary (second), dropping the adapter filter in `pump` (fourth), stopping the user's scan on the primary (third), securing only the first adapter (fifth). The XML now says that power-off answers the first error even if other adapters switched off.

**Rule kept as specified.** No better rule found: counting paired devices keeps a bonded pad's adapter primary whatever the order. Known limit: if the primary is off while another adapter is on, `Powered` reads true but scan/pair on the primary answer `unavailable`-ish errors until the user toggles power (power-on switches all, so rare). Why the Dell has two adapters: not answered (T-338 data not available to this task).

Files: `api/dbus/org.ruyaos.Devices1.xml`, `services/ruya-devices/src/{bluetooth,bluez,dbus,main,battery}.rs`, `shell/src/bluetooth/{Bluetooth.h,Bluetooth.cpp,BluetoothBackend.h,DBusBluetoothBackend.cpp,MockBluetoothBackend.cpp}`, `shell/tests/tst_bluetooth.qml`, `scripts/vm-devices-check.sh`, `docs/specs/03-services-and-apps.md`, `docs/dev-setup.md`.

