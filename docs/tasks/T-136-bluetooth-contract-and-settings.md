# T-136 — Bluetooth and controllers: `Devices1.Bluetooth` contract, mock, Settings pane

Status: todo · Phase: 2 · Depends: — · Area: api, shell · Size: M

## Goal
Settings → "Bluetooth & controllers" lets the user turn Bluetooth on or off, scan, pair a controller or headset with the pad alone, see battery levels and forget a device, against a mock. The BlueZ service part is a later task.

## Read first
- `docs/specs/03-services-and-apps.md` §2.1 (controllers: pairing, battery, player assignment) and §2.3 (the Audio policy for Bluetooth sinks)
- `api/dbus/org.ruyaos.Devices1.xml` (**add a sibling interface**, as the header says) and T-129's task Outcome (`docs/tasks/T-129-network-contract-and-settings.md`: the pattern, step by step)
- `shell/src/network/` (backend, mock, D-Bus client, facade), `shell/qml/NetworkPane.qml`, `shell/qml/SettingsPage.qml` (the `bluetooth` category is a placeholder)
- `shell/CLAUDE.md` (backend pattern) and `shell/PATTERNS.md` (settings controls)

## Scope
1. **Contract:** `org.ruyaos.Devices1.Bluetooth` in the same XML file. Cover: `Powered` (read/write), `Discovering`, a device list (`id`, `name`, `kind` = `controller | headset | audio | other`, `paired`, `connected`, `trusted`, `battery` = 0..100 or -1 unknown), `StartScan()`/`StopScan()`, `Pair(id)` (pairs, trusts and connects, as spec 2.1 says), `Forget(id)`, `Connect(id)`, `Disconnect(id)`, and a `DevicesChanged` signal. Status strings in the header (`ok`, `unknown-device`, `pairing-failed`, `timeout`, `unavailable`, `invalid`, `failed`). Extend rather than work around.
2. **Shell `Bluetooth` singleton** in `shell/src/bluetooth/` (mock by default off Linux, D-Bus client compiled and marked **unverified**), same structure as `shell/src/network/`.
3. **Settings pane** (`BluetoothPane.qml`, listed in `CMakeLists.txt`): a power toggle; "Add a device" that scans, with a short hint on how to put a controller into pairing mode; the discovered and paired devices as rows with status and a battery value where known; Accept on a device connects or disconnects, an action row forgets it. Everything by controller keys. With Bluetooth off, the pane says so and hides the lists.
4. **Low-battery toast** when a connected device's battery drops under 15 % (once per crossing).
5. The mock includes a controller that needs two scans to appear, one device whose pairing fails, and one with unknown battery.

## Out of scope
- BlueZ service, player assignment, button test and stick calibration, remapping (input daemon, B-006), pairing PIN/passkey dialogs (the mock only models "just works"), HID-over-GATT specifics.

## Acceptance criteria
- [ ] Contract and mock agree (a test goes through every status string with the mock).
- [ ] Toggling power off hides devices and stops scanning; on again shows the pane's list (test, focus asserted after each step).
- [ ] Scan → pair a mock controller by keys only → it shows `Connected` and its battery; a failed pairing shows the message and keeps focus on the row (tests in `tst_bluetooth.qml`).
- [ ] Forget removes the device and moves focus to a valid row (test).
- [ ] The low-battery toast fires once when the battery crosses 15 % (test).
- [ ] Screenshot `26-settings-bluetooth.png` reviewed (devices, a battery value, focus ring visible).
- [ ] `dev.ps1 test` ALL GREEN, `dev.ps1 shots` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §2.1 (as built, shell side only), `docs/specs/02-shell.md` (Settings), the XML header.

## Hints
- The Settings list scrolls (see the clipped rows in `23-settings-network.png`): after a list update keep focus on a still-existing row (T-131's "focus follows the list update").
- Refresh translations and give Turkish a real translation.

## Outcome
_Filled in by the implementer. Start with a `Verified:` line._
