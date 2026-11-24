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

    Component {
        id: chipComponent
        BatteryChip { u: 1 }
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

        // The tray is laid out when it is as wide as the row inside it (the bell is the nav's last pill since
        // RUY-1136); the clock's right edge is the tray's (no padding, RUY-1109). The budget
        // that picks the chips is computed at once from the fonts, but the Row (and so the pill) follows
        // one frame later, and the clock text changes width (HH:mm in a proportional font) every
        // minute: right after either, the pill's edge is still the old one (the gap read 23 or 25 px
        // against 24 under load). Measured widths only: nothing here depends on a font's metrics.
        function pillIsLaidOut() {
            const pill = find("statusTray")
            const inner = find("batteryStatus").parent
            return Math.abs(pill.width - inner.width) < 0.5
        }
        // "" when the cluster clears the nav and sits in the safe area, else what is wrong.
        function clusterProblem(size, what) {
            const nav = find("sectionNav")
            const pill = find("statusTray")
            const u = tc.shell.u
            const navRight = nav.mapToItem(tc.shell, nav.width, 0).x
            // The bell's glass pill sits between them (RUY-1170): the nav, a gap, the bell, a gap, the tray.
            const bell = find("bellGlass")
            const bellLeft = bell.mapToItem(tc.shell, 0, 0).x
            const bellRight = bellLeft + bell.width
            if (navRight + Theme.spaceM * u > bellLeft + 0.5)
                return what + " at " + size[1] + "p: the bell starts at " + bellLeft + ", the nav ends at " + navRight + " (a gap of spaceM at least)"
            if (Math.abs(bellRight + Theme.spaceM * u - pill.x) > 0.5)
                return what + " at " + size[1] + "p: the bell ends at " + bellRight + ", the cluster starts at " + pill.x
            if (pill.x + pill.width > tc.shell.width - tc.shell.marginX + 1)
                return what + " at " + size[1] + "p: inside the safe area, right edge " + (pill.x + pill.width)
            if (find("batteryStatus").width > pill.width)
                return what + ": the chips sit inside the tray"
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
                // RUY-658: the budget re-picks the chips when the clock text or the layout changes; wait on the
                // settled chip count and "N more" instead of reading them once (the count flaked under load at 4K).
                tryVerify(() => chipIds().length === 2 && find("batteryMore").count === 3, 5000,
                          "two chips and an \"N more\" chip for 'Ada' at " + size[1] + "p")
                compare(chipIds().length, 2, "two chips and an \"N more\" chip for 'Ada' at " + size[1] + "p")
                compare(find("batteryMore").count, 3)
                tryCompare(findChild(find("batteryMore"), "batteryMoreLabel"), "text", "3 more", 2000, "with its words")
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
                    // The bell (RUY-413, the nav's last pill since RUY-1136) takes room: four full pads ("100%", three
                    // digits) leave Ada one or two chips and the rest in "N more", by a few pixels of the clock's width.
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
            NotificationCentre.mockReset()      // a bell shot's posted row must not reach the next function (RUY-1175)
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
            compare(find("batteryChip_padB").Accessible.name, "Wireless Controller 2 battery 55 percent")
            checkCluster([1920, 1080], "two like pads", ["Wireless Controller battery 80 percent", "Wireless Controller 2 battery 55 percent"])
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
            compare(find("batteryChip_padA").Accessible.name, "Wireless Controller battery 80 percent")
            compare(find("batteryChip_padB").Accessible.name, "Wireless Controller 2 battery 55 percent")
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
            Batteries.mockSet("c3", 30, "discharging", "controller", "8BitDo Pro 2", "generic")
            Batteries.mockSet("padA", 80, "discharging", "controller", "Wireless Controller", "playstation", tc.padA)
            Batteries.mockSet("padB", 55, "discharging", "controller", "Wireless Controller", "playstation", tc.padB)
            openShell(1920, 1080)
            tryVerify(() => find("batteryMore").visible, 2000)
            const more = find("batteryMore")
            verify(more.Accessible.name.indexOf("Wireless Controller 80 percent") >= 0, more.Accessible.name)
            verify(more.Accessible.name.indexOf("Wireless Controller 2 55 percent") >= 0, more.Accessible.name)
            openMore()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("batteryList").shown, 2000, "Accept opens the list")
            tryVerify(() => find("batteryListClose").activeFocus, 2000, "Close has focus")
            compare(find("batteryListName_padA").text, "Wireless Controller")
            compare(find("batteryListName_padB").text, "Wireless Controller 2")
            compare(find("batteryListChip_padA").Accessible.name, "Wireless Controller battery 80 percent")
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
            Batteries.mockSet("c3", 30, "discharging", "controller", "8BitDo Pro 2", "generic")
            Batteries.mockSet("padA", 80, "discharging", "controller", "Wireless Controller", "playstation", tc.padA)
            Batteries.mockSet("padB", 55, "discharging", "controller", "Wireless Controller", "playstation", tc.padB)
            openShell(1920, 1080)
            tryVerify(() => find("batteryMore").visible, 2000)
            openMore()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("batteryList").shown, 2000, "Accept opens the list")
            const name = find("batteryListName_padB")
            verify(name.text.endsWith(" 2"), "the tail is whole: " + name.text)
            verify(name.text.indexOf("\u2026") > 0, "the name is cut: " + name.text)
            verify(name.paintedWidth <= name.width + 0.5, "one line: " + name.paintedWidth + " > " + name.width)
            compare(name.Accessible.name, wide + " 2")
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
                    compare(label.text === "+" + more.count, find("statusTray").moreCompact, what + ": \"+N\" only when the words are dropped")
                    if (percent === 100)
                        compare(find("statusTray").moreCompact, false, what + ": the words fit at the normal size")
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
                compact.push(find("statusTray").moreCompact)
                compare(label.text, find("statusTray").moreCompact ? "+" + more.count : more.count + " more")
                compare(findChild(more, "batteryMoreFront").visible, !find("statusTray").moreCompact, "the glyph goes with the words")
                // Its focus pill keeps the 76 u height and is never narrower than that: compact, a round pill (04 §5.5).
                const pill = findChild(more, "batteryMoreFocus")
                const u = tc.shell.u
                compare(pill.height, Theme.buttonHeight * u)
                compare(pill.width, Math.max(Theme.buttonHeight * u, more.width + 2 * Theme.spaceS * u))
                if (find("statusTray").moreCompact)
                    compare(pill.width, Theme.buttonHeight * u, "\"+N\" is narrower than the pill: the pill is round")
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
                const fits = find("statusTray").fitsRoom
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
            for (let i = 0; i < 5; ++i)
                keyClick(Qt.Key_Right)                             // ... to the last pill, the bell (RUY-1136)
            tryCompare(find("sectionNav"), "currentKey", "notifications")
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
            compare(find("hintBar").hints[0].action + " " + find("hintBar").hints[0].text, "accept Close", "the hint bar says what A does")
            compare(find("hintBar").hints[1].action + " " + find("hintBar").hints[1].text, "back Back")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !list.shown, 2000, "Back closes")
            tryVerify(() => more.activeFocus, 2000, "focus returns to the chip")
            keyClick(Qt.Key_Return)                                // Accept opens, Accept on Close closes
            tryVerify(() => list.shown)
            keyClick(Qt.Key_Return)
            tryVerify(() => !list.shown && more.activeFocus, 2000, "Accept on Close closes too, focus on the chip")
            // The chip leads back: Left to the nav's last pill (the bell), Left to the gear, and Right twice again;
            // Down into the page; Back leaves Home alone.
            keyClick(Qt.Key_Left)
            tryVerify(() => find("sectionNav").activeFocus && find("sectionNav").currentKey === "notifications", 2000, "Left: the bell")
            keyClick(Qt.Key_Left)
            tryVerify(() => find("sectionNav").activeFocus && find("sectionNav").currentKey === "settings", 2000, "Left: the gear")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("sectionNav").currentKey === "notifications")
            keyClick(Qt.Key_Right)
            tryVerify(() => more.activeFocus)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Down: the page")
            tc.shell.destroy()
            wait(50)
        }

        // Every item below `item` with this object name.
        function descendants(item, name) {
            let out = []
            for (const child of item.children) {
                if (child.objectName === name)
                    out.push(child)
                out = out.concat(descendants(child, name))
            }
            return out
        }

        // The flat tray (RUY-1109, RUY-1136, 04 §5.5): no glass and no shade; the bell is the nav's last pill; the clock's
        // right edge is the safe area; the line is centred on the nav (its ink: tst_tray_ink).
        function test_the_tray_is_flat_without_a_shade() {
            Batteries.mockPopulate()
            openShell(1920, 1080)
            const tray = find("statusTray")
            compare(descendants(tray, "glassBlur").length + descendants(tray, "glassFill").length, 0, "no glass in the tray")
            verify(find("statusGlass") === null, "no glass container")
            verify(find("trayShade") === null, "no shade")
            const clock = find("statusClock")
            const right = clock.mapToItem(tc.shell, clock.width, 0).x
            verify(Math.abs(right - (tc.shell.width - tc.shell.marginX)) < 1, "the clock's right edge is the safe area: " + right)
            const nav = find("sectionNav")
            const navMid = nav.mapToItem(tc.shell, 0, nav.height / 2).y
            const bell = find("navPill_notifications")
            compare(bell.width, Theme.buttonHeight * tc.shell.u, "the bell is an icon pill, round like the gear")
            compare(bell.width, find("navPill_settings").width)
            verify(Math.abs(bell.mapToItem(tc.shell, 0, bell.height / 2).y - navMid) < 1, "the bell is centred on the nav")
            verify(Math.abs(clock.mapToItem(tc.shell, 0, clock.height / 2).y - navMid) < 2, "the clock is on the line")
            tc.shell.destroy()
            wait(50)
        }

        // The bell's own glass pill (RUY-1170, 04 §5.5): right of the nav's pill, at the tray's left edge a gap (spaceM)
        // before its first item, the nav pill's height and line, the bell inside it; it follows the tray as it grows.
        function test_the_bell_has_its_own_pill_at_the_trays_left() {
            openShell(1920, 1080)
            const u = tc.shell.u
            const nav = find("sectionNav")
            const glass = find("sectionNavGlass")
            const bell = find("bellGlass")
            const tray = find("statusTray")
            const pos = item => item.mapToItem(tc.shell, 0, 0)
            compare(bell.height, glass.height, "the nav pill's height")
            compare(bell.width, bell.height, "icon-only: round")
            compare(pos(bell).y, pos(glass).y, "on the nav's line")
            verify(pos(bell).x >= pos(glass).x + glass.width + Theme.spaceM * u, "right of the nav's pill, spaceM at least")
            verify(pos(bell).x + bell.width < pos(tray).x, "left of the tray")
            compare(pos(bell).x + bell.width + Theme.spaceM * u, pos(tray).x, "a gap before the tray's first item")
            const pill = find("navPill_notifications")
            verify(pos(pill).x > pos(bell).x && pos(pill).x + pill.width < pos(bell).x + bell.width, "the bell sits inside its glass")
            verify(nav.width < pos(bell).x - pos(nav).x, "the nav's own pill does not hold the bell")
            const before = pos(bell).x
            const trayBefore = pos(tray).x
            Batteries.mockPopulate()
            tryVerify(() => find("batteryStatus").visible, 2000, "the batteries show")
            tryVerify(() => pos(tray).x < trayBefore, 2000, "the tray grows to the left")
            tryVerify(() => Math.abs(pos(bell).x + bell.width + Theme.spaceM * u - pos(tray).x) < 0.5, 2000, "the bell follows")
            verify(pos(bell).x < before)
            tc.shell.destroy()
            wait(50)
        }

        // `item` lies inside the bell's glass (both in the shell's coordinates).
        function inBellGlass(item, size, what) {
            const glass = find("bellGlass")
            const a = item.mapToItem(tc.shell, 0, 0)
            const g = glass.mapToItem(tc.shell, 0, 0)
            verify(a.x >= g.x - 0.5 && a.x + item.width <= g.x + glass.width + 0.5 && a.y >= g.y - 0.5 && a.y + item.height <= g.y + glass.height + 0.5,
                   size + "p: " + what + " lies in the bell's glass: " + a.x + "," + a.y + " " + item.width + "x" + item.height)
        }
        // The names of the items of the nav that belong to the bell (and each one's check that it is inside the glass).
        function bellItems(item, size, names) {
            for (const child of item.children) {
                if (child.objectName.indexOf("bell") === 0 || child.objectName.indexOf("_notifications") > 0) {
                    names.push(child.objectName)
                    if (child.visible && child.width > 0 && child.objectName !== "bellBadge" && child.objectName !== "bellBadgeText")
                        inBellGlass(child, size, child.objectName)
                }
                bellItems(child, size, names)
            }
        }

        // One bell pill only (RUY-1170 round 2): after focus goes Home, Settings, bell, nothing bell-shaped lies outside the
        // bell's own glass: its fill and ring, its pill, its glyph; the nav's pill has no ghost of the highlight at the bell
        // (a glide left at an old x showed as a stray disc beside the gear). At 1080p and 720p.
        function test_only_one_bell_pill_after_the_focus_travels() {
            Batteries.mockPopulate()
            for (const size of [[1920, 1080], [1280, 720]]) {
                openShell(size[0], size[1])
                const nav = find("sectionNav")
                keyClick(Qt.Key_Up)
                tryVerify(() => nav.activeFocus, 2000)
                for (let i = 0; i < nav.keys.length && nav.currentKey !== "notifications"; ++i)
                    keyClick(Qt.Key_Right)                    // Home, Games, Media, Store, Settings, the bell
                compare(nav.currentKey, "notifications", "the focus travelled to the bell")
                tryVerify(() => !find("navGlide").visible, 2000, size[1] + "p: the nav's highlight is gone from the nav's pill")
                const names = []
                bellItems(nav, size[1], names)
                verify(names.length >= 4, size[1] + "p: the bell's items were found: " + names)
                compare(names.filter(n => n === "bellGlass").length, 1, "one bell glass")
                compare(names.filter(n => n === "navPill_notifications").length, 1, "one bell pill")
                tc.shell.destroy()
                wait(50)
            }
        }

        // D-pad around the bell (RUY-1170): the nav's order is unchanged, the tray's first item is next to it.
        function test_dpad_goes_settings_bell_more_and_back() {
            Batteries.mockPopulate()
            openShell(1920, 1080)
            const nav = find("sectionNav")
            keyClick(Qt.Key_Up)
            tryVerify(() => nav.activeFocus, 2000, "up reaches the nav")
            nav.currentIndex = nav.keys.indexOf("settings")
            keyClick(Qt.Key_Right)
            compare(nav.currentKey, "notifications", "Right from Settings is the bell")
            keyClick(Qt.Key_Left)
            compare(nav.currentKey, "settings", "Left from the bell is Settings")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("batteryMore").activeFocus, 2000, "Right from the bell is the tray's first item")
            keyClick(Qt.Key_Left)
            tryVerify(() => nav.activeFocus && nav.currentKey === "notifications", 2000, "Left comes back to the bell")
            keyClick(Qt.Key_Down)
            tryVerify(() => !nav.activeFocus, 2000, "Down leaves the nav as from any pill")
            tc.shell.destroy()
            wait(50)
        }

        // "N more" has no container at rest; focused it draws the focus pill outside its content: nothing shifts.
        function test_n_more_draws_its_focus_pill_outside_the_content() {
            Batteries.mockPopulate()
            openShell(1920, 1080)
            const more = find("batteryMore")
            const focus = findChild(more, "batteryMoreFocus")
            compare(focus.visible, false, "nothing behind it at rest")
            waitForRendering(tc.shell)
            tryVerify(() => settled() && pillIsLaidOut(), 2000, "the tray is laid out")
            const clock = find("statusClock")
            // The chip's place relative to the clock: the clock text changes width every minute (HH:mm in a proportional
            // font) and the right-anchored tray moves with it, so absolute x would read that as a shift.
            const where = () => [more.mapToItem(tc.shell, 0, 0).x - clock.mapToItem(tc.shell, 0, 0).x, more.width]
            const before = where()
            openMore()
            compare(focus.visible, true)
            compare(find("hintBar").hints.map(h => (h.action ?? h.actions.join("+")) + " " + h.text),
                    ["accept Open", "tabPrev+tabNext Sections"], "a tray item says A Open, LB RB Sections")
            const u = tc.shell.u
            compare(focus.height, Theme.buttonHeight * u)
            compare(focus.width, more.width + 2 * Theme.spaceS * u, "the content and spaceS each side")
            compare(focus.border.width, Theme.focusRingWidth * u)
            compare(where(), before, "nothing shifts")
            compare(find("navPillFill_notifications").border.width, 0, "the bell's ring is off while it is not focused")
            keyClick(Qt.Key_Left)
            tryVerify(() => find("sectionNav").activeFocus && find("sectionNav").currentKey === "notifications", 2000)
            compare(find("navPillFill_notifications").border.width, Theme.focusRingWidth * u, "the bell's ring, as every pill's")
            compare(focus.visible, false)
            tc.shell.destroy()
            wait(50)
        }

        // A coarse battery (RUY-935) is a level-only chip: the kind icon and the level glyph, no number, the level in words.
        function test_a_level_only_chip_has_no_number_but_a_level_in_words() {
            Batteries.mockSet("pad-1", 60)
            const chip = createTemporaryObject(chipComponent, host, { deviceId: "pad-1", levelOnly: true })
            verify(chip)
            tryCompare(chip, "percent", 60)
            compare(findChild(chip, "batteryPercent").visible, false, "no number")
            verify(findChild(chip, "batteryLevelIcon").visible && findChild(chip, "batteryKindIcon").visible)
            compare(chip.Accessible.name, "Ruya Pad Pro battery level high")
            Batteries.mockSet("pad-1", 5)
            tryCompare(chip, "levelWord", "empty")
            compare(chip.Accessible.name, "Ruya Pad Pro battery level empty")
            compare(findChild(chip, "batteryLevelIcon").name, "battery_alert", "the low glyph is not colour alone")
            const numbered = createTemporaryObject(chipComponent, host, { deviceId: "pad-1" })
            compare(findChild(numbered, "batteryPercent").visible, true)
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
                ["none", () => { Batteries.mockClear() }],
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
            Batteries.mockSet("c3", 30, "discharging", "controller", "8BitDo Pro 2", "generic")
            Batteries.mockSet("padA", 80, "discharging", "controller", "Wireless Controller", "playstation", tc.padA)
            Batteries.mockSet("padB", 55, "discharging", "controller", "Wireless Controller", "playstation", tc.padB)
            openShell(1920, 1080)
            tryVerify(() => find("batteryMore").visible, 2000)
            openMore()
            wait(500)
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
        // The bell on its own pill at the tray's left (RUY-1170): focused on Home, then current on its page and focused again
        // from the page's top stop, English and Turkish, at 1080p and 720p.
        function test_zz_bell_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Batteries.mockPopulate()
            for (const lang of ["en", "tr"]) {
                DeviceSettings.language = lang
                for (const size of [[1920, 1080, "1080"], [1280, 720, "720"]]) {
                    openShell(size[0], size[1])
                    const nav = find("sectionNav")
                    keyClick(Qt.Key_Up)
                    tryVerify(() => nav.activeFocus, 2000)
                    nav.currentIndex = nav.keys.indexOf("notifications")
                    tryVerify(() => !find("navGlide").visible, 2000, "the nav's highlight has left the nav's pill")
                    waitForRendering(tc.shell)
                    grabImage(tc.shell).save(shotsDir + "/bell-place-" + lang + "-" + size[2] + "-focused.png")
                    if ((lang === "en" && size[2] === "1080") || (lang === "tr" && size[2] === "720")) {
                        // The unread badge on the moved bell.
                        NotificationCentre.post({ title: "Badge", kind: "info", source: "system" })
                        tryVerify(() => find("bellBadge").visible, 2000, "the badge shows")
                        waitForRendering(tc.shell)
                        grabImage(tc.shell).save(shotsDir + "/bell-place-" + lang + "-" + size[2] + "-badge.png")
                    }
                    keyClick(Qt.Key_Return)                          // its page: the bell is current
                    tryVerify(() => tc.shell.navSection === "notifications", 2000)
                    tryVerify(() => tc.shell.topSettled(), 3000, "the page has settled")
                    for (let i = 0; i < 4 && !nav.activeFocus; ++i)       // from the first row up to the top stop, then the nav
                        keyClick(Qt.Key_Up)
                    tryVerify(() => nav.activeFocus, 2000, "Up from the page's top stop reaches the nav")
                    waitForRendering(tc.shell)
                    grabImage(tc.shell).save(shotsDir + "/bell-place-" + lang + "-" + size[2] + "-current.png")
                    tc.shell.destroy()
                    wait(50)
                }
            }
            DeviceSettings.language = "en"
        }

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
                keyClick(Qt.Key_Left)                              // the bell, focused (the nav's last pill, RUY-1136)
                tryVerify(() => find("sectionNav").activeFocus && find("sectionNav").currentKey === "notifications", 2000)
                wait(300)
                grabImage(tc.shell).save(shotsDir + "/battery-bell-focus-" + lang + ".png")
                keyClick(Qt.Key_Right)
                tryVerify(() => find("batteryMore").activeFocus, 2000)
                keyClick(Qt.Key_Return)
                tryVerify(() => find("batteryList").shown, 2000)
                wait(600)
                grabImage(tc.shell).save(shotsDir + "/battery-list-" + lang + ".png")
                keyClick(Qt.Key_Escape)
                tryVerify(() => !find("batteryList").shown, 2000)
                tc.shell.destroy()
                wait(50)
            }
            // Turkish at 720p, "N tane daha" focused (RUY-1109).
            DeviceSettings.language = "tr"
            openShell(1280, 720)
            tryVerify(() => find("batteryMore").visible, 2000)
            openMore()
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/battery-more-tr-720.png")
            tc.shell.destroy()
            wait(50)
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
                tc.shell.destroy()
                wait(50)
            }
        }
    }
}
