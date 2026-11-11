# T-453 — Hub Controllers panel

Status: done · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
From the Hub over a game the player sees every connected controller, its battery and how it is connected, and can jump to the controller settings.

## Read first
- ADR-033; `02` §1.6 (T-447's Controllers panel); `04` §3, §4, §8
- `Devices1.Bluetooth`, `Devices1.Batteries`, `InputPresent` in `api/dbus/org.ruyaos.Devices1.xml`; the status cluster (T-223) and the Settings controllers pane

## Scope
1. The Controllers panel: one row per connected pad (name, family glyph where we have one, battery level and charging where reported, USB or Bluetooth).
2. "Controller settings" opens the Settings pane (leaving the Hub: level 3 of ADR-033).
3. Mapping, profiles and player slots are not here (Ruya Input, T-366..T-374): the panel shows no control for them.

## Acceptance criteria
- [ ] Two pads on the mock show two rows with their battery and connection (test); none connected: one line that says so (test)
- [ ] A pad that disconnects while the panel is open leaves it without moving the focus out of the panel (test)
- [ ] UX: Back lands on the Controllers entry; readable at 10 ft; `UX notes:` line
- [ ] `dev.ps1 test` ALL GREEN; `shots` of the panel reviewed

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `02` §1.6 built marks.

## Hints
- Planned by lead-10 (ADR-033).

## Outcome
Verified: host (vm pending: vm-devices-check.sh gamepads; ListGamepads in `check` too)
UX notes: states reached: the panel with pads (Bluetooth, USB, charging, full, not reported), with none ("No controllers connected." and Controller settings), a pad leaving or arriving while open, Controller settings. Back in the panel returns to the Hub with the focus on the Controllers entry (test); Back in the Hub resumes the game. Focus lands on the first pad row, or on the one line when none is connected; the readings take focus only so Up/Down walk them (Accept silent, hint bar `B Back`). When the focused pad leaves, the focus goes to the row that took its place (the last pad: Controller settings), never out of the panel; a pad that arrives does not move it. Controller settings: hint `A Open`, the Hub closes and Settings opens on Bluetooth & controllers over Home (games keep running behind it); Back from Settings lands on Home, not back in the Hub (level 3 of ADR-033 leaves the Hub). All text is `text` (04 §7); at 10 ft the two-line rows are the T-452 reading rows (caption name above, body value), read in `hub-controllers-2-pads.png`. Doubted: the name is the small line and the battery the big one; a pad name could be the more important line, but it follows the reading-row pattern of T-452.

**Built.** The Controllers panel as a table of row descriptors in `QuickMenu.panelDef` (`panelIds` = audio, controllers, performance): one *info* row per pad (new optional descriptor field `icon`: the family glyph via `DeviceIcons.iconFor`) and Controller settings as a new descriptor kind `action` (`activate()`, hint `A Open`, centred pill), no mapping/profile/slot control. Pads come from the service's `ListGamepads` (round 2 below; round 1 joined `Batteries` and `Bluetooth.devices`, which missed wired pads), sorted by name then id. Texts "Battery 62 %", "Battery 62 %, charging", "Battery full", "Battery not reported" + " · USB / Bluetooth" (`padText()`). An info row without a value is one body-size line. `settingsRequested(category)` signal; `Shell.openSettingsFromHub` (Home's route over an app, else closes pages) then `openPage("settings", { category })`. `QuickMenu` follows `Bluetooth.gamepadsChanged` with `rebuild()`.

