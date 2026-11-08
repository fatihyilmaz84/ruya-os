# T-332 - Format a removable drive: the service (udisks2 Block.Format, polkit, refusals)

Status: todo · Phase: 2 · Depends: T-196, T-194 · Area: api, services (ruya-devices), image (polkit rule, packages) · Size: M · Owner: builder

## Goal
Owner, 2026-11-08: "allow the user to format the removable drives". The service side: `Devices1.Storage` can erase and format one removable drive with a filesystem from a short list, for an admin only, and refuses everything that could hit the system disk, a drive in use, or a different stick than the one the person chose. The screens are T-333.

## Read first
- `docs/specs/03-services-and-apps.md` §2.2 (T-174: "internal disks are never mounted, ejected or formatted"; the Time paragraph for the polkit and "trust boundary" wording to copy)
- `api/dbus/org.ruyaos.Devices1.xml` interface `Devices1.Storage`; `services/ruya-devices/src/storage.rs` (`RawVolume`, `SYSTEM_MOUNTS`, `Udisks` trait, `UnmountError`), `udisks.rs`, `dbus.rs`, `time.rs` (`caller_may_set`)
- `image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-storage.rules` (all other udisks2 actions are NO for `ruya-shell`), `50-ruyaos-time.rules`
- `services/ruya-session` `ClearHistory(profile, admin_id, admin_pin)` and `api/dbus/org.ruyaos.Profiles1.xml` `VerifyAdmin` (the PIN is checked by `ruya-profiles`; hashes never leave it)
- `image/CLAUDE.md`, `image/build/20-base.sh` (packages), `scripts/vm-storage-check.sh` and `.ps1` (the QEMU virtual USB disk)

