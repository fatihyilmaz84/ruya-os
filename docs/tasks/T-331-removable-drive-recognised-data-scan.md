# T-331 - Settings > Storage shows what RuyaOS finds on a removable drive

Status: in-progress · Phase: 2 · Depends: T-196 · Area: api, services (ruya-devices), shell (Storage facade, mock, StoragePane) · Size: M · Owner: builder

## Goal
Owner, 2026-11-08: "if the drives contain data that is recognized by ruya os, then show that too (like the internal drive)". Each mounted removable drive in Settings > Storage gets the same kind of breakdown as "This console": used and free, then what RuyaOS knows on it (games, backups, captures, pictures, packages, reports) with sizes, and "Other" for the rest. The scan only reads names and sizes; it never opens, runs or trusts anything on the drive.

## Read first
- `docs/specs/03-services-and-apps.md` §2.2 Storage ("As built, service side (T-174)", "The console's own storage (T-196)")
- `api/dbus/org.ruyaos.Devices1.xml` interface `Devices1.Storage` (`GetSystemUsage` and `SystemUsageChanged` are the pattern: answer at once, work on the blocking pool, tell with a signal)
- `services/ruya-devices/src/sysusage.rs` (pure core over traits, fake source and clock, `TreeSize.partial`), `storage.rs`, `dbus.rs` (Storage part)
- `shell/src/storage/*`, `shell/qml/StoragePane.qml` (`UsageRow`, `focusableRows`), `shell/PATTERNS.md` (settings rows)
- `docs/specs/04-design-system.md` §3 and §8 (existing components only; new ones allowed: none)
- Root `CLAUDE.md` security invariants: nothing auto-runs from removable media

## Scope
1. **Contract first (`Devices1.Storage`):** `ScanVolume(id) -> status` (starts a scan of one mounted removable volume; `ok` also when a fresh result is cached; `unknown-volume`, `unsupported`, `busy` when another scan runs, `failed`), `GetVolumeScan(id) -> a{sv}` (`state` `idle|running|done|cancelled`, `partial` b, `used_bytes` x, `categories` aa{sv} of `key` s, `bytes` x, `files` x, and `other_bytes` x), `CancelScan(id)`, signal `VolumeScanChanged(id)`. Extend or reshape if the pattern of `GetSystemUsage` asks for it (drafts until release); write the XML first, then the Rust service, the mock and the D-Bus client.
2. **The category table is data, in one place** (`services/ruya-devices/src/drive_scan.rs`, and one table in `03`), each row = category key, folder convention, file match. Start with: `games` = `RuyaOS/ROMs/` (T-303 may rename it, change the table not the code), `backups` = `RuyaOS-Backups/` (T-215), `captures` = `RuyaOS/Captures/` (T-305), `packages` = `*.play` files anywhere in the top two levels (T-236), `pictures` = `Wallpapers/`, `Pictures/` (T-208 reads images from any drive), `reports` = `RuyaOS-system-report.*` (T-226). Anything else on the drive is `other_bytes`. A category the task cannot name a folder for yet stays out of the table; adding a row later must need no other change.
3. **The scan (pure core, `drive_scan.rs`)** over a `ScanSource` trait that offers only `list(dir)` and `stat(path)`: no `open`, no `read`, no `exec` exist in the trait, so content cannot be read by construction. Bounds: depth 6, 200 000 entries, 10 s wall clock (fake clock in tests); counts allocated blocks like `sysusage.rs`; never follows a symlink, never enters another mount, skips names it cannot represent; a directory it cannot read, a bound that was hit or a cancel makes `partial` true (numbers shown with "at least"). Runs on the blocking pool, one scan at a time, result cached until the volume changes (`VolumesChanged`) or the volume is unplugged; `CancelScan` stops within one directory.
4. **Shell:** `Storage` facade gets `scan(volumeId)` data (map per volume, `valid` false until the first reply, late replies dropped with `RequestSequence`), the D-Bus backend and the mock follow the contract; the mock stick has a believable breakdown (games 12 GB, backups 2 GB, captures, other) and a `partial` variant.
5. **Pane:** under each mounted removable volume, rows in the style of the "This console" section: a "Scanning..." row while running, then one row per found category (name, size) and "Other". A volume with nothing recognised shows one line "Nothing from RuyaOS on this drive". The scan starts for the focused or first mounted removable volume when the pane is shown and is cancelled when the pane hides or the drive is ejected; numbers update rows in place without moving focus. Strings via `qsTr()`, Turkish translated. Eject keeps working during a scan (the scan is cancelled first).
6. **Docs:** `03` §2.2 (the table, the bounds, "read-only: names and sizes"), the XML header, `dev-setup.md` (what the devices check prints).

## Out of scope
- Formatting (T-332, T-333), deleting or moving anything on the drive, a file browser (T-256), hashing or opening files, scanning internal disks or unmounted volumes, per-profile data.

## Acceptance criteria
- [ ] Rust tests (`drive_scan.rs`, fake source): each table row maps its folder and match to its key; the rest is `other_bytes` and the parts add up to `used_bytes`; the depth bound, the entry bound and the clock bound each give `partial` (revert: remove the bound, the test goes red); a symlink and a directory on another mount are not followed; an unreadable directory gives `partial`, not an error; `CancelScan` stops a walk in progress; a hostile name (control characters, bidi override, 4 000 characters) never fails the call and is not echoed unfiltered; the result is cached and dropped on `VolumesChanged`.
- [ ] A test that the trait has no way to read content: a fake source that panics on any method except `list`/`stat` is enough.
- [ ] `tst_storage.qml::test_removable_breakdown` (categories and sizes from the mock, "Other", the partial wording, the empty line), `::test_scan_cancelled_when_pane_hides`, `::test_late_scan_reply_is_dropped`, focus stays on its row while numbers change.
- [ ] D-Bus client path: the call, the signal and the status mapping agree with the XML (`tst_storage.qml` with the mock plus the existing client tests pattern).
- [ ] Screenshots (`dev.ps1 shots`): the Storage pane with a stick (English and Turkish), read against `04` §8.
- [ ] UI tasks - UX: from every new state Back leaves; focus lands sensibly after open/close/error; readable at 10 ft; Outcome has a `UX notes:` line
- [ ] VM (lead run): `scripts/vm-storage-check.sh` gets a `scan` step after `plugged`: it creates `RuyaOS/ROMs/snes/a.bin` (3 MiB), `RuyaOS-Backups/p/b.tar.zst`, a stray 1 MiB file, an executable `run.sh` that would `touch /tmp/scan-ran`, then compares `GetVolumeScan` with `du` (within 5 %), asserts `/tmp/scan-ran` does not exist, and that a scan of a 10-level deep tree ends `partial`. Outcome `Verified: host (vm pending: vm-storage-check.sh scan)`.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `api/dbus/org.ruyaos.Devices1.xml`, `docs/specs/03-services-and-apps.md` (§2.2), `docs/specs/02-shell.md` (Storage pane), `docs/dev-setup.md`.

## Hints
- Copy `sysusage.rs` for the shape (pure core, trait source, fake clock, one walk at a time, never block the D-Bus executor: T-192 lesson).
- exFAT and FAT mounts are owned by `ruya-shell` (udisks passes the caller's uid), so the walk can read them; an ext4 stick made elsewhere may have directories `ruya-shell` cannot read: that is the `partial` case.
- T-332 and T-333 touch the same files (`storage.rs`, `dbus.rs`, `Devices1.xml`, `StoragePane.qml`): do not run them in parallel with this task. T-333 uses this scan for its "what you will lose" line.

## Outcome
_Filled in by the implementer._
