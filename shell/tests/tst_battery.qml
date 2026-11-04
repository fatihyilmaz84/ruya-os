import QtQuick
import QtTest
import RuyaShell

// The controller battery (Batteries, UPower behind it) against the mock backend: the status
// cluster icon on Home, and the low-battery toast. Signs in as "Ada" (p2, no PIN). The mock is
// reset before every test.
Item {
    id: host
    width: 1280
    height: 720

    SignalSpy { id: lowSpy; target: Batteries; signalName: "batteryLow" }
    SignalSpy { id: btLowSpy; target: Bluetooth; signalName: "batteryLow" }

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "Battery"
        when: windowShown

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Batteries.mockReset()
            tryVerify(() => Batteries.controllers.length === 1 && Batteries.lowest === 60)
            lowSpy.clear()
            btLowSpy.clear()
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
            clearToasts()
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

        function lowToasts() {
            return toastTexts().filter(t => t.startsWith("Controller battery low"))
        }

        function test_one_controller_shows_the_icon_and_level() {
            const status = find("batteryStatus")
            tryVerify(() => status.visible, 2000, "a controller at 60 %")
            compare(find("batteryLevel").text, "60%")
            compare(find("batteryIcon").name, "battery_full")
            compare(status.Accessible.name, "Controller battery 60%")
            verify(find("batteryIcon").known, "the glyph is in the icon table")
            // Centred in the pill, like the clock.
            const pill = find("statusGlass")
            const mid = status.mapToItem(pill, 0, status.height / 2).y
            verify(Math.abs(mid - pill.height / 2) < 2, "centred in the status cluster: " + mid)
            verify(find("homePlay").activeFocus, "the battery never takes focus")
        }

        function test_no_controller_hides_the_icon() {
            Batteries.mockClear()
            tryCompare(Batteries, "lowest", -1)
            tryVerify(() => !find("batteryStatus").visible, 2000)
            Batteries.mockSet("pad-1", 80)
            tryVerify(() => find("batteryStatus").visible, 2000)
            compare(find("batteryLevel").text, "80%")
        }

        function test_the_lowest_controller_wins() {
            Batteries.mockSet("pad-2", 35)
            tryCompare(Batteries, "lowest", 35)
            tryCompare(find("batteryLevel"), "text", "35%")
            Batteries.mockRemove("pad-2")
            tryCompare(find("batteryLevel"), "text", "60%")
        }

        function test_low_battery_toast_once_and_not_while_charging() {
            Batteries.mockSet("pad-1", 16)
            tryCompare(Batteries, "lowest", 16)
            compare(lowSpy.count, 0, "above the limit")
            compare(find("batteryIcon").name, "battery_full")
            Batteries.mockSet("pad-1", 15)
            tryCompare(lowSpy, "count", 1)
            tryVerify(() => lowToasts().length === 1, 2000)
            compare(lowToasts()[0], "Controller battery low (15%)")
            compare(find("batteryIcon").name, "battery_alert")
            Batteries.mockSet("pad-1", 14)
            tryCompare(Batteries, "lowest", 14)
            Batteries.mockSet("pad-1", 9)
            tryCompare(Batteries, "lowest", 9)
            compare(lowSpy.count, 1, "still low: not repeated at 14 % or 9 %")
            compare(lowToasts().length, 1)
            // Charging: no toast, and the rule re-arms.
            Batteries.mockSet("pad-1", 9, "charging")
            tryCompare(Batteries, "lowestState", "charging")
            compare(find("batteryIcon").name, "battery_charging_full")
            Batteries.mockSet("pad-1", 10)
            tryCompare(lowSpy, "count", 2)
        }

        function test_charging_at_a_low_level_never_toasts() {
            Batteries.mockSet("pad-1", 5, "charging")
            tryCompare(Batteries, "lowest", 5)
            tryCompare(Batteries, "lowestState", "charging")
            compare(lowSpy.count, 0)
            compare(lowToasts().length, 0)
        }

        function test_a_bluetooth_controller_does_not_toast_twice() {
            // The same pad is also a Bluetooth device (kind "controller"): Batteries owns it.
            Bluetooth.mockReset()
            tryVerify(() => Bluetooth.devices.length === 3)
            Batteries.mockSet("pad-1", 12)
            Bluetooth.mockSetBattery("bt-pad-main", 12)
            tryCompare(Batteries, "lowest", 12)
            tryVerify(() => lowToasts().length === 1, 2000)
            tryVerify(() => Bluetooth.devices.find(d => d.id === "bt-pad-main").battery === 12)
            compare(btLowSpy.count, 0, "Bluetooth does not report a controller")
            compare(toastTexts().filter(t => t.includes("battery low")).length, 1, "one toast for one controller")
        }
    }
}