## Scope
1. **What the image can make (do this first).** `20-base.sh` installs `exfatprogs` and `ntfs-3g`. In the built image (WSL image or a booted VM) run `command -v mkfs.ext4 mkfs.exfat mkfs.vfat mkntfs` and write the result in the Outcome. `mkntfs` may live in `ntfsprogs` and `mkfs.vfat` in `dosfstools`, which an install without weak dependencies may not pull in. If one is missing, add the package to `20-base.sh` (and keep it in `50-slim.sh`'s keep list); this needs the owner's yes only if it is not one of the two named in STATUS "Open owner decisions" (drive formats: `dosfstools`, `ntfsprogs`). The service offers only what it finds (`FormatOptions` below), so the screens can never list a filesystem the image cannot make.
2. **Contract first (`Devices1.Storage`):** `FormatOptions() -> a{sv}` (`filesystems` as `aa{sv}` of `id` ext4|exfat|vfat|ntfs, `recommended` b, `max_label` i, `max_file_bytes` x or -1), `Format(id, filesystem, label, erase, identity, admin_id, admin_pin) -> status` (`erase` `quick|full`), a signal `FormatStateChanged(id, state)` (`working|ok|failed`). Add `identity` s to the `ListVolumes` dictionary: an opaque stable value built from the drive's serial (else WWN, else vendor+model), its size and the filesystem UUID. Statuses: `ok`, `unknown-volume`, `not-removable`, `unsupported` (filesystem not offered), `invalid` (label), `busy`, `changed` (identity differs), `forbidden`, `wrong-pin`, `locked-out`, `failed`. Extend or reshape as needed; XML first, then Rust, mock, client.
3. **Refusals (pure, `format.rs`, tested before any call to udisks):** the volume must be in the current list with `removable` true on a drive whose every volume is removable; never a drive that holds any `SYSTEM_MOUNTS` path, `/var` or the booted image's device (look at the mount table too, not only `HintSystem`); never an internal disk or a loop/zram device; label rules per filesystem (length, characters; control and Unicode format characters refused like the profile names); caller rule like `time::caller_may_set`: only while Profiles1's active profile is an admin, and the service itself asks `Profiles1.VerifyAdmin(admin_id, admin_pin)` (fail closed: `wrong-pin`, `locked-out`, `forbidden`); no PIN or hash is logged.
4. **The format (Linux, `udisks.rs`):** re-read udisks right before acting and compare `identity` (`changed` if it differs, nothing touched); unmount the volume and every other mounted partition of the drive (`busy` if a file is open: remount what was unmounted, never force); then make a fresh partition table (recommended `dos` up to 2 TiB, else `gpt`) with one partition and the filesystem (`PartitionTable.CreatePartitionAndFormat`, or `Block.Format` on the drive then on the partition; record which in the Outcome) with the label and the `erase` option (`full` = `erase: zero`; it cannot report progress and cannot be cancelled: say so in the XML). `FormatStateChanged` is `working` at the start and `ok` or `failed` at the end. After `ok` the new volume is mounted once by the existing mount policy (nosuid,nodev,noexec) and listed; after `failed` nothing is mounted and the drive is listed as it is. Serialise: one format at a time; `Eject` and `SaveReport` on that drive answer `busy` meanwhile.
5. **Polkit (`50-ruyaos-storage.rules`):** add exactly `org.freedesktop.udisks2.modify-device` (and its `-other-seat` variant) for the user `ruya-shell`; everything else stays NO, in particular `modify-device-system`, `filesystem-unmount-others`, `encrypt-*`, `loop-*`. Update the file comment, and `03` with the same trust-boundary sentence as the Time rule (polkit sees the user, the admin check lives in the service; third-party apps never run as `ruya-shell`).
6. **Mock and client:** the shell's `Storage` mock and D-Bus client follow the contract with test hooks (`mockFormatResult`, `mockFormatDelayed`), and `Storage.format(...)`/`formatFinished(id, status)` through `RequestSequence`. No UI here (T-333).

## Out of scope
- Any screen (T-333), the data summary (T-331), partition editing, encryption, formatting internal disks or the console's own storage, repair/fsck, labels longer than the filesystem allows, a progress percentage.

## Acceptance criteria
- [ ] Rust tests (`format.rs`, fake udisks): refuses the system disk, a drive that holds `/var`, an internal volume, a volume not in the list, a drive with one non-removable volume (`not-removable`); wrong `identity` after a replug is `changed` and no unmount happens; a busy volume is remounted and nothing is formatted; an unknown filesystem is `unsupported`; each label rule; a non-admin caller, a wrong PIN and a locked-out admin are refused and the call never reaches udisks; a second format while one runs is `busy`; a failed format leaves the drive unmounted and listed; after `ok` the volume is listed and mounted with `nosuid,nodev,noexec`. Each refusal test names the check that must turn it red when removed.
- [ ] `FormatOptions` lists only filesystems whose tool exists (fake `which`): a missing `mkfs.vfat` removes FAT32.
- [ ] Mock, client and XML agree (`tst_storage.qml::test_format_statuses` with the mock; late reply dropped).
- [ ] `50-ruyaos-storage.rules`: a lint or test that the rule file allows exactly the listed actions (extend the existing storage-rule check if there is one; else `scripts/vm-storage-check.sh baseline` prints `pkcheck` for allowed and refused actions).
- [ ] VM (lead run): `scripts/vm-storage-check.sh` gets steps `fmtservice` and `fmtrefuse`, driven by `vm-storage-check.ps1` with the existing virtual USB disk: `Format` to ext4 then exFAT: `ListVolumes` shows the new filesystem and label, mounted `nosuid,nodev,noexec`, `free_bytes` within 5 % of the size, a file can be written; `Format` of the guest's system volume, of an unplugged id, with a wrong `identity` (replug between listing and call) and as `nobody` is refused and the stick's data is still there; `pkcheck` says NO for `modify-device-system`. Outcome `Verified: host (vm pending: vm-storage-check.sh fmtservice)`. Hardware (lead, the Dell): a real stick formatted to exFAT and read on the Windows PC.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `api/dbus/org.ruyaos.Devices1.xml`, `docs/specs/03-services-and-apps.md` (§2.2: the format rules, "internal disks are never formatted" stays), `image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-storage.rules`, `docs/dev-setup.md`, `docs/specs/01-platform.md` if packages change.

## Hints
- Not the first udisks write path: `udisks.rs` already mounts and unmounts; add `format` beside them with the same `UnmountError` style.
- Do not run in parallel with T-331 or T-333 (same files).
- Image risk is limited to the polkit rule and a package: a "VM (lead run)" is enough unless the package list grows; if it does, the lead runs `smoke-test.ps1` once with the next image.

## Outcome
_Filled in by the implementer._
