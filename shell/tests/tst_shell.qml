import QtQuick
import QtTest
import RuyaShell

// End-to-end focus and sign-in flows, driven only by the keys a controller produces
// (arrows, Return = Accept, Escape = Back, HomePage = Guide) unless stated otherwise.
// Mock profiles: p1 "Player One" (PIN 1234), p2 "Ada" (no PIN), p3 "Guest".
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    Component {
        id: appComponent
        Item { objectName: "standInApp" }
    }

    TestCase {
        id: tc
        name: "Shell"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function typePin(pin) {
            for (const digit of pin)
                keyClick(digit)
        }

        function signInAsAda() {
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
        }

        function test_profiles_are_listed() {
            compare(find("profileList").count, 3)
            compare(find("profileList").currentIndex, 0)
        }

        function test_profile_without_pin_signs_in() {
            signInAsAda()
            compare(find("activeProfileName").text, "Ada")
            tryVerify(() => !find("profilePicker").visible, 2000, "picker fades out")
        }

        function test_pin_with_keyboard() {
            keyClick(Qt.Key_Return)                    // Player One has a PIN
            tryVerify(() => find("pinPad").shown)
            typePin("1234")
            keyClick(Qt.Key_Enter)                     // keypad Enter submits
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => find("homePlay").activeFocus)
        }

        function test_pin_with_dpad_only() {
            keyClick(Qt.Key_Return)
            tryVerify(() => find("pinPad").shown)
            const keys = find("pinKeys")
            tryVerify(() => keys.activeFocus)
            // Keypad layout: 1 2 3 / 4 5 6 / 7 8 9 / Del 0 OK. Focus starts on "1".
            keyClick(Qt.Key_Return)                                  // 1
            keyClick(Qt.Key_Right); keyClick(Qt.Key_Return)          // 2
            keyClick(Qt.Key_Right); keyClick(Qt.Key_Return)          // 3
            keyClick(Qt.Key_Down); keyClick(Qt.Key_Left); keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Return)                                  // 4
            compare(find("pinPad").entered, "1234")
            keyClick(Qt.Key_Down); keyClick(Qt.Key_Down)             // -> Del
            keyClick(Qt.Key_Right); keyClick(Qt.Key_Right)           // -> OK
            compare(keys.currentIndex, 11)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => find("homePlay").activeFocus, 2000, "home takes focus after PIN sign-in")
        }

        function test_back_edits_then_closes_pin_pad() {
            keyClick(Qt.Key_Return)
            tryVerify(() => find("pinPad").shown)
            typePin("12")
            keyClick(Qt.Key_Escape)
            compare(find("pinPad").entered, "1")
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("pinPad").shown)
            tryVerify(() => find("profileList").activeFocus, 2000, "focus returns to the picker")
            compare(Profiles.activeProfile, "")
        }

        function test_pin_pad_is_modal() {
            keyClick(Qt.Key_Return)
            tryVerify(() => find("pinPad").shown)
            keyClick(Qt.Key_Right)   // moves on the keypad, not the profile list underneath
            compare(find("profileList").currentIndex, 0)
            compare(find("pinKeys").currentIndex, 1)
        }

        function test_super_toggles_overlay_data() {
            return [
                { tag: "Super_L", key: Qt.Key_Super_L },
                { tag: "Super_R", key: Qt.Key_Super_R },
                { tag: "Meta", key: Qt.Key_Meta },        // the Windows key on the Windows host
            ]
        }

        function test_super_toggles_overlay(data) {
            signInAsAda()
            keyClick(data.key)
            tryVerify(() => find("systemActions").activeFocus, 2000, "Super opens the overlay")
            keyClick(Qt.Key_Right)                     // modal: swallowed
            verify(!find("homeDetails").activeFocus, "the key did not reach Home")
            keyClick(data.key)
            tryCompare(find("systemPanel"), "open", false)
            tryVerify(() => find("homePlay").activeFocus, 2000, "and closes it again, focus back on the shelf")
        }

        function test_menu_is_not_guide() {
            signInAsAda()
            keyClick(Qt.Key_Menu)                      // the context-menu key (T-124)
            wait(200)
            compare(find("systemPanel").open, false)
            verify(find("homePlay").activeFocus)
            keyClick(Qt.Key_HomePage)                  // Guide still opens it
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_Menu)                      // and Menu does not close it
            wait(200)
            compare(find("systemPanel").open, true)
            keyClick(Qt.Key_HomePage)
            tryCompare(find("systemPanel"), "open", false)
        }

        function test_guide_overlay_and_switch_profile() {
            signInAsAda()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_Right)                     // swallowed by the modal overlay
            verify(!find("homeDetails").activeFocus, "the key did not reach Home")
            keyClick(Qt.Key_Escape)                    // Back closes it
            tryVerify(() => find("homePlay").activeFocus)

            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_Return)                    // "Switch profile"
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => find("profileList").activeFocus, 2000, "picker regains focus after lock")
        }

        // T-293: the drift of the animated backdrop costs frames; with an app in front nobody sees it.
        function test_backdrop_stops_while_app_focused() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            signInAsAda()
            const backdrop = find("backdrop")
            tryVerify(() => backdrop.drifting, 2000, "the blobs drift on Home")
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app)
            tryCompare(backdrop, "drifting", false)
            tc.shell.removeApp(app)
            tryCompare(backdrop, "drifting", true)
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            wait(400)
            grabImage(tc.shell).save(shotsDir + "/1-picker.png")
            keyClick(Qt.Key_Return)
            typePin("12")
            wait(400)
            grabImage(tc.shell).save(shotsDir + "/2-pin.png")
            typePin("34")
            keyClick(Qt.Key_Enter)
            tryCompare(Profiles, "activeProfile", "p1")
            keyClick(Qt.Key_Right)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/3-home.png")
            keyClick(Qt.Key_HomePage)
            wait(400)
            grabImage(tc.shell).save(shotsDir + "/4-overlay.png")
        }
    }
}
