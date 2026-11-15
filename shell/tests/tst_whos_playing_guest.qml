import QtQuick
import QtTest
import RuyaShell

// The Guest card of "Who's playing?" (RUY-631, 02 §1.9): it ends the row, Accept makes a temporary guest
// (Profiles.createGuest) and joins the pad to it at once (no step 2, no PIN), refusals are the toast, a
// guest made for a failed join is removed, a guest whose seat ends is wiped, and Lock sends nothing. The
// Xbox pad signs Player One (p1) in; the DualSense and the Pro Controller have no player.
Item {
    id: host
    width: 1920
    height: 1080

    readonly property string dualSense: "bluetooth-054c-0ce6-3f2a9c41d0b7"
    readonly property string xbox: "usb-045e-0b12-8e01c2d4a9f3"
    readonly property string pro: "bluetooth-057e-2009-b7c0e1f2a3d4"

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: joinSpy; target: Input; signalName: "joinFinished" }
    SignalSpy { id: createdSpy; target: Profiles; signalName: "guestCreated" }
    SignalSpy { id: removedSpy; target: Profiles; signalName: "guestRemoved" }

    // The order of the calls: a CreateGuest answer, then the join.
    property var order: []
    Connections {
        target: Profiles
        function onGuestCreated(status, id, number) { host.order = host.order.concat(["create " + status]) }
    }
    Connections {
        target: Input
        function onJoinFinished(deviceId, profile, status, slot) { host.order = host.order.concat(["join " + status]) }
    }

    TestCase {
        id: tc
        name: "WhosPlayingGuest"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        function prompt() { return find("whosPlaying") }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.language = "en"
            DeviceSettings.reducedMotion = false
            Library.resetMockForTests("")
            Session.mockReset()
            Profiles.resetMockForTests("seeded")
            Profiles.mockSetAvailable(true)
            Input.mockFail(false)
            Input.mockFailJoin("")
            Input.mockSeatHoldMs(60000)
            Input.mockResetDevices()
            joinSpy.clear()
            createdSpy.clear()
            removedSpy.clear()
            host.order = []
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            DeviceSettings.language = "en"
            Profiles.mockSetAvailable(true)
            Input.mockFailJoin("")
            Input.mockSeatHoldMs(60000)
            Input.mockResetDevices()
        }

        function signIn(w, h) {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host, { width: w ?? 1920, height: h ?? 1080 })
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has the focus")
            tryVerify(() => Input.devices.length === 3, 2000, "the mock's three pads are listed")
            Input.mockPadButton(host.xbox, "dpad_left")
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => Input.players.length === 1 && Input.players[0].device_id === host.xbox, 2000)
            tryVerify(() => Library.available)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            verify(!prompt().shown)
            joinSpy.clear()
            host.order = []
        }

        function askWith(deviceId) {
            Input.mockPadButton(deviceId, "south")
            tryVerify(() => prompt().shown && prompt().pad === deviceId, 2000, "the prompt opens for " + deviceId)
            tryVerify(() => Input.mockNavigator() === deviceId, 2000, "the asking pad navigates")
        }

        // A temporary guest of this session, seated on `deviceId`; its profile id.
        function seatGuest(deviceId) {
            const before = createdSpy.count
            Profiles.createGuest()
            tryCompare(createdSpy, "count", before + 1)
            compare(createdSpy.signalArguments[before][0], "ok")
            const id = createdSpy.signalArguments[before][1]
            const joins = joinSpy.count
            Input.joinPlayer(deviceId, id)
            tryCompare(joinSpy, "count", joins + 1)
            compare(joinSpy.signalArguments[joins][2], "ok")
            return id
        }

        function guestIds() { return Profiles.guests.map(g => g.id) }

        // Player Two (Ada) joins on the Pro Controller: every profile has a pad.
        function everyProfilePlays() {
            Input.joinPlayer(host.pro, "p2")
            tryVerify(() => Input.players.length === 2, 2000)
        }

        function openHub() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
        }

        // ---- the card ----------------------------------------------------------------------------------

        function test_the_guest_card_ends_the_row_after_the_profiles() {
            signIn()
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            compare(list.count, 3, "Player One, Ada, Guest")
            compare(prompt().cards.length, 2)
            list.currentIndex = 2
            const card = list.currentItem
            compare(card.width, Theme.cardProfileWidth * prompt().u)
            compare(card.height, Theme.cardProfileHeight * prompt().u)
            compare(findChild(card, "profileCardName").text, "Guest")
            verify(!findChild(card, "profileCardPlayer").visible, "no badge")
            compare(list.itemAtIndex(1).x < card.x, true, "after Ada")
            compare(list.itemAtIndex(1).modelData.name, "Ada")
            compare(card.isGuest, true)
            verify(!list.itemAtIndex(1).isGuest)
        }

        function test_the_detail_line_names_the_next_guest() {
            signIn()
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            list.currentIndex = 2
            list.forceActiveFocus()
            compare(find("whosPlayingDetail").text, "Joins as a guest. Nothing is kept after it leaves.")
            // Guest plays: the next one is Guest 2.
            find("whosPlayingNotNow").forceActiveFocus()
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown, 2000)
            seatGuest(host.pro)
            Input.mockPadButton(host.dualSense, "guide")
            tryVerify(() => prompt().shown && prompt().pad === host.dualSense, 2000, "Guide asks again")
            const again = find("whosPlayingCards")
            tryVerify(() => again.activeFocus, 2000)
            again.currentIndex = 2
            compare(find("whosPlayingDetail").text, "Joins as Guest 2. Nothing is kept after it leaves.")
            // Turkish: the prompt opens again with the language already set.
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown, 2000)
            DeviceSettings.language = "tr"
            Input.mockPadButton(host.dualSense, "guide")
            tryVerify(() => prompt().shown && prompt().pad === host.dualSense, 2000)
            const tr = find("whosPlayingCards")
            tryVerify(() => tr.activeFocus, 2000)
            tr.currentIndex = 2
            tryVerify(() => find("whosPlayingDetail").text === "Misafir 2 olarak katılır. Ayrılınca hiçbir şey saklanmaz.", 2000)
            tryVerify(() => findChild(tr.currentItem, "profileCardName").text === "Misafir", 2000)
        }

        function test_with_no_free_profile_the_guest_card_has_the_focus() {
            signIn()
            everyProfilePlays()
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            tryVerify(() => list.activeFocus && list.currentIndex === 2, 2000, "Guest, not Not now")
            compare(find("whosPlayingDetail").text, "Joins as a guest. Nothing is kept after it leaves.")
            const first = list.itemAtIndex(0)
            compare(findChild(first, "profileCardPlayer").text, "Player 1")
        }

        function test_a_free_profile_still_has_the_focus_first() {
            signIn()
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            tryVerify(() => list.activeFocus && list.currentIndex === 1, 2000, "Ada is free")
        }

        // ---- Accept ------------------------------------------------------------------------------------

        function test_accept_makes_a_guest_and_joins_it_at_once() {
            signIn()
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            list.currentIndex = 2
            keyClick(Qt.Key_Return)
            tryVerify(() => !prompt().shown, 2000, "it closes")
            compare(host.order, ["create ok", "join ok"], "CreateGuest, then JoinPlayer")
            compare(joinSpy.signalArguments[0][0], host.dualSense)
            compare(joinSpy.signalArguments[0][1], guestIds()[0], "the guest it made")
            compare(Profiles.guests.length, 1)
            compare(Input.players.length, 2)
            compare(Input.players[1].profile, guestIds()[0])
            compare(Input.players[1].device_id, host.dualSense)
            compare(prompt().step, "pick", "no step 2 and no PIN")
            verify(!find("whosPlayingPin").shown)
            compare(Notifications.model.count, 0)
        }

        function test_the_second_guest_is_guest_2() {
            signIn()
            seatGuest(host.pro)
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            list.currentIndex = 2
            keyClick(Qt.Key_Return)
            tryVerify(() => !prompt().shown, 2000)
            compare(Profiles.guests.map(g => g.number).sort(), [1, 2])
            compare(Profiles.nameOf(Profiles.guests.find(g => g.number === 2).id), "Guest 2")
            compare(Profiles.nameOf(Profiles.guests.find(g => g.number === 1).id), "Guest")
        }

        function test_three_guests_playing_say_so_and_accept_makes_no_call() {
            signIn()
            for (let i = 0; i < 3; ++i)
                Profiles.createGuest()
            tryCompare(createdSpy, "count", 3)
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            list.currentIndex = 2
            list.forceActiveFocus()
            compare(find("whosPlayingDetail").text, "Three guests are already playing. One must leave first.")
            const joins = joinSpy.count
            keyClick(Qt.Key_Return)
            wait(0)
            wait(0)
            compare(createdSpy.count, 3, "no CreateGuest call")
            compare(Notifications.model.count, 0, "no toast")
            compare(joinSpy.count, joins, "no join")
            verify(prompt().shown, "the prompt stays")
            verify(list.activeFocus && list.currentIndex === 2, "the focus stays on Guest")
        }

        function test_a_refused_create_shows_the_toast_and_keeps_the_focus() {
            signIn()
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            list.currentIndex = 2
            list.forceActiveFocus()
            Profiles.mockFailGuests("createGuest", "failed", 1)
            keyClick(Qt.Key_Return)
            tryCompare(Notifications.model, "count", 1)
            compare(Notifications.model.get(0).text, "Guest could not join")
            compare(Notifications.model.get(0).detail, "Try again.")
            verify(prompt().shown, "the prompt stays")
            compare(Profiles.guests.length, 0)
            tryVerify(() => list.activeFocus && list.currentIndex === 2, 2000, "the focus stays on Guest")
        }

        function test_two_guests_ending_together_are_both_removed() {
            signIn()
            seatGuest(host.pro)
            seatGuest(host.dualSense)
            compare(Profiles.guests.length, 2)
            Input.leavePlayer(2)
            Input.leavePlayer(3)
            tryVerify(() => Profiles.guests.length === 0, 3000, "both are wiped")
            compare(removedSpy.count, 2)
        }

        function test_a_refused_join_after_the_prompt_closed_still_removes_its_guest() {
            signIn()
            askWith(host.dualSense)
            Input.mockFailJoin("full")
            prompt().acceptGuest()
            prompt().close(false)                   // the asking pad went before the answers came
            tryCompare(Notifications.model, "count", 1)
            tryVerify(() => Profiles.guests.length === 0, 3000, "the guest it made is removed")
            compare(Input.players.length, 1)
        }

        function test_two_quick_guest_requests_leave_no_stray_guest() {
            signIn()
            askWith(host.dualSense)
            prompt().acceptGuest()
            prompt().acceptGuest()
            tryCompare(createdSpy, "count", 2)
            tryCompare(joinSpy, "count", 2)
            tryVerify(() => Profiles.guests.length === 1, 3000, "the guest that lost the pad is wiped")
            compare(Input.players.length, 2)
            compare(Input.players[1].device_id, host.dualSense)
            compare(Input.players[1].profile, guestIds()[0])
        }

        function test_a_failed_remove_is_retried_once_at_the_next_change() {
            signIn()
            seatGuest(host.pro)
            Profiles.mockFailGuests("removeGuest", "failed", 1)
            Input.leavePlayer(2)
            tryCompare(removedSpy, "count", 1)
            compare(removedSpy.signalArguments[0][1], "failed")
            compare(Profiles.guests.length, 1, "still there")
            Input.joinPlayer(host.pro, "p2")            // a change of the players
            tryVerify(() => Profiles.guests.length === 0, 3000, "the retry")
            compare(removedSpy.count, 2)
        }

        function test_unknown_profile_counts_as_done() {
            signIn()
            seatGuest(host.pro)
            Profiles.mockFailGuests("removeGuest", "unknown-profile", 1)
            Input.leavePlayer(2)
            tryCompare(removedSpy, "count", 1)
            Input.joinPlayer(host.pro, "p2")
            tryVerify(() => Input.players.length === 2, 2000)
            wait(0)
            wait(0)
            compare(removedSpy.count, 1, "not asked again")
        }

        function test_a_refused_join_removes_the_guest_it_made() {
            signIn()
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            list.currentIndex = 2
            Input.mockFailJoin("full")
            keyClick(Qt.Key_Return)
            tryCompare(Notifications.model, "count", 1)
            compare(Notifications.model.get(0).text, "Guest could not join")
            tryVerify(() => Profiles.guests.length === 0, 2000, "removeGuest")
            tryCompare(removedSpy, "count", 1)
            compare(removedSpy.signalArguments[0][1], "ok")
            verify(prompt().shown)
            tryVerify(() => list.activeFocus && list.currentIndex === 2, 2000, "the focus stays on Guest")
            compare(Input.players.length, 1)
        }

        // ---- names -------------------------------------------------------------------------------------

        function test_the_chips_and_the_hub_row_read_guest_and_guest_2() {
            signIn()
            seatGuest(host.pro)
            seatGuest(host.dualSense)
            tryVerify(() => find("playerChip_3") !== null, 2000)
            compare(find("playerChip_2").Accessible.name, "Guest, player 2")
            compare(find("playerChip_3").Accessible.name, "Guest 2, player 3")
            openHub()
            tryVerify(() => find("hubPlayers").visible, 2000)
            compare(findChild(find("hubPlayer_2"), "hubPlayerName").text, "Guest")
            compare(findChild(find("hubPlayer_3"), "hubPlayerName").text, "Guest 2")
            DeviceSettings.language = "tr"
            tryVerify(() => findChild(find("hubPlayer_2"), "hubPlayerName").text === "Misafir", 2000)
            tryVerify(() => findChild(find("hubPlayer_3"), "hubPlayerName").text === "Misafir 2", 2000)
            tryVerify(() => find("playerChip_3").Accessible.name === "Misafir 2, 3. oyuncu", 2000)
        }

        // ---- the wipe ----------------------------------------------------------------------------------

        function test_a_guest_who_leaves_is_wiped() {
            signIn()
            const id = seatGuest(host.pro)
            compare(guestIds(), [id])
            Input.leavePlayer(2)
            tryVerify(() => Profiles.guests.length === 0, 2000, "LeavePlayer")
            tryCompare(removedSpy, "count", 1)
            compare(removedSpy.signalArguments[0][0], id)
        }

        function test_a_guest_whose_hold_ends_is_wiped() {
            signIn()
            Input.mockSeatHoldMs(30)
            const id = seatGuest(host.pro)
            Input.mockRemoveDevice(host.pro)
            tryVerify(() => Profiles.guests.length === 0, 3000, "the hold ended")
            compare(removedSpy.signalArguments[0][0], id)
        }

        function test_a_guest_whose_pad_picks_a_profile_is_wiped() {
            signIn()
            seatGuest(host.pro)
            Input.joinPlayer(host.pro, "p2")
            tryVerify(() => Profiles.guests.length === 0, 2000, "the pad moved on to Ada")
            compare(Input.players.find(s => s.device_id === host.pro).profile, "p2")
        }

        function test_a_guest_who_stays_is_kept() {
            signIn()
            seatGuest(host.pro)
            Input.joinPlayer(host.dualSense, "p2")
            tryVerify(() => Input.players.length === 3, 2000)
            wait(0)
            wait(0)
            compare(Profiles.guests.length, 1)
            compare(removedSpy.count, 0)
        }

        function test_lock_sends_no_remove() {
            signIn()
            seatGuest(host.pro)
            seatGuest(host.dualSense)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => Profiles.guests.length === 0, 2000, "ruya-profiles wipes them")
            tryVerify(() => Input.players.length === 0, 2000, "the seats are gone")
            wait(0)
            wait(0)
            compare(removedSpy.count, 0, "the shell sent nothing")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            for (const lang of ["en", "tr"]) {
                for (const size of [[1920, 1080, "1080"], [1280, 720, "720"]]) {
                    init()
                    DeviceSettings.language = lang
                    signIn(size[0], size[1])
                    const tag = "whos-guest-" + lang + "-" + size[2]
                    // Guest focused, none playing.
                    askWith(host.dualSense)
                    find("whosPlayingCards").currentIndex = 2
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-none.png")
                    keyClick(Qt.Key_Escape)
                    tryVerify(() => !prompt().shown, 2000)
                    // Guest focused as Guest 2 (Guest plays on the Pro Controller).
                    seatGuest(host.pro)
                    Input.mockPadButton(host.dualSense, "guide")       // Not now keeps its presses quiet
                    tryVerify(() => prompt().shown && prompt().pad === host.dualSense, 2000)
                    find("whosPlayingCards").currentIndex = 2
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-guest2.png")
                    keyClick(Qt.Key_Escape)
                    tryVerify(() => !prompt().shown, 2000)
                    // The Hub row with a guest.
                    openHub()
                    tryVerify(() => find("hubPlayers").visible, 2000)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-hub.png")
                    tc.shell.destroy()
                    wait(50)
                    // The empty board: Player One plays, Ada plays, Guest has the focus.
                    init()
                    DeviceSettings.language = lang
                    signIn(size[0], size[1])
                    everyProfilePlays()
                    askWith(host.dualSense)
                    tryVerify(() => find("whosPlayingCards").currentIndex === 2, 2000)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-empty.png")
                    // Three guests play already.
                    for (let i = 0; i < 3; ++i)
                        Profiles.createGuest()
                    tryVerify(() => Profiles.guests.length === 3, 2000)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-full.png")
                    tc.shell.destroy()
                    wait(50)
                }
            }
        }
    }
}
