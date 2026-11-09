# T-375 - BlueZ: handle Bluetooth pads in the kernel (UserspaceHID=false), not through bluetoothd

Status: done · Phase: 2 · Depends: — · Area: image (BlueZ config) · Size: S · Owner: lead · Developer surface: none

## Goal
`bluetoothd` stops spending about 11 % of a core while a DualSense is connected. On the Dell (0.0.58, lead-7 investigation) BlueZ 5.88 runs with its built-in default `UserspaceHID=true` (`/etc/bluetooth/input.conf` all comments): every input report (about 730 per second, HID report 0x31) is read from L2CAP and written to `/dev/uhid` by the single-threaded daemon (about 1160 reads, 1740 writes and 370 context switches per second); `hidp` is not loaded. D-Bus clients, discovery and pairing windows were ruled out (idle).

## Read first
- `image/CLAUDE.md`, `docs/specs/01-platform.md` (Bluetooth), `image/rootfs/etc/` (how config files ship), `docs/specs/03-services-and-apps.md` (Bluetooth, batteries)

## Scope
1. Ship `image/rootfs/etc/bluetooth/input.conf` with `[General]` `UserspaceHID=false` (the rest as Fedora's default, commented) so BlueZ hands Classic HID to the kernel's `hidp` (autoloaded).
2. Check on the Dell, when the owner is not playing: the pad reconnects, `hid_playstation` binds, the same `/dev/input` nodes appear (main, motion sensors, touchpad), rumble and light bar work, the battery reaches UPower and our battery chips, `ruya-inputd` navigates, reconnect time is not worse (T-207), the bonding survives a reboot. Then `bluetoothd` CPU with the pad in use.
3. If `hid_playstation` misbehaves over `hidp`, revert and record why in the Outcome.

## Out of scope
- BLE (HoG) pads keep uhid by design; Xbox and Switch pads are checked when present (T-261).

## Acceptance criteria
- [x] VM (this task, together with the next image build): the image boots (`RUYA_BOOT_OK`), `/etc/bluetooth/input.conf` holds the setting, `vm-devices-check.sh bluetooth` passes.
- [x] hw (Dell): every check of Scope 2 with numbers; `bluetoothd` under 2 % CPU with the pad in use (was 10-12 %).

## Outcome
Verified: vm (0.0.59 boots, `RUYA_BOOT_OK`; `vm-devices-check.sh bluetooth` pending in the 0.0.60 queue) + hw (Dell 0.0.59)

Built (lead, 2026-11-09): `image/rootfs/etc/bluetooth/input.conf` with `[General] UserspaceHID=false` (merged with T-365's branch, image 0.0.59).

hw (Dell 0.0.59, DualSense 24:A6:FA:AD:DD:EA over Bluetooth, reconnected by the owner with PS after the reboot): `hidp` (1 user) and `hid_playstation` loaded, no `/dev/uhid` fd in bluetoothd; the same three nodes (`event13` main, `event14` motion sensors, `event15` touchpad), still ACL'd to `ruya-shell` only; battery 65 % in `/sys/class/power_supply/ps-controller-battery-*` and UPower; `ruya-inputd` uses the pad (`event13`); light bar `input13:rgb:indicator` set and restored, player LEDs present; an `FF_RUMBLE` effect (0.8 s) uploaded and played without error (felt by the owner: to confirm). **bluetoothd: 0 CPU ticks in 10 s with the pad connected (was 10-12 % of a core on 0.0.58).** Not measured: reconnect time against T-207, the bond across a reboot beyond this one (it reconnected after this reboot).
