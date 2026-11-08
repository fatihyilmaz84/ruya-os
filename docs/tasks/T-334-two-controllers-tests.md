# T-334 - Two controllers at once: tests that prove the second pad does not disturb the first

Status: in-progress · Phase: 2 · Depends: — · Area: services (ruya-devices tests), shell (tests, mock), scripts · Size: M · Owner: builder

## Goal
Owner report (2026-11-08): "the second DualSense overrides the first". A read-only investigation of the Dell (image 0.0.53) found no override in the code: both pads were paired, bonded and trusted, `ListDevices` returned two entries with different ids, and the first pad never left (the second dropped 21 s after it connected: T-338). Every existing fixture holds one pad, so nothing stops a later change from breaking two. This task adds the missing two-pad tests; it changes no product code unless a test finds a defect (then fix it and say so in the Outcome).

## Read first
- `docs/LEAD-NOTES.md` "Owner report the second DualSense overrides the first" (the finding, with the code places)
- `services/ruya-devices/src/bluetooth.rs`: `FakeBluez` (`with_devices`, calls log, hooks), the `window_bt()`/`open()`/`near()` helpers (line ~2092) and the window tests (`a_gamepad_that_pairs_with_us_is_accepted_trusted_and_ends_the_window`, `what_was_paired_before_the_window_is_not_a_stranger`, `a_phone_that_bonds_anyway_is_removed_again`), `an_idle_report_disconnects_only_connected_controllers_once`; `idle_pads.rs` (`each_connected_pad_is_counted_from_its_own_connection` is the pure policy test)
- `shell/tests/tst_bluetooth.qml`, `tst_controller_onboarding.qml` (`ControllerToasts`), `shell/src/bluetooth/MockBluetoothBackend.*` (`mockPopulate`, `mockGamepad`, `mockPairingScript`)
- `scripts/vm-devices-check.sh` `bluetooth_fake_check` (the `ruya-devices --session` pattern with FakeBluez on ruya-shell's user bus)
- Related epic: `T-263`..`T-268` (registry and player slots) will build on these fixtures; this task is the safety net, not the registry

## Scope
1. **Rust (`bluetooth.rs` tests, FakeBluez):** a fixture `two_pads()` (pad A paired, bonded, trusted, connected; pad B near, in pairing mode; **identical alias and modalias**, different addresses). Tests: window opened with A connected, B pairs: no `remove` call at all, A still connected and paired, B ends the window `paired`, `list()` has two entries with different ids; a manual `pair(B)` with A connected leaves A alone; `forget(B)` removes only B; `connect(B)` and `disconnect(B)` touch only B (the calls log names the address); a stranger sweep never removes A or B (both in or out of `paired_before`); the idle policy with two connected pads: only the pad past its own timeout is disconnected, once, and the pad that connected 21 s ago is not.
2. **QML (`tst_bluetooth.qml`, `tst_controller_onboarding.qml`):** two paired mock controllers with the same name show two rows in `BluetoothPane` (distinct accessible names, e.g. "Wireless Controller, connected" and "...(2)" or the address tail: decide, the rows must be told apart), forgetting one leaves the other's row and focus sensible; `ControllerToasts` shows two toasts for two connects; a disconnect toast names the right pad; the status cluster battery chips (T-223) list both.
3. **VM check (`scripts/vm-devices-check.sh`):** extend the `--session` FakeBluez fixture with a second pad of the same name and a step that opens the pairing window and pairs it; assert `ListDevices` has both addresses, both `paired` and `bonded`, and that the first is still `connected`.
4. **Fix only what a test proves broken**, with the failing test first.

## Out of scope
- Player slots and who-is-playing (T-264, T-265), real hardware (T-338), two adapters (T-336), logging (T-335), `ruya-inputd` (T-337).

## Acceptance criteria
- [ ] The Rust tests above exist by these names: `two_pads_a_second_pairing_never_removes_the_first`, `two_pads_with_identical_alias_and_modalias_have_two_ids`, `manual_pair_of_a_second_pad_leaves_the_first`, `forget_removes_only_the_chosen_pad`, `connect_and_disconnect_touch_only_their_pad`, `the_sweep_spares_both_pads`, `idle_policy_counts_each_pad_from_its_own_connection_through_the_service`. Revert check: making `remove_stranger` ignore `paired_before` turns the sweep tests red.
- [ ] QML tests: `test_two_controllers_same_name_two_rows`, `test_forget_one_keeps_the_other_row`, `test_two_connect_toasts`, `test_disconnect_toast_names_its_pad`, `test_battery_chips_for_two_pads`.
- [ ] VM (lead run): `vm-devices-check.sh bluetooth_fake_check` (or a new `twopads` step) PASSes with two pads. Outcome `Verified: host (vm pending: vm-devices-check.sh twopads)`.
- [ ] UI (rows told apart): UX: from every new state Back leaves; focus lands sensibly after open/close/error; readable at 10 ft; Outcome has a `UX notes:` line (only if a screen changed).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN. No test was weakened.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/dev-setup.md` (what the devices check prints), `shell/PATTERNS.md` only if a mock helper is added.

## Hints
- Do not rename existing fakes' addresses: other tests use `AA:00:00:00:00:01..03`; use `AA:00:00:00:00:04`/`05` for the new pads.
- Start by writing the tests against the current code; if they all pass, say so in the Outcome: that is the result (no override in the code), and T-338 looks at the hardware.
- T-336 (second adapter) and T-337 (inputd) need their own fakes; do not fold them in.

## Outcome
_Filled in by the implementer._
