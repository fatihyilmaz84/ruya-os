import QtQuick
import QtTest
import RuyaShell

// Who plays is visible (RUY-629, 04 section 5 "Player chip" and the Quick menu's players row): the top
// bar shows player 1's chip with the name, then each other player's chip; the Ruya Hub gets a players
// row while two or more play. Players are seated through the mock Input service (nothing in the shell
// joins one yet). Signs in as Ada (p2). `shots` saves Home with two players and the Hub with three and
// four, in English and Turkish, at 1080p and 720p.
Item {
    id: host
    width: 1920
    height: 1080

    readonly property string xbox: "usb-045e-0b12-8e01c2d4a9f3"
    readonly property string pro: "bluetooth-057e-2009-b7c0e1f2a3d4"
    readonly property string extra: "usb-1234-5678-000000000001"

    Component {
        id: shellComponent
        Shell { version: "test"; focus: true }
    }

    SignalSpy { id: joinSpy; target: Input; signalName: "joinFinished" }
    SignalSpy { id: leaveSpy; target: Input; signalName: "leaveFinished" }
    SignalSpy { id: guestSpy; target: Profiles; signalName: "guestCreated" }
    SignalSpy { id: renameSpy; target: Profiles; signalName: "renameFinished" }

    TestCase {
        id: tc
        name: "PlayerChips"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        function u() { return tc.shell.u }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.language = "en"
            Theme.motionFactor = 0.03
            Batteries.mockClear()
            Input.mockFail(false)
            Input.mockFailJoin("")
            Input.mockNameOwned(true)
            Input.mockResetDevices()
            Input.mockAddDevice({ id: host.extra, family: "generic" })
            Profiles.resetMockForTests("seeded")
            joinSpy.clear()
            leaveSpy.clear()
            guestSpy.clear()
            renameSpy.clear()
        }

        function cleanup() {
            Theme.motionFactor = 1.0
            DeviceSettings.language = "en"
        }

        function openShell(w, h) {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host, { width: w ?? 1920, height: h ?? 1080 })
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay") !== null && find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            tryVerify(() => Input.players.length === 1, 2000, "player 1 is seated by the sign-in")
        }

        function join(deviceId, profile) {
            const before = joinSpy.count
            Input.joinPlayer(deviceId, profile)
            tryCompare(joinSpy, "count", before + 1)
            compare(joinSpy.signalArguments[before][2], "ok")
        }

        function rename(id, name) {
            const before = renameSpy.count
            Profiles.renameProfile("p1", "1234", id, name)
            tryCompare(renameSpy, "count", before + 1)
            compare(renameSpy.signalArguments[before][1], "ok")
        }

        // A guest of this session: its profile id.
        function newGuest() {
            const before = guestSpy.count
            Profiles.createGuest()
            tryCompare(guestSpy, "count", before + 1)
            compare(guestSpy.signalArguments[before][0], "ok")
            return guestSpy.signalArguments[before][1]
        }

        // Three players with long names and a guest: all four seats.
        function seatFour() {
            rename("p1", "Alexandria Montgomery")
            rename("p3", "Bartholomew Winchester")
            join(host.xbox, "p1")
            join(host.pro, "p3")
            join(host.extra, newGuest())
            tryVerify(() => Input.players.length === 4, 2000, "four players")
        }

        function openHub() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
        }

        // Where the top bar's chip of seat `slot` is, in the cluster.
        function chipX(slot) { return find("playerChip_" + slot).mapToItem(find("statusGlass"), 0, 0).x }

        function test_one_player_is_todays_avatar_and_no_row() {
            openShell()
            const chip = find("playerChip_1")
            verify(chip && chip.visible)
            compare(chip.width, 48 * u())
            compare(chip.height, 48 * u())
            verify(!findChild(chip, "playerDot").visible, "no number dot for one player")
            compare(find("playerChip_2"), null)
            compare(find("activeProfileName").text, "Ada")
            openHub()
            verify(!find("hubPlayers").visible, "no players row for one player")
            compare(find("hubPlayers").height, 0)
        }

        function test_two_players_show_two_chips_and_the_hub_row() {
            openShell()
            join(host.xbox, "p1")
            tryVerify(() => find("playerChip_2") !== null, 2000, "the second chip")
            const first = find("playerChip_1"), second = find("playerChip_2")
            compare(findChild(first, "playerDigit").text, "1")
            compare(findChild(second, "playerDigit").text, "2")
            verify(findChild(first, "playerDot").visible && findChild(second, "playerDot").visible)
            // The name sits between them; the next chip is `spaceS` after it.
            const name = find("activeProfileName")
            const nameRight = name.mapToItem(find("statusGlass"), name.width, 0).x
            tryVerify(() => Math.abs(chipX(2) - nameRight - Theme.spaceS * u()) < 1.5, 2000,
                      "second chip " + chipX(2) + " after the name's end " + nameRight)
            compare(second.Accessible.name, "Player One, player 2")
            compare(first.Accessible.name, "Ada, player 1")
            openHub()
            tryVerify(() => find("hubPlayers").visible, 2000, "the Hub's players row")
            compare(findChild(find("hubPlayer_1"), "hubPlayerName").text, "Ada")
            compare(findChild(find("hubPlayer_2"), "hubPlayerName").text, "Player One")
            // The second player starts `spaceM` after the first.
            const a = find("hubPlayer_1"), b = find("hubPlayer_2")
            compare(b.x, a.x + a.width + Theme.spaceM * u())
        }

        function test_a_player_who_leaves_disappears_from_both() {
            openShell()
            join(host.xbox, "p1")
            tryVerify(() => find("playerChip_2") !== null, 2000)
            openHub()
            tryVerify(() => find("hubPlayers").visible, 2000)
            Input.leavePlayer(2)
            tryCompare(leaveSpy, "count", 1)
            tryVerify(() => find("playerChip_2") === null, 2000, "the top bar's chip is gone")
            tryVerify(() => !find("hubPlayers").visible, 2000, "the Hub's row is gone")
            verify(!findChild(find("playerChip_1"), "playerDot").visible, "one player again: no dot")
        }

        function test_geometry_chip_dot_and_offset() {
            openShell()
            join(host.xbox, "p1")
            tryVerify(() => find("playerChip_2") !== null, 2000)
            const chip = find("playerChip_2")
            const circle = findChild(chip, "playerAvatar"), dot = findChild(chip, "playerDot")
            compare(circle.width, 48 * u())
            compare(dot.width, 28 * u())
            compare(dot.height, 28 * u())
            compare(dot.x + dot.width, circle.width + 6 * u(), "overhangs by 6 u to the right")
            compare(dot.y + dot.height, circle.height + 6 * u(), "and by 6 u downwards")
        }

        // The battery chips give way before a player chip: each further player takes 64 u from the budget.
        function test_the_budget_counts_each_further_player() {
            openShell(1280, 720)
            Batteries.mockPopulate()
            const glass = find("statusGlass")
            tryVerify(() => glass.batteryDevices.length >= 4, 2000)
            const baseWidth = glass.fixedWidth
            const baseChips = glass.chipCount
            join(host.xbox, "p1")
            join(host.pro, "p3")
            tryVerify(() => glass.otherPlayers.length === 2, 2000)
            compare(glass.fixedWidth, baseWidth + 2 * (Theme.statusAvatarSize + Theme.spaceS) * u())
            verify(glass.chipCount <= baseChips, "never more battery chips with more players")
            verify(glass.chipCount < baseChips || glass.moreCompact,
                   "the battery group gave way: " + baseChips + " -> " + glass.chipCount)
            verify(glass.x >= find("sectionNav").x + find("sectionNav").width, "the pill stays clear of the nav")
        }

        function test_a_long_name_is_elided_at_110u() {
            openShell()
            rename("p1", "Alexandria Montgomery")
            join(host.xbox, "p1")
            openHub()
            tryVerify(() => find("hubPlayers").visible && find("hubPlayer_2") !== null, 2000)
            const longName = findChild(find("hubPlayer_2"), "hubPlayerName")
            tryCompare(longName, "text", "Alexandria Montgomery")
            compare(longName.width, 110 * u())
            verify(longName.truncated, "elided at the end")
        }

        function test_four_players_wrap_the_hub_row_inside_the_panel() {
            openShell()
            seatFour()
            openHub()
            const row = find("hubPlayers")
            tryVerify(() => row.visible && find("hubPlayer_4") !== null, 2000)
            const entries = [1, 2, 3, 4].map(s => find("hubPlayer_" + s))
            const ys = entries.map(e => e.y)
            const lines = Array.from(new Set(ys)).sort((a, b) => a - b)
            compare(lines.length, 2, "two lines: " + ys)
            for (const e of entries)
                verify(e.x + e.width <= row.width + 0.5, "inside the content width: " + e.x + "+" + e.width + " > " + row.width)
            // The second line starts a chip and `spaceS` under the first (the entries are `spaceM - spaceS` short).
            compare(lines[1] - lines[0], (48 + Theme.spaceS) * u())
            const panel = find("guidePanel")
            verify(row.mapToItem(panel, 0, row.height).y <= panel.height, "inside the panel")
            compare(findChild(find("hubPlayer_4"), "hubPlayerName").text, "Guest 1")
        }

        function test_the_hub_keeps_its_stops_focus_and_back() {
            openShell()
            openHub()
            const menu = find("systemPanel")
            const keysOne = JSON.stringify(menu.itemKeys)
            const startKey = menu.currentKey
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("systemActions").activeFocus, 2000, "the Hub closes")
            seatFour()
            openHub()
            tryVerify(() => find("hubPlayers").visible, 2000)
            compare(JSON.stringify(menu.itemKeys), keysOne, "the same stops")
            compare(menu.currentKey, startKey, "the same first focus")
            verify(find("systemActions").activeFocus)
            for (const s of [1, 2, 3, 4]) {
                verify(!find("hubPlayer_" + s).activeFocus, "a player entry never takes focus")
                verify(!find("playerChip_" + s).activeFocus)
            }
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Up)
            compare(menu.currentKey, startKey)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("systemActions").activeFocus, 2000, "Back closes the Hub")
        }

        // RUY-649: a seat held for a removed pad dims the chip, shows the waiting glyph for the number and
        // reads ", held"; the pad back, and it is as before. Top bar and Hub row alike.
        function test_a_held_seat_is_dimmed_with_a_glyph_and_read_as_held() {
            openShell()
            Input.mockSeatHoldMs(60000)
            join(host.xbox, "p1")
            openHub()
            // The Repeaters rebuild their chips when the seats change: find them afresh each time.
            const bar = () => find("playerChip_2")
            const hub = () => findChild(find("hubPlayer_2"), "playerAvatar").parent
            tryVerify(() => bar() !== null && find("hubPlayer_2") !== null, 2000)
            compare(findChild(bar(), "playerAvatar").opacity, 1.0)
            verify(!findChild(bar(), "playerHeldGlyph").visible)
            Input.mockRemoveDevice(host.xbox)
            tryVerify(() => bar() !== null && bar().held, 2000, "the top bar's chip is held")
            compare(findChild(bar(), "playerAvatar").opacity, 0.5)
            verify(findChild(bar(), "playerHeldGlyph").visible, "the glyph in the dot")
            verify(!findChild(bar(), "playerDigit").visible, "in place of the number")
            compare(bar().Accessible.name, "Player One, player 2, held")
            tryVerify(() => hub().held, 2000, "and the Hub's")
            compare(findChild(hub(), "playerAvatar").opacity, 0.5)
            compare(hub().Accessible.name, "Player One, player 2, held")
            // Player 1 is not held.
            compare(find("playerChip_1").Accessible.name, "Ada, player 1")
            verify(!find("playerChip_1").held)
            Input.mockAddDevice({ id: host.xbox, family: "xbox" })
            tryVerify(() => bar() !== null && !bar().held, 2000, "the pad is back")
            compare(findChild(bar(), "playerAvatar").opacity, 1.0)
            verify(findChild(bar(), "playerDigit").visible)
            verify(!findChild(bar(), "playerHeldGlyph").visible)
            compare(bar().Accessible.name, "Player One, player 2")
            tryVerify(() => !hub().held, 2000)
        }

        function test_the_held_name_is_turkish() {
            DeviceSettings.language = "tr"
            openShell()
            Input.mockSeatHoldMs(60000)
            join(host.xbox, "p1")
            tryVerify(() => find("playerChip_2") !== null, 2000)
            Input.mockRemoveDevice(host.xbox)
            tryVerify(() => find("playerChip_2") !== null && find("playerChip_2").held, 2000)
            compare(find("playerChip_2").Accessible.name, "Player One, 2. oyuncu, bekleniyor")
        }

        // Chip 1 stands for seat 1's profile, not for whoever is signed in.
        function test_chip_one_follows_seat_ones_profile() {
            openShell()
            compare(find("playerChip_1").profileId, "p2")
            Input.setRoute("shell", "", "", "p1")
            tryVerify(() => Input.players.length === 1 && Input.players[0].slot === 1 && Input.players[0].profile === "p1",
                      2000, "p1 sits in seat 1: " + JSON.stringify(Input.players))
            tryCompare(find("playerChip_1"), "profileId", "p1")
            compare(find("playerChip_1").Accessible.name, "Player One, player 1")
            compare(Profiles.activeProfile, "p2", "the signed-in profile is unchanged")
        }

        // The Hub row's name is read once: the entry is hidden from assistive tech, its chip carries it.
        function test_the_hub_row_names_each_player_once() {
            openShell()
            join(host.xbox, "p1")
            openHub()
            tryVerify(() => find("hubPlayer_2") !== null, 2000)
            for (const s of [1, 2]) {
                const entry = find("hubPlayer_" + s)
                verify(entry.Accessible.ignored, "the entry wrapper is ignored")
                const chip = findChild(entry, "playerAvatar").parent
                verify(!chip.Accessible.ignored, "the chip is read")
                compare(chip.Accessible.name, s === 1 ? "Ada, player 1" : "Player One, player 2")
            }
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            for (const lang of ["en", "tr"]) {
                for (const size of [[1920, 1080, "1080"], [1280, 720, "720"]]) {
                    init()
                    DeviceSettings.language = lang
                    openShell(size[0], size[1])
                    join(host.xbox, "p1")
                    tryVerify(() => find("playerChip_2") !== null, 2000)
                    wait(400)
                    const tag = "players-" + lang + "-" + size[2]
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-home2.png")
                    grabImage(find("statusGlass")).save(shotsDir + "/" + tag + "-home2-crop.png")
                    Input.mockSeatHoldMs(60000)
                    Input.mockRemoveDevice(host.xbox)
                    tryVerify(() => find("playerChip_2") !== null && find("playerChip_2").held, 2000)
                    wait(300)
                    grabImage(find("statusGlass")).save(shotsDir + "/" + tag + "-held-crop.png")
                    Input.mockAddDevice({ id: host.xbox, family: "xbox" })
                    tryVerify(() => !find("playerChip_2").held, 2000)
                    rename("p1", "Alexandria Montgomery")
                    rename("p3", "Bartholomew Winchester")
                    join(host.pro, "p3")
                    tryVerify(() => Input.players.length === 3, 2000)
                    openHub()
                    tryVerify(() => find("hubPlayer_3") !== null, 2000)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-hub3.png")
                    Input.mockRemoveDevice(host.pro)
                    tryVerify(() => find("hubPlayer_3") !== null && findChild(find("hubPlayer_3"), "playerAvatar").parent.held, 2000)
                    wait(300)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-hub3-held.png")
                    Input.mockAddDevice({ id: host.pro, family: "switch" })
                    tryVerify(() => !findChild(find("hubPlayer_3"), "playerAvatar").parent.held, 2000)
                    join(host.extra, newGuest())
                    tryVerify(() => find("hubPlayer_4") !== null, 2000)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-hub4.png")
                    tc.shell.destroy()
                    wait(50)
                }
            }
        }
    }
}
