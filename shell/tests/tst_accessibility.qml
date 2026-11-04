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

        // Presses `key` `count` times and returns the name of the focused item before the first
        // press and after each one. Every name must be non-empty.
        function namesAlong(key, count, where) {
            checkFocused(where + " (start)")
            const names = [focused().Accessible.name]
            for (let i = 0; i < count; ++i) {
                keyClick(key)
                checkFocused(where + " step " + i)
                names.push(focused().Accessible.name)
            }
            return names
        }

        // For a list, a grid or the keyboard the name must follow the index.
        function verifyNamesChange(names, where) {
            const distinct = names.filter((n, i) => names.indexOf(n) === i)
            verify(distinct.length >= 3, where + ": the name must follow the index, got " + JSON.stringify(names))
        }

        function openStore() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            compare(find("sectionNav").currentKey, "store")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "store")
            tryVerify(() => find("storeCards_featured") && find("storeCards_featured").activeFocus, 2000,
                      "first card of Featured has focus")
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

        // The walks above reset the mocks to empty; leave them seeded for whoever runs next.
        function cleanup() {
            Profiles.resetMockForTests("seeded")
            Library.resetMockForTests("")
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
            // A profile with a PIN says so; one without does not.
            verify(seen.indexOf(": Player One, PIN protected") >= 0, "Player One is PIN protected: " + seen)
            verify(seen.indexOf(": Ada") >= 0, "Ada has no PIN: " + seen)
            verify(seen.indexOf(": Guest") >= 0, "Guest has no PIN: " + seen)
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
            // The nav is one focus item: its name must follow the current pill.
            verify(seen.indexOf("sectionNav: Games") >= 0, "nav names Games: " + seen)
            verify(seen.indexOf("sectionNav: Settings") >= 0, "nav names Settings: " + seen)
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

        function test_games_grid() {
            Library.resetMockForTests("")
            signInAsAda()
            tryVerify(() => Library.items.length === 10)
            keyClick(Qt.Key_Up)                          // the section nav
            keyClick(Qt.Key_Right)
            compare(find("sectionNav").currentKey, "games")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "games")
            const grid = find("gamesGrid")
            tryVerify(() => grid.activeFocus, 2000, "the grid has focus")
            verifyNamesChange(namesAlong(Qt.Key_Right, 3, "games grid"), "games grid")
            keyClick(Qt.Key_Down)
            checkFocused("games grid, next row")
            for (let i = 0; i < 4 && !find("gamesFilter").activeFocus; ++i)
                keyClick(Qt.Key_Up)
            tryVerify(() => find("gamesFilter").activeFocus, 2000, "Up reaches the filter")
            checkFocused("games filter")
            keyClick(Qt.Key_Right)
            checkFocused("games filter, Steam")
        }

        function test_games_empty() {
            Library.resetMockForTests("empty")
            signInAsAda()
            tryVerify(() => Library.items.length === 0)
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "games")
            tryVerify(() => find("gamesOpenStore").activeFocus, 2000, "the empty page offers the Store")
            checkFocused("games empty")
        }

        function test_store_and_app_detail() {
            signInAsAda()
            openStore()
            verifyNamesChange(namesAlong(Qt.Key_Right, 3, "featured row"), "featured row")
            // Down through the rows: each focused list names its current card.
            for (let i = 0; i < 3; ++i) {
                keyClick(Qt.Key_Down)
                checkFocused("store row below " + i)
            }
            for (let i = 0; i < 8 && !find("storeSearch").activeFocus; ++i)
                keyClick(Qt.Key_Up)
            tryVerify(() => find("storeSearch").activeFocus, 2000, "Up reaches the toolbar")
            checkFocused("store search")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("storeShowAll").activeFocus)
            checkFocused("store show all")
            keyClick(Qt.Key_Left)

            // The keyboard: the dialog's name carries the focused key, so it changes with every move.
            keyClick(Qt.Key_Return)
            const entry = find("storeSearchEntry")
            tryVerify(() => entry.visible && entry.activeFocus, 2000, "the keyboard opens with focus")
            verifyNamesChange(namesAlong(Qt.Key_Right, 4, "keyboard keys"), "keyboard keys")
            keyClick(Qt.Key_Down)
            checkFocused("keyboard, next row")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("storeSearch").activeFocus, 2000, "Cancel gives focus back")

            // Results: the name follows the index. Typing is tst_textentry's job.
            entry.accepted("a")
            const results = find("storeResults")
            tryVerify(() => results.visible && results.model.length >= 3, 2000, "several results")
            tryVerify(() => results.activeFocus, 2000)
            verifyNamesChange(namesAlong(Qt.Key_Right, 3, "store results"), "store results")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("storeRows").visible)
            tryVerify(() => find("storeCards_featured").activeFocus, 2000)

            // The detail page.
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
            tryCompare(find("page_appDetail"), "detailsReady", true)
            checkFocused("detail primary")
            for (let i = 0; i < 4; ++i) {
                keyClick(i % 2 === 0 ? Qt.Key_Down : Qt.Key_Right)
                checkFocused("detail step " + i)
            }
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "store")
        }

        function test_power_confirm_buttons() {
            signInAsAda()
            tc.shell.openPage("power")
            tryCompare(tc.shell, "currentPage", "power")
            tryVerify(() => find("powerSuspend") && find("powerSuspend").activeFocus, 2000)
            checkFocused("power suspend")
            keyClick(Qt.Key_Down)
            checkFocused("power restart")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("powerConfirmDialog").shown)
            tryVerify(() => find("powerCancel").activeFocus, 2000, "Cancel has focus")
            checkFocused("power Cancel")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("powerConfirm").activeFocus, 2000, "Confirm has focus")
            checkFocused("power Confirm")
            verify(seen.indexOf("powerCancel: Cancel") >= 0 && seen.indexOf("powerConfirm: Confirm") >= 0,
                   "both buttons are named: " + seen)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Return)                      // Cancel
            tryVerify(() => !find("powerConfirmDialog").shown)
        }

        function test_setup_wizard_steps() {
            Profiles.resetMockForTests("empty")
            tryVerify(() => Profiles.profiles.length === 0)
            tc.shell.destroy()
            tc.shell = createTemporaryObject(shellComponent, host)
            tc.shell.forceActiveFocus()
            const setup = find("setup")
            tryVerify(() => setup.visible && setup.activeFocus, 2000, "the wizard has focus")
            checkFocused("setup welcome")
            compare(focused().Accessible.name, "Welcome to RuyaOS")
            keyClick(Qt.Key_Return)
            tryCompare(setup, "step", 1)
            tryVerify(() => find("setupLanguageRow").activeFocus)
            checkFocused("setup language")
            keyClick(Qt.Key_Return)
            tryCompare(setup, "step", 2)
            checkFocused("setup network")
            compare(focused().Accessible.name, "Network")
            keyClick(Qt.Key_Return)
            tryCompare(setup, "step", 3)
            tryVerify(() => find("setupNameRow").activeFocus)
            checkFocused("setup name")
            // The create flow (name, PIN) is tst_setup's; here only the last step is named.
            setup.step = 4
            setup.focusStep()
            tryVerify(() => !find("setupNameRow").activeFocus && setup.activeFocus)
            checkFocused("setup done")
            compare(focused().Accessible.name, "You're all set")
            verify(seen.indexOf(": Setup") < 0, "no step is just 'Setup': " + seen)
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
