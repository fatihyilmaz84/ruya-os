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

        property Shell shell: null
        property var seen: []           // "objectName: name" of every focused item visited

        function find(name) { return findChild(tc.shell, name) }
        function focused() { return tc.shell.Window.window.activeFocusItem }

        function describe(item) {
            return (item.objectName || String(item)) + " [" + item.Accessible.role + "]"
        }

        // The focused item must carry a name and a role (T-189: describe() prints the role, but
        // nothing asserted it); remember it for the coverage checks.
        function checkFocused(where) {
            const item = focused()
            verify(item !== null, where + ": nothing has focus")
            verify(item.Accessible.name.length > 0,
                   where + ": focused item without Accessible.name: " + describe(item))
            verify(item.Accessible.role !== Accessible.NoRole,
                   where + ": focused item without Accessible.role: " + describe(item))
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
            verify(seen.indexOf("powerCancel: Cancel") >= 0 && seen.indexOf("powerConfirm: Restart now") >= 0,
                   "both buttons are named: " + seen)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Return)                      // Cancel
            tryVerify(() => !find("powerConfirmDialog").shown)
        }

        // The Confirm button is named after the action, never the bare word "Confirm" (T-186).
        function test_power_confirm_names_follow_the_action() {
            signInAsAda()
            tc.shell.openPage("power")
            tryCompare(tc.shell, "currentPage", "power")
            tryVerify(() => find("powerSuspend") && find("powerSuspend").activeFocus, 2000)
            const expected = [["suspend", "powerSuspend", "Suspend now"],
                              ["restart", "powerRestart", "Restart now"],
                              ["poweroff", "powerOff", "Power off now"]]
            const dialog = find("powerConfirmDialog")
            for (const [action, row, name] of expected) {
                for (let i = 0; i < 4 && !find(row).activeFocus; ++i)
                    keyClick(Qt.Key_Down)
                tryVerify(() => find(row).activeFocus, 2000, row + " has focus")
                keyClick(Qt.Key_Return)
                tryVerify(() => dialog.shown, 2000, action + ": the dialog opens")
                tryVerify(() => find("powerCancel").activeFocus, 2000, action + ": Cancel has focus")
                compare(dialog.action, action)
                keyClick(Qt.Key_Right)
                tryVerify(() => find("powerConfirm").activeFocus, 2000, action + ": Confirm has focus")
                compare(focused().Accessible.name, name, action)
                compare(findChild(dialog, "powerConfirmLabel").text, name, action + ": the visible label is the name (T-194)")
                verify(focused().Accessible.name !== "Confirm", action + ": not the bare word Confirm")
                compare(find("powerCancel").Accessible.name, "Cancel")
                keyClick(Qt.Key_Escape)                  // Back cancels: nothing powers off
                tryVerify(() => !dialog.shown, 2000, action + ": the dialog closes")
            }
        }

        // Resets to a console without profiles and walks the wizard to the name and PIN step.
        function startWizardAtNameStep() {
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
            tryVerify(() => find("setupZoneRegions").activeFocus)
            checkFocused("setup time zone")
            compare(focused().objectName, "setupZoneRegion_Europe", "the current region row has focus")
            compare(focused().Accessible.name, "Europe")
            keyClick(Qt.Key_Menu)                      // Start skips the time zone
            tryCompare(setup, "step", 3)
            checkFocused("setup network")
            compare(focused().Accessible.name, "Network")
            keyClick(Qt.Key_Return)
            tryCompare(setup, "step", 4)
            tryVerify(() => find("setupNameRow").activeFocus)
            checkFocused("setup name")
            return setup
        }

        // The wizard's create-name-and-PIN step: its two rows, the name keyboard and the PIN pad.
        function test_setup_wizard_create_step() {
            startWizardAtNameStep()
            compare(focused().Accessible.name, "Name, Not set")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("setupCreateRow").activeFocus)
            checkFocused("setup create row")
            compare(focused().Accessible.name, "Choose a PIN and finish")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("setupNameRow").activeFocus)

            // The name keyboard: its name follows the focused key.
            keyClick(Qt.Key_Return)
            const entry = find("setupNameEntry")
            tryVerify(() => entry.shown && entry.activeFocus, 2000, "the keyboard opens with focus")
            verifyNamesChange(namesAlong(Qt.Key_Right, 4, "wizard keyboard"), "wizard keyboard")
            keyClick(Qt.Key_Down)
            checkFocused("wizard keyboard, next row")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !entry.shown && find("setupNameRow").activeFocus, 2000, "Cancel gives focus back")

            // The PIN pad needs a name first.
            entry.accepted("Zed")
            tryVerify(() => find("setupCreateRow").activeFocus, 2000, "an accepted name moves to Create")
            checkFocused("wizard create row after the name")
            keyClick(Qt.Key_Return)
            const pad = find("setupPinPad")
            tryVerify(() => pad.shown, 2000, "the PIN pad opens")
            tryVerify(() => findChild(pad, "pinKeys").activeFocus, 2000, "the keypad has focus")
            walk(Qt.Key_Right, 3, "wizard pin row")
            walk(Qt.Key_Down, 4, "wizard pin column")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !pad.shown && find("setupCreateRow").activeFocus, 2000, "the pad returns to Create")
            checkFocused("wizard create row after the pad")
            compare(Profiles.profiles.length, 0, "nothing was created")
            verify(seen.indexOf("setupNameRow: Name, Not set") >= 0, "the name row is named: " + seen)
        }

        function test_setup_wizard_steps() {
            const setup = startWizardAtNameStep()
            // The create flow (name, PIN) is test_setup_wizard_create_step; here the last step.
            setup.step = setup.stepDone
            setup.focusStep()
            tryVerify(() => !find("setupNameRow").activeFocus && setup.activeFocus)
            checkFocused("setup done")
            compare(focused().Accessible.name, "You're all set")
            verify(seen.indexOf(": Setup") < 0, "no step is just 'Setup': " + seen)
        }

        function signInAsAdmin() {
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function openProfilesPane() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList") && find("categoryList").activeFocus, 2000)
            compare(find("categoryList").currentIndex, 0, "Profiles is the first category")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneProfiles").activeFocus, 2000, "the pane has focus")
            tryVerify(() => find("paneProfiles").focusableRows().some(r => r.activeFocus), 2000)
        }

        function goToRow(name, key) {
            for (let i = 0; i < 20 && !(find(name) && find(name).activeFocus); ++i) {
                keyClick(key ?? Qt.Key_Down)
                checkFocused("on the way to " + name)
            }
            tryVerify(() => find(name) && find(name).activeFocus, 2000, "reached " + name)
        }

        // A PIN pad opened by the Profiles pane: walk its keys, then Back closes it.
        function walkProfilesPad(where) {
            const pad = find("profilesPinPad")
            tryVerify(() => pad.shown, 2000, where + ": the PIN pad opens")
            tryVerify(() => findChild(pad, "pinKeys").activeFocus, 2000, where + ": the keypad has focus")
            walk(Qt.Key_Right, 3, where + " pin row")
            walk(Qt.Key_Down, 4, where + " pin column")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !pad.shown, 2000, where + ": the pad closes")
        }

        // Settings -> Profiles as an admin: Add profile with its form, the name keyboard and the PIN pad.
        function test_profiles_add_flow() {
            signInAsAdmin()
            openProfilesPane()
            goToRow("rowAdd")
            checkFocused("profiles add row")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("rowNewName").activeFocus, 2000, "the form opens on the name row")
            checkFocused("add form name")
            compare(focused().Accessible.name, "Name, Not set")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowNewRole").activeFocus)
            checkFocused("add form role")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowNewPin").activeFocus)
            checkFocused("add form PIN toggle")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowCreate").activeFocus)
            checkFocused("add form create")
            verify(seen.indexOf("rowNewRole: Role, Standard") >= 0, "the role row names its value: " + seen)
            verify(seen.indexOf("rowCreate: Create profile") >= 0, "Create is named: " + seen)

            // The name keyboard.
            goToRow("rowNewName", Qt.Key_Up)
            keyClick(Qt.Key_Return)
            const entry = find("profileNameEntry")
            tryVerify(() => entry.shown && entry.activeFocus, 2000, "the keyboard opens with focus")
            verifyNamesChange(namesAlong(Qt.Key_Right, 4, "add keyboard"), "add keyboard")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("rowNewName").activeFocus, 2000, "Cancel gives focus back")

            // The admin PIN pad, reached through Create (a name is set so Create goes ahead).
            entry.accepted("Kit")
            tryVerify(() => find("rowNewName").activeFocus, 2000)
            goToRow("rowCreate")
            keyClick(Qt.Key_Return)
            walkProfilesPad("add profile")
            tryVerify(() => find("rowCreate").activeFocus, 2000, "focus returns to Create")
            checkFocused("add form create after the pad")
            walk(Qt.Key_Down, 8, "rows below the form")
            compare(Profiles.profiles.length, 3, "nothing was created")
        }

        // Settings -> Profiles as an admin: select a profile, Rename (keyboard) and Delete (confirmation, PIN pad).
        function test_profiles_manage_flow() {
            signInAsAdmin()
            openProfilesPane()
            const row = find("profileRow_p2")
            verify(row, "Ada is listed")
            for (let i = 0; i < 8 && !row.activeFocus; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => row.activeFocus, 2000, "the Ada row has focus")
            checkFocused("profile row")
            compare(focused().Accessible.name.indexOf("Ada"), 0, "the row starts with the profile name")
            keyClick(Qt.Key_Return)                      // select: Rename and Delete appear
            tryVerify(() => find("rowRename").activeFocus, 2000, "Rename takes focus")
            checkFocused("manage rename")
            compare(focused().Accessible.name, "Rename Ada")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowDelete").activeFocus)
            checkFocused("manage delete")
            compare(focused().Accessible.name, "Delete Ada")

            // Rename: the keyboard.
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Return)
            const entry = find("profileRenameEntry")
            tryVerify(() => entry.shown && entry.activeFocus, 2000, "the rename keyboard opens")
            verifyNamesChange(namesAlong(Qt.Key_Right, 4, "rename keyboard"), "rename keyboard")
            // Back deletes a letter of "Ada" first and cancels once the field is empty.
            for (let i = 0; i < 4 && entry.shown; ++i)
                keyClick(Qt.Key_Escape)
            tryVerify(() => find("rowRename").activeFocus, 2000, "Cancel gives focus back: " + describe(focused()))

            // Delete: the confirmation names its action, then the admin PIN pad.
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowDelete").activeFocus)
            keyClick(Qt.Key_Return)
            const confirm = find("profileDeleteConfirm")
            tryVerify(() => confirm.shown, 2000, "the delete confirmation opens")
            const cancel = findChild(confirm, "powerCancel")
            tryVerify(() => cancel.activeFocus, 2000, "Cancel has focus")
            checkFocused("delete cancel")
            compare(focused().Accessible.name, "Cancel")
            keyClick(Qt.Key_Right)
            const ok = findChild(confirm, "powerConfirm")
            tryVerify(() => ok.activeFocus, 2000, "Confirm has focus")
            checkFocused("delete confirm")
            compare(focused().Accessible.name, "Delete Ada")
            compare(findChild(confirm, "powerConfirmLabel").text, "Delete Ada", "the visible label is the name (T-194)")
            keyClick(Qt.Key_Return)
            walkProfilesPad("delete profile")
            tryVerify(() => find("rowDelete").activeFocus, 2000, "focus returns to Delete")
            checkFocused("manage delete after the pad")
            compare(Profiles.profiles.length, 3, "nothing was deleted")
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
