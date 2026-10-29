import QtQuick
import QtTest
import RuyaShell

// The app layer and the C++ key router (T-150): a stand-in app item (what T-130's compositor
// will add) sits above home and pages and below the overlays; Guide and the volume keys stay
// with the shell, every other key reaches the focused app. Signs in as "Ada" (p2, no PIN).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // Records the keys it receives and accepts all of them, like a real app would.
    Component {
        id: appComponent
        Item {
            objectName: "standInApp"
            property var keys: []
            Keys.onPressed: event => {
                keys = keys.concat([event.key])
                event.accepted = true
            }
        }
    }

    TestCase {
        id: tc
        name: "CompositorLayers"
        when: windowShown

        property Item shell: null
        property Item app: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Audio.mockReset()
            Power.mockReset()
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("tiles").activeFocus, 2000, "home shelf takes focus after sign-in")
            tc.app = createTemporaryObject(appComponent, host)
            verify(tc.app)
            tc.shell.addApp(tc.app)
            tryVerify(() => tc.app.activeFocus, 2000, "the app takes focus")
        }

        function test_keys_reach_app() {
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Escape)
            compare(tc.app.keys, [Qt.Key_Left, Qt.Key_Down, Qt.Key_A, Qt.Key_Return, Qt.Key_Escape])
            verify(!find("tiles").activeFocus, "the home tiles got nothing")
        }

        function test_guide_blocks_app() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the overlay opens over the app")
            verify(!tc.app.activeFocus)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_B)
            compare(tc.app.keys.length, 0, "nothing reaches the app while the overlay is open")
        }

        function test_focus_back_after_overlay() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_Escape)
            tryVerify(() => tc.app.activeFocus, 2000, "closing the overlay returns focus to the app")
            compare(tc.app.keys.length, 0, "neither Guide nor Back reached the app")
            keyClick(Qt.Key_X)
            compare(tc.app.keys, [Qt.Key_X])

            keyClick(Qt.Key_Super_L)                     // a keyboard Guide, same path
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_Super_L)                     // and Guide closes the overlay again
            tryVerify(() => tc.app.activeFocus)
            compare(tc.app.keys, [Qt.Key_X])
        }

        function test_guide_hold() {
            keyPress(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the overlay opens on press")
            compare(find("systemPanel").powerMode, false)
            tryCompare(find("systemPanel"), "powerMode", true, Theme.guideHoldMs + 2000)
            keyRelease(Qt.Key_HomePage)
            wait(100)
            verify(find("systemPanel").open, "releasing after the hold does not close it")
            compare(tc.app.keys.length, 0)
        }

        function test_volume_keys() {
            const before = Audio.volume
            keyClick(Qt.Key_VolumeUp)
            tryCompare(Audio, "volume", before + 5)
            keyClick(Qt.Key_VolumeDown)
            tryCompare(Audio, "volume", before)
            compare(tc.app.keys.length, 0, "the volume keys do not reach the app")
            verify(tc.app.activeFocus, "and focus did not move")
        }

        function test_app_removed() {
            tc.shell.removeApp(tc.app)
            tryVerify(() => find("tiles").activeFocus, 2000, "focus goes back to the home tiles")
            compare(tc.shell.appOpen, false)
            tc.shell.addApp(tc.app)                      // an app that is destroyed does the same
            tryVerify(() => tc.app.activeFocus)
            tc.app.destroy()
            tryVerify(() => find("tiles").activeFocus, 2000, "a destroyed app item is removed too")
            compare(tc.shell.appOpen, false)
        }

        function test_overlays_above_app_layer() {
            const layer = find("appLayer")
            verify(layer.z < find("toastLayer").z, "toasts above the app layer")
            verify(layer.z < find("modalLayer").z, "modals above the app layer")
            verify(layer.z < find("systemPanel").z, "the Guide overlay above the app layer")
            verify(layer.z < find("volumeOsd").z, "the volume OSD above the app layer")
            verify(layer.z > find("pageHost").z, "the app layer above the pages")
            compare(tc.app.parent, layer)
        }
    }
}
