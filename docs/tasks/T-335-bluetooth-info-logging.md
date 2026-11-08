# T-335 - ruya-devices logs what it does to Bluetooth devices, so the next report is diagnosable

Status: in-progress · Phase: 2 · Depends: — · Area: services (ruya-devices) · Size: S · Owner: builder

## Goal
Today `ruya-devices` writes a line only when something fails, so "my second controller vanished" could not be explained from the journal (T-334 and T-338 had to guess). After this task the journal tells, for every pairing window, pairing, removal, connect, disconnect and idle disconnect, what happened to which device and why, without secrets.

## Read first
- `services/ruya-devices/src/bluetooth.rs` (`open_window`, `close_window`, `finish`, `remove_stranger`, `report_idle`, `pair_one`, `refresh`/`read`), `bluez.rs`, `dbus.rs` (where the Bluetooth watcher turns `PropertiesChanged` into `refresh`); the existing lines look like `eprintln!("ruya-devices: removing {address} failed: ...")`
- `services/CLAUDE.md` (logging rules if any), root `CLAUDE.md` security invariants (no secrets)

## Scope
1. One small logging helper in `ruya-devices` (a function `info(line)` that writes `ruya-devices: <line>` to stderr, which the journal collects, and, under `cfg(test)`, also pushes to a thread-local buffer a test can read). No new crate.
2. INFO lines (one each, short, address + alias): pairing window opened (length) and closed (outcome: `paired <addr>`, `timeout`, `stopped`, `rejected <addr>`); a device paired and by which path (`window`, `manual`); trusted; removed with the **reason** (`forget` by the user, `sweep` of a stranger in the window, `agent-refused`, `late-pair`); connect and disconnect requested by us with the reason (`user`, `idle-timeout`, `window`); a connect/disconnect **seen** in a refresh that we did not cause (`link`: the device or the radio dropped it); adapter powered/pairable changes by us; the idle report decision (`idle 35 min >= 15 min: disconnecting <addr>`) once per pad.
3. Rate: transition-based, never per refresh and never while nothing changes (a test that 100 refreshes of an unchanged world write nothing).
4. Never log a PIN, passkey, link key or the contents of an agent call; addresses and aliases are fine (the journal stays on the console; telemetry never includes it, T-224).

## Out of scope
- A log viewer, a log setting, `ruya-inputd` logs (T-337), changing behaviour, the `btmon` capture (T-338).

## Acceptance criteria
- [ ] Rust tests (`bluetooth.rs` with the test buffer): `window_open_and_close_are_logged_with_the_outcome`, `a_pairing_in_the_window_logs_its_path`, `a_removal_logs_its_reason_sweep_and_forget`, `connect_and_disconnect_log_who_asked`, `a_drop_we_did_not_cause_logs_link`, `idle_disconnect_logs_once_per_pad`, `an_unchanged_world_logs_nothing`, `no_log_line_contains_a_pin_or_passkey` (feed an agent call with a passkey; scan every line). Revert check: deleting the reason from the removal line turns the second test red.
- [ ] VM (lead run): `scripts/vm-devices-check.sh` bluetooth step greps `journalctl -u ruya-devices` (user unit: `journalctl --user-unit` as ruya-shell, or `-t ruya-devices`) for the window and pairing lines of the FakeBluez run. Outcome `Verified: host (vm pending: vm-devices-check.sh bluetooth)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/03-services-and-apps.md` (Bluetooth: "what the journal says"), `docs/dev-setup.md` (the `journalctl` line to read pad history).

## Hints
- Put the reason where the action is decided (`remove_stranger(address, reason)`), not in a wrapper, or the reason is guessed afterwards.
- T-338 uses these lines on the Dell; T-336 (adapters) adds the adapter name to each line when it lands.

## Outcome
_Filled in by the implementer._
