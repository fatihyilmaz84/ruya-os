# T-301 — Controller and battery UI follow-ups: Pair again, keyboard announcement, one status mapping, a clearer "+N"

Status: in-progress · Phase: 2 · Depends: T-300 · Area: shell (BluetoothPane, ControllerOnboarding, ControllerToasts, status cluster in Shell.qml, BatteryChip) · Size: M · Owner: builder

## Goal
A headset or pad that is paired but not bonded can be repaired in one step, the status cluster in the top bar ranks and explains what it shows, a Bluetooth keyboard connecting is announced like a pad, and the shell has one place that turns a Bluetooth status into words.

## Read first
- `docs/specs/02-shell.md` (controller onboarding, top bar), `04-design-system.md` §5 (BatteryChip, ToastLayer), §8
- T-260, T-223, T-199 Outcomes; `shell/qml/BluetoothPane.qml` (`statusText`), `ControllerOnboarding.qml` (`reasonText`), `ControllerToasts.qml`, `BatteryChip.qml`, `Shell.qml` (`fitChips()` ~568, `statusGlass.fixedWidth` ~537, avatar `48 * root.u` ~618), `DeviceIcons.qml`
- `shell/tests/tst_bluetooth.qml`, `tst_battery_cluster.qml`, `tst_controller_onboarding.qml`; STATUS-parked.md "Inbox triage 2026-11-07", bullets T-301

## Scope
1. **Pair again:** a paired device with `bonded == false` (T-300) shows "Pair again" in the Bluetooth pane (and in its row's actions) which runs Forget then Pair; the row says "Not fully paired" until then (en and tr).
2. **Keyboard announcement:** a Bluetooth keyboard (kind keyboard) connecting shows a toast "<Name> connected" with the keyboard icon from `DeviceIcons.iconFor`, like pads.
3. **One status mapping:** `BluetoothPane.statusText` and `ControllerOnboarding.reasonText` use one shared function/component for Bluetooth statuses (a singleton `BluetoothText`, listed in `shell/CMakeLists.txt`).
4. **Status cluster:** rank pads and headsets above mice and keyboards for the three visible slots; `fitChips()` checks that "+N" plus the shortest chip name fits at the current text scale; the "+N" chip carries a meaning (a battery-stack glyph and the label "N more"), reachable with the pad: Accept on it opens a small list modal of the hidden devices with their percentages (the Guide overlay list stays with T-147). The avatar diameter `48` becomes a `Theme` token used by both the avatar and `statusGlass.fixedWidth`.
5. **Names:** the cluster, pane and toast use the same icon for the same device (family from T-300).

## Out of scope
- The Players UI and slot chips (T-265: it reuses `BatteryChip`; keep its API stable), the Guide overlay list, the 40 px pad glyph redesign (Dell look first), brand art.

## Acceptance criteria
- [ ] `tst_bluetooth.qml::test_pair_again_for_unbonded` (row shows the action only when `bonded` is false; Accept calls Forget then Pair in the mock) and `::test_status_text_single_mapping` (both screens give the same words for every status).
- [ ] `tst_controller_onboarding.qml` still passes with the shared mapping.
- [ ] `tst_battery_cluster.qml::test_pads_rank_above_mice`, `::test_plus_n_fits_at_text_scale_2`, `::test_plus_n_opens_the_hidden_list` (Back closes, focus returns to the chip).
- [ ] `tst_shell.qml::test_keyboard_connect_toast`.
- [ ] Screenshots reviewed: cluster with 5 devices (en, tr, text scale large), the hidden-list modal, Bluetooth pane with a Pair again row.
- [ ] UX: from every new state Back leaves; focus lands sensibly after open/close/error; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- 02 (top bar chips, onboarding), 04 §5 (BatteryChip "+N", the avatar token).

## Hints
- Reference: `ControllerToasts.qml` for announcing, `PowerConfirm.qml` for a small modal with focus return.
- Overlaps T-285 (hints), T-265 (chips): run after T-300 and before T-265.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
