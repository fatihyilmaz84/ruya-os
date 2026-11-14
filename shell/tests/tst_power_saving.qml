import QtQuick
import QtTest
import RuyaShell

// Power saving (T-202): the idle clock, the screen saver, the dark screen, sleep, the inhibitors,
// the idle-controller report and Settings -> Power saving. The clock is a fake one (IdleClock.now),
// moved by hand; nothing here waits for real minutes. Signs in as "Ada" (p2, no PIN).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    Component {
        id: factRowComponent
        SettingRow {
            kind: "info"
            width: 1200
            height: 80
            label: "Keeping the console awake"
            value: "a download or install, a system update, audio playing, an app, and more words"
        }
    }

    // Takes the keys when the shell is not meant to: what the page below would have seen.
    Item {
        id: probe
        property int presses: 0
        Keys.onPressed: event => { presses++; event.accepted = true }
    }

    TestCase {
        id: tc
        name: "PowerSaving"
        when: windowShown

        property Shell shell: null
        property double t: 1000000000000   // the fake clock, ms
        property var order: []                // the stage signals, in the order they came
        property double slept: 0              // the fake "total ms suspended" (IdleClock.slept)
        property var defaultNow: null         // IdleClock's own clock source (monotonic), kept to test it
        property var defaultSlept: null
        property var defaultWallNow: null
        property var defaultLog: null

        function find(name) { return findChild(tc.shell, name) }
        // The fake clock moves in steps of at most a minute, as the real timer looks at it: a bigger
        // gap between two looks is a sleep (see jump()).
        function advance(ms) {
            let left = ms
            while (left > 0) {
                const step = Math.min(left, 60000)
                tc.t += step
                left -= step
                IdleClock.evaluate()
            }
        }
        function minutes(m) { advance(m * 60000) }
        function seconds(s) { advance(s * 1000) }
        // The machine was suspended: one look, far after the last.
        function jump(ms) { tc.t += ms; IdleClock.evaluate() }

        function setTimes(saver, off, sleep, pads) {
            DeviceSettings.saverMinutes = saver
            DeviceSettings.screenOffMinutes = off
            DeviceSettings.sleepMinutes = sleep
            DeviceSettings.padIdleMinutes = pads
        }

        function initTestCase() {
            tc.defaultNow = IdleClock.now
            tc.defaultSlept = IdleClock.slept
            tc.defaultWallNow = IdleClock.wallNow
            tc.defaultLog = IdleClock.log
            IdleClock.saverStarted.connect(() => tc.order.push("saver"))
            IdleClock.displayOffStarted.connect(() => tc.order.push("off"))
            IdleClock.sleepRequested.connect(() => tc.order.push("sleep"))
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.language = "en"
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            Power.mockReset()
            Bluetooth.mockReset()
            Audio.mockReset()
            Store.mockReset()
            Update.mockReset()
            setTimes(10, 30, 60, 15)
            tc.t = 1000000000000
            tc.slept = 0
            IdleClock.now = () => tc.t
            IdleClock.slept = () => tc.slept
            IdleClock.wallNow = () => tc.t
            IdleClock.appOpen = false
            IdleClock.reset()
            tc.order = []
            probe.presses = 0
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
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            IdleClock.reset()              // the sign-in keys were input; start the count here
        }

        function cleanup() {
            IdleClock.now = tc.defaultNow
            IdleClock.slept = tc.defaultSlept
            IdleClock.wallNow = tc.defaultWallNow
            IdleClock.log = tc.defaultLog
            IdleClock.reset()
            setTimes(10, 30, 60, 15)
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            Power.mockReset()
        }

        // ---- the timeline ----

        function test_saver_starts_after_the_timeout_and_not_before() {
            const saver = find("screenSaver")
            seconds(599)
            compare(IdleClock.stage, "active", "599 s is not 10 minutes")
            verify(!saver.visible)
            seconds(1)
            compare(IdleClock.stage, "saver")
            compare(tc.order.join(","), "saver")
            tryVerify(() => saver.visible)
            compare(IdleClock.covered, true)
            compare(ScreenPower.on, true, "the display is still on under the saver")
        }

        // RUY-563: the saver writes one journal line when it starts and one when it ends, with the reason.
        function test_saver_logs_one_line_on_and_one_off_with_the_reason() {
            const lines = []
            IdleClock.log = text => lines.push(text)
            seconds(599)
            compare(lines.length, 0, "nothing before the saver")
            seconds(1)
            compare(lines.length, 1)
            compare(lines[0], "ruya-shell: screen saver on (idle 600 s, stage saver)")
            minutes(25)
            compare(IdleClock.stage, "off")
            compare(lines.length, 1, "no line while it stays on, nor for the deeper stage")
            IdleClock.noteInput()
            compare(lines.length, 2)
            compare(lines[1], "ruya-shell: screen saver off (input, was off)")
            IdleClock.noteInput()
            compare(lines.length, 2, "input while awake is not a saver line")
            minutes(10)
            compare(IdleClock.stage, "saver")
            compare(lines.length, 3)
            tc.slept += 3600 * 1000
            jump(3600 * 1000)
            compare(lines.length, 4)
            compare(lines[3], "ruya-shell: screen saver off (resume, was saver)")
        }

        function test_display_off_and_sleep_follow_in_order() {
            minutes(10)
            compare(IdleClock.stage, "saver")
            minutes(19)
            compare(IdleClock.stage, "saver", "29 minutes: still the saver")
            compare(ScreenPower.on, true)
            minutes(1)
            compare(IdleClock.stage, "off")
            compare(ScreenPower.on, false, "the display is switched off")
            compare(Power.actionCount, 0)
            minutes(29)
            compare(IdleClock.stage, "off")
            compare(Power.actionCount, 0, "59 minutes: not asleep yet")
            minutes(1)
            compare(IdleClock.stage, "sleep")
            compare(Power.lastAction, "suspend")
            compare(Power.actionCount, 1)
            compare(tc.order.join(","), "saver,off,sleep")
        }

        function test_off_disables_a_step() {
            setTimes(0, 30, 0, 15)               // no saver, no sleep
            minutes(29)
            compare(IdleClock.stage, "active", "no saver when it is Off")
            minutes(1)
            compare(IdleClock.stage, "off", "the screen still goes off")
            minutes(120)
            compare(IdleClock.stage, "off")
            compare(Power.actionCount, 0, "no sleep when it is Never")
            IdleClock.noteInput()
            setTimes(5, 0, 0, 0)
            minutes(5)
            compare(IdleClock.stage, "saver")
            minutes(300)
            compare(IdleClock.stage, "saver", "Never turns the screen off")
            compare(ScreenPower.on, true)
        }

        function test_a_setting_changes_apply_without_restart() {
            minutes(4)
            compare(IdleClock.stage, "active")
            DeviceSettings.saverMinutes = 5
            seconds(60)
            compare(IdleClock.stage, "saver", "the new time counts from the last input, at once")
            IdleClock.noteInput()
            DeviceSettings.saverMinutes = 15
            minutes(14)
            compare(IdleClock.stage, "active")
            minutes(1)
            compare(IdleClock.stage, "saver")
        }

        function test_sleep_is_not_offered_where_suspend_is_not_available() {
            Power.mockSetCapabilities("no", "yes", "yes")
            tryCompare(Power, "sleepAllowed", false)
            compare(IdleClock.sleepAfter, 0)
            minutes(120)
            compare(IdleClock.stage, "off", "the dark screen is as far as it goes")
            compare(Power.actionCount, 0)
            Power.mockReset()
            tryCompare(Power, "sleepAllowed", true)
        }

        function test_the_debug_divisor_shortens_every_time() {
            compare(IdleInhibit.timeDivisor, 1, "unset: real time")
            compare(IdleClock.secs(10), 600)
            compare(IdleClock.secs(0), 0, "0 stays off")
        }

        // ---- input ----

        function test_input_dismisses_the_saver_and_is_not_passed_on() {
            minutes(10)
            compare(IdleClock.stage, "saver")
            probe.forceActiveFocus()
            keyClick(Qt.Key_Return)
            compare(IdleClock.stage, "active", "the first press wakes")
            compare(probe.presses, 0, "and nothing below sees it")
            keyClick(Qt.Key_Return)
            compare(probe.presses, 1, "the next press is an ordinary one")
            compare(IdleClock.idleSeconds, 0)
        }

        function test_input_wakes_the_dark_screen_and_the_display() {
            minutes(30)
            compare(IdleClock.stage, "off")
            compare(ScreenPower.on, false)
            probe.forceActiveFocus()
            keyClick(Qt.Key_Escape)
            compare(IdleClock.stage, "active")
            compare(ScreenPower.on, true, "the display is back at the first input")
            compare(probe.presses, 0)
        }

        function test_a_held_key_that_woke_the_console_does_not_repeat_into_the_page() {
            minutes(10)
            probe.forceActiveFocus()
            keyPress(Qt.Key_Down)
            compare(IdleClock.stage, "active")
            keyPress(Qt.Key_Down)                 // the key repeating while it is held
            keyRelease(Qt.Key_Down)
            compare(probe.presses, 0)
            keyClick(Qt.Key_Down)
            compare(probe.presses, 1)
        }

        function test_the_guide_button_wakes_and_is_eaten_too() {
            minutes(10)
            probe.forceActiveFocus()
            keyClick(Qt.Key_HomePage)
            compare(IdleClock.stage, "active")
            compare(probe.presses, 0)
            verify(!find("systemPanel") || !find("systemPanel").open, "the Guide overlay did not open")
        }

        function test_after_a_sleep_the_clock_jumping_ahead_is_a_wake() {
            minutes(60)
            compare(IdleClock.stage, "sleep")
            compare(ScreenPower.on, false)
            jump(3600 * 1000)                      // the machine was suspended; nothing ticked
            compare(IdleClock.stage, "active", "waking by the power button is activity")
            compare(ScreenPower.on, true)
            compare(IdleClock.idleSeconds, 0)
        }

        function test_suspend_from_the_menu_then_two_hours_is_a_wake_not_idle_time() {
            Power.suspend()                        // the Guide menu's Suspend: nothing of the idle clock knows
            compare(Power.lastAction, "suspend")
            const before = Power.actionCount
            jump(2 * 3600 * 1000)
            compare(IdleClock.stage, "active", "the time asleep is not idle time")
            compare(IdleClock.idleSeconds, 0)
            compare(ScreenPower.on, true)
            compare(Power.actionCount, before, "and it does not go back to sleep at once")
            minutes(9)
            compare(IdleClock.stage, "active", "the countdown starts at the wake")
            minutes(1)
            compare(IdleClock.stage, "saver")
        }

        function test_the_gap_limit_is_longer_than_the_heartbeat() {
            compare(IdleClock.heartbeatMs, 60000)
            compare(IdleClock.gapMs, 90000)
            verify(IdleClock.gapMs > IdleClock.heartbeatMs, "the timer never looks less often than the gap allows")
        }

        function test_a_pad_connecting_is_input() {
            minutes(10)
            compare(IdleClock.stage, "saver")
            Bluetooth.mockGamepad(true, "bt-9", "Wireless Controller", "playstation", "bluetooth")
            tryCompare(IdleClock, "stage", "active")
            compare(IdleClock.idleSeconds, 0)
            Bluetooth.mockGamepad(false, "bt-9", "Wireless Controller", "playstation", "bluetooth")
        }

        // ---- inhibitors ----

        function test_an_app_inhibitor_prevents_the_saver_and_releasing_restarts_the_count() {
            IdleInhibit.acquire("wayland:7")
            minutes(45)
            compare(IdleClock.stage, "active", "a video player is running")
            compare(IdleClock.idleSeconds, 45 * 60, "the idle time is real; only the countdown is held")
            IdleInhibit.release("wayland:7")
            minutes(9)
            compare(IdleClock.stage, "active", "the countdown starts again at the release")
            seconds(59)
            compare(IdleClock.stage, "active")
            seconds(1)
            compare(IdleClock.stage, "saver")
        }

        function test_two_holders_of_one_reason_need_two_releases() {
            IdleInhibit.acquire("wayland:1")
            IdleInhibit.acquire("wayland:1")
            IdleInhibit.release("wayland:1")
            compare(IdleInhibit.held, true)
            IdleInhibit.release("wayland:1")
            compare(IdleInhibit.held, false)
            IdleInhibit.release("wayland:1")           // too many: ignored
            compare(IdleInhibit.held, false)
        }

        function test_a_store_job_prevents_idling() {
            Store.install("org.example.Racer")
            tryVerify(() => Store.jobs["org.example.Racer"] !== undefined, 2000, "progress arrived")
            Store.mockPauseJobs(true)             // the install stands still
            compare(IdleInhibit.reasons.indexOf("job") >= 0, true, "a running install holds the console awake")
            minutes(40)
            compare(IdleClock.stage, "active")
            Store.mockPauseJobs(false)
            tryVerify(() => IdleInhibit.reasons.indexOf("job") < 0, 5000, "released when the job ends")
        }

        function test_an_update_being_fetched_prevents_idling() {
            Update.mockSetUpdateExists(true)
            Update.mockPauseDownloadAt(50)
            Update.check()
            tryVerify(() => Update.available !== "", 5000, "the check found an update")
            Update.download()
            tryCompare(Update, "state", "downloading", 2000)
            tryVerify(() => IdleInhibit.reasons.indexOf("update") >= 0, 2000)
            minutes(40)
            compare(IdleClock.stage, "active")
            Update.mockResumeDownload()
            tryVerify(() => IdleInhibit.reasons.indexOf("update") < 0, 5000)
        }

        // RUY-562: audio lets the saver start, and holds only the screen-off and sleep steps.
        function test_audio_playing_lets_the_saver_start_but_holds_screen_off_and_sleep() {
            Audio.mockSetPlaying(true)
            tryVerify(() => Audio.playing)
            tryVerify(() => IdleInhibit.reasons.indexOf("audio") >= 0)
            minutes(9)
            compare(IdleClock.stage, "active")
            minutes(1)
            compare(IdleClock.stage, "saver", "the saver starts over music")
            minutes(200)
            compare(IdleClock.stage, "saver", "no display-off and no sleep while it plays")
            compare(ScreenPower.on, true)
            compare(Power.actionCount, 0)
            Audio.mockSetPlaying(false)
            tryVerify(() => IdleInhibit.reasons.indexOf("audio") < 0)
            minutes(29)
            compare(IdleClock.stage, "saver", "the screen-off countdown starts again at the stop")
            minutes(1)
            compare(IdleClock.stage, "off")
        }

        function test_audio_and_another_holder_hold_the_saver_until_the_other_lets_go() {
            Audio.mockSetPlaying(true)
            tryVerify(() => IdleInhibit.reasons.indexOf("audio") >= 0)
            IdleInhibit.acquire("job")
            minutes(40)
            compare(IdleClock.stage, "active", "a job holds the saver even while music plays")
            IdleInhibit.release("job")
            minutes(9)
            compare(IdleClock.stage, "active")
            minutes(1)
            compare(IdleClock.stage, "saver", "only audio is left: the saver starts")
        }

        function test_every_holder_but_audio_holds_the_saver() {
            for (const reason of ["job", "update", "wayland:3"]) {
                IdleClock.reset()
                IdleInhibit.acquire(reason)
                minutes(40)
                compare(IdleClock.stage, "active", reason + " holds the saver")
                IdleInhibit.release(reason)
            }
        }

        // T-313: the shell's own ambient bed is a running PipeWire stream, but Devices1 leaves the
        // shell's streams out of `Playing`, so with the bed on and no app the stages still come.
        function test_the_ambient_bed_does_not_hold_the_saver() {
            DeviceSettings.ambientSound = true
            const bed = find("ambientBed")
            verify(bed, "the ambient bed exists")
            compare(bed.switchedOn, true)
            compare(bed.wanted, true, "nothing in front: the bed is wanted")
            // The service answers false although the bed's stream runs: an answer after a true one
            // (an app that played and stopped) makes the clock look at the holds again.
            Audio.mockSetPlaying(true)
            tryVerify(() => IdleInhibit.reasons.indexOf("audio") >= 0)
            Audio.mockSetPlaying(false)
            tryCompare(Audio, "playing", false)
            tryVerify(() => IdleInhibit.reasons.indexOf("audio") < 0)
            compare(bed.switchedOn, true, "the bed is still on")
            compare(IdleInhibit.reasons.indexOf("audio"), -1)
            minutes(10)
            compare(IdleClock.stage, "saver")
            minutes(20)
            compare(IdleClock.stage, "off")
        }

        function test_an_inhibitor_that_appears_later_does_not_end_the_saver_but_stops_the_next_step() {
            minutes(10)
            compare(IdleClock.stage, "saver")
            IdleInhibit.acquire("audio")
            minutes(100)
            compare(IdleClock.stage, "saver", "no display-off and no sleep while it is held")
            compare(ScreenPower.on, true)
            compare(Power.actionCount, 0)
        }

        // ---- looks ----

        function test_the_saver_obeys_reduced_motion_and_the_performance_tier() {
            const saver = find("screenSaver")
            minutes(10)
            compare(IdleClock.stage, "saver")
            compare(saver.showArt, true, "art on the full tier")
            compare(saver.animating, Library.items.length > 1, "drifting, with more than one picture")
            DeviceSettings.reducedMotion = true
            compare(saver.animating, false, "reduced motion: one still frame")
            compare(saver.showArt, true)
            verify(find("saverClock").visible, "the clock still moves")
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "performance"
            compare(saver.showArt, false, "Performance: plain dark, no art")
            compare(saver.animating, false)
            verify(find("saverClock").visible)
        }

        function test_the_clock_moves_every_minute() {
            const saver = find("screenSaver")
            minutes(10)
            const tick = find("saverTick")
            tick.triggered()
            const first = [find("saverClock").x, find("saverClock").y]
            minutes(1)
            tick.triggered()
            const second = [find("saverClock").x, find("saverClock").y]
            verify(first[0] !== second[0] || first[1] !== second[1], "a new place after a minute")
            const margin = DeviceSettings.overscan * saver.width
            verify(second[0] >= margin - 1 && second[0] + find("saverClock").width <= saver.width - margin + 1,
                   "inside the safe area")
            verify(second[1] >= DeviceSettings.overscan * saver.height - 1)
        }

        function test_the_clock_is_in_the_consoles_zone() {
            TimeZone.mockSetOutside("Asia/Tokyo")
            tryCompare(TimeZone, "timezone", "Asia/Tokyo")
            minutes(10)
            find("saverTick").triggered()
            const tokyo = new Date(tc.t + 9 * 3600000)
            const hh = ("0" + tokyo.getUTCHours()).slice(-2)
            const mm = ("0" + tokyo.getUTCMinutes()).slice(-2)
            tryCompare(find("saverClock"), "text", hh + ":" + mm)
            compare(find("saverClock").text, TimeZone.formatClock(tc.t))
            TimeZone.mockReset()
        }

        function test_the_dark_screen_runs_nothing() {
            minutes(30)
            compare(IdleClock.stage, "off")
            verify(!find("saverClock").visible, "no clock on a dark screen")
            verify(!find("saverTick").running, "no timers while the screen is off")
            verify(!find("saverSlides").running)
            verify(!find("backdrop").shown, "the backdrop under it stops drifting")
        }

        // ---- the PIN pad ----

        function test_a_pin_pad_never_stays_up_behind_the_saver() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => find("profileList").activeFocus)
            for (let i = 0; i < 3 && find("profileList").currentIndex > 0; ++i)
                keyClick(Qt.Key_Left)
            compare(find("profileList").currentIndex, 0, "Player One, who has a PIN")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("pinPad").shown, 2000, "the PIN pad is open")
            keyClick(Qt.Key_Return)                // type a digit
            IdleClock.reset()
            minutes(10)
            compare(IdleClock.stage, "saver")
            compare(find("pinPad").shown, false, "closed when the saver started")
            compare(find("pinPad").entered, "", "and nothing typed is left")
            keyClick(Qt.Key_Return)                // wakes, eaten
            compare(IdleClock.stage, "active")
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker is back on its list")
        }

        // ---- idle controllers: what the shell tells the service ----

        function test_idle_pads_are_reported_when_the_console_has_been_idle_that_long() {
            const before = Bluetooth.mockIdleReports()
            minutes(14)
            compare(Bluetooth.mockIdleReports(), before, "nothing before the timeout")
            minutes(1)
            tryVerify(() => Bluetooth.mockIdleReports() === before + 1)
            compare(Bluetooth.mockLastIdleSeconds(), 900)
            compare(Bluetooth.mockLastIdleTimeout(), 900)
            compare(Bluetooth.mockLastIdleHold(), false)
            minutes(1)
            tryVerify(() => Bluetooth.mockIdleReports() === before + 2, 2000, "and every minute after")
            keyClick(Qt.Key_Left)
            tryVerify(() => Bluetooth.mockLastIdleSeconds() === 0, 2000, "input ends the idle period at once")
        }

        function test_pads_are_held_on_while_an_app_is_open() {
            IdleClock.appOpen = true
            minutes(20)
            tryVerify(() => Bluetooth.mockIdleReports() > 0)
            compare(Bluetooth.mockLastIdleHold(), true)
        }

        function test_never_means_no_reports() {
            DeviceSettings.padIdleMinutes = 0
            const before = Bluetooth.mockIdleReports()
            minutes(120)
            compare(Bluetooth.mockIdleReports(), before)
        }

        function test_the_one_idle_clock_feeds_the_update_service() {
            Update.mockReset()                    // the report is throttled to one a minute
            const before = Update.mockActivityCount()
            keyClick(Qt.Key_Left)
            tryVerify(() => Update.mockActivityCount() > before, 2000, "input still reaches the update service")
        }

        // ---- Settings -> Power saving ----

        function openPowerPane() {
            tc.shell.openPage("settings")
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus)
            for (let i = 0; i < 8; ++i)
                keyClick(Qt.Key_Down)
            compare(find("categoryList").currentIndex, 8)
            tryVerify(() => find("category_power"))
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowScreenSaver").activeFocus, 2000, "the first row has focus")
        }

        function test_the_pane_rows_write_the_settings_and_focus_stays() {
            openPowerPane()
            compare(find("rowScreenSaver").currentLabel, "10 minutes")
            keyClick(Qt.Key_Right)
            compare(DeviceSettings.saverMinutes, 15)
            compare(find("rowScreenSaver").currentLabel, "15 minutes")
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            compare(DeviceSettings.saverMinutes, 5)
            keyClick(Qt.Key_Left)
            compare(DeviceSettings.saverMinutes, 0)
            compare(find("rowScreenSaver").currentLabel, "Off")
            verify(find("rowScreenSaver").activeFocus)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowScreenOff").activeFocus)
            compare(find("rowScreenOff").currentLabel, "30 minutes")
            keyClick(Qt.Key_Right)
            compare(DeviceSettings.screenOffMinutes, 60)
            compare(find("rowScreenOff").currentLabel, "1 hour")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowSleep").activeFocus)
            compare(find("rowSleep").currentLabel, "1 hour")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowControllersOff").activeFocus)
            compare(find("rowControllersOff").currentLabel, "15 minutes")
            keyClick(Qt.Key_Left)
            compare(DeviceSettings.padIdleMinutes, 10)
            // Screen off and Sleep are both 60 minutes now: the note row (it takes focus like a row).
            compare(find("rowOrderNote").visible, true)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowOrderNote").activeFocus)
            compare(find("rowOrderNote").kind, "info")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowKeepingAwake").activeFocus)
            compare(find("rowKeepingAwake").kind, "info")
            compare(find("rowKeepingAwake").value, "Nothing")
            compare(find("audioNote").visible, false, "no note without audio")
            IdleInhibit.acquire("audio")
            compare(find("rowKeepingAwake").value, "audio playing", "a stuck holder is named")
            compare(find("audioNote").visible, true, "the note says what audio does not hold")
            compare(find("audioNote").text, "Sound doesn't stop the screen saver.")
            compare(find("audioNote").activeFocus, false)
            IdleInhibit.release("audio")
            compare(find("audioNote").visible, false, "the note goes with the holder")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Back leaves the pane for the list")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play regains focus")
        }

        // RUY-589: at most two phrases, then "and N more".
        function test_the_held_text_names_two_reasons_then_counts_the_rest() {
            openPowerPane()
            const row = find("rowKeepingAwake")
            IdleInhibit.acquire("job")
            compare(row.value, "a download or install")
            IdleInhibit.acquire("audio")
            compare(row.value, "audio playing, a download or install", "two read as they did")
            IdleInhibit.acquire("update")
            compare(row.value, "audio playing and 2 more")
            IdleInhibit.acquire("wayland:3")
            compare(row.value, "audio playing and 3 more")
            IdleInhibit.release("wayland:3")
            IdleInhibit.release("update")
            IdleInhibit.release("audio")
            IdleInhibit.release("job")
        }

        function test_a_fact_value_never_takes_more_than_half_the_row() {
            const row = createTemporaryObject(factRowComponent, host)
            verify(row)
            const label = findChild(row, "label")
            const value = findChild(row, "value")
            verify(value.implicitWidth > row.width * 0.5, "the test value is longer than half a row")
            compare(value.width, row.width * 0.5)
            verify(value.truncated, "the long value is elided")
            compare(label.truncated, false, "the label stays whole")
            verify(label.x + label.contentWidth < value.x, "the label ends before the value")
            row.value = "Nothing"
            verify(!value.truncated)
            compare(value.width, value.implicitWidth)
        }

        function test_a_later_step_at_or_before_an_earlier_one_gets_a_note() {
            openPowerPane()
            compare(find("rowOrderNote").visible, false, "the defaults are in order")
            DeviceSettings.screenOffMinutes = 15
            DeviceSettings.saverMinutes = 30
            compare(find("rowOrderNote").visible, true)
            compare(find("rowOrderNote").label, "The screen saver never shows")
            compare(find("rowOrderNote").value, "The screen turns off first")
            DeviceSettings.saverMinutes = 5
            compare(find("rowOrderNote").visible, false)
            DeviceSettings.sleepMinutes = 30
            DeviceSettings.screenOffMinutes = 60
            compare(find("rowOrderNote").label, "The screen is not turned off")
            compare(find("rowOrderNote").value, "The console sleeps instead", "T-293: says what happens instead")
            DeviceSettings.screenOffMinutes = 0
            compare(find("rowOrderNote").visible, false, "Never has no order to break")
        }

        function test_the_sleep_row_is_hidden_where_suspend_is_not_available() {
            Power.mockSetCapabilities("no", "yes", "yes")
            tryCompare(Power, "sleepAllowed", false)
            openPowerPane()
            compare(find("rowSleep").visible, false)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowControllersOff").activeFocus, 2000, "focus skips the missing row")
        }

        // ---- the monotonic clock, resume, the sleep row, the wake gap (T-293) ----

        // IdleClock.now is the monotonic clock, not Date.now: a wall clock that jumps an hour
        // (NTP, a time zone, a date set by hand) neither starts nor ends a stage.
        function test_wall_clock_jump_does_not_change_stage() {
            IdleClock.now = tc.defaultNow
            IdleClock.slept = tc.defaultSlept
            IdleClock.reset()
            for (let i = 0; i < 10; ++i) {
                MonotonicClock.mockAdvance(60000)         // ten minutes pass, a minute at a time
                IdleClock.evaluate()
            }
            compare(IdleClock.stage, "saver")
            const realNow = Date.now
            Date.now = () => realNow() + 3600 * 1000      // the wall clock jumps forward an hour
            IdleClock.evaluate()
            compare(IdleClock.stage, "saver", "a jump of the wall clock is not input and not a resume")
            compare(IdleClock.quietSeconds, 600, "and it adds no idle time")
            Date.now = () => realNow() - 3600 * 1000      // and back two hours
            IdleClock.evaluate()
            Date.now = realNow
            compare(IdleClock.stage, "saver")
            compare(IdleClock.quietSeconds, 600)
        }

        // The monotonic clock stops while the machine is suspended; what grew is the time slept.
        function test_resume_restarts_idle() {
            minutes(10)
            compare(IdleClock.stage, "saver")
            tc.slept += 3 * 3600 * 1000                   // suspended for three hours; `now` did not move
            IdleClock.evaluate()
            compare(IdleClock.stage, "active", "a resume is activity")
            compare(IdleClock.quietSeconds, 0)
            compare(IdleClock.idleSeconds, 0)
            minutes(9)
            compare(IdleClock.stage, "active", "the countdown starts again at the resume")
            minutes(1)
            compare(IdleClock.stage, "saver")
            minutes(20)
            compare(IdleClock.stage, "off")
            compare(ScreenPower.on, false)
            tc.slept += 1800 * 1000
            IdleClock.evaluate()
            compare(IdleClock.stage, "active", "also from the dark screen")
            compare(ScreenPower.on, true)
        }

        function test_a_short_stall_is_not_a_resume() {
            minutes(10)
            tc.slept += 400                               // the boot clock and the monotonic one drift apart a little
            IdleClock.evaluate()
            compare(IdleClock.stage, "saver")
        }

        function test_sleep_row_disabled_without_marker() {
            Power.mockSetSuspendVerified(false)
            tryCompare(Power, "sleepAllowed", false)
            compare(IdleClock.sleepAfter, 0, "the step does not exist")
            openPowerPane()
            const row = find("rowSleep")
            compare(row.visible, true, "the row is not silently missing")
            compare(row.enabled, false)
            compare(row.label, "Sleep is not available on this console yet")
            compare(row.valueText.visible, false, "no value to change")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowControllersOff").activeFocus, 2000, "focus skips the disabled row")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("rowScreenOff").activeFocus, 2000, "and Up passes it too")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Back leaves the pane")
            minutes(120)
            compare(IdleClock.stage, "off", "the dark screen is as far as it goes")
            compare(Power.actionCount, 0)
        }

        function test_sleep_row_enabled_with_marker() {
            Power.mockSetSuspendVerified(true)
            tryCompare(Power, "sleepAllowed", true)
            openPowerPane()
            const row = find("rowSleep")
            compare(row.visible, true)
            compare(row.enabled, true)
            compare(row.label, "Sleep")
            compare(row.valueText.visible, true)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            tryVerify(() => row.activeFocus, 2000, "the row takes focus")
            keyClick(Qt.Key_Right)
            compare(DeviceSettings.sleepMinutes, 120)
            keyClick(Qt.Key_Left)
        }

        function test_marker_appearing_later_enables_the_row_and_the_step() {
            Power.mockSetSuspendVerified(false)
            tryCompare(Power, "sleepAllowed", false)
            openPowerPane()
            compare(find("rowSleep").enabled, false)
            Power.mockSetSuspendVerified(true)
            tryCompare(find("rowSleep"), "enabled", true)
            compare(IdleClock.sleepAfter, 3600)
        }

        // The screen came back from off: the TV may still be re-syncing, so for a second the input
        // only counts as activity. Input at the dark screen itself is eaten as before.
        function test_input_swallowed_for_1s_after_wake() {
            probe.forceActiveFocus()
            minutes(30)
            compare(IdleClock.stage, "off")
            keyClick(Qt.Key_Return)                       // wakes
            compare(IdleClock.stage, "active")
            compare(ScreenPower.on, true)
            compare(probe.presses, 0)
            compare(IdleClock.swallowInput, true, "the gap is on")
            keyClick(Qt.Key_Return)
            compare(probe.presses, 0, "within the second: swallowed")
            seconds(0.5)
            keyClick(Qt.Key_Return)
            compare(probe.presses, 0, "still within it")
            compare(IdleClock.stage, "active", "swallowed input is still activity, not a stage change")
            compare(IdleClock.idleSeconds, 0)
        }

        // RUY-588: pad input to a game never reaches KeyRouter; Input1.UserActive stands for it.
        function test_pad_activity_to_a_game_restarts_the_count() {
            minutes(9)
            compare(IdleClock.stage, "active")
            Input.mockUserActive()
            compare(IdleClock.idleSeconds, 0)
            minutes(9)
            compare(IdleClock.stage, "active", "9 min after the pad, not 18 after the key")
            minutes(2)
            compare(IdleClock.stage, "saver")
        }

        function test_pad_activity_does_not_wake_the_saver_by_itself() {
            minutes(10)
            compare(IdleClock.stage, "saver")
            Input.mockUserActive()
            compare(IdleClock.stage, "saver", "the key the pad also sends wakes it, KeyRouter eating it")
            minutes(20)
            compare(IdleClock.stage, "off")
            Input.mockUserActive()
            compare(IdleClock.stage, "off")
            compare(ScreenPower.on, false)
        }

        function test_input_after_1s_passes() {
            probe.forceActiveFocus()
            minutes(30)
            keyClick(Qt.Key_Return)
            compare(probe.presses, 0)
            compare(IdleClock.wakeGapMs, 1000)
            seconds(1)
            compare(IdleClock.swallowInput, false, "the gap ended after 1 s")
            keyClick(Qt.Key_Return)
            compare(probe.presses, 1, "an ordinary press again")
        }

        function test_the_wake_gap_is_only_after_the_screen_was_off() {
            probe.forceActiveFocus()
            minutes(10)
            compare(IdleClock.stage, "saver")
            keyClick(Qt.Key_Return)                       // dismisses the saver
            compare(IdleClock.swallowInput, false, "the saver needs no gap: the screen never went dark")
            keyClick(Qt.Key_Return)
            compare(probe.presses, 1)
        }

        function test_a_resume_from_sleep_opens_the_gap_too() {
            probe.forceActiveFocus()
            minutes(60)
            compare(IdleClock.stage, "sleep")
            tc.slept += 3600 * 1000                       // woken by the power button: no key
            IdleClock.evaluate()
            compare(IdleClock.stage, "active")
            compare(IdleClock.swallowInput, true)
            keyClick(Qt.Key_Return)
            compare(probe.presses, 0)
            seconds(1)
            keyClick(Qt.Key_Return)
            compare(probe.presses, 1)
        }

        // ---- screenshots (dev.ps1 shots) ----

        function settle() {
            wait(800)
            grabImage(tc.shell)
            wait(400)
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openPowerPane()
            IdleInhibit.acquire("audio")
            settle()
            grabImage(tc.shell).save(shotsDir + "/92-power-saving-settings-en.png")
            IdleInhibit.release("audio")
            Power.mockSetSuspendVerified(false)          // T-293: the Sleep row without the marker
            tryCompare(find("rowSleep"), "enabled", false)
            settle()
            grabImage(tc.shell).save(shotsDir + "/92-power-saving-no-sleep-en.png")
            Power.mockSetSuspendVerified(true)
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            minutes(10)
            compare(IdleClock.stage, "saver")
            settle()
            grabImage(tc.shell).save(shotsDir + "/92-screen-saver-en.png")
            IdleClock.noteInput()
            DeviceSettings.reducedMotion = true
            minutes(10)
            settle()
            grabImage(tc.shell).save(shotsDir + "/92-screen-saver-reduced-motion-en.png")
            IdleClock.noteInput()
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "performance"
            minutes(10)
            settle()
            grabImage(tc.shell).save(shotsDir + "/92-screen-saver-performance-en.png")
        }

        // RUY-589: audio and a job held at once, in Turkish, at 720p, 1080p and the large UI size.
        function test_zz_screenshots_held_tr() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.language = "tr"
            openPowerPane()
            IdleInhibit.acquire("audio")
            IdleInhibit.acquire("job")
            settle()
            grabImage(tc.shell).save(shotsDir + "/92-power-saving-held-tr-720p.png")
            host.width = 1920
            host.height = 1080
            settle()
            grabImage(tc.shell).save(shotsDir + "/92-power-saving-held-tr-1080p.png")
            Display.setUiScale(150)
            for (let i = 0; i < 6 && !find("rowKeepingAwake").activeFocus; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => find("rowKeepingAwake").activeFocus, 2000)
            settle()
            grabImage(tc.shell).save(shotsDir + "/92-power-saving-held-tr-large.png")
            IdleInhibit.acquire("update")                // four holders: the first and "ve 3 tane daha"
            IdleInhibit.acquire("wayland:3")
            settle()
            grabImage(tc.shell).save(shotsDir + "/92-power-saving-held-4-tr-large.png")
            Display.setUiScale(0)
            host.width = 1280
            host.height = 720
            IdleInhibit.release("wayland:3")
            IdleInhibit.release("update")
            IdleInhibit.release("job")
            IdleInhibit.release("audio")
        }
    }
}
