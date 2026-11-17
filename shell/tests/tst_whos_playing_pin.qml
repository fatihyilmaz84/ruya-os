import QtQuick
import QtTest
import RuyaShell

// "Who's playing?", part 2 (RUY-628, 02 §1.9): Move a profile that plays now to the asking pad (Cancel
// first), and the PIN on the TV (PinPad's player mode: Profiles.verifyPin, never a sign-in) for Join,
// Switch and Move, typed with the asking pad (the navigator) or the keyboard; Back on an empty pad returns
// to the step before; a padless player 1 skips Move; a seated pad's Guide asks while seat 1 has no pad.
// Through the Shell and the mock services: Player One (p1) has PIN 1234, Ada (p2) none. Its own file: the
// wrong PINs count towards the mock's lockout (reset by every init()).
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
    SignalSpy { id: verifySpy; target: Profiles; signalName: "pinVerified" }
    SignalSpy { id: switchSpy; target: Profiles; signalName: "switchFinished" }
    SignalSpy { id: foreignSpy; target: Input; signalName: "foreignInput" }

    // The order of a Switch: the Lock and the sign-in (activeProfile) and then the join.
    property var order: []
    // Which Move button had the focus when the last JoinPlayer answered.
    property string focusAtJoin: ""
    Connections {
        target: Profiles
        function onActiveProfileChanged() { host.order = host.order.concat(["active " + Profiles.activeProfile]) }
    }
    Connections {
        target: Input
        function onJoinFinished(deviceId, profile, status, slot) {
            host.order = host.order.concat(["join " + deviceId + " " + profile + " " + status])
            // Connected before any Shell exists, so this runs before the prompt reacts to the answer.
            if (!tc.shell)
                return
            const move = tc.findChild(tc.shell, "whosPlayingMove")
            const cancel = tc.findChild(tc.shell, "whosPlayingMoveCancel")
            host.focusAtJoin = move && move.activeFocus ? "move" : cancel && cancel.activeFocus ? "cancel" : "other"
        }
    }

    TestCase {
        id: tc
        name: "WhosPlayingPin"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        function prompt() { return find("whosPlaying") }
        function pin() { return find("whosPlayingPin") }
        // The prompt's own PIN pad (the picker has another one).
        function pinChild(name) { return findChild(pin(), name) }

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
            verifySpy.clear()
            switchSpy.clear()
            foreignSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            DeviceSettings.language = "en"
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

        // A pad signs `id` in: it is player 1.
        function signInWith(deviceId, id, pinText, w, h) {
            startShell(w, h)
            Input.mockPadButton(deviceId, "dpad_left")
            Profiles.switchTo(id, pinText)
            tryCompare(Profiles, "activeProfile", id)
            tryVerify(() => Input.players.length === 1 && Input.players[0].profile === id
                      && Input.players[0].device_id === deviceId, 2000, "player 1 is on " + deviceId)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            verify(!prompt().shown)
            joinSpy.clear()
            verifySpy.clear()
            switchSpy.clear()
            host.order = []
        }
        // Player One (PIN) on the Xbox pad.
        function signIn(w, h) { signInWith(host.xbox, "p1", "1234", w, h) }
        // Ada (no PIN) on the Xbox pad: Player One is free.
        function signInAda() { signInWith(host.xbox, "p2", "") }

        // The keyboard signs Ada in from the picker: seat 1 has no pad.
        function signInAdaWithKeyboard() {
            startShell()
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => Input.players.length === 1 && Input.players[0].device_id === "", 2000, "seat 1 has no pad")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            joinSpy.clear()
            verifySpy.clear()
            foreignSpy.clear()
        }

        function askWith(deviceId) {
            Input.mockPadButton(deviceId, "south")
            tryVerify(() => prompt().shown && prompt().pad === deviceId, 2000, "the prompt opens for " + deviceId)
            tryVerify(() => Input.mockNavigator() === deviceId, 2000, "the asking pad navigates")
        }

        // The pad's name as the prompt shows it.
        function padNameOf(deviceId) {
            const d = Input.devices.find(x => x.id === deviceId)
            return Notifications.named(DeviceIcons.padName(d.id, d.name ?? "", d.family ?? ""))
        }

        // The asking pad types `digits` on the keypad (D-pad and A), then presses Start (submit).
        function padTypes(deviceId, digits) {
            const keys = pinChild("pinKeys")
            for (const ch of digits) {
                const target = ch === "0" ? 10 : Number(ch) - 1
                while (keys.currentIndex % 3 < target % 3)
                    Input.mockPadButton(deviceId, "dpad_right")
                while (keys.currentIndex % 3 > target % 3)
                    Input.mockPadButton(deviceId, "dpad_left")
                while (keys.currentIndex < target)
                    Input.mockPadButton(deviceId, "dpad_down")
                while (keys.currentIndex > target)
                    Input.mockPadButton(deviceId, "dpad_up")
                compare(keys.currentIndex, target)
                Input.mockPadButton(deviceId, "south")
            }
            Input.mockPadButton(deviceId, "start")
        }
        // The keyboard types a PIN and Enter.
        function keyboardTypes(digits) {
            for (const ch of digits)
                keyClick(Qt.Key_0 + Number(ch))
            keyClick(Qt.Key_Enter)
        }

        function pinShown() {
            return prompt().step === "pin" && pin().shown && pinChild("pinKeys").activeFocus
        }

        function cardList() { return find("whosPlayingCards") }

        // ---- Move ---------------------------------------------------------------------------------------------

        function test_accept_on_a_playing_profile_shows_move_with_cancel_focused() {
            signIn()
            Input.joinPlayer(host.pro, "p2")
            tryVerify(() => Input.players.length === 2, 2000, "Ada is player 2 on the Pro Controller")
            joinSpy.clear()
            askWith(host.dualSense)
            tryVerify(() => cardList().activeFocus && cardList().currentIndex === 2, 2000, "every profile plays: Guest")
            keyClick(Qt.Key_Left)
            compare(cardList().currentIndex, 1, "Ada")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000, "Move with Cancel focused")
            compare(prompt().step, "move")
            compare(find("whosPlayingConfirmTitle").text, "Move Ada to this controller?")
            compare(find("whosPlayingConfirmDetail").text, padNameOf(host.pro) + " stops playing as Ada.")
            verify(find("whosPlayingMove").visible && !find("whosPlayingJoin").visible, "Move's buttons, not Join's")
            compare(tc.shell.hintList.map(h => h.text), ["Select", "Back"])
            keyClick(Qt.Key_Right)
            verify(find("whosPlayingMove").activeFocus, "Move to the right")
            keyClick(Qt.Key_Left)
            verify(find("whosPlayingMoveCancel").activeFocus)
            keyClick(Qt.Key_Escape)
            tryVerify(() => cardList().activeFocus, 2000, "Back: step 1")
            compare(prompt().step, "pick")
            compare(cardList().currentIndex, 1, "on that card")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000)
            keyClick(Qt.Key_Return)                                 // Cancel
            tryVerify(() => cardList().activeFocus, 2000, "Cancel: step 1")
            compare(prompt().step, "pick")
            compare(cardList().currentIndex, 1, "on that card")
            compare(joinSpy.count, 0, "nothing joined yet")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                                 // Move: Ada has no PIN
            tryCompare(joinSpy, "count", 1)
            compare(joinSpy.signalArguments[0][0], host.dualSense)
            compare(joinSpy.signalArguments[0][1], "p2")
            tryVerify(() => !prompt().shown, 2000, "closed on ok")
            tryVerify(() => Input.players.length === 2 && Input.players[1].profile === "p2"
                      && Input.players[1].device_id === host.dualSense, 2000, "Ada plays on the DualSense now")
            compare(verifySpy.count, 0, "no VerifyPin for a profile without a PIN")
        }

        // Player One's own card: the PIN, then the pad becomes player 1's and the Xbox pad is unseated.
        function test_player_ones_card_moves_player_1_to_the_asking_pad_after_the_pin() {
            signIn()
            askWith(host.dualSense)
            tryVerify(() => cardList().activeFocus, 2000)
            keyClick(Qt.Key_Left)
            compare(cardList().currentIndex, 0, "Player One")
            compare(find("whosPlayingDetail").text, "Now on " + padNameOf(host.xbox) + ". Picking it moves Player One here.")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000)
            compare(find("whosPlayingConfirmTitle").text, "Move Player One to this controller?")
            compare(find("whosPlayingConfirmDetail").text, padNameOf(host.xbox) + " stops playing as Player One.")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                                 // Move
            tryVerify(() => pinShown(), 2000, "Move on a PIN profile asks the PIN")
            compare(joinSpy.count, 0, "no join before the PIN")
            compare(pinChild("pinTitle").text, "Enter PIN for Player One")
            compare(tc.shell.hintList.map(h => h.text), ["Select", "Back"])
            keyClick(Qt.Key_3)
            compare(tc.shell.hintList.map(h => h.text), ["Select", "Delete"], "a digit typed: Back deletes it")
            keyClick(Qt.Key_Backspace)
            compare(tc.shell.hintList.map(h => h.text), ["Select", "Back"])
            compare(Input.mockNavigator(), host.dualSense, "the asking pad still navigates")
            padTypes(host.dualSense, "9999")                        // wrong
            tryVerify(() => pinChild("pinMessage").text === "Wrong PIN. 4 attempts left.", 2000)
            verify(pinShown(), "the focus stays on the keys")
            compare(switchSpy.count, 0, "never a sign-in")
            compare(Profiles.activeProfile, "p1")
            compare(joinSpy.count, 0)
            padTypes(host.dualSense, "1234")
            tryCompare(joinSpy, "count", 1)
            compare(joinSpy.signalArguments[0][0], host.dualSense)
            compare(joinSpy.signalArguments[0][1], "p1")
            tryVerify(() => !prompt().shown, 2000)
            tryVerify(() => Input.players.length === 1 && Input.players[0].profile === "p1"
                      && Input.players[0].device_id === host.dualSense, 2000, "the DualSense is player 1's pad")
            verify(!Input.devices.find(d => d.id === host.xbox).slot, "the Xbox pad is unseated")
            compare(switchSpy.count, 0, "no switchTo at all")
            compare(verifySpy.count, 2, "a VerifyPin for each PIN typed")
            compare(Profiles.activeProfile, "p1")
            tryVerify(() => Input.mockNavigator() === "", 2000)
        }

        // A profile that plays with no pad (player 1 after its hold ran out) has no Move step: the PIN, then
        // the join; Back on the empty pad returns to its card.
        function test_a_padless_player_1_skips_move() {
            signIn()
            Input.mockSeatHoldMs(300)
            Input.mockRemoveDevice(host.xbox)
            tryVerify(() => Input.players.length === 1 && Input.players[0].device_id === "" && !Input.players[0].held,
                      3000, "the hold ran out: seat 1 has no pad")
            askWith(host.dualSense)
            tryVerify(() => cardList().activeFocus, 2000)
            compare(cardList().currentIndex, 0, "player 1's card first while seat 1 has no pad")
            compare(find("whosPlayingDetail").text, "", "no pad to name")
            keyClick(Qt.Key_Return)
            tryVerify(() => pinShown(), 2000, "straight to the PIN, no Move")
            Input.mockPadButton(host.dualSense, "south")            // "1"
            compare(pin().entered, "1")
            keyClick(Qt.Key_Escape)
            compare(pin().entered, "", "Back deletes a digit first")
            verify(pinShown(), "and stays")
            keyClick(Qt.Key_Escape)
            tryVerify(() => cardList().activeFocus, 2000, "Back on the empty pad: the card")
            compare(prompt().step, "pick")
            compare(cardList().currentIndex, 0)
            verify(!pin().shown)
            keyClick(Qt.Key_Return)
            tryVerify(() => pinShown(), 2000)
            padTypes(host.dualSense, "1234")
            tryCompare(joinSpy, "count", 1)
            compare(joinSpy.signalArguments[0][1], "p1")
            tryVerify(() => !prompt().shown, 2000)
            tryVerify(() => Input.players[0].device_id === host.dualSense, 2000, "the DualSense is player 1")
            compare(switchSpy.count, 0)
        }

        function test_a_padless_player_1_without_a_pin_joins_at_once() {
            signInAdaWithKeyboard()
            askWith(host.dualSense)
            tryVerify(() => cardList().activeFocus, 2000)
            compare(cardList().currentIndex, 1, "Ada, player 1 without a pad, first")
            compare(find("whosPlayingDetail").text, "")
            keyClick(Qt.Key_Return)
            tryCompare(joinSpy, "count", 1)
            compare(joinSpy.signalArguments[0][1], "p2")
            verify(prompt().step !== "move", "no Move")
            tryVerify(() => !prompt().shown, 2000)
            tryVerify(() => Input.players[0].device_id === host.dualSense, 2000)
            compare(verifySpy.count, 0, "no VerifyPin for a profile without a PIN")
        }

        // ---- the PIN on Join and Switch -----------------------------------------------------------------------

        function test_join_asks_the_pin_and_joins_after_it() {
            signInAda()
            askWith(host.dualSense)
            tryVerify(() => cardList().activeFocus, 2000)
            compare(cardList().currentIndex, 0, "Player One, free, with a PIN")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000, "a PIN card opens Join or Switch")
            keyClick(Qt.Key_Return)                                 // Join
            tryVerify(() => pinShown(), 2000, "Join asks the PIN")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000, "Back on the empty pad: Join or Switch, Join focused")
            compare(prompt().step, "confirm")
            keyClick(Qt.Key_Return)
            tryVerify(() => pinShown(), 2000)
            padTypes(host.dualSense, "1111")
            tryVerify(() => pinChild("pinMessage").text === "Wrong PIN. 4 attempts left.", 2000)
            compare(switchSpy.count, 0, "no switchTo before the PIN is right")
            compare(Profiles.activeProfile, "p2")
            compare(joinSpy.count, 0)
            padTypes(host.dualSense, "1234")
            tryCompare(joinSpy, "count", 1)
            compare(joinSpy.signalArguments[0][0], host.dualSense)
            compare(joinSpy.signalArguments[0][1], "p1")
            tryVerify(() => !prompt().shown, 2000)
            compare(Input.players.map(p => p.slot + ":" + p.profile).join(" "), "1:p2 2:p1")
            compare(switchSpy.count, 0, "and none after it")
            compare(Profiles.activeProfile, "p2")
        }

        function test_switch_asks_the_pin_then_locks_signs_in_and_joins() {
            signInAda()
            askWith(host.dualSense)
            tryVerify(() => cardList().activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                                 // Switch
            tryVerify(() => pinShown(), 2000, "Switch asks the PIN")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000, "Back on the empty pad: Join focused")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => pinShown(), 2000)
            keyboardTypes("4321")                                   // the keyboard types too
            tryVerify(() => pinChild("pinMessage").text === "Wrong PIN. 4 attempts left.", 2000)
            compare(switchSpy.count, 0, "no switchTo before the PIN is right")
            compare(Profiles.activeProfile, "p2", "Ada stays signed in")
            compare(host.order, [], "no Lock")
            verify(prompt().shown)
            padTypes(host.dualSense, "1234")
            tryVerify(() => host.order.length === 3, 3000, "the Lock, the sign-in and the join")
            compare(host.order, ["active ", "active p1", "join " + host.dualSense + " p1 ok"])
            compare(switchSpy.count, 1, "one switchTo, after the PIN")
            compare(switchSpy.signalArguments[0][1], "ok")
            tryVerify(() => Input.players.length === 1 && Input.players[0].profile === "p1"
                      && Input.players[0].device_id === host.dualSense, 2000, "the DualSense is the new player 1")
            compare(pin().entered, "", "the PIN is cleared after the Switch")
            compare(pin().shown, false)
        }

        // ---- wrong PIN, lockout, failures ---------------------------------------------------------------------

        function test_a_wrong_pin_shows_the_attempts_and_the_lockout_dims_the_keys() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => pinShown(), 2000)
            for (let left = 4; left >= 1; --left) {
                keyboardTypes("0000")
                tryVerify(() => pinChild("pinMessage").text === "Wrong PIN. " + left + (left === 1 ? " attempt left." : " attempts left."), 2000)
                compare(pin().entered, "")
                verify(pinShown(), "the focus stays on the keys")
            }
            keyboardTypes("0000")
            tryVerify(() => pin().locked, 2000, "the fifth wrong PIN locks the profile out")
            verify(pinChild("pinMessage").text.startsWith("Too many attempts. Try again in "), pinChild("pinMessage").text)
            compare(pinChild("pinDots").opacity, Theme.disabledOpacity, "the dots are dimmed")
            const keys = pinChild("pinKeys")
            compare(keys.itemAtIndex(0).children[0].opacity, Theme.disabledOpacity, "and the keys")
            verify(pinShown(), "the focus stays on the keys")
            keyboardTypes("1234")
            wait(50)
            compare(pin().entered, "", "a locked pad takes no digit")
            compare(joinSpy.count, 0)
            compare(switchSpy.count, 0)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000, "Back leaves to Move, Cancel focused")
        }

        // A refused join after a right PIN: the step before with its first button focused, and the toast.
        function test_a_refused_join_after_the_pin_returns_to_the_step_with_the_toast() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => pinShown(), 2000)
            Input.mockFailJoin("full")
            padTypes(host.dualSense, "1234")
            tryCompare(joinSpy, "count", 1)
            tryVerify(() => Notifications.model.count === 1, 2000, "the toast")
            compare(Notifications.model.get(0).text, "Player One could not join")
            compare(Notifications.model.get(0).detail, "Try again.")
            verify(prompt().shown)
            compare(prompt().step, "move")
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000, "Move again, Cancel focused")
            verify(!pin().shown)
            Input.mockFailJoin("")
        }

        // While the join after a right PIN is on its way the focus waits on Move (not Cancel), and Accept and
        // Back do nothing (lead, round 2).
        function test_while_the_join_runs_accept_and_back_do_nothing() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => pinShown(), 2000)
            host.focusAtJoin = ""
            padTypes(host.dualSense, "1234")
            tryCompare(joinSpy, "count", 1)
            compare(host.focusAtJoin, "move", "the focus was on Move when the join answered (seen before the prompt reacts)")
            tryVerify(() => !prompt().shown, 2000)
            // A join on its way, held here: Accept on Cancel and Back change nothing.
            askWith(host.pro)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Return)                                 // Player One plays on the DualSense now: Move
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000)
            prompt().joining = { pad: host.pro, id: "p1", from: "move" }
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Escape)
            compare(prompt().step, "move", "Accept on Cancel and Back wait for the join")
            verify(find("whosPlayingMoveCancel").activeFocus)
            prompt().joining = null
            keyClick(Qt.Key_Return)
            tryVerify(() => cardList().activeFocus, 2000, "with no join on its way Cancel works again")
        }

        // The prompt closes during the PIN step (the asking pad disconnects): the PIN pad closes with it and
        // drops the half-typed PIN, and the next pad's prompt opens on Pick, not on the PIN pad (lead, round 2).
        function test_a_prompt_that_closes_on_the_pin_step_drops_the_pin() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => pinShown(), 2000)
            keyClick(Qt.Key_1)
            keyClick(Qt.Key_2)
            compare(pin().entered, "12")
            Input.mockRemoveDevice(host.dualSense)
            tryVerify(() => !prompt().shown, 2000, "the asking pad went: closed as Not now")
            verify(!pin().shown, "the PIN pad closed with it")
            compare(pin().entered, "", "and the half-typed PIN is gone")
            askWith(host.pro)
            compare(prompt().step, "pick")
            verify(!pin().shown, "the next prompt opens on Pick")
            tryVerify(() => cardList().activeFocus || find("whosPlayingNotNow").activeFocus, 2000)
            verify(!pinChild("pinKeys").activeFocus)
        }

        // VerifyPin answers something else than ok, wrong-pin or locked-out (the profile went): the PIN pad's
        // failure message, and Back leaves.
        function test_a_failed_verify_shows_the_message_and_back_leaves() {
            signIn()
            Profiles.setPin("p2", "", "5678")                       // Ada gets a PIN
            tryVerify(() => Profiles.profiles.find(p => p.id === "p2").hasPin, 2000)
            askWith(host.dualSense)
            tryVerify(() => cardList().activeFocus && cardList().currentIndex === 1, 2000, "Ada")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingJoin").activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => pinShown(), 2000)
            compare(pinChild("pinTitle").text, "Enter PIN for Ada")
            Profiles.deleteProfile("p1", "1234", "p2")             // Ada is gone before her PIN is checked
            tryVerify(() => Profiles.profiles.length === 2, 2000)
            keyboardTypes("5678")
            tryVerify(() => pinChild("pinMessage").text === "That profile no longer exists.", 2000)
            verify(pinShown())
            compare(joinSpy.count, 0)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !pin().shown && prompt().step !== "pin", 2000, "Back leaves the PIN")
            compare(switchSpy.count, 0)
        }

        // ---- a seated pad's Guide while seat 1 has no pad -----------------------------------------------------

        function test_a_seated_pads_guide_asks_while_seat_1_has_no_pad() {
            signInAdaWithKeyboard()
            Input.joinPlayer(host.dualSense, "p1")
            tryVerify(() => Input.players.length === 2, 2000, "the DualSense is player 2 (Player One)")
            joinSpy.clear()
            Input.mockPadButton(host.dualSense, "guide")
            tryVerify(() => prompt().shown && prompt().pad === host.dualSense, 2000, "player 2's Guide asks")
            tryVerify(() => Input.mockNavigator() === host.dualSense, 2000)
            tryVerify(() => cardList().activeFocus, 2000)
            compare(cardList().currentIndex, 1, "Ada, player 1 without a pad, first")
            compare(find("whosPlayingDetail").text, "This controller stops playing as Player One.", "RUY-664: said before Accept")
            keyClick(Qt.Key_Left)
            compare(find("whosPlayingDetail").text, "", "Player One plays on this pad: nothing to move")
            keyClick(Qt.Key_Right)
            Input.mockPadButton(host.dualSense, "south")            // Ada: no PIN, no Move
            tryCompare(joinSpy, "count", 1)
            compare(joinSpy.signalArguments[0][1], "p2")
            tryVerify(() => !prompt().shown, 2000)
            tryVerify(() => Input.players[0].device_id === host.dualSense, 2000, "the DualSense is player 1")
        }

        function test_a_seated_pads_guide_asks_nothing_while_seat_1_has_a_pad() {
            signIn()
            Input.joinPlayer(host.pro, "p2")
            tryVerify(() => Input.players.length === 2, 2000)
            foreignSpy.clear()
            Input.mockPadButton(host.pro, "guide")
            tryCompare(foreignSpy, "count", 1, 2000)
            compare(foreignSpy.signalArguments[0][1], "player-guide")
            wait(50)
            verify(!prompt().shown, "player 2's Guide opens nothing")
            verify(find("homePlay").activeFocus)
        }

        // RUY-664: a seated pad that picks the padless player 1 is told, before Accept, that it stops playing
        // as its own profile; only that card says it, and the line follows the language while the prompt is open.
        function test_the_pad_that_gives_up_its_seat_is_told_before_accept() {
            signInAdaWithKeyboard()
            Input.joinPlayer(host.dualSense, "p1")
            tryVerify(() => Input.players.length === 2, 2000, "the DualSense is player 2 (Player One)")
            Input.mockPadButton(host.dualSense, "guide")
            tryVerify(() => prompt().shown && prompt().pad === host.dualSense, 2000)
            tryVerify(() => cardList().activeFocus && cardList().currentIndex === 1, 2000, "Ada, player 1 without a pad")
            compare(find("whosPlayingDetail").text, "This controller stops playing as Player One.")
            keyClick(Qt.Key_Left)
            compare(find("whosPlayingDetail").text, "", "Player One's own card says nothing")
            keyClick(Qt.Key_Right)
            DeviceSettings.language = "tr"
            tryVerify(() => find("whosPlayingDetail").text === "Bu kontrolcü artık Player One olarak oynamıyor.", 2000,
                      "the open prompt follows the language")
            compare(cardList().currentIndex, 1, "the model did not reset")
            keyClick(Qt.Key_Right)                                  // p3, the guest-role profile (RUY-680)
            keyClick(Qt.Key_Right)
            tryVerify(() => cardList().currentIndex === 3, 2000)
            tryVerify(() => findChild(cardList().currentItem, "profileCardName").text === "Misafir", 2000)
            DeviceSettings.language = "en"
            tryVerify(() => findChild(cardList().currentItem, "profileCardName").text === "Guest", 2000)
            compare(cardList().currentIndex, 3)
        }

        // The shots (RUY-664): the detail line before Accept, en and tr, on Ada's card with Player One's pad asking.
        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            for (const lang of ["en", "tr"]) {
                init()
                DeviceSettings.language = lang
                signInAdaWithKeyboard()
                Input.joinPlayer(host.dualSense, "p1")
                tryVerify(() => Input.players.length === 2, 2000)
                Input.mockPadButton(host.dualSense, "guide")
                tryVerify(() => prompt().shown && prompt().pad === host.dualSense, 2000)
                tryVerify(() => cardList().activeFocus && cardList().currentIndex === 1, 2000)
                wait(500)
                grabImage(tc.shell).save(shotsDir + "/whos-stops-" + lang + ".png")
                tc.shell.destroy()
                wait(50)
            }
        }

        // ---- geometry at 1080p (u = 1) ------------------------------------------------------------------------

        function test_pin_step_geometry_and_the_pad_line() {
            signIn()
            askWith(host.dualSense)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("whosPlayingMoveCancel").activeFocus, 2000)
            const u = tc.shell.u
            compare(find("whosPlayingMoveCancel").height, Theme.buttonHeight * u)
            verify(find("whosPlayingMoveCancel").width >= 300 * u)
            verify(find("whosPlayingMove").width >= 300 * u)
            const cancel = find("whosPlayingMoveCancel")
            const move = find("whosPlayingMove")
            verify(cancel.mapToItem(tc.shell, 0, 0).x < move.mapToItem(tc.shell, 0, 0).x, "Cancel first, then Move")
            fuzzyCompare(move.mapToItem(tc.shell, 0, 0).x - cancel.mapToItem(tc.shell, cancel.width, 0).x, Theme.spaceM * u, 0.5)
            compare(find("whosPlayingConfirmAvatar").width, 120 * u)
            compare(find("whosPlayingConfirmPanel").color, Theme.panel)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => pinShown(), 2000)
            const line = pinChild("pinPadLine")
            const title = pinChild("pinTitle")
            tryVerify(() => line.visible, 1000, "the pad line in player mode")
            compare(pinChild("pinPadName").text, padNameOf(host.dualSense))
            compare(pinChild("pinPadName").font.pixelSize, Theme.typeBody * u)
            // The column lays the line out on its next polish after the line shows.
            tryVerify(() => Math.abs(title.mapToItem(tc.shell, 0, 0).y - line.mapToItem(tc.shell, 0, line.height).y - Theme.spaceM * u) < 0.5,
                      1000, "the pad line spaceM above the title")
            verify(!pinChild("pinScrim").visible, "on the prompt's scrim, not a second one")
            verify(find("whosPlayingScrim").visible)
            verify(!find("whosPlayingConfirmPanel").visible && !find("whosPlayingPick").visible, "only the PIN pad")
        }
    }
}
