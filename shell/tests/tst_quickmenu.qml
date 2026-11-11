import QtQuick
import QtTest
import RuyaShell

// The Quick Hub (T-448, 02 §1.6): what Guide opens. The status row, the app part with Resume first, the
// recent games that are not running (Accept starts one and the Hub closes), the volume row, the quick
// tiles (Wi-Fi, Bluetooth, Mute: each flips the mock's state and shows the answer), Power and Switch
// profile. Controller keys only. Signs in as "Ada" (p2): the mock library's recent, launchable and not
// running games are then Turbo Racer, Open Player, Block Puzzle and Pixel Hopper (Steam games have no
// Session1 path).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A window of an app that takes every key, like a game.
    Component {
        id: appComponent
        Item {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            Keys.onPressed: event => event.accepted = true
        }
    }

    // A "game" with something to look at behind the Hub (screenshots).
    Component {
        id: pictureAppComponent
        Rectangle {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            color: "steelblue"
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: parent.height / 3; color: "darkgreen" }
            Rectangle { x: parent.width * 0.55; y: parent.height * 0.2; width: parent.width * 0.2; height: width; radius: width / 2; color: "gold" }
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }

    TestCase {
        id: tc
        name: "QuickHub"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function start() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => Library.available)
            tryVerify(() => Library.items.length === 10)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            Library.resetMockForTests("")
            Session.mockReset()
            Network.mockReset()
            Bluetooth.mockReset()
            Audio.mockReset()
            launchedSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
        }

        // Play on the hero, the answer, and the app's window: the app item is returned focused.
        function playRacer() {
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(appComponent, host)
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")
            return app
        }

        function openHub() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
        }

        function focusedKey() {
            const list = find("systemActions")
            return list.model[list.currentIndex]
        }

        // Down until the row is focused (at most 20 steps); the Hub's rows are many.
        function goTo(key) {
            for (let i = 0; i < 20 && focusedKey() !== key; ++i)
                keyClick(Qt.Key_Down)
            compare(focusedKey(), key)
            verify(find("quickMenuItem_" + key).focused, key + " has the focus ring")
        }

        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text)
            return out
        }

        // ---- order and focus ---------------------------------------------------------------------

        function test_quick_hub_order() {
            start()
            const app = playRacer()
            openHub()
            verify(!app.activeFocus)
            compare(focusedKey(), "resume")
            verify(find("quickMenuItem_resume").focused, "Resume has the focus on every open")
            compare(find("systemPanel").itemKeys, ["resume", "home", "closeGame",
                "recent:flatpak:org.example.Player", "recent:flatpak:org.example.Puzzle",
                "volume", "tiles:0", "tiles:1", "panel:audio", "panel:controllers", "panel:performance", "power", "switch"], "the Hub's order; the running game is not repeated under Recent, and over an app there are two; the microphone tile wraps to a second line")
            // Down reaches every row in that order, one key press each.
            for (const key of ["home", "closeGame", "recent:flatpak:org.example.Player", "recent:flatpak:org.example.Puzzle",
                               "volume", "tiles:0", "tiles:1", "panel:audio", "panel:controllers", "panel:performance", "power", "switch"]) {
                keyClick(Qt.Key_Down)
                compare(focusedKey(), key)
                verify(find("systemActions").activeFocus)
            }
            keyClick(Qt.Key_Down)
            compare(focusedKey(), "switch", "the last row stays")
            // Back closes the Hub and gives the app its focus.
            keyClick(Qt.Key_Escape)
            tryVerify(() => app.activeFocus && !find("systemPanel").open, 2000, "Back leaves the Hub")
            // The next open starts at Resume again.
            openHub()
            compare(focusedKey(), "resume")
            keyClick(Qt.Key_Escape)
            tryVerify(() => app.activeFocus, 2000)
        }

        function test_the_hub_without_an_app_is_the_same_minus_the_app_part() {
            start()
            openHub()
            compare(find("systemPanel").hasApp, false)
            verify(!find("quickMenuApp").visible, "no app part")
            tryVerify(() => find("quickMenuSystem").visible, 2000, "the System heading instead")
            tryVerify(() => find("hubStatus").visible, 2000, "the status row is there too")
            compare(find("systemPanel").itemKeys, [
                "recent:flatpak:org.example.Racer", "recent:flatpak:org.example.Player",
                "recent:flatpak:org.example.Puzzle", "recent:flatpak:org.example.Platformer",
                "volume", "tiles:0", "tiles:1", "panel:audio", "panel:controllers", "panel:performance", "power", "switch", "close"])
            verify(!find("quickMenuItem_resume") && !find("quickMenuItem_home") && !find("quickMenuItem_closeGame"))
            compare(focusedKey(), "recent:flatpak:org.example.Racer", "focus starts on the first Recent row")
            verify(find("quickMenuItem_recent:flatpak:org.example.Racer").focused)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("systemPanel").open)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Back returns to Play")
        }

        function test_without_recent_games_focus_starts_on_switch_profile() {
            start()
            Library.resetMockForTests("empty")
            tryVerify(() => Library.recent.length === 0)
            openHub()
            tryVerify(() => find("systemPanel").recent.length === 0)
            compare(focusedKey(), "switch")
            verify(find("quickMenuItem_switch").focused)
            verify(!find("quickMenuItem_recent:flatpak:org.example.Racer"))
            keyClick(Qt.Key_Escape)
        }

        function test_the_status_row_shows_the_clock_and_the_network() {
            start()
            openHub()
            const row = find("hubStatus")
            tryVerify(() => row.visible, 2000, "the status row is drawn")
            compare(find("hubClock").text, TimeZone.clockText)
            verify(find("hubClock").text !== "")
            compare(find("hubNetworkName").text, "Wired", "the mock is on a cable")
            Network.mockSetCable(false)
            tryCompare(find("hubNetworkName"), "text", "Not connected")
            verify(!row.activeFocus, "the status row never takes focus")
            for (let i = 0; i < 12; ++i)
                keyClick(Qt.Key_Down)
            verify(find("systemActions").activeFocus)
            keyClick(Qt.Key_Escape)
        }

        function test_the_status_row_lists_the_device_batteries() {
            start()
            Batteries.mockPopulate()
            tryVerify(() => Batteries.chips.length > 0)
            openHub()
            tryVerify(() => find("hubBatteries").visible, 2000, "chips show once a device reports a battery")
            verify(find("hubBatteries").width > 0)
            const first = Batteries.chips[0].id
            verify(findChild(find("hubBatteries"), "hubBattery_" + first), "the lowest device has its chip")
            keyClick(Qt.Key_Escape)
        }

        // ---- Recent -------------------------------------------------------------------------------

        function test_a_recent_game_launches_from_the_hub_and_the_hub_closes() {
            start()
            openHub()
            goTo("recent:flatpak:org.example.Puzzle")
            keyClick(Qt.Key_Return)
            tryVerify(() => !find("systemPanel").open, 2000, "the Hub closes")
            tryCompare(launchedSpy, "count", 1)
            compare(launchedSpy.signalArguments[0][0], "org.example.Puzzle", "that game, not the hero's")
            compare(launchedSpy.signalArguments[0][1], "p2")
            compare(launchedSpy.signalArguments[0][2], "ok")
            tryVerify(() => find("launchSplash").shown, 2000, "the splash takes over as Home's Play does")
        }

        function test_a_recent_row_shows_its_title_and_never_a_steam_game() {
            start()
            openHub()
            compare(find("quickMenuItem_recent:flatpak:org.example.Racer").label, "Turbo Racer")
            const thumb = findChild(find("quickMenuItem_recent:flatpak:org.example.Racer"), "quickMenuThumb")
            tryVerify(() => thumb.visible, 2000, "the row has its picture")
            verify(!find("quickMenuItem_recent:steam:730"), "a game with no Session1 launch path has no row")
            compare(find("systemPanel").recent.length, 4, "at most four")
            keyClick(Qt.Key_Escape)
        }

        // ---- Tiles ---------------------------------------------------------------------------------

        function test_left_and_right_move_along_the_tiles_and_stop_at_the_ends() {
            start()
            openHub()
            goTo("tiles:0")
            verify(find("quickTile_wifi").focused, "the first tile has the ring")
            keyClick(Qt.Key_Left)
            verify(find("quickTile_wifi").focused, "Left at the start stays")
            keyClick(Qt.Key_Right)
            verify(find("quickTile_bluetooth").focused && !find("quickTile_wifi").focused)
            keyClick(Qt.Key_Right)
            verify(find("quickTile_mute").focused)
            keyClick(Qt.Key_Right)
            verify(find("quickTile_mute").focused, "Right at the end stays")
            verify(find("systemPanel").open, "Left/Right never close the Hub")
            keyClick(Qt.Key_Up)
            compare(focusedKey(), "volume")
            keyClick(Qt.Key_Down)
            verify(find("quickTile_mute").focused, "the column is kept")
            keyClick(Qt.Key_Escape)
        }

        function test_the_wifi_tile_flips_the_radio_and_shows_the_answer() {
            start()
            openHub()
            goTo("tiles:0")
            const tile = find("quickTile_wifi")
            compare(Network.wifi, "on")
            verify(tile.on)
            compare(tile.detail, "Not connected", "on a cable, no Wi-Fi network is joined")
            keyClick(Qt.Key_Return)
            tryCompare(Network, "wifi", "off")
            tryVerify(() => !tile.on, 2000, "the tile shows the answer")
            compare(tile.detail, "Off")
            compare(tile.Accessible.name, "Wi-Fi, off")
            keyClick(Qt.Key_Return)
            tryCompare(Network, "wifi", "on")
            tryVerify(() => tile.on)
            verify(find("systemPanel").open, "a tile never closes the Hub")
            verify(tile.focused, "and keeps the focus")
            keyClick(Qt.Key_Escape)
        }

        function test_the_wifi_tile_names_the_joined_network() {
            start()
            Network.mockSetCable(false)
            Network.connectWifi("wifi-lounge", "")
            tryVerify(() => Network.networks.some(n => n.active))
            openHub()
            goTo("tiles:0")
            compare(find("quickTile_wifi").detail, "Lounge 5G")
            keyClick(Qt.Key_Escape)
        }

        function test_a_refused_wifi_switch_toasts_and_keeps_the_old_state() {
            start()
            Network.mockWifiScript("failed")
            openHub()
            goTo("tiles:0")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().indexOf("Could not change Wi-Fi.") >= 0, 2000, "a warning says why")
            compare(Network.wifi, "on", "the state did not move")
            verify(find("quickTile_wifi").on)
            keyClick(Qt.Key_Escape)
        }

        function test_without_a_wifi_switch_the_tile_is_absent() {
            start()
            Network.mockWifiSupported(false)
            tryCompare(Network, "wifi", "unsupported")
            openHub()
            goTo("tiles:0")
            verify(!find("quickTile_wifi"), "no fake control")
            verify(find("quickTile_bluetooth") && find("quickTile_mute"))
            verify(find("quickTile_bluetooth").focused, "the first tile that exists has the focus")
            keyClick(Qt.Key_Escape)
        }

        function test_the_bluetooth_tile_flips_the_adapter_and_shows_the_answer() {
            start()
            tryVerify(() => Bluetooth.powered, 2000)
            openHub()
            goTo("tiles:0")
            keyClick(Qt.Key_Right)
            const tile = find("quickTile_bluetooth")
            verify(tile.focused)
            verify(tile.on)
            compare(tile.detail, "On")
            keyClick(Qt.Key_Return)
            tryCompare(Bluetooth, "powered", false)
            tryVerify(() => !tile.on, 2000, "the tile shows the answer")
            compare(tile.detail, "Off")
            compare(tile.Accessible.name, "Bluetooth, off")
            keyClick(Qt.Key_Return)
            tryCompare(Bluetooth, "powered", true)
            tryVerify(() => tile.on)
            keyClick(Qt.Key_Escape)
        }

        function test_the_mute_tile_flips_the_master_mute_and_shows_the_answer() {
            start()
            tryVerify(() => Audio.volume >= 0)
            compare(Audio.muted, false)
            openHub()
            goTo("tiles:0")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            const tile = find("quickTile_mute")
            verify(tile.focused)
            verify(!tile.on)
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "muted", true)
            tryVerify(() => tile.on, 2000, "the tile shows the answer")
            compare(tile.detail, "Muted")
            compare(tile.Accessible.name, "Mute, on")
            compare(find("quickMenuVolumeValue").text, "Muted", "and so does the volume row")
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "muted", false)
            tryVerify(() => !tile.on)
            keyClick(Qt.Key_Escape)
        }

        // ---- Power and Back -------------------------------------------------------------------------

        function test_power_still_opens_the_choices_and_back_returns_to_the_hub() {
            start()
            openHub()
            goTo("power")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "powerMode", true)
            verify(find("systemActions").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(find("systemPanel"), "powerMode", false)
            verify(find("systemPanel").open, "Back left only the choices")
            compare(focusedKey(), "power", "the focus is on the entry that was opened")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("systemPanel").open)
        }

        function test_a_long_hub_scrolls_so_the_focused_row_is_in_view() {
            start()
            openHub()
            const list = find("systemActions")
            goTo("close")
            const row = find("quickMenuItem_close")
            const top = row.mapToItem(list, 0, 0).y
            verify(top >= -1 && top + row.height <= list.height + 1, "the row lies inside the list's window")
            keyClick(Qt.Key_Escape)
        }

        function hintVerbs() {
            const bar = find("hintBar")
            const parts = []
            for (const b of ["A", "B"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        function test_the_a_hint_says_what_the_row_does() {
            start()
            const app = playRacer()
            openHub()
            compare(hintVerbs(), "A Select|B Resume")
            goTo("recent:flatpak:org.example.Player")
            compare(hintVerbs(), "A Start|B Resume")
            goTo("tiles:0")
            compare(hintVerbs(), "A Toggle|B Resume")
            goTo("power")
            compare(hintVerbs(), "A Select|B Resume")
            keyClick(Qt.Key_Escape)
            tryVerify(() => app.activeFocus, 2000)
        }

        function test_a_cue_says_there_are_more_rows_in_the_direction_the_list_scrolls() {
            start()
            openHub()
            const below = find("hubMoreBelow")
            const above = find("hubMoreAbove")
            verify(!above.needed, "at the top nothing is hidden above")
            verify(below.needed, "the list is longer than the panel: rows are hidden below")
            goTo("close")
            tryVerify(() => above.needed, 2000, "scrolled down: rows are hidden above")
            verify(!below.needed, "at the end nothing is hidden below")
            keyClick(Qt.Key_Escape)
        }

        // ---- Screenshots (dev.ps1 shots) ------------------------------------------------------------------

        function test_zz_screenshots_hub_over_the_app() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(pictureAppComponent, host)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000)
            Batteries.mockPopulate()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused, 2000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/hub-1-over-app.png")
            goTo("tiles:0")
            keyClick(Qt.Key_Right)
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/hub-2-tiles.png")
            keyClick(Qt.Key_Left)                    // Wi-Fi: on, then switched off, and focused
            keyClick(Qt.Key_Return)
            tryCompare(Network, "wifi", "off")
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/hub-4-tiles-wifi-off.png")
        }

        function test_zz_screenshots_hub_without_an_app() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_recent:flatpak:org.example.Racer").focused, 2000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/hub-3-no-app.png")
        }
    }
}
