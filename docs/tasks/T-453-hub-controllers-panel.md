# T-453 — Hub Controllers panel

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder · Complexity: normal · Developer surface: none

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
Verified: host
UX notes: states reached: the panel with pads (Bluetooth, USB, charging, full, not reported), with none ("No controllers connected." and Controller settings), a pad leaving or arriving while open, Controller settings. Back in the panel returns to the Hub with the focus on the Controllers entry (test); Back in the Hub resumes the game. Focus lands on the first pad row, or on the one line when none is connected; the readings take focus only so Up/Down walk them (Accept silent, hint bar `B Back`). When the focused pad leaves, the focus goes to the row that took its place (the last pad: Controller settings), never out of the panel; a pad that arrives does not move it. Controller settings: hint `A Open`, the Hub closes and Settings opens on Bluetooth & controllers over Home (games keep running behind it); Back from Settings lands on Home, not back in the Hub (level 3 of ADR-033 leaves the Hub). All text is `text` (04 §7); at 10 ft the two-line rows are the T-452 reading rows (caption name above, body value), read in `hub-controllers-2-pads.png`. Doubted: the name is the small line and the battery the big one; a pad name could be the more important line, but it follows the reading-row pattern of T-452.

**Built.** The Controllers panel as a table of row descriptors in `QuickMenu.panelDef` (`panelIds` = audio, controllers, performance): one *info* row per pad (new optional descriptor field `icon`: the family glyph via `DeviceIcons.iconFor`) and Controller settings as a new descriptor kind `action` (`activate()`, hint `A Open`, centred pill), no mapping/profile/slot control. Pads come from `Batteries.devices` (kind controller; address set: Bluetooth, else USB) plus connected controllers of `Bluetooth.devices` that no battery entry names by address (`controllerPads()`, sorted by name then id, keys by address or battery id). Texts "Battery 62 %", "Battery 62 %, charging", "Battery full", "Battery not reported" + " · USB / Bluetooth" (`padText()`). An info row without a value is one body-size line. `settingsRequested(category)` signal; `Shell.openSettingsFromHub` (Home's route over an app, else closes pages) then `openPage("settings", { category })`. `QuickMenu` follows `Batteries.devicesChanged` and `Bluetooth.devicesChanged` with `rebuild()`.

**Two small fixes found on the way** (both in `QuickMenu.qml`): `rebuild()` read `actions.currentIndex` after the new model had reset it to 0, so a vanished focused row sent the focus to the first row; it now keeps the index from before. The "more rows" cues ignored `originY` (ListView's estimated heights make it non-zero), so with one more row in the Hub the last row showed a false "more below" (`tst_quickmenu` and `tst_hub_audio` went red); both cues now use `originY`. `tst_quickmenu`'s three order lists gain `panel:controllers`.

**Tests** (`shell/tests/tst_hub_controllers.qml`, 13 + screenshots): entry order and Back to the entry; two Bluetooth pads and a USB pad with battery, connection, glyph and `Theme.text`; charging, unreported battery, a headset not listed; a pad in both lists is one row; none connected is one line; no mapping/profile/slot rows; a pad that disconnects (wired, then Bluetooth, then the last) leaves without the focus leaving the panel; a pad that connects does not move the focus; a reading follows its battery; Controller settings from over a game and from Home. Revert checks (`revert-check.ps1`): `rebuild()` using the index after the reset (the disconnect test red), `settingsRequested("bluetooth")` -> `"display"` (both Controller settings tests red), the `Bluetooth` and `Batteries` `devicesChanged` hook removed (connect and disconnect tests red). The `originY` fix is covered by the existing `tst_quickmenu` cue test, which was red without it. No test lost (`lost-tests.sh` empty); `tst_quickmenu` lists were edited for the new entry.

**Limits.** A wired pad that UPower lists no battery for and that has no Bluetooth entry is not shown (the service has no list-of-pads call; `GamepadConnected` only announces changes after its baseline). In the mock's default state the Bluetooth pad `bt-pad-main` and the battery `pad-1` ("Ruya Pad Pro") are two rows (no shared address); tests set their own state. `Verified: host`: real pads and the Dell are not tried.

**Files.** `shell/qml/QuickMenu.qml`, `shell/qml/Shell.qml`, `shell/tests/tst_hub_controllers.qml` (new), `shell/tests/tst_quickmenu.qml`, `shell/i18n/ruyashell_en.ts`, `shell/i18n/ruyashell_tr.ts` (ten strings, Turkish done), `docs/specs/02-shell.md` (§1.6), `docs/specs/04-design-system.md` (Hub rows).
