# T-448 — The Quick Hub: status row, quick tiles, running and recent games

Status: done · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder · Complexity: normal · Developer surface: none

## Goal
Guide opens Ruya Hub's first level: the time, network and battery at the top, the running game and Resume, the other running and recent games, a row of quick tiles and the entries to the panels, all with a controller.

## Read first
- ADR-033 (`00-overview.md`); `02` §1.6 as written by T-447; `04` §3, §4, §5, §8 (new tokens or components allowed: only those T-447 specified)
- `shell/qml/QuickMenu.qml`, the status cluster (T-223), `shell/PATTERNS.md`

## Scope
1. Restructure `QuickMenu.qml` into the Quick Hub of `02` §1.6: status row (reuse the status cluster), the app header with Resume first, Switch to <app> per other running app, up to 4 recent games (`Library.recent`; Accept launches through `Shell.launchApp`), the tiles row and the panel entries.
2. Build the Quick tile (`QuickTile.qml`, proposed in `04` §5; set it to built and add it to `shell/CMakeLists.txt`). Tiles that already have a backend: Wi-Fi (on/off and the network name), Bluetooth (on/off), mute. A tile whose backend is not built yet (microphone, brightness) is absent.
3. A panel entry appears only when its panel exists (Volume and Power today; the others arrive with their tasks).
4. Keep T-147's behaviour: Resume, Home, Close game, Switch profile, Power; T-147's tests stay green unchanged.

## Out of scope
- The Audio, Performance and Controllers panels (T-450, T-452, T-453); display tiles (T-454); per-pad Guide (T-456).

## Acceptance criteria
- [ ] Guide over an app focuses Resume; Down reaches the tiles and entries in the order of `02` §1.6 (test: `tst_quickmenu.qml::test_quick_hub_order`)
- [ ] A recent game launches from the Hub and the Hub closes (test)
- [ ] The Wi-Fi, Bluetooth and mute tiles change the mock's state and show it (one test per tile)
- [ ] Without an app: the same Hub minus the app part (test)
- [ ] UX: from every new state Back leaves; focus lands on Resume or the first row after open; readable at 10 ft; Outcome has a `UX notes:` line
- [ ] `dev.ps1 test` ALL GREEN; `shots` of the Hub over an app and without one reviewed

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `02` §1.6 built marks.

## Hints
- Planned by lead-10 (ADR-033). `vm-app-check.sh flow` counts `focus quickMenuItem_resume`: keep that objectName or update the check in the same commit.

