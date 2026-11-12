import QtQuick
import QtTest
import RuyaShell

// The performance overlay (T-469, 02 §1.6, 04 §5): with the switch on (Ruya Hub -> Performance, per profile)
// and a game in front, the shell draws FPS and frame time top left and CPU, GPU, RAM, VRAM, temperatures and
// power top right. It takes no focus and no key, hides under the Hub, the splash, a toast in its corner and
// Home, and the service is asked only while it is shown. Mock backend; signs in as "Ada" (p2).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A window of an app that takes every key, like a game, and remembers the last one.
    Component {
        id: appComponent
        Item {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            property int lastKey: 0
            property int keys: 0
            Keys.onPressed: event => { lastKey = event.key; keys += 1; event.accepted = true }
        }
    }

    // A "game" with something to look at behind the overlay (screenshots).
    Component {
        id: pictureAppComponent
        Rectangle {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            color: "steelblue"
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: parent.height / 3; color: "darkgreen" }
            Rectangle { x: parent.width * 0.55; y: parent.height * 0.2; width: parent.width * 0.2; height: width; radius: width / 2; color: "gold" }
            Rectangle { x: 0; y: 0; width: parent.width * 0.4; height: parent.height * 0.15; color: "white" }       // the worst case under the left corner
            Rectangle { x: parent.width * 0.6; y: 0; width: parent.width * 0.4; height: parent.height * 0.3; color: "white" }
        }
    }

    Component { id: surfaceComponent; QtObject { signal redraw() } }
    Component { id: windowComponent; QtObject { signal frameSwapped() } }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }

    TestCase {
        id: tc
        name: "PerfOverlay"
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
            DeviceSettings.setPerformanceOverlay("p2", false)
            DeviceSettings.setPerformanceOverlay("p1", false)
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
            DeviceSettings.setPerformanceOverlay("p2", false)
            DeviceSettings.setPerformanceOverlay("p1", false)
            Performance.frameSource = null
            Performance.frameWindow = null
            Performance.fakeFrameClockMs(-1)
            Performance.mockFail(false)
            Performance.mockReplyDelay(0)
        }

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

        function overlay() { return find("perfOverlay") }
        function leftBlock() { return find("perfOverlayLeft") }
        function rightBlock() { return find("perfOverlayRight") }
        function line(name) { return find("perfOverlay" + name).text }
        function drawn() { return overlay().visible && (leftBlock().visible || rightBlock().visible) }

        function frameStand() {
            const surface = createTemporaryObject(surfaceComponent, host)
            const win = createTemporaryObject(windowComponent, host)
            Performance.fakeFrameClockMs(1000)
            Performance.frameWindow = win
            Performance.frameSource = surface
            return { surface: surface, win: win }
        }
        // Two seconds at 60 Hz on the meter's test clock.
        function drive60(stand) {
            let t = 1000
            for (let i = 1; i <= 120; ++i) {
                t = 1000 + i * 1000 / 60
                Performance.fakeFrameClockMs(t - 4)
                stand.surface.redraw()
                Performance.fakeFrameClockMs(t)
                stand.win.frameSwapped()
            }
            Performance.fakeFrameClockMs(t + 5)
            Performance.updateFrames()
        }

        function openHub() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
        }

        // ---- the switch -----------------------------------------------------------------------------------

        function test_the_switch_persists_per_profile() {
            compare(overlayPersistence, "")
        }

        function test_a_deleted_profile_loses_its_switch() {
            start()
            DeviceSettings.setPerformanceOverlay("p3", true)
            Profiles.deleteProfile("p1", "1234", "p3")
            tryVerify(() => !DeviceSettings.performanceOverlay("p3"), 2000, "the Guest profile is gone, so is its switch")
            tryVerify(() => Profiles.profiles.length === 2)
            Profiles.resetMockForTests("")
            tryVerify(() => Profiles.profiles.length === 3)
        }

        // ---- when it is drawn ---------------------------------------------------------------------------------

        function test_off_nothing_is_drawn_and_nothing_is_asked() {
            start()
            playRacer()
            verify(!drawn(), "the switch is off")
            verify(!Performance.polling)
            const before = Performance.pollCount
            wait(1200)
            compare(Performance.pollCount, before, "no polling while off")
            verify(!Performance.counting)
        }

        function test_on_with_a_game_in_front_both_corners_are_drawn() {
            start()
            playRacer()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => drawn(), 2000)
            verify(leftBlock().visible && rightBlock().visible)
            verify(Performance.polling)
            // inside the safe area, in the top corners
            compare(leftBlock().mapToItem(tc.shell, 0, 0).x, tc.shell.marginX)
            compare(leftBlock().mapToItem(tc.shell, 0, 0).y, tc.shell.marginY)
            compare(rightBlock().mapToItem(tc.shell, rightBlock().width, 0).x, tc.shell.width - tc.shell.marginX)
            compare(rightBlock().mapToItem(tc.shell, 0, 0).y, tc.shell.marginY)
            verify(leftBlock().x < tc.shell.width / 2 && rightBlock().x > tc.shell.width / 2)
            // the switch is the signed-in profile's
            DeviceSettings.setPerformanceOverlay("p2", false)
            tryVerify(() => !drawn(), 2000)
            DeviceSettings.setPerformanceOverlay("p1", true)
            wait(200)
            verify(!drawn(), "another profile's switch does not show it")
        }

        function test_home_shows_nothing_and_asks_for_nothing() {
            start()
            DeviceSettings.setPerformanceOverlay("p2", true)
            wait(300)
            verify(!drawn(), "Home")
            verify(!Performance.polling)
            const before = Performance.pollCount
            wait(1200)
            compare(Performance.pollCount, before)
            const app = playRacer()
            tryVerify(() => drawn(), 2000, "a game in front")
            tc.shell.sendAppsHome()
            tryVerify(() => !drawn(), 2000, "the game sent behind Home")
            verify(!Performance.polling)
            tc.shell.focusApp(app)
            tryVerify(() => drawn(), 2000, "and back")
        }

        function test_the_hub_hides_it_and_stops_the_asking() {
            start()
            playRacer()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => drawn(), 2000)
            tryVerify(() => Performance.pollCount > 0, 2000)
            openHub()
            verify(!drawn(), "the Hub is open")
            verify(!Performance.polling)
            verify(!Performance.counting)
            const before = Performance.pollCount
            wait(1200)
            compare(Performance.pollCount, before, "nothing asked under the Hub")
            keyClick(Qt.Key_Escape)
            tryVerify(() => drawn(), 2000, "back in the game")
            verify(Performance.polling)
        }

        function test_the_splashes_hide_it() {
            start()
            playRacer()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => drawn(), 2000)
            tc.shell.launchState = { appId: "org.example.Other", title: "Other", picture: "", profile: "p2", ok: false,
                                     instance: "", slow: false, restore: null }
            tryVerify(() => !drawn(), 2000, "the launch splash")
            verify(!Performance.polling)
            tc.shell.launchState = null
            tryVerify(() => drawn(), 2000)
            tc.shell.closeState = { instance: "x", appId: "org.example.Racer", title: "Racer", picture: "" }
            tryVerify(() => !drawn(), 2000, "the closing splash")
            verify(!Performance.polling)
            tc.shell.closeState = null
            tryVerify(() => drawn(), 2000)
        }

        function test_a_toast_in_the_corner_hides_the_right_block_only() {
            start()
            playRacer()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => drawn() && rightBlock().visible, 2000)
            Notifications.show("Hello", "warning")   // only errors and warnings are drawn over a game
            tryVerify(() => !rightBlock().visible, 2000, "the toast stack is in the top right")
            verify(leftBlock().visible, "the left corner is clear")
            verify(Performance.polling)
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            tryVerify(() => rightBlock().visible, 3000, "the toast is gone")
        }

        function test_it_is_asked_at_the_chosen_interval_only_while_shown() {
            start()
            playRacer()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => Performance.pollCount >= 3, 3000, "every 500 ms")
            compare(Performance.consumers, 1)
            DeviceSettings.performanceIntervalMs = 5000
            tryCompare(Performance, "intervalMs", 5000)
            tryVerify(() => Performance.fresh, 2000)
            const before = Performance.pollCount
            wait(1500)
            compare(Performance.pollCount, before, "5 s apart now")
            DeviceSettings.setPerformanceOverlay("p2", false)
            tryCompare(Performance, "consumers", 0)
        }

        // ---- the four states of a value ---------------------------------------------------------------------------

        // supported: the number.
        function test_a_measured_value_shows_its_number() {
            start()
            playRacer()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => line("CpuTemp") === "CPU temperature: 52 °C", 3000, line("CpuTemp"))
            tryVerify(() => line("Cpu") === "CPU: 24 %", 3000, "the second answer has the load: " + line("Cpu"))
            tryVerify(() => line("Gpu") === "GPU: 41 %", 3000)
            tryVerify(() => line("Ram") === "RAM: 3.2 GB of 8 GB", 3000)
            compare(find("perfOverlayCpu").color, Theme.text)
        }

        // unsupported: said plainly, in `text` (textDim is under the contrast floor).
        function test_an_unsupported_value_says_so() {
            start()
            playRacer()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => Performance.valid && Performance.fresh, 3000)
            compare(line("Vram"), "VRAM: Not available on this console")
            compare(line("GpuTemp"), "GPU temperature: Not available on this console")
            verify(!find("perfOverlayVram").truncated)
            compare(find("perfOverlayVram").color, Theme.text)
            // The frame meter without a compositor window (this host) is unsupported too.
            compare(line("Fps"), "FPS: Not available on this console")
            compare(line("FrameTime"), "Frame time: Not available on this console")
        }

        // unavailable: the first reading of a rate has nothing to compare with.
        function test_a_value_without_a_number_yet_says_measuring() {
            start()
            DeviceSettings.performanceIntervalMs = 5000       // the second answer is not due while we look
            playRacer()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => Performance.fresh, 2000, "the first answer")
            compare(line("Cpu"), "CPU: Measuring...")
            compare(line("Gpu"), "GPU: Measuring...")
            compare(line("Power"), "Power: Measuring...")
            compare(line("CpuTemp"), "CPU temperature: 52 °C", "a temperature has a number at once")
        }

        // The frames with a window and an app in front, but less than a second counted.
        function test_frames_say_measuring_before_a_whole_second() {
            start()
            playRacer()
            frameStand()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => Performance.counting, 2000)
            compare(line("Fps"), "FPS: Measuring...")
            compare(line("FrameTime"), "Frame time: Measuring...")
        }

        // A compositor window, but no app surface in front.
        function test_frames_say_no_game_in_front_without_an_app_surface() {
            start()
            playRacer()
            Performance.frameWindow = createTemporaryObject(windowComponent, host)
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => drawn(), 2000)
            compare(line("Fps"), "FPS: No game in front")
            Performance.frameSource = createTemporaryObject(surfaceComponent, host)
            tryVerify(() => line("Fps") === "FPS: Measuring...", 2000, line("Fps"))
        }

        // stale: the last good value, said to be old.
        function test_a_failed_reading_shows_the_last_value_marked_as_old() {
            start()
            playRacer()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => line("Power") === "Power: 18.4 W (last reading)", 3000, "stale from the second answer: " + line("Power"))
        }

        function test_the_frame_numbers_of_the_app_in_front() {
            start()
            playRacer()
            const stand = frameStand()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => Performance.counting, 2000)
            drive60(stand)
            tryVerify(() => line("Fps") === "60 FPS", 2000, line("Fps"))
            compare(line("FrameTime"), "17 ms, slowest 17 ms")
            verify(!find("perfOverlayFrameTime").truncated)
        }

        // Held numbers are not shown as live (T-451 review).
        function test_numbers_held_before_a_failed_reading_are_not_shown_as_live() {
            start()
            playRacer()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => line("CpuTemp") === "CPU temperature: 52 °C", 3000)
            Performance.mockFail(true)
            tryVerify(() => line("CpuTemp") === "CPU temperature: Measuring...", 3000, "the held 52 is gone: " + line("CpuTemp"))
            compare(line("Vram"), "VRAM: Not available on this console", "a console without a source stays without one")
            Performance.mockFail(false)
            tryVerify(() => line("CpuTemp") === "CPU temperature: 52 °C", 3000, "and the next answer is live again")
        }

        function test_the_first_show_after_idle_does_not_show_the_numbers_of_the_last_one() {
            start()
            playRacer()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => line("CpuTemp") === "CPU temperature: 52 °C", 3000)
            DeviceSettings.setPerformanceOverlay("p2", false)
            tryVerify(() => !Performance.polling)
            Performance.mockSet("cpu_temp", "supported", 71)       // what the console reads now
            Performance.mockReplyDelay(5000)                        // the answer is not here yet when it comes back
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => drawn(), 2000)
            compare(line("CpuTemp"), "CPU temperature: Measuring...", "not the 52 of the time before")
            verify(!Performance.fresh)
            Performance.mockReplyDelay(0)
            tryVerify(() => line("CpuTemp") === "CPU temperature: 71 °C", 3000, "the fresh answer")
        }

        // ---- never in the way ----------------------------------------------------------------------------------

        function test_it_takes_no_focus_and_no_key() {
            start()
            const app = playRacer()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => drawn(), 2000)
            verify(app.activeFocus, "the game keeps the focus")
            verify(!overlay().activeFocus)
            verify(!overlay().enabled, "disabled: it takes no input")
            verify(!overlay().activeFocusOnTab, "not in the focus chain")
            for (const key of [Qt.Key_Return, Qt.Key_Escape, Qt.Key_Left, Qt.Key_Tab, Qt.Key_A]) {
                const before = app.keys
                keyClick(key)
                compare(app.keys, before + 1, "key " + key + " reached the game")
                compare(app.lastKey, key)
            }
            verify(app.activeFocus)
            verify(!find("perfOverlayLeft").activeFocus && !find("perfOverlayRight").activeFocus)
            verify(!find("systemPanel").open, "no key opened anything")
        }

        // ---- Screenshots (dev.ps1 shots) ------------------------------------------------------------------

        function test_zz_screenshots_perf_overlay() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            playRacer(pictureAppComponent)
            const stand = frameStand()
            DeviceSettings.setPerformanceOverlay("p2", true)
            tryVerify(() => Performance.counting, 2000)
            // The first answer: FPS and the rates are not measurable yet, VRAM and GPU temperature are unsupported.
            DeviceSettings.performanceIntervalMs = 5000
            tryVerify(() => Performance.fresh, 2000)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/perf-overlay-1-measuring.png")
            // Every state at once: frames measured, CPU and temperature supported, GPU measuring, VRAM and
            // GPU temperature unsupported, power the last reading.
            DeviceSettings.performanceIntervalMs = 500
            drive60(stand)
            Performance.mockSet("gpu_percent", "unavailable", 0)
            tryVerify(() => line("Cpu") === "CPU: 24 %" && line("Gpu") === "GPU: Measuring..."
                            && line("Power") === "Power: 18.4 W (last reading)" && line("Fps") === "60 FPS", 3000)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/perf-overlay-2-states.png")
            Notifications.show("A toast takes the right corner", "warning")
            tryVerify(() => !rightBlock().visible, 2000)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/perf-overlay-3-toast.png")
        }
    }
}
