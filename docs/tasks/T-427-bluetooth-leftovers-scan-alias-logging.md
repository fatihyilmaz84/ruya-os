# T-427 - Bluetooth leftovers: scan after a primary flip, toast names, logging, address tails

Status: todo · Phase: 2 · Depends: — · Area: services (ruya-devices bluetooth), shell (Bluetooth pane, DeviceIcons) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
The small Bluetooth defects found in the T-359 reviews are gone: a scan stops when it should, a low-battery toast names the pad the player knows, the logs go through one logger, and an address tail is never cut off.

## Read first
- `docs/tasks/T-359-bluetooth-follow-ups-adapters-names.md` (Outcome, review notes), `docs/specs/03-services.md` (Bluetooth), `docs/specs/04-design-system.md` §3 (copy), `shell/qml/TailText.qml`
- `services/ruya-devices/src/bluetooth*` (`stop_scan`, `tick`, `dbus.rs`), `shell/qml/DeviceIcons.qml`, the Bluetooth pane, `docs/tasks/T-289-system-information-follow-ups.md` item 1

## Scope
1. A user scan running on a non-window adapter is stopped when the primary adapter flips (`stop_scan`/`tick`); test in Rust.
2. The low-battery toast names a pad by its paired alias (fallback: the device name), not its UPower id; test.
3. `dbus.rs` `eprintln!` lines go through `log::info`/`log::warn`.
4. `SettingRow` labels that show an address use `TailText`, so the tail is kept (test: elided label keeps the last 5 characters).
5. A translator comment on `qsTr("%1 (%2)")` in `DeviceIcons.shownParts` (the name must stay first).
6. "Primary adapter off, another on" names the adapter that is off (copy in 04 style; test).
7. T-289 item 1: drop the `bluetoothctl` fallback if the primary address is now read over the bus everywhere, else say why it stays.

## Out of scope
- New Bluetooth features, pairing flow changes.

## Acceptance criteria
- [ ] Items 1, 2, 4 and 6 each have a test red without the change (named in the Outcome).
- [ ] UI tasks - UX: Back leaves every touched state; Outcome has a `UX notes:` line.
- [ ] VM (lead run): `scripts/vm-devices-check.sh bluetooth` still PASS (Outcome: `Verified: host (vm pending: devices bluetooth)`).
- [ ] `dev.ps1 test` ALL GREEN; `shots` of the Bluetooth pane reviewed.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/03-services.md` if the scan or toast behaviour is described there; T-289 item 1 note.

## Hints
- From the STATUS Inbox (T-359 reviews, lead-8), triaged by lead-9 on 2026-11-10.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
