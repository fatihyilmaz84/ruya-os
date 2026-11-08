import QtQuick
import QtTest
import RuyaShell

// Managing profiles: the mock must reject exactly what ruya-profiles (service.rs) rejects,
// and Settings -> Profiles must drive CreateProfile / SetPin with controller keys only
// (arrows, Return = Accept, Escape = Back). Own file: it creates profiles and PINs, and
// each file gets a fresh mock; the mock is also reset before every test.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: createSpy; target: Profiles; signalName: "createFinished" }
    SignalSpy { id: pinSpy; target: Profiles; signalName: "setPinFinished" }
    SignalSpy { id: renameSpy; target: Profiles; signalName: "renameFinished" }
    SignalSpy { id: deleteSpy; target: Profiles; signalName: "deleteFinished" }

    TestCase {
        id: tc
        name: "ProfileAdmin"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        property string padName: "profilesPinPad"     // the pad of the pane under test
        function padKeys() { return findChild(find(padName), "pinKeys") }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            tryCompare(Profiles, "activeProfile", "")
            createSpy.clear()
            pinSpy.clear()
            renameSpy.clear()
            deleteSpy.clear()
        }

        function rename(actorId, actorPin, id, name) {
            const before = renameSpy.count
            Profiles.renameProfile(actorId, actorPin, id, name)
            tryCompare(renameSpy, "count", before + 1)
            return renameSpy.signalArguments[before]      // [id, status, attemptsLeft, retryAfterSecs]
        }

        function remove(adminId, adminPin, id) {
            const before = deleteSpy.count
            Profiles.deleteProfile(adminId, adminPin, id)
            tryCompare(deleteSpy, "count", before + 1)
            return deleteSpy.signalArguments[before]      // [id, status, attemptsLeft, retryAfterSecs]
        }

        // ---- service-level helpers (no UI) ----

        function create(adminId, adminPin, name, role, pin) {
            const before = createSpy.count
            Profiles.createProfile(adminId, adminPin, name, role, pin)
            tryCompare(createSpy, "count", before + 1)
            return createSpy.signalArguments[before]      // [status, id, attemptsLeft, retryAfterSecs]
        }

        function changePin(id, oldPin, newPin) {
            const before = pinSpy.count
            Profiles.setPin(id, oldPin, newPin)
            tryCompare(pinSpy, "count", before + 1)
            return pinSpy.signalArguments[before]         // [id, status, attemptsLeft, retryAfterSecs]
        }

        // ---- UI helpers ----

        function startShell() {
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
        }

        function signIn(id, pin) {
            Profiles.switchTo(id, pin)
            tryCompare(Profiles, "activeProfile", id)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function openSettingsList() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList") !== null && find("categoryList").activeFocus)
            compare(find("categoryList").currentIndex, 0) // My profile
        }

        function enterPane(name) {
            keyClick(Qt.Key_Right)                        // enter the pane
            tryVerify(() => find(name).activeFocus, 2000, "pane has focus")
            tryVerify(() => find(name).focusableRows().some(r => r.activeFocus), 2000, "a row has focus")
        }

        // Settings -> Manage profiles (admins): the second category.
        function openProfilesPane() {
            openSettingsList()
            keyClick(Qt.Key_Down)
            compare(find("categoryList").currentIndex, 1)
            verify(find("paneProfiles").visible)
            tc.padName = "profilesPinPad"
            enterPane("paneProfiles")
        }

        // Settings -> My profile: the first category.
        function openMyProfilePane() {
            openSettingsList()
            verify(find("paneMyProfile").visible)
            tc.padName = "myProfilePinPad"
            enterPane("paneMyProfile")
        }

        function goToRow(name) {
            for (let i = 0; i < 20; ++i) {
                const row = find(name)
                if (row && row.activeFocus)
                    return
                keyClick(Qt.Key_Down)
            }
            fail("could not reach row " + name)
        }

        // D-pad over the PIN pad keypad (3 columns: 1-9, then Del 0 OK).
        function padPress(label) {
            const order = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "del", "0", "ok"]
            const target = order.indexOf(label)
            verify(target >= 0)
            const pad = find(padName)
            const keys = padKeys()
            verify(pad.shown, "the PIN pad is open")
            for (let step = 0; step < 12; ++step) {
                if (keys.currentIndex === target)
                    break
                const row = Math.floor(keys.currentIndex / 3)
                const targetRow = Math.floor(target / 3)
                const before = keys.currentIndex
                if (row !== targetRow)
                    keyClick(row < targetRow ? Qt.Key_Down : Qt.Key_Up)
                else
                    keyClick(keys.currentIndex % 3 < target % 3 ? Qt.Key_Right : Qt.Key_Left)
                if (keys.currentIndex === before)
                    fail("PIN pad key navigation is stuck at " + before + " going to " + label
                         + " (keys.activeFocus=" + keys.activeFocus + " stage=" + pad.stage + " mode=" + pad.mode + ")")
            }
            compare(keys.currentIndex, target)
            keyClick(Qt.Key_Return)
        }

        function enterPin(pin) {
            for (const d of pin)
                padPress(d)
            padPress("ok")
        }

        // D-pad over the on-screen keyboard.
        function keyboardGoTo(entry, value) {
            let target = null
            for (let r = 0; r < entry.rows.length && !target; ++r) {
                const c = entry.rows[r].keys.findIndex(k => k.value === value)
                if (c >= 0)
                    target = { row: r, col: c }
            }
            verify(target !== null, "keyboard has '" + value + "'")
            for (let step = 0; step < 60; ++step) {
                if (entry.focusRow === target.row && entry.focusCol === target.col)
                    return
                if (entry.focusRow !== target.row) {
                    keyClick(entry.focusRow < target.row ? Qt.Key_Down : Qt.Key_Up)
                } else {
                    const n = entry.rows[target.row].keys.length
                    const right = (target.col - entry.focusCol + n) % n
                    keyClick(right <= n - right ? Qt.Key_Right : Qt.Key_Left)
                }
            }
            fail("could not reach '" + value + "'")
        }

        function typeName(text, entryName) {
            const entry = find(entryName ?? "profileNameEntry")
            for (const ch of text) {
                if (ch !== ch.toLowerCase()) {
                    keyboardGoTo(entry, "shift")
                    keyClick(Qt.Key_Return)
                }
                keyboardGoTo(entry, ch.toLowerCase())
                keyClick(Qt.Key_Return)
            }
            keyboardGoTo(entry, "done")
            keyClick(Qt.Key_Return)
        }

        function openAddForm() {
            goToRow("rowAdd")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("rowNewName").activeFocus, 2000, "the form opens on the name row")
        }

        function nameRowValue() { return findChild(find("rowNewName"), "value").text }

        // ---- the mock follows the service rules ----

        function test_mock_rules_match_service() {
            Profiles.resetMockForTests("empty")
            tryVerify(() => Profiles.profiles.length === 0)

            // first_profile_must_be_admin_with_pin
            compare(create("", "", "Kid", "standard", "")[0], "not-allowed")
            compare(create("", "", "Admin", "admin", "")[0], "invalid")
            let r = create("", "", "Admin", "admin", "1234")
            compare(r[0], "ok")
            compare(r[1], "p1")
            tryVerify(() => Profiles.profiles.length === 1)
            compare(Profiles.profiles[0].role, "admin")
            compare(Profiles.profiles[0].hasPin, true)

            // creating_more_profiles_needs_admin_credentials
            r = create("p1", "1234", "Kid", "standard", "")
            compare(r[0], "ok")
            compare(r[1], "p2")
            compare(create("p1", "9999", "X", "standard", "")[0], "wrong-pin")
            compare(create("p2", "", "X", "standard", "")[0], "not-allowed", "a standard profile is not an admin")
            compare(create("nobody", "", "X", "standard", "")[0], "not-allowed")
            compare(create("p1", "1234", "Guest", "guest", "")[0], "ok")
            compare(create("p1", "1234", "G2", "guest", "1111")[0], "invalid", "guests never have a PIN")
            compare(create("p1", "1234", "  ", "standard", "")[0], "invalid", "blank name")
            compare(create("p1", "1234", "X", "superuser", "")[0], "invalid", "unknown role")

            // PIN and name format
            compare(create("p1", "1234", "Pin3", "standard", "123")[0], "invalid", "PIN too short")
            compare(create("p1", "1234", "Pin7", "standard", "1234567")[0], "invalid", "PIN too long")
            compare(create("p1", "1234", "PinX", "standard", "12a4")[0], "invalid", "PIN not digits")
            compare(create("p1", "1234", "A2", "admin", "")[0], "invalid", "admins need a PIN")
            compare(create("p1", "1234", "x".repeat(33), "standard", "")[0], "invalid", "name over 32 characters")
            compare(create("p1", "1234", "x".repeat(32), "standard", "")[0], "ok", "32 characters is fine")
            compare(create("p1", "1234", "Tab\there", "standard", "")[0], "invalid", "control character in the name")
            r = create("p1", "1234", "  Trim Me  ", "standard", "4321")
            compare(r[0], "ok")
            tryVerify(() => Profiles.profiles.some(p => p.name === "Trim Me" && p.hasPin))

            // ids are never reused; failed creates did not consume one
            compare(r[1], "p5")

            // wrong_pins_lead_to_lockout_shared_across_operations
            for (let left = 4; left >= 1; --left) {
                r = create("p1", "0000", "Z", "standard", "")
                compare(r[0], "wrong-pin")
                compare(r[2], left, "attempts left")
            }
            r = create("p1", "0000", "Z", "standard", "")
            compare(r[0], "locked-out")
            compare(r[3], 30)
            compare(create("p1", "1234", "Z", "standard", "")[0], "locked-out", "even the right PIN is refused")
            compare(changePin("p1", "1234", "5678")[1], "locked-out", "the counter is shared with SetPin")
        }

        function test_mock_set_pin_rules_match_service() {
            // pin_rules_for_set_pin
            compare(changePin("p1", "1234", "")[1], "invalid", "admins keep a PIN")
            compare(changePin("p1", "0000", "5678")[1], "wrong-pin")
            compare(changePin("p1", "1234", "5678")[1], "ok")
            tryVerify(() => Profiles.profiles[0].hasPin)
            compare(changePin("p2", "", "43")[1], "invalid", "PIN too short")
            compare(changePin("p3", "", "4321")[1], "invalid", "guests cannot have a PIN")
            compare(changePin("p9", "", "4321")[1], "unknown-profile")

            compare(changePin("p2", "", "4321")[1], "ok")
            tryVerify(() => Profiles.profiles[1].hasPin)
            compare(changePin("p2", "9999", "")[1], "wrong-pin", "removing needs the current PIN")
            compare(changePin("p2", "4321", "")[1], "ok")
            tryVerify(() => !Profiles.profiles[1].hasPin)
        }

        // Mirrors rename_rules, delete_rules_and_effects and the lockout tests in service.rs.
        function test_mock_lifecycle_rules_match_service() {
            // rename_rules
            for (const bad of ["", "   ", "a\tb", "x".repeat(33)])
                compare(rename("p1", "1234", "p2", bad)[1], "invalid", JSON.stringify(bad))
            compare(rename("p1", "1234", "p9", "X")[1], "unknown-profile")
            compare(rename("p2", "", "p1", "Boss")[1], "not-allowed", "a non-admin renames only itself")
            compare(rename("p9", "", "p2", "X")[1], "not-allowed")
            let r = rename("p1", "0000", "p2", "X")
            compare(r[1], "wrong-pin")
            compare(r[2], 4)
            compare(rename("p2", "", "p2", "  Ada2  ")[1], "ok")
            tryVerify(() => Profiles.profiles[1].name === "Ada2")
            compare(rename("p1", "1234", "p2", "Bo")[1], "ok")
            compare(rename("p1", "", "p1", "Root")[1], "pin-required")
            compare(rename("p1", "1234", "p1", "Root")[1], "ok")
            tryVerify(() => Profiles.profiles[0].name === "Root")

            // delete_rules_and_effects
            compare(remove("p1", "1234", "p9")[1], "unknown-profile")
            compare(remove("p2", "", "p3")[1], "not-allowed", "only admins delete")
            compare(remove("p1", "1234", "p1")[1], "not-allowed", "the last admin stays")
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            compare(remove("p1", "1234", "p2")[1], "not-allowed", "the active profile stays")
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            r = remove("p1", "0000", "p2")
            compare(r[1], "wrong-pin")
            compare(r[2], 4, "a successful check reset the counter")
            compare(remove("p1", "1234", "p2")[1], "ok")
            tryVerify(() => Profiles.profiles.length === 2)
            r = create("p1", "1234", "Again", "standard", "")
            compare(r[1], "p4", "ids are never reused")

            // a second admin can be deleted
            r = create("p1", "1234", "Admin2", "admin", "4321")
            compare(remove("p1", "1234", r[1])[1], "ok")

            // lockout is shared with the other operations
            for (let i = 0; i < 5; ++i)
                remove("p1", "0000", "p3")
            r = remove("p1", "1234", "p3")
            compare(r[1], "locked-out")
            compare(r[3], 30)
            compare(rename("p1", "1234", "p3", "X")[1], "locked-out")
        }

        // ---- Settings -> Profiles ----

        function test_add_profile_flow() {
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            tryVerify(() => find("profileRow_p1") !== null && find("profileRow_p3") !== null)

            openAddForm()
            keyClick(Qt.Key_Return)                       // name: the on-screen keyboard
            tryVerify(() => find("profileNameEntry").shown)
            typeName("Kid")
            tryVerify(() => !find("profileNameEntry").shown)
            tryVerify(() => find("rowNewName").activeFocus, 2000, "focus returns to the name row")
            compare(nameRowValue(), "Kid")

            goToRow("rowCreate")                          // Standard, no PIN: only the admin PIN is asked
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profilesPinPad").shown)
            compare(find("profilesPinPad").mode, "collect")
            enterPin("1234")

            tryVerify(() => Profiles.profiles.length === 4, 3000, "the profile was created")
            const kid = Profiles.profiles[3]
            compare(kid.name, "Kid")
            compare(kid.role, "standard")
            compare(kid.hasPin, false)
            tryVerify(() => find("profilesMessage").text.indexOf("created") >= 0)
            tryVerify(() => find("rowAdd").activeFocus, 2000, "focus lands on Add profile")
            verify(!find("rowNewName").visible, "the form closes")
            tryVerify(() => find("profileRow_p4") !== null, 2000, "and the list shows the new profile")

            Profiles.lock()                               // the picker lists 4 profiles
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => find("profileList").count === 4)
        }

        function test_add_profile_with_pin() {
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            openAddForm()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profileNameEntry").shown)
            typeName("Mia")
            goToRow("rowNewPin")
            keyClick(Qt.Key_Return)                       // protect with a PIN
            verify(find("rowNewPin").checked)
            goToRow("rowCreate")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profilesPinPad").shown)
            compare(find("profilesPinPad").mode, "collect-confirm")
            enterPin("2580")                              // new PIN, then its confirmation
            compare(find("profilesPinPad").stage, 1)
            enterPin("2580")
            tryVerify(() => find("profilesPinPad").shown && find("profilesPinPad").mode === "collect", 2000, "then the admin PIN")
            enterPin("1234")
            tryVerify(() => Profiles.profiles.length === 4, 3000)
            compare(Profiles.profiles[3].name, "Mia")
            compare(Profiles.profiles[3].hasPin, true)
            changePin("p4", "2580", "2580")               // the PIN is the one that was typed
            compare(pinSpy.signalArguments[0][1], "ok")
        }

        function test_add_profile_wrong_admin_pin() {
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            openAddForm()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profileNameEntry").shown)
            typeName("Kid")
            goToRow("rowCreate")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profilesPinPad").shown)
            enterPin("0000")
            tryVerify(() => find("profilesMessage").text.indexOf("attempt(s) left") >= 0
                            || find("profilesMessage").text.indexOf("attempt") >= 0, 3000)
            verify(find("profilesMessage").text.indexOf("4") >= 0, "4 attempts left: " + find("profilesMessage").text)
            compare(Profiles.profiles.length, 3, "nothing was created")
            tryVerify(() => find("rowCreate").activeFocus, 2000, "focus is back on the form")
            verify(find("rowNewName").visible, "the form stays open")
        }

        function test_add_profile_locked_out_message() {
            startShell()
            signIn("p1", "1234")
            for (let i = 0; i < 4; ++i)
                Profiles.switchTo("p1", "0000")           // 4 wrong PINs from elsewhere
            openProfilesPane()
            openAddForm()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profileNameEntry").shown)
            typeName("Kid")
            goToRow("rowCreate")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profilesPinPad").shown)
            enterPin("0000")                              // the 5th failure locks it
            tryVerify(() => find("profilesMessage").text.indexOf("Try again in 30") >= 0, 3000)
            compare(Profiles.profiles.length, 3)
        }

        function test_add_needs_a_name() {
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            openAddForm()
            goToRow("rowCreate")
            keyClick(Qt.Key_Return)
            verify(!find("profilesPinPad").shown, "no PIN is asked without a name")
            compare(find("profilesMessage").text, "Enter a name first.")
        }

        function test_cancel_pin_pad_aborts_the_flow() {
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            openAddForm()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profileNameEntry").shown)
            typeName("Kid")
            goToRow("rowCreate")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profilesPinPad").shown)
            keyClick(Qt.Key_Escape)                       // Back on an empty pad
            tryVerify(() => !find("profilesPinPad").shown)
            tryVerify(() => find("rowCreate").activeFocus, 2000, "focus is back on the form")
            compare(Profiles.profiles.length, 3)
            compare(createSpy.count, 0, "nothing was sent")
        }

        function test_add_hidden_for_standard() {
            startShell()
            signIn("p2", "")                              // Ada, a standard profile
            openMyProfilePane()
            verify(find("category_profiles") === null, "Manage profiles is not listed for a standard profile")
            compare(findChild(find("rowWho"), "label").text, "Ada")
            compare(findChild(find("rowWho"), "value").text, "Standard")
            verify(find("rowChangePin").visible)
            compare(findChild(find("rowChangePin"), "label").text, "Set a PIN")
            verify(!find("rowRemovePin").visible, "no PIN to remove")
            // The first row has focus, and the hidden ones are skipped when moving.
            tryVerify(() => find("rowWho").activeFocus)
            for (let i = 0; i < 6; ++i)
                keyClick(Qt.Key_Down)
            verify(find("rowActivity").activeFocus, "the last row is Activity (T-247)")
            keyClick(Qt.Key_Up)
            verify(find("rowChangePin").activeFocus)
        }

        function test_admin_cannot_remove_pin() {
            startShell()
            signIn("p1", "1234")
            openMyProfilePane()
            compare(findChild(find("rowChangePin"), "label").text, "Change my PIN")
            verify(!find("rowRemovePin").visible, "an admin keeps a PIN")
            verify(find("category_profiles") !== null, "an admin sees Manage profiles")
            verify(!find("paneProfiles").visible, "and it is another category")
            verify(find("rowAdd") === null || !find("rowAdd").visible, "Add profile is not in My profile")
        }

        function test_change_pin() {
            startShell()
            signIn("p2", "")
            openMyProfilePane()
            goToRow("rowChangePin")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("myProfilePinPad").shown)
            const pad = find("myProfilePinPad")
            compare(pad.mode, "collect-confirm")          // Ada has no PIN: no current-PIN step

            enterPin("1357")
            compare(pad.stage, 1, "now asks for the confirmation")
            enterPin("1111")                              // does not match
            verify(pad.shown)
            compare(pad.message, "PINs don't match")
            compare(pad.stage, 0, "collection restarts")
            compare(pad.entered, "")
            compare(pinSpy.count, 0, "nothing was sent")

            enterPin("2468")
            enterPin("2468")                              // matches: setPin
            tryVerify(() => pinSpy.count === 1, 3000)
            compare(pinSpy.signalArguments[0][0], "p2")
            compare(pinSpy.signalArguments[0][1], "ok")
            tryVerify(() => find("myProfileMessage").text === "PIN changed.")
            verify(Profiles.profiles[1].hasPin)
            tryVerify(() => find("rowChangePin").activeFocus, 2000, "focus is back on the row")
            compare(findChild(find("rowChangePin"), "label").text, "Change my PIN")
            verify(find("rowRemovePin").visible)

            Profiles.lock()                               // the new PIN works at the picker
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => find("profileList").activeFocus)
            keyClick(Qt.Key_Right)                        // Ada (the picker was not used to sign in)
            compare(find("profileList").currentIndex, 1)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("pinPad").shown)
            for (const d of "2468")
                keyClick(d)
            keyClick(Qt.Key_Enter)
            tryCompare(Profiles, "activeProfile", "p2")
        }

        function test_change_pin_wrong_current_pin() {
            startShell()
            changePin("p2", "", "2468")
            signIn("p2", "2468")
            openMyProfilePane()
            goToRow("rowChangePin")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("myProfilePinPad").shown)
            compare(find("myProfilePinPad").mode, "collect")   // asks for the current PIN first
            enterPin("0000")
            enterPin("1357")
            enterPin("1357")
            tryVerify(() => find("myProfileMessage").text.indexOf("attempt") >= 0, 3000)
            verify(find("myProfileMessage").text.indexOf("4") >= 0)
            compare(Profiles.profiles[1].hasPin, true)
            changePin("p2", "2468", "2468")
            compare(pinSpy.signalArguments[pinSpy.count - 1][1], "ok", "the PIN did not change")
        }

        function test_remove_own_pin() {
            startShell()
            changePin("p2", "", "2468")
            signIn("p2", "2468")
            openMyProfilePane()
            verify(find("rowRemovePin").visible)
            goToRow("rowRemovePin")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("myProfilePinPad").shown)
            compare(find("myProfilePinPad").mode, "collect")
            enterPin("2468")
            tryVerify(() => find("myProfileMessage").text === "PIN removed.", 3000)
            compare(Profiles.profiles[1].hasPin, false)
            verify(!find("rowRemovePin").visible)
            tryVerify(() => find("rowChangePin").activeFocus, 2000, "focus is not lost when the focused row disappears")
        }

        // ---- rename and delete ----

        function selectRow(id) {
            goToRow("profileRow_" + id)
            keyClick(Qt.Key_Return)
        }

        function openConfirmFor(id, exists) {
            if (!exists)
                create("p1", "1234", "Kid", "standard", "")
            tryVerify(() => find("profileRow_" + id) !== null)
            selectRow(id)
            tryVerify(() => find("rowDelete").visible && find("rowRename").activeFocus, 2000, "actions open on Rename")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowDelete").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profilesDeleteConfirm").shown)
        }

        function test_rename_other() {
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            selectRow("p2")
            tryVerify(() => find("rowRename").activeFocus, 2000, "Rename is focused")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profilesRenameEntry").shown)
            compare(find("profilesRenameEntry").text, "Ada", "pre-filled with the current name")
            typeName("m", "profilesRenameEntry")
            tryVerify(() => find("profilesPinPad").shown, 2000, "the admin PIN is asked")
            enterPin("1234")
            tryVerify(() => Profiles.profiles[1].name === "Adam", 3000)
            tryVerify(() => find("profileRow_p2") !== null && find("profileRow_p2").activeFocus, 2000, "focus stays on the row")
            compare(findChild(find("profileRow_p2"), "label").text, "Adam")
        }

        function test_rename_self_standard() {
            startShell()
            signIn("p2", "")
            openMyProfilePane()
            goToRow("rowRenameMe")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("myProfileRenameEntry").shown)
            typeName("m", "myProfileRenameEntry")
            tryVerify(() => Profiles.profiles[1].name === "Adam", 3000)   // Ada has no PIN: none asked
            verify(!find("myProfilePinPad").shown)
            tryVerify(() => find("rowRenameMe").activeFocus, 2000, "focus is back on Rename")
            compare(findChild(find("rowWho"), "label").text, "Adam", "the identity row shows the new name")
        }

        function test_delete_cancel() {
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            openConfirmFor("p4")
            verify(findChild(find("profilesDeleteConfirm"), "powerCancel").activeFocus, "Cancel is focused first")
            keyClick(Qt.Key_Return)
            tryVerify(() => !find("profilesDeleteConfirm").shown)
            compare(Profiles.profiles.length, 4)
            compare(deleteSpy.count, 0)
            tryVerify(() => find("rowDelete").activeFocus, 2000, "focus is back on Delete")
        }

        function test_delete_confirm() {
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            openConfirmFor("p4")
            keyClick(Qt.Key_Right)
            verify(findChild(find("profilesDeleteConfirm"), "powerConfirm").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profilesPinPad").shown)
            enterPin("1234")
            tryVerify(() => Profiles.profiles.length === 3, 3000)
            tryVerify(() => find("profileRow_p4") === null)
            tryVerify(() => find("profileRow_p3") !== null && find("profileRow_p3").activeFocus, 2000,
                      "focus goes to the previous row at the end of the list: "
                      + (Window.activeFocusItem ? Window.activeFocusItem.objectName : "none"))
        }

        function test_delete_not_offered() {
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            selectRow("p1")                               // the active profile: renamed and PIN'd under My profile
            verify(!find("rowRename").visible, "your own profile is not renamed here")
            verify(!find("rowDelete").visible)
            verify(find("profilesMessage").text.indexOf("My profile") >= 0, "and the pane says where")
            tryVerify(() => find("profileRow_p1").activeFocus, 2000, "focus stays on the row")
            keyClick(Qt.Key_Down)                         // down the list to the Guest entry
            tryVerify(() => find("profileRow_p2").activeFocus)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("profileRow_p3").activeFocus)
            keyClick(Qt.Key_Return)
            verify(!find("rowRename").visible)
            verify(!find("rowDelete").visible)
            keyClick(Qt.Key_Up)
            tryVerify(() => find("profileRow_p2").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("rowDelete").visible)
        }

        function test_delete_wrong_pin() {
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            openConfirmFor("p4")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profilesPinPad").shown)
            enterPin("0000")
            tryVerify(() => find("profilesMessage").text.indexOf("4 attempt") >= 0, 3000)
            compare(Profiles.profiles.length, 4, "nothing was deleted")
        }

        // ---- My profile and Manage profiles (T-315) ----

        function rowNames(pane) { return pane.focusableRows().map(r => r.objectName) }

        function categoryKeys() {
            return find("categoryList").model.map(c => "category_" + c.key)
        }

        function test_categories_for_an_admin() {
            startShell()
            signIn("p1", "1234")
            openSettingsList()
            const keys = categoryKeys()
            compare(keys[0], "category_myprofile", "My profile is first")
            compare(keys[1], "category_profiles", "Manage profiles is second")
            compare(find("categoryList").count, 11)
            compare(find("categoryList").currentItem.Accessible.name, "My profile")
            keyClick(Qt.Key_Down)
            compare(find("categoryList").currentItem.Accessible.name, "Manage profiles")
        }

        function test_each_row_is_in_exactly_one_pane() {
            startShell()
            signIn("p1", "1234")
            openSettingsList()
            // My profile: who I am, rename me, the PIN row (an admin keeps theirs), Activity.
            compare(rowNames(find("paneMyProfile")), ["rowWho", "rowRenameMe", "rowChangePin", "rowActivity"])
            keyClick(Qt.Key_Down)
            // Manage profiles: the list, Add profile; Rename / Delete only for a selected other profile.
            compare(rowNames(find("paneProfiles")), ["profileRow_p1", "profileRow_p2", "profileRow_p3", "rowAdd"])
            compare(find("paneMyProfile").pad.objectName, "myProfilePinPad")
            compare(find("paneProfiles").pad.objectName, "profilesPinPad")
        }

        function test_categories_for_a_standard_profile() {
            startShell()
            signIn("p2", "")
            openSettingsList()
            verify(find("category_profiles") === null, "no Manage profiles")
            compare(find("categoryList").count, 10)
            compare(categoryKeys()[0], "category_myprofile")
            compare(categoryKeys()[1], "category_network", "the next category follows My profile at once")
            compare(rowNames(find("paneMyProfile")), ["rowWho", "rowRenameMe", "rowChangePin", "rowActivity"])
        }

        function test_guest_has_a_small_my_profile() {
            startShell()
            signIn("p3", "")
            openSettingsList()
            verify(find("category_profiles") === null, "no Manage profiles for a guest")
            compare(rowNames(find("paneMyProfile")), ["rowWho", "rowActivity"], "a guest cannot rename or set a PIN")
            compare(findChild(find("rowWho"), "value").text, "Guest")
        }

        function test_standard_cannot_reach_manage_by_keys() {
            startShell()
            signIn("p2", "")
            openSettingsList()
            const list = find("categoryList")
            for (let i = 0; i < list.count; ++i) {      // the last Down is clamped
                verify(!find("paneProfiles").visible, "Manage profiles never shows (index " + list.currentIndex + ")")
                verify(!find("paneProfiles").activeFocus)
                verify(list.currentItem.objectName !== "category_profiles")
                keyClick(Qt.Key_Down)
            }
            compare(list.currentIndex, list.count - 1)
            for (let i = list.count - 1; i > 0; --i)
                keyClick(Qt.Key_Up)
            compare(list.currentIndex, 0)
            keyClick(Qt.Key_Right)
            verify(!find("paneProfiles").activeFocus)
            tryVerify(() => find("paneMyProfile").activeFocus, 2000, "Right enters My profile")
            keyClick(Qt.Key_Escape)
            tryVerify(() => list.activeFocus)
            // A deep link to it opens My profile instead.
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tc.shell.openPage("settings", { category: "profiles" })
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000)
            compare(find("categoryList").currentIndex, 0)
            verify(find("paneMyProfile").visible)
        }

        function test_admin_deep_link_lands_on_manage() {
            startShell()
            signIn("p1", "1234")
            tc.shell.openPage("settings", { category: "profiles" })
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000)
            compare(find("categoryList").currentIndex, 1)
            verify(find("paneProfiles").visible)
        }

        // The signed-in profile changes to a standard one while Manage profiles is open: the
        // category disappears and focus lands on the category list.
        function test_role_switch_while_manage_is_open_leaves_it() {
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            verify(find("paneProfiles").activeFocus)
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("category_profiles") === null, 2000, "Manage profiles left the list")
            tryVerify(() => find("categoryList").activeFocus, 2000, "focus lands on the category list")
            verify(!find("paneProfiles").activeFocus)
            verify(!find("paneProfiles").visible)
            compare(find("categoryList").currentIndex, 0, "My profile is selected")
            verify(find("paneMyProfile").visible)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneMyProfile").activeFocus, 2000, "and it can be entered")
            compare(findChild(find("rowWho"), "label").text, "Ada")
        }

        // The selected category stays selected when the list changes around it.
        function test_role_switch_keeps_the_selected_category() {
            startShell()
            signIn("p1", "1234")
            openSettingsList()
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)                         // Network (third with Manage profiles)
            compare(find("categoryList").currentItem.objectName, "category_network")
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("category_profiles") === null, 2000)
            compare(find("categoryList").currentItem.objectName, "category_network")
            compare(find("categoryList").currentIndex, 1)
            verify(find("paneNetwork").visible)
        }

        function test_rename_self_as_admin_under_my_profile() {
            startShell()
            signIn("p1", "1234")
            openMyProfilePane()
            tryVerify(() => find("rowWho").activeFocus, 2000, "the pane opens on the identity row")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowRenameMe").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("myProfileRenameEntry").shown)
            typeName("2", "myProfileRenameEntry")
            tryVerify(() => find("myProfilePinPad").shown, 2000, "the admin's PIN is asked")
            enterPin("1234")
            tryVerify(() => Profiles.profiles[0].name === "Player One2", 3000)
            tryVerify(() => find("rowRenameMe").activeFocus, 2000, "focus is back on Rename")
            compare(findChild(find("rowWho"), "label").text, "Player One2")
            tryVerify(() => find("myProfileMessage").text === "Profile renamed.")
        }

        function test_back_leaves_each_pane_to_the_category_list() {
            startShell()
            signIn("p1", "1234")
            openMyProfilePane()
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "My profile -> list")
            compare(find("categoryList").currentIndex, 0)
            keyClick(Qt.Key_Down)
            enterPane("paneProfiles")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Manage profiles -> list")
            compare(find("categoryList").currentIndex, 1)
            compare(tc.shell.currentPage, "settings")
        }

        function test_zz_screenshots_my_profile() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Notifications.pending = []
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            startShell()
            signIn("p1", "1234")
            openMyProfilePane()
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/11-settings-my-profile.png")
        }

        function test_zz_screenshots_standard_categories() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Notifications.pending = []
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            startShell()
            signIn("p2", "")
            openSettingsList()
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/12-settings-categories-standard.png")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Notifications.pending = []                    // toasts left by earlier tests would cover the rows
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            openAddForm()
            find("paneProfiles").newName = "Kid"
            goToRow("rowNewRole")
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/10-settings-profiles.png")
        }

        function test_zz_screenshots_delete() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Notifications.pending = []
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            openConfirmFor("p4")
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/24-profile-delete-confirm.png")
        }
    }
}
