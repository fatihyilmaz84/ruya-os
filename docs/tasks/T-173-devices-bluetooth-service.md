# T-173 — `ruya-devices`: `Devices1.Bluetooth` over BlueZ

Status: in-progress · Phase: 2 · Depends: — · Area: services, image · Size: M · Owner: builder

## Goal
The Bluetooth pane T-136 built against the mock talks to a real service. On a machine with an adapter, scanning, pairing a "just works" controller, connecting and forgetting go through BlueZ. With no adapter (as in the VM), the pane says Bluetooth is unavailable.

## Read first
- `api/dbus/org.ruyaos.Devices1.xml`, the `Bluetooth` interface (T-136; statuses `ok`, `unknown-device`, `pairing-failed`, `timeout`, `unavailable`, `invalid`, `failed`)
- `docs/specs/03-services-and-apps.md` §2.1; ADR-010 in `00-overview.md`
- `services/ruya-devices/src/network.rs` + `networkmanager.rs` (the reference: a pure core plus the system-service adapter, T-132), `dbus.rs`, `services/CLAUDE.md`
- `shell/src/bluetooth/DBusBluetoothBackend.cpp` (compiled, never run: it is the other half of this contract)
- `scripts/vm-devices-check.sh`

## Scope
1. **Pure core** (unit-tested): device list ordering (paired first), the 30 s scan auto-stop, power-off clearing the list, mapping BlueZ errors to the contract's statuses, battery from `org.bluez.Battery1`.
2. **BlueZ adapter:** `org.bluez` over the system bus (Adapter1, Device1, Battery1, ObjectManager signals → `DevicesChanged`). A `Powered` write that rfkill blocks answers `failed`.
3. **Pair timeout:** `Pair` answers within the D-Bus default call timeout (~25 s). The service either answers `timeout` itself before that, or the client sets a longer call timeout. Write the rule in the XML.
4. **Image:** `bluez` installed and `bluetooth.service` enabled. The `ruya-devices` bus policy and unit get only what BlueZ needs, and the hardening stays.
5. **Contract:** extend it if the real service needs it, in the same commit (XML, service, mock, client).

## Out of scope
- PIN/passkey pairing dialogs, player assignment, button test and remapping (input daemon, B-006).
- Bluetooth audio routing (B-007).

## Acceptance criteria
- [ ] Core unit tests: ordering, scan auto-stop at 30 s (fake clock), power-off clears, every BlueZ error name maps to a contract status (`cargo test -p ruya-devices`).
- [ ] VM (this task): image built, `RUYA_BOOT_OK`; `vm-devices-check.sh` asserts `bluetooth.service` is active, `ListDevices` answers an empty list, and `StartScan` answers `unavailable` with no adapter. A real adapter and controller are **unverified** (none in the VM): say so.
- [ ] `systemd-analyze security ruya-devices` is no worse than before (Outcome: both numbers).
- [ ] `dev.ps1 test` ALL GREEN.

## Docs to update
- `03` §2.1 (as built, service side), `01` (packages, units), STATUS B-007 note.

## Outcome
Verified: vm (image `0.0.35-t173` built and booted, `RUYA_BOOT_OK 0.0.35-t173`; `vm-devices-check.sh check`: ALL CHECKS PASSED, audio, network, batteries and the new Bluetooth part) and host (`dev.ps1 test` ALL GREEN). A real adapter and controller are **unverified** (none in the VM): scanning, pairing, Battery1, rfkill and the 20 s/30 s timers against real hardware were tested only against `FakeBluez`. `shots` not run: no UI file changed.

