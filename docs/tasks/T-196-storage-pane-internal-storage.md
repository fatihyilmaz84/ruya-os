# T-196 — Settings → Storage shows the console's own storage

Status: todo · Phase: 2 · Depends: — · Area: api, services, shell · Size: M · Owner: builder

## Goal
Settings → Storage shows the internal storage first (how much is free, and how much the apps and games take), then the removable drives as today. Owner, 2026-11-06, after the first run on real hardware: with no USB stick the pane showed nothing, and a console needs to know how full it is. Today's pane skips every internal disk on purpose (T-174: the OS is not a "drive").

## Read first
- `docs/specs/03-services-and-apps.md` §3 storage paragraphs ("As built, service side (T-174)", "One toast per drive (T-184)") and the line "Settings → Storage shows usage per app"
- `api/dbus/org.ruyaos.Devices1.xml` interface `Devices1.Storage` (header status strings at the top)
- `services/ruya-devices/src/storage.rs`, `udisks.rs`, `dbus.rs` (the Storage part)
- `shell/src/storage/*` (Storage facade, backends), `shell/qml/StoragePane.qml`
- `docs/specs/04-design-system.md` §3 and §8 (existing components only; a new one needs the spec update in the same commit)
- `shell/PATTERNS.md` (settings rows), `shell/CLAUDE.md`

## Scope
1. **Contract first (`Devices1.Storage`):** add a method `GetSystemUsage() -> a{sv}` and a signal `SystemUsageChanged`. Keys: `total_bytes` x and `free_bytes` x (the filesystem that holds `/var`, where apps, games and profile data live), `apps_bytes` x (the system Flatpak installation, `/var/lib/flatpak`), `data_bytes` x (profile homes, `/var/home`), `system_bytes` x (the rest of what is used: `total - free - apps - data`, never negative). Unknown parts are `-1`. Document it in the XML header; the existing `ListVolumes` stays as it is (the OS is still not a volume).
2. **Service (`ruya-devices`):** a pure core for the numbers (unit-tested with a fake filesystem source) and a Linux source: `statvfs` for total/free (cheap), directory sizes for `apps_bytes` and `data_bytes` computed **on the blocking pool, cached** (for example 60 s) and recomputed after a change signal from the Store (`InstalledChanged`) or on request when the cache is older than that. It must never block the D-Bus executor (T-192 lesson) and never follow symlinks out of the tree. No new privilege: read-only, the unit's hardening stays (check `systemd-analyze --user security ruya-devices` before/after). A prefer-std solution; a new crate needs a one-line justification.
3. **Shell:** `Storage` facade gets `internal` (a map with the five numbers, `valid` false until the first reply); the D-Bus backend and the mock follow the contract; the guard against late replies applies (`RequestSequence`, T-191). The mock has a believable internal disk (for example 464 GB, 450 GB free) and a low-space variant for the screenshot.
4. **Pane:** a first section "This console": one row with the free space ("450 GB free of 464 GB") and a usage bar, then rows for "Apps and games", "Profile data" and "System" with sizes (use the existing row/progress components; text uses `qsTr`, Turkish translated). Below it, the existing removable-drive rows unchanged. With less than 10 % free the bar uses the warning colour token (no new tokens). Focus order: the section's rows are focusable like the others, eject rows keep their behaviour and focus stays on a row when numbers update.
5. **Docs:** the XML, `03` (the Storage "As built" paragraphs: internal usage; the "OS is not listed as a volume" rule stays), `04` §8 if a component is used in a new way, `dev-setup.md` (what the devices check prints).

## Out of scope
- Per-app sizes and uninstall/clear-data from this pane (the Store has them; a later task), a low-space toast, blocking an install when the disk is full, formatting or partitioning, other internal disks (the second data disk case: list it as a volume only if it is mounted outside the system paths, as today).

## Acceptance criteria
- [ ] Rust tests: the core maps a fake `statvfs` and fake directory sizes to the five keys (`system_bytes` is the remainder and never negative, unknown parts are -1); a failing directory walk does not fail the call; the cache is reused within its time and recomputed after a change signal (fake clock).
- [ ] `tst_storage.qml`: with the mock, `Storage.internal` has the numbers, the pane shows the "This console" section with free/total text and the bar value, updating `internal` updates the rows in place and focus stays; the low-space mock turns the bar to the warning colour token (assert the token, not pixels); the removable rows are unchanged (existing tests untouched and green).
- [ ] The D-Bus client path: a late `GetSystemUsage` reply is dropped (like the other facades).
- [ ] Screenshots (`dev.ps1 shots`): the Storage pane with the internal section and a stick, and the low-space variant, read against `04` §8 and the criteria; English and, if the tests have it, Turkish.
- [ ] VM (lead run): `scripts/vm-devices-check.sh` storage part compares `GetSystemUsage` `total_bytes`/`free_bytes` with `stat -f /var` (within 1 %) and `apps_bytes` after installing the test app grows; Outcome `Verified: host (vm pending: vm-devices-check.sh)`. Hardware: the Dell shows its ~450 GB (lead check).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `api/dbus/org.ruyaos.Devices1.xml`, `docs/specs/03-services-and-apps.md`, `docs/dev-setup.md`, `04-design-system.md` §8 only if a component changes.

## Hints
- Mirror T-174 and T-173 for the Rust layout (pure core, trait for the OS, Linux implementation, thin `dbus.rs`), and `Network`/`Batteries` for how a facade holds one map.
- Directory sizes: count allocated blocks (`st_blocks * 512`), not apparent size, and do not cross into other mounts. `/var/home` can be large and holds profile data other users own: the service runs as `ruya-shell` (a user unit), so a profile's private files may not be readable; sum what is readable and say so in the XML (profile data is then a lower bound), or ask `ruya-profiles` for the per-profile numbers if that is cleaner. Pick one and record why in the Outcome.
- The Dell test machine has a 464 GB `/var` (grown by hand on 2026-11-06); the ISO's 70 GiB cap is a separate Inbox item.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
