import QtQuick
import QtTest
import RuyaShell

// PinPad's pad line (RUY-628, 04 "PIN pad"): only the player mode with a pad shows it, above the title,
// spaceM apart; the verify, collect, collect-confirm and admin modes (and the player mode without a pad)
// show none, so their geometry is as before: the title is the column's first row. The pad draws its own
// scrim unless its host turns it off.
Item {
    id: host
    width: 1920
    height: 1080

    readonly property string dualSense: "bluetooth-054c-0ce6-3f2a9c41d0b7"

    Component {
        id: padComponent
        PinPad { anchors.fill: parent; u: 1 }
    }

    TestCase {
        id: tc
        name: "PinPad"
        when: windowShown

        property PinPad pad: null

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.language = "en"
            Input.mockResetDevices()
            tryVerify(() => Input.devices.length === 3, 2000)
            tc.pad = createTemporaryObject(padComponent, host)
            verify(tc.pad)
        }

        function line() { return findChild(tc.pad, "pinPadLine") }
        function title() { return findChild(tc.pad, "pinTitle") }

        // The title is the column's first row: nothing above it.
        // (The pad fades in: its rows read visible only once it is.)
        function verifyNoPadLine(what) {
            tryVerify(() => tc.pad.visible, 1000, what + ": the pad shows")
            verify(title().visible, what + ": the title shows")
            verify(!line().visible, what + ": no pad line")
            tryCompare(title(), "y", 0, 1000, what + ": the title is the first row")
        }

        function test_the_other_modes_show_no_pad_line() {
            tc.pad.open({ id: "p1", name: "Player One" })
            verify(tc.pad.shown)
            compare(title().text, "Enter PIN for Player One")
            verifyNoPadLine("verify")
            tc.pad.close()
            tc.pad.collect("New PIN", false)
            verifyNoPadLine("collect")
            tc.pad.close()
            tc.pad.collect("New PIN", true)
            verifyNoPadLine("collect-confirm")
            tc.pad.close()
            tc.pad.verifyAdmin("Enter an admin's PIN", "p1")
            verifyNoPadLine("admin")
            tc.pad.close()
            tc.pad.verifyPlayer({ id: "p1", name: "Player One" }, "")
            compare(title().text, "Enter PIN for Player One")
            verifyNoPadLine("player without a pad")
            verify(findChild(tc.pad, "pinScrim").visible, "its own scrim by default")
        }

        function test_the_player_mode_shows_the_pad_line_above_the_title() {
            tc.pad.verifyPlayer({ id: "p1", name: "Player One" }, host.dualSense)
            compare(tc.pad.mode, "player")
            tryVerify(() => line().visible, 1000, "the pad line shows")
            compare(title().text, "Enter PIN for Player One")
            const d = Input.devices.find(x => x.id === host.dualSense)
            compare(findChild(tc.pad, "pinPadName").text,
                    Notifications.named(DeviceIcons.padName(d.id, d.name ?? "", d.family ?? "")))
            tryVerify(() => title().y > 0, 1000, "the column is laid out with the line")
            compare(line().y, 0, "the pad line is the first row")
            fuzzyCompare(title().y - (line().y + line().height), Theme.spaceM, 0.5, "spaceM above the title")
            compare(line().spacing, Theme.spaceS)
            verify(findChild(tc.pad, "pinKeys").activeFocus, "the keys have the focus")
            // Back to another mode: the line goes and the title is the first row again.
            tc.pad.close()
            tc.pad.open({ id: "p1", name: "Player One" })
            verifyNoPadLine("verify after player")
        }
    }
}
