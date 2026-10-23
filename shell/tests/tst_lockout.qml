import QtQuick
import QtTest
import RuyaShell

// Separate file: each test file gets its own engine, hence a fresh mock service whose
// lockout state cannot leak into the other tests.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "Lockout"
        when: windowShown

        SignalSpy {
            id: switchSpy
            target: Profiles
            signalName: "switchFinished"
        }

        function test_wrong_pins_lock_the_profile() {
            const shell = createTemporaryObject(shellComponent, host)
            shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            const pad = findChild(shell, "pinPad")
            const message = findChild(shell, "pinMessage")

            keyClick(Qt.Key_Return)                    // Player One
            tryVerify(() => pad.shown)

            for (let left = 4; left >= 1; --left) {
                for (const d of "0000") keyClick(d)
                keyClick(Qt.Key_Enter)
                tryVerify(() => !pad.busy)
                verify(message.text.indexOf(String(left)) !== -1, "shows attempts left: " + message.text)
                compare(pad.entered, "", "entry is cleared after a wrong PIN")
            }

            for (const d of "0000") keyClick(d)
            keyClick(Qt.Key_Enter)
            tryVerify(() => pad.lockSecs > 0)
            verify(message.text.indexOf(String(pad.lockSecs)) !== -1, "shows the countdown: " + message.text)

            // Locked: digits and OK do nothing, and the pad looks disabled.
            const dots = findChild(shell, "pinDots")
            verify(pad.locked)
            verify(dots.opacity < 1, "locked pad is dimmed")
            const before = switchSpy.count
            for (const d of "1234") keyClick(d)
            compare(pad.entered, "", "digits are ignored while locked")
            keyClick(Qt.Key_Enter)
            keyClick(Qt.Key_Return)                    // Accept on the focused key
            wait(100)
            compare(switchSpy.count, before, "nothing is sent to the service while locked")
            compare(Profiles.activeProfile, "")

            if (shotsDir) {
                wait(400)
                grabImage(shell).save(shotsDir + "/15-pin-locked.png")
            }

            // Shorten the visible countdown (the mock's own lock is still 30 s): the pad is
            // usable again when it reaches 0, with focus where it was.
            pad.lockSecs = 1
            tryVerify(() => !pad.locked, 3000)
            compare(dots.opacity, 1, "disabled look is off after the countdown")
            verify(findChild(shell, "pinKeys").activeFocus)
            keyClick("5")
            compare(pad.entered, "5", "digits are accepted again")
            for (const d of "678") keyClick(d)
            keyClick(Qt.Key_Enter)                     // the service still refuses: back to locked
            tryVerify(() => pad.locked)
            compare(pad.entered, "")
        }
    }
}
