# T-177 — `ruya-devices` watchers can't be starved; battery cluster and replies stay consistent

Status: in-progress · Phase: 2 · Depends: — · Area: services, shell, scripts · Size: S · Owner: builder

## Goal
A stream of D-Bus signals can't hold off a refresh indefinitely: busy Wi-Fi, a PipeWire burst or a room full of BLE devices. The battery in the status cluster always agrees with the low-battery toast. A host session catches compile errors in Linux-only service code before the image build does.

## Read first
- `services/ruya-devices/src/dbus.rs` (`watch_batteries` ~:353, `watch_network` ~:459, and `watch_bluetooth` with `DEBOUNCE_MAX`, T-173: the pattern to copy), `services/CLAUDE.md`
- `shell/src/battery/Batteries.cpp` (`lowest`, `lowestState`), `shell/src/battery/DBusBatteryBackend.cpp` (async `ListBatteries`), `shell/tests/tst_battery.qml`
- `scripts/dev.ps1` (the `rust` step: clippy for the Linux target), `docs/dev-setup.md`

## Scope
1. **Debounce cap:** `watch_batteries` and `watch_network` debounce until 300 ms of quiet with no maximum. Give them the same 1 s maximum wait as `watch_bluetooth` (`DEBOUNCE_MAX`). Share one helper if that's simple; otherwise copy it and say so.
2. **Battery cluster:** on a tie, or when the lowest pad is charging, the cluster shows the discharging pad's level and state, so the warning colour matches the toast. (Example: A 10 % charging, B 12 % discharging → show B.)
3. **Stale replies:** `DBusBatteryBackend` drops a `ListBatteries` reply older than one already applied (sequence counter). If the sibling backends (network, bluetooth, storage, audio) use the same async pattern, do the same there or add one Inbox line naming them.
4. **Linux compile check:** check how `dev.ps1 rust`'s Linux clippy treats Linux-only modules (`bluez.rs`, `upower.rs`, `networkmanager.rs`, `pipewire.rs`). If they aren't type-checked on the host, make the step check them. If they need the Linux sysroot, run `cargo check` for `ruya-devices` in WSL instead, with a clear message when WSL is missing. Don't add a step that only passes on this machine.

## Out of scope
- New D-Bus API; the hardware checks (B-002).

## Acceptance criteria
- [ ] A Rust test drives the debounce helper with a fake clock and a signal every 100 ms: it fires within 1 s (fails with an uncapped debounce).
- [ ] `tst_battery.qml`: A 10 % charging + B 12 % discharging → the cluster shows 12 % in the warning state; equal levels prefer the discharging pad.
- [ ] A backend test (or a QML test through the mock's delay hook) where an older reply arrives after a newer one leaves the newer data shown.
- [ ] A deliberate type error in `bluez.rs` fails `dev.ps1 rust` (or the WSL check) on this host; the Outcome shows the failing run, then the fix reverted.
- [ ] VM (lead run): `scripts/vm-devices-check.sh check` still passes (Outcome: `Verified: host (vm pending: vm-devices-check.sh check)`).
- [ ] `dev.ps1 test` ALL GREEN.

## Docs to update
- `docs/dev-setup.md` if the `rust` step changes; `03` §2 (debounce rule) if it describes the watchers.

## Outcome
Verified: host (vm pending: vm-devices-check.sh check)

Built:
- `services/ruya-devices/src/debounce.rs` (new, platform independent): `Debounce` (pure rule: quiet 300 ms, maximum 1 s, optional nearer limit) and `settle()` (the async wait). `watch_network`, `watch_batteries` and `watch_bluetooth` all use it (one helper, no copy); the BlueZ watcher passes the scan deadline as the limit as before. Tests: a signal every 100 ms on a fake clock fires within 1 s; a quiet bus fires after the quiet time; a nearer limit wins; `settle` returns on a never-quiet real stream. Revert test: with `MAX_WAIT` set to 3600 s the first test fails ("fired after 1000.3s"). (My first draft compared against `MAX_WAIT` itself and passed uncapped; fixed to the literal 1 s.)
- `Batteries::apply`: the cluster's `lowest`/`lowestState` come from the lowest pad, or, if that is not discharging, the lowest discharging pad (A 10 % charging + B 12 % discharging -> 12 %, warning; ties prefer discharging, whichever order). Tests in `tst_battery.qml`: `test_a_charging_lowest_pad_shows_the_discharging_one` (also checks the toast agrees), `test_equal_levels_prefer_the_discharging_pad`. Not revert-run (the old code would show 10 % / `charging`).
- Stale replies: `BatteryBackend` numbers requests (`beginRequest`) and `deliver()` drops a reply not newer than the last one shown; `DBusBatteryBackend` uses it. The mock goes through the same code with a reply delay (`Batteries.mockRefreshDelayed`, `mockPendingReplies`). Test `test_an_older_reply_arriving_late_is_dropped`; revert test: with the guard disabled it fails ("the late 60 % reply was dropped").
- Scope 4: no change needed. `dev.ps1 rust`'s "clippy (Linux target)" step runs `cargo clippy --target x86_64-unknown-linux-gnu`, which compiles the `#[cfg(target_os = "linux")]` modules (bluez.rs, upower.rs) on this host. Proof: appending `fn _deliberate() { let _x: u32 = "text"; }` to `bluez.rs` made `dev.ps1 rust` end `FAILED: cargo fmt --check, clippy linux` with `error[E0308]: mismatched types ... bluez.rs:273` while Windows clippy passed; the line was then removed.

Files: services/ruya-devices/src/{debounce.rs,lib.rs,dbus.rs}, shell/src/battery/{Batteries.h,Batteries.cpp,BatteryBackend.h,DBusBatteryBackend.cpp,MockBatteryBackend.h,MockBatteryBackend.cpp}, shell/tests/tst_battery.qml, docs/specs/03-services-and-apps.md. No new QML/C++ file in the shell, so CMakeLists is unchanged; `dev.ps1` and `dev-setup.md` unchanged.

Deviations: none. Sibling backends (network, bluetooth, storage, audio) use the same unguarded async pattern: Inbox line in the HANDOFF.
