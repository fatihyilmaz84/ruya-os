# T-161 — Controller battery: `Devices1` over UPower, status cluster, low-battery toast

Status: todo · Phase: 2 · Depends: T-157 · Area: api, services, image, shell · Size: M · Owner: builder

## Goal
The status cluster on Home shows the controller's battery, as the design asks (04 §2), from real data: `ruya-devices` reads UPower, and a controller running low raises a toast.

## Read first
- `docs/specs/03-services-and-apps.md` (controllers: "Battery level comes from `upower` … Low battery shows a toast"), `04-design-system.md` §2 (status cluster), §3.7 (icons), §5 (`GlassPill`, Toast), §8
- `api/dbus/org.ruyaos.Devices1.xml`; `services/ruya-devices/src/` (`network.rs` + `networkmanager.rs` are the pattern for a pure core over a system service, `events.rs` for signals); ADR-010 (why `ruya-devices` is a user unit)
- `shell/src/network` (backend pattern), the status cluster in `shell/qml/Shell.qml` (`statusGlass`), T-157 Outcome (`Icon`, which glyph names exist)
- `services/CLAUDE.md`, `shell/CLAUDE.md`, `image/CLAUDE.md`

## Scope
1. **Contract first** (`Devices1`): the controllers' batteries, for example `ListBatteries() -> a{sv}[]` with `id`, `name`, `percent` (0–100), `state` (`charging` | `discharging` | `full` | `unknown`), and a `BatteriesChanged` signal. Status strings in the header.
2. **Service:** a pure core that turns UPower devices into that list (only gaming-input devices: UPower's `Type` for gamepads; ignore the PC's own battery and peripherals), and a UPower client on the system bus (`EnumerateDevices`, `DeviceAdded`/`DeviceRemoved`, each device's `PropertiesChanged`). If UPower is not on the bus, the list is empty, never an error.
3. **Image:** make sure `upower` is installed and the user unit may reach it (no hardening relaxed beyond what the bus call needs; record any change).
4. **Shell:** `Devices.batteries` through the mock and the D-Bus client; the status cluster shows one battery icon (T-157 glyph) with the lowest controller's level when at least one controller reports a battery, nothing otherwise; a `warning` toast "Controller battery low (15 %)" once when a controller drops to 15 % or below while discharging.
5. Turkish for the new strings; specs 03 and 04 §2 marked built.

## Out of scope
- Player assignment, per-controller lists in Settings → Bluetooth & controllers (T-136 owns that pane), Bluetooth pairing.
- Battery of the PC itself (laptops), charging animations.

## Acceptance criteria
- [ ] Pure core: a gamepad at 40 % discharging is listed; a laptop battery and a mouse are not; a device removed leaves the list (Rust tests).
- [ ] Mock: one controller at 60 % → the battery icon is visible in the status cluster; none → hidden; a drop to 15 % → one toast, not repeated at 14 % (QML tests).
- [ ] Screenshot of Home with the battery in the status cluster, reviewed against `04` §2 and §8 (icon size and alignment with the clock).
- [ ] VM: image built, `RUYA_BOOT_OK`; a VM check (extend `scripts/vm-devices-check.sh`) asserts `upower` runs and `ListBatteries` answers an empty list. A real controller's battery is **unverified** (no controller in the VM); say so.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```
Then the image recipe in `docs/dev-setup.md` and the devices check over SSH.

## Docs to update
- `docs/specs/03-services-and-apps.md` (controllers), `04-design-system.md` §2 (status cluster: built), the Devices1 XML header.

## Hints
- UPower device `Type` 12 is "gaming input" in current UPower; check the installed version's enum before relying on it, and keep the mapping in the pure core with a test.
- Copy how `networkmanager.rs` watches a system-bus service from the user unit.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
