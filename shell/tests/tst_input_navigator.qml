import QtQuick
import QtTest
import RuyaShell

// Who drives the UI (RUY-38, ADR-017 points 2 and 9, 06 §11.3), through the Shell and the mock
// service, which keeps ruya-inputd's rule (routing.rs `navigates`): before a sign-in every pad
// navigates; after it only player 1's pad (the one that signed in) does, another pad's press or Guide
// is a ForeignInput and moves nothing; Input.setNavigator gives one pad the UI (the pad of "Who's
// playing?", RUY-122) and player 1's pad does nothing meanwhile, Guide included. Player 1's pad lost
// over a game (its seat held, RUY-627) opens the Hub, which pauses the game; the pad back drives it
// and Accept on the game card resumes. Over Home nothing opens. Pads are driven with
// Input.mockPadButton (the service's keys on "RuyaOS Navigation"), the keyboard with keyClick.
Item {
    id: host
    width: 1280
    height: 720

    readonly property string dualSense: "bluetooth-054c-0ce6-3f2a9c41d0b7"
    readonly property string xbox: "usb-045e-0b12-8e01c2d4a9f3"

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
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }
    SignalSpy { id: foreignSpy; target: Input; signalName: "foreignInput" }
    SignalSpy { id: navigatorSpy; target: Input; signalName: "navigatorFinished" }

    TestCase {
        id: tc
        name: "InputNavigator"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.pauseGamesInHub = true
            Library.resetMockForTests("")
            Session.mockReset()
            Input.mockFail(false)
            Input.mockSeatHoldMs(60000)
            Input.mockResetDevices()
            launchedSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            Input.mockSeatHoldMs(60000)
            Input.mockResetDevices()
        }

        // The Xbox pad (player 1) signs Ada (p2) in from the picker: before a sign-in every pad navigates.
        function signInWithXbox() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has the focus")
            tryVerify(() => Input.devices.length === 3, 2000, "the mock's three pads are listed")
            for (let i = 0; i < 3; ++i)
                Input.mockPadButton(host.xbox, "dpad_left")      // the first profile, whichever the picker kept
            Input.mockPadButton(host.dualSense, "dpad_right")   // any pad moves the picker
            compare(find("profileList").currentIndex, 1, "the DualSense moved the picker before the sign-in")
            Input.mockPadButton(host.xbox, "south")             // Accept: Ada has no PIN
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => Input.players.length === 1 && Input.players[0].device_id === host.xbox, 2000,
                      "player 1 is on the pad that signed in")
            tryVerify(() => Library.available)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            foreignSpy.clear()
            navigatorSpy.clear()
        }

        function setNavigator(deviceId, status) {
            const before = navigatorSpy.count
            Input.setNavigator(deviceId)
            tryVerify(() => navigatorSpy.count === before + 1, 2000, "SetNavigator answered")
            compare(navigatorSpy.signalArguments[before][0], deviceId)
            compare(navigatorSpy.signalArguments[before][1], status)
        }

        function foreignOf(deviceId) {
            const out = []
            for (let i = 0; i < foreignSpy.count; ++i) {
                if (foreignSpy.signalArguments[i][0] === deviceId)
                    out.push(foreignSpy.signalArguments[i][1])
            }
            return out
        }

        function recordOf(instance) {
            return Session.running.find(r => r.instance === instance)
        }

        // Player 1's pad presses Play on the hero: the app runs and takes the focus.
        function playRacer() {
            Input.mockPadButton(host.xbox, "south")
            tryCompare(launchedSpy, "count", 1)
            const instance = launchedSpy.signalArguments[0][3]
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            const app = createTemporaryObject(appComponent, host)
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")
            return { app: app, instance: instance }
        }

        // ---- who navigates -----------------------------------------------------------------------------------

        function test_after_the_sign_in_another_pad_asks_and_moves_nothing() {
            signInWithXbox()
            const play = find("homePlay")
            Input.mockPadButton(host.dualSense, "dpad_right")
            tryVerify(() => foreignOf(host.dualSense).length === 1, 2000, "the DualSense asked")
            compare(foreignOf(host.dualSense), ["press"])
            verify(play.activeFocus, "nothing moved")
            verify(!find("homeDetails").activeFocus)
            Input.mockPadButton(host.dualSense, "south")        // within a second: not asked again
            Input.mockPadButton(host.dualSense, "guide")
            tryVerify(() => foreignOf(host.dualSense).length === 2, 2000)
            compare(foreignOf(host.dualSense), ["press", "guide"])
            verify(!find("systemPanel").open, "its Guide opens no Hub")
            verify(play.activeFocus)
            // Player 1's pad navigates and asks nothing.
            Input.mockPadButton(host.xbox, "dpad_right")
            tryVerify(() => find("homeDetails").activeFocus, 2000, "player 1's pad moved the focus")
            Input.mockPadButton(host.xbox, "dpad_left")
            tryVerify(() => play.activeFocus, 2000, "and back")
            compare(foreignOf(host.xbox), [])
        }

        function test_the_navigator_drives_the_ui_and_player_1_does_nothing() {
            signInWithXbox()
            const play = find("homePlay")
            setNavigator(host.dualSense, "ok")
            compare(Input.navigator, host.dualSense)
            tryCompare(Input, "activeDevice", host.dualSense)       // its glyphs at once
            compare(Input.activeFamily, "playstation")
            Input.mockPadButton(host.dualSense, "dpad_right")
            tryVerify(() => find("homeDetails").activeFocus, 2000, "the navigator moved the focus")
            Input.mockPadButton(host.xbox, "dpad_left")
            wait(50)
            verify(find("homeDetails").activeFocus, "player 1's pad does nothing")
            Input.mockPadButton(host.xbox, "guide")
            wait(50)
            verify(!find("systemPanel").open, "not even Guide")
            compare(foreignOf(host.xbox), [], "player 1's pad asks for nothing")
            Input.mockPadButton(host.dualSense, "dpad_left")
            tryVerify(() => play.activeFocus, 2000, "the navigator moves it back")
            // The keyboard always navigates.
            keyClick(Qt.Key_Right)
            tryVerify(() => find("homeDetails").activeFocus, 2000, "the keyboard moved it")
            keyClick(Qt.Key_Left)
            tryVerify(() => play.activeFocus, 2000)
            // Cleared: player 1's pad again, the DualSense asks again.
            setNavigator("", "ok")
            compare(Input.navigator, "")
            Input.mockPadButton(host.xbox, "dpad_right")
            tryVerify(() => find("homeDetails").activeFocus, 2000, "player 1 navigates again")
            Input.mockPadButton(host.dualSense, "dpad_left")
            wait(50)
            verify(find("homeDetails").activeFocus, "the DualSense does not")
            Input.mockPadButton(host.xbox, "dpad_left")
            tryVerify(() => play.activeFocus, 2000)
        }

        function test_set_navigator_refusals_and_its_pad_going() {
            signInWithXbox()
            setNavigator("usb-0000-0000-gone", "unknown-device")
            compare(Input.navigator, "", "a refused navigator is not kept")
            setNavigator(host.dualSense, "ok")
            Input.mockRemoveDevice(host.dualSense)
            tryCompare(Input, "navigator", "", 2000, "the navigator goes with its pad")
            compare(Input.mockNavigator(), "")
            const play = find("homePlay")
            Input.mockPadButton(host.xbox, "dpad_right")
            tryVerify(() => find("homeDetails").activeFocus, 2000, "player 1 navigates again")
            Input.mockPadButton(host.xbox, "dpad_left")
            tryVerify(() => play.activeFocus, 2000)
            // Nobody signed in: not allowed (the picker is everyone's).
            Profiles.lock()
            tryCompare(Input, "profile", "")
            tryCompare(Input, "status", "ok")
            setNavigator(host.xbox, "not-allowed")
        }

        function test_a_profile_change_drops_the_navigator() {
            signInWithXbox()
            setNavigator(host.dualSense, "ok")
            Profiles.lock()
            tryCompare(Input, "navigator", "", 2000)
            tryCompare(Input, "profile", "")
            compare(Input.mockNavigator(), "")
        }

        function test_a_players_guide_is_player_guide_and_shows_nothing() {
            signInWithXbox()
            const before = foreignSpy.count
            Input.joinPlayer(host.dualSense, "p1")
            tryVerify(() => Input.players.length === 2, 2000, "the DualSense is player 2")
            Input.mockPadButton(host.dualSense, "south")
            Input.mockPadButton(host.dualSense, "guide")
            tryVerify(() => foreignSpy.count === before + 1, 2000)
            compare(foreignOf(host.dualSense), ["player-guide"], "a seated pad's press asks for nothing")
            verify(!find("systemPanel").open)
            verify(find("homePlay").activeFocus)
        }

        // A restarted service knows no navigator: the shell sets it again after the players, and that
        // answer is nobody's (no navigatorFinished).
        function test_the_navigator_is_set_again_after_a_restart() {
            signInWithXbox()
            setNavigator(host.dualSense, "ok")
            const answers = navigatorSpy.count
            Input.mockRestart()
            tryVerify(() => Input.mockNavigator() === host.dualSense, 3000, "the navigator is set again")
            compare(Input.navigator, host.dualSense)
            tryVerify(() => Input.mockPlayers().length === 1 && Input.mockPlayers()[0].device_id === host.xbox, 2000)
            wait(50)
            compare(navigatorSpy.count, answers, "the replay is not announced")
        }

        // ---- player 1's pad lost over a game ---------------------------------------------------------------------

        function test_player_1s_pad_lost_over_a_game_opens_the_hub_and_its_return_resumes() {
            signInWithXbox()
            const run = playRacer()
            // A copy: a list element read from a property follows the list, which loses the pad below.
            const record = JSON.parse(JSON.stringify(Input.devices.find(d => d.id === host.xbox)))
            compare(record.id, host.xbox)
            Input.mockRemoveDevice(host.xbox)
            tryVerify(() => find("systemPanel").open && find("systemActions").activeFocus, 2000, "the Hub opens")
            verify(find("quickMenuItem_resume").focused, "the focus is on the game card")
            tryVerify(() => recordOf(run.instance).frozen === true, 2000, "the Hub's pause froze the game")
            compare(Session.mockCalls(), ["freeze " + run.instance])
            // The keyboard navigates meanwhile; no other pad does.
            keyClick(Qt.Key_Down)
            verify(!find("quickMenuItem_resume").focused)
            keyClick(Qt.Key_Up)
            verify(find("quickMenuItem_resume").focused)
            Input.mockPadButton(host.dualSense, "south")
            wait(50)
            verify(find("systemPanel").open, "an unseated pad does not resume")
            // The pad is back within the hold: it drives the Hub, Accept on the game card resumes.
            Input.mockAddDevice(record)
            tryVerify(() => Input.players.length === 1 && Input.players[0].held === false, 2000, "the seat is the pad's again")
            Input.mockPadButton(host.xbox, "south")
            tryVerify(() => run.app.activeFocus && !find("systemPanel").open, 2000, "Accept resumes the game")
            tryVerify(() => Session.mockCalls().length === 2, 2000, "the Thaw reached the game")
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance])
            compare(run.app.keysSeen, 0, "the game saw none of it")
        }

        function test_back_leaves_the_hub_the_lost_pad_opened() {
            signInWithXbox()
            const run = playRacer()
            Input.mockRemoveDevice(host.xbox)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
            verify(find("quickMenuItem_resume").focused)
            keyClick(Qt.Key_Escape)
            tryVerify(() => run.app.activeFocus && !find("systemPanel").open, 2000, "Back resumes the game")
        }

        // ---- the interim fallback while the seat gate is off (until RUY-122) ------------------------------

        // A keyboard sign-in: Ada (p2) from the picker, seat 1 has no pad.
        function signInWithKeyboard() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has the focus")
            tryVerify(() => Input.devices.length === 3, 2000)
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => Input.players.length === 1 && Input.players[0].device_id === "", 2000, "seat 1 has no pad")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            foreignSpy.clear()
        }

        // Gate off: player 1's pad does not come back within the hold, so the Hub it opened would freeze
        // the game for good without a keyboard: the first pad that presses is player 1 and resumes it.
        function test_gate_off_after_the_hold_another_pad_takes_seat_1_and_resumes_the_game() {
            signInWithXbox()
            const run = playRacer()
            Input.mockSeatHoldMs(300)
            Input.mockRemoveDevice(host.xbox)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
            tryVerify(() => recordOf(run.instance).frozen === true, 2000)
            Input.mockPadButton(host.dualSense, "south")
            wait(50)
            verify(find("systemPanel").open, "while the hold runs nothing changes")
            tryVerify(() => Input.players.length === 1 && Input.players[0].device_id === "", 3000, "the hold ran out")
            Input.mockPadButton(host.dualSense, "south")
            tryVerify(() => run.app.activeFocus && !find("systemPanel").open, 2000, "the DualSense resumes the game")
            tryVerify(() => Session.mockCalls().length === 2, 2000)
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance])
            tryVerify(() => Input.players[0].device_id === host.dualSense, 2000, "the DualSense is player 1")
        }

        function test_gate_off_a_keyboard_sign_in_then_a_pad_press_takes_seat_1() {
            signInWithKeyboard()
            Input.mockPadButton(host.dualSense, "dpad_right")
            tryVerify(() => find("homeDetails").activeFocus, 2000, "its first press navigates")
            tryVerify(() => Input.players[0].device_id === host.dualSense, 2000, "it is player 1")
            compare(foreignOf(host.dualSense), [])
            Input.mockPadButton(host.xbox, "dpad_left")
            wait(50)
            verify(find("homeDetails").activeFocus, "the next pad is not player 1")
        }

        // Gate on (RUY-122): the prompt's Move is the path; a press takes no seat.
        function test_gate_on_no_pad_takes_a_padless_seat_1() {
            Input.mockSeatGate(true)
            signInWithKeyboard()
            Input.mockPadButton(host.dualSense, "dpad_right")
            tryVerify(() => foreignOf(host.dualSense).length === 1, 2000)
            compare(foreignOf(host.dualSense), ["press"])
            verify(find("homePlay").activeFocus, "nothing moved")
            compare(Input.players[0].device_id, "")
        }

        function test_over_home_a_lost_pad_opens_nothing() {
            signInWithXbox()
            Input.mockRemoveDevice(host.xbox)
            tryVerify(() => Input.players.length === 1 && Input.players[0].held === true, 2000, "seat 1 is held")
            wait(50)
            verify(!find("systemPanel").open, "no Hub over Home")
            verify(find("homePlay").activeFocus, "the focus stays")
            compare(Notifications.model.count, 0, "and no toast")
        }
    }
}
