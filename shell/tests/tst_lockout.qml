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

            // The right PIN is refused while locked out (submit is a no-op).
            for (const d of "1234") keyClick(d)
            keyClick(Qt.Key_Enter)
            wait(100)
            compare(Profiles.activeProfile, "")
        }
    }
}
