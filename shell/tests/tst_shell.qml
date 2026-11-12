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

        // Down until the Quick Hub's row `key` has the focus (T-448: the rows above it depend on the
        // library, the tiles and the recent games).
        function hubGoTo(key) {
            const menu = find("systemPanel")
            const list = find("systemActions")
            if (key === "switch" && !menu.powerMode) {
                // Switch profile is the last choice of the Power panel (T-471)
                hubGoTo("panel:power")
                keyClick(Qt.Key_Return)
                tryCompare(menu, "powerMode", true)
            }
            // Up/Down to the control's row, then Left/Right along it (T-471: a row may hold several controls).
            for (let i = 0; i < 30 && menu.currentKey !== key; ++i)
                keyClick(menu.itemKeys.indexOf(menu.rowKeyOf(key)) > list.currentIndex ? Qt.Key_Down
                         : menu.itemKeys.indexOf(menu.rowKeyOf(key)) < list.currentIndex ? Qt.Key_Up
                         : menu.columnOf(key) > menu.currentColumn ? Qt.Key_Right : Qt.Key_Left)
            compare(menu.currentKey, key)
        }

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

        // T-301: a Bluetooth keyboard that connects is announced like a pad, with the keyboard glyph; a mouse
        // is not, nor is a keyboard that leaves.
        function test_keyboard_connect_toast() {
            signInAsAda()
            Bluetooth.mockPopulate()
            tryVerify(() => Bluetooth.devices.find(d => d.id === "bt-gallery-keyboard") !== undefined, 2000)
            const toasts = find("toastLayer").controllerToasts
            toasts.debounceMs = 40
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
            Bluetooth.disconnectDevice("bt-gallery-keyboard")
            tryVerify(() => Bluetooth.devices.find(d => d.id === "bt-gallery-keyboard").connected === false, 2000)
            Bluetooth.disconnectDevice("bt-gallery-mouse")
            tryVerify(() => Bluetooth.devices.find(d => d.id === "bt-gallery-mouse").connected === false, 2000)
            wait(150)
            compare(Notifications.model.count, 0, "leaving says nothing")
            Bluetooth.connectDevice("bt-gallery-mouse")
            Bluetooth.connectDevice("bt-gallery-keyboard")
            tryCompare(Notifications.model, "count", 1)
            compare(Notifications.model.get(0).text, "Living Room Keyboard connected")
            compare(Notifications.model.get(0).iconName, DeviceIcons.iconFor("keyboard", ""))
            compare(Notifications.model.get(0).iconName, "keyboard")
            compare(Notifications.model.get(0).kind, "success")
            wait(150)
            compare(Notifications.model.count, 1, "the mouse said nothing, the keyboard once")
            // Gone and back is news again.
            Bluetooth.disconnectDevice("bt-gallery-keyboard")
            tryVerify(() => Bluetooth.devices.find(d => d.id === "bt-gallery-keyboard").connected === false, 2000)
            Bluetooth.connectDevice("bt-gallery-keyboard")
            tryCompare(Notifications.model, "count", 2)
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
            hubGoTo("switch")
            keyClick(Qt.Key_Return)                    // "Switch profile"
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => find("profileList").activeFocus, 2000, "picker regains focus after lock")
        }

        // Home -> Settings with the controller keys.
        function openSettings() {
            keyClick(Qt.Key_Up)                        // the section nav
            tryVerify(() => find("sectionNav").activeFocus, 2000, "the section nav has focus")
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("page_settings") !== null && find("page_settings").activeFocus, 2000, "Settings has focus")
        }

        // T-293: the drift of the animated backdrop costs frames; with an app in front nobody sees it.
        // Checked on a page, where the blobs are seen (on Home the hero covers them, T-421).
        function test_backdrop_stops_while_app_focused() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            signInAsAda()
            openSettings()
            const backdrop = find("backdrop")
            tryVerify(() => backdrop.drifting, 2000, "the blobs drift on a page")
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app)
            tryCompare(backdrop, "drifting", false)
            tc.shell.removeApp(app)
            tryVerify(() => find("page_settings").activeFocus, 2000, "the page has focus again")
            tryCompare(backdrop, "drifting", true)
        }

        // T-421: on Home the hero's art or colour field is opaque and covers the backdrop: the blobs rest
        // there (a still Home drew 60 frames a second for them on the Dell, about 30 % of its GPU). They
        // drift where they are seen: the profile picker and the pages.
        function test_backdrop_rests_under_the_home_hero() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            const backdrop = find("backdrop")
            tryVerify(() => backdrop.drifting, 2000, "the blobs drift on the profile picker")
            signInAsAda()
            const hero = find("heroArt")
            // tryCompare is fuzzy (0.99999 passes) while covers needs the fade's exact end: wait on covers itself.
            tryVerify(() => hero.covers, 2000, "the hero covers the backdrop")
            tryCompare(backdrop, "paused", true)
            tryCompare(backdrop, "drifting", false, 2000, "the blobs rest under the hero")
            openSettings()
            tryCompare(backdrop, "drifting", true, 2000, "they drift again on a page")
            keyClick(Qt.Key_Escape)                    // list -> Home
            tryVerify(() => find("sectionNav").activeFocus, 2000, "focus back on the section nav")
            tryCompare(backdrop, "drifting", false, 2000, "and rest again on Home")
        }

        // T-434: the page blur's texture is re-rendered only while the blurred copy shows: on the profile
        // picker and on Home the drifting blobs do not redraw it every frame.
        function test_page_blur_texture_is_idle_off_pages() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            const backdrop = find("backdrop")
            tryVerify(() => backdrop.drifting, 2000, "the blobs drift on the profile picker")
            verify(find("profileList").activeFocus, "the picker has focus")
            const reduced = find("backdropReduced")
            verify(reduced !== null, "the blurred copy is ready")
            compare(reduced.live, false, "its texture is idle on the picker")
            compare(find("backdropBlur").visible, false)
            signInAsAda()
            openSettings()
            tryVerify(() => reduced.live, 2000, "live on a page")
            tryCompare(find("backdropBlur"), "opacity", 1)
            keyClick(Qt.Key_Escape)                    // list -> Home
            tryVerify(() => find("sectionNav").activeFocus, 2000, "focus back on the section nav")
            tryVerify(() => find("backdropBlur").opacity === 0, 2000, "the copy fades out")
            tryCompare(reduced, "live", false, 2000, "and its texture is idle again on Home")
        }

        // T-421: where the blobs are seen they still rest once nobody has touched anything for the idle
        // period (LiquidGate, as the liquid pill's specular): a still page drew 60 frames a second for
        // them. The next key brings the drift back.
        function test_backdrop_rests_when_idle_and_drifts_on_input() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            signInAsAda()
            openSettings()
            const backdrop = find("backdrop")
            tryVerify(() => backdrop.drifting, 2000, "the blobs drift on a page")
            LiquidGate.idleMs = 150
            LiquidGate.noteInput()
            tryCompare(LiquidGate, "idle", true, 2000, "no input for the idle period")
            tryCompare(backdrop, "drifting", false, 2000, "the blobs rest")
            keyClick(Qt.Key_Down)                      // the next category
            compare(LiquidGate.idle, false, "a key is input")
            tryCompare(backdrop, "drifting", true, 2000, "the blobs drift again")
            verify(find("categoryList").activeFocus, "the key moved within the category list")
            LiquidGate.reset()
        }

        function cleanup() {
            LiquidGate.reset()
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
