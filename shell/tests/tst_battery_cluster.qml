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

        // The pill is laid out when it is as wide as the row inside it plus the bell's slot on the left
        // (RUY-413) and its padding on the right. The budget
        // that picks the chips is computed at once from the fonts, but the Row (and so the pill) follows
        // one frame later, and the clock text changes width (HH:mm in a proportional font) every
        // minute: right after either, the pill's edge is still the old one (the gap read 23 or 25 px
        // against 24 under load). Measured widths only: nothing here depends on a font's metrics.
        function pillIsLaidOut() {
            const pill = find("statusGlass")
            const inner = find("batteryStatus").parent
            return Math.abs(pill.width - (inner.width + pill.bellSlot + Theme.spaceL * tc.shell.u)) < 0.5
        }
        // "" when the cluster clears the nav and sits in the safe area, else what is wrong.
        function clusterProblem(size, what) {
            const nav = find("sectionNav")
            const pill = find("statusGlass")
            const u = tc.shell.u
            const navRight = nav.mapToItem(tc.shell, nav.width, 0).x
            if (navRight + 24 * u > pill.x + 0.5)
                return what + " at " + size[1] + "p: the cluster starts at " + pill.x + ", the nav ends at " + navRight
            if (pill.x + pill.width > tc.shell.width - tc.shell.marginX + 1)
                return what + " at " + size[1] + "p: inside the safe area, right edge " + (pill.x + pill.width)
            if (find("batteryStatus").width + 2 * 8 * u > pill.width)
                return what + ": the chips sit inside the pill"
            return ""
        }

        function checkCluster(size, what, expectedDevices) {
            waitForRendering(tc.shell)       // the Row lays out on the next frame
            tryVerify(() => settled() && pillIsLaidOut(), 2000, what + ": the chips and the pill are laid out")
            // Re-read for up to 2 s: a change of the clock text re-budgets the chips at once and the pill
            // follows a frame later; an overlap that stays is still reported, with its numbers.
            // RUY-582: waits on the condition itself (a fixed count of 50 ms waits ran short under load at 4K).
            let problem = clusterProblem(size, what)
            tryVerify(() => { problem = clusterProblem(size, what); return problem === "" }, 2000, what)
            compare(problem, "")
            const row = find("batteryStatus")
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
                tryVerify(() => find("batteryMore").visible, 2000, "chips and an \"N more\" chip")
                checkCluster(size, "five devices", ["WH-1000XM4", "Ruya Keyboard"])
                // The "N more" chip carries words since T-301, so it is wider than the old "+N" and two chips
                // (not three) fit beside it for a short name at every size.
                compare(chipIds().length, 2, "two chips and an \"N more\" chip for 'Ada' at " + size[1] + "p")
                compare(find("batteryMore").count, 3)
                compare(findChild(find("batteryMore"), "batteryMoreLabel").text, "3 more", "with its words")
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
                    // The bell (RUY-413) takes 64 u of the room: four full pads ("100%", three digits) now leave Ada
                    // one or two chips and the rest in "N more", by a few pixels of the clock's width (two chips need
                    // 11 px more at 720p with "07:59"); before the bell two always fitted.
                    if (name === "Ada")
                        verify(chipsShown >= 1, "a short name leaves room for a chip at " + size[1] + "p: " + chipsShown)
                    if (name === names[4] && size[1] === 720) {
                        verify(find("activeProfileName").truncated, "the 32-character name elides at 720p")
                        verify(chipsShown < 3 || find("batteryMore").visible, "fewer chips or a +N: " + chipsShown)
                        compare(chipsShown + find("batteryMore").count, 4, "every device is a chip or in the +N")
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
            tryVerify(() => chipGlyph("pad-late") === "pad_dualsense", 2000, "the chip got the PlayStation pad after the late bond: " + chipGlyph("pad-late"))
            compare(DeviceIcons.iconFor("controller", "playstation"), "pad_dualsense", "the family's silhouette")
            // The model the service named, once the pad's maker has told it, replaces the family's silhouette.
            Batteries.mockSet("pad-late", 62, "discharging", "controller", "Wireless Controller", "playstation", "", "dualshock4")
            tryVerify(() => chipGlyph("pad-late") === "pad_dualshock4", 2000, "the chip got the model: " + chipGlyph("pad-late"))
            tc.shell.destroy()
            wait(50)
        }

        function cleanup() {
            Display.setUiScale(0)               // a test that enlarged the UI puts it back
            DeviceSettings.language = "en"
            tryCompare(Theme, "uiScale", 1)
            Bluetooth.mockReset()               // the two pads a test added are listed, connected and have batteries of their own
        }

        // T-301: the three slots go to pads and headsets before mice and keyboards, each group lowest first;
        // the ones left out are named by the "N more" chip.
        function test_pads_rank_above_mice() {
            Batteries.mockClear()
            Batteries.mockSet("mouse", 5, "discharging", "mouse", "Travel Mouse")
            Batteries.mockSet("kb", 9, "discharging", "keyboard", "Ruya Keyboard")
            Batteries.mockSet("padA", 90, "discharging", "controller", "Pad A")
            Batteries.mockSet("padB", 80, "discharging", "controller", "Pad B")
            Batteries.mockSet("hs", 70, "discharging", "headset", "WH-1000XM4")
            openShell(1920, 1080)
            tryVerify(() => find("batteryMore").visible, 2000, "two devices do not fit the three slots")
            // As many as fit (two beside the "N more" chip for 'Ada'), the lowest pad or headset first,
            // although the mouse and the keyboard are lower still.
            compare(chipIds(), ["batteryChip_hs", "batteryChip_padB"],
                    "pads and headsets, lowest first, although the mouse and the keyboard are lower")
            compare(find("batteryMore").count, 3)
            const name = find("batteryMore").Accessible.name
            verify(name.indexOf("Travel Mouse") >= 0 && name.indexOf("Ruya Keyboard") >= 0, "the chip names them: " + name)
            // With only mice and keyboards the lowest still come first.
            Batteries.mockClear()
            Batteries.mockSet("m1", 40, "discharging", "mouse", "Mouse One")
            Batteries.mockSet("k1", 20, "discharging", "keyboard", "Keyboard One")
            tryVerify(() => chipIds().join() === "batteryChip_k1,batteryChip_m1", 2000, "no pad or headset: lowest first: " + chipIds())
            tc.shell.destroy()
            wait(50)
        }

        // T-334: two pads of one model, one chip each: the chips are two (told apart by their
        // own ids and levels), both inside the cluster, none squeezed into the "+N".
        function test_battery_chips_for_two_pads() {
            Batteries.mockClear()
            Batteries.mockSet("padA", 80, "discharging", "controller", "Wireless Controller", "playstation")
            Batteries.mockSet("padB", 55, "discharging", "controller", "Wireless Controller", "playstation")
            openShell(1920, 1080)
            tryVerify(() => chipIds().length === 2, 2000, "a chip for each pad: " + chipIds())
            compare(chipIds(), ["batteryChip_padB", "batteryChip_padA"], "the lower one first")
            verify(!find("batteryMore").visible, "both fit: nothing is hidden")
            compare(find("batteryChip_padA").percent, 80)
            compare(find("batteryChip_padB").percent, 55)
            compare(find("batteryChip_padA").Accessible.name, "Wireless Controller battery 80 percent")
            compare(find("batteryChip_padB").Accessible.name, "Wireless Controller battery 55 percent")
            checkCluster([1920, 1080], "two like pads", ["Wireless Controller battery 80 percent", "Wireless Controller battery 55 percent"])
            // One goes away: its chip goes and the other stays.
            Batteries.mockRemove("padB")
            tryVerify(() => chipIds().join() === "batteryChip_padA", 2000, "only the first pad's chip is left: " + chipIds())
            tc.shell.destroy()
            wait(50)
        }

        // T-359: the service tells a battery's Bluetooth address. Two like pads are named after their paired
        // devices (the end of the address added, as in Settings) in the chip's accessible name, in the
        // "N more" chip's and in the "More devices" list; a pad with a name of its own, and a battery that
        // has no address (a wired pad), keep their plain names.
        readonly property string padA: "AA:00:00:00:00:04"
        readonly property string padB: "AA:00:00:00:00:05"

        function twoLikePads() {
            Bluetooth.mockReset()
            Bluetooth.mockTwoPads()
            tryVerify(() => Bluetooth.devices.find(d => d.id === tc.padA) !== undefined
                      && Bluetooth.devices.find(d => d.id === tc.padB) !== undefined, 2000, "both pads are listed")
        }

        function test_like_pads_are_told_apart_in_the_chips() {
            twoLikePads()
            Batteries.mockClear()
            Batteries.mockSet("padA", 80, "discharging", "controller", "Wireless Controller", "playstation", tc.padA)
            Batteries.mockSet("padB", 55, "discharging", "controller", "Wireless Controller", "playstation", tc.padB)
            openShell(1920, 1080)
            tryVerify(() => chipIds().length === 2, 2000, "a chip for each pad: " + chipIds())
            compare(find("batteryChip_padA").Accessible.name, "Wireless Controller (00:04) battery 80 percent")
            compare(find("batteryChip_padB").Accessible.name, "Wireless Controller (00:05) battery 55 percent")
            // One pad gets a name of its own: the other has no twin any more.
            Bluetooth.mockSetName(tc.padB, "Ada's pad")
            tryCompare(find("batteryChip_padB").Accessible, "name", "Ada's pad battery 55 percent")
            compare(find("batteryChip_padA").Accessible.name, "Wireless Controller battery 80 percent")
            // A battery UPower knows by address but Bluetooth does not list (the radio is off): two like
            // names still get their tails, a wired pad without an address keeps its name.
            Bluetooth.mockReset()
            tryVerify(() => Bluetooth.devices.find(d => d.id === tc.padA) === undefined, 2000)
            tryCompare(find("batteryChip_padA").Accessible, "name", "Wireless Controller (00:04) battery 80 percent")
            Batteries.mockSet("wired", 90, "discharging", "controller", "Wireless Controller", "playstation")
            tryVerify(() => find("batteryChip_wired") !== null, 2000)
            compare(find("batteryChip_wired").Accessible.name, "Wireless Controller battery 90 percent")
            tc.shell.destroy()
            wait(50)
        }

        function test_like_pads_are_told_apart_in_more_devices() {
            twoLikePads()
            Batteries.mockClear()
            // Three controllers with a lower level take the chips; the two pads are the "N more".
            Batteries.mockSet("c1", 10, "discharging", "controller", "Xbox Wireless Controller", "xbox")
            Batteries.mockSet("c2", 20, "discharging", "controller", "Pro Controller", "nintendo")
            Batteries.mockSet("c3", 30, "discharging", "controller", "8BitDo Pro 2", "8bitdo")
            Batteries.mockSet("padA", 80, "discharging", "controller", "Wireless Controller", "playstation", tc.padA)
            Batteries.mockSet("padB", 55, "discharging", "controller", "Wireless Controller", "playstation", tc.padB)
            openShell(1920, 1080)
            tryVerify(() => find("batteryMore").visible, 2000)
            const more = find("batteryMore")
            verify(more.Accessible.name.indexOf("Wireless Controller (00:04) 80 percent") >= 0, more.Accessible.name)
            verify(more.Accessible.name.indexOf("Wireless Controller (00:05) 55 percent") >= 0, more.Accessible.name)
            openMore()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("batteryList").shown, 2000, "Accept opens the list")
            tryVerify(() => find("batteryListClose").activeFocus, 2000, "Close has focus")
            compare(find("batteryListName_padA").text, "Wireless Controller (00:04)")
            compare(find("batteryListName_padB").text, "Wireless Controller (00:05)")
            compare(find("batteryListChip_padA").Accessible.name, "Wireless Controller (00:04) battery 80 percent")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("batteryList").shown, 2000, "Back closes")
            tryVerify(() => more.activeFocus, 2000, "focus returns to the chip")
            tc.shell.destroy()
            wait(50)
        }

        // T-359: in "More devices" a too long name is cut before the end of the address, which stays whole.
        function test_more_devices_cuts_a_long_name_before_its_address() {
            twoLikePads()
            const wide = "W".repeat(48)
            Bluetooth.mockSetName(tc.padA, wide)
            Bluetooth.mockSetName(tc.padB, wide)
            tryVerify(() => Bluetooth.devices.find(d => d.id === tc.padB).name === wide, 2000)
            Batteries.mockClear()
            Batteries.mockSet("c1", 10, "discharging", "controller", "Xbox Wireless Controller", "xbox")
            Batteries.mockSet("c2", 20, "discharging", "controller", "Pro Controller", "nintendo")
            Batteries.mockSet("c3", 30, "discharging", "controller", "8BitDo Pro 2", "8bitdo")
            Batteries.mockSet("padA", 80, "discharging", "controller", "Wireless Controller", "playstation", tc.padA)
            Batteries.mockSet("padB", 55, "discharging", "controller", "Wireless Controller", "playstation", tc.padB)
            openShell(1920, 1080)
            tryVerify(() => find("batteryMore").visible, 2000)
            openMore()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("batteryList").shown, 2000, "Accept opens the list")
            const name = find("batteryListName_padB")
            verify(name.text.endsWith(" (00:05)"), "the tail is whole: " + name.text)
            verify(name.text.indexOf("\u2026") > 0, "the name is cut: " + name.text)
            verify(name.paintedWidth <= name.width + 0.5, "one line: " + name.paintedWidth + " > " + name.width)
            compare(name.Accessible.name, wide + " (00:05)")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("batteryList").shown, 2000, "Back closes")
            tc.shell.destroy()
            wait(50)
        }

        // T-301: with larger text the "N more" chip still fits beside the shortest profile name and the pill keeps
        // its gap to the nav. The accessibility text scale (04 section 1) is not built yet, so the nearest thing
        // is the UI size: at 125 % the words no longer fit beside a battery chip, so one chip and the "+N" show
        // (from 150 % up the nav leaves the cluster less than its parts need; no layout gives that back).
        function test_plus_n_fits_at_text_scale_2() {
            Batteries.mockPopulate()
            const seen = []
            for (const percent of [100, 125]) {
                Display.setUiScale(percent === 100 ? 0 : percent)
                tryCompare(Theme, "uiScale", percent / 100)
                for (const size of [[1280, 720], [1920, 1080], [3840, 2160]]) {
                    openShell(size[0], size[1])
                    tryVerify(() => find("batteryMore").visible, 2000, "an \"N more\" chip at " + percent + " %")
                    const what = percent + " % at " + size[1] + "p"
                    checkCluster(size, what, ["WH-1000XM4", "Ruya Keyboard"])
                    const row = find("batteryStatus")
                    const more = find("batteryMore")
                    verify(more.x + more.width <= row.width + 0.5, what + ": the chip sits inside the group: " + more.x + "+" + more.width + " in " + row.width)
                    const label = findChild(more, "batteryMoreLabel")
                    verify(label.width >= label.implicitWidth - 0.5, what + ": the label is not squeezed")
                    compare(chipIds().length + more.count, 5, what + ": every device is a chip or behind the chip")
                    compare(label.text === "+" + more.count, find("statusGlass").moreCompact, what + ": \"+N\" only when the words are dropped")
                    if (percent === 100)
                        compare(find("statusGlass").moreCompact, false, what + ": the words fit at the normal size")
                    seen.push(chipIds().length)
                    tc.shell.destroy()
                    wait(50)
                }
            }
            verify(Math.max(seen[3], seen[4], seen[5]) <= Math.min(seen[0], seen[1], seen[2]), "larger text never shows more chips: " + seen)

        }

        // A window too narrow for the words: the chip shrinks to "+N" (what the cluster showed before the words), keeps its
        // meaning in the accessible name, and the pill still clears the nav; wide enough, the words come back.
        function test_the_chip_shrinks_to_plus_n_in_a_narrow_room() {
            Batteries.mockPopulate()
            const compact = []
            for (const width of [narrowestRoom(), 1384, 1464, 1920]) {
                openShell(width, 1080)
                tryVerify(() => find("batteryMore").visible, 2000, "the chip at " + width)
                find("statusClock").text = "88:88"   // the widest time of day, not the minute the test runs in
                checkCluster([width, 1080], "a " + width + " px wide window", ["WH-1000XM4", "Ruya Keyboard"])
                const more = find("batteryMore")
                const label = findChild(more, "batteryMoreLabel")
                compact.push(find("statusGlass").moreCompact)
                compare(label.text, find("statusGlass").moreCompact ? "+" + more.count : more.count + " more")
                compare(findChild(more, "batteryMoreFront").visible, !find("statusGlass").moreCompact, "the glyph goes with the words")
                tc.shell.destroy()
                wait(50)
            }
            compare(compact[0], true, "narrow: +N")
            compare(compact[compact.length - 1], false, "wide: the words")
        }

        // The narrowest 1080p window (from 1354 px, in 2 px steps) where the "+N" chip alone fits beside the
        // shortest name with the widest clock (the range moved by the bell's 64 px at 1080p, RUY-413: the
        // bell's slot, 8 + 76 + 16 u, less the 36 u of padding it replaces). Below it the pill may reach into the nav's gap by design
        // (Shell.qml, fitChips' last case), and where that starts depends on the host's font rendering: a
        // fixed 1290 fitted on Windows but not on Fedora (CI red whenever the clock read wide, lead-9).
        function narrowestRoom() {
            for (let width = 1354; width <= 1384; width += 2) {
                openShell(width, 1080)
                tryVerify(() => find("batteryMore").visible, 2000, "the chip at " + width)
                find("statusClock").text = "88:88"
                waitForRendering(tc.shell)
                const fits = find("statusGlass").fitsRoom
                tc.shell.destroy()
                wait(50)
                if (fits)
                    return width
            }
            fail("the cluster fits in no 1080p window up to 1384 px")
            return 0
        }

        function openMore() {
            keyClick(Qt.Key_Up)                                    // the nav, on Home
            tryVerify(() => find("sectionNav").activeFocus, 2000, "the nav has focus")
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)                             // ... to the last pill
            tryCompare(find("sectionNav"), "currentIndex", 4)
            keyClick(Qt.Key_Right)                                 // ... on to the cluster's bell (RUY-413)
            tryVerify(() => find("notificationBell").activeFocus, 2000, "Right from the last pill reaches the bell")
            keyClick(Qt.Key_Right)                                 // ... and on to the chip
            tryVerify(() => find("batteryMore").activeFocus, 2000, "Right from the bell reaches the +N chip")
        }

        function test_plus_n_opens_the_hidden_list() {
            Batteries.mockPopulate()
            openShell(1920, 1080)
            tryVerify(() => find("batteryMore").visible, 2000)
            const more = find("batteryMore")
            const list = find("batteryList")
            compare(list.shown, false)
            openMore()
            keyClick(Qt.Key_Return)
            tryVerify(() => list.shown, 2000, "Accept opens the list")
            tryVerify(() => find("batteryListClose").activeFocus, 2000, "Close has focus")
            const hidden = Batteries.chips.concat(Batteries.more).filter(d => chipIds().indexOf("batteryChip_" + d.id) < 0)
            compare(hidden.length, more.count, "the list is the hidden devices")
            for (const d of hidden) {
                const row = find("batteryListRow_" + d.id)
                verify(row !== null, d.name + " is listed")
                const chip = find("batteryListChip_" + d.id)
                verify(chip.Accessible.name.indexOf(d.percent + " percent") >= 0, d.name + " shows " + d.percent + ": " + chip.Accessible.name)
                verify(chip.Accessible.name.indexOf(d.name) >= 0)
            }
            compare(find("hintBar").hints[0].button + " " + find("hintBar").hints[0].text, "A Close", "the hint bar says what A does")
            compare(find("hintBar").hints[1].button + " " + find("hintBar").hints[1].text, "B Back")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !list.shown, 2000, "Back closes")
            tryVerify(() => more.activeFocus, 2000, "focus returns to the chip")
            keyClick(Qt.Key_Return)                                // Accept opens, Accept on Close closes
            tryVerify(() => list.shown)
            keyClick(Qt.Key_Return)
            tryVerify(() => !list.shown && more.activeFocus, 2000, "Accept on Close closes too, focus on the chip")
            // The chip leads back: Left to the bell, Left to the last pill, and Right twice again; Down into the
            // page; Back leaves Home alone.
            keyClick(Qt.Key_Left)
            tryVerify(() => find("notificationBell").activeFocus, 2000, "Left: the bell")
            keyClick(Qt.Key_Left)
            tryVerify(() => find("sectionNav").activeFocus && find("sectionNav").currentIndex === 4, 2000, "Left: the last pill")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("notificationBell").activeFocus)
            keyClick(Qt.Key_Right)
            tryVerify(() => more.activeFocus)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Down: the page")
            tc.shell.destroy()
            wait(50)
        }

        // The chip does not swallow keys it does not handle: Guide opens the system panel from it as from the nav.
        function test_guide_opens_the_panel_from_the_chip() {
            Batteries.mockPopulate()
            openShell(1920, 1080)
            tryVerify(() => find("batteryMore").visible, 2000)
            openMore()
            compare(find("systemPanel").open, false)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemPanel").open, 2000, "Guide opens the system panel with the chip focused")
            keyClick(Qt.Key_HomePage)
            tryCompare(find("systemPanel"), "open", false)
            tc.shell.destroy()
            wait(50)
        }

        // The chip goes away under the focus with no list open: the focus goes to the nav, not nowhere.
        function test_the_focused_chip_going_away_hands_the_focus_to_the_nav() {
            Batteries.mockPopulate()
            openShell(1920, 1080)
            tryVerify(() => find("batteryMore").visible, 2000)
            openMore()
            Batteries.mockClear()
            Batteries.mockSet("pad-1", 62, "discharging", "controller", "Pad One")
            tryVerify(() => !find("batteryMore").visible, 2000)
            tryVerify(() => find("sectionNav").activeFocus, 2000, "focus moved to the nav, not nowhere")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("homePlay").activeFocus, 2000, "and the keys still work from there")
            tc.shell.destroy()
            wait(50)
        }

        // The list is a picture of the live batteries: a hidden device that drops out closes it, and
        // focus does not end up nowhere when the chip itself goes away.
        function test_the_list_and_the_chip_follow_the_batteries() {
            Batteries.mockPopulate()
            openShell(1920, 1080)
            tryVerify(() => find("batteryMore").visible, 2000)
            openMore()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("batteryList").shown)
            Batteries.mockClear()
            Batteries.mockSet("pad-1", 62, "discharging", "controller", "Pad One")
            tryVerify(() => !find("batteryList").shown, 2000, "nothing is hidden any more: the list closed")
            tryVerify(() => !find("batteryMore").visible, 2000)
            tryVerify(() => find("sectionNav").activeFocus, 2000, "focus moved to the nav, not nowhere")
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

        // T-359: the cluster with two like pads and "More devices" naming them apart.
        function test_zz_like_pads_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            twoLikePads()
            Batteries.mockClear()
            Batteries.mockSet("c1", 10, "discharging", "controller", "Xbox Wireless Controller", "xbox")
            Batteries.mockSet("c2", 20, "discharging", "controller", "Pro Controller", "nintendo")
            Batteries.mockSet("c3", 30, "discharging", "controller", "8BitDo Pro 2", "8bitdo")
            Batteries.mockSet("padA", 80, "discharging", "controller", "Wireless Controller", "playstation", tc.padA)
            Batteries.mockSet("padB", 55, "discharging", "controller", "Wireless Controller", "playstation", tc.padB)
            openShell(1920, 1080)
            tryVerify(() => find("batteryMore").visible, 2000)
            openMore()
            wait(500)
            grabImage(find("statusGlass")).save(shotsDir + "/T359-battery-like-pads-crop.png")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("batteryList").shown, 2000)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/T359-battery-list-like-pads.png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("batteryList").shown, 2000)
            tc.shell.destroy()
            wait(50)
        }

        // T-301: the "N more" chip with its focus ring and the list it opens, in English and Turkish, and
        // the cluster at larger UI sizes.
        function test_zz_more_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Batteries.mockPopulate()
            for (const lang of ["en", "tr"]) {
                DeviceSettings.language = lang
                openShell(1920, 1080)
                tryVerify(() => find("batteryMore").visible, 2000)
                openMore()
                wait(500)
                grabImage(tc.shell).save(shotsDir + "/battery-more-" + lang + ".png")
                grabImage(find("statusGlass")).save(shotsDir + "/battery-more-" + lang + "-crop.png")
                keyClick(Qt.Key_Return)
                tryVerify(() => find("batteryList").shown, 2000)
                wait(600)
                grabImage(tc.shell).save(shotsDir + "/battery-list-" + lang + ".png")
                keyClick(Qt.Key_Escape)
                tryVerify(() => !find("batteryList").shown, 2000)
                tc.shell.destroy()
                wait(50)
            }
            DeviceSettings.language = "en"
            // The chip and its list on the light theme (the stack glyph must still read).
            const before = DeviceSettings.theme
            DeviceSettings.theme = "daylight"
            openShell(1920, 1080)
            tryCompare(Theme, "mix", 1, 5000, "the theme has finished fading")
            tryVerify(() => !Theme.fade.running)
            tryVerify(() => find("batteryMore").visible, 2000)
            openMore()
            wait(500)
            grabImage(find("statusGlass")).save(shotsDir + "/battery-more-daylight-crop.png")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("batteryList").shown, 2000)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/battery-list-daylight.png")
            keyClick(Qt.Key_Escape)
            tc.shell.destroy()
            DeviceSettings.theme = before
            wait(50)
            for (const percent of [150, 200]) {
                Display.setUiScale(percent)
                tryCompare(Theme, "uiScale", percent / 100)
                openShell(1920, 1080)
                wait(500)
                grabImage(tc.shell).save(shotsDir + "/battery-scale-" + percent + ".png")
                grabImage(find("statusGlass")).save(shotsDir + "/battery-scale-" + percent + "-crop.png")
                tc.shell.destroy()
                wait(50)
            }
        }
    }
}
