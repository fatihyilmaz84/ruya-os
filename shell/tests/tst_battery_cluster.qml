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

        // The chips are laid out left to right: each starts after the one before it.
        function settled() {
            const row = find("batteryStatus")
            let right = -1
            for (const child of row.children) {
                if (!child.visible || child.width === 0)
                    continue
                if (child.x < right)
                    return false
                right = child.x + child.width
            }
            return true
        }

        function chipIds() {
            const row = find("batteryStatus")
            const found = []
            for (const child of row.children) {
                if (child.objectName.startsWith("batteryChip_"))
                    found.push(child.objectName)
            }
            return found
        }

        function checkCluster(size, what, expectedDevices) {
            waitForRendering(tc.shell)       // the Row lays out on the next frame
            tryVerify(() => settled(), 2000, what + ": the chips are laid out")
            const nav = find("sectionNav")
            const pill = find("statusGlass")
            const u = tc.shell.u
            const navRight = nav.mapToItem(tc.shell, nav.width, 0).x
            verify(navRight + 24 * u <= pill.x + 0.5, what + " at " + size[1] + "p: the cluster starts at " + pill.x
                   + ", the nav ends at " + navRight)
            verify(pill.x + pill.width <= tc.shell.width - tc.shell.marginX + 1,
                   what + " at " + size[1] + "p: inside the safe area, right edge " + (pill.x + pill.width))
            const row = find("batteryStatus")
            verify(row.width + 2 * 8 * u <= pill.width, what + ": the chips sit inside the pill")
            // The name is not squeezed under about six characters.
            const nameItem = find("activeProfileName")
            verify(nameItem.width >= Math.min(nameItem.implicitWidth, 3 * nameItem.font.pixelSize), what + ": the name keeps a minimum: " + nameItem.width)
            // Every device is still named: by a chip, or by the "+N".
            let names = ""
            for (const child of row.children) {
                if (child.objectName.startsWith("batteryChip_"))
                    names += child.Accessible.name + "; "
            }
            names += find("batteryMore").Accessible.name
            for (const device of expectedDevices)
                verify(names.indexOf(device) >= 0, what + ": " + device + " is named in " + names)
        }

        function test_the_cluster_clears_the_nav_with_five_devices_at_three_sizes() {
            Batteries.mockPopulate()
            for (const size of [[1280, 720], [1920, 1080], [3840, 2160]]) {
                openShell(size[0], size[1])
                tryVerify(() => find("batteryMore").visible, 2000, "three chips and a +N")
                checkCluster(size, "five devices", ["WH-1000XM4", "Ruya Keyboard"])
                compare(chipIds().length, 3, "three chips and a +N for 'Ada' at " + size[1] + "p")
                tc.shell.destroy()
                wait(50)
            }
        }

        // The review's case: ordinary and 32-character profile names with three full batteries and
        // a fourth: fewer than three chips may show, the name elides, nothing reaches the nav.
        function test_long_profile_names_and_many_devices_never_reach_the_nav() {
            Batteries.mockClear()
            const devices = ["Pad One", "Pad Two", "Pad Three", "Pad Four"]
            for (let i = 0; i < devices.length; ++i)
                Batteries.mockSet("d" + i, 100, "discharging", "controller", devices[i])
            const names = ["Ada", "Player One", "Grandma Fatma", "Mehmet Ali Yilmaz",
                           "Mehmet Ali Yilmaz-Kucukoglu Doga"]
            compare(names[4].length, 32, "the long name has 32 characters")
            for (const name of names) {
                Profiles.renameProfile("p1", "1234", "p2", name)
                tryVerify(() => Profiles.active.name === name)
                for (const size of [[1280, 720], [1920, 1080], [3840, 2160]]) {
                    openShell(size[0], size[1])
                    tryVerify(() => find("batteryMore").visible || find("batteryStatus").children.length > 0, 2000)
                    tryCompare(find("activeProfileName"), "text", name)
                    checkCluster(size, "'" + name + "'", devices)
                    const chipsShown = chipIds().length
                    if (name === "Ada")
                        verify(chipsShown >= 2, "a short name leaves room for chips at " + size[1] + "p: " + chipsShown)
                    if (name === names[4] && size[1] === 720) {
                        verify(find("activeProfileName").truncated, "the 32-character name elides at 720p")
                        verify(chipsShown < 3 || find("batteryMore").visible, "fewer chips or a +N: " + chipsShown)
                        compare(chipsShown + parseInt(find("batteryMore").text.substring(1)), 4, "every device is a chip or in the +N")
                    }
                    tc.shell.destroy()
                    wait(50)
                }
            }
            Profiles.renameProfile("p1", "1234", "p2", "Ada")
            tryVerify(() => Profiles.active.name === "Ada")
        }

        // T-300: a pad whose battery UPower listed before it bonded is announced again with its family
        // (the service sends BatteriesChanged when the Bluetooth side changes); the chip follows at once.
        function chipGlyph(id) {
            const chip = find("batteryChip_" + id)
            return chip ? findChild(chip, "batteryKindIcon").name : ""
        }

        function test_family_after_late_bond() {
            openShell(1920, 1080)
            Batteries.mockClear()
            Batteries.mockSet("pad-late", 62, "discharging", "controller", "Wireless Controller")
            tryVerify(() => chipGlyph("pad-late") === "sports_esports", 2000, "no family yet: the generic pad: " + chipGlyph("pad-late"))
            Batteries.mockSet("pad-late", 62, "discharging", "controller", "Wireless Controller", "playstation")
            tryVerify(() => chipGlyph("pad-late") === "pad_playstation", 2000, "the chip got the PlayStation pad after the late bond: " + chipGlyph("pad-late"))
            compare(DeviceIcons.iconFor("controller", "playstation"), "pad_playstation")
            tc.shell.destroy()
            wait(50)
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
            // The review's worst case: a 32-character name and four full batteries.
            Profiles.renameProfile("p1", "1234", "p2", "Mehmet Ali Yilmaz-Kucukoglu Doga")
            tryVerify(() => Profiles.active.name === "Mehmet Ali Yilmaz-Kucukoglu Doga")
            Batteries.mockClear()
            for (let i = 0; i < 4; ++i)
                Batteries.mockSet("d" + i, 100, "discharging", "controller", "Pad " + i)
            for (const size of [[1280, 720, "720"], [1920, 1080, "1080"]]) {
                openShell(size[0], size[1])
                wait(500)
                grabImage(tc.shell).save(shotsDir + "/battery-" + size[2] + "-longname.png")
                grabImage(find("statusGlass")).save(shotsDir + "/battery-" + size[2] + "-longname-crop.png")
                tc.shell.destroy()
                wait(50)
            }
            Profiles.renameProfile("p1", "1234", "p2", "Ada")
            tryVerify(() => Profiles.active.name === "Ada")
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
