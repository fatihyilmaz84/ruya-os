# T-289 — System information follow-ups: Bluetooth address from BlueZ, image from a root source, one info row, report scrub, drive chooser

Status: todo · Phase: 2 · Depends: — · Area: services (ruya-sysinfo, ruya-devices), api, shell (info rows, drive chooser) · Size: M · Owner: builder

## Goal
Settings > System information is correct on a real image (image name and digest present, the Bluetooth address read from BlueZ), the report never leaks an address in UPower's form, the two duplicated info-row components become one, and a console with two USB sticks asks which one to use.

## Read first
- `docs/specs/03-services-and-apps.md` (System information), `04-design-system.md` §8 (one shared component)
- `services/ruya-sysinfo/src/net.rs` (`parse_bluetoothctl_address`, ~line 56), `services/ruya-devices/src/sysinfo.rs`, `report.rs` (the scrub), `bluez.rs`, `services/ruya-update` (how it reads `bootc status`)
- `shell/qml/SystemInfoPage.qml`, `SystemInfoRows.qml`, `StoragePane.qml`, `AboutPane.qml` (`UsageRow`, `InfoRow`)
- T-226 Outcome; STATUS-parked.md "Inbox triage 2026-11-07", bullets T-289

## Scope
1. **Bluetooth address:** read `Adapter1.Address` from BlueZ (the `bluez.rs` client) instead of spawning `bluetoothctl show`; remove the parser and its test, keep a unit test for the new path with a fake BlueZ reply.
2. **Image and digest:** `bootc status` needs root and is absent on a real image today. Give `GetSystemInfo` a root source (reuse what `ruya-update` already reads, or a small root reader; choose the smaller and say why). The row shows the image name and a short digest.
3. **Report scrub:** the address scrub also removes UPower's `o`-separated serial form (`aa_bb_cc_dd_ee_ff` object paths and ids); table test with real-looking samples.
4. **One info row:** `UsageRow` (StoragePane) and `InfoRow` (SystemInfoRows/AboutPane) become one component (name it in 04 §5 and `shell/CMakeLists.txt`); no visual change except what unifying forces.
5. **Drive chooser:** wherever the shell picks "the" removable drive (report export, wallpaper copy, sound-theme import; grep `Storage.volumes`/first-volume use), two or more mounted drives open a chooser (a `ChoiceRow` list modal in the existing style); one drive behaves as today.

## Out of scope
- HDR/VRR rows (after T-218/T-222), capturing the Dell's data as fixtures (Dell look-at list), per-app sizes, an eject UI.

## Acceptance criteria
- [ ] Rust: Bluetooth address from a fake `Adapter1.Address`; scrub test with the `o`-separated form fails when the new rule is removed; image/digest present in `GetSystemInfo` output for a fake source.
- [ ] `tst_system_info.qml` and `tst_storage.qml` pass with the unified row; a grep for `UsageRow`/`InfoRow` in the Outcome shows one definition.
- [ ] `tst_storage.qml::test_drive_chooser_with_two_sticks` (mock with two volumes: chooser appears, Accept picks, Back cancels with no copy) and `::test_one_stick_no_chooser`.
- [ ] Screenshot of the chooser and of System information (reviewed, en).
- [ ] UX: from every new state Back leaves; focus lands on the first drive; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] VM (lead run): `scripts/vm-devices-check.sh system` shows a non-empty image and the adapter address; Outcome `Verified: host (vm pending: vm-devices-check.sh system)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- 03 (System information sources), 04 §5 (info row).

## Hints
- Reference for a root source and its fake: `services/ruya-devices/src/sysusage.rs` and the `Source` trait in `ruya-sysinfo/src/source.rs`.
- Overlaps T-288 (`SystemInfoRows.qml`, `SystemInfoPage.qml`): run after T-288.

## Note (lead-8)
T-359 did half of item 1: `AdapterInfo.address` from BlueZ and the primary adapter's address in sysinfo; only the `bluetoothctl show` fallback and its parser are left.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
