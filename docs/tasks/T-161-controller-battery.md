# T-161 — Controller battery: `Devices1` over UPower, status cluster, low-battery toast

Status: in-progress · Phase: 2 · Depends: T-157 · Area: api, services, image, shell · Size: M · Owner: builder

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
- [ ] VM (this task): image built, `RUYA_BOOT_OK`; a VM check (extend `scripts/vm-devices-check.sh`) asserts `upower` runs and `ListBatteries` answers an empty list. A real controller's battery is **unverified** (no controller in the VM); say so.

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
Verified: vm (image 0.0.34-t161 built and booted, RUYA_BOOT_OK; vm-devices-check.sh check: ALL CHECKS PASSED incl. upower active and ListBatteries empty) and host (dev.ps1 test ALL GREEN); screenshots pending (desktop locked); a real controller battery unverified

**Built.**
- Contract: new interface `org.ruyaos.Devices1.Batteries` in `api/dbus/org.ruyaos.Devices1.xml` (`ListBatteries` -> `aa{sv}` with `id`, `name`, `percent`, `state`; signal `BatteriesChanged`; no status strings, the list is the status).
- Service: `battery.rs` (pure core: only UPower kind 12 "gaming input"; state 1/5 charging, 2/3/6 discharging, 4 full, else unknown; percent rounded and clamped; sorted by id; a pad with unknown state and 0 % has no reading and is not listed; `Batteries` with change detection; `FakeUPower`), `upower.rs` (Linux client: `EnumerateDevices` + `GetAll`; ServiceUnknown/NameHasNoOwner/spawn errors read as an empty list), and in `dbus.rs` `BatteriesIface` and `watch_batteries` (UPower's signals plus NameOwnerChanged for UPower, debounced 300 ms, no polling). `--session` serves a fake "Dev Pad" at 60 %.
- Image: `upower` added to `image/build/20-base.sh` (and the package table in spec 01). It is D-Bus activated. The user unit needed no change: `AF_UNIX` is enough for the system bus and UPower's own bus policy lets any user call it; no hardening was relaxed.
- Shell: `Batteries` singleton (`shell/src/battery/`: backend interface, mock, D-Bus client, the QML face with `controllers`, `lowest`, `lowestState`, `low`, `batteryLow`). The status cluster in `Shell.qml` shows `batteryStatus` (icon + level) first in the pill: `battery_full`, `battery_charging_full`, or `battery_alert` + warning colour while the lowest controller discharges at 15 % or less; hidden without a controller. `ToastLayer` raises `Controller battery low (15%)` (warning) once per crossing (discharging and 15 % or less; re-armed after recovery or charging). Three icons added to the font subset (`icons.txt`, `Icon.qml`, both TTFs re-cut).
- Turkish for the two new strings.

**Which battery source wins (reconciliation with T-136).** A Bluetooth controller is in `Devices1.Bluetooth.ListDevices` (own `battery`) and in UPower (BlueZ's Battery1 feeds UPower; wired/dongle pads are UPower only). `Devices1.Batteries` is the one source for the status cluster and the controller low-battery toast. `Bluetooth.batteryLow` is no longer raised for devices of kind `controller` (still for headset/audio/other under 15 %), so there is no second toast. Settings -> Bluetooth & controllers still shows each device's own `battery`. To keep the existing T-136 toast test meaningful it now drives the connected non-controller "Soundbar" (it used to use the controller `bt-pad-main`) and additionally asserts that a controller at 5 % raises nothing; this is a changed requirement, not a weakened one. Documented in spec 03 and the XML.

**Deviations.** The singleton is `Batteries`, not `Devices.batteries` (every device class has its own singleton). The toast text uses `%1%` like the other battery toast ("15%", not "15 %"). The low limit is "15 % or less" (as in this task), whereas the Bluetooth toast is "under 15 %" (T-136, unchanged).

**Tests.** Rust `battery::tests` (8). QML `tst_battery.qml` (7) and the changed `test_low_battery_toast_once_per_crossing`. Revert tests: removing the kind-12 filter fails `a_laptop_battery_a_mouse_and_other_peripherals_are_not_listed`; removing the controller exclusion in `Bluetooth::checkBatteries` fails the Bluetooth test and `test_a_bluetooth_controller_does_not_toast_twice`; changing `<=` to `<` fails `test_low_battery_toast_once_and_not_while_charging`.

**Unverified.** A real controller's battery (no controller in the VM; type 12 mapping is from UPower's `UpDeviceKind`, checked only against the installed version's behaviour in the VM as far as the empty list goes). Screenshot review: pending, desktop locked (lead re-shoots `shots`).

**Files.** `api/dbus/org.ruyaos.Devices1.xml`, `services/ruya-devices/src/{battery,upower,dbus,lib,main}.rs`, `image/build/20-base.sh`, `scripts/vm-devices-check.sh`, `shell/src/battery/*`, `shell/src/bluetooth/Bluetooth.{h,cpp}`, `shell/qml/{Shell,ToastLayer,Icon}.qml`, `shell/fonts/*`, `shell/i18n/*.ts`, `shell/CMakeLists.txt`, `shell/tests/{tst_battery,tst_bluetooth}.qml`, specs 01/03/04.
