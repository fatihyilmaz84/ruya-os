import QtQuick
import QtTest
import RuyaShell

// The Quick Hub (T-448, T-471, 02 §1.6): what Guide opens. One screen, no scroll, at most five focus stops:
// the status row (not focusable), the game card (Resume, focus first), Home | Close game, the running strip
// (art tiles of the other running apps), Volume and the panel icons (Audio, Controllers, Performance, Power).
// Without a game: the strip, Volume and the icons. Controller keys only. Signs in as "Ada" (p2).
Item {
    id: host
    width: 1280
    height: 720

    // A 1080p screen inside the 720p test window (the fit test): the shell sizes itself from its parent.
    Item {
        id: bigHost
        width: 1920
        height: 1080
    }

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
            Keys.onPressed: event => event.accepted = true
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

        function start(parentItem) {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, parentItem ?? host)
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

        // Play on the hero (Turbo Racer), the answer, and the app's window: the app item is returned focused.
        function playRacer(component) {
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(component ?? appComponent, host)
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")
            return app
        }

        // Another game started for Ada, with its window: the newest window is in front.
        function launchOther(appId, component) {
            const n = launchedSpy.count
            Session.launch(appId, "p2")
            tryCompare(launchedSpy, "count", n + 1)
            tryVerify(() => Session.running.some(r => r.appId === appId && r.state === "running"))
            const app = createTemporaryObject(component ?? appComponent, host, { appId: appId })
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, appId + " is in front")
            return app
        }

        // Turbo Racer, Block Puzzle, then Pixel Hopper in front: two other apps run behind it.
        function threeGames(component) {
            const racer = playRacer(component)
            const puzzle = launchOther("org.example.Puzzle", component)
            const hopper = launchOther("org.example.Platformer", component)
            return { racer: racer, puzzle: puzzle, hopper: hopper }
        }

        function openHub() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
        }

        function focusedKey() {
            return find("systemPanel").currentKey
        }

        function goTo(key) {
            const menu = find("systemPanel")
            const list = find("systemActions")
            if (key === "switch" && !menu.powerMode) {
                // Switch profile is the last choice of the Power panel (T-471)
                goTo("panel:power")
                keyClick(Qt.Key_Return)
                tryCompare(menu, "powerMode", true)
            }
            // Up/Down to the control's row, then Left/Right along it (T-471: a row may hold several controls).
            for (let i = 0; i < 30 && menu.currentKey !== key; ++i)
                keyClick(menu.itemKeys.indexOf(menu.rowKeyOf(key)) > list.currentIndex ? Qt.Key_Down
                         : menu.itemKeys.indexOf(menu.rowKeyOf(key)) < list.currentIndex ? Qt.Key_Up
                         : menu.columnOf(key) > menu.currentColumn ? Qt.Key_Right : Qt.Key_Left)
            compare(focusedKey(), key)
            verify(find("quickMenuItem_" + key).focused, key + " has the focus ring")
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

        // ---- the rows, focus and Back --------------------------------------------------------------------

        function test_quick_hub_order() {
            start()
            const games = threeGames()
            openHub()
            verify(!games.hopper.activeFocus)
            const menu = find("systemPanel")
            compare(menu.itemKeys, ["resume", "leave", "running", "volume", "panels"],
                    "the game card, Home | Close game, the strip, Volume, the icons: five focus stops")
            compare(find("systemActions").count, 5)
            compare(focusedKey(), "resume")
            verify(find("quickMenuItem_resume").focused, "the game card has the focus on every open")
            compare(find("hubGameCard").title, "Pixel Hopper", "the game in front")
            // Down reaches every row in that order, one key press each, each on its first control.
            for (const key of ["home", "to:org.example.Racer", "volume", "panel:audio"]) {
                keyClick(Qt.Key_Down)
                compare(focusedKey(), key)
                verify(find("quickMenuItem_" + key).focused, key + " has the focus ring")
                verify(find("systemActions").activeFocus)
            }
            keyClick(Qt.Key_Down)
            compare(focusedKey(), "panel:audio", "the last row stays")
            // Back closes the Hub and gives the game its focus.
            keyClick(Qt.Key_Escape)
            tryVerify(() => games.hopper.activeFocus && !menu.open, 2000, "Back leaves the Hub")
            // The next open starts at the game card again.
            openHub()
            compare(focusedKey(), "resume")
            verify(find("quickMenuItem_resume").focused)
            keyClick(Qt.Key_Escape)
            tryVerify(() => games.hopper.activeFocus, 2000)
        }

        function test_guide_then_a_resumes_and_b_resumes() {
            start()
            const app = playRacer()
            keyClick(Qt.Key_HomePage)
            keyClick(Qt.Key_Return)                          // Guide then A, as fast as a player presses them
            tryVerify(() => app.activeFocus && !find("systemPanel").open, 2000, "A on the game card resumes")
            openHub()
            compare(focusedKey(), "resume")
            compare(hintVerbs(), "A Resume|B Resume")
            keyClick(Qt.Key_Escape)
            tryVerify(() => app.activeFocus && !find("systemPanel").open, 2000, "B resumes")
        }

        function test_left_and_right_move_inside_a_row_and_stop_at_the_ends() {
            start()
            const games = threeGames()
            openHub()
            goTo("home")
            keyClick(Qt.Key_Left)
            compare(focusedKey(), "home", "Left at the start stays")
            keyClick(Qt.Key_Right)
            compare(focusedKey(), "closeGame")
            verify(find("quickMenuItem_closeGame").focused && !find("quickMenuItem_home").focused)
            keyClick(Qt.Key_Right)
            compare(focusedKey(), "closeGame", "Right at the end stays")
            verify(find("systemPanel").open, "Left/Right never close the Hub")
            // The strip: Racer, then Puzzle, and it stops there.
            keyClick(Qt.Key_Down)
            compare(focusedKey(), "to:org.example.Racer")
            keyClick(Qt.Key_Right)
            compare(focusedKey(), "to:org.example.Puzzle")
            verify(find("quickMenuItem_to:org.example.Puzzle").focused && !find("quickMenuItem_to:org.example.Racer").focused)
            keyClick(Qt.Key_Right)
            compare(focusedKey(), "to:org.example.Puzzle", "the strip stops at its end")
            // The icons: Audio, Controllers, Performance, Power, and it stops there.
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            for (const key of ["panel:controllers", "panel:performance", "panel:power", "panel:power"]) {
                keyClick(Qt.Key_Right)
                compare(focusedKey(), key)
                verify(find("quickMenuItem_" + key).focused)
            }
            // Up and Down again: each row kept its column while the Hub is open.
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Up)
            compare(focusedKey(), "to:org.example.Puzzle")
            keyClick(Qt.Key_Up)
            compare(focusedKey(), "closeGame")
            // A new open starts every row on its first control.
            keyClick(Qt.Key_Escape)
            tryVerify(() => games.hopper.activeFocus, 2000)
            openHub()
            keyClick(Qt.Key_Down)
            compare(focusedKey(), "home")
            keyClick(Qt.Key_Down)
            compare(focusedKey(), "to:org.example.Racer")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            compare(focusedKey(), "panel:audio")
            keyClick(Qt.Key_Escape)
        }

        // At most five focus stops and no scrolling, at the sizes a TV is driven at (layout A, owner 2026-11-12).
        function test_the_hub_fits_on_one_screen_data() {
            return [{ tag: "720p", parentItem: host }, { tag: "1080p", parentItem: bigHost }]
        }
        function test_the_hub_fits_on_one_screen(data) {
            start(data.parentItem)
            threeGames()
            openHub()
            compare(tc.shell.height, data.parentItem.height)
            const menu = find("systemPanel")
            const list = find("systemActions")
            const panel = find("guidePanel")
            verify(list.count <= 5, "at most five focus stops: " + list.count)
            compare(list.count, 5, "the full Hub (a game, two others) is measured")
            tryCompare(menu, "settled", true)
            verify(list.contentHeight <= list.height + 0.5, "the rows fit: " + list.contentHeight + " in " + list.height)
            verify(!find("hubMoreBelow").needed && !find("hubMoreAbove").needed, "no scroll cue")
            const top = panel.mapToItem(tc.shell, 0, 0).y
            verify(top >= menu.marginY - 0.5, "the panel starts inside the safe area: " + top)
            verify(top + panel.height <= menu.height - menu.marginY - menu.bottomReserve + 0.5,
                   "and ends above the hint bar: " + (top + panel.height))
            // Every row is drawn inside the list.
            for (let i = 0; i < list.count; ++i) {
                const row = list.itemAtIndex(i)
                verify(row, "row " + i + " is built")
                const y = row.mapToItem(list, 0, 0).y
                verify(y >= -0.5 && y + row.height <= list.height + 0.5, menu.itemKeys[i] + " lies inside the list")
            }
            keyClick(Qt.Key_Escape)
        }

        function test_the_hub_without_a_game() {
            start()
            openHub()
            const menu = find("systemPanel")
            compare(menu.hasApp, false)
            compare(menu.itemKeys, ["volume", "panels"], "nothing runs: Volume and the icons")
            verify(!find("quickMenuItem_resume") && !find("hubGameCard"), "no game card")
            verify(!find("quickMenuItem_home") && !find("quickMenuItem_closeGame"), "no Home | Close game")
            verify(!find("quickMenuItem_running"), "no strip")
            tryVerify(() => find("hubStatus").visible, 2000, "the status row is there")
            compare(focusedKey(), "volume", "the focus starts on the first row there is")
            verify(find("quickMenuItem_volume").focused)
            compare(hintVerbs(), "A Mute|B Close")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !menu.open)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Back returns to Play")
        }

        function test_a_game_behind_home_puts_the_strip_first() {
            start()
            const app = playRacer()
            openHub()
            goTo("home")
            keyClick(Qt.Key_Return)
            tryVerify(() => !tc.shell.appOpen && !find("systemPanel").open, 2000, "Home")
            openHub()
            compare(find("systemPanel").itemKeys, ["running", "volume", "panels"])
            compare(focusedKey(), "to:org.example.Racer", "the focus starts on the strip")
            verify(find("quickMenuItem_to:org.example.Racer").focused)
            keyClick(Qt.Key_Return)
            tryVerify(() => app.activeFocus && !find("systemPanel").open, 2000, "A switches to it")
        }

        // ---- the running strip --------------------------------------------------------------------------

        function test_running_apps_show_their_art_and_a_switches() {
            Library.resetMockForTests("art:" + artFixtures)
            start()
            const games = threeGames()
            openHub()
            tryVerify(() => find("hubRunningStrip") !== null, 2000, "the strip is there with two other apps")
            const strip = find("hubRunningStrip")
            for (const id of ["org.example.Racer", "org.example.Puzzle"]) {
                const item = Library.items.find(i => Library.sessionAppId(i.id) === id)
                const art = findChild(find("quickMenuItem_to:" + id), "hubRunningArt")
                verify(art, id + " has a tile")
                verify(item.art.tile.length > 0)
                compare(art.picture, item.art.tile, id + "'s tile shows its Library card art")
                tryCompare(art, "imageStatus", Image.Ready)
            }
            verify(!find("hubRunningName").visible, "no name while the strip has no focus")
            goTo("to:org.example.Racer")
            const name = find("hubRunningName")
            verify(name.visible, "the focused tile's name is under it")
            compare(name.text, "Turbo Racer")
            compare(find("quickMenuItem_to:org.example.Racer").Accessible.name, "Switch to Turbo Racer")
            compare(hintVerbs(), "A Switch|B Resume")
            keyClick(Qt.Key_Right)
            compare(name.text, "Block Puzzle", "the name follows the focus")
            const tile = find("quickMenuItem_to:org.example.Puzzle")
            const centre = tile.mapToItem(strip, tile.width / 2, 0).x
            tryVerify(() => Math.abs(name.mapToItem(strip, name.width / 2, 0).x - centre) < 2, 2000, "the name is under that tile")
            keyClick(Qt.Key_Return)
            tryVerify(() => games.puzzle.activeFocus && !find("systemPanel").open, 2000, "A switches to Block Puzzle")
        }

        function test_the_strip_is_absent_with_one_app() {
            start()
            playRacer()
            openHub()
            compare(find("systemPanel").itemKeys, ["resume", "leave", "volume", "panels"])
            verify(!find("quickMenuItem_running") && !find("hubRunningStrip"), "no strip when nothing else runs")
            keyClick(Qt.Key_Escape)
        }

        // ---- the panel icons ------------------------------------------------------------------------------

        function test_the_panel_icons_open_their_panels_and_back_returns_to_the_icon_data() {
            return [{ tag: "audio", title: "Audio", icon: "volume_up" },
                    { tag: "controllers", title: "Controllers", icon: "sports_esports" },
                    { tag: "performance", title: "Performance", icon: "monitoring" },
                    { tag: "power", title: "Power", icon: "power_settings_new" }]
        }
        function test_the_panel_icons_open_their_panels_and_back_returns_to_the_icon(data) {
            start()
            const app = playRacer()
            openHub()
            const menu = find("systemPanel")
            const key = "panel:" + data.tag
            goTo(key)
            const icon = find("quickMenuItem_" + key)
            compare(icon.Accessible.name, data.title)
            compare(findChild(icon, "hubIconGlyph").name, data.icon)
            verify(findChild(icon, "hubIconGlyph").known, "the glyph is in the icon table")
            const name = find("hubIconName")
            verify(name.visible)
            compare(name.text, data.title, "the focused icon's name is under it")
            compare(hintVerbs(), "A Open|B Resume")
            keyClick(Qt.Key_Return)
            if (data.tag === "power")
                tryCompare(menu, "powerMode", true)
            else
                tryCompare(menu, "panelId", data.tag)
            compare(find("hubPanelTitle").text, data.title)
            verify(find("hubPanelTitle").visible)
            verify(find("systemActions").activeFocus)
            compare(find("systemActions").currentIndex, 0, "the panel's first row")
            keyClick(Qt.Key_Escape)
            tryVerify(() => menu.panelId === "" && !menu.powerMode, 2000, "Back leaves the panel")
            verify(menu.open, "and only the panel")
            compare(focusedKey(), key, "the focus is back on the icon")
            verify(find("quickMenuItem_" + key).focused)
            verify(find("systemActions").activeFocus)
            keyClick(Qt.Key_Escape)
            tryVerify(() => app.activeFocus && !menu.open, 2000)
        }

        function test_power_still_opens_the_choices_and_back_returns_to_the_hub() {
            start()
            openHub()
            goTo("panel:power")
            keyClick(Qt.Key_Return)
            const menu = find("systemPanel")
            tryCompare(menu, "powerMode", true)
            verify(find("systemActions").activeFocus)
            compare(menu.itemKeys.slice(-2), ["switch", "back"], "Switch profile is the last choice, before Back")
            goTo("back")
            keyClick(Qt.Key_Return)                          // the Back row
            tryCompare(menu, "powerMode", false)
            compare(focusedKey(), "panel:power", "the focus is on the icon that was opened")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !menu.open)
        }

        function test_switch_profile_is_in_the_power_panel() {
            start()
            openHub()
            goTo("switch")
            compare(find("quickMenuItem_switch").label, "Switch profile")
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker")
        }

        // ---- what left the Hub (owner, 2026-11-12) ---------------------------------------------------------

        function test_recent_tiles_display_and_switch_profile_are_gone_from_the_hub() {
            start()
            const games = threeGames()
            openHub()
            const menu = find("systemPanel")
            const controls = []
            for (const row of menu.itemKeys)
                controls.push(...menu.controlsOf(row))
            compare(controls, ["resume", "home", "closeGame", "to:org.example.Racer", "to:org.example.Puzzle",
                               "volume", "panel:audio", "panel:controllers", "panel:performance", "panel:power"],
                    "nothing else: no Recent, no tiles, no Display, no Switch profile")
            for (const gone of ["quickTile_wifi", "quickTile_bluetooth", "quickTile_mute", "quickTile_mic",
                                "quickMenuItem_panel:display", "quickMenuItem_switch", "quickMenuItem_close",
                                "quickMenuItem_recent:flatpak:org.example.Player", "quickMenuSystem"])
                compare(find(gone), null, gone + " is gone")
            keyClick(Qt.Key_Escape)
            tryVerify(() => games.hopper.activeFocus, 2000)
        }

        // ---- the status row ----------------------------------------------------------------------------------

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
            for (let i = 0; i < 6; ++i)
                keyClick(Qt.Key_Up)
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

        function test_the_a_hint_says_what_the_row_does() {
            start()
            threeGames()
            openHub()
            compare(hintVerbs(), "A Resume|B Resume")
            goTo("home")
            compare(hintVerbs(), "A Select|B Resume")
            goTo("closeGame")
            compare(hintVerbs(), "A Select|B Resume")
            goTo("to:org.example.Racer")
            compare(hintVerbs(), "A Switch|B Resume")
            goTo("volume")
            compare(hintVerbs(), "A Mute|B Resume")
            goTo("panel:controllers")
            compare(hintVerbs(), "A Open|B Resume")
            keyClick(Qt.Key_Escape)
        }

        // ---- Screenshots (dev.ps1 shots) ------------------------------------------------------------------

        function test_zz_screenshots_hub_over_the_app() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Library.resetMockForTests("art:" + artFixtures)
            start()
            threeGames(pictureAppComponent)
            Batteries.mockPopulate()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused, 2000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/hub-1-over-game.png")
            goTo("to:org.example.Puzzle")
            wait(400)
            grabImage(tc.shell).save(shotsDir + "/hub-2-strip.png")
            goTo("panel:performance")
            wait(400)
            grabImage(tc.shell).save(shotsDir + "/hub-4-icons.png")
            goTo("panel:power")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "powerMode", true)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/hub-5-power-panel.png")
        }

        function test_zz_screenshots_hub_without_an_app() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_volume").focused, 2000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/hub-3-no-app.png")
        }
    }
}
