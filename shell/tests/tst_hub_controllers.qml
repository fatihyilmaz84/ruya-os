import QtQuick
import QtTest
import RuyaShell

// The Controllers panel of Ruya Hub (T-453, 02 §1.6): from the Quick Hub's Controllers entry the player
// sees every connected pad with its battery and how it is connected, and "Controller settings" opens
// Settings (leaving the Hub). Mock backends; signs in as "Ada" (p2), controller keys only.
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
        name: "HubControllers"
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
            Bluetooth.mockReset()
            Batteries.mockClear()
            launchedSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
            Batteries.mockReset()
            Bluetooth.mockReset()
        }

        // No controller connected: the mock's one paired pad goes, the batteries are empty.
        function noPads() {
            Bluetooth.disconnectDevice("bt-pad-main")
            tryVerify(() => Bluetooth.gamepads.length === 0)
        }

        // A wired pad, as the service lists it (ListGamepads).
        function plugIn(id, name, family) {
            Bluetooth.mockGamepad(true, id, name, family, "usb")
            tryVerify(() => Bluetooth.gamepads.some(g => g.id === id))
        }

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

        // The Hub, then the Controllers panel; the focus is on its first row.
        function openControllers() {
            openHub()
            goTo("panel:controllers")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "controllers")
            tryCompare(find("systemPanel"), "swap", 1)
            verify(find("systemActions").activeFocus)
        }

        function rowName(key) { return find("quickMenuItem_" + key).Accessible.name }
        function padKeys() { return find("systemPanel").itemKeys.filter(k => k.startsWith("controllers:pad:")) }

        function hintVerbs() {
            const bar = find("hintBar")
            const parts = []
            for (const b of ["A", "Left/Right", "B"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        // ---- the entry, in the order of the spec -----------------------------------------------------------

        function test_the_entry_sits_between_audio_and_performance_and_back_returns_to_it() {
            start()
            const app = playRacer()
            openHub()
            const keys = find("systemPanel").controlsOf("panels")       // the panel icons (T-471)
            verify(keys.indexOf("panel:audio") < keys.indexOf("panel:controllers"))
            verify(keys.indexOf("panel:controllers") < keys.indexOf("panel:performance"))
            goTo("panel:controllers")
            compare(find("quickMenuItem_panel:controllers").Accessible.name, "Controllers")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "controllers")
            compare(find("hubPanelTitle").text, "Controllers")
            verify(!find("hubGameCard"), "the panel replaces the game card")
            // Back: the Quick Hub again, the focus on the entry that was opened; the Hub stays open.
            keyClick(Qt.Key_Escape)
            tryCompare(find("systemPanel"), "panelId", "")
            verify(find("systemPanel").open)
            compare(focusedKey(), "panel:controllers")
            verify(find("quickMenuItem_panel:controllers").focused)
            keyClick(Qt.Key_Escape)
            tryVerify(() => app.activeFocus && !find("systemPanel").open, 2000, "Back in the Hub resumes the game")
        }

        // ---- two pads: their battery and connection -----------------------------------------------------------

        function test_two_pads_show_two_rows_with_battery_and_connection() {
            start()
            noPads()
            Bluetooth.mockTwoPads()                                    // two connected Bluetooth pads, 80 % and 55 %
            plugIn("usb-1", "Xbox Controller", "xbox")                 // a wired pad
            Batteries.mockSet("up-usb", 100, "full", "controller", "Xbox Wireless Controller", "xbox")   // UPower: no address
            tryVerify(() => Batteries.devices.length === 1)
            openControllers()
            compare(padKeys().length, 3)
            compare(find("systemPanel").itemKeys.length, 4, "three pads and Controller settings")
            compare(find("systemPanel").itemKeys[3], "controllers:settings")
            compare(rowName("controllers:pad:aa:00:00:00:00:04"), "Wireless Controller (00:04), Battery 80 % · Bluetooth")
            compare(rowName("controllers:pad:aa:00:00:00:00:05"), "Wireless Controller (00:05), Battery 55 % · Bluetooth")
            compare(rowName("controllers:pad:usb-1"), "Xbox Controller, Battery full · USB")
            // The family glyph of each.
            compare(findChild(find("quickMenuItem_controllers:pad:usb-1"), "hubInfoIcon").name, "pad_xbox")
            compare(findChild(find("quickMenuItem_controllers:pad:aa:00:00:00:00:04"), "hubInfoIcon").name, "pad_playstation")
            // The readings are in `text`, never `textDim` (04 §7), and take focus so Up/Down walk them.
            compare(findChild(find("quickMenuItem_controllers:pad:usb-1"), "hubInfoValue").color, Theme.text)
            compare(focusedKey(), padKeys()[0], "the focus lands on the first pad")
            compare(hintVerbs(), "B Back", "a reading has nothing to press")
            keyClick(Qt.Key_Return)
            compare(find("systemPanel").panelId, "controllers", "Accept on a reading does nothing")
            keyClick(Qt.Key_Escape)
        }

        function test_charging_and_an_unreported_battery_say_so_in_words() {
            start()
            noPads()
            plugIn("usb-2", "DualSense", "playstation")
            Batteries.mockSet("up-2", 40, "charging", "controller", "DualSense Wireless Controller", "playstation")
            Batteries.mockSet("up-3", 70, "discharging", "headset", "Headset")      // not a pad: not listed
            Bluetooth.mockSetBattery("bt-pad-old", -1)
            Bluetooth.connectDevice("bt-pad-old")
            tryVerify(() => Bluetooth.gamepads.length === 2)
            openControllers()
            compare(padKeys().length, 2)
            compare(rowName("controllers:pad:usb-2"), "DualSense, Battery 40 %, charging · USB")
            compare(rowName("controllers:pad:bt-pad-old"), "Retro Pad, Battery not reported · Bluetooth")
            keyClick(Qt.Key_Escape)
        }

        // A wired pad that has neither a UPower battery nor a Bluetooth entry is still a pad: one row, USB, no reading.
        function test_a_wired_pad_with_no_battery_and_no_bluetooth_entry_is_listed() {
            start()
            noPads()
            plugIn("usb-9", "Generic USB Pad", "")
            compare(Batteries.devices.length, 0)
            verify(!Bluetooth.devices.some(d => d.connected && d.kind === "controller"))
            openControllers()
            compare(padKeys(), ["controllers:pad:usb-9"])
            compare(rowName("controllers:pad:usb-9"), "Generic USB Pad, Battery not reported · USB")
            compare(findChild(find("quickMenuItem_controllers:pad:usb-9"), "hubInfoIcon").name, "sports_esports")
            keyClick(Qt.Key_Escape)
        }

        // The mock's default state is one pad and one row (the battery and the paired device share an address).
        function test_the_default_mock_state_shows_one_row_per_pad() {
            start()
            Batteries.mockReset()
            tryVerify(() => Bluetooth.gamepads.length === 1)
            openControllers()
            compare(padKeys().length, 1)
            compare(rowName(padKeys()[0]), "Ruya Pad Pro, Battery 60 % · Bluetooth")
            keyClick(Qt.Key_Escape)
        }

        // A Bluetooth pad that the batteries list too is one row, not two (the address ties them).
        function test_a_pad_in_both_lists_is_one_row_with_its_battery() {
            start()
            noPads()
            Bluetooth.mockTwoPads()
            Batteries.mockSet("up-1", 63, "discharging", "controller", "Wireless Controller", "playstation", "AA:00:00:00:00:04")
            tryVerify(() => Batteries.devices.length === 1)
            openControllers()
            compare(padKeys().length, 2)
            compare(rowName("controllers:pad:aa:00:00:00:00:04"), "Wireless Controller (00:04), Battery 63 % · Bluetooth",
                    "the battery list's reading wins, the paired device's alias names it")
            keyClick(Qt.Key_Escape)
        }

        // ---- none connected: one line that says so ------------------------------------------------------------

        function test_none_connected_says_so_in_one_line() {
            start()
            noPads()
            openControllers()
            compare(padKeys().length, 0)
            compare(find("systemPanel").itemKeys, ["controllers:none", "controllers:settings"])
            const line = find("quickMenuItem_controllers:none")
            compare(line.Accessible.name, "No controllers connected.")
            compare(findChild(line, "hubInfoLabel").text, "No controllers connected.")
            verify(!findChild(line, "hubInfoValue").visible, "one line, no second one")
            compare(findChild(line, "hubInfoLabel").color, Theme.text)
            verify(!findChild(line, "hubInfoIcon").visible)
            keyClick(Qt.Key_Escape)
        }

        // ---- no mapping, profile or slot controls (Ruya Input is not built) -------------------------------------------

        function test_the_panel_has_no_mapping_profile_or_slot_controls() {
            start()
            Bluetooth.mockTwoPads()
            openControllers()
            for (const k of find("systemPanel").itemKeys)
                verify(k.startsWith("controllers:pad:") || k === "controllers:settings" || k === "controllers:none", k)
            keyClick(Qt.Key_Escape)
        }

        // ---- a pad that goes while the panel is open ------------------------------------------------------------------

        function test_a_pad_that_disconnects_leaves_the_panel_and_the_focus_stays_in_it() {
            start()
            noPads()
            Bluetooth.mockTwoPads()
            plugIn("usb-1", "Xbox Controller", "xbox")
            openControllers()
            compare(padKeys().length, 3)
            // Focus the wired pad (the last pad row: sorted by name, "Wireless" before "Xbox"), then pull it out.
            goTo("controllers:pad:usb-1")
            Bluetooth.mockGamepad(false, "usb-1", "Xbox Controller", "xbox", "usb")
            tryVerify(() => padKeys().length === 2, 2000, "the pad's row is gone")
            verify(find("systemActions").activeFocus, "the list still has the focus")
            compare(find("systemPanel").panelId, "controllers", "still in the panel")
            compare(focusedKey(), "controllers:settings", "the focus moved to the next row, not out of the panel")
            verify(find("quickMenuItem_controllers:settings").focused)
            // A Bluetooth pad disconnects while another row has the focus: the focus stays where it was.
            keyClick(Qt.Key_Up)
            const kept = focusedKey()
            verify(kept.startsWith("controllers:pad:aa:00:00:00:00:05"))
            Bluetooth.disconnectDevice("AA:00:00:00:00:04")
            tryVerify(() => padKeys().length === 1, 2000)
            compare(focusedKey(), kept, "the focused pad stays focused")
            verify(find("systemActions").activeFocus)
            // The last one goes: the one line appears and the focus is still in the panel.
            Bluetooth.disconnectDevice("AA:00:00:00:00:05")
            tryVerify(() => find("systemPanel").itemKeys.indexOf("controllers:none") === 0, 2000)
            compare(find("systemPanel").panelId, "controllers")
            verify(find("systemActions").activeFocus)
            verify(["controllers:none", "controllers:settings"].indexOf(focusedKey()) >= 0)
            keyClick(Qt.Key_Escape)
            tryCompare(find("systemPanel"), "panelId", "")
        }

        // A pad that connects while the panel is open appears, the focus does not move.
        function test_a_pad_that_connects_appears_without_moving_the_focus() {
            start()
            noPads()
            openControllers()
            keyClick(Qt.Key_Down)
            compare(focusedKey(), "controllers:settings")
            Bluetooth.mockGamepad(true, "usb-1", "Xbox Controller", "xbox", "usb")
            tryVerify(() => padKeys().length === 1, 2000)
            compare(focusedKey(), "controllers:settings", "the focus stays on the row it was on")
            verify(find("quickMenuItem_controllers:settings").focused)
            keyClick(Qt.Key_Escape)
        }

        // A reading follows the battery in place.
        function test_a_battery_reading_follows_the_pad() {
            start()
            noPads()
            plugIn("usb-1", "Xbox Controller", "xbox")
            Batteries.mockSet("up-1", 55, "discharging", "controller", "Xbox Wireless Controller", "xbox")
            openControllers()
            compare(rowName("controllers:pad:usb-1"), "Xbox Controller, Battery 55 % · USB")
            Batteries.mockSet("up-1", 14, "discharging")
            tryCompare(find("quickMenuItem_controllers:pad:usb-1"), "objectName", "quickMenuItem_controllers:pad:usb-1")
            tryVerify(() => rowName("controllers:pad:usb-1") === "Xbox Controller, Battery 14 % · USB", 2000)
            compare(focusedKey(), "controllers:pad:usb-1")
            keyClick(Qt.Key_Escape)
        }

        // ---- Controller settings -----------------------------------------------------------------------------------------

        function test_controller_settings_leaves_the_hub_for_the_settings_pane() {
            start()
            const app = playRacer()
            openControllers()
            goTo("controllers:settings")
            compare(hintVerbs(), "A Open|B Back")
            keyClick(Qt.Key_Return)
            tryVerify(() => !find("systemPanel").open, 2000, "the Hub closes")
            tryVerify(() => find("page_settings") !== null, 2000, "Settings opens")
            compare(find("page_settings").current.key, "bluetooth", "on Bluetooth & controllers")
            verify(!app.activeFocus, "the game does not get the focus back; Settings has it")
            tryVerify(() => find("page_settings").activeFocus, 2000, "Settings has the focus")
            // Back leaves Settings for Home (the game keeps running behind it).
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("page_settings") === null, 2000)
            tryVerify(() => find("homePlay") !== null && find("homePlay").visible, 2000)
            compare(Session.running.length, 1, "the game still runs")
        }

        function test_controller_settings_from_home_without_a_game() {
            start()
            openControllers()
            goTo("controllers:settings")
            keyClick(Qt.Key_Return)
            tryVerify(() => !find("systemPanel").open, 2000)
            tryVerify(() => find("page_settings") !== null, 2000)
            compare(find("page_settings").current.key, "bluetooth")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("page_settings") === null, 2000)
        }

        // ---- Screenshots (dev.ps1 shots) ------------------------------------------------------------------------------------

        function test_zz_screenshots_hub_controllers_panel() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            noPads()
            Bluetooth.mockTwoPads()
            plugIn("usb-1", "Xbox Controller", "xbox")
            Batteries.mockSet("up-usb", 100, "full", "controller", "Xbox Wireless Controller", "xbox")
            Batteries.mockSet("up-1", 14, "discharging", "controller", "Wireless Controller", "playstation", "AA:00:00:00:00:04")
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(pictureAppComponent, host)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused, 2000)
            goTo("panel:controllers")
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/hub-controllers-1-entry.png")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "controllers")
            tryCompare(find("systemPanel"), "swap", 1)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-controllers-2-pads.png")
            goTo("controllers:settings")
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/hub-controllers-3-settings.png")
            // None connected.
            Batteries.mockClear()
            Bluetooth.mockGamepad(false, "usb-1", "Xbox Controller", "xbox", "usb")
            Bluetooth.disconnectDevice("AA:00:00:00:00:04")
            Bluetooth.disconnectDevice("AA:00:00:00:00:05")
            tryVerify(() => find("systemPanel").itemKeys.indexOf("controllers:none") === 0, 2000)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-controllers-4-none.png")
        }
    }
}
