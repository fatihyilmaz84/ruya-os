import QtQuick
import QtTest
import RuyaShell

// The batteries of the wireless devices (Batteries, UPower behind it) against the mock backend:
// one chip per device in the status cluster on Home (kind icon, level glyph, percentage), and the
// low-battery toast for controllers. Signs in as "Ada" (p2, no PIN). The mock is reset before
// every test.
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

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        function chip(id) { return find("batteryChip_" + id) }
        function inChip(id, name) { return findChild(chip(id), name) }
        function levelIcon(id) { return inChip(id, "batteryLevelIcon").name }
        function kindIcon(id) { return inChip(id, "batteryKindIcon").name }
        function percentText(id) { return inChip(id, "batteryPercent").text }
        function devicePercent(id) {
            const d = Batteries.devices.find(x => x.id === id)
            return d ? d.percent : -1
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Batteries.mockReset()
            tryVerify(() => Batteries.devices.length === 1 && Batteries.devices[0].percent === 60)
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

        // The ids of the chips in the cluster, left to right (the Row keeps the model's order).
        function chipIds() {
            const row = find("batteryStatus")
            const found = []
            for (let i = 0; i < row.children.length; ++i) {
                const name = row.children[i].objectName
                if (name.startsWith("batteryChip_"))
                    found.push(name.substring("batteryChip_".length))
            }
            return found
        }

        function test_one_device_shows_a_chip() {
            const status = find("batteryStatus")
            tryVerify(() => status.visible, 2000, "a controller at 60 %")
            tryVerify(() => chip("pad-1") !== null)
            compare(percentText("pad-1"), "60%")
            compare(kindIcon("pad-1"), "sports_esports")
            compare(levelIcon("pad-1"), "battery_4_bar")
            compare(chip("pad-1").Accessible.name, "Ruya Pad Pro battery 60 percent")
            verify(inChip("pad-1", "batteryKindIcon").known, "the kind glyph is in the icon table")
            verify(inChip("pad-1", "batteryLevelIcon").known, "the level glyph is in the icon table")
            compare(find("batteryMore").visible, false, "no +N for one device")
            // Centred in the pill, like the clock.
            const pill = find("statusGlass")
            const mid = status.mapToItem(pill, 0, status.height / 2).y
            verify(Math.abs(mid - pill.height / 2) < 2, "centred in the status cluster: " + mid)
            verify(find("homePlay").activeFocus, "the battery never takes focus")
        }

        // Not live: the steps, the states that override them, and the kinds.
        function test_level_glyph_function() {
            const c = chip("pad-1")
            verify(c)
            const steps = [[0, "battery_0_bar"], [7, "battery_0_bar"], [8, "battery_1_bar"], [21, "battery_1_bar"],
                           [22, "battery_2_bar"], [35, "battery_2_bar"], [36, "battery_3_bar"], [50, "battery_3_bar"],
                           [51, "battery_4_bar"], [64, "battery_4_bar"], [65, "battery_5_bar"], [78, "battery_5_bar"],
                           [79, "battery_full"], [100, "battery_full"]]
            for (const [percent, name] of steps)
                compare(c.levelIconFor(percent, "discharging", false), name, percent + " %")
            compare(c.levelIconFor(40, "charging", false), "battery_charging_full")
            compare(c.levelIconFor(5, "discharging", true), "battery_alert")
            compare(c.levelIconFor(90, "full", false), "battery_full")
            // The glyph is DeviceIcons' (one table for every screen); the chip asks it for kind and family.
            compare(DeviceIcons.iconFor("controller", ""), "sports_esports")
            compare(DeviceIcons.iconFor("headset", ""), "headphones")
            compare(DeviceIcons.iconFor("speaker", ""), "speaker")
            compare(DeviceIcons.iconFor("mouse", ""), "mouse")
            compare(DeviceIcons.iconFor("keyboard", ""), "keyboard")
            compare(DeviceIcons.iconFor("other", ""), "bluetooth")
            compare(DeviceIcons.iconFor("", ""), "bluetooth")
            compare(DeviceIcons.iconFor("toaster", ""), "bluetooth")
        }

        // Live, in the cluster. State "unknown" is neither low nor charging, so the level alone
        // picks the glyph (a discharging pad at 15 % or less shows the alert instead).
        function test_the_glyph_follows_the_level_in_seven_steps() {
            const steps = [[0, "battery_0_bar"], [7, "battery_0_bar"], [8, "battery_1_bar"], [35, "battery_2_bar"],
                           [36, "battery_3_bar"], [64, "battery_4_bar"], [65, "battery_5_bar"], [78, "battery_5_bar"],
                           [79, "battery_full"], [100, "battery_full"]]
            for (const [percent, name] of steps) {
                Batteries.mockSet("pad-1", percent, "unknown")
                tryCompare(inChip("pad-1", "batteryPercent"), "text", percent + "%")
                compare(levelIcon("pad-1"), name, percent + " %")
            }
        }

        function test_each_kind_has_its_icon() {
            Batteries.mockClear()
            Batteries.mockSet("h", 70, "discharging", "headset", "WH-1000XM4")
            Batteries.mockSet("k", 71, "discharging", "keyboard", "Ruya Keys")
            Batteries.mockSet("m", 72, "discharging", "mouse", "Ruya Mouse")
            tryVerify(() => chip("m") !== null && chip("k") !== null && chip("h") !== null)
            compare(kindIcon("h"), "headphones")
            compare(kindIcon("k"), "keyboard")
            compare(kindIcon("m"), "mouse")
            Batteries.mockRemove("m")
            Batteries.mockRemove("k")
            Batteries.mockSet("s", 73, "discharging", "speaker", "Soundbar")
            Batteries.mockSet("o", 74, "discharging", "other", "Thing")
            tryVerify(() => chip("o") !== null && chip("s") !== null)
            compare(kindIcon("s"), "speaker")
            compare(kindIcon("o"), "bluetooth")
        }

        function test_charging_uses_the_bolt() {
            Batteries.mockSet("pad-1", 40, "charging")
            tryCompare(inChip("pad-1", "batteryLevelIcon"), "name", "battery_charging_full")
            compare(chip("pad-1").Accessible.name, "Ruya Pad Pro battery 40 percent, charging")
            compare(inChip("pad-1", "batteryPercent").color, Theme.text, "no warning while charging")
        }

        function test_low_uses_the_alert_glyph_and_the_warning_colour() {
            Batteries.mockSet("pad-1", 16)
            tryCompare(inChip("pad-1", "batteryPercent"), "text", "16%")
            compare(levelIcon("pad-1"), "battery_1_bar", "16 % is not low")
            compare(inChip("pad-1", "batteryPercent").color, Theme.text)
            Batteries.mockSet("pad-1", 15)
            tryCompare(inChip("pad-1", "batteryLevelIcon"), "name", "battery_alert")
            compare(inChip("pad-1", "batteryLevelIcon").color, Theme.warningText)
            compare(inChip("pad-1", "batteryKindIcon").color, Theme.warningText)
            compare(inChip("pad-1", "batteryPercent").color, Theme.warningText)
            compare(chip("pad-1").Accessible.name, "Ruya Pad Pro battery 15 percent, low")
            Batteries.mockSet("pad-1", 9, "charging")
            tryCompare(inChip("pad-1", "batteryLevelIcon"), "name", "battery_charging_full")
            compare(inChip("pad-1", "batteryPercent").color, Theme.text, "charging at 9 % is not a warning")
        }

        function test_lowest_first_and_a_plus_n_beyond_three() {
            Batteries.mockPopulate()
            // mouse 12, pad-2 41, pad-1 62 (charging), headset 78, keyboard 94. The slots go to pads and
            // headsets first, the lowest first (T-301); beside the "N more" chip (whose words are wider than the
            // old "+N") two chips fit here, the three only when nothing is left over.
            tryCompare(find("batteryMore"), "visible", true)
            tryCompare(find("batteryMore"), "count", 3)
            tryVerify(() => chipIds().length === 2)
            compare(chipIds(), ["pad-2", "pad-1"], "the lowest pads and headsets, lowest first, not the mouse at 12")
            compare(chip("headset-1"), null)
            compare(chip("mouse-1"), null)
            compare(chip("keyboard-1"), null)
            compare(find("batteryMore").Accessible.name,
                    "3 more devices with a battery: WH-1000XM4 78 percent, Ruya Mouse 12 percent, Ruya Keyboard 94 percent")
            // Drop one: the count follows.
            Batteries.mockRemove("mouse-1")
            tryCompare(find("batteryMore"), "count", 2)
            compare(chipIds(), ["pad-2", "pad-1"])
            // Down to three devices: all three are chips and nothing is left for the "N more" chip.
            Batteries.mockRemove("keyboard-1")
            tryCompare(find("batteryMore"), "visible", false)
            tryVerify(() => chip("headset-1") !== null)
            compare(chipIds(), ["pad-2", "pad-1", "headset-1"])
        }

        function test_equal_levels_put_the_discharging_one_first() {
            Batteries.mockClear()
            Batteries.mockSet("a", 20, "charging")
            Batteries.mockSet("b", 20, "discharging")
            tryVerify(() => chip("a") !== null && chip("b") !== null)
            compare(chipIds(), ["b", "a"])
            Batteries.mockClear()
            Batteries.mockSet("b", 20, "discharging")
            Batteries.mockSet("a", 20, "charging")
            tryVerify(() => chip("a") !== null && chip("b") !== null)
            compare(chipIds(), ["b", "a"], "whichever comes first in the list")
        }

        function test_chips_update_in_place() {
            Batteries.mockSet("pad-2", 90, "discharging", "controller", "Second Pad")
            tryVerify(() => chip("pad-2") !== null && chip("pad-1") !== null)
            const first = chip("pad-1")
            const second = chip("pad-2")
            Batteries.mockSet("pad-1", 58)
            tryCompare(inChip("pad-1", "batteryPercent"), "text", "58%")
            verify(chip("pad-1") === first, "the chip is the same item, only its level changed")
            verify(chip("pad-2") === second)
            compare(levelIcon("pad-1"), "battery_4_bar")
            Batteries.mockSet("pad-1", 50)
            tryCompare(inChip("pad-1", "batteryLevelIcon"), "name", "battery_3_bar")
            verify(chip("pad-1") === first)
        }

        function test_a_device_that_disconnects_loses_its_chip() {
            Batteries.mockSet("pad-2", 35, "discharging", "controller", "Second Pad")
            tryVerify(() => chip("pad-2") !== null)
            compare(chipIds(), ["pad-2", "pad-1"])
            Batteries.mockRemove("pad-2")
            tryVerify(() => chip("pad-2") === null)
            compare(chipIds(), ["pad-1"])
            Batteries.mockClear()
            tryVerify(() => Batteries.devices.length === 0)
            tryVerify(() => !find("batteryStatus").visible, 2000)
            Batteries.mockSet("pad-1", 80)
            tryVerify(() => find("batteryStatus").visible, 2000)
            tryVerify(() => chip("pad-1") !== null)
            compare(percentText("pad-1"), "80%")
        }

        function test_a_device_without_a_reading_has_no_chip() {
            Batteries.mockSet("pad-2", -1, "unknown", "headset", "Silent Headset")
            Batteries.mockSet("pad-1", 61)
            tryCompare(inChip("pad-1", "batteryPercent"), "text", "61%")
            compare(Batteries.devices.length, 1, "not even in the list")
            compare(chip("pad-2"), null)
            Batteries.mockSet("pad-2", 55)
            tryVerify(() => chip("pad-2") !== null)
            Batteries.mockSet("pad-2", -1)
            tryVerify(() => chip("pad-2") === null)
        }

        function test_a_full_device_on_the_charger_has_no_chip() {
            Batteries.mockSet("pad-1", 100, "charging")
            tryVerify(() => !find("batteryStatus").visible, 2000, "100 % on the charger: nothing to show")
            compare(chip("pad-1"), null)
            compare(Batteries.devices.length, 1, "it is still listed")
            Batteries.mockSet("pad-1", 99, "charging")
            tryVerify(() => chip("pad-1") !== null)
            compare(levelIcon("pad-1"), "battery_charging_full")
            Batteries.mockSet("pad-1", 100, "full")
            tryVerify(() => chip("pad-1") === null)
            Batteries.mockSet("pad-1", 100, "discharging")
            tryVerify(() => chip("pad-1") !== null, 2000, "unplugged at 100 %: back")
            compare(levelIcon("pad-1"), "battery_full")
        }

        function test_an_older_reply_arriving_late_is_dropped() {
            // pad-1 is at 60 %. Ask again (the reply, a snapshot at 60 %, is held back), then the
            // level falls to 40 %: the late reply must not put 60 % back.
            Batteries.mockRefreshDelayed(150)
            compare(Batteries.mockPendingReplies(), 1)
            Batteries.mockSet("pad-1", 40)
            tryVerify(() => devicePercent("pad-1") === 40)
            tryVerify(() => Batteries.mockPendingReplies() === 0)
            compare(devicePercent("pad-1"), 40, "the late 60 % reply was dropped")
            tryCompare(inChip("pad-1", "batteryPercent"), "text", "40%")
        }

        function test_low_battery_toast_once_and_not_while_charging() {
            Batteries.mockSet("pad-1", 16)
            tryCompare(inChip("pad-1", "batteryPercent"), "text", "16%")
            compare(lowSpy.count, 0, "above the limit")
            compare(levelIcon("pad-1"), "battery_1_bar")
            Batteries.mockSet("pad-1", 15)
            tryCompare(lowSpy, "count", 1)
            tryVerify(() => lowToasts().length === 1, 2000)
            compare(lowToasts()[0], "Controller battery low")
            compare(Notifications.model.get(Notifications.model.count - 1).detail.slice(-3), "15%")
            tryCompare(inChip("pad-1", "batteryLevelIcon"), "name", "battery_alert")
            Batteries.mockSet("pad-1", 14)
            tryCompare(inChip("pad-1", "batteryPercent"), "text", "14%")
            Batteries.mockSet("pad-1", 9)
            tryCompare(inChip("pad-1", "batteryPercent"), "text", "9%")
            compare(lowSpy.count, 1, "still low: not repeated at 14 % or 9 %")
            compare(lowToasts().length, 1)
            // Charging: no toast, and the rule re-arms.
            Batteries.mockSet("pad-1", 9, "charging")
            tryCompare(inChip("pad-1", "batteryLevelIcon"), "name", "battery_charging_full")
            Batteries.mockSet("pad-1", 10)
            tryCompare(lowSpy, "count", 2)
        }

        function test_charging_at_a_low_level_never_toasts() {
            Batteries.mockSet("pad-1", 5, "charging")
            tryCompare(inChip("pad-1", "batteryPercent"), "text", "5%")
            compare(lowSpy.count, 0)
            compare(lowToasts().length, 0)
        }

        function test_a_charging_low_pad_does_not_toast_but_the_discharging_one_does() {
            Batteries.mockSet("pad-1", 10, "charging")
            Batteries.mockSet("pad-2", 12, "discharging")
            tryVerify(() => chip("pad-2") !== null && chip("pad-1") !== null)
            tryCompare(inChip("pad-2", "batteryLevelIcon"), "name", "battery_alert", 2000, "warning state, like the toast")
            compare(levelIcon("pad-1"), "battery_charging_full")
            tryVerify(() => lowToasts().length === 1, 2000)
            compare(lowToasts()[0], "Controller battery low")
            compare(Notifications.model.get(Notifications.model.count - 1).detail.slice(-3), "12%")
            compare(lowSpy.count, 1, "only the discharging pad was reported")
            compare(lowSpy.signalArguments[0][0], "pad-2")
        }

        function test_a_low_headset_warns_in_the_cluster_but_not_here() {
            // Headsets toast through Bluetooth.batteryLow, not through Batteries (no double toast).
            Batteries.mockSet("h", 10, "discharging", "headset", "WH-1000XM4")
            tryVerify(() => chip("h") !== null)
            tryCompare(inChip("h", "batteryLevelIcon"), "name", "battery_alert")
            wait(100)
            compare(lowSpy.count, 0, "Batteries.batteryLow is for controllers")
            compare(lowToasts().length, 0)
        }

        function test_a_bluetooth_controller_does_not_toast_twice() {
            // The same pad is also a Bluetooth device (kind "controller"): Batteries owns it.
            Bluetooth.mockReset()
            tryVerify(() => Bluetooth.devices.length === 3)
            Batteries.mockSet("pad-1", 12)
            Bluetooth.mockSetBattery("bt-pad-main", 12)
            tryCompare(inChip("pad-1", "batteryPercent"), "text", "12%")
            tryVerify(() => lowToasts().length === 1, 2000)
            tryVerify(() => Bluetooth.devices.find(d => d.id === "bt-pad-main").battery === 12)
            compare(btLowSpy.count, 0, "Bluetooth does not report a controller")
            compare(toastTexts().filter(t => t.includes("battery low")).length, 1, "one toast for one controller")
        }
    }
}
