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

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }
        function setup() { return find("setup") }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
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

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
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
