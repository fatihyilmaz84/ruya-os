# T-174 — `ruya-devices`: `Devices1.Storage` over udisks2

Status: todo · Phase: 2 · Depends: T-137 · Area: services, image · Size: M · Owner: builder

## Goal
Plug a USB stick into the console and the shell toasts "Drive inserted". Settings → Storage lists it with its free space and ejects it safely. This is the real service behind T-137's mock.

## Read first
- `api/dbus/org.ruyaos.Devices1.xml`, the `Storage` interface (T-137: `ListVolumes`, `Eject`, `VolumesChanged`, `VolumeAdded`; statuses `ok`, `unknown-volume`, `busy`, `unsupported`, `invalid`, `failed`). The XML says `VolumeAdded` is sent for hot-plug only, before `VolumesChanged`.
- `docs/specs/03-services-and-apps.md` §2.2; `CLAUDE.md` security invariant "Nothing auto-runs from removable media"
- `services/ruya-devices/src/network.rs` + `networkmanager.rs` (reference pattern), `services/CLAUDE.md`
- `shell/src/storage/DBusStorageBackend.cpp` (compiled, never run)
- `scripts/smoke-test.ps1`, `scripts/vm-lib.ps1`, `scripts/vm-devices-check.sh`

## Scope
1. **Pure core** (unit-tested): which block devices are volumes, removable vs internal, `unsupported` for unknown filesystems, free-space values, `VolumeAdded` only for hot-plug (not for volumes present at start).
2. **udisks2 adapter:** list, auto-mount removable volumes read-only or `nosuid,nodev,noexec`, and eject (unmount and power off; `busy` when a file is open).
3. **Image:** `udisks2` present and its polkit rules allow `ruya-devices` only. Auto-mount may never execute anything. The hardening stays.
4. **Contract:** extend it if needed, in the same commit (XML, service, mock, client).

## Out of scope
- The toast's Browse media and Install package actions (spec 03 §2.2, later with Media).
- Formatting drives; internal disks other than listing them.

## Acceptance criteria
- [ ] Core unit tests: classification, `unsupported`, hot-plug-only `VolumeAdded`, `busy` mapping (`cargo test -p ruya-devices`).
- [ ] VM (this task): image built, `RUYA_BOOT_OK`; a USB stick image (exFAT or FAT) hot-plugged through the QEMU monitor (`device_add usb-storage`) appears in `ListVolumes` with `VolumeAdded`, is mounted `noexec`, and `Eject` removes it. `vm-devices-check.sh` (or a new `vm-storage-check.sh`) does it unattended.
- [ ] `systemd-analyze security ruya-devices` is no worse than before (Outcome: both numbers).
- [ ] `dev.ps1 test` ALL GREEN.

## Docs to update
- `03` §2.2 (as built, service side), `01` (packages, mount policy).

## Hints
- QEMU needs a USB controller for hot-plug (`-device qemu-xhci`). Check how `smoke-test.ps1` starts QEMU before you add one.

## Outcome
_Filled in by the implementer._
