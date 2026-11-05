# T-184 — USB stick with several partitions: one notification; PipeWire watcher debounce

Status: todo · Phase: 2 · Depends: — · Area: services, shell · Size: S · Owner: builder

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
- [ ] VM (lead run): `vm-storage-check.sh` two-partition and unsupported cases. Outcome: `Verified: host (vm pending: vm-storage-check)`.
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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
