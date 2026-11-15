import QtQuick
import QtTest
import RuyaShell

// "Who's playing?" on a wake from sleep (RUY-707, ADR-017 amendment 7, 02 §1.9 "Wake"): a resume
// (IdleClock's test path: the fake `slept` jumps, then `evaluate()`) while seat 1 has no connected pad
// opens the Pick step in wake mode: the signed-in profile's card first and focused ("Continue as Ada."),
// the others as Switches, no Guest and no Not now; Accept on Ada, Back and Guide continue (no PIN; a pad
// that answers is seated as player 1); another profile is a Switch, through its PIN. The keyboard drives
// it until a pad connects or presses; that pad takes it over with the focus where it was. Through the
// Shell and the mock services: Ada (p2, no PIN) is signed in, Player One (p1) has PIN 1234, Sam (p3) none.
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
            Keys.onReleased: event => { keysSeen++; event.accepted = true }
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }
    SignalSpy { id: joinSpy; target: Input; signalName: "joinFinished" }
    SignalSpy { id: verifySpy; target: Profiles; signalName: "pinVerified" }

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
        name: "WhosPlayingWake"
        when: windowShown

        property Shell shell: null
        property double t: 1000000000000   // the fake monotonic clock, ms (IdleClock.now)
        property double slept: 0              // the fake "total ms suspended" (IdleClock.slept)
        property var defaultNow: null
        property var defaultSlept: null

        function find(name) { return findChild(tc.shell, name) }
        function prompt() { return find("whosPlaying") }
        function cardList() { return find("whosPlayingCards") }
        function pin() { return find("whosPlayingPin") }

        function initTestCase() {
            tc.defaultNow = IdleClock.now
            tc.defaultSlept = IdleClock.slept
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.language = "en"
            DeviceSettings.reducedMotion = false
            DeviceSettings.pauseGamesInHub = true
            DeviceSettings.saverMinutes = 10
            Library.resetMockForTests("")
            Session.mockReset()
            Profiles.resetMockForTests("seeded")
            Profiles.mockSetAvailable(true)
            Input.mockFail(false)
            Input.mockFailJoin("")
            Input.mockSeatHoldMs(60000)
            Input.mockResetDevices()
            tc.t = 1000000000000
            tc.slept = 0
            IdleClock.now = () => tc.t
            IdleClock.slept = () => tc.slept
            IdleClock.reset()
            launchedSpy.clear()
            joinSpy.clear()
            verifySpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            DeviceSettings.language = "en"
            DeviceSettings.saverMinutes = 10
            IdleClock.now = tc.defaultNow
            IdleClock.slept = tc.defaultSlept
            IdleClock.reset()
            Input.mockFailJoin("")
            Input.mockSeatHoldMs(60000)
            Input.mockResetDevices()
        }

        function startShell(w, h) {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host, { width: w ?? 1920, height: h ?? 1080 })
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has the focus")
            tryVerify(() => Input.devices.length === 3, 2000, "the mock's three pads are listed")
        }

        // The keyboard signs Ada in from the picker: seat 1 has no pad.
        function signInAdaWithKeyboard(w, h) {
            startShell(w, h)
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => Input.players.length === 1 && Input.players[0].device_id === "", 2000, "seat 1 has no pad")
            tryVerify(() => Library.available)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            verify(!prompt().shown)
            settle()
        }

        // The Xbox pad signs Ada in: player 1 on a connected pad.
        function signInAdaWithXbox() {
            startShell()
            Input.mockPadButton(host.xbox, "dpad_left")
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => Input.players.length === 1 && Input.players[0].device_id === host.xbox, 2000,
                      "player 1 is on the Xbox pad")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            verify(!prompt().shown)
            settle()
        }

        // The Xbox pad (Ada's) goes during the sleep: seat 1 is held for a pad that is not there.
        function xboxGone() {
            // A copy: an element of the list property would read the list again (another pad after the removal).
            const record = JSON.parse(JSON.stringify(Input.devices.find(d => d.id === host.xbox)))
            Input.mockRemoveDevice(host.xbox)
            tryVerify(() => Input.players.length === 1 && Input.players[0].held === true
                      && !Input.devices.some(d => d.id === host.xbox), 2000, "seat 1 is held, its pad gone")
            verify(!prompt().shown, "a lost pad over Home opens nothing by itself")
            return record
        }

        function settle() {
            joinSpy.clear()
            verifySpy.clear()
            host.order = []
        }

        // The machine slept for an hour and runs again: IdleClock's resume (the monotonic clock did not move).
        function resume() {
            tc.slept += 3600 * 1000
            IdleClock.evaluate()
        }

        function wakeShown() {
            return prompt().shown && prompt().wakeMode && cardList().activeFocus
        }

        function recordOf(instance) {
            return Session.running.find(r => r.instance === instance)
        }

        // Ada (keyboard) presses Play on the hero: the app runs and takes the focus.
        function playRacer() {
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            const instance = launchedSpy.signalArguments[0][3]
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            const app = createTemporaryObject(appComponent, host)
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")
            tryVerify(() => Input.mockServiceRoute() === "app", 2000)
            compare(Session.mockCalls(), [], "nothing frozen yet")
            return { app: app, instance: instance }
        }

        // A pad presses until the prompt has made it its navigator (the service sends one ForeignInput
        // "press" a second at most).
        function padTakesOver(deviceId) {
            tryVerify(() => {
                if (prompt().pad === deviceId)
                    return true
                Input.mockPadButton(deviceId, "dpad_up")   // a press that does nothing once it navigates
                return false
            }, 3000, deviceId + " drives the wake step")
            tryVerify(() => Input.mockNavigator() === deviceId, 2000, "the pad is the navigator")
        }

        // The pad's name as the prompt shows it.
        function padNameOf(deviceId) {
            const d = Input.devices.find(x => x.id === deviceId)
            return Notifications.named(DeviceIcons.padName(d.id, d.name ?? "", d.family ?? ""))
        }

        function hintTexts() { return tc.shell.hintList.map(h => h.text) }
        function hintFamilies() { return tc.shell.hintList.map(h => h.family ?? "") }

        // ---- the trigger ---------------------------------------------------------------------------------

        function test_a_resume_with_no_pad_on_seat_1_opens_wake_mode_on_the_signed_in_card() {
            signInAdaWithKeyboard()
            resume()
            tryVerify(() => wakeShown(), 2000, "the wake step opens with the cards focused")
            compare(cardList().currentIndex, 0)
            compare(prompt().entries.map(e => e.id), ["p2", "p1", "p3"], "Ada first, then the picker's order")
            verify(prompt().entries.every(e => e.kind !== "guest"), "no Guest card")
            compare(cardList().count, 3)
            compare(find("whosPlayingDetail").text, "Continue as Ada.")
            verify(!find("whosPlayingNotNow").visible, "no Not now")
            compare(find("whosPlayingTitle").text, "Who's playing?")
            const padLine = find("whosPlayingPadLine")
            compare(padLine.label, "Turn on a controller to play")
            compare(padLine.icon, "sports_esports", "the generic pad")
            compare(prompt().pad, "", "no pad asks")
            compare(Input.mockNavigator(), "")
            compare(hintTexts(), ["Select", "Continue"])
            compare(hintFamilies(), ["keyboard", "keyboard"], "the keyboard's key caps: Enter, Esc")
            // The others are Switches; Down does nothing (no button under the cards); Right clamps.
            keyClick(Qt.Key_Right)
            compare(cardList().currentIndex, 1)
            compare(find("whosPlayingDetail").text, "Switches to Player One.")
            keyClick(Qt.Key_Down)
            verify(cardList().activeFocus, "Down stays on the cards")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(cardList().currentIndex, 2, "clamped on the last card, no Guest after it")
            compare(find("whosPlayingDetail").text, "Switches to Sam.")
        }

        function test_a_resume_with_the_pad_held_but_gone_opens_wake_mode_too() {
            signInAdaWithXbox()
            xboxGone()
            resume()
            tryVerify(() => wakeShown(), 2000)
            compare(cardList().currentIndex, 0)
            compare(find("whosPlayingDetail").text, "Continue as Ada.")
        }

        function test_a_resume_with_seat_1_pad_connected_opens_nothing() {
            signInAdaWithXbox()
            resume()
            wait(Theme.pageMs + 50)
            verify(!prompt().shown, "player 1's pad is there: Home as it was")
            verify(!prompt().wakePending)
            verify(find("homePlay").activeFocus)
        }

        function test_the_screen_saver_ending_opens_nothing() {
            signInAdaWithKeyboard()
            DeviceSettings.saverMinutes = 1
            tc.t += 40000
            IdleClock.evaluate()
            tc.t += 30000
            IdleClock.evaluate()
            compare(IdleClock.stage, "saver", "the saver is up")
            keyClick(Qt.Key_Right)                          // only wakes (eaten)
            compare(IdleClock.stage, "active")
            wait(Theme.pageMs + 50)
            verify(!prompt().shown, "the saver is not a sleep: nothing opens")
            verify(!prompt().wakePending)
        }

        function test_no_wake_on_the_picker() {
            startShell()
            resume()
            wait(Theme.pageMs + 50)
            verify(!prompt().shown, "nobody is signed in: the picker as it was")
            verify(find("profileList").activeFocus)
        }

        // ---- Continue ------------------------------------------------------------------------------------

        function test_accept_on_the_signed_in_card_with_the_keyboard_closes_and_seats_nothing() {
            signInAdaWithKeyboard()
            resume()
            tryVerify(() => wakeShown(), 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => !prompt().shown, 2000, "Continue closes it")
            tryVerify(() => find("homePlay").activeFocus, 2000, "the focus is back on Home")
            compare(Profiles.activeProfile, "p2", "the profile is unchanged")
            compare(joinSpy.count, 0, "no pad, so nothing joins")
            compare(Input.players.length, 1)
            compare(Input.players[0].device_id, "", "seat 1 stays padless")
            compare(host.order, [])
        }

        function test_accept_on_the_signed_in_card_seats_the_answering_pad_as_player_1() {
            signInAdaWithXbox()
            xboxGone()
            resume()
            tryVerify(() => wakeShown(), 2000)
            padTakesOver(host.dualSense)
            verify(prompt().shown && cardList().currentIndex === 0, "still on Ada's card")
            Input.mockPadButton(host.dualSense, "south")    // A: Continue
            tryCompare(joinSpy, "count", 1)
            compare(joinSpy.signalArguments[0][0], host.dualSense)
            compare(joinSpy.signalArguments[0][1], "p2")
            compare(joinSpy.signalArguments[0][2], "ok")
            compare(verifySpy.count, 0, "no PIN")
            tryVerify(() => !prompt().shown, 2000)
            compare(Profiles.activeProfile, "p2")
            tryVerify(() => Input.players.length === 1 && Input.players[0].device_id === host.dualSense
                      && Input.players[0].held !== true, 2000, "the DualSense is player 1")
            tryVerify(() => Input.mockNavigator() === "", 2000)
            tryVerify(() => find("homePlay").activeFocus, 2000)
        }

        // ---- Switch --------------------------------------------------------------------------------------

        function test_accept_on_another_profile_without_a_pin_switches_and_ada_s_game_is_frozen() {
            signInAdaWithKeyboard()
            const run = playRacer()
            resume()
            tryVerify(() => wakeShown(), 2000)
            tryVerify(() => recordOf(run.instance).frozen === true, 2000, "the game is paused behind it")
            padTakesOver(host.dualSense)
            Input.mockPadButton(host.dualSense, "dpad_right")
            Input.mockPadButton(host.dualSense, "dpad_right")
            tryCompare(cardList(), "currentIndex", 2)
            compare(find("whosPlayingDetail").text, "Switches to Sam. Ada's games are paused and kept.")
            Input.mockPadButton(host.dualSense, "south")
            tryVerify(() => host.order.length === 3, 3000, "the Lock, the sign-in and the join")
            compare(host.order, ["active ", "active p3", "join " + host.dualSense + " p3 ok"])
            verify(!prompt().shown)
            compare(verifySpy.count, 0, "Sam has no PIN")
            tryVerify(() => Input.players.length === 1 && Input.players[0].profile === "p3"
                      && Input.players[0].device_id === host.dualSense, 2000, "the DualSense is Sam's player 1")
            // As a Hub switch: the prompt's close thaws, the Lock freezes Ada's game again, and it is kept.
            tryVerify(() => recordOf(run.instance) !== undefined && recordOf(run.instance).frozen === true, 2000,
                      "Ada's game is frozen and kept")
            const calls = Session.mockCalls()
            compare(calls[calls.length - 1], "freeze " + run.instance)
        }

        function test_a_pin_profile_asks_its_pin_back_returns_to_its_card_and_a_right_pin_switches() {
            signInAdaWithKeyboard()
            resume()
            tryVerify(() => wakeShown(), 2000)
            keyClick(Qt.Key_Right)
            compare(cardList().currentIndex, 1, "Player One")
            keyClick(Qt.Key_Return)
            tryVerify(() => prompt().step === "pin" && pin().shown && findChild(pin(), "pinKeys").activeFocus, 2000,
                      "the PIN step")
            verify(!findChild(pin(), "pinPadLine").visible, "no pad: no pad line")
            compare(host.order, [], "nothing switched yet")
            keyClick(Qt.Key_Escape)                         // Back on the empty pad
            tryVerify(() => prompt().step === "pick" && cardList().activeFocus, 2000, "the wake step again")
            compare(cardList().currentIndex, 1, "on Player One's card")
            compare(find("whosPlayingDetail").text, "Switches to Player One.")
            verify(prompt().shown && prompt().wakeMode)
            keyClick(Qt.Key_Return)
            tryVerify(() => prompt().step === "pin" && findChild(pin(), "pinKeys").activeFocus, 2000)
            for (const ch of "1234")
                keyClick(Qt.Key_0 + Number(ch))
            keyClick(Qt.Key_Enter)
            tryVerify(() => host.order.length === 2, 3000, "the Lock and the sign-in")
            compare(host.order, ["active ", "active p1"])
            verify(!prompt().shown)
            tryVerify(() => prompt().switching === null, 2000, "the keyboard Switch has nobody to seat: it ends")
            wait(Theme.pageMs + 50)
            compare(joinSpy.count, 0, "no pad: no join")
        }

        // ---- Back and Guide -------------------------------------------------------------------------------

        function test_back_and_guide_continue_from_any_card() {
            signInAdaWithKeyboard()
            resume()
            tryVerify(() => wakeShown(), 2000)
            keyClick(Qt.Key_Right)
            compare(cardList().currentIndex, 1)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown, 2000, "Back on Player One's card continues as Ada")
            compare(Profiles.activeProfile, "p2")
            compare(host.order, [], "no Switch")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            resume()
            tryVerify(() => wakeShown(), 2000, "a second wake")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(cardList().currentIndex, 2)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => !prompt().shown, 2000, "Guide on Sam's card continues as Ada")
            compare(Profiles.activeProfile, "p2")
            verify(!find("systemPanel").open, "Guide did not open the Hub")
            compare(host.order, [])
            compare(joinSpy.count, 0)
        }

        function test_back_with_a_pad_continues_and_seats_it() {
            signInAdaWithKeyboard()
            resume()
            tryVerify(() => wakeShown(), 2000)
            padTakesOver(host.dualSense)
            Input.mockPadButton(host.dualSense, "dpad_right")
            tryCompare(cardList(), "currentIndex", 1)
            Input.mockPadButton(host.dualSense, "east")           // B on Player One's card
            tryCompare(joinSpy, "count", 1)
            compare(joinSpy.signalArguments[0][0], host.dualSense)
            compare(joinSpy.signalArguments[0][1], "p2", "Ada continues, on this pad")
            tryVerify(() => !prompt().shown, 2000)
            compare(Profiles.activeProfile, "p2")
            tryVerify(() => Input.players[0].device_id === host.dualSense, 2000, "the DualSense is player 1")
        }

        // ---- the pad that takes over -------------------------------------------------------------------------

        function test_a_pad_that_connects_takes_over_with_the_focus_unchanged_and_no_second_prompt() {
            signInAdaWithKeyboard()
            resume()
            tryVerify(() => wakeShown(), 2000)
            keyClick(Qt.Key_Right)
            compare(cardList().currentIndex, 1)
            Input.mockAddDevice({ id: host.extra, name: "8BitDo Pro 2", family: "generic" })
            tryVerify(() => prompt().pad === host.extra, 2000, "the new pad drives the wake step")
            tryVerify(() => Input.mockNavigator() === host.extra, 2000)
            verify(prompt().shown && prompt().wakeMode && prompt().step === "pick")
            verify(cardList().activeFocus, "the focus stays on the cards")
            compare(cardList().currentIndex, 1, "on the same card")
            compare(prompt().queue, [], "no second prompt waits for it")
            compare(find("whosPlayingPadLine").label, padNameOf(host.extra) + " wants to play")
            compare(hintTexts(), ["Select", "Continue"])
            compare(hintFamilies(), ["", ""], "the pad's own glyphs now")
            Input.mockPadButton(host.extra, "dpad_left")
            tryCompare(cardList(), "currentIndex", 0)
            Input.mockPadButton(host.extra, "south")
            tryVerify(() => !prompt().shown, 2000)
            tryVerify(() => Input.players[0].device_id === host.extra, 2000, "the new pad is player 1")
            wait(Theme.pageMs + 50)
            verify(!prompt().shown, "no prompt for the pad afterwards")
        }

        function test_seat_1_s_own_pad_coming_back_drives_the_step_which_stays_open() {
            signInAdaWithXbox()
            const record = xboxGone()
            resume()
            tryVerify(() => wakeShown(), 2000)
            keyClick(Qt.Key_Right)
            compare(cardList().currentIndex, 1)
            Input.mockAddDevice(record)                     // it rebinds into its held seat (RUY-627)
            tryVerify(() => Input.players[0].held !== true && Input.players[0].device_id === host.xbox, 2000,
                      "the Xbox pad is back in seat 1")
            tryVerify(() => prompt().pad === host.xbox, 2000, "it drives the wake step")
            tryVerify(() => Input.mockNavigator() === host.xbox, 2000)
            verify(prompt().shown && prompt().wakeMode, "the step stays open: another person may still take over")
            verify(cardList().activeFocus)
            compare(cardList().currentIndex, 1, "the focus stayed")
            compare(prompt().queue, [])
            Input.mockPadButton(host.xbox, "east")          // B: continue as Ada
            tryVerify(() => !prompt().shown, 2000)
            compare(Profiles.activeProfile, "p2")
            compare(Input.players[0].device_id, host.xbox)
        }

        function test_the_navigating_pad_going_gives_the_step_back_to_the_keyboard() {
            signInAdaWithKeyboard()
            resume()
            tryVerify(() => wakeShown(), 2000)
            keyClick(Qt.Key_Right)
            Input.mockAddDevice({ id: host.extra, name: "8BitDo Pro 2", family: "generic" })
            tryVerify(() => prompt().pad === host.extra, 2000)
            Input.mockRemoveDevice(host.extra)
            tryVerify(() => prompt().pad === "", 2000, "the keyboard drives it again")
            verify(prompt().shown && prompt().wakeMode, "it stays open")
            verify(cardList().activeFocus)
            compare(cardList().currentIndex, 1, "on the same card")
            compare(find("whosPlayingPadLine").label, "Turn on a controller to play")
            compare(hintFamilies(), ["keyboard", "keyboard"])
            keyClick(Qt.Key_Escape)
            tryVerify(() => !prompt().shown, 2000)
            compare(Profiles.activeProfile, "p2")
            compare(joinSpy.count, 0)
        }

        function test_a_later_pad_queues_for_the_normal_prompt() {
            signInAdaWithKeyboard()
            resume()
            tryVerify(() => wakeShown(), 2000)
            padTakesOver(host.dualSense)
            Input.mockAddDevice({ id: host.extra, name: "8BitDo Pro 2", family: "generic" })
            tryVerify(() => prompt().queue.includes(host.extra), 2000, "the second pad waits")
            compare(prompt().pad, host.dualSense, "the first pad keeps the wake step")
            keyClick(Qt.Key_Return)                         // continue: the DualSense is player 1
            tryVerify(() => prompt().shown && !prompt().wakeMode && prompt().pad === host.extra, 3000,
                      "then the normal prompt for the second pad")
            verify(find("whosPlayingNotNow").visible, "the normal step has Not now")
            compare(prompt().entries[prompt().entries.length - 1].kind, "guest", "and the Guest card")
        }

        // ---- over a game ------------------------------------------------------------------------------------

        function test_over_a_game_it_pauses_and_continue_resumes() {
            signInAdaWithKeyboard()
            const run = playRacer()
            resume()
            tryVerify(() => wakeShown(), 2000)
            tryVerify(() => recordOf(run.instance).frozen === true, 2000, "the game is frozen")
            compare(Session.mockCalls(), ["freeze " + run.instance])
            tryVerify(() => Input.mockServiceRoute() === "overlay", 2000)
            tryVerify(() => find("whosPlayingPausedPill").visible, 2000, "the Paused pill")
            verify(!run.app.activeFocus)
            keyClick(Qt.Key_Return)                         // Continue as Ada
            tryVerify(() => !prompt().shown && run.app.activeFocus, 2000, "back in the game")
            tryVerify(() => Session.mockCalls().length === 2, 2000)
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance])
            tryVerify(() => Input.mockServiceRoute() === "app", 2000)
            compare(run.app.keysSeen, 0, "the game saw none of it")
        }

        // ---- geometry -----------------------------------------------------------------------------------------

        function test_geometry_the_column_ends_at_the_detail_line_and_is_centred() {
            signInAdaWithKeyboard()
            resume()
            tryVerify(() => wakeShown(), 2000)
            wait(Theme.pageMs + 50)
            const u = tc.shell.u
            const column = find("whosPlayingPick")
            const padLine = find("whosPlayingPadLine")
            const title = find("whosPlayingTitle")
            const detail = find("whosPlayingDetail")
            compare(detail.height, 36 * u)
            const expected = padLine.height + Theme.spaceM * u + title.height + Theme.spaceXxl * u
                             + Theme.cardProfileHeight * u + Theme.spaceL * u + Theme.spaceL * u
            fuzzyCompare(column.height, expected, 0.5, "pad line, title, cards, detail: no Not now")
            const top = column.mapToItem(tc.shell, 0, 0).y
            fuzzyCompare(top + column.height / 2, tc.shell.height / 2, 1, "re-centred")
            fuzzyCompare(detail.mapToItem(tc.shell, 0, detail.height).y, top + column.height, 0.5, "the detail line ends it")
            const list = cardList()
            const a = list.itemAtIndex(0)
            const b = list.itemAtIndex(1)
            fuzzyCompare(b.x - (a.x + a.width), Theme.spaceXl * u, 0.5, "cards 48 u apart")
        }

        // ---- screenshots ------------------------------------------------------------------------------------

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            for (const lang of ["en", "tr"]) {
                for (const size of [[1920, 1080, "1080"], [1280, 720, "720"]]) {
                    init()
                    DeviceSettings.language = lang
                    signInAdaWithKeyboard(size[0], size[1])
                    const tag = "whos-playing-wake-" + lang + "-" + size[2]
                    // Over Home, no pad yet (Wake-nopad).
                    resume()
                    tryVerify(() => wakeShown(), 2000)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-nopad.png")
                    keyClick(Qt.Key_Escape)
                    tryVerify(() => !prompt().shown && find("homePlay").activeFocus, 2000)
                    // Over a game: Continue (Wake-over-game), another profile (Wake-other), its PIN (Wake-pin).
                    playRacer()
                    resume()
                    tryVerify(() => wakeShown(), 2000)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-game.png")
                    keyClick(Qt.Key_Right)
                    wait(400)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-other.png")
                    keyClick(Qt.Key_Return)
                    tryVerify(() => prompt().step === "pin" && findChild(pin(), "pinKeys").activeFocus, 2000)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-pin.png")
                    keyClick(Qt.Key_Escape)
                    tryVerify(() => prompt().step === "pick" && cardList().activeFocus, 2000)
                    keyClick(Qt.Key_Left)
                    // A pad turns on and drives it (Wake-continue).
                    padTakesOver(host.dualSense)
                    wait(500)
                    grabImage(tc.shell).save(shotsDir + "/" + tag + "-continue.png")
                    tc.shell.destroy()
                    wait(50)
                }
            }
        }
    }
}
