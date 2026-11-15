import QtQuick
import QtTest
import RuyaShell

// RUY-691: toasts draw above every modal and sheet (one fixed z) and below the volume OSD, the mode
// confirm and the screen saver; a toast never takes the focus from the modal under it. Signs in as
// Ada (p2, no PIN).
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
        name: "ToastLayering"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            IdleClock.stage = "active"
            Notifications.durationMs = 60000
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            clearToasts()
        }

        function cleanup() {
            Notifications.durationMs = Theme.toastMs
            clearToasts()
        }

        function clearToasts() {
            const keys = Object.keys(Notifications.keyed)
            for (let i = 0; i < keys.length; ++i)
                Notifications.remove(keys[i])
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function checkOrder(label) {
            const t = find("toastLayer").z
            const below = ["modalLayer", "profilePicker", "setup", "systemPanel", "notificationSheet",
                           "overlayPowerConfirm", "thermalPolicy"]
            for (let i = 0; i < below.length; ++i)
                verify(t > find(below[i]).z, label + ": toasts (" + t + ") above " + below[i] + " (" + find(below[i]).z + ")")
            const above = ["volumeOsd", "modeConfirm", "screenSaver"]
            for (let j = 0; j < above.length; ++j)
                verify(t < find(above[j]).z, label + ": toasts (" + t + ") below " + above[j] + " (" + find(above[j]).z + ")")
        }

        function test_order_nothing_open() { checkOrder("nothing open") }

        function test_order_hub_open() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
            verify(find("systemPanel").open)
            checkOrder("Hub open")
        }

        function test_order_whos_playing_over_hub() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
            find("whosPlaying").open("p2")
            tryVerify(() => find("whosPlaying").shown, 2000, "the prompt opens")
            tryCompare(find("modalLayer"), "z", 21)
            checkOrder("Who's playing over the Hub")
        }

        function test_toast_over_modal_keeps_focus() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
            find("whosPlaying").open("p2")
            tryVerify(() => find("whosPlaying").shown, 2000, "the prompt opens")
            const focused = Window.activeFocusItem
            verify(focused, "something has the focus")
            Notifications.show("That file can't be used", "error", "", "", "Not a picture.")
            tryVerify(() => Notifications.model.count === 1, 2000, "the toast is queued")
            tryVerify(() => find("toastList").visible && find("toastList").count > 0, 2000, "the toast shows")
            verify(find("toastLayer").visible)
            verify(find("toastLayer").z > find("modalLayer").z)
            compare(Window.activeFocusItem, focused, "the modal keeps the focus")
            verify(find("whosPlaying").shown)
        }

        // dev.ps1 shots: an error toast over the Hub, undimmed (the import picker's refusal is shot in
        // tst_controls_in_games, 28-controls-import-refused).
        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
            Notifications.show("That file can't be used", "error", "", "", "It isn't a RuyaOS controls file.")
            tryVerify(() => find("toastList").count > 0, 2000)
            wait(800)
            grabImage(tc.shell)
            wait(400)
            grabImage(tc.shell).save(shotsDir + "/" + "95-toast-over-hub.png")
        }
    }
}