**What was built.**
- `services/ruya-devices/src/bluetooth.rs`: pure core (`Bluetooth<B: Bluez>`, trait `Bluez`, `FakeBluez`). Ordering (paired first, then name, then id; unnamed unpaired devices left out), `kind` from BlueZ's `Icon`, battery from `Battery1.Percentage` (-1 when none), 30 s scan auto-stop (`start_scan(now)`, `scan_deadline()`, `tick(now)`; fake-clock tests), power-off clears list and scan, `map_error` for every `org.bluez.Error.*` name plus the bus errors, pair = Pair + Trusted + Connect.
- `bluez.rs` (Linux): `org.bluez` client with zbus (GetManagedObjects for adapter, Device1, Battery1; Adapter1 StartDiscovery/StopDiscovery/RemoveDevice; Device1 Pair/Connect/Disconnect; Properties.Set for Powered/Trusted). BlueZ missing reads as no adapter. `Pair`/`Connect` give up after 20 s (`CALL_TIMEOUT`), call `CancelPairing`/`Disconnect` and report `timeout`.
- `dbus.rs`: `BluetoothIface` (`Powered` rw, `Discovering`, `ListDevices`, `StartScan`, `StopScan`, `Pair`, `Forget`, `Connect`, `Disconnect`, `DevicesChanged`) and `watch_bluetooth` (BlueZ signals + NameOwnerChanged, 300 ms debounce, and the scan deadline in the same loop, so no polling and no extra tasks). `main.rs` wires it; `--session` serves `FakeBluez`.
- **Pair timeout rule** (task item 3): the service answers `timeout` itself after 20 s, before the 25 s D-Bus default; written in the XML header. The client is unchanged.
- **Contract** (same commit): XML text only (timeout rule; `Powered` doc now says the list is empty while off and Powered is false without an adapter). No names, arguments or statuses changed, so mock and `DBusBluetoothBackend` are untouched. A `Powered` write BlueZ refuses (no adapter: `org.bluez.Error.NotReady`; rfkill blocked) answers a D-Bus error, as the XML always said; the client turns that into `failed`. The task text "answers `failed`" is that.
- **Controller battery:** `ListDevices.battery` is reported for the pane; the service raises no low-battery event (UPower stays the single source, T-161).
- **Image:** `bluez` was already installed (`20-base.sh`); new are `systemctl enable bluetooth.service` (Containerfile) and a drop-in `bluetooth.service.d/10-ruyaos.conf` that clears the stock `ConditionPathIsDirectory=/sys/class/bluetooth` (without an adapter that directory is missing, the unit is skipped and `org.bluez` is absent; in the VM `bluetoothd` now runs idle at ~5.8 MB RSS). **Bus policy:** BlueZ's own policy lets only root and group `bluetooth` call `org.bluez`; `org.ruyaos.Devices1.conf` now also lets user `ruya-shell` `send_destination="org.bluez"` (nothing else of BlueZ: no `own`). Confirmed in the VM: `Powered`/`ListDevices`/`StartScan` reach BlueZ as the user unit. Side effect to know: any process running as `ruya-shell` (the shell itself) can now call BlueZ too; third-party apps run as other users.
- **Hardening:** `ruya-devices.service` is unchanged (`RestrictAddressFamilies=AF_UNIX` is enough for the system bus). `systemd-analyze --user security ruya-devices`: before 3.4 OK (T-132, same unit file; not rebuilt from the old image), after 3.4 OK (VM, `vm-devices-check.sh security`).
- **`vm-devices-check.sh`**: new `bluetooth` part (also in `check`): `bluetooth.service` active, `org.bluez` on the bus, `Powered`/`Discovering` false, `ListDevices` empty, `StartScan`/`Pair` `unavailable`, `Pair("")` `invalid`, `Forget(unknown)` `unknown-device`, `StopScan` `ok`, `Powered` write error, other user refused.
- **Tests:** 20 new Rust tests in `bluetooth.rs` (Rust total 82 in `ruya-devices`). Revert checks: reversing the paired-first comparison fails `paired_devices_come_first_then_by_name`; changing `SCAN_LIMIT` to 31 s fails `the_contract_times_hold`. `dev.ps1 test`: 342 QML passed, 28 skips, Rust all passed.
- **Docs:** `03` §2.1 (service side), `01` packages row. **STATUS B-007 note not edited** (the lead owns STATUS): BlueZ is no longer open there.

Files: see the commit. Deviation: the pure core also decides the `unavailable`/`unknown-device` order (empty id first, then no adapter, then unknown id).
