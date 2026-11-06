import QtQuick
import QtTest
import RuyaShell

// The gliding highlight in the Settings category list (04 §3.8, T-205): its goal is the focused
// category row, it scrolls with the rows, focus and the accessible name stay on the list and its
// rows, and the pane focus hides it. Signs in as "Ada" (p2, no PIN).
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
        name: "GlideSettings"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
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
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            keyClick(Qt.Key_Up)
            const nav = find("sectionNav")
            tryVerify(() => nav.activeFocus)
            for (let i = 0; i < nav.keys.indexOf("settings"); ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Settings opens on the category list")
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
        }

        function test_highlight_follows_the_focused_category() {
            const list = find("categoryList")
            const glide = find("categoryGlide")
            tryVerify(() => glide.active)
            compare(list.currentIndex, 0)
            compare(glide.activeFocus, false, "the highlight never has focus")
            for (let i = 0; i < 8; ++i) {
                const row = list.currentItem
                compare(glide.targetY, row.y, "goal is the focused row, row " + list.currentIndex)
                compare(glide.targetX, row.x)
                compare(glide.targetWidth, row.width)
                compare(glide.targetHeight, row.height)
                compare(list.activeFocus, true)
                compare(glide.activeFocus, false)
                compare(list.Accessible.name, row.Accessible.name, "the screen reader names the focused row")
                keyClick(Qt.Key_Down)
            }
            compare(list.currentIndex, 8)
            compare(glide.targetY, list.currentItem.y, "also after the list scrolled ")
            tryCompare(glide, "y", glide.targetY)
        }

        function test_rows_keep_their_ring_and_hide_their_fill_under_the_highlight() {
            const glide = find("categoryGlide")
            tryVerify(() => glide.active)
            const row = find("category_profiles")
            tryVerify(() => row.color.a === 0)
            compare(row.border.width > 0, true, "the ring stays on the row")
            compare(Qt.colorEqual(row.border.color, Theme.focusRing), true)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("category_network").border.width > 0)
            compare(find("category_network").color.a, 0)
        }

        function test_highlight_hides_while_the_pane_has_focus() {
            const list = find("categoryList")
            const glide = find("categoryGlide")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            compare(list.currentIndex, 2)
            tryVerify(() => glide.active)
            keyClick(Qt.Key_Right)                         // into the Bluetooth pane
            tryCompare(list, "activeFocus", false)
            compare(glide.active, false)
            const row = find("category_bluetooth")
            tryVerify(() => Qt.colorEqual(row.color, Theme.selectedFill), 2000, "the chosen row shows the selected fill")
            keyClick(Qt.Key_Left)
            tryVerify(() => list.activeFocus)
            tryVerify(() => glide.active)
            compare(list.currentIndex, 2)
            tryCompare(glide, "y", glide.targetY)
        }

        function test_highlight_snaps_under_reduced_motion() {
            DeviceSettings.reducedMotion = true
            const glide = find("categoryGlide")
            tryVerify(() => glide.active)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            compare(glide.y, glide.targetY)
            compare(glide.gliding, false)
        }

        function test_zz_screenshots_settings_glide() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            const glide = find("categoryGlide")
            tryVerify(() => glide.active && !glide.gliding)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/glide-settings-rest.png")
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => glide.gliding && glide.y > glide.targetY - glide.targetHeight * 1.5, 2000)
            wait(0)
            grabImage(tc.shell).save(shotsDir + "/glide-settings-mid.png")
            tryVerify(() => !glide.gliding, 2000)
        }
    }
}
