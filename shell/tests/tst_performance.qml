import QtQuick
import QtTest
import RuyaShell

// The performance numbers (T-451) against the mock backend: nothing is asked for and no frame is
// counted while no consumer is open; a consumer polls at the interval setting (500-5000 ms); the
// mock's answer holds every state; a late reply is dropped. The compositor's FPS counter with a
// stand-in surface (`signal redraw()`, one per commit) and window (`signal frameSwapped()`, one
// per presented frame) driven at known rates on the meter's test clock.
Item {
    id: host
    width: 640
    height: 360

    Component {
        id: consumerComponent
        PerformanceConsumer {}
    }

    // A Wayland surface as the meter sees it: one redraw() per commit.
    Component {
        id: surfaceComponent
        QtObject {
            signal redraw()
        }
    }

    // The shell's window as the meter sees it: one frameSwapped() per presented frame.
    Component {
        id: windowComponent
        QtObject {
            signal frameSwapped()
        }
    }

    TestCase {
        id: tc
        name: "Performance"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Performance.mockReset()
            Performance.mockReplyDelay(0)
            DeviceSettings.performanceIntervalMs = 1000
            compare(Performance.consumers, 0, "no consumer left from a test before")
        }

        function cleanup() {
            Performance.frameSource = null
            Performance.frameWindow = null
            Performance.fakeFrameClockMs(-1)
            Performance.mockReplyDelay(0)
            Performance.mockReset()
            DeviceSettings.performanceIntervalMs = 1000
        }

        // Commits and presented frames on the test clock: `count` frames, one every `stepMs`,
        // starting a step after `fromMs`; `commitsPerFrame` commits before each presented frame.
        function drive(surface, win, fromMs, stepMs, count, commitsPerFrame) {
            for (let i = 1; i <= count; ++i) {
                const t = fromMs + i * stepMs
                for (let c = 0; c < commitsPerFrame; ++c) {
                    Performance.fakeFrameClockMs(t - stepMs / 2 + c * stepMs / (2 * commitsPerFrame))
                    surface.redraw()
                }
                Performance.fakeFrameClockMs(t)
                win.frameSwapped()
            }
            return fromMs + count * stepMs
        }

        // Runs first (the functions run in name order): the engine is fresh, so nothing has asked yet.
        function test_0_nothing_is_asked_before_a_consumer() {
            compare(Performance.pollCount, 0)
            verify(!Performance.polling)
            verify(!Performance.valid)
            compare(Performance.stateOf("cpu_percent"), "unavailable", "no reply: unavailable")
        }

        function test_no_polling_without_a_consumer() {
            DeviceSettings.performanceIntervalMs = 500
            const before = Performance.pollCount
            verify(!Performance.polling)
            Performance.refresh()                  // a no-op without a consumer
            wait(1200)                             // more than two intervals
            compare(Performance.pollCount, before)
            compare(Performance.mockPendingReplies(), 0)
        }

        function test_a_consumer_polls_at_the_interval_and_stops_when_closed() {
            DeviceSettings.performanceIntervalMs = 500
            compare(Performance.intervalMs, 500)
            const before = Performance.pollCount
            const consumer = createTemporaryObject(consumerComponent, host)
            verify(consumer)
            compare(Performance.consumers, 1)
            verify(Performance.polling)
            compare(Performance.pollCount, before + 1, "the first numbers are asked for at once")
            tryVerify(() => Performance.pollCount >= before + 3, 3000, "and then every 500 ms")
            consumer.active = false
            verify(!Performance.polling)
            compare(Performance.consumers, 0)
            const stopped = Performance.pollCount
            wait(1200)
            compare(Performance.pollCount, stopped, "nothing asked after the consumer closed")
            consumer.active = true
            verify(Performance.polling)
            consumer.destroy()
            tryCompare(Performance, "consumers", 0)
            verify(!Performance.polling, "a destroyed consumer releases")
        }

        function test_two_consumers_share_the_polling() {
            const a = createTemporaryObject(consumerComponent, host)
            const b = createTemporaryObject(consumerComponent, host)
            compare(Performance.consumers, 2)
            a.active = false
            verify(Performance.polling, "one consumer is still open")
            b.active = false
            verify(!Performance.polling)
        }

        function test_the_interval_setting_is_bounded() {
            DeviceSettings.performanceIntervalMs = 2000
            compare(Performance.intervalMs, 2000)
            DeviceSettings.performanceIntervalMs = 300
            compare(DeviceSettings.performanceIntervalMs, 2000, "under 0.5 s is refused")
            DeviceSettings.performanceIntervalMs = 6000
            compare(DeviceSettings.performanceIntervalMs, 2000, "over 5 s is refused")
            DeviceSettings.performanceIntervalMs = 5000
            compare(Performance.intervalMs, 5000)
            DeviceSettings.performanceIntervalMs = 500
            compare(Performance.intervalMs, 500)
        }

        function test_the_mock_answer_holds_every_state() {
            DeviceSettings.performanceIntervalMs = 500
            const consumer = createTemporaryObject(consumerComponent, host)
            verify(consumer)
            tryVerify(() => Performance.fresh)   // the first answer (what was held from before is marked unavailable until then, T-452)
            // The first reply, like the service's: a rate needs a reading before it.
            compare(Performance.stateOf("cpu_percent"), "unavailable")
            compare(Performance.valueOf("cpu_percent"), 0)
            compare(Performance.stateOf("ram_total"), "supported")
            tryVerify(() => Performance.stateOf("cpu_percent") === "supported", 2000)
            compare(Performance.valueOf("cpu_percent"), 23.5)
            compare(Performance.stateOf("gpu_percent"), "supported")
            compare(Performance.stateOf("vram_used"), "unsupported")
            compare(Performance.stateOf("gpu_temp"), "unsupported")
            compare(Performance.stateOf("power_w"), "stale")
            compare(Performance.valueOf("power_w"), 18.4)
            const names = ["cpu_percent", "ram_used", "ram_total", "gpu_percent", "vram_used",
                           "vram_total", "cpu_temp", "gpu_temp", "power_w"]
            for (const n of names)
                verify(Performance.metrics[n] !== undefined, n)
            compare(Performance.stateOf("no_such_metric"), "unavailable")
            Performance.mockSet("gpu_temp", "supported", 64)
            tryVerify(() => Performance.stateOf("gpu_temp") === "supported", 2000)
            compare(Performance.valueOf("gpu_temp"), 64)
        }

        function test_a_late_reply_does_not_replace_a_newer_one() {
            DeviceSettings.performanceIntervalMs = 5000   // only the two polls below
            Performance.mockReplyDelay(600)
            const consumer = createTemporaryObject(consumerComponent, host)   // poll 1: slow
            verify(consumer)
            compare(Performance.mockPendingReplies(), 1)
            Performance.mockReplyDelay(0)
            Performance.mockSet("cpu_percent", "supported", 77)
            Performance.refresh()                                            // poll 2: at once
            tryVerify(() => Performance.stateOf("cpu_percent") === "supported")
            tryVerify(() => Performance.mockPendingReplies() === 0, 2000)
            compare(Performance.stateOf("cpu_percent"), "supported", "poll 1's reply was dropped")
            compare(Performance.valueOf("cpu_percent"), 77)
        }

        // Never show held numbers as live (T-451 review, T-452).
        function test_a_failed_request_marks_the_held_numbers_unavailable() {
            DeviceSettings.performanceIntervalMs = 5000
            const consumer = createTemporaryObject(consumerComponent, host)
            verify(consumer)
            tryVerify(() => Performance.fresh)
            compare(Performance.stateOf("cpu_temp"), "supported")
            compare(Performance.valueOf("cpu_temp"), 52)
            Performance.mockFail(true)
            Performance.refresh()
            tryVerify(() => !Performance.fresh, 2000, "the failed request says the numbers are not live")
            compare(Performance.stateOf("cpu_temp"), "unavailable")
            compare(Performance.valueOf("cpu_temp"), 0, "no held number behind it")
            compare(Performance.stateOf("ram_total"), "unavailable")
            compare(Performance.stateOf("vram_used"), "unsupported", "a console without a source stays without one")
            verify(Performance.valid, "an answer was had once")
            Performance.mockFail(false)
            Performance.refresh()
            tryVerify(() => Performance.fresh, 2000)
            compare(Performance.stateOf("cpu_temp"), "supported", "the next answer is live again")
        }

        function test_the_first_open_after_idle_does_not_hold_the_numbers_of_the_visit_before() {
            DeviceSettings.performanceIntervalMs = 5000
            const first = createTemporaryObject(consumerComponent, host)
            tryVerify(() => Performance.fresh)
            compare(Performance.stateOf("cpu_temp"), "supported")
            first.active = false
            verify(!Performance.polling)
            compare(Performance.stateOf("cpu_temp"), "supported", "closing alone changes nothing: the last answer is still the newest")
            Performance.mockSet("cpu_temp", "supported", 71)
            Performance.mockReplyDelay(300)                         // the answer is not here when it opens
            first.active = true
            compare(Performance.stateOf("cpu_temp"), "unavailable", "not the 52 of the visit before")
            compare(Performance.valueOf("cpu_temp"), 0)
            verify(!Performance.fresh)
            compare(Performance.stateOf("vram_used"), "unsupported")
            tryVerify(() => Performance.fresh, 2000)
            compare(Performance.stateOf("cpu_temp"), "supported")
            compare(Performance.valueOf("cpu_temp"), 71)
        }

        // --- the compositor's frame meter

        function test_frames_are_not_counted_without_a_consumer() {
            const surface = createTemporaryObject(surfaceComponent, host)
            const win = createTemporaryObject(windowComponent, host)
            Performance.frameWindow = win
            Performance.frameSource = surface
            verify(!Performance.counting)
            const seen = Performance.commitsSeen
            drive(surface, win, 0, 20, 30, 1)
            Performance.updateFrames()
            compare(Performance.commitsSeen, seen, "no commit reached the meter")
            compare(Performance.fps, 0)
            compare(Performance.frameState, "unavailable")
        }

        function test_fps_and_frame_time_of_a_surface_at_a_known_rate() {
            const surface = createTemporaryObject(surfaceComponent, host)
            const win = createTemporaryObject(windowComponent, host)
            Performance.fakeFrameClockMs(1000)
            Performance.frameWindow = win
            Performance.frameSource = surface
            const consumer = createTemporaryObject(consumerComponent, host)
            verify(consumer)
            verify(Performance.counting)
            const seen = Performance.commitsSeen
            // Half a second at 50 Hz: not a whole second measured yet.
            let t = drive(surface, win, 1000, 20, 25, 1)
            Performance.updateFrames()
            compare(Performance.frameState, "unavailable", "Measuring... before a whole second")
            // Then 60 Hz for two seconds.
            t = drive(surface, win, t, 1000 / 60, 120, 1)
            Performance.fakeFrameClockMs(t + 5)   // off the frame grid: no frame on the window's edge
            Performance.updateFrames()
            compare(Performance.frameState, "supported")
            compare(Performance.fps, 60)
            compare(Performance.commitsPerSecond, 60)
            fuzzyCompare(Performance.frameTimeMs, 1000 / 60, 0.01)
            fuzzyCompare(Performance.frameTimeP99Ms, 1000 / 60, 0.01)
            compare(Performance.commitsSeen, seen + 145)
        }

        function test_commits_faster_than_the_display_count_as_presented_frames() {
            const surface = createTemporaryObject(surfaceComponent, host)
            const win = createTemporaryObject(windowComponent, host)
            Performance.fakeFrameClockMs(0)
            Performance.frameWindow = win
            Performance.frameSource = surface
            const consumer = createTemporaryObject(consumerComponent, host)
            verify(consumer)
            // 120 commits a second, 60 presented frames: the player sees 60.
            drive(surface, win, 0, 1000 / 60, 90, 2)
            // The shell also draws frames without new app content (the quick menu animating).
            Performance.fakeFrameClockMs(1500.5)
            win.frameSwapped()
            Performance.updateFrames()
            compare(Performance.fps, 60)
            compare(Performance.commitsPerSecond, 120)
        }

        function test_a_slow_frame_shows_in_the_99th_percentile() {
            const surface = createTemporaryObject(surfaceComponent, host)
            const win = createTemporaryObject(windowComponent, host)
            Performance.fakeFrameClockMs(1000)
            Performance.frameWindow = win
            Performance.frameSource = surface
            const consumer = createTemporaryObject(consumerComponent, host)
            verify(consumer)
            let t = drive(surface, win, 1000, 20, 30, 1)   // frames 1020..1600
            t = drive(surface, win, t, 400, 1, 1)           // a hitch: 2000
            t = drive(surface, win, t, 20, 5, 1)            // 2020..2100
            Performance.updateFrames()
            // The last second (1100, 2100]: 25 + 1 + 5 frames; 30 intervals of 20 ms and one of 400.
            compare(Performance.fps, 31)
            fuzzyCompare(Performance.frameTimeP99Ms, 400, 0.01)
            fuzzyCompare(Performance.frameTimeMs, 1000 / 31, 0.01)
        }

        function test_another_app_in_front_starts_the_count_again() {
            const first = createTemporaryObject(surfaceComponent, host)
            const second = createTemporaryObject(surfaceComponent, host)
            const win = createTemporaryObject(windowComponent, host)
            Performance.fakeFrameClockMs(0)
            Performance.frameWindow = win
            Performance.frameSource = first
            const consumer = createTemporaryObject(consumerComponent, host)
            verify(consumer)
            let t = drive(first, win, 0, 20, 60, 1)
            Performance.updateFrames()
            compare(Performance.frameState, "supported")
            Performance.frameSource = second
            verify(Performance.counting)
            Performance.updateFrames()
            compare(Performance.frameState, "unavailable", "a new app is measured from now")
            compare(Performance.fps, 0)
            const seen = Performance.commitsSeen
            first.redraw()
            compare(Performance.commitsSeen, seen, "the app behind is not counted")
            t = drive(second, win, t, 25, 41, 1)
            Performance.updateFrames()
            compare(Performance.frameState, "supported")
            compare(Performance.fps, 40)
            Performance.frameSource = null
            verify(!Performance.counting)
            compare(Performance.frameState, "unavailable", "no app in front")
        }

        function test_without_a_compositor_window_frames_are_unsupported() {
            const consumer = createTemporaryObject(consumerComponent, host)
            verify(consumer)
            compare(Performance.frameWindow, null)
            verify(!Performance.counting)
            compare(Performance.frameState, "unsupported")
        }

        function test_closing_the_consumer_disconnects_the_meter() {
            const surface = createTemporaryObject(surfaceComponent, host)
            const win = createTemporaryObject(windowComponent, host)
            Performance.frameWindow = win
            Performance.frameSource = surface
            const consumer = createTemporaryObject(consumerComponent, host)
            verify(consumer)
            verify(Performance.counting)
            surface.redraw()
            const seen = Performance.commitsSeen
            verify(seen > 0)
            consumer.active = false
            verify(!Performance.counting)
            surface.redraw()
            surface.redraw()
            compare(Performance.commitsSeen, seen)
        }
    }
}
