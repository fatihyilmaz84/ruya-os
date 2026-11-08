# T-335 - ruya-devices logs what it does to Bluetooth devices, so the next report is diagnosable

Status: done · Phase: 2 · Depends: — · Area: services (ruya-devices) · Size: S · Owner: builder

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
Verified: host + vm (image 0.0.56, lead-5 2026-11-08: vm-devices-check.sh bluetooth: 23 PASS incl. the journal lines of the two-adapter run). hw (Dell) still to check: the journal on the Dell.

Built. `services/ruya-devices/src/log.rs`: `info(line)` writes `ruya-devices: <line>` to stderr and, under `cfg(test)`, to a thread-local buffer (`log::take()`); `clean()` turns control characters of a remote device's name into `?`. `bluetooth.rs` logs through small helpers that sit where the action is decided and take the reason: `connect_device(address, timeout, reason)`, `disconnect_device(address, reason)`, `remove_device(address, reason)`, `trust(address)`, `set_pairable(adapter, on, why)`, `label(address)` (`AA:.. "Alias" (hci0)`, so every line names the adapter, T-336). The lines and their wording are in 03 §2.1 ("What the journal says").

Link drops: `read()` compares the devices of two reads and logs `connected|disconnected <device>: link` for a change no request of ours explains. A request is remembered (`State::intents`, address to the state asked for) before the call is made and forgotten when the call fails or the change is seen, so a signal that arrives while `Connect` is still running is not called `link`. Devices in only one of the reads (first read, radio off and on) say nothing.

Tests (`bluetooth.rs`, the eight named plus `a_pairing_that_ends_after_its_window_says_so`, and two in `log.rs`): all pass. Revert checks (each mutation applied by `output/mutate.py` with a rebuild, the named test went red, source restored): removal line without its reason -> `a_removal_logs_its_reason_sweep_and_forget`; `"stopped"` outcome renamed -> `window_open_and_close_are_logged_with_the_outcome`; `via manual` changed to `via window` -> `a_pairing_in_the_window_logs_its_path`; the own-request filter of `link_changes` removed -> `a_drop_we_did_not_cause_logs_link`; the same-state skip of `link_changes` removed (logs every device on every read) -> `an_unchanged_world_logs_nothing`; `idle-timeout` reason renamed -> `idle_disconnect_logs_once_per_pad`; user connect reason changed -> `connect_and_disconnect_log_who_asked`; the PIN line made to format the call -> `no_log_line_contains_a_pin_or_passkey`.

VM (lead run): `scripts/vm-devices-check.sh bluetooth`, the two-adapter step, now keeps the `--session` instance's stderr, also calls `StartControllerPairing`/`StopControllerPairing`, and greps for the window opened/closed lines (hci1, the primary one), the `connect ... (hci1): user` and the `remove ... (hci1): forget` lines. Not run here.

Deviations / readings of the task:
- `rejected <addr>` is not a window outcome in the code (the window stays open when it refuses a device, `ControllerPairingState` has no such state), so it is its own line `refused <device>: not an input device` next to the `remove ... sweep|agent-refused` line; the window's closing line says `paired <device>`, `timeout` or `stopped`.
- `late-pair` removal does not exist: a pairing that completes after its window ended is left bonded and untrusted (T-203 test `a_pairing_that_completes_after_the_window_ended_is_not_trusted`). Task says not to change behaviour, so the line says `paired <device> via window after the window ended: left untrusted`. Inbox line below.
- The idle decision is one line with the reason inside it (`disconnect <device>: idle-timeout (idle 35 min >= 15 min)`), not a decision line plus a request line.
- Existing failure `eprintln!`s of the Bluetooth core that could be replaced by the new helpers were (removal, trust, connect); the rest (Pairable, scan, agent registration) are as before.
- `adapters powered on|off (user)` is written only for the user's `Powered` call; a power change seen in a refresh that we did not cause is not logged (not asked for). Inbox.

Unverified: the real journal (identifier `ruya-devices`, `--user-unit`) on the image; the VM grep.

Files: `services/ruya-devices/src/{log.rs,lib.rs,bluetooth.rs}`, `scripts/vm-devices-check.sh`, `docs/specs/03-services-and-apps.md`, `docs/dev-setup.md`, this file.
