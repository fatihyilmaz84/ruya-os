# T-301 — Controller and battery UI follow-ups: Pair again, keyboard announcement, one status mapping, a clearer "+N"

Status: done · Phase: 2 · Depends: T-300 · Area: shell (BluetoothPane, ControllerOnboarding, ControllerToasts, status cluster in Shell.qml, BatteryChip) · Size: M · Owner: builder

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
Verified: host (offscreen `dev.ps1 test` and `dev.ps1 shots` on Windows; nothing here needs the VM).

UX notes: states reached: (1) Settings -> Bluetooth with a paired, not-bonded device: the row says "Not fully paired" and a "Pair again <name>" row sits among its actions; Accept runs Forget, a scan, then Pair, the row shows "Pairing..." while it works, focus stays in the pane (on the neighbour of the row that vanished); if the scan ends without finding the device (not in pairing mode) a toast says "Could not find it. Put the device in pairing mode and try again." and the device is an ordinary unpaired one; Back leaves the pane as before. (2) The "N more" chip: Up from Home to the nav, Right to the last pill, Right again reaches the chip (focus ring); Left returns to the last pill, Down enters the page, Back closes the page as in the nav, LB/RB step the section, Right and Up do nothing. (3) The hidden-list modal: Accept opens it, "Close" has the focus, Back or Accept closes it and focus is back on the chip, Up/Down scroll a list longer than six rows, the hint bar says "B Close"; it closes by itself when nothing is hidden any more, and if the chip went away then, the nav takes the focus. (4) A keyboard connecting: a toast with the keyboard glyph. Doubted: the stack glyph is two `battery_full` icons (the font has no "battery stack"; adding one means a new font cut, see inbox) and reads as a single dim battery at 10 ft; the words make the meaning.

What was built (files in `shell/`):
- **Pair again** (`qml/BluetoothPane.qml`): `bonded` in the row model, "Not fully paired" value, a `btRepair_<id>` row (`Pair again %1`) visible for a paired device that is not bonded. Forget, then `startScan()` on the forget's answer, then `Bluetooth.pair(id)` when the device is listed unpaired; the repair ends with a toast if the scan ends without it or if forget or the scan fail, and silently if Bluetooth goes off. The mock got `mockSetSilent(id, silent)` (a device a scan does not find) for the not-found test (`Bluetooth.*`, `MockBluetoothBackend.*`).
- **One status mapping** (`qml/BluetoothText.qml`, singleton, in `CMakeLists.txt`): `statusText(op, status, subject)`; `BluetoothPane.statusText` and `ControllerOnboarding.reasonText` call it (subject "device" in the pane, "controller" on the pairing screen: only the noun differs, so the pairing-screen wording and its existing test are unchanged).
- **Keyboard announcement** (`qml/ControllerToasts.qml`): `noteDevices()` on `Bluetooth.devicesChanged`: a listed keyboard whose `connected` turns true after the first list says "<Name> connected" (its own battery if known, glyph `DeviceIcons.iconFor("keyboard")`), same debounce as pads; a keyboard already connected, appearing connected, or leaving is silent; `gamepadsReset` makes the next list a baseline again.
- **Status cluster** (`qml/Shell.qml`, `qml/BatteryMore.qml`, `qml/BatteryListModal.qml`, `qml/SectionNav.qml`, `qml/Theme.qml`): slots go to controllers and headsets before the rest (stable, so lowest first inside each group); the "+N" became the focusable "N more" chip (stack glyph + words) with `SectionNav.edgeRequested`; `fitChips()` now returns `{chips, compact}`: it budgets the real chip (probes of the translated label, one and two digits), prefers the words with at least one battery chip, then the old "+N" (no glyph, no words) with at least one chip, else the chip alone; the hidden-list modal lives in `modalLayer`; `Theme.statusAvatarSize` (48) is used by the avatar and by `fixedWidth`.
- **Names/icons**: toast, pane and chip use `DeviceIcons.iconFor` (T-300 family) as before; the keyboard toast uses the same call.
- Specs: 02 (status cluster, toasts, Bluetooth list), 04 (sizes: `statusAvatarSize`; Battery chip row: the "N more" chip and modal; a `BluetoothText` row). Translations (en, tr) refreshed; strings that moved contexts are re-listed, vanished ones deleted.

