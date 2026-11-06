# T-184 — USB stick with several partitions: one notification; PipeWire watcher debounce

Status: done · Phase: 2 · Depends: — · Area: services, shell · Size: S · Owner: builder

## Goal
A stick with two partitions shows one "volume added" toast, not two. And the PipeWire watcher in `ruya-devices` gets the same flood protection as the other watchers.

## Read first
- `docs/tasks/T-174-devices-storage-service.md` Outcome (`VolumeAdded` per partition) and `T-177-devices-watchers-and-battery-polish.md` (`debounce.rs`, 1 s cap)
- `services/ruya-devices/src/storage*.rs`, `events.rs` (PipeWire watcher with its own 100 ms debounce), `debounce.rs`
- `api/dbus/org.ruyaos.Devices1.xml` (Storage); `shell/src/storage/`; where the shell toasts a new volume
- `scripts/vm-storage-check.sh`

## Scope
1. **Group volumes per drive:** the shell shows one toast per drive that appeared (several `VolumeAdded` within a short window, same drive), naming the drive or the first volume plus a count. Decide in the shell or in the service; if it needs a `drive` field on the volume, extend the contract (XML, service, mock, client) and say so. Unsupported-filesystem partitions don't count towards the toast but stay listed.
2. **PipeWire watcher:** use `debounce.rs` (with the 1 s cap) instead of its own 100 ms debounce, or write down in the Outcome why 100 ms is right; either way a test shows an event flood produces a bounded number of refreshes.
3. **`vm-storage-check.sh`:** add a two-partition stick and an unsupported-filesystem partition. (You write it; the lead runs it.)

## Out of scope
- Media access for profile users and Flatpak apps (the Media task), unmount/eject behaviour changes.

## Acceptance criteria
- [ ] Rust or QML test: two `VolumeAdded` for one drive give one toast; two different drives give two (fails without the grouping).
- [ ] Rust test: a burst of PipeWire events yields at most N refreshes in the window the debounce defines.
- [ ] VM (lead run): `vm-storage-check.sh` two-partition and unsupported cases. Outcome: `Verified: vm (lead, image `0.0.42-lead`, 2026-11-06): `vm-storage-check.ps1` STORAGE CHECKS PASSED (98 PASS, 0 FAIL), including the three-partition stick (one non-empty drive value for all three, exFAT mounted, ext2 listed as unknown and not mounted) and the not-the-same-drive check; `vm-devices-check.sh check` 57 PASS with the PipeWire watcher change (needs `smoke-test.ps1 -Audio`). Earlier: host`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `03-services-and-apps.md` storage section if the contract changed; `docs/dev-setup.md` if the check's use changed.

## Hints
- Don't build an image.

## Outcome
Verified: host (vm pending: vm-storage-check)

**Contract (extended, in the same commit).** `ListVolumes` dictionaries gain `drive` (s): the udisks drive object, opaque to the shell; partitions of one stick share it. `VolumeAdded` is unchanged (still one per volume, also for a partition with an unsupported filesystem). XML, `storage.rs` (`Volume.drive`, test `partitions_of_one_stick_share_the_drive_and_other_sticks_do_not`), `dbus.rs`, the mock and `DBusStorageBackend` agree.