## Outcome
Verified: host (vm pending: `scripts/vm-devices-check.sh` (the network part: `WifiEnabled` get/set read-back, polkit `enable-disable-wifi` allowed). `dev.ps1 test` ALL GREEN (QML counts in the HANDOFF; Rust ok), `shots` reviewed (`hub-1..4`, `appflow-3..5`; four unrelated Settings, Store, System information and Wallpaper screenshot tests time out in 3 of 4 runs while another builder runs tests on this machine, one earlier run was fully green; they do not touch the Hub). The Linux-only NetworkManager client code (`NmClient::set_wifi_enabled_async`, `flag`) is compiled and clippy-checked (Windows and Linux targets) but not run.
Lead, 2026-11-10, image 0.0.63 (VM this task): `vm-devices-check.sh check` network part PASS: WifiEnabled reads false without an adapter and a write is a bus error, a write from nobody is refused, polkit allows ruya-devices `enable-disable-wifi` and still refuses the wifi.share actions; `vm-devices-check.sh security` PASS. Now Verified: vm. (The same run's one idle pw-dump FAIL is investigated separately.)

**Built (round 1).** The quick menu is now the Quick Hub of `02` §1.6: status row (clock, network icon and name, up to two `BatteryChip`s and "+N"; not focusable), the app header, Resume, Home, Close game, Switch to <app>, the recent games that are not running (`Shell.quickMenuRecent`: `Library.recent` with a Session1 launch path; Accept closes the Hub, then `Library.launch`), Volume, the quick tiles, Power, Switch profile (Close without an app). `QuickTile.qml` is new (04 §5 built). Tiles Wi-Fi, Bluetooth, Mute: one list row per line of three, Left/Right stop at the ends, the column is kept; Accept flips the backend and the tile shows the backend's answer; a refused switch toasts a `warning` and keeps the state. Focus opens on Resume, else the first Recent row, else Switch profile. A panel entry exists only for Power. The list scrolls and the panel leaves room for the hint bar (`bottomReserve`).

**Round 2.**
- *`WifiEnabled` is served.* `api/dbus/org.ruyaos.Devices1.xml`: `WifiEnabled` (b, rw, no "not served yet"). `services/ruya-devices`: `Raw.wifi_enabled` (NM `WirelessEnabled` and a Wi-Fi adapter exists), `NetworkManager::set_wifi_enabled` (NM client: `Properties.Set` on `WirelessEnabled`; error with no adapter; fake: `set_wifi_fails`), `Network::wifi_enabled`/`set_wifi_enabled` (re-reads, returns `Changes` with new `wifi`), the D-Bus property and setter (`fdo::Error::Failed` on error like `Powered`; zbus announces `WifiEnabled`, the rest (State, Primary, NetworksChanged) is emitted; an outside change is announced by the NM watcher through `Changes.wifi`). Tests on the fake NM: switch reads back and reports what changed (radio, access points), the radio off drops a Wi-Fi connection, a refused switch is an error and keeps the state, a radio switched from outside is noticed by the next refresh. **Image:** `image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-network.rules` now also allows `enable-disable-wifi` for `ruya-shell` (it was refused by T-180, so the service's Set would have failed on a real console); 01 §Network updated; `vm-devices-check.sh` moves it from the refused list to the allowed one (five allowed, eleven refused) and adds the `WifiEnabled` step (with an adapter: off and on read back; without one, as in the VM: reads false and a write is a bus error; a write from `nobody` is refused). Wi-Fi hard-blocks and a console with no Wi-Fi adapter show the tile "Off" and a press toasts the failure (no adapter presence signal yet: Inbox, like Bluetooth).
- *Rulings applied:* over an app at most 2 Recent rows, without an app 4 (`02` §1.6); 04 §5 texts (tile height, Recent rows are Hub pill rows, tile focus); Quick tile pairs in the contrast gate (`tst_theme_contrast`, label and state line (`text`) on `selectedFill` and `focusFill` over `glassOpaque` over white and black at 4.5:1; `onPrimary` on `primaryFill` was already there). **The gate found a real failure:** `textDim` on `selectedFill` is 3.4 to 4.1:1 and on `focusFill` 2.8 to 4.2:1 in all four dark themes, so the tile's state line uses `text` (not `textDim` as 04 §5 proposed); 04 §5 says so. Shot `hub-4-tiles-wifi-off.png` (Wi-Fi off and focused, Bluetooth on, Mute off).
- *Cheap UX:* scroll cue (a `glassOpaque`-to-clear fade, `hubMoreAbove`/`hubMoreBelow`, test `test_a_cue_says_there_are_more_rows...`); the A hint says `Start` on a Recent row, `Toggle` on a tile, else `Select` (test `test_the_a_hint_says_what_the_row_does`; Left/Right "Adjust" on Volume is not done: the hint bar's D-pad pill is the interim letter pill, T-285); `NetworkBackend::deliverState` has no default argument for `wifi` any more.

**Tests.** `tests/tst_quickmenu.qml` (20 tests, 2 shot-only), see round 1: order, no app, no recent, status row, batteries, recent launch, recent rows, tiles along, one test per tile, network name, refused switch, absent tile, Power and Back, scrolling, A hint, scroll cue. Revert checks (`revert-check.ps1 -Test tst_quickmenu`), each caught: Wi-Fi flip -> `setWifiEnabled(true)`; Bluetooth flip -> `setPowered(true)`; `launchRequested` -> `closeRequested`; dropping the "not running" filter; the `unsupported` tile filter; `positionViewAtIndex` -> `0`; the mock's refused answer. Not re-run after round 2: the Recent limit, the A hint and the cue (their tests were written with the change and pass; no revert check). The Mute flip has no revert check of its own (shared `Audio.toggleMute()`).

**Existing tests changed (not weakened), accepted by the lead.** `tst_appflow.qml`, `tst_power.qml`, `tst_pages.qml`, `tst_shell.qml` reach their row by key (`hubGoTo`) and the no-app focus is the first Recent row; round 2 adds `tst_hints.qml::test_overlay` (`A Start|B Close`: the focus opens on a Recent row) and `tst_theme_contrast.qml` rows. `lost-tests.sh`: none.

**UX notes:** States reached: the Hub over an app (2 recents), without an app (4), without recent games, with and without a Wi-Fi tile, each tile on, off and refused, the power choices, a scrolled list with the cue. Back leaves each: the Hub closes and returns focus to the app, page or Home; in the power choices it returns to the Hub on Power. Focus lands on Resume, else the first Recent row, else Switch profile on every open. Left/Right on tiles stop at the ends. Readable at 10 ft: 04 tokens (the state line is the smallest text, `typeMicro`). Doubts: the status row drops the network name when a console has many batteries (icon only; Inbox: keep the name next to the chips); the scroll jumps (no animation); the bottom fade lies over the lower edge of a focused tile when the tiles are the last row in view.

**Files.** Shell: `QuickMenu.qml`, `QuickTile.qml` (new), `Shell.qml`, `Icon.qml`, `shell/fonts/*`, `shell/src/network/*`, `i18n/*.ts`, `CMakeLists.txt`; services: `ruya-devices/src/{network,networkmanager,dbus}.rs`; `api/dbus/org.ruyaos.Devices1.xml`; image: the polkit rule; scripts: `vm-devices-check.sh`; tests: `tst_quickmenu.qml` (new), `tst_appflow`, `tst_power`, `tst_pages`, `tst_shell`, `tst_hints`, `tst_theme_contrast`; docs: `01-platform.md`, `02-shell.md`, `04-design-system.md`. `vm-app-check.sh flow` is unchanged (`quickMenuItem_resume` kept; Resume first, Home second).
