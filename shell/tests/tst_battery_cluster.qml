import QtQuick
import QtTest
import RuyaShell

// The device batteries in the status cluster (T-223) at the sizes a real display has: the cluster
// must clear the section nav on its left and stay inside the safe area at 720p, 1080p and 4K with
// the most chips it can hold, and `shots` saves it for review (1080p and 720p, one, two, four and
// five devices, charging, low, a crop at 1:1). Signs in as "Ada" (p2, no PIN).
Item {
    id: host
    width: 1920
    height: 1080

    Component {
        id: sizedShell
        Shell { version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "BatteryCluster"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Batteries.mockReset()
            tryVerify(() => Batteries.devices.length === 1 && Batteries.devices[0].percent === 60)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            const first = createTemporaryObject(sizedShell, host, { width: 1920, height: 1080 })
            verify(first)
            first.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => findChild(first, "profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => findChild(first, "homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            first.destroy()
            wait(50)
        }

        function openShell(w, h) {
            tc.shell = createTemporaryObject(sizedShell, host, { width: w, height: h })
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => find("homePlay") !== null && find("homePlay").activeFocus, 2000, "Home at " + h + "p")
            tryVerify(() => find("batteryStatus").visible, 2000, "the cluster shows batteries")
        }

        function test_the_cluster_clears_the_nav_with_five_devices_at_three_sizes() {
            Batteries.mockPopulate()
            for (const size of [[1280, 720], [1920, 1080], [3840, 2160]]) {
                openShell(size[0], size[1])
                tryVerify(() => find("batteryMore").visible, 2000, "three chips and a +N")
                const nav = find("sectionNav")
                const pill = find("statusGlass")
                const navRight = nav.mapToItem(tc.shell, nav.width, 0).x
                const u = tc.shell.u
                verify(navRight + 24 * u <= pill.x, size[1] + "p: the cluster starts at " + pill.x
                       + ", the nav ends at " + navRight)
                verify(pill.x + pill.width <= tc.shell.width - tc.shell.marginX + 1,
                       size[1] + "p: inside the safe area, right edge " + (pill.x + pill.width))
                const row = find("batteryStatus")
                verify(row.width + 2 * 8 * u <= pill.width, size[1] + "p: the chips sit inside the pill")
                tc.shell.destroy()
                wait(50)
            }
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            const cases = [
                ["one", () => { Batteries.mockSet("pad-1", 62, "discharging", "controller", "DualSense Wireless Controller") }],
                ["two", () => { Batteries.mockClear(); Batteries.mockSet("pad-1", 62, "charging", "controller", "DualSense Wireless Controller")
                                Batteries.mockSet("h", 41, "discharging", "headset", "WH-1000XM4") }],
                ["low", () => { Batteries.mockClear(); Batteries.mockSet("pad-1", 62, "discharging", "controller", "DualSense Wireless Controller")
                                Batteries.mockSet("h", 9, "discharging", "headset", "WH-1000XM4") }],
                ["four", () => { Batteries.mockPopulate() }],
                ["steps", () => { Batteries.mockClear(); Batteries.mockSet("a", 5, "unknown", "mouse", "A")
                                  Batteries.mockSet("b", 30, "unknown", "keyboard", "B")
                                  Batteries.mockSet("c", 55, "unknown", "headset", "C") }]
            ]
            for (const size of [[1920, 1080, "1080"], [1280, 720, "720"]]) {
                openShell(size[0], size[1])
                for (const c of cases) {
                    c[1]()
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/battery-" + size[2] + "-" + c[0] + ".png")
                    grabImage(find("statusGlass")).save(shotsDir + "/battery-" + size[2] + "-" + c[0] + "-crop.png")
                }
                tc.shell.destroy()
                wait(50)
            }
            // The light theme: the warning colour and the glyphs must still read on it.
            const before = DeviceSettings.theme
            DeviceSettings.theme = "daylight"
            openShell(1920, 1080)
            Batteries.mockPopulate()
            tryCompare(Theme, "mix", 1, 5000, "the theme has finished fading")
            tryVerify(() => !Theme.fade.running)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/battery-1080-daylight.png")
            grabImage(find("statusGlass")).save(shotsDir + "/battery-1080-daylight-crop.png")
            tc.shell.destroy()
            DeviceSettings.theme = before
        }
    }
}