**1. One toast per drive (shell).** Grouping is done in the shell's `Storage` singleton, not in the service: it already knows when a volume is in the list. An announced volume that reaches the list is held for 400 ms from the first one (`Storage::groupWindowMs`; a later partition of a drive in a later list still joins), then `driveAdded(drive, label, volumeCount)` is emitted once per drive. `label` is the first volume with a supported filesystem, `volumeCount` counts those; unsupported partitions (`filesystem == "unknown"`) stay in the list but are not counted, and a drive with only such partitions gives no toast. `volumeAdded(id, label)` of the facade is replaced by `driveAdded` (ToastLayer was its only user). Toast: "Drive inserted: Ruya Stick" or "Drive inserted: Ruya Stick (and 1 more)" (`%n` plural, English and Turkish entries). A partition that shows up more than 400 ms after the first is its own toast. The `RequestSequence` guard in `StorageBackend` is untouched. Mock: volumes carry a drive; `Storage.mockPlug([ids])` plugs several at once (`vol-stick-2`, `vol-stick-raw` on the stick's drive, `vol-card`, `vol-odd`); mock eject now removes every partition of the drive like the real one.
At the flush a volume that is no longer in the list is dropped and a volume announced twice counts once: a stick pulled inside the window gives no toast, one pulled and plugged in again gives "Drive inserted: Ruya Stick" without "(and 1 more)".
Tests (`shell/tests/tst_storage.qml`): `test_two_partitions_of_one_drive_give_one_toast`, `test_a_partition_that_follows_inside_the_window_joins_the_toast`, `test_two_different_drives_give_two_toasts`, `test_unsupported_partitions_are_listed_but_not_counted`, `test_a_drive_ejected_inside_the_window_gives_no_toast`, `test_a_volume_plugged_in_twice_inside_the_window_counts_once`; the existing single-stick tests moved to `driveAdded`. The "nothing more comes" checks wait `Storage.groupWindowMs + 200` ms, a real property of `Storage` (round 1 used a C++ constant QML could not see, so those waits were `wait(NaN)` and checked nothing; fixed in round 2, and a test asserts the property is positive). Revert checks, all run in round 2: grouping by volume id instead of drive failed the first two; counting unsupported partitions failed the fourth; emitting `driveAdded` for a drive with no supported volume failed the unsupported-only and the eject-inside-window tests; emitting a second `driveAdded` 150 ms after the first (a late separate toast) failed six tests through their post-wait `addedSpy.count` checks; dropping the "still listed" and "once" conditions failed the eject-inside-window and plugged-twice tests.

**2. PipeWire watcher.** `events::follow` now runs the burst through `debounce::Debounce` with the shared 1 s cap (`MAX_WAIT`); the quiet time stays 100 ms (`events::DEBOUNCE`, not the 300 ms `QUIET`): a graph read is cheap and a changed volume or output should show within a moment, so only the cap was missing (a graph that never went quiet for 100 ms was never read). The clock is injected (`now`, `Instant::now` in `dbus.rs`) so the test runs on a fake one. Test `a_flood_of_events_is_read_at_most_once_per_cap`: an event every 50 ms for 10 s gives 8-11 refreshes besides the connect and the final one (about one per second); with the cap set to 100000 s it gives 0, so it fails without the cap.

**3. `vm-storage-check.sh` / `.ps1` (not run here, the lead runs it).** New steps `mformat`, `mplugged`, `meject` after the existing `eject`: a second 96 MiB stick gets a GPT with two exFAT partitions (RUYAPART1, RUYAPART2) and one ext2 (RUYARAW, a filesystem the service does not mount). Checked: all three listed with one non-empty shared `drive` (and not the first stick's), the exFAT ones mounted `nosuid,nodev,noexec`, the ext2 one `unknown` and unmounted, exactly three `VolumeAdded` (one per partition) before `VolumesChanged`, and `Eject` of one partition removes all three. `plugged` also checks `drive` starts with `/org/freedesktop/UDisks2/drives/` and records it in `/tmp/storage-first-drive`; `mplugged` fails when the partitioned stick has that same drive path (round 1 compared against a stick that was already gone, which proved nothing). The dictionary split in the script moved from `"filesystem" s` to `"drive" s` (keys are alphabetical; `drive` is now first). `bash -n` passes; nothing ran against udisks2 here, so the exact busctl/lsblk behaviour (partition nodes, the service mounting a partition while the next one is formatted) is **unverified** until the lead run.

Not done: `shots` (the toast only gained a few words in the same 560 px toast; no layout changed). Files: see the commit.
