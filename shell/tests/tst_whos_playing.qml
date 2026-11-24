import QtQuick
import QtTest
import RuyaShell

// "Who's playing?" for a new controller (RUY-122, ADR-017 points 2-3 and 6, 02 §1.9), through the Shell
// and the mock services: it opens on a pad with no player that connects, presses (unless quiet) or
// presses Guide, only while a profile is signed in; over a game it pauses it like the Hub (the Freeze,
// route "overlay") and the game resumes by itself after a pick or Not now; asking pads queue; the
// asking pad navigates while it is open; Pick (focus, detail line, badges), Join or Switch, the errors,
// the waiting text, the padless seat 1 (its card joins at once: no Move), and the geometry at 1080p. Move
// and the PIN are tst_whos_playing_pin.qml (RUY-628). The Xbox pad
// signs Player One (p1) in; the DualSense and the Pro Controller have no player.
Item {
    id: host
    width: 1920
    height: 1080

    readonly property string dualSense: "bluetooth-054c-0ce6-3f2a9c41d0b7"
    readonly property string xbox: "usb-045e-0b12-8e01c2d4a9f3"
    readonly property string pro: "bluetooth-057e-2009-b7c0e1f2a3d4"
    readonly property string extra: "usb-2dc8-3106-0a1b2c3d4e5f"

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A window of an app that takes every key, like a game.
    Component {
        id: appComponent
        Item {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            property int keysSeen: 0
            Keys.onPressed: event => { keysSeen++; event.accepted = true }
            Keys.onReleased: event => { keysSeen++; event.accepted = true }    // the release of the closing key too
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }
    SignalSpy { id: devicesSpy; target: Input; signalName: "devicesChanged" }
    SignalSpy { id: joinSpy; target: Input; signalName: "joinFinished" }
    SignalSpy { id: navigatorSpy; target: Input; signalName: "navigatorFinished" }
    SignalSpy { id: foreignSpy; target: Input; signalName: "foreignInput" }

    // The order of a Switch: the Lock and the sign-in (activeProfile) and then the join.
    property var order: []
    Connections {
        target: Profiles
        function onActiveProfileChanged() { host.order = host.order.concat(["active " + Profiles.activeProfile]) }
    }
    Connections {
        target: Input
        function onJoinFinished(deviceId, profile, status, slot) {
            host.order = host.order.concat(["join " + deviceId + " " + profile + " " + status])
        }
    }

    TestCase {
        id: tc
        name: "WhosPlaying"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        function prompt() { return find("whosPlaying") }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.language = "en"
            DeviceSettings.reducedMotion = false
            DeviceSettings.pauseGamesInHub = true
            Library.resetMockForTests("")
            Session.mockReset()
            Profiles.resetMockForTests("seeded")
            Profiles.mockSetAvailable(true)
            Input.mockFail(false)
            Input.mockFailJoin("")
            Input.mockSeatHoldMs(60000)
            Input.mockResetDevices()
            launchedSpy.clear()
            joinSpy.clear()
            navigatorSpy.clear()
            foreignSpy.clear()
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

        // The Xbox pad signs Player One (p1, PIN 1234) in: it is player 1. Optionally at another size.
        function signIn(w, h) {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host, { width: w ?? 1920, height: h ?? 1080 })
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has the focus")
            tryVerify(() => Input.devices.length === 3, 2000, "the mock's three pads are listed")
            Input.mockPadButton(host.xbox, "dpad_left")     // the Xbox pad is the one in use
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => Input.players.length === 1 && Input.players[0].profile === "p1"
                      && Input.players[0].device_id === host.xbox, 2000, "player 1 is on the Xbox pad")
            tryVerify(() => Library.available)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            verify(!prompt().shown)
            navigatorSpy.clear()
            host.order = []
        }

        // A pad with no player presses a button: the prompt opens for it.
        function askWith(deviceId) {
            Input.mockPadButton(deviceId, "south")
            tryVerify(() => prompt().shown && prompt().pad === deviceId, 2000, "the prompt opens for " + deviceId)
            tryVerify(() => Input.mockNavigator() === deviceId, 2000, "the asking pad navigates")
        }

        // The pad presses until the service's ForeignInput "press" is heard (it sends one a second at
        // most): the shell has had the press it reacts to.
        function pressUntilHeard(deviceId) {
            foreignSpy.clear()
            tryVerify(() => heardOrPress(deviceId), 3000, "the press of " + deviceId + " reached the shell")
            wait(0)                     // the shell's own reaction (Qt.callLater) has run
        }
        function heardOrPress(deviceId) {
            for (let i = 0; i < foreignSpy.count; ++i) {
                if (foreignSpy.signalArguments[i][0] === deviceId && foreignSpy.signalArguments[i][1] === "press")
                    return true
            }
            Input.mockPadButton(deviceId, "south")
            return false
        }

        function recordOf(instance) {
            return Session.running.find(r => r.instance === instance)
        }

        // Player 1 presses Play on the hero: the app runs and takes the focus.
        function playRacer() {
            Input.mockPadButton(host.xbox, "south")
            tryCompare(launchedSpy, "count", 1)
            const instance = launchedSpy.signalArguments[0][3]
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            const app = createTemporaryObject(appComponent, host)
            verify(app)
            tc.shell.addApp(app, "p1")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")
            tryVerify(() => Input.mockServiceRoute() === "app", 2000)
            compare(Session.mockCalls(), [], "nothing frozen yet")
            return { app: app, instance: instance }
        }

        function cardOf(index) {
            const list = find("whosPlayingCards")
            list.currentIndex = index
            return list.currentItem
        }

        function badgeOn(index) {
            return findChild(cardOf(index), "profileCardPlayer")
        }

        // ---- opening -----------------------------------------------------------------------------------------

        function test_it_opens_on_a_connect_while_signed_in_and_not_on_the_picker() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            tc.shell.forceActiveFocus()
            tryVerify(() => find("profileList").activeFocus, 2000)
            tryVerify(() => Input.devices.length === 3, 2000)
            Input.mockAddDevice({ id: host.extra, name: "8BitDo Pro 2", family: "generic" })
            tryVerify(() => Input.devices.length === 4, 2000)
            wait(50)
            verify(!prompt().shown, "not on the picker")
            verify(find("profileList").activeFocus)
            Input.mockRemoveDevice(host.extra)
            tryVerify(() => Input.devices.length === 3, 2000)
            Input.mockPadButton(host.xbox, "dpad_left")
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            wait(50)
            verify(!prompt().shown, "the pads that were there do not ask")
            Input.mockAddDevice({ id: host.extra, name: "8BitDo Pro 2", family: "generic" })
            tryVerify(() => prompt().shown && prompt().pad === host.extra, 2000, "a pad that connects asks")
            tryVerify(() => find("whosPlayingCards").activeFocus, 2000, "the cards have the focus")
            compare(find("whosPlayingTitle").text, "Who's playing?")
            verify(find("whosPlayingPadLine") !== null)
        }

        function test_it_opens_on_a_press_not_again_while_quiet_and_guide_reopens_it() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Escape)                                 // Back = Not now
            tryVerify(() => !prompt().shown, 2000)
            tryVerify(() => find("homePlay").activeFocus, 2000, "the focus is back on Home")
            tryVerify(() => Input.mockNavigator() === "", 2000, "the navigator is cleared")
            pressUntilHeard(host.dualSense)
            verify(!prompt().shown, "a quiet pad's press asks nothing")
            Input.mockPadButton(host.dualSense, "guide")
            tryVerify(() => prompt().shown && prompt().pad === host.dualSense, 2000, "its Guide always opens it")
            // Over Home the quiet ends when the pad disconnects.
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown, 2000)
            const record = JSON.parse(JSON.stringify(Input.devices.find(d => d.id === host.dualSense)))
            Input.mockRemoveDevice(host.dualSense)
            tryVerify(() => !Input.devices.some(d => d.id === host.dualSense), 2000)
            Input.mockAddDevice(record)
            tryVerify(() => prompt().shown && prompt().pad === host.dualSense, 2000, "back, it asks on connect")
        }

        // ---- the pause ----------------------------------------------------------------------------------------

        function test_over_a_game_it_pauses_and_not_now_resumes() {
            signIn()
            const run = playRacer()
            askWith(host.dualSense)
            tryVerify(() => recordOf(run.instance).frozen === true, 2000, "the game is frozen")
            compare(Session.mockCalls(), ["freeze " + run.instance])
            tryVerify(() => Input.mockServiceRoute() === "overlay" && Input.mockServiceInstance() === run.instance, 2000,
                      "the route is overlay with the instance")
            verify(find("whosPlayingPausedPill").visible, "the Paused pill")
            verify(find("whosPlayingPausedText").text.startsWith("Paused · "))
            verify(!run.app.activeFocus)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown && run.app.activeFocus, 2000, "Not now: back in the game")
            tryVerify(() => Session.mockCalls().length === 2, 2000)
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance])
            tryVerify(() => Input.mockServiceRoute() === "app" && Input.mockServiceInstance() === run.instance, 2000,
                      "the route is app again")
            compare(run.app.keysSeen, 0, "the game saw none of it")
            // Quiet until the game exits.
            pressUntilHeard(host.dualSense)
            verify(!prompt().shown, "quiet over the game")
            Session.stop(run.instance)
            tryVerify(() => recordOf(run.instance) === undefined, 3000, "the game exited")
            pressUntilHeard(host.dualSense)
            tryVerify(() => prompt().shown && prompt().pad === host.dualSense, 2000, "the quiet ended with the game")
        }

        function test_over_a_game_join_resumes_it() {
            signIn()
            const run = playRacer()
            askWith(host.dualSense)
            tryVerify(() => find("whosPlayingCards").activeFocus, 2000)
            compare(find("whosPlayingCards").currentIndex, 1, "Ada, the first profile without a pad")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000, "Join or Switch, Join first")
            keyClick(Qt.Key_Return)
            tryVerify(() => !prompt().shown && run.app.activeFocus, 2000, "joined: back in the game")
            compare(joinSpy.signalArguments[0][0], host.dualSense)
            compare(joinSpy.signalArguments[0][1], "p2")
            compare(joinSpy.signalArguments[0][2], "ok")
            tryVerify(() => Session.mockCalls().length === 2, 2000)
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance])
            tryVerify(() => Input.mockServiceRoute() === "app", 2000)
            compare(run.app.keysSeen, 0, "the game saw no key, not the release of Accept either")
            compare(Input.players.map(p => p.slot + ":" + p.profile + ":" + p.device_id).join(" "),
                    "1:p1:" + host.xbox + " 2:p2:" + host.dualSense)
        }

        function test_over_home_nothing_is_frozen() {
            signIn()
            askWith(host.dualSense)
            verify(!find("whosPlayingPausedPill").visible, "no Paused pill over Home")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown, 2000)
            wait(50)
            compare(Session.mockCalls(), [])
            compare(Input.mockServiceRoute(), "shell")
        }

        function test_it_closes_back_to_an_open_hub() {
            signIn()
            const run = playRacer()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemPanel").open && find("systemActions").activeFocus, 2000, "the Hub")
            tryVerify(() => recordOf(run.instance).frozen === true, 2000)
            askWith(host.dualSense)
            tryVerify(() => find("whosPlayingCards").activeFocus, 2000, "the prompt over the Hub")
            compare(tc.shell.hintList[1].text, "Not now", "its own hints over the Hub")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown && find("systemActions").activeFocus, 2000, "back to the Hub")
            verify(find("systemPanel").open)
            wait(50)
            compare(Session.mockCalls(), ["freeze " + run.instance], "the game stays paused under the Hub")
        }

        // "Pause games when Ruya Hub opens" off: the game is not frozen, but the route still holds its pads
        // (overlay with the instance), so it sees no input while the prompt is open.
        function test_with_the_pause_off_the_game_runs_and_sees_no_input() {
            DeviceSettings.pauseGamesInHub = false
            signIn()
            const run = playRacer()
            askWith(host.dualSense)
            tryVerify(() => Input.mockServiceRoute() === "overlay" && Input.mockServiceInstance() === run.instance, 2000,
                      "the route is overlay with the instance")
            wait(50)
            compare(Session.mockCalls(), [], "no Freeze is asked")
            verify(recordOf(run.instance).frozen !== true)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown && run.app.activeFocus, 2000)
            tryVerify(() => Input.mockServiceRoute() === "app", 2000)
            compare(Session.mockCalls(), [], "and no Thaw")
            compare(run.app.keysSeen, 0)
            DeviceSettings.pauseGamesInHub = true
        }

        // Two pads ask over a game: the game stays frozen from the first prompt to the end of the second.
        function test_two_prompts_in_a_row_keep_the_game_frozen() {
            signIn()
            const run = playRacer()
            askWith(host.dualSense)
            pressUntilHeard(host.pro)
            compare(prompt().queue, [host.pro])
            tryVerify(() => Session.mockCalls().length === 1, 2000)
            keyClick(Qt.Key_Escape)                                 // Not now for the DualSense
            tryVerify(() => prompt().shown && prompt().pad === host.pro, 2000, "the Pro Controller asks next")
            verify(!run.app.activeFocus)
            tryVerify(() => find("whosPlayingCards").activeFocus, 2000)
            compare(Input.mockServiceRoute(), "overlay")
            wait(50)
            compare(Session.mockCalls(), ["freeze " + run.instance], "no Thaw and no second Freeze between them")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown && run.app.activeFocus, 2000, "the game after the last one")
            tryVerify(() => Session.mockCalls().length === 2, 2000)
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance])
            compare(run.app.keysSeen, 0)
        }

        // Player 1's pad goes while the prompt is open over the game (reviewer's probe, round 2): the Hub
        // waits under nothing, the prompt keeps the focus, and its close opens the lost-pad Hub with the
        // focus, the game still frozen; the keyboard's Back never reaches the game.
        function test_a_lost_pad_hub_waits_for_the_prompt() {
            signIn()
            const run = playRacer()
            askWith(host.dualSense)
            tryVerify(() => find("whosPlayingCards").activeFocus, 2000)
            Input.mockRemoveDevice(host.xbox)
            tryVerify(() => Input.players.length === 1 && Input.players[0].held === true, 2000, "seat 1 is held")
            wait(50)
            verify(!find("systemPanel").open, "no Hub under the prompt")
            verify(find("whosPlayingCards").activeFocus, "the prompt keeps the focus")
            keyClick(Qt.Key_Escape)                                 // Not now
            tryVerify(() => !prompt().shown && find("systemPanel").open && find("systemActions").activeFocus, 2000,
                      "the lost-pad Hub opens with the focus")
            verify(find("quickMenuItem_resume").focused)
            wait(50)
            compare(Session.mockCalls(), ["freeze " + run.instance], "frozen throughout, no Thaw")
            compare(run.app.keysSeen, 0)
            keyClick(Qt.Key_Escape)                                 // Back closes the Hub: the game again
            tryVerify(() => run.app.activeFocus && !find("systemPanel").open, 2000)
            verify(!prompt().shown)
        }

        // The pad comes back before the prompt closes: no Hub then.
        function test_a_lost_pad_back_before_the_prompt_closes_opens_no_hub() {
            signIn()
            const run = playRacer()
            const record = JSON.parse(JSON.stringify(Input.devices.find(d => d.id === host.xbox)))
            askWith(host.dualSense)
            Input.mockRemoveDevice(host.xbox)
            tryVerify(() => Input.players.length === 1 && Input.players[0].held === true, 2000)
            Input.mockAddDevice(record)
            tryVerify(() => Input.players[0].held === false, 2000, "the seat is the pad's again")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown && run.app.activeFocus, 2000, "back in the game, no Hub")
            verify(!find("systemPanel").open)
        }

        // A page's lazily built modal leaves the modal layer: the prompt is not blocked after it (round 2,
        // the reviewer's probe; `Shell.modalShown` skips a child that is gone).
        function test_it_opens_after_a_page_was_open() {
            failOnWarning(/TypeError/)          // a null child of the modal layer once threw here (round 2)
            signIn()
            keyClick(Qt.Key_Up)
            tryVerify(() => find("sectionNav").activeFocus, 2000)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("page_settings") !== null && find("page_settings").activeFocus, 2000)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("sectionNav").activeFocus, 2000)
            verify(!prompt().blocked)
            askWith(host.dualSense)
        }

        // ---- the queue and the navigator ----------------------------------------------------------------------

        function test_two_pads_queue_and_the_navigator_follows() {
            signIn()
            askWith(host.dualSense)
            compare(navigatorSpy.signalArguments[0][0], host.dualSense)
            pressUntilHeard(host.pro)
            compare(prompt().pad, host.dualSense, "one at a time")
            compare(prompt().queue, [host.pro])
            // The asking pad drives it; player 1's pad does nothing meanwhile.
            Input.mockPadButton(host.xbox, "dpad_left")
            wait(50)
            compare(find("whosPlayingCards").currentIndex, 1)
            Input.mockPadButton(host.dualSense, "dpad_left")
            tryCompare(find("whosPlayingCards"), "currentIndex", 0, 2000, "the DualSense moved it")
            keyClick(Qt.Key_Escape)                                 // Back: Not now
            tryVerify(() => prompt().shown && prompt().pad === host.pro, 2000, "the next pad asks")
            tryVerify(() => Input.mockNavigator() === host.pro, 2000)
            verify(find("whosPlayingCards").activeFocus)
            // The asking pad disconnects: closed as Not now.
            Input.mockRemoveDevice(host.pro)
            tryVerify(() => !prompt().shown, 2000, "its pad is gone")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            tryVerify(() => Input.navigator === "", 2000, "the navigator is cleared")
        }

        function test_a_waiting_pad_that_disconnects_is_dropped() {
            signIn()
            askWith(host.dualSense)
            Input.mockPadButton(host.pro, "south")
            tryVerify(() => prompt().queue.length === 1, 2000)
            Input.mockRemoveDevice(host.pro)
            tryVerify(() => prompt().queue.length === 0, 2000, "dropped from the queue")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown, 2000)
            wait(100)
            verify(!prompt().shown, "nobody else asks")
        }

        // ---- step "pick" --------------------------------------------------------------------------------------

        function test_pick_focus_detail_line_and_badges() {
            signIn()
            Input.joinPlayer(host.pro, "p2")
            tryVerify(() => Input.players.length === 2, 2000, "Ada is player 2 on the Pro Controller")
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            compare(prompt().cards.map(p => p.id), ["p1", "p2", "p3"], "every kept profile, the guest-role p3 too (RUY-680)")
            tryVerify(() => list.activeFocus && list.currentIndex === 2, 2000, "the first profile without a pad: p3, the guest-role one")
            keyClick(Qt.Key_Down)
            verify(find("whosPlayingNotNow").activeFocus, "Down to Not now")
            compare(find("whosPlayingDetail").text, "")
            keyClick(Qt.Key_Up)
            verify(list.activeFocus, "Up to the cards")
            list.currentIndex = 0
            const detail = find("whosPlayingDetail")
            verify(detail.text.startsWith("Now on "), detail.text)
            verify(detail.text.endsWith(". Picking it moves Player One here."), detail.text)
            keyClick(Qt.Key_Right)
            compare(list.currentIndex, 1)
            verify(detail.text.endsWith(". Picking it moves Ada here."), detail.text)
            keyClick(Qt.Key_Right)
            compare(list.currentIndex, 2, "the guest-role profile")
            keyClick(Qt.Key_Right)
            compare(list.currentIndex, 3, "the Guest card")
            keyClick(Qt.Key_Right)
            compare(list.currentIndex, 3, "the last card stays")
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Down)
            verify(find("whosPlayingNotNow").activeFocus, "Down to Not now")
            compare(detail.text, "", "no card, no detail")
            keyClick(Qt.Key_Up)
            verify(list.activeFocus && list.currentIndex === 1, "Up back to the card it left")
            keyClick(Qt.Key_Left)
            compare(list.currentIndex, 0)
            keyClick(Qt.Key_Left)
            compare(list.currentIndex, 0, "the first card stays")
            // Badges: Player 1 and Player 2; the PIN badge stays.
            compare(badgeOn(0).visible, true)
            compare(badgeOn(0).text, "Player 1")
            compare(badgeOn(1).visible, true)
            compare(badgeOn(1).text, "Player 2")
            // Accept on a profile that plays opens Move (RUY-628, tst_whos_playing_pin.qml); Back returns.
            list.currentIndex = 0
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000)
            compare(prompt().step, "move")
            tryCompare(joinSpy, "count", 1, 2000, "only the test's own join (its answer comes a turn after the seat)")
            keyClick(Qt.Key_Escape)
            tryVerify(() => list.activeFocus, 2000)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown, 2000, "Back = Not now")
        }

        function test_a_free_card_has_no_badge_or_detail_and_a_pin_card_opens_join_or_switch() {
            signIn()
            // Ada signs in on the Xbox pad instead, so Player One (PIN) is free.
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => Input.mockServiceRoute() === "locked", 2000, "the service knows nobody is signed in")
            Input.mockPadButton(host.xbox, "dpad_left")
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => Input.players.length === 1 && Input.players[0].profile === "p2"
                      && Input.players[0].device_id === host.xbox, 2000, "the seats are Ada's")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            tryVerify(() => list.activeFocus, 2000)
            compare(list.currentIndex, 0, "Player One, the first profile without a pad")
            compare(badgeOn(0).visible, false, "a free profile has no Player badge")
            compare(find("whosPlayingDetail").text, "")
            keyClick(Qt.Key_Right)
            verify(find("whosPlayingDetail").text.endsWith("Picking it moves Ada here."), "Ada's own line")
            keyClick(Qt.Key_Left)
            compare(find("whosPlayingDetail").text, "")
            // A PIN profile opens Join or Switch like any free one; the PIN comes after (RUY-628).
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000, "a PIN card opens Join or Switch")
            compare(prompt().step, "confirm")
            compare(find("whosPlayingConfirmTitle").text, "Join in or switch to Player One?")
            compare(joinSpy.count, 0)
        }

        // ---- step "Join or Switch" ----------------------------------------------------------------------------

        function test_join_or_switch_back_returns_to_the_card() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Return)                                 // Ada
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            compare(prompt().step, "confirm")
            compare(find("whosPlayingConfirmTitle").text, "Join in or switch to Ada?")
            compare(find("whosPlayingConfirmDetail").text,
                    "Join: Ada plays alongside Player One. Switch: Ada becomes player 1, and Player One's games are paused and kept.")
            compare(tc.shell.hintList.map(h => h.text), ["Select", "Back"])
            keyClick(Qt.Key_Right)
            verify(find("whosPlayingSwitch").activeFocus, "Switch to the right")
            keyClick(Qt.Key_Left)
            verify(find("whosPlayingJoin").activeFocus)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("whosPlayingCards").activeFocus, 2000, "Back: step 1")
            compare(prompt().step, "pick")
            compare(find("whosPlayingCards").currentIndex, 1, "on that card")
            compare(tc.shell.hintList.map(h => h.text), ["Select", "Not now"])
            verify(prompt().shown)
        }

        function test_join_gives_join_player_with_the_pad_and_the_profile() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryCompare(joinSpy, "count", 1)
            compare(joinSpy.signalArguments[0][0], host.dualSense)
            compare(joinSpy.signalArguments[0][1], "p2")
            tryVerify(() => !prompt().shown, 2000, "closed on ok")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            tryVerify(() => Input.mockNavigator() === "", 2000)
            compare(Notifications.model.count, 0, "no joined toast")
        }

        // RUY-680: a kept profile with role "guest" (mock p3) is a person on this console: a card, and Join seats it.
        function test_a_guest_role_profile_is_a_card() {
            signIn()
            askWith(host.dualSense)
            compare(prompt().cards.map(p => p.id), ["p1", "p2", "p3"])
            const list = find("whosPlayingCards")
            list.currentIndex = 2
            keyClick(Qt.Key_Return)                                 // no PIN: Join or Switch
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryCompare(joinSpy, "count", 1)
            compare(joinSpy.signalArguments[0][0], host.dualSense)
            compare(joinSpy.signalArguments[0][1], "p3")
            tryVerify(() => !prompt().shown, 2000, "closed on ok")
        }

        function test_a_temporary_guest_is_not_a_card_of_its_own() {
            signIn()
            Profiles.createGuest()
            tryVerify(() => Profiles.guests.length === 1, 2000)
            askWith(host.dualSense)
            compare(prompt().cards.map(p => p.id), ["p1", "p2", "p3"], "the temporary guest is the Guest card's")
            compare(prompt().entries.length, 4)
        }

        function test_switch_locks_signs_in_and_then_joins() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => host.order.length === 3, 3000, "the Lock, the sign-in and the join")
            compare(host.order, ["active ", "active p2", "join " + host.dualSense + " p2 ok"])
            verify(!prompt().shown)
            tryVerify(() => Input.players.length === 1 && Input.players[0].profile === "p2"
                      && Input.players[0].device_id === host.dualSense, 2000, "the DualSense is the new player 1")
            tryVerify(() => find("homePlay").activeFocus, 2000)
        }

        // ---- a Switch that never gets its seat --------------------------------------------------------------

        // The asking pad goes during a Switch: the join cannot happen (refused, or given up before it), the toast
        // says so, and nothing keeps the prompt shut afterwards.
        function test_a_switch_whose_pad_goes_ends_cleanly_and_the_prompt_opens_again() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                                 // Switch
            verify(prompt().switching !== null)
            Input.mockRemoveDevice(host.dualSense)
            tryVerify(() => prompt().switching === null, 2000, "the Switch gave up")
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => Notifications.model.count === 1, 2000)
            compare(Notifications.model.get(0).text, "Ada could not join")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            tryVerify(() => Input.players.length === 1 && Input.players[0].profile === "p2", 2000)
            askWith(host.pro)                                       // nothing keeps it shut
        }

        // Another profile signs in before the Switch's seat came: the Switch gives up at once.
        function test_a_switch_overtaken_by_another_profile_gives_up() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            Input.mockFail(true)                                    // Ada's seat never comes
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            verify(prompt().switching !== null, "the Switch waits for Ada's seat")
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            verify(prompt().switching !== null, "a Lock alone is no answer")
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => prompt().switching === null, 1000, "gave up when Player One signed in")
            tryVerify(() => Notifications.model.count === 1, 2000)
            compare(Notifications.model.get(0).text, "Ada could not join")
            Input.mockFail(false)
        }

        function test_a_switch_with_no_seat_gives_up_after_its_timeout() {
            signIn()
            prompt().switchTimeoutMs = 300
            askWith(host.dualSense)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            Input.mockFail(true)                                    // the service answers nothing useful
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => prompt().switching === null, 3000, "the Switch gave up")
            tryVerify(() => Notifications.model.count === 1, 2000)
            compare(Notifications.model.get(0).text, "Ada could not join")
            compare(joinSpy.count, 0)
            Input.mockFail(false)
        }

        // ---- errors -------------------------------------------------------------------------------------------

        function test_a_refused_join_shows_the_toast_with_join_focused() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            Input.mockFailJoin("full")
            keyClick(Qt.Key_Return)
            tryCompare(joinSpy, "count", 1)
            compare(joinSpy.signalArguments[0][2], "full")
            tryVerify(() => Notifications.model.count === 1, 2000, "the toast")
            compare(Notifications.model.get(0).text, "Ada could not join")
            compare(Notifications.model.get(0).detail, "Try again.")
            compare(Notifications.model.get(0).kind, "error")
            verify(prompt().shown)
            compare(prompt().step, "confirm")
            verify(find("whosPlayingJoin").activeFocus, "Join has the focus")
            const toasts = find("toastLayer")
            verify(toasts.z > find("modalLayer").z, "the toast is drawn over the prompt")
            Input.mockFailJoin("")
            keyClick(Qt.Key_Return)
            tryVerify(() => !prompt().shown, 2000, "the next try joins")
        }

        function test_a_failed_call_is_refused_too() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            Input.mockFailJoin("failed")
            keyClick(Qt.Key_Return)
            tryVerify(() => Notifications.model.count === 1, 2000)
            verify(find("whosPlayingJoin").activeFocus)
        }

        function test_unavailable_profiles_show_the_waiting_text_with_not_now_focused() {
            signIn()
            Profiles.mockSetAvailable(false)
            askWith(host.dualSense)
            tryVerify(() => find("whosPlayingNotNow").activeFocus, 2000, "Not now has the focus")
            verify(find("whosPlayingWaiting").visible)
            compare(find("whosPlayingWaiting").text, "Waiting for the profiles service…")
            verify(!find("whosPlayingCards").visible)
            keyClick(Qt.Key_Up)
            verify(find("whosPlayingNotNow").activeFocus, "no cards to go up to")
            keyClick(Qt.Key_Return)
            tryVerify(() => !prompt().shown, 2000)
        }

        function test_a_refused_switch_leaves_the_picker_with_the_toast() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            Profiles.deleteProfile("p1", "1234", "p2")             // Ada is gone before the Switch reaches her
            tryVerify(() => Profiles.profiles.length === 2, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => Notifications.model.count === 1, 2000, "the toast")
            compare(Notifications.model.get(0).text, "Ada could not join")
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker stays up")
            verify(!prompt().shown)
        }

        // ---- no padless console (the seat gate is on) ---------------------------------------------------------

        function test_a_pad_joins_as_player_1_when_seat_1_has_no_pad() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            tc.shell.forceActiveFocus()
            tryVerify(() => find("profileList").activeFocus, 2000)
            tryVerify(() => Input.devices.length === 3, 2000)
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                                 // the keyboard signs Ada in
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => Input.players.length === 1 && Input.players[0].device_id === "", 2000, "seat 1 has no pad")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            tryVerify(() => list.activeFocus, 2000)
            compare(list.currentIndex, 1, "Ada, player 1 without a pad, has the focus first (one press back)")
            compare(find("whosPlayingDetail").text, "", "no pad to name, no Move (RUY-628)")
            compare(badgeOn(1).text, "Player 1")
            list.currentIndex = 1
            verify(list.activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(joinSpy, "count", 1)
            compare(joinSpy.signalArguments[0][1], "p2")
            tryVerify(() => !prompt().shown, 2000)
            tryVerify(() => Input.players[0].device_id === host.dualSense, 2000, "the DualSense is player 1")
            tryVerify(() => Input.mockNavigator() === "", 2000)
            Input.mockPadButton(host.dualSense, "dpad_right")
            tryVerify(() => find("homeDetails").activeFocus, 2000, "and it navigates")
        }

        // ---- a pad remembers its player (RUY-124) ----------------------------------------------------------

        // `who` plays on the DualSense, so the pad learns it as its owner (the seat may be given up again).
        function rememberOnDualSense(who) {
            Input.joinPlayer(host.dualSense, who)
            tryVerify(() => Input.devices.find(d => d.id === host.dualSense).owner === who, 2000, "the DualSense remembers " + who)
        }

        function test_a_pad_opens_on_its_owner() {
            signIn()
            // The owner arrives with the next device record (asynchronous in the mock as over D-Bus): wait for it.
            tryVerify(() => Input.devices.find(d => d.id === host.xbox).owner === "p1", 2000, "the sign-in taught the Xbox pad")
            // A third profile, so the owner is not also "the first profile without a pad" (Ada).
            const before = Profiles.profiles.length
            Profiles.createProfile("p1", "1234", "Cem", "standard", "")
            tryVerify(() => Profiles.profiles.length === before + 1, 2000, "Cem was created")
            const cem = Profiles.profiles.find(p => p.name === "Cem").id
            rememberOnDualSense(cem)
            Input.leavePlayer(2)
            tryVerify(() => Input.players.length === 1, 2000, "Cem left; the DualSense keeps Cem as its owner")
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            tryVerify(() => list.activeFocus, 2000)
            const cemIndex = prompt().cards.findIndex(p => p.id === cem)
            verify(cemIndex > prompt().cards.findIndex(p => p.id === "p2"), "Cem comes after Ada, the first without a pad")
            compare(list.currentIndex, cemIndex, "the owner's card, not Ada's")
            compare(prompt().step, "pick", "focus only: nothing joined by itself")
            tryCompare(joinSpy, "count", 1, 2000, "only the test's own join (its answer comes a turn after the seat)")
        }

        function test_an_owner_who_plays_elsewhere_is_focused_and_accept_means_move_and_the_pin_is_asked() {
            signIn()
            rememberOnDualSense("p1")
            Input.joinPlayer(host.xbox, "p1")                       // player 1 plays on the Xbox pad again
            tryVerify(() => Input.players[0].device_id === host.xbox, 2000)
            askWith(host.dualSense)
            const list = find("whosPlayingCards")
            tryVerify(() => list.activeFocus, 2000)
            compare(list.currentIndex, 0, "Player One, though Ada is the first profile without a pad")
            verify(find("whosPlayingDetail").text.endsWith(". Picking it moves Player One here."), find("whosPlayingDetail").text)
            keyClick(Qt.Key_Return)
            tryVerify(() => prompt().step === "move", 2000, "Accept means Move")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => prompt().step === "pin", 2000, "Player One has a PIN: it is asked")
        }

        function test_an_owner_that_is_no_card_falls_back_to_the_first_profile_without_a_pad() {
            signIn()
            rememberOnDualSense("p9")                               // deleted: no card
            Input.leavePlayer(2)
            tryVerify(() => Input.players.length === 1, 2000)
            askWith(host.dualSense)
            tryVerify(() => find("whosPlayingCards").activeFocus, 2000)
            compare(find("whosPlayingCards").currentIndex, 1, "Ada, the first profile without a pad")
        }

        // RUY-669: a deleted profile's pads read no owner, announced as DevicesChanged (inputd: one DeviceChanged each).
        function test_forgetting_a_profile_empties_the_owner_of_the_pads_that_remembered_it() {
            signIn()
            rememberOnDualSense("p9")
            tryVerify(() => Input.devices.find(d => d.id === host.xbox).owner === "p1", 2000)
            devicesSpy.clear()
            Input.forgetConsoleProfile("p9")
            tryVerify(() => Input.devices.find(d => d.id === host.dualSense).owner === "", 2000, "the DualSense forgot p9")
            verify(devicesSpy.count >= 1, "the change was announced")
            compare(Input.devices.find(d => d.id === host.xbox).owner, "p1", "another pad's owner stays")
        }

        // RUY-669: joining the profile that already holds the pad's seat changes nothing but the owner, which is announced.
        function test_the_same_again_join_teaches_the_pad_its_owner_and_announces_it() {
            signIn()
            rememberOnDualSense("p2")
            Input.forgetConsoleProfile("p2")                        // p2 keeps its seat on the DualSense, the pad forgets
            tryVerify(() => Input.devices.find(d => d.id === host.dualSense).owner === "", 2000)
            joinSpy.clear()
            devicesSpy.clear()
            Input.joinPlayer(host.dualSense, "p2")                  // the same again
            tryVerify(() => Input.devices.find(d => d.id === host.dualSense).owner === "p2", 2000, "the pad remembers p2 again")
            verify(devicesSpy.count >= 1, "and says so")
            compare(Input.players.length, 2, "no seat moved")
        }

        // ---- geometry at 1080p (u = 1) ------------------------------------------------------------------------

        function test_geometry() {
            signIn()
            const run = playRacer()
            askWith(host.dualSense)
            const u = tc.shell.u
            const pill = find("whosPlayingPausedPill")
            compare(pill.height, 80 * u)
            compare(pill.x, tc.shell.marginX)
            compare(pill.y, tc.shell.marginY)
            const list = find("whosPlayingCards")
            const a = list.itemAtIndex(0)
            const b = list.itemAtIndex(1)
            fuzzyCompare(b.x - (a.x + a.width), Theme.spaceXl * u, 0.5, "cards 48 u apart (unscaled, in the list)")
            const title = find("whosPlayingTitle")
            const titleBottom = title.mapToItem(tc.shell, 0, title.height).y
            const slot = find("whosPlayingCardSlot")
            fuzzyCompare(slot.mapToItem(tc.shell, 0, 0).y - titleBottom, Theme.spaceXxl * u, 0.5, "64 u under the title")
            compare(slot.height, Theme.cardProfileHeight * u)
            const detail = find("whosPlayingDetail")
            compare(detail.height, 36 * u, "the detail line is 36 u")
            fuzzyCompare(detail.mapToItem(tc.shell, 0, 0).y - slot.mapToItem(tc.shell, 0, slot.height).y, Theme.spaceL * u, 0.5,
                         "the detail line spaceL under the cards: " + detail.mapToItem(tc.shell, 0, 0).y + " " + slot.mapToItem(tc.shell, 0, slot.height).y)
            const notNow = find("whosPlayingNotNow")
            fuzzyCompare(notNow.mapToItem(tc.shell, 0, 0).y - detail.mapToItem(tc.shell, 0, detail.height).y, 36 * u, 0.5,
                    "Not now 36 u below")
            compare(notNow.height, Theme.rowHeight * u)
            verify(notNow.width >= 300 * u)
            verify(find("whosPlayingBlur") !== null)
            compare(find("whosPlayingScrim").color, Theme.scrim)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            compare(find("whosPlayingJoin").height, Theme.buttonHeight * u)
            verify(find("whosPlayingJoin").width >= 300 * u)
            compare(find("whosPlayingConfirmAvatar").width, 120 * u)
            verify(find("whosPlayingConfirmPanel").width <= 1300 * u)
        }

        // ---- screenshots --------------------------------------------------------------------------------------

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            for (const lang of ["en", "tr"]) {
                for (const size of [[1920, 1080, "1080"], [1280, 720, "720"]]) {
                    init()
                    DeviceSettings.language = lang
                    signIn(size[0], size[1])
                    const tag = "whos-playing-" + lang + "-" + size[2]
                    askWith(host.dualSense)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-home.png")
                    keyClick(Qt.Key_Return)
                    tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
                    wait(400)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-join.png")
                    Input.mockFailJoin("full")
                    keyClick(Qt.Key_Return)
                    tryVerify(() => Notifications.model.count === 1, 2000)
                    wait(600)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-toast.png")
                    Input.mockFailJoin("")
                    keyClick(Qt.Key_Escape)
                    tryVerify(() => find("whosPlayingCards").activeFocus, 2000)
                    while (Notifications.model.count > 0)
                        Notifications.dismiss(Notifications.model.get(0).toastId)
                    // The join's toast has left the screen (its remove transition too) before the Move shot.
                    tryVerify(() => find("toastList").contentItem.children.every(c => !c.visible || c.opacity === 0), 3000,
                              "no toast on screen")
                    // Move (RUY-628): Player One plays on the Xbox pad; then the PIN with the pad line, a wrong PIN.
                    keyClick(Qt.Key_Left)
                    keyClick(Qt.Key_Return)
                    tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000)
                    wait(600)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-move.png")
                    keyClick(Qt.Key_Right)
                    keyClick(Qt.Key_Return)
                    const pinPad = find("whosPlayingPin")
                    tryVerify(() => pinPad.shown && findChild(pinPad, "pinKeys").activeFocus, 2000)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-pin.png")
                    keyClick(Qt.Key_1)                          // digits typed: Back deletes (RUY-662)
                    keyClick(Qt.Key_2)
                    wait(300)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-pindigits.png")
                    keyClick(Qt.Key_Backspace)
                    keyClick(Qt.Key_Backspace)
                    for (let i = 0; i < 4; ++i)
                        keyClick(Qt.Key_0)
                    keyClick(Qt.Key_Enter)
                    tryVerify(() => findChild(pinPad, "pinMessage").text !== "", 2000)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-wrongpin.png")
                    keyClick(Qt.Key_Escape)                     // the empty pad: back to Move
                    tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000)
                    keyClick(Qt.Key_Escape)
                    tryVerify(() => find("whosPlayingCards").activeFocus, 2000)
                    keyClick(Qt.Key_Escape)
                    tryVerify(() => !tc.shell || !find("whosPlaying").shown, 2000)
                    playRacer()
                    askWith(host.pro)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-game.png")
                    keyClick(Qt.Key_Escape)
                    tryVerify(() => !find("whosPlaying").shown, 2000)
                    Profiles.mockSetAvailable(false)
                    keyClick(Qt.Key_HomePage)
                    tryVerify(() => find("systemPanel").open, 2000)
                    Input.mockPadButton(host.dualSense, "guide")
                    tryVerify(() => find("whosPlaying").shown, 2000)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-waiting.png")
                    Profiles.mockSetAvailable(true)
                    tc.shell.destroy()
                    wait(50)
                }
            }
        }
    }
}
