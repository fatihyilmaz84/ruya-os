import QtQuick
import QtTest
import RuyaShell

// First-boot setup (T-106): with no profiles the shell shows the setup wizard instead of the
// picker, and the whole flow works with controller keys only (arrows, Return = Accept,
// Escape = Back). Own file: it creates a profile and changes the language, and each file gets
// a fresh engine; the mock is also reset before every test.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: createSpy; target: Profiles; signalName: "createFinished" }

    TestCase {
        id: tc
        name: "Setup"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        function setup() { return find("setup") }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Bluetooth.mockReset()
            tryVerify(() => Bluetooth.inputKnown && Bluetooth.inputPresent && Bluetooth.controllerPairing === "idle")
            Profiles.lock()
            Profiles.resetMockForTests("empty")
            tryVerify(() => Profiles.profiles.length === 0)
            createSpy.clear()
            DeviceSettings.language = "en"
        }

        function startShell() {
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.available)
        }

        // Presses Accept until the wizard is on `target`, checking each step on the way.
        function goToStep(target) {
            for (let i = 0; i < 6 && setup().step < target; ++i) {
                const before = setup().step
                keyClick(Qt.Key_Return)
                tryCompare(setup(), "step", before + 1)
            }
            compare(setup().step, target)
        }

        // D-pad over the PIN pad keypad (3 columns: 1-9, then Del 0 OK).
        function padPress(label) {
            const order = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "del", "0", "ok"]
            const target = order.indexOf(label)
            verify(target >= 0)
            const pad = find("setupPinPad")
            const keys = findChild(pad, "pinKeys")
            verify(pad.shown, "the PIN pad is open")
            for (let step = 0; step < 12; ++step) {
                if (keys.currentIndex === target)
                    break
                const row = Math.floor(keys.currentIndex / 3)
                const targetRow = Math.floor(target / 3)
                const before = keys.currentIndex
                if (row !== targetRow)
                    keyClick(row < targetRow ? Qt.Key_Down : Qt.Key_Up)
                else
                    keyClick(keys.currentIndex % 3 < target % 3 ? Qt.Key_Right : Qt.Key_Left)
                if (keys.currentIndex === before)
                    fail("PIN pad key navigation is stuck at " + before + " going to " + label)
            }
            compare(keys.currentIndex, target)
            keyClick(Qt.Key_Return)
        }

        function enterPin(pin) {
            for (const d of pin)
                padPress(d)
            padPress("ok")
        }

        // D-pad over the on-screen keyboard.
        function keyboardGoTo(entry, value) {
            let target = null
            for (let r = 0; r < entry.rows.length && !target; ++r) {
                const c = entry.rows[r].keys.findIndex(k => k.value === value)
                if (c >= 0)
                    target = { row: r, col: c }
            }
            verify(target !== null, "keyboard has '" + value + "'")
            for (let step = 0; step < 60; ++step) {
                if (entry.focusRow === target.row && entry.focusCol === target.col)
                    return
                if (entry.focusRow !== target.row) {
                    keyClick(entry.focusRow < target.row ? Qt.Key_Down : Qt.Key_Up)
                } else {
                    const n = entry.rows[target.row].keys.length
                    const right = (target.col - entry.focusCol + n) % n
                    keyClick(right <= n - right ? Qt.Key_Right : Qt.Key_Left)
                }
            }
            fail("could not reach '" + value + "'")
        }

        // On step 3 with the name row focused: open the keyboard, type, Done.
        function typeName(text) {
            keyClick(Qt.Key_Return)
            const entry = find("setupNameEntry")
            tryVerify(() => entry.shown, 2000, "the keyboard opens")
            for (const ch of text) {
                if (ch !== ch.toLowerCase()) {
                    keyboardGoTo(entry, "shift")
                    keyClick(Qt.Key_Return)
                }
                keyboardGoTo(entry, ch.toLowerCase())
                keyClick(Qt.Key_Return)
            }
            keyboardGoTo(entry, "done")
            keyClick(Qt.Key_Return)
            tryVerify(() => !entry.shown)
        }

        // ---- acceptance criteria ----

        function test_setup_shown_when_no_profiles() {
            startShell()
            tryVerify(() => setup().visible, 2000, "the wizard is shown")
            verify(!find("profilePicker").visible, "not the picker")
            verify(!find("profilePicker").enabled)
            compare(setup().step, 0)
            verify(setup().activeFocus, "the wizard has focus")
            compare(find("setupStepLabel").text, "Step 1 of 5")
        }

        function test_seeded_mock_never_shows_setup() {
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            startShell()
            tryVerify(() => find("profilePicker").visible)
            verify(!setup().visible)
            verify(find("profileList").activeFocus)
        }

        function test_language_choice() {
            startShell()
            goToStep(1)
            tryVerify(() => find("setupLanguageRow").activeFocus, 2000, "the language row has focus")
            compare(DeviceSettings.language, "en")
            keyClick(Qt.Key_Right)
            compare(DeviceSettings.language, "tr")
            compare(find("setupLanguageRow").value, "tr")
            keyClick(Qt.Key_Left)
            compare(DeviceSettings.language, "en")
            keyClick(Qt.Key_Right)
            compare(DeviceSettings.language, "tr")

            // An invalid value is rejected and leaves the old one.
            ignoreWarning(new RegExp("rejecting invalid language"))
            DeviceSettings.language = "xx"
            compare(DeviceSettings.language, "tr")
            tryCompare(find("setupLanguageRow"), "value", "tr")
        }

        function test_full_setup_flow() {
            startShell()
            goToStep(3)
            tryVerify(() => find("setupNameRow").activeFocus, 2000, "the name row has focus")
            typeName("Owner")
            compare(setup().adminName, "Owner")
            tryVerify(() => find("setupCreateRow").activeFocus, 2000, "focus moves on to the PIN row")

            keyClick(Qt.Key_Return)
            tryVerify(() => find("setupPinPad").shown, 2000, "the PIN pad opens")
            compare(find("setupPinPad").mode, "collect-confirm")
            enterPin("2468")
            enterPin("2468")

            tryCompare(setup(), "step", 4)
            compare(Profiles.profiles.length, 1)
            compare(Profiles.profiles[0].name, "Owner")
            compare(Profiles.profiles[0].role, "admin")
            compare(Profiles.profiles[0].hasPin, true)
            verify(setup().visible, "the Done step stays; no flash of the picker")
            verify(!find("profilePicker").enabled)
            compare(Profiles.activeProfile, "", "setup does not sign anyone in")

            keyClick(Qt.Key_Return)
            tryVerify(() => !setup().visible, 2000, "the wizard is gone")
            tryVerify(() => find("profilePicker").visible && find("profilePicker").enabled)
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has focus")
            compare(find("profileList").count, 1, "the picker shows exactly the new profile")

            // The PIN really is 2468.
            keyClick(Qt.Key_Return)
            tryVerify(() => find("pinPad").shown)
            for (const d of "2468")
                keyClick(d)
            keyClick(Qt.Key_Enter)
            tryCompare(Profiles, "activeProfile", "p1")
        }

        // T-179: Backspace is Back, like Esc.
        function test_backspace_goes_back_a_step() {
            startShell()
            goToStep(2)
            keyClick(Qt.Key_Backspace)
            tryCompare(setup(), "step", 1)
            tryVerify(() => find("setupLanguageRow").activeFocus)
            keyClick(Qt.Key_Backspace)
            tryCompare(setup(), "step", 0)
            keyClick(Qt.Key_Backspace)                        // nothing before the welcome step
            compare(setup().step, 0)
        }

        function test_back_navigation() {
            startShell()
            keyClick(Qt.Key_Escape)                           // nothing before the welcome step
            compare(setup().step, 0)

            goToStep(1)
            keyClick(Qt.Key_Right)                            // Türkçe
            compare(DeviceSettings.language, "tr")
            goToStep(3)
            typeName("Ab")

            keyClick(Qt.Key_Escape)                           // 3 -> 2
            tryCompare(setup(), "step", 2)
            keyClick(Qt.Key_Escape)                           // 2 -> 1
            tryCompare(setup(), "step", 1)
            tryVerify(() => find("setupLanguageRow").activeFocus)
            compare(DeviceSettings.language, "tr", "the language is kept")
            keyClick(Qt.Key_Escape)                           // 1 -> 0
            tryCompare(setup(), "step", 0)

            goToStep(3)
            compare(setup().adminName, "Ab", "the name is kept")
            tryVerify(() => find("setupCreateRow").activeFocus, 2000, "focus is on the PIN row once a name is set")
            compare(Profiles.profiles.length, 0, "going back and forth creates nothing")
        }

        function test_name_is_required() {
            startShell()
            goToStep(3)
            keyClick(Qt.Key_Down)                             // to the PIN row
            tryVerify(() => find("setupCreateRow").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("setupMessage").text === "Enter a name first.")
            verify(!find("setupPinPad").shown, "no PIN pad without a name")
            compare(createSpy.count, 0)
        }

        function test_cancelling_the_pin_pad_creates_nothing() {
            startShell()
            goToStep(3)
            typeName("Owner")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("setupPinPad").shown)
            keyClick(Qt.Key_Escape)                           // Back on an empty pad
            tryVerify(() => !find("setupPinPad").shown)
            tryVerify(() => find("setupCreateRow").activeFocus, 2000, "focus returns to the PIN row")
            compare(setup().step, 3)
            compare(createSpy.count, 0)
            compare(Profiles.profiles.length, 0)
        }

        function test_error_is_shown_and_can_be_retried() {
            startShell()
            goToStep(3)
            setup().adminName = "x".repeat(40)                // the keyboard stops at 32; the service refuses this
            keyClick(Qt.Key_Down)
            tryVerify(() => find("setupCreateRow").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("setupPinPad").shown)
            enterPin("2468")
            enterPin("2468")
            tryVerify(() => find("setupMessage").text.indexOf("isn't allowed") >= 0, 3000)
            compare(setup().step, 3)
            tryVerify(() => find("setupCreateRow").activeFocus, 2000, "focus is back on the PIN row")
            compare(Profiles.profiles.length, 0)

            setup().adminName = "Owner"                       // fix it and try again
            keyClick(Qt.Key_Return)
            tryVerify(() => find("setupPinPad").shown)
            enterPin("2468")
            enterPin("2468")
            tryCompare(setup(), "step", 4)
            compare(Profiles.profiles.length, 1)
        }

        // The hint bar as "A Next|B Back", from the bar's own delegates.
        function hintsShown() {
            const bar = find("hintBar")
            if (!bar.visible)
                return ""
            const parts = []
            for (const b of ["A", "B"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        function test_hints_follow_the_step() {
            startShell()
            compare(hintsShown(), "A Next", "welcome: nothing to go back to")
            goToStep(1)
            compare(hintsShown(), "A Next|B Back")
            goToStep(2)
            compare(hintsShown(), "A Next|B Back")
            goToStep(3)
            compare(hintsShown(), "A Select|B Back")
            keyClick(Qt.Key_Return)                           // the name row opens the keyboard
            tryVerify(() => find("setupNameEntry").shown, 2000, "the keyboard opens")
            compare(hintsShown(), "B Cancel")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("setupNameEntry").shown, 2000)
            compare(hintsShown(), "A Select|B Back")
            setup().adminName = "Owner"
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("setupPinPad").shown, 2000)
            compare(hintsShown(), "B Cancel")
            enterPin("2468")
            enterPin("2468")
            tryCompare(setup(), "step", 4)
            compare(hintsShown(), "A Next", "done: the account exists, no Back")
        }

        // ---- T-203: pairing a controller with no keyboard ----

        function pairingVisible() { return find("setupPairing").visible }

        // The console has no input device: the wizard starts with the pairing stage.
        function startWithoutInput(script) {
            Bluetooth.mockSetInputPresent(false)
            Bluetooth.mockPairingScript(script)
            tryVerify(() => !Bluetooth.inputPresent)
            startShell()
        }

        function test_no_pairing_stage_when_an_input_device_exists() {
            startShell()
            tryVerify(() => setup().visible)
            verify(Bluetooth.inputPresent && Bluetooth.inputKnown)
            verify(!pairingVisible(), "no controller step")
            verify(find("setupWelcome").visible)
            compare(Bluetooth.mockPairingStarts(), 0, "the window was never opened")
            compare(Bluetooth.controllerPairing, "idle")
            compare(hintsShown(), "A Next")
        }

        function test_pairing_stage_comes_first_when_there_is_no_input_device() {
            startWithoutInput("wait")
            tryVerify(() => pairingVisible(), 2000, "the controller step is shown")
            verify(!find("setupWelcome").visible, "instead of the welcome step")
            compare(setup().step, 0)
            verify(setup().activeFocus, "the wizard keeps focus")
            tryCompare(Bluetooth, "controllerPairing", "open")
            compare(Bluetooth.mockPairingStarts(), 1)
            verify(find("setupPairHintText").text.indexOf("Hold the pairing button") >= 0)
            verify(!find("setupPairRetry").visible, "nothing to retry while waiting")
            compare(hintsShown(), "B Skip")
        }

        function test_a_controller_that_pairs_moves_the_wizard_on_and_works() {
            startWithoutInput("success")
            tryVerify(() => pairingVisible(), 2000)
            tryVerify(() => !pairingVisible(), 4000, "the step is left when the controller has paired")
            verify(find("setupWelcome").visible)
            verify(setup().activeFocus)
            const pad = Bluetooth.devices.find(d => d.id === "bt-pad-new")
            verify(pad && pad.paired && pad.connected, "the controller is paired and connected")
            tryCompare(Bluetooth, "controllerPairing", "idle", 2000, "the window is closed")
            compare(hintsShown(), "A Next", "the numbered steps are as before")
            // the new controller can go on: A is Accept
            keyClick(Qt.Key_Return)
            tryCompare(setup(), "step", 1)
            tryVerify(() => find("setupLanguageRow").activeFocus)
            compare(find("setupStepLabel").text, "Step 2 of 5")
        }

        function test_a_timeout_offers_retry_with_the_pad() {
            startWithoutInput("timeout")
            tryVerify(() => find("setupPairRetry").visible, 4000, "Try again is offered")
            compare(Bluetooth.controllerPairing, "timeout")
            verify(pairingVisible(), "still on the step")
            verify(find("setupPairHintText").text.indexOf("No controller was found") >= 0)
            compare(hintsShown(), "A Try again|B Skip")
            compare(Bluetooth.mockPairingStarts(), 1)
            Bluetooth.mockPairingScript("success")
            keyClick(Qt.Key_Return)                           // Try again
            tryVerify(() => !pairingVisible(), 4000, "the second window found the controller")
            compare(Bluetooth.mockPairingStarts(), 2)
            verify(find("setupWelcome").visible)
        }

        function test_back_skips_the_stage_for_good() {
            startWithoutInput("wait")
            tryCompare(Bluetooth, "controllerPairing", "open")
            keyClick(Qt.Key_Escape)                           // B
            tryVerify(() => !pairingVisible(), 2000)
            verify(find("setupWelcome").visible)
            tryCompare(Bluetooth, "controllerPairing", "idle", 2000, "leaving closes the window")
            verify(setup().activeFocus)
            // the stage does not come back, and the rest of the wizard works
            wait(300)
            verify(!pairingVisible())
            keyClick(Qt.Key_Return)
            tryCompare(setup(), "step", 1)
            keyClick(Qt.Key_Escape)
            tryCompare(setup(), "step", 0)
            verify(!pairingVisible(), "Back from step 1 goes to the welcome step, not to the pairing stage")
            compare(Bluetooth.mockPairingStarts(), 1)
        }

        function test_a_keyboard_plugged_in_ends_the_stage() {
            startWithoutInput("wait")
            tryVerify(() => pairingVisible(), 2000)
            tryCompare(Bluetooth, "controllerPairing", "open")
            Bluetooth.mockSetInputPresent(true)
            tryVerify(() => !pairingVisible(), 2000)
            verify(find("setupWelcome").visible)
            tryCompare(Bluetooth, "controllerPairing", "idle", 2000)
        }

        function test_a_device_that_is_not_a_controller_is_said_to_be_ignored() {
            startWithoutInput("rejected")
            tryVerify(() => find("setupPairHintIgnored").visible, 3000, "the rejected device is mentioned")
            verify(pairingVisible(), "the window stays open")
            compare(Bluetooth.controllerPairing, "open")
        }

        function test_a_stage_that_is_not_the_wizards_turn_does_not_steal_focus() {
            // seeded profiles: the picker is up, the wizard is hidden. No input device appears.
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            startShell()
            tryVerify(() => find("profileList").activeFocus)
            Bluetooth.mockSetInputPresent(false)
            tryVerify(() => !Bluetooth.inputPresent)
            verify(!setup().visible && !setup().pairingStage, "the wizard stays out of it")
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker keeps focus")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            startWithoutInput("wait")
            tryVerify(() => pairingVisible(), 2000)
            tryCompare(Bluetooth, "controllerPairing", "open")
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/13-setup-controller.png")
            Bluetooth.mockSetInputPresent(true)
            tryVerify(() => !pairingVisible(), 2000)
            tc.shell.destroy()
            Bluetooth.mockReset()
            tryVerify(() => Bluetooth.inputPresent)
            startShell()
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/11-setup-welcome.png")
            goToStep(3)
            setup().adminName = "Owner"
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/12-setup-admin.png")
        }
    }
}
