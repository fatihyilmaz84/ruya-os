# T-448 — The Quick Hub: status row, quick tiles, running and recent games

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder · Complexity: normal · Developer surface: none

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
Verified: host (`dev.ps1 test` ALL GREEN: 1086 QML passed + 92 skipped (the shot-only tests), Rust all ok; `shots` exit 0, `hub-1..3` and `appflow-3..5` reviewed). The `Devices1.Network.WifiEnabled` client is Linux-only code that was compiled and clippy-checked but never run against a service (the service does not offer it yet), so that path is unverified.

**Built.** The quick menu is now the Quick Hub of `02` §1.6: a status row (clock, network icon and name, up to two `BatteryChip`s and a "+N", not focusable); the app header; Resume, Home, Close game, Switch to <app>; up to four recent games that are not running (`Shell.quickMenuRecent`: `Library.recent` with a Session1 launch path, not in `runningAppIds`; Accept closes the Hub, then `Library.launch` -> `launchApp`: splash); Volume; the quick tiles; Power; Switch profile (and Close without an app). `QuickTile.qml` is new (04 §5 row set to built). Tiles: Wi-Fi, Bluetooth, Mute; one list row per line of three; Left/Right stop at the ends, the column is kept; Accept flips the backend and the tile shows the backend's answer (never optimistic); a refused Wi-Fi or Bluetooth switch toasts a `warning` and keeps the state. The list scrolls (`positionViewAtIndex(Contain)`) and the panel leaves room for the hint bar (`bottomReserve`, set by the shell). Over an app focus opens on Resume; without an app on the first Recent row, else Switch profile. A panel entry exists only for Power (Audio, Controllers, Performance, Notifications, Display arrive with their tasks).

**Wi-Fi tile and the contract (needs a decision).** The task says the Wi-Fi tile has a backend; it has none: `Devices1.Network` has no radio switch. Extended in this commit: `api/dbus/org.ruyaos.Devices1.xml` gets `WifiEnabled` (b, readwrite, documented "not served yet"); `NetworkBackend`/`Network` get `wifi` ("unsupported" | "off" | "on"), `setWifiEnabled(bool)` and `wifiFinished(status)`; the mock implements it (+ `mockWifiScript`, `mockWifiSupported`); the D-Bus client reads `WifiEnabled` from `GetAll` (missing property -> "unsupported") and sets it with `Properties.Set`. **The Rust service does not serve it** (NetworkManager `WirelessEnabled` in `services/ruya-devices`: left out of a shell task and because T-449 is editing that service), so on a real console the Wi-Fi tile is absent until a service task adds it; Bluetooth and Mute work there. Icons added to the subset font (`wifi`, `wifi_off`, `bluetooth_disabled`, `lan`; `icons.txt`, `Icon.qml`, both TTFs re-cut with `scripts/subset-icons.sh`).

**Tests.** New `tests/tst_quickmenu.qml` (18 tests, 2 shot-only): `test_quick_hub_order` (Down visits every row in the order of 02 §1.6, Back leaves, the next open is on Resume again), the Hub without an app, no recent games -> Switch profile first, status row (clock, network, batteries), a recent game launches and the Hub closes, recent rows (title, thumbnail, no Steam game, at most four), Left/Right along the tiles, one test each for the Wi-Fi, Bluetooth and Mute tiles (state changes with the mock's answer, accessible name), the Wi-Fi network name, a refused Wi-Fi switch (toast, state kept), no Wi-Fi tile when the service offers no switch, Power and Back, scrolling keeps the focused row in view. Revert checks (`revert-check.ps1 -Test tst_quickmenu`), each caught by the named test: Wi-Fi flip `setWifiEnabled(Network.wifi !== "on")` -> `(true)` (`test_the_wifi_tile_flips...`); Bluetooth flip -> `setPowered(true)` (`test_the_bluetooth_tile_flips...`); `menu.launchRequested(...)` -> `closeRequested()` (`test_a_recent_game_launches...`); dropping the "not running" filter in `Shell.qml` (`test_quick_hub_order`); the `unsupported` tile filter (`test_without_a_wifi_switch...`); `positionViewAtIndex` -> `0` (`test_a_long_hub_scrolls...`); the mock's refused answer (`test_a_refused_wifi_switch_toasts...`). The Mute flip has no revert check of its own (it shares `Audio.toggleMute()` with the volume row).

**Existing tests changed (not weakened).** The new order and first focus change what T-147 and others pinned by position; the task said they must stay green unchanged, which cannot hold: the Hub now always has tiles and, with recent games, rows before Switch profile, so "focus starts on Switch profile", "Up from Switch profile is Volume", "Down then Accept is Power", "Accept on the first row is Switch profile" and `count == 4` are false by design (`02` §1.6). Changed, same intent, same assertions otherwise: `tst_appflow.qml` (no-app focus is the first Recent row; reach Volume with `hubGoTo("volume")`; the no-app shot test), `tst_power.qml` (4 tests and the shot test reach "power" by key with `hubGoTo`; `count == 4` became "the last rows are power, switch, close"; the index 2 became `itemKeys.indexOf("power")`), `tst_pages.qml` and `tst_shell.qml` (reach "switch" with `hubGoTo`). Every other T-147 test (Resume focus, Home, Close game, Switch to, volume keys, Back) is untouched. `lost-tests.sh`: none.

**UX notes:** States reached: the Hub over an app, without an app, without recent games, with and without a Wi-Fi tile, each tile on and off (and a refused switch), the power choices, a scrolled list. Back leaves each: in the Hub it closes it and returns focus to the app, the page or Home (tested), in the power choices it returns to the Hub on the Power row (tested). Focus lands on Resume over an app, else the first Recent row, else Switch profile, on every open (`tileCol` and scroll position reset). Left/Right on tiles stop at the ends and never close the Hub. Readable at 10 ft: sizes are the 04 tokens; tile detail text is `typeMicro` (20 u) as 04 §5 says, the smallest text on the Hub. Doubts: (1) over an app at 1080p the tiles, Power and Switch profile are below the fold when the list shows three recent games; they are one or two Downs away but invisible on open (see design lines in the HANDOFF). (2) The status row drops the network name when a console has many batteries (icon only). (3) The scroll is a jump, not an animation.

**Files.** `shell/qml/QuickMenu.qml`, `QuickTile.qml` (new), `Shell.qml`, `Icon.qml`; `shell/fonts/*` (icons); `shell/src/network/*` (client, mock, base, facade); `api/dbus/org.ruyaos.Devices1.xml`; `shell/i18n/*.ts`; `shell/CMakeLists.txt`; tests `tst_quickmenu.qml` (new), `tst_appflow.qml`, `tst_power.qml`, `tst_pages.qml`, `tst_shell.qml`; `docs/specs/02-shell.md` (§1, §1.4 rows, §1.6 built marks), `04-design-system.md` (Quick tile built, Quick menu row). `vm-app-check.sh flow` is unchanged: `quickMenuItem_resume` is kept and Resume is still first with Home second.
