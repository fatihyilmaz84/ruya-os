import QtQuick
import QtTest
import RuyaShell

// The time zone (T-213, org.ruyaos.Devices1.Time): the mock follows the contract's statuses, the
// shell's clock follows a zone change at once, and Settings -> System has an admin-only "Time zone"
// row that opens a region / city picker driven with the controller keys. The first-boot step is in
// tst_setup.qml. Own file: it changes the (process-wide) zone and the language.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: finishedSpy; target: TimeZone; signalName: "setTimezoneFinished" }

    TestCase {
        id: tc
        name: "TimeZone"
        when: windowShown

        property Shell shell: null
        readonly property int systemIndex: 8
        // 2027-01-15 08:00:00 UTC (a winter instant, so no daylight saving in any zone used here).
        readonly property real instant: 1800000000000

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            tryCompare(Profiles, "activeProfile", "")
            TimeZone.mockReset()
            tryCompare(TimeZone, "timezone", "UTC")
            tryVerify(() => TimeZone.timezones.length > 0)
            DeviceSettings.language = "en"
            finishedSpy.clear()
        }

        function cleanup() {
            TimeZone.mockReset()
            Notifications.durationMs = Theme.toastMs
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
            DeviceSettings.language = "en"
            DeviceSettings.reducedMotion = false
        }

        // The reply status of one SetTimezone call.
        function setZone(name) {
            const before = finishedSpy.count
            TimeZone.setTimezone(name)
            tryCompare(finishedSpy, "count", before + 1)
            return finishedSpy.signalArguments[before][1]
        }

        function startShell() {
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
        }

        // ---- the mock follows the contract ----

        function test_the_mock_follows_the_contract() {
            compare(setZone("Mars/Olympus_Mons"), "invalid")
            compare(setZone(""), "invalid")
            compare(TimeZone.timezone, "UTC")

            TimeZone.mockSetCallerAllowed(false)
            compare(setZone("Asia/Tokyo"), "forbidden", "a caller that may not")
            compare(TimeZone.timezone, "UTC")
            TimeZone.mockSetCallerAllowed(true)

            TimeZone.mockFailNext()
            compare(setZone("Asia/Tokyo"), "failed")
            compare(TimeZone.timezone, "UTC", "a failed call changes nothing")

            compare(setZone("Asia/Tokyo"), "ok")
            tryCompare(TimeZone, "timezone", "Asia/Tokyo")
            compare(finishedSpy.signalArguments[finishedSpy.count - 1][0], "Asia/Tokyo")
            compare(setZone("Asia/Tokyo"), "ok", "the zone it already has is ok")

            TimeZone.mockSetOutside("Europe/Istanbul")      // someone ran timedatectl
            tryCompare(TimeZone, "timezone", "Europe/Istanbul")
        }

        function test_the_zones_are_grouped_by_region() {
            const regions = TimeZone.regions
            verify(regions.indexOf("Europe") >= 0 && regions.indexOf("Asia") >= 0 && regions.indexOf("America") >= 0)
            compare(regions[regions.length - 1], "Other", "names without a region come last")
            const sorted = regions.slice(0, regions.length - 1)
            compare(JSON.stringify(sorted), JSON.stringify(sorted.slice().sort()), "the others are alphabetical")
            const europe = TimeZone.citiesIn("Europe")
            verify(europe.length > 5)
            compare(europe[0].zone.indexOf("Europe/"), 0)
            verify(europe.some(c => c.zone === "Europe/Istanbul" && c.city === "Istanbul"))
            const argentina = TimeZone.citiesIn("America").find(c => c.zone === "America/Argentina/Buenos_Aires")
            verify(argentina, "a three-part name is listed under its region")
            compare(argentina.city, "Argentina / Buenos Aires", "readable: slashes and underscores")
            compare(TimeZone.citiesIn("Other")[0].zone, "UTC")
            compare(TimeZone.regionOf("Europe/Istanbul"), "Europe")
            compare(TimeZone.regionOf("UTC"), "Other")
            compare(TimeZone.defaultZoneFor("tr"), "Europe/Istanbul")
            compare(TimeZone.defaultZoneFor("en"), "Europe/London")
        }

        function test_a_late_state_reply_does_not_undo_a_newer_zone() {
            TimeZone.mockRefreshDelayed(300)                // asks now, answers "UTC" in 300 ms
            compare(TimeZone.mockPendingReplies(), 1)
            TimeZone.mockSetOutside("Asia/Tokyo")           // a newer state is published at once
            tryCompare(TimeZone, "timezone", "Asia/Tokyo")
            tryVerify(() => TimeZone.mockPendingReplies() === 0)   // the old answer has landed ...
            wait(50)
            compare(TimeZone.timezone, "Asia/Tokyo", "... and was dropped")
        }

        function test_a_late_state_reply_does_not_undo_a_zone_that_was_set() {
            TimeZone.mockRefreshDelayed(300)                // a GetTimezone on its way, answering "UTC"
            compare(TimeZone.mockPendingReplies(), 1)
            compare(setZone("Asia/Tokyo"), "ok")
            compare(TimeZone.timezone, "Asia/Tokyo")
            tryVerify(() => TimeZone.mockPendingReplies() === 0)
            wait(50)
            compare(TimeZone.timezone, "Asia/Tokyo", "the old reply was dropped")
        }

        // ---- the clock ----

        function test_the_clock_text_is_in_the_zone() {
            compare(TimeZone.formatClock(tc.instant), "08:00", "UTC")
            TimeZone.mockSetOutside("Asia/Tokyo")
            tryCompare(TimeZone, "timezone", "Asia/Tokyo")
            compare(TimeZone.formatClock(tc.instant), "17:00", "UTC+9")
            TimeZone.mockSetOutside("Pacific/Honolulu")
            tryCompare(TimeZone, "timezone", "Pacific/Honolulu")
            compare(TimeZone.formatClock(tc.instant), "22:00", "UTC-10, the evening before")
            TimeZone.mockSetOutside("Asia/Kathmandu")
            tryCompare(TimeZone, "timezone", "Asia/Kathmandu")
            compare(TimeZone.formatClock(tc.instant), "13:45", "UTC+5:45")
        }

        function test_the_status_clock_follows_a_zone_change_at_once() {
            startShell()
            const clock = find("statusClock")
            verify(clock)
            // Compared with the same instant's text, so a minute rollover cannot fail it.
            tryVerify(() => clock.text === TimeZone.formatClock(Date.now()), 2000, "shows the zone's time")
            const utc = clock.text
            TimeZone.mockSetOutside("Pacific/Honolulu")     // 10 hours earlier than UTC
            tryVerify(() => clock.text === TimeZone.formatClock(Date.now()), 2000, "follows without waiting for the next tick")
            verify(clock.text !== utc, "the text changed with the zone: " + clock.text + " vs " + utc)
            TimeZone.mockSetOutside("Asia/Tokyo")
            tryVerify(() => clock.text === TimeZone.formatClock(Date.now()), 2000)
            verify(TimeZone.formatClock(Date.now()) !== TimeZone.formatClock(Date.now() + 3 * 3600 * 1000), "three hours is a visible difference")
        }

        // ---- Settings -> System ----

        function openSystemPane(id, pin) {
            startShell()
            tryVerify(() => Profiles.profiles.length === 3)
            Profiles.switchTo(id, pin)
            tryCompare(Profiles, "activeProfile", id)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
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

        function goToRow(name) {
            for (let i = 0; i < 20; ++i) {
                const row = find(name)
                if (row && row.activeFocus)
                    return
                keyClick(Qt.Key_Down)
            }
            fail("could not reach row " + name)
        }

        function pressUntil(key, done, what) {
            for (let i = 0; i < 40 && !done(); ++i)
                keyClick(key)
            verify(done(), what)
        }

        function test_the_row_is_for_admins_only() {
            openSystemPane("p2", "")                      // Ada: standard
            compare(find("rowTimezone").visible, false, "a standard user has no Time zone row")
            tc.shell.destroy()
            openSystemPane("p1", "1234")                  // Player One: admin
            verify(find("rowTimezone").visible, "an admin has it")
            compare(find("rowTimezone").value, "UTC")
            goToRow("rowTimezone")
            verify(find("rowTimezone").activeFocus)
        }

        function test_an_admin_picks_a_region_then_a_city() {
            openSystemPane("p1", "1234")
            goToRow("rowTimezone")
            keyClick(Qt.Key_Return)
            const picker = find("zonePicker")
            tryVerify(() => picker.shown, 2000, "the picker opens")
            tryVerify(() => find("zoneRegions").activeFocus, 2000, "the regions have focus")
            const chooser = find("zoneChooser")
            compare(chooser.region, "Other", "it opens on the current zone's region (UTC)")
            compare(chooser.selectedZone, "UTC")
            compare(find("zoneCity_UTC").marked, true, "and marks the current zone")

            pressUntil(Qt.Key_Up, () => chooser.region === "Europe", "Up reaches Europe")
            verify(find("zoneRegions").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("zoneCities").activeFocus, 2000, "the cities have focus")
            pressUntil(Qt.Key_Down, () => chooser.selectedZone === "Europe/Istanbul", "Down reaches Istanbul")
            keyClick(Qt.Key_Return)
            tryVerify(() => !picker.shown, 2000, "the picker closes")
            tryCompare(TimeZone, "timezone", "Europe/Istanbul")
            tryCompare(find("rowTimezone"), "value", "Europe/Istanbul")
            tryVerify(() => find("rowTimezone").activeFocus, 2000, "focus is back on the row")
            tryVerify(() => Notifications.model.count > 0 && Notifications.model.get(0).text === "Time zone set to Europe/Istanbul")
        }

        function hintsShown() {
            const bar = find("hintBar")
            if (!bar.visible)
                return ""
            const parts = []
            for (const b of ["A", "B"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        function test_the_picker_says_what_a_and_b_do() {
            openSystemPane("p1", "1234")
            goToRow("rowTimezone")
            compare(hintsShown(), "A Select|B Back", "the pane")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("zoneRegions").activeFocus, 2000)
            compare(hintsShown(), "A Select|B Cancel", "the picker: A chooses, B cancels")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("zonePicker").shown, 2000)
            compare(hintsShown(), "A Select|B Back")
        }

        function test_the_selected_region_stays_marked_while_the_cities_have_focus() {
            openSystemPane("p1", "1234")
            goToRow("rowTimezone")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("zoneRegions").activeFocus, 2000)
            const row = find("zoneRegion_Other")
            compare(row.focused, true)
            compare(row.restingSelection, false)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("zoneCities").activeFocus)
            compare(row.focused, false)
            compare(row.restingSelection, true, "the region the cities belong to keeps the selected look")
            compare(row.color, Theme.selectedFill)
        }

        function test_back_closes_the_picker_without_choosing() {
            openSystemPane("p1", "1234")
            goToRow("rowTimezone")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("zoneRegions").activeFocus, 2000)
            keyClick(Qt.Key_Right)                          // into the cities of "Other"
            tryVerify(() => find("zoneCities").activeFocus)
            keyClick(Qt.Key_Escape)                         // Back: the regions
            tryVerify(() => find("zoneRegions").activeFocus)
            verify(find("zonePicker").shown, "the picker is still open")
            keyClick(Qt.Key_Escape)                         // Back on the regions: closes
            tryVerify(() => !find("zonePicker").shown, 2000)
            tryVerify(() => find("rowTimezone").activeFocus, 2000, "focus is back on the row")
            compare(TimeZone.mockSetCalls(), 0)
            compare(TimeZone.timezone, "UTC")
        }

        function test_a_refusal_is_told() {
            openSystemPane("p1", "1234")
            goToRow("rowTimezone")
            TimeZone.mockSetCallerAllowed(false)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("zoneRegions").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("zoneCities").activeFocus)
            keyClick(Qt.Key_Return)                         // UTC again
            tryVerify(() => !find("zonePicker").shown, 2000)
            tryVerify(() => Notifications.model.count > 0 && Notifications.model.get(0).text === "Only an admin can do this.")
            compare(TimeZone.timezone, "UTC")
            tryVerify(() => find("rowTimezone").activeFocus, 2000, "focus is back on the row")
        }

        function test_a_clock_that_is_not_set_says_so() {
            openSystemPane("p2", "")
            compare(find("timeNtpNote").visible, false, "synchronised: no note")
            TimeZone.mockSetNtp(false)
            tryVerify(() => find("timeNtpNote").visible, 2000)
            TimeZone.mockSetNtp(true)
            tryVerify(() => !find("timeNtpNote").visible, 2000)
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            // The final state of the picture, not a fade: without animations it does not depend on how fast the window renders.
            DeviceSettings.reducedMotion = true
            openSystemPane("p1", "1234")
            goToRow("rowTimezone")
            tryVerify(() => find("rowTimezone").opacity === 1, 5000, "the row is drawn")
            wait(1000)
            grabImage(tc.shell)                              // the first grab can be of the frame before the last change
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/16-settings-timezone-row.png")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("zoneRegions").activeFocus, 2000)
            const chooser = find("zoneChooser")
            pressUntil(Qt.Key_Up, () => chooser.region === "Europe", "Up reaches Europe")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("zoneCities").activeFocus, 2000)
            pressUntil(Qt.Key_Down, () => chooser.selectedZone === "Europe/Istanbul", "Down reaches Istanbul")
            tryCompare(find("zonePicker"), "opacity", 1, 10000, "the picker is shown")
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/17-settings-timezone-picker.png")
        }
    }
}
