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

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }
        function padKeys() { return findChild(find("profilesPinPad"), "pinKeys") }

        function init() {
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
            tryVerify(() => find("tiles").activeFocus, 2000, "home shelf takes focus after sign-in")
        }

        function openProfilesPane() {
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                       // Settings tile
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList") !== null && find("categoryList").activeFocus)
            compare(find("categoryList").currentIndex, 0) // Profiles
            keyClick(Qt.Key_Right)                        // enter the pane
            tryVerify(() => find("paneProfiles").activeFocus, 2000, "pane has focus")
            tryVerify(() => find("paneProfiles").focusableRows().some(r => r.activeFocus), 2000, "a row has focus")
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
            const pad = find("profilesPinPad")
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

        function typeName(text) {
            const entry = find("profileNameEntry")
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
            openProfilesPane()
            verify(!find("rowAdd").visible, "Add profile is for admins")
            verify(!find("rowNewName").visible)
            verify(!find("rowCreate").visible)
            verify(find("rowChangePin").visible)
            compare(findChild(find("rowChangePin"), "label").text, "Set a PIN")
            verify(!find("rowRemovePin").visible, "no PIN to remove")
            // The first visible row has focus, and the hidden ones are skipped when moving.
            tryVerify(() => find("profileRow_p1").activeFocus)
            for (let i = 0; i < 6; ++i)
                keyClick(Qt.Key_Down)
            verify(find("rowChangePin").activeFocus)
            verify(!find("rowAdd").activeFocus)
        }

        function test_admin_cannot_remove_pin() {
            startShell()
            signIn("p1", "1234")
            openProfilesPane()
            verify(find("rowAdd").visible)
            compare(findChild(find("rowChangePin"), "label").text, "Change my PIN")
            verify(!find("rowRemovePin").visible, "an admin keeps a PIN")
        }

        function test_change_pin() {
            startShell()
            signIn("p2", "")
            openProfilesPane()
            goToRow("rowChangePin")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profilesPinPad").shown)
            const pad = find("profilesPinPad")
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
            tryVerify(() => find("profilesMessage").text === "PIN changed.")
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
            openProfilesPane()
            goToRow("rowChangePin")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profilesPinPad").shown)
            compare(find("profilesPinPad").mode, "collect")   // asks for the current PIN first
            enterPin("0000")
            enterPin("1357")
            enterPin("1357")
            tryVerify(() => find("profilesMessage").text.indexOf("attempt") >= 0, 3000)
            verify(find("profilesMessage").text.indexOf("4") >= 0)
            compare(Profiles.profiles[1].hasPin, true)
            changePin("p2", "2468", "2468")
            compare(pinSpy.signalArguments[pinSpy.count - 1][1], "ok", "the PIN did not change")
        }

        function test_remove_own_pin() {
            startShell()
            changePin("p2", "", "2468")
            signIn("p2", "2468")
            openProfilesPane()
            verify(find("rowRemovePin").visible)
            goToRow("rowRemovePin")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("profilesPinPad").shown)
            compare(find("profilesPinPad").mode, "collect")
            enterPin("2468")
            tryVerify(() => find("profilesMessage").text === "PIN removed.", 3000)
            compare(Profiles.profiles[1].hasPin, false)
            verify(!find("rowRemovePin").visible)
            tryVerify(() => find("rowChangePin").activeFocus, 2000, "focus is not lost when the focused row disappears")
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
    }
}
