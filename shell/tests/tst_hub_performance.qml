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
            const list = find("systemActions")
            return list.model[list.currentIndex]
        }

        function goTo(key) {
            for (let i = 0; i < 20 && focusedKey() !== key; ++i)
                keyClick(Qt.Key_Down)
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
            compare(focusedKey(), "performance:frames", "the focus lands on the first row")
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
            verify(!find("quickMenuApp").visible, "the panel replaces the app part")
            compare(find("systemPanel").itemKeys, ["performance:frames", "performance:cpu", "performance:gpu", "performance:ram",
                                                   "performance:vram", "performance:cputemp", "performance:gputemp",
                                                   "performance:power", "performance:interval"])
            compare(focusedKey(), "performance:frames")
            compare(find("quickMenuItem_performance:frames").Accessible.name.indexOf("Frames, "), 0)
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
            const keys = find("systemPanel").itemKeys
            verify(keys.indexOf("panel:audio") >= 0 && keys.indexOf("panel:audio") < keys.indexOf("panel:performance"))
            verify(keys.indexOf("panel:performance") < keys.indexOf("power"), "before Power")
            keyClick(Qt.Key_Escape)
        }

        // ---- polling only while the panel is open --------------------------------------------------------

        function test_polling_starts_when_the_panel_opens_and_stops_when_it_closes() {
            start()
            openHub()
            verify(!Performance.polling, "the Quick Hub does not ask for numbers")
            const before = Performance.pollCount
            goTo("panel:performance")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "performance")
            verify(Performance.polling, "the panel is a consumer")
            compare(Performance.consumers, 1)
            tryVerify(() => Performance.pollCount >= before + 3, 3000, "asked at once and then every 500 ms")
            // Back to the Quick Hub: nothing is asked any more.
            keyClick(Qt.Key_Escape)
            tryCompare(find("systemPanel"), "panelId", "")
            verify(!Performance.polling)
            const stopped = Performance.pollCount
            wait(1200)
            compare(Performance.pollCount, stopped, "nothing asked after Back")
            // Open again, then Guide closes the whole Hub: nothing is asked either.
            goTo("panel:performance")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "performance")
            verify(Performance.polling)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => !find("systemPanel").open, 2000)
            verify(!Performance.polling, "closing the Hub stops it")
            compare(Performance.consumers, 0)
        }

        function test_the_frames_are_counted_only_while_the_panel_is_open() {
            start()
            const surface = createTemporaryObject(surfaceComponent, host)
            const win = createTemporaryObject(windowComponent, host)
            Performance.frameWindow = win
            Performance.frameSource = surface
            openHub()
            verify(!Performance.counting, "the Quick Hub does not count frames")
            goTo("panel:performance")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "performance")
            verify(Performance.counting)
            keyClick(Qt.Key_Escape)
            tryCompare(find("systemPanel"), "panelId", "")
            verify(!Performance.counting, "Back disconnects the meter")
            keyClick(Qt.Key_Escape)
        }

        // ---- the four states of a value ---------------------------------------------------------------------

        // supported: the number.
        function test_a_measured_value_shows_its_number() {
            start()
            openPerformance()
            tryVerify(() => rowName("performance:cputemp") === "CPU temperature, 52 °C", 3000)
            tryVerify(() => rowName("performance:cpu") === "CPU, 24 %", 3000, "the second answer has the load: " + rowName("performance:cpu"))
            tryVerify(() => rowName("performance:gpu") === "GPU, 41 %", 3000)
            tryVerify(() => rowName("performance:ram") === "RAM, 3.2 GB of 8 GB", 3000)
            verify(valueOf("performance:cputemp") !== "")
            compare(valueText("performance:cputemp").color, Theme.text)
            keyClick(Qt.Key_Escape)
        }

        // unsupported: said plainly, in textDim.
        function test_an_unsupported_value_says_so_in_the_dim_colour() {
            start()
            openPerformance()
            tryVerify(() => Performance.valid && Performance.fresh, 3000)
            compare(rowName("performance:vram"), "VRAM, Not available on this console")
            compare(rowName("performance:gputemp"), "GPU temperature, Not available on this console")
            verify(!valueText("performance:vram").truncated, "the whole sentence is shown, not cut off")
            verify(!valueText("performance:gputemp").truncated)
            compare(valueText("performance:vram").color, Theme.textDim)
            // The frame meter without a compositor window (this host) is unsupported too.
            compare(Performance.frameState, "unsupported")
            compare(rowName("performance:frames"), "Frames, Not available on this console")
            keyClick(Qt.Key_Escape)
        }

        // unavailable: the first reading of a rate has nothing to compare with.
        function test_a_value_without_a_number_yet_says_measuring() {
            start()
            DeviceSettings.performanceIntervalMs = 5000       // the second answer is not due while we look
            openPerformance()
            tryVerify(() => Performance.fresh, 2000, "the first answer")
            compare(rowName("performance:cpu"), "CPU, Measuring...")
            compare(rowName("performance:gpu"), "GPU, Measuring...")
            compare(rowName("performance:power"), "Power, Measuring...")
            compare(rowName("performance:cputemp"), "CPU temperature, 52 °C", "a temperature has a number at once")
            compare(valueText("performance:cpu").color, Theme.text)
            keyClick(Qt.Key_Escape)
        }

        // The frames with a window and an app in front, but less than a second counted.
        function test_frames_say_measuring_before_a_whole_second() {
            start()
            const surface = createTemporaryObject(surfaceComponent, host)
            const win = createTemporaryObject(windowComponent, host)
            Performance.fakeFrameClockMs(1000)
            Performance.frameWindow = win
            Performance.frameSource = surface
            openPerformance()
            compare(Performance.frameState, "unavailable")
            compare(rowName("performance:frames"), "Frames, Measuring...")
            keyClick(Qt.Key_Escape)
        }

        // stale: the last good value, said to be old.
        function test_a_failed_reading_shows_the_last_value_marked_as_old() {
            start()
            openPerformance()
            tryVerify(() => rowName("performance:power") === "Power, 18.4 W (last reading)", 3000, "stale from the second answer: " + rowName("performance:power"))
            keyClick(Qt.Key_Escape)
        }

        function test_the_frame_numbers_of_the_app_in_front() {
            start()
            const surface = createTemporaryObject(surfaceComponent, host)
            const win = createTemporaryObject(windowComponent, host)
            Performance.fakeFrameClockMs(1000)
            Performance.frameWindow = win
            Performance.frameSource = surface
            openPerformance()
            // Two seconds at 60 Hz on the meter's test clock.
            let t = 1000
            for (let i = 1; i <= 120; ++i) {
                t = 1000 + i * 1000 / 60
                Performance.fakeFrameClockMs(t - 4)
                surface.redraw()
                Performance.fakeFrameClockMs(t)
                win.frameSwapped()
            }
            Performance.fakeFrameClockMs(t + 5)
            Performance.updateFrames()
            tryVerify(() => rowName("performance:frames") === "Frames, 60 FPS · 17 ms, slowest 17 ms", 2000, rowName("performance:frames"))
            verify(!valueText("performance:frames").truncated, "the whole line is shown")
            keyClick(Qt.Key_Escape)
        }

        // Held numbers are not shown as live (T-451 review).
        function test_numbers_held_before_a_failed_reading_are_not_shown_as_live() {
            start()
            openPerformance()
            tryVerify(() => rowName("performance:cputemp") === "CPU temperature, 52 °C", 3000)
            Performance.mockFail(true)
            tryVerify(() => rowName("performance:cputemp") === "CPU temperature, Measuring...", 3000, "the held 52 is gone: " + rowName("performance:cputemp"))
            compare(rowName("performance:vram"), "VRAM, Not available on this console", "a console without a source stays without one")
            Performance.mockFail(false)
            tryVerify(() => rowName("performance:cputemp") === "CPU temperature, 52 °C", 3000, "and the next answer is live again")
            keyClick(Qt.Key_Escape)
        }

        function test_the_first_open_after_idle_does_not_show_the_numbers_of_the_last_visit() {
            start()
            openPerformance()
            tryVerify(() => rowName("performance:cputemp") === "CPU temperature, 52 °C", 3000)
            keyClick(Qt.Key_Escape)
            tryCompare(find("systemPanel"), "panelId", "")
            verify(!Performance.polling)
            Performance.mockSet("cpu_temp", "supported", 71)       // what the console reads now
            Performance.mockReplyDelay(5000)                        // the answer is not here yet when the panel opens
            goTo("panel:performance")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "performance")
            compare(rowName("performance:cputemp"), "CPU temperature, Measuring...", "not the 52 of the visit before")
            verify(!Performance.fresh)
            Performance.mockReplyDelay(0)
            tryVerify(() => rowName("performance:cputemp") === "CPU temperature, 71 °C", 3000, "the fresh answer")
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

        function test_the_readings_take_focus_but_accept_does_nothing() {
            start()
            openPerformance()
            compare(hintVerbs(), "B Back", "nothing to press on a reading")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            compare(focusedKey(), "performance:frames")
            compare(find("systemPanel").panelId, "performance")
            compare(DeviceSettings.performanceIntervalMs, 500)
            keyClick(Qt.Key_Down)
            compare(focusedKey(), "performance:cpu", "Down walks the rows")
            verify(find("systemActions").activeFocus)
            keyClick(Qt.Key_Escape)
        }

        function test_every_row_is_reachable_and_clear_of_the_fade() {
            start()
            openPerformance()
            const box = find("systemActions").parent
            const fade = find("hubMoreBelow").height
            for (let i = 0; i < 9; ++i) {
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
            // The first answer: the rates are not measurable yet, VRAM and GPU temperature are unsupported.
            DeviceSettings.performanceIntervalMs = 5000
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused, 2000)
            goTo("panel:performance")
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/hub-performance-1-entry.png")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "performance")
            tryCompare(find("systemPanel"), "swap", 1)
            tryVerify(() => Performance.fresh, 2000)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-performance-2-measuring.png")
            // Every state at once: frames measured, CPU and temperature supported, GPU measuring, VRAM and
            // GPU temperature unsupported, power the last reading.
            DeviceSettings.performanceIntervalMs = 500
            const surface = createTemporaryObject(surfaceComponent, host)
            const win = createTemporaryObject(windowComponent, host)
            Performance.fakeFrameClockMs(1000)
            Performance.frameWindow = win
            Performance.frameSource = surface
            let t = 1000
            for (let i = 1; i <= 120; ++i) {
                t = 1000 + i * 1000 / 60
                Performance.fakeFrameClockMs(t - 4)
                surface.redraw()
                Performance.fakeFrameClockMs(t)
                win.frameSwapped()
            }
            Performance.fakeFrameClockMs(t + 5)
            Performance.updateFrames()
            Performance.mockSet("gpu_percent", "unavailable", 0)
            tryVerify(() => rowName("performance:cpu") === "CPU, 24 %" && rowName("performance:gpu") === "GPU, Measuring..."
                            && rowName("performance:power") === "Power, 18.4 W (last reading)", 3000)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-performance-3-states.png")
            goTo("performance:interval")
            keyClick(Qt.Key_Right)
            tryCompare(DeviceSettings, "performanceIntervalMs", 1000)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-performance-4-interval.png")
        }
    }
}