**Two small fixes found on the way** (both in `QuickMenu.qml`): `rebuild()` read `actions.currentIndex` after the new model had reset it to 0, so a vanished focused row sent the focus to the first row; it now keeps the index from before. The "more rows" cues ignored `originY` (ListView's estimated heights make it non-zero), so with one more row in the Hub the last row showed a false "more below" (`tst_quickmenu` and `tst_hub_audio` went red); both cues now use `originY`. `tst_quickmenu`'s three order lists gain `panel:controllers`.

**Tests, round 1** (`shell/tests/tst_hub_controllers.qml`, 13 + screenshots; rewritten in round 2): entry order and Back to the entry; two Bluetooth pads and a USB pad with battery, connection, glyph and `Theme.text`; charging, unreported battery, a headset not listed; a pad in both lists is one row; none connected is one line; no mapping/profile/slot rows; a pad that disconnects (wired, then Bluetooth, then the last) leaves without the focus leaving the panel; a pad that connects does not move the focus; a reading follows its battery; Controller settings from over a game and from Home. Revert checks (`revert-check.ps1`): `rebuild()` using the index after the reset (the disconnect test red), `settingsRequested("bluetooth")` -> `"display"` (both Controller settings tests red), the list hook removed (connect and disconnect tests red; round 1: the `devicesChanged` hooks). The `originY` fix is covered by the existing `tst_quickmenu` cue test, which was red without it. No test lost (`lost-tests.sh` empty); `tst_quickmenu` lists were edited for the new entry.

**Files.** `shell/qml/QuickMenu.qml`, `shell/qml/Shell.qml`, `shell/tests/tst_hub_controllers.qml` (new), `shell/tests/tst_quickmenu.qml`, `shell/i18n/ruyashell_en.ts`, `shell/i18n/ruyashell_tr.ts` (ten strings, Turkish done), `docs/specs/02-shell.md` (§1.6), `docs/specs/04-design-system.md` (Hub rows).

**Round 2 (code review: the pad list was a workaround).** Round 1 built the list by joining `Batteries` and `Bluetooth.devices`, so a wired Xbox or generic USB pad (no UPower battery, no BlueZ entry) was "No controllers connected." Contract first, as CLAUDE.md asks (contracts are drafts; a join in the shell is the workaround it forbids):
- **`api/dbus/org.ruyaos.Devices1.xml`:** `Bluetooth.ListGamepads() -> aa{sv}` `{id, name, family, transport}` (the keys of `GamepadConnected`): the pads present now, baseline included, one entry per pad, empty before the first read; the two signals are documented as "call it again". Same interface, same bus policy (shell and root), no battery in it (`Batteries` has it, `address` = a Bluetooth pad's `id`, any case). Not app-reachable: Developer surface stays none.
- **Rust (`input.rs`, `dbus.rs`):** `InputPresence::pads()` (the last `refresh`) and `BluetoothIface::list_gamepads` (`gamepad_dicts`). Tests: `pads_lists_what_is_there_now_baseline_included`, `list_gamepads_answers_every_pad_with_the_contract_keys` (a wired Xbox 360 pad with a keyboard beside it: one entry, four keys, `usb`, `xbox`). Revert check: `transport` answered as "other" in `gamepad_dicts` turns the dbus test red.
- **Shell:** `BtGamepad`, `BluetoothBackend::gamepadsListed`, the D-Bus client asks `ListGamepads` on every refresh (start, service appears) and after each `GamepadConnected`/`GamepadDisconnected`, `Bluetooth.gamepads` (+ `gamepadsChanged`). The mock lists its connected Bluetooth controllers and the pads given to `mockGamepad` (its events now keep the list); the mock's default battery `pad-1` carries the address `bt-pad-main`, so the default state is one pad, one row. `QuickMenu.controllerPads()` now lists `Bluetooth.gamepads`; transport is the service's word, not "has an address"; battery by Bluetooth address from `Batteries`, else the paired device's level, else for a wired pad the one address-less controller battery of its family (unambiguous only), else "Battery not reported"; a transport other than USB or Bluetooth shows no connection word. The panel rebuilds on `gamepadsChanged` (the `Batteries`/`Bluetooth.devices` hooks are gone).
- **Tests** (`tst_hub_controllers.qml`, 15 + screenshots): rewritten on `Bluetooth.mockGamepad`; new `a_wired_pad_with_no_battery_and_no_bluetooth_entry_is_listed` (one row "Generic USB Pad, Battery not reported · USB", generic gamepad glyph) and `the_default_mock_state_shows_one_row_per_pad`. Revert checks: "USB" word always "Bluetooth" (four tests red), the mock listing no `mockGamepad` pads (six red), the mock battery's address removed (default-state test red).
- **VM (lead run):** `scripts/vm-devices-check.sh`: `check` (in the Bluetooth part) now calls `ListGamepads` (empty `aa{sv}` in the VM: QEMU's keyboard is no pad; refused for `nobody`), and the new mode `gamepads` (also run from `check`) makes a virtual USB pad through `/dev/uinput` (needs python3; no uinput: SKIP, said so), waits up to 8 s for it in `ListGamepads` (id and name "Ruya Test Pad", `xbox`, `usb`, four keys) and up to 8 s for it to go after `UI_DEV_DESTROY`. Not run on this machine.
- **Specs:** `02` §1.6 (where the pads come from) and `03` (Devices1: `ListGamepads`).
- **Limit left:** a pad's battery is only found for a wired pad when the match by family is unambiguous (two wired pads of one family with UPower batteries show "Battery not reported" rather than a guess).
