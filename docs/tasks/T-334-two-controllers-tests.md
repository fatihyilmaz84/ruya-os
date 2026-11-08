# T-334 - Two controllers at once: tests that prove the second pad does not disturb the first

Status: done · Phase: 2 · Depends: — · Area: services (ruya-devices tests), shell (tests, mock), scripts · Size: M · Owner: builder

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
Verified: host (vm pending: vm-devices-check.sh twopads). Review APPROVE round 1; lead fixed `shownName` for aliases containing %1/%2 in a review commit (test added).

UX notes: one screen changed, Settings -> Bluetooth & controllers (no new state, no new key). Two paired devices with the same alias now carry the end of their address ("Wireless Controller (00:04)" / "(00:05)") in the device row, its accessible name, the Rename / Forget / Pair-again rows, the Forget confirmation title and its red button, and the connected / disconnected toasts. Back from the pane, from the rename keyboard (Back deletes a letter, on an empty field it cancels) and from the confirmation leaves as before, and focus lands on the row that opened it (asserted in `test_two_controllers_same_name_two_rows`); after Forget, focus moves to the next row, or up from the last one (asserted in `test_forget_one_keeps_the_other_row`). A name nobody shares gets no suffix, so forgetting one of two pads makes the other lose it (spec 02 says so). Not doubted: the "(00:04)" form is readable but terse at 10 ft; a screenshot was not taken (no `shots` while the image build runs), the text is the existing row/toast text and only longer.

**Result: the code has no override.** All seven Rust tests were written against the unchanged product code and passed first time: a second pad (pairing in the window by itself, or calling in; manual `Pair`) never removes, disconnects or names the first, `Forget`/`Connect`/`Disconnect` make exactly one call about the chosen address, the sweep removes only the phone, and the idle rule counts each pad from its own connection. So the owner's "second DualSense overrides the first" is not in `ruya-devices` (T-338 looks at the hardware). No Rust product code changed.

**The one defect the tests found is in the shell:** two pads of one model have the same name everywhere the user acts, so the pane's rows, Rename / Forget rows, the confirmation and the toasts could not be told apart (and a "disconnected" toast could not say which pad). Decision (the task left it open): add the end of the address when, and only when, another listed device has the same alias - `DeviceIcons.shownName(list, d)` (+ `addressTail`), used by `BluetoothPane` (a new `shown` model role; `name` stays the alias, Rename pre-fills it) and by `DeviceIcons.padName` (toasts). New string `"%1 (%2)"` (en and tr).

Built:
- Rust (`bluetooth.rs`): `FakeBluez::with_two_pads()` (A `AA:00:00:00:00:04` paired/bonded/trusted/connected, B `:05` in pairing mode, same alias, `Name`, modalias); tests `two_pads_a_second_pairing_never_removes_the_first` (both the window pairing B itself and B calling in; also reads the log), `two_pads_with_identical_alias_and_modalias_have_two_ids`, `manual_pair_of_a_second_pad_leaves_the_first`, `forget_removes_only_the_chosen_pad` (both directions), `connect_and_disconnect_touch_only_their_pad`, `the_sweep_spares_both_pads` (A before the window; both before; neither before), `idle_policy_counts_each_pad_from_its_own_connection_through_the_service` (A due, B 21 s old, then B), plus `a_second_pad_paired_by_hand_in_the_window_is_bonded_and_the_first_is_left` (the VM step's sequence). `main.rs`: `RUYA_DEVICES_FAKE_BLUETOOTH=two-pads`.
- QML: `test_two_controllers_same_name_two_rows`, `test_forget_one_keeps_the_other_row` (`tst_bluetooth.qml`); `test_two_connect_toasts`, `test_disconnect_toast_names_its_pad`, `test_a_pad_alone_keeps_its_plain_name` (`tst_controller_onboarding.qml`); `test_battery_chips_for_two_pads` (`tst_battery_cluster.qml`, where the cluster tests live). Mock: `Bluetooth.mockTwoPads()` (C++ `addTwoPads`; ids are addresses, batteries 80 / 55 %).
- VM: `scripts/vm-devices-check.sh` `bluetooth_two_pads_check`, step `twopads` (also called from `bluetooth_check`).
- Docs: specs 02 and 03, `docs/dev-setup.md`. Translations refreshed.

Revert checks: Rust - dropping `&& !window.paired_before.contains(..)` from `pump`'s stranger filter turned `the_sweep_spares_both_pads`, `two_pads_a_second_pairing_never_removes_the_first` and `what_was_paired_before_the_window_is_not_a_stranger` red; making `IdlePads::decide` restart a pad's `connected_since` on every report (`insert` for `or_insert`) turned the idle test red. (The task's wording, "`remove_stranger` ignores `paired_before`", has no such code: `remove_stranger` only removes; the filter is in `pump`, so that is what I undid.) QML - `twins > 1` made unreachable in `shownName` turned 4 tests red (the two row tests and the two toast tests); `BatteryChip` finding `find(d => true)` instead of by id turned `tst_battery_cluster` red. The forget / connect / disconnect Rust tests pin exact call lists, no separate mutation was run. Not verified by a revert: `test_a_pad_alone_keeps_its_plain_name` (it guards against over-suffixing).

Deviations: the QML `test_battery_chips_for_two_pads` is in `tst_battery_cluster.qml`, not `tst_bluetooth` / `tst_controller_onboarding` (the cluster's helpers are there). The VM step pairs the second pad with `Pair` inside the open window rather than by the window's own pump: the `--session` service has no BlueZ signal loop (`follow_system` runs only on the real bus), so nothing wakes `pump`; the Rust tests drive the window path.

Unverified: `vm-devices-check.sh twopads` (lead run); no screenshot of the suffixed rows.
