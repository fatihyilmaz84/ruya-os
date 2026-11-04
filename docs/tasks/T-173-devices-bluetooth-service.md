# T-173 — `ruya-devices`: `Devices1.Bluetooth` over BlueZ

Status: todo · Phase: 2 · Depends: — · Area: services, image · Size: M · Owner: builder

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
_Filled in by the implementer._
