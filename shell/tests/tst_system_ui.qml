import QtQuick
import QtTest
import RuyaShell

// System UI: toasts and the volume OSD. Neither may ever take focus; the volume keys work
// in every state. Driven with controller/media keys only. Signs in as "Ada" (p2, no PIN),
// except where a test needs the PIN pad (Player One, PIN 1234).
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
        name: "SystemUi"
        when: windowShown

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            Audio.setVolume(50)
            if (Audio.muted)
                Audio.toggleMute()
            tryCompare(Audio, "volume", 50)
            tryCompare(Audio, "muted", false)
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
        }

        function cleanup() {
            Notifications.durationMs = Theme.toastMs
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        // activeFocus is false everywhere when the OS deactivates the test window (another
        // window grabbing focus during a long test). The item's own `focus` flag still shows
        // that the shell kept focus where it belongs, so fall back to it only in that case.
        function hasFocus(item) {
            return item.activeFocus || (!host.Window.window.active && item.focus)
        }

        function signInAsAda() {
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("tiles").activeFocus, 2000, "home shelf takes focus after sign-in")
        }

        function test_toast_never_steals_focus() {
            keyClick(Qt.Key_Return)                    // Player One has a PIN: the pad opens
            tryVerify(() => find("pinPad").shown)
            tryVerify(() => find("pinKeys").activeFocus)
            const before = host.Window.activeFocusItem
            verify(before)

            Notifications.show("Controller connected", "info")
            tryCompare(Notifications.model, "count", 1)
            tryVerify(() => find("toastList").count === 1)
            compare(host.Window.activeFocusItem, before)

            Notifications.show("Update ready", "success", "!")
            Notifications.show("Low battery", "warning")
            Notifications.show("Disk error", "error")
            compare(host.Window.activeFocusItem, before)
            verify(find("pinKeys").activeFocus)
            keyClick(Qt.Key_Right)                     // the pad still gets the keys
            compare(find("pinKeys").currentIndex, 1)
        }

        function test_toast_queue() {
            signInAsAda()
            Notifications.durationMs = 400
            const base = Notifications.shownCount      // cumulative across tests
            for (let i = 1; i <= 5; ++i)
                Notifications.show("Toast " + i, "info")
            compare(Notifications.model.count, 3, "at most 3 visible")
            compare(Notifications.pendingCount, 2)
            verify(find("toastList").count <= 3)

            tryCompare(Notifications, "shownCount", base + 5, 5000, "all five are shown eventually")
            verify(Notifications.model.count <= 3)
            tryCompare(Notifications.model, "count", 0, 5000, "and each goes away by itself")
            compare(Notifications.pendingCount, 0)
            verify(tc.hasFocus(find("tiles")))
        }

        function test_toast_kind_falls_back_to_info() {
            Notifications.show("Hello", "bogus")
            compare(Notifications.model.get(0).kind, "info")
        }

        function test_volume_keys() {
            signInAsAda()
            const osd = find("volumeOsd")
            verify(!osd.shown)

            keyClick(Qt.Key_VolumeUp)
            tryCompare(Audio, "volume", 55)
            tryCompare(osd, "shown", true)
            verify(find("tiles").activeFocus, "focus does not move")

            keyClick(Qt.Key_VolumeDown)
            tryCompare(Audio, "volume", 50)

            keyClick(Qt.Key_VolumeMute)
            tryCompare(Audio, "muted", true)
            keyClick(Qt.Key_VolumeMute)
            tryCompare(Audio, "muted", false)

            tryCompare(osd, "shown", false, 4000, "the OSD hides by itself")
            verify(tc.hasFocus(find("tiles")))
        }

        function test_volume_keys_in_modal() {
            keyClick(Qt.Key_Return)                    // PIN pad
            tryVerify(() => find("pinPad").shown)
            tryVerify(() => find("pinKeys").activeFocus)
            keyClick(Qt.Key_VolumeDown)
            tryCompare(Audio, "volume", 45)
            verify(find("pinKeys").activeFocus, "the PIN pad keeps focus")

            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("pinPad").shown)
            tryVerify(() => find("profileList").activeFocus)
            signInAsAda()

            keyClick(Qt.Key_HomePage)                  // the Guide overlay is modal too
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_VolumeUp)
            tryCompare(Audio, "volume", 50)
            verify(find("systemActions").activeFocus, "the overlay keeps focus")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("tiles").activeFocus)
        }

        function test_volume_clamps() {
            signInAsAda()
            Audio.setVolume(98)
            tryCompare(Audio, "volume", 98)
            keyClick(Qt.Key_VolumeUp)
            keyClick(Qt.Key_VolumeUp)
            tryCompare(Audio, "volume", 100)
            tryCompare(find("volumeOsd"), "shown", true)

            Audio.setVolume(3)
            tryCompare(Audio, "volume", 3)
            keyClick(Qt.Key_VolumeDown)
            keyClick(Qt.Key_VolumeDown)
            tryCompare(Audio, "volume", 0)
            Audio.setVolume(250)
            tryCompare(Audio, "volume", 100)
            Audio.setVolume(-5)
            tryCompare(Audio, "volume", 0)
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            signInAsAda()
            Notifications.show("Controller connected", "success", "+")
            Notifications.show("Update ready: restart to apply", "info")
            Notifications.show("Controller battery low", "warning")
            keyClick(Qt.Key_VolumeUp)
            tryCompare(Audio, "volume", 55)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/14-toast-and-osd.png")
        }
    }
}