Tests (all new ones fail without their change, see below): `tst_bluetooth::test_pair_again_for_unbonded`, `::test_pair_again_when_the_device_is_not_found`, `::test_status_text_single_mapping`; `tst_battery_cluster::test_pads_rank_above_mice`, `::test_plus_n_fits_at_text_scale_2`, `::test_the_chip_shrinks_to_plus_n_in_a_narrow_room`, `::test_plus_n_opens_the_hidden_list` (Back closes, focus returns to the chip), `::test_the_list_and_the_chip_follow_the_batteries`; `tst_shell::test_keyboard_connect_toast`; screenshots `test_zz_more_screenshots` (en, tr, UI size 150 and 200 %), `test_zz_pair_again_screenshot`.

Revert checks (`revert-check.ps1 -Test`): `visible: paired && !bonded ...` -> `visible: false` fails both pair-again tests; the pairing-screen "The controller went away." reworded in `BluetoothText` fails `test_status_text_single_mapping`; `rankOf` -> `return 0` fails `test_pads_rank_above_mice`; dropping the chip's width from `batteryWidth` fails four cluster tests (the nav is overrun); `onActivated: batteryList.open()` -> `{}` fails the two list tests; `compact: statusGlass.moreCompact` -> `false` fails the narrow-room and 125 % tests; `if (d.kind !== "keyboard")` -> `"keyboardx"` fails `test_keyboard_connect_toast`. **Not caught:** `onClosed: Qt.callLater(root.rescueFocus)` in `Shell.qml` (the mock orders the changes so that the chip's own `onVisibleChanged` already rescues the focus; the extra rescue covers the other order and is untested). Also untested: the repair's "scan failed" and "Bluetooth went off" branches.

Deviations / decisions:
- **"Text scale 2"**: the accessibility text scale (04 section 1) is not built, so `test_plus_n_fits_at_text_scale_2` uses the nearest thing, the UI size (100 % and 125 % at 720p, 1080p, 4K). 150 % and up cannot be fixed by the cluster: the nav alone takes the room (pre-existing, 02 says pages crop there); at 150 % the cluster shows "+N" and is a pixel or two from the nav at 720p. Re-run the test with the real text scale when it exists.
- **Fewer chips** (accepted by the lead, whose UX review prefers the words to a third chip): the "N more" chip with its words is wider than the old "+N", so for a short profile name two chips (not three) fit beside it at every size in English (in Turkish at 1080p one chip fits beside "4 tane daha", the label is longer; fewer at larger UI sizes: none at 150 %, where only the "+N" shows). `tst_battery_cluster::test_the_cluster_clears_the_nav_with_five_devices_at_three_sizes` (3 -> 2 chips) and `tst_battery::test_lowest_first_and_a_plus_n_beyond_three` (ranking, 2 chips, `count` instead of the "+N" text) were changed for that; every other assertion in them stays. With three devices all three still show.
- `tst_display::openDisplayPane` presses Left four times first: Right at the last nav pill now reaches the chip, and the second round of a test opened the nav on the Settings pill.
- "Pair again" label is "Pair again <name>" (like Rename/Forget); the repair needs the device in pairing mode, since the service's Forget removes it from the list and Pair needs it found again.
- The stack glyph is built from two `battery_full` icons (no new font cut).

Follow-ups (also in the HANDOFF inbox): a real `battery_stack` style glyph needs a font cut (Material has none under that name: `stacks`/`layers` exist); the Guide overlay list of hidden devices (T-147); re-run the cluster test at the real text scale; `Batteries.MaxChips` is not exposed to QML (the cluster derives it from `chips.length`).

**Round 2 (review):** the chip no longer accepts every key: only Accept, the arrows, LB/RB and Back, so Guide and Menu bubble up (`tst_battery_cluster::test_guide_opens_the_panel_from_the_chip`); the back glyph of the stack is `text` at `Theme.peekOpacity` (not `textDim` on glass; shot `battery-more-daylight-crop.png` and `battery-list-daylight.png` for the light theme); the list modal's hint bar says "A Close, B Back"; the "Pair again" row's value says "Put it in pairing mode first"; `test_the_focused_chip_going_away_hands_the_focus_to_the_nav` covers the chip's own focus rescue with no modal open; 04 (Battery chip row) and 02 updated. The "two chips beside the chip" claim holds for English only: in Turkish at 1080p one chip fits beside "4 tane daha". The words-over-a-third-chip trade-off is accepted by the lead. Inbox: RTL (Left/Right at the nav edge under a mirrored layout) is not handled for the chip.
