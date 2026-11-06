import QtQuick
import QtTest
import RuyaShell

// The console's temperatures (Thermal, org.ruyaos.Devices1.Thermal) against the mock backend: what
// the shell does at each level (ThermalPolicy: warm changes nothing, hot drops the effects quality
// for the session and says so once, critical shows a notice, stops the apps and powers off after
// the grace time if it still holds), the "Device health" rows in Settings -> System (updated in
// place, focus kept), the heat mark on the System category and a late reply. Signs in as "Ada"
// (p2, no PIN). The mock is reset before every test.
Item {
    id: host
    width: 1280
    height: 720

    SignalSpy { id: stopSpy; target: Session; signalName: "stopFinished" }

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "Thermal"
        when: windowShown

        property Shell shell: null
        readonly property int systemIndex: 7

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.language = "en"
            DeviceSettings.effectsQuality = "high"
            Thermal.mockReset()
            tryCompare(Thermal, "level", "normal")
            Power.mockReset()
            Session.mockReset()
            tryVerify(() => Session.running.length === 0)
            stopSpy.clear()
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
            clearToasts()
        }

        function cleanup() {
            Thermal.mockReset()
            tryCompare(Thermal, "level", "normal")
            clearToasts()
            DeviceSettings.language = "en"
        }

        function clearToasts() {
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text)
            return out
        }

        function heatToasts() {
            return toastTexts().filter(t => t.startsWith("The console is running hot"))
        }

        function setCpu(value, level) { Thermal.mockSet("mock:cpu", "cpu", value, level) }

        function openSystemPane() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus, 2000, "category list has focus")
            for (let i = 0; i < 20 && list.currentIndex < systemIndex; ++i)
                keyClick(Qt.Key_Down)
            compare(list.currentIndex, systemIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneSystem").activeFocus, 2000, "System pane has focus")
        }

        // Down to the named row, asserting that the pane keeps focus.
        function goTo(name) {
            tryVerify(() => find(name) !== null && find(name).visible, 3000, name + " exists")
            for (let i = 0; i < 40 && !find(name).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => find(name).activeFocus, 2000, name + " has focus")
        }

        // ---- the policy

        function test_warm_changes_nothing() {
            const shown0 = Notifications.shownCount
            setCpu(82, "warm")
            tryCompare(Thermal, "level", "warm")
            compare(Thermal.levelSensor, "mock:cpu")
            wait(100)
            compare(DeviceSettings.effectsQuality, "high")
            compare(DeviceSettings.thermalLimited, false)
            compare(Notifications.shownCount, shown0, "no toast")
            compare(find("thermalNotice").shown, false)
            verify(find("homePlay").activeFocus, "nothing took the focus")
        }

        function test_hot_drops_the_effects_and_says_so_once() {
            const shown0 = Notifications.shownCount
            setCpu(91, "hot")
            tryCompare(DeviceSettings, "effectsQuality", "performance")
            compare(DeviceSettings.storedEffectsQuality, "high", "the owner's setting is not rewritten")
            compare(Theme.blurMax, 0, "no blur")
            tryVerify(() => heatToasts().length === 1, 2000)
            compare(Notifications.shownCount - shown0, 1)
            compare(heatToasts()[0], "The console is running hot (Processor). Effects are reduced.")
            compare(Notifications.model.get(0).kind, "warning")
            compare(find("thermalNotice").shown, false, "hot is a toast, not a notice")

            // The same level again, and another sensor at the same level: nothing more is said.
            setCpu(92, "hot")
            Thermal.mockSet("mock:ssd", "ssd", 76, "hot")
            wait(100)
            compare(Notifications.shownCount - shown0, 1, "a repeat of the level does not toast twice")
            compare(DeviceSettings.effectsQuality, "performance")

            // Cooler but not normal: the limit stays, and the way back up is the same incident.
            setCpu(84, "warm")
            Thermal.mockSet("mock:ssd", "ssd", 60, "normal")
            tryCompare(Thermal, "level", "warm")
            compare(DeviceSettings.effectsQuality, "performance", "limited until the level is normal")
            setCpu(93, "hot")
            tryCompare(Thermal, "level", "hot")
            wait(100)
            compare(Notifications.shownCount - shown0, 1, "no new toast within one incident")

            // Normal: the owner's quality is back.
            setCpu(45, "normal")
            tryCompare(DeviceSettings, "effectsQuality", "high")
            compare(DeviceSettings.thermalLimited, false)
            // A new incident says it again.
            setCpu(95, "hot")
            tryVerify(() => Notifications.shownCount - shown0 === 2, 2000)
        }

        function test_the_owners_choice_made_while_limited_comes_back() {
            setCpu(91, "hot")
            tryCompare(DeviceSettings, "effectsQuality", "performance")
            DeviceSettings.effectsQuality = "balanced"
            compare(DeviceSettings.effectsQuality, "performance", "still limited")
            compare(DeviceSettings.storedEffectsQuality, "balanced")
            setCpu(40, "normal")
            tryCompare(DeviceSettings, "effectsQuality", "balanced")
        }

        function test_critical_shows_the_notice_stops_the_apps_and_powers_off() {
            Session.launch("org.example.Chess", "p2")
            tryVerify(() => Session.running.length === 1)
            const policy = find("thermalPolicy")
            policy.poweroffMs = 700
            setCpu(97, "critical")
            tryVerify(() => find("thermalNotice").shown, 2000, "the notice")
            compare(find("thermalNoticeTitle").text, "The console is too hot")
            compare(find("thermalNoticeSensor").text, "Processor is at 97 °C")
            verify(find("thermalNoticeDetail").text.indexOf("Apps are being closed") === 0)
            tryVerify(() => find("thermalNoticeOk").activeFocus, 2000, "the notice has the focus")
            compare(DeviceSettings.effectsQuality, "performance")
            // Every running app is asked to stop.
            tryVerify(() => stopSpy.count === 1, 2000)
            compare(stopSpy.signalArguments[0][1], "ok")
            tryVerify(() => Session.running.length === 0, 2000)
            // The power-off is a request after the grace time, not at once.
            compare(Power.actionCount, 0, "not yet")
            compare(policy.poweroffPending, true)
            tryCompare(Power, "actionCount", 1, 3000)
            compare(Power.lastAction, "poweroff")
        }

        function test_an_app_that_starts_while_critical_is_stopped_too() {
            find("thermalPolicy").poweroffMs = 5000
            setCpu(97, "critical")
            tryVerify(() => find("thermalNotice").shown, 2000)
            Session.launch("org.example.Chess", "p2")
            tryVerify(() => stopSpy.count >= 1, 2000, "the new app was asked to stop")
            tryVerify(() => Session.running.length === 0, 2000)
        }

        function test_critical_that_cools_down_does_not_power_off() {
            const shown0 = Notifications.shownCount
            find("thermalPolicy").poweroffMs = 500
            setCpu(97, "critical")
            tryVerify(() => find("thermalNotice").shown, 2000)
            tryVerify(() => find("homePlay") !== null)
            setCpu(88, "hot")
            tryVerify(() => !find("thermalNotice").shown, 2000, "the notice goes away")
            compare(find("thermalPolicy").poweroffPending, false)
            compare(Notifications.shownCount, shown0, "it was told by the notice already")
            wait(900)                                    // past the grace time
            compare(Power.actionCount, 0, "it cooled down in time")
            compare(DeviceSettings.effectsQuality, "performance", "still limited until normal")
            verify(find("homePlay").activeFocus, "focus is back where it was")
        }

        function test_the_notice_is_dismissed_with_ok_and_the_countdown_goes_on() {
            const policy = find("thermalPolicy")
            policy.poweroffMs = 5000
            setCpu(97, "critical")
            tryVerify(() => find("thermalNoticeOk").activeFocus, 2000)
            keyClick(Qt.Key_Down)                        // a modal: nothing leaks to the page below
            verify(find("thermalNoticeOk").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => !find("thermalNotice").shown, 2000)
            tryVerify(() => find("homePlay").activeFocus, 2000, "focus returns to Home")
            compare(policy.poweroffPending, true, "the policy goes on")
            // The notice is shown again for a new critical spell.
            setCpu(50, "normal")
            tryCompare(policy, "poweroffPending", false)
            setCpu(98, "critical")
            tryVerify(() => find("thermalNotice").shown, 2000)
            keyClick(Qt.Key_Escape)                      // Back dismisses, too
            tryVerify(() => !find("thermalNotice").shown, 2000)
        }

        function test_the_notice_counts_down() {
            find("thermalPolicy").poweroffMs = 4000
            setCpu(97, "critical")
            tryVerify(() => find("thermalNotice").shown, 2000)
            tryVerify(() => find("thermalNotice").secondsLeft <= 3, 3000, "the seconds go down")
            verify(find("thermalNoticeDetail").text.indexOf("powers off in") > 0)
        }

        // ---- Settings -> System

        function test_the_health_rows_show_label_value_and_mark() {
            openSystemPane()
            compare(find("healthHeading").text, "Device health")
            const cpu = find("health_mock:cpu")
            const ssd = find("health_mock:ssd")
            const fan = find("health_mock:fan")
            verify(cpu && ssd && fan, "one row per sensor")
            compare(cpu.label, "Processor")
            compare(cpu.value, "41 °C")
            compare(ssd.label, "Drive")
            compare(ssd.value, "38 °C")
            compare(fan.label, "Fan")
            compare(fan.value, "1820 rpm")
            compare(cpu.marked, false, "normal shows no mark")
            compare(find("healthLine").visible, false)
            compare(find("healthNone").visible, false)
            // Order: processor, drive, fan.
            verify(cpu.y < ssd.y && ssd.y < fan.y)
        }

        function test_rows_update_in_place_and_focus_stays() {
            openSystemPane()
            goTo("health_mock:fan")
            const fan = find("health_mock:fan")
            const cpu = find("health_mock:cpu")
            Thermal.mockSet("mock:fan", "fan", 2410, "normal")
            tryCompare(fan, "value", "2410 rpm")
            verify(find("health_mock:fan") === fan, "the same row, not a new one")
            verify(fan.activeFocus, "focus stays on the row while its value changes")

            setCpu(82, "warm")
            tryCompare(cpu, "marked", true)
            compare(cpu.value, "82 °C")
            compare(find("health_mock:cpu") === cpu, true)
            compare(cpu.level, "warm")
            compare(cpu.accessibleValue, "82 °C, Warm")
            verify(fan.activeFocus, "focus stays")
            compare(find("healthLine").visible, true)
            compare(find("healthLine").text, "The console is warm. Nothing needs to be done.")

            setCpu(92, "hot")
            tryCompare(cpu, "level", "hot")
            compare(find("healthLine").text, "The console is running hot. Visual effects are reduced until it cools down.")
            verify(fan.activeFocus)

            setCpu(40, "normal")
            tryCompare(cpu, "marked", false)
            compare(find("healthLine").visible, false)
            verify(fan.activeFocus)
        }

        function test_the_focused_row_going_away_moves_focus_to_a_neighbour() {
            openSystemPane()
            goTo("health_mock:ssd")
            Thermal.mockRemove("mock:ssd")
            tryVerify(() => find("health_mock:ssd") === null, 2000, "its row is gone")
            tryVerify(() => find("paneSystem").focusableRows().some(r => r.activeFocus), 2000, "focus is not lost")
        }

        function test_several_sensors_of_one_class_are_numbered_and_none_says_so() {
            Thermal.mockSet("mock:ssd2", "ssd", 44, "normal")
            tryVerify(() => Thermal.sensors.length === 4)
            openSystemPane()
            tryVerify(() => find("health_mock:ssd2") !== null, 2000)
            compare(find("health_mock:ssd").label, "Drive 1")
            compare(find("health_mock:ssd2").label, "Drive 2")
            compare(find("health_mock:cpu").label, "Processor")
            Thermal.mockClear()
            tryVerify(() => find("healthNone").visible, 2000)
            compare(find("healthNone").text, "No temperature sensors were found on this device.")
            compare(Thermal.level, "normal")
        }

        function test_the_language_follows() {
            openSystemPane()
            DeviceSettings.language = "tr"
            tryCompare(find("healthHeading"), "text", "Cihaz sağlığı")
            compare(find("health_mock:fan").value, "1820 dev/dk")
            compare(find("health_mock:cpu").label, "İşlemci")
        }

        function test_the_system_category_carries_the_heat_mark() {
            keyClick(Qt.Key_Up)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000)
            for (let i = 0; i < 20 && find("categoryList").currentIndex < systemIndex; ++i)
                keyClick(Qt.Key_Down)
            const mark = find("categoryHeatMark_system")
            compare(mark.visible, false, "normal shows nothing")
            setCpu(82, "warm")
            tryVerify(() => find("categoryHeatMark_system").visible, 2000, "a warm console is marked")
            compare(find("categoryHeatMark_system").color.toString(), Theme.warningText.toString())
            setCpu(92, "hot")
            tryVerify(() => find("categoryHeatMark_system").color.toString() === Theme.errorText.toString(), 2000)
            setCpu(40, "normal")
            tryVerify(() => !find("categoryHeatMark_system").visible, 2000)
            verify(find("categoryList").activeFocus, "focus untouched")
        }

        // ---- a late reply

        function test_a_late_list_is_dropped() {
            Thermal.mockRefreshDelayed(300)                 // a snapshot with everything normal
            compare(Thermal.mockPendingReplies(), 1)
            setCpu(91, "hot")                               // the service says it is hot now
            tryCompare(Thermal, "level", "hot")
            tryVerify(() => Thermal.mockPendingReplies() === 0, 2000)
            compare(Thermal.level, "hot", "the late snapshot did not bring 'normal' back")
            compare(DeviceSettings.effectsQuality, "performance")
        }

        // ---- screenshots (dev.ps1 shots)

        function test_zz_screenshots_normal() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openSystemPane()
            goTo("health_mock:fan")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/29-settings-health.png")
        }

        function test_zz_screenshots_warm() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            setCpu(83, "warm")
            tryCompare(Thermal, "level", "warm")
            openSystemPane()
            goTo("health_mock:fan")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/29-settings-health-warm.png")
        }

        function test_zz_screenshots_hot() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            setCpu(92, "hot")
            Thermal.mockSet("mock:ssd", "ssd", 76, "hot")
            tryCompare(Thermal, "level", "hot")
            tryCompare(DeviceSettings, "effectsQuality", "performance")
            openSystemPane()
            goTo("health_mock:fan")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/29-settings-health-hot.png")
        }

        function test_zz_screenshots_critical() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            find("thermalPolicy").poweroffMs = 60000
            setCpu(97, "critical")
            tryVerify(() => find("thermalNotice").shown, 2000)
            tryVerify(() => find("thermalNoticeOk").activeFocus, 2000)
            wait(1500)
            grabImage(tc.shell).save(shotsDir + "/29-thermal-critical.png")
        }

        function test_zz_screenshots_turkish() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            setCpu(92, "hot")
            tryCompare(Thermal, "level", "hot")
            DeviceSettings.language = "tr"
            openSystemPane()
            goTo("health_mock:fan")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/29-settings-health-tr.png")
        }
    }
}
