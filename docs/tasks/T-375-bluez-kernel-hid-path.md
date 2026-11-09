# T-375 - BlueZ: handle Bluetooth pads in the kernel (UserspaceHID=false), not through bluetoothd

Status: in-progress · Phase: 2 · Depends: — · Area: image (BlueZ config) · Size: S · Owner: lead · Developer surface: none

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
- [ ] VM (this task, together with the next image build): the image boots (`RUYA_BOOT_OK`), `/etc/bluetooth/input.conf` holds the setting, `vm-devices-check.sh bluetooth` passes.
- [ ] hw (Dell): every check of Scope 2 with numbers; `bluetoothd` under 2 % CPU with the pad in use (was 10-12 %).

## Outcome
_Filled in by the implementer._
