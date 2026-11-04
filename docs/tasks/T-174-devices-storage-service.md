# T-174 — `ruya-devices`: `Devices1.Storage` over udisks2

Status: done · Phase: 2 · Depends: T-137 · Area: services, image · Size: M · Owner: builder

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
Verified: vm (round 2: image 0.0.39-t174, RUYA_BOOT_OK, vm-storage-check.ps1 passed in full; round 1 was 0.0.38-t174: RUYA_BOOT_OK; `scripts/vm-storage-check.ps1` passed on the second full run, after the fixes under "VM run")

**Built**
- `services/ruya-devices/src/storage.rs` (pure core, 24 unit tests): classification (removable = drive removable or USB/SDIO bus and not `HintSystem`; `HintIgnore` and drive-less devices never listed; internal volumes only when mounted outside the system paths; five known filesystems, else `unknown`), free space only while mounted, label fallbacks, order, mounting policy, `VolumeAdded` hot-plug only, `Eject` with `busy` mapping (what was unmounted is mounted again), a `FakeUdisks`.
- `services/ruya-devices/src/udisks.rs` (Linux): `GetManagedObjects`, `Filesystem.Mount/Unmount`, `Drive.PowerOff/Eject`, `statvfs` through `libc` (already in the tree through ruya-update; Linux-only dependency).
- `dbus.rs`: `StorageIface` (keys of each dictionary in alphabetical order, so the VM check can parse `busctl` output) and `watch_storage` (udisks2 signals + name owner, shared debounce, no polling); `Eject` refreshes at once. `main.rs`: first read at start (mounts sticks already plugged in, no `VolumeAdded`), `--session` runs on a fake stick.
- Mount policy: removable volumes with a known filesystem are mounted once when first seen, `nosuid,nodev,noexec`, read-write (read-only would stop people copying saves onto a stick; the three options already stop execution, privilege gain and device nodes). Never re-mounted after an eject or a failed mount until unplugged (`seen` set; tests cover it).
- Image: `image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-storage.rules` (ruya-shell: `filesystem-mount`, `eject-media`, `power-off-drive` and the `-other-seat` variants only). `udisks2`, `exfatprogs`, `ntfs-3g` were already in `20-base.sh`; the unit file is unchanged.
- VM check: `scripts/vm-storage-check.ps1` (host: QEMU monitor `drive_add` + `device_add usb-storage`, format, detach, re-attach) and `scripts/vm-storage-check.sh` (guest steps).
- Contract: XML only got clearer text for `ListVolumes` (which volumes are listed and mounted); no names or statuses changed, so mock and shell client are untouched.

**Deviations / interpretations**
- Spec 03 said "mounted for the active profile (`/run/media/<user>/...`)": mounted for `ruya-shell` (the user the service runs as); profile users get media access with the Media task. Spec updated.
- Internal volumes: listed only when mounted outside system paths (the OS partitions would be noise); never mounted or ejected.

**Revert tests:** removing `noexec` from `MOUNT_OPTIONS` plus the `seen` guard failed 3 storage tests (options, no re-mount after eject, failed mount); forcing `added` empty failed 3 (hot-plug, unsupported hot-plug, leave-and-return).

**VM run (0.0.38-t174, QEMU xhci + usb-storage, 64 MiB exFAT image):** `make-disk.sh` first failed with "Cannot allocate memory", a plain retry passed. The first runs only showed script faults, no service fault: (1) `vm-storage-check.ps1` threw on ssh stderr and swallowed the guest output, now `Continue` and `Write-Host`; (2) `device_del` removes the legacy `drive_add` drive, so the second attach defines it again; (3) `modify-device` and `encrypted-unlock` are allowed for `ruya-shell` by **udisks2's own default policy** (active session, `allow_active=yes`), not by our rule, so the check now prints them as notes instead of failing. Result of the last run: baseline (polkit allows `filesystem-mount`, `eject-media`, `power-off-drive`; `filesystem-mount-system`, `-unmount-others`, `-fstab` need authentication = not allowed; nobody refused; `Eject ""` invalid, unknown id `unknown-volume`); hot-plug: listed after ~3 s, already `mounted`, `exfat`, `removable`, mount options `rw,nosuid,nodev,noexec,relatime,uid=972,...`, exactly one `VolumeAdded` before `VolumesChanged`, writing works, a copied binary does not run, `free_bytes` 64995328 vs kernel 64958464; `Eject` with a process in the mount: `busy`, stays mounted and listed; `Eject` after: `ok`, volume leaves the list, unmounted, the USB disk is gone from the kernel, no second `VolumeAdded`.
**Round 2 (review):** the polkit rule now answers NO for every `org.freedesktop.udisks2.*` action outside the allow list for `ruya-shell` (round 1 left udisks2's default allow_active=yes for `modify-device`, `encrypted-unlock`, loop devices). `ruya-devices` needs nothing else: it only calls `Filesystem.Mount`, `Filesystem.Unmount` (of its own mounts, no check), `Drive.PowerOff`/`Eject`, and reads. VM (0.0.39-t174): `pkcheck` exit 0 for `filesystem-mount`, `eject-media`, `power-off-drive`; exit 1 for `filesystem-mount-system`, `-unmount-others`, `-fstab`, `modify-device`, `modify-device-system`, `encrypted-unlock`, `loop-setup`, `rescan`; `nobody` cannot read `/run/media/ruya-shell`; all steps passed again. `Storage::refresh` no longer holds the state lock across the blocking `mount` call (test `listing_is_not_blocked_while_a_mount_runs`; with the old code it fails after its 2 s timeout). Specs 01/03 say what the rule allows and refuses.

**Security:** `systemd-analyze --user security ruya-devices`: before 3.4 OK (T-173), after 3.4 OK (unit file unchanged).

**Unverified:** unsupported filesystem and a drive with two partitions in the VM (unit tests only). Real USB hardware, SD readers and NTFS sticks are not covered by the VM check.

