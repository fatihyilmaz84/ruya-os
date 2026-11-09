# T-359 - Bluetooth follow-ups: late adapters, scan ownership, telling like pads apart

Status: todo · Phase: 2 · Depends: — · Area: api, services (ruya-devices bluetooth, pairing, battery), shell (Bluetooth pane, onboarding, battery chips) · Size: M · Owner: builder · Developer surface: internal

## Goal
Bluetooth behaves on consoles with more than one adapter or a late adapter, and two identical pads can be told apart everywhere the shell names them.

## Read first
- `docs/specs/03-services-and-apps.md` (Bluetooth), `api/dbus/` Devices XML (Bluetooth and battery methods), `services/CLAUDE.md`
- `services/ruya-devices/src/bluetooth.rs`, `pairing.rs`, `battery.rs`, `upower.rs`, `sysinfo.rs`, `dbus.rs`
- `shell/qml` Bluetooth pane, `ControllerOnboarding`, the battery cluster; `shell/src` device icons (`DeviceIcons.addressTail`)
- T-300, T-334, T-335, T-336 Outcomes (only their follow-up lists)

## Scope
1. **Late adapter:** an adapter that appears after the service started gets the same secure Pairable/Discoverable setup as one present at start.
2. **Scan ownership:** when a user scan on another adapter took over (primary flip between StartScan and the pairing window), the window's own scan is stopped on the window's adapter. StartScan/Pair answer `unavailable` when the primary is off but another adapter is on.
3. **One primary:** sysinfo uses `bluetooth::primary_index`/`Raw::primary()` instead of its own pick.
4. **Like pads apart:** `ListBatteries` carries the Bluetooth address (contract first: XML, service, mock, client) so battery chips and "More devices" use the paired name plus the `addressTail` tie-break, like the Bluetooth pane; "Found nearby" in onboarding shows the tail for like-named pads; the rename keyboard is titled with the shown name, not "Controller name".
5. **Journal hygiene:** aliases in journal labels also lose `"` and Unicode format characters (reuse `pairing::is_format_char`); radio changes we did not cause (rfkill, `Powered` changing) and the pairable state after a BlueZ restart are logged with `log::info`; the remaining `eprintln!` failure lines go through `log::info`.
6. The missing `BatteriesChanged` test of T-300.

## Out of scope
- An "Identify" action (rumble/light bar), what to do with a stranger that pairs after the window (own decision), T-264's registry, InputPlumber (B-006).

## Acceptance criteria
- [ ] Rust tests: `a_late_adapter_gets_the_secure_pairable_setup`, `the_window_scan_stops_on_its_own_adapter_after_a_primary_flip`, `start_scan_is_unavailable_when_only_a_non_primary_adapter_is_on`, `sysinfo_reports_the_primary_adapter`, `journal_label_strips_quotes_and_format_chars`, `batteries_changed_is_emitted_on_a_level_change` (each red when its behaviour is removed).
- [ ] `ListBatteries` returns the address; XML, service, mock and client agree (Rust and QML tests).
- [ ] QML tests: two like-named pads show different labels in the battery chips, "More devices" and "Found nearby"; the rename keyboard title is the shown name.
- [ ] UX: Back leaves every touched state; screenshots of the battery chips and Found nearby with two like pads, reviewed; `UX notes:` line.
- [ ] VM (lead run): `vm-devices-check.sh bluetooth` still passes; Outcome `Verified: host (vm pending: vm-devices-check.sh bluetooth)`.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `03` Bluetooth (late adapters, scan ownership, battery address), `02` if labels changed.

## Hints
- Inbox lines (T-336, T-335, T-334 reviews) are verbatim in `STATUS-parked.md`, "Inbox triage 2026-11-09 (lead-7)".

## Outcome
_Filled in by the implementer._
