import QtQuick
import QtTest
import RuyaShell

// Every item that can hold focus has an accessible name (04 section 7), so the Orca spike starts
// from a clean base. Each test walks a focus chain with controller keys only and checks the
// focused item after every step. Mock profiles: p1 "Player One" (PIN 1234), p2 "Ada", p3 "Guest".
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
        name: "Accessibility"
        when: windowShown

        property Item shell: null
        property var seen: []           // "objectName: name" of every focused item visited

        function find(name) { return findChild(tc.shell, name) }
        function focused() { return tc.shell.Window.window.activeFocusItem }

        function describe(item) {
            return (item.objectName || String(item)) + " [" + item.Accessible.role + "]"
        }

        // The focused item must carry a name; remember it for the coverage checks.
        function checkFocused(where) {
            const item = focused()
            verify(item !== null, where + ": nothing has focus")
            verify(item.Accessible.name.length > 0,
                   where + ": focused item without Accessible.name: " + describe(item))
            seen.push(item.objectName + ": " + item.Accessible.name)
        }

        // Press `key` up to `max` times, checking the focused item after each press, until it
        // stops changing.
        function walk(key, max, where) {
            checkFocused(where + " (start)")
            for (let i = 0; i < max; ++i) {
                const before = focused()
                keyClick(key)
                checkFocused(where + " step " + i)
                if (focused() === before && key !== Qt.Key_Right && key !== Qt.Key_Down)
                    break
            }
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.seen = []
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
        }

        function signInAsAda() {
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function test_picker() {
            walk(Qt.Key_Right, 4, "picker")
            walk(Qt.Key_Left, 4, "picker back")
            // The PIN pad of Player One.
            keyClick(Qt.Key_Return)
            tryVerify(() => find("pinPad").shown)
            tryVerify(() => find("pinKeys").activeFocus)
            walk(Qt.Key_Right, 3, "pin row")
            walk(Qt.Key_Down, 4, "pin column")
            keyClick(Qt.Key_Escape)
        }

        function test_home() {
            signInAsAda()
            checkFocused("Play")
            keyClick(Qt.Key_Right)
            checkFocused("Details")
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Down)                        // the shelf
            walk(Qt.Key_Right, 4, "shelf")
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Up)                          // the section nav
            walk(Qt.Key_Right, 5, "section nav")
        }

        function test_settings_every_pane() {
            signInAsAda()
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Up)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus, 2000, "category list has focus")
            checkFocused("category list")
            let paneCount = 0
            for (let c = 0; c < list.count; ++c) {
                for (let i = 0; i < 20 && list.currentIndex < c; ++i)
                    keyClick(Qt.Key_Down)
                compare(list.currentIndex, c)
                checkFocused("category " + c)
                keyClick(Qt.Key_Right)                   // into the pane, if the category has one
                if (list.activeFocus)
                    continue
                paneCount += 1
                walk(Qt.Key_Down, 14, "pane " + c)
                keyClick(Qt.Key_Escape)
                tryVerify(() => list.activeFocus, 2000, "pane " + c + " returns to the categories")
            }
            compare(paneCount, 8, "every category but Accessibility has a pane")
        }

        function test_guide_overlay() {
            signInAsAda()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            walk(Qt.Key_Down, 6, "guide")
            walk(Qt.Key_Right, 6, "guide")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("homePlay").activeFocus)
        }
    }
}
