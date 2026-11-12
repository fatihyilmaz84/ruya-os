import QtQuick
import QtTest
import RuyaShell

// The Performance panel of Ruya Hub (T-452, 02 §1.6): from the Quick Hub's Performance entry the player
// reads FPS, frame time, CPU, GPU, RAM, VRAM, temperatures and power, and each value that is not a
// measured number says why (unsupported, measuring, last reading). The service is asked and the frames
// counted only while the panel is open. Mock backend; signs in as "Ada" (p2), controller keys only.
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

    // A Wayland surface and the shell's window as the frame meter sees them (tst_performance.qml).
    Component { id: surfaceComponent; QtObject { signal redraw() } }
    Component { id: windowComponent; QtObject { signal frameSwapped() } }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }

    TestCase {
        id: tc
        name: "HubPerformance"
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
            DeviceSettings.performanceIntervalMs = 500
            Library.resetMockForTests("")
            Session.mockReset()
            Audio.mockReset()
            Performance.mockReset()
            Performance.mockReplyDelay(0)
            launchedSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.performanceIntervalMs = 1000
            Performance.frameSource = null
            Performance.frameWindow = null
            Performance.fakeFrameClockMs(-1)
            Performance.mockFail(false)
            Performance.mockReplyDelay(0)
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

        // The Hub, then the Performance panel; the focus is on its first row.
        function openPerformance() {
            openHub()
            goTo("panel:performance")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "performance")
            tryCompare(find("systemPanel"), "swap", 1)
            compare(focusedKey(), "performance:overlay", "the focus lands on the first row")
            verify(find("systemActions").activeFocus)
        }

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

        function rowName(key) { return find("quickMenuItem_" + key).Accessible.name }
        // The value part of a row (the accessible name is "<label>, <value>").
        function valueText(key) { return findChild(find("quickMenuItem_" + key), "hubInfoValue") }
        function valueOf(key) { return valueText(key).text }

        // ---- the entry, the rows and Back ---------------------------------------------------------------

        function test_the_entry_opens_the_panel_and_back_returns_to_it() {
            start()
            const app = playRacer()
            openHub()
            goTo("panel:performance")
            compare(find("quickMenuItem_panel:performance").Accessible.name, "Performance")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "performance")
            const title = find("hubPanelTitle")
            verify(title.visible)
            compare(title.text, "Performance")
            verify(!find("hubGameCard"), "the panel replaces the game card")
            compare(find("systemPanel").itemKeys, ["performance:overlay", "performance:interval"])
            compare(focusedKey(), "performance:overlay")
            compare(find("quickMenuItem_performance:overlay").Accessible.name.indexOf("Performance overlay, "), 0)
            // Back: the Quick Hub again, on the entry that was opened; the Hub stays open.
            keyClick(Qt.Key_Escape)
            tryCompare(find("systemPanel"), "panelId", "")
            verify(find("systemPanel").open, "Back left only the panel")
            compare(focusedKey(), "panel:performance", "the focus is on the entry")
            verify(find("quickMenuItem_panel:performance").focused)
            // Back in the Quick Hub resumes the game.
            keyClick(Qt.Key_Escape)
            tryVerify(() => app.activeFocus && !find("systemPanel").open, 2000, "Back leaves the Hub")
        }

        function test_the_entries_come_in_the_order_of_the_spec() {
            start()
            openHub()
            const keys = find("systemPanel").controlsOf("panels")       // the panel icons (T-471)
            verify(keys.indexOf("panel:audio") >= 0 && keys.indexOf("panel:audio") < keys.indexOf("panel:performance"))
            verify(keys.indexOf("panel:performance") < keys.indexOf("panel:power"), "before Power")
            keyClick(Qt.Key_Escape)
        }

        // ---- the interval -------------------------------------------------------------------------------------

        function test_the_interval_row_changes_how_often_the_service_is_asked() {
            start()
            openPerformance()
            for (let i = 0; i < 20 && focusedKey() !== "performance:interval"; ++i)
                keyClick(Qt.Key_Down)
            compare(focusedKey(), "performance:interval")
            compare(hintVerbs(), "A Next|Left/Right Change|B Back")
            compare(rowName("performance:interval"), "Update every, 0.5 s")
            keyClick(Qt.Key_Right)
            tryCompare(DeviceSettings, "performanceIntervalMs", 1000)
            compare(rowName("performance:interval"), "Update every, 1 s")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(DeviceSettings, "performanceIntervalMs", 5000)
            tryCompare(Performance, "intervalMs", 5000)
            keyClick(Qt.Key_Return)                              // wraps to the shortest
            tryCompare(DeviceSettings, "performanceIntervalMs", 500)
            keyClick(Qt.Key_Left)
            tryCompare(DeviceSettings, "performanceIntervalMs", 5000)
            verify(find("systemActions").activeFocus && focusedKey() === "performance:interval")
            keyClick(Qt.Key_Escape)
        }

        function test_the_panel_has_the_switch_and_the_interval_and_no_readings() {
            start()
            openPerformance()
            compare(find("systemPanel").itemKeys, ["performance:overlay", "performance:interval"])
            verify(!find("quickMenuItem_performance:cpu"), "no reading rows")
            verify(!Performance.polling, "the panel asks for nothing: the game is frozen, the overlay shows the numbers")
            verify(!Performance.counting)
            compare(hintVerbs(), "A Toggle|B Back")
            compare(rowName("performance:overlay"), "Performance overlay, Off")
            keyClick(Qt.Key_Escape)
        }

        function test_the_switch_is_stored_for_the_profile() {
            start()
            openPerformance()
            verify(!DeviceSettings.performanceOverlay("p2"))
            keyClick(Qt.Key_Return)
            tryVerify(() => DeviceSettings.performanceOverlay("p2"), 2000, "Accept turns it on")
            compare(rowName("performance:overlay"), "Performance overlay, On")
            verify(!DeviceSettings.performanceOverlay("p1"), "another profile is not touched")
            compare(focusedKey(), "performance:overlay")
            verify(find("systemActions").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => !DeviceSettings.performanceOverlay("p2"), 2000, "and off again")
            compare(rowName("performance:overlay"), "Performance overlay, Off")
            keyClick(Qt.Key_Escape)
        }


        function test_every_row_is_reachable_and_clear_of_the_fade() {
            start()
            openPerformance()
            const box = find("systemActions").parent
            const fade = find("hubMoreBelow").height
            for (let i = 0; i < 2; ++i) {
                const row = find("quickMenuItem_" + focusedKey())
                const top = row.mapToItem(box, 0, 0).y
                verify(top >= -1 && top + row.height <= box.height + 1, focusedKey() + " is inside the list: " + top + " of " + box.height)
                if (find("hubMoreBelow").needed)
                    verify(top + row.height <= box.height - fade + 1, focusedKey() + " ends above the lower fade")
                keyClick(Qt.Key_Down)
            }
            compare(focusedKey(), "performance:interval")
            keyClick(Qt.Key_Escape)
        }

        // ---- Screenshots (dev.ps1 shots) ------------------------------------------------------------------

        function test_zz_screenshots_hub_performance_panel() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(pictureAppComponent, host)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused, 2000)
            goTo("panel:performance")
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/hub-performance-1-entry.png")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "performance")
            tryCompare(find("systemPanel"), "swap", 1)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-performance-2-off.png")
            keyClick(Qt.Key_Return)
            tryVerify(() => DeviceSettings.performanceOverlay("p2"), 2000)
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/hub-performance-3-on.png")
            goTo("performance:interval")
            keyClick(Qt.Key_Right)
            tryCompare(DeviceSettings, "performanceIntervalMs", 1000)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-performance-4-interval.png")
        }
    }
}
