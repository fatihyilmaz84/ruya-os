import QtQuick
import QtTest
import RuyaShell

// OS updates (org.ruyaos.Update1): the mock must follow the contract's status rules, and
// Settings -> System must drive check / download / restart / rollback with controller keys
// only. Own file: it creates lockout state with wrong PINs and each file gets a fresh mock.
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

    SignalSpy { id: requestSpy; target: Update; signalName: "requestFinished" }

    TestCase {
        id: tc
        name: "Update"
        when: windowShown

        property Shell shell: null
        readonly property int systemIndex: 8

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            tryCompare(Profiles, "activeProfile", "")
            Update.mockReset()
            tryCompare(Update, "state", "idle")
            DeviceSettings.language = "en"
            requestSpy.clear()
        }

        function cleanup() {
            Update.mockSetCallerIsAdmin(true)
            Update.mockAnnounceRestart(0)
            Notifications.durationMs = Theme.toastMs
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
            DeviceSettings.language = "en"               // a Left/Right in the System pane changes it (T-167)
        }

        // The language is process-wide (the installed translator) and later tests compare English
        // text, so this one must not leave "tr" behind: init and cleanup put "en" back.
        function test_a_press_in_the_system_pane_reaches_the_language_row() {
            openSystemPane("p2", "")
            verify(find("rowLanguage").activeFocus, "the System pane starts on the Language row")
            compare(DeviceSettings.language, "en")
            keyClick(Qt.Key_Right)                       // a ChoiceRow consumes Left/Right (02 §1.2)
            tryCompare(DeviceSettings, "language", "tr")
            verify(find("rowLanguage").activeFocus)
        }

        function test_a_press_right_after_sign_in_stays_on_home() {
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in (02 §1)")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("homeDetails").activeFocus, 2000, "Right on Play goes to Details")
            compare(DeviceSettings.language, "en")
        }

        // The reply status of one request: [method, status].
        function request(call) {
            const before = requestSpy.count
            call()
            tryCompare(requestSpy, "count", before + 1)
            return requestSpy.signalArguments[before]
        }

        function openSystemPane(id, pin) {
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            Profiles.switchTo(id, pin)
            tryCompare(Profiles, "activeProfile", id)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus, 2000, "category list has focus")
            for (let i = 0; i < 20 && list.currentIndex < systemIndex; ++i)
                keyClick(Qt.Key_Down)
            compare(list.currentIndex, systemIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneSystem").activeFocus, 2000, "System pane has focus")
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
            const pad = find("updatePinPad")
            const keys = findChild(pad, "pinKeys")
            verify(pad.shown, "the PIN pad is open")
            for (let step = 0; step < 12 && keys.currentIndex !== target; ++step) {
                const row = Math.floor(keys.currentIndex / 3)
                const targetRow = Math.floor(target / 3)
                if (row !== targetRow)
                    keyClick(row < targetRow ? Qt.Key_Down : Qt.Key_Up)
                else
                    keyClick(keys.currentIndex % 3 < target % 3 ? Qt.Key_Right : Qt.Key_Left)
            }
            compare(keys.currentIndex, target)
            keyClick(Qt.Key_Return)
        }

        function enterPin(pin) {
            for (const d of pin)
                padPress(d)
            padPress("ok")
        }

        function test_mock_follows_the_contract() {
            compare(request(() => Update.download())[1], "unavailable", "nothing found yet")
            compare(request(() => Update.rollback())[1], "ok", "rollback is available by default")
            tryCompare(Update, "state", "staged")
            compare(Update.staged, "0.0.17")
            compare(Update.rollbackAvailable, false)
            compare(request(() => Update.rollback())[1], "unavailable", "rollback only once")
            compare(Update.mockRollbackCount(), 1)

            Update.mockReset()
            tryCompare(Update, "state", "idle")
            compare(request(() => Update.check())[1], "ok")
            tryCompare(Update, "state", "checking")
            compare(request(() => Update.check())[1], "busy")
            compare(request(() => Update.download())[1], "busy")
            compare(request(() => Update.rollback())[1], "busy")
            compare(request(() => Update.setChannel("beta"))[1], "busy")
            tryCompare(Update, "state", "idle")
            compare(Update.available, "0.0.19")
            verify(Update.lastCheck > 0)

            compare(request(() => Update.setChannel("nightly"))[1], "invalid")
            compare(Update.channel, "stable")
            compare(request(() => Update.setChannel("beta"))[1], "ok")
            tryCompare(Update, "channel", "beta")
            compare(Update.available, "", "a channel change forgets the found update")
            compare(request(() => Update.download())[1], "unavailable")

            Update.mockFailNextCheck()
            compare(request(() => Update.check())[1], "failed")
            tryCompare(Update, "state", "failed")
            verify(Update.error.length > 0)

            Update.mockReset()
            tryCompare(Update, "state", "idle")
            Update.mockSetUpdateExists(false)
            request(() => Update.check())
            tryCompare(Update, "state", "up-to-date")
        }

        function test_check_download_restart() {
            openSystemPane("p2", "")                      // Ada: standard
            compare(find("rowChannel").visible, false, "channel is for admins")
            compare(find("rowRollback").visible, false, "rollback is for admins")
            goToRow("rowUpdate")
            compare(find("rowUpdate").label, "Check for updates")
            const shownBefore = Notifications.shownCount

            keyClick(Qt.Key_Return)
            tryCompare(Update, "state", "idle")
            tryCompare(Update, "available", "0.0.19")
            tryVerify(() => find("rowUpdate").label === "Download version 0.0.19")
            verify(find("rowUpdate").activeFocus)

            keyClick(Qt.Key_Return)
            tryCompare(Update, "state", "staged")
            tryVerify(() => find("rowUpdate").label === "Restart to finish")
            verify(find("rowUpdate").activeFocus, "the row keeps focus through the whole update")

            tryCompare(Notifications, "shownCount", shownBefore + 1)
            wait(100)
            compare(Notifications.shownCount, shownBefore + 1, "the staged toast appears once")

            keyClick(Qt.Key_Return)
            const confirm = find("updateRestartConfirm")
            tryVerify(() => confirm.shown, 2000, "Accept opens the restart confirm")
            compare(Power.actionCount, 0)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !confirm.shown)
            tryVerify(() => find("rowUpdate").activeFocus, 2000, "focus returns to the row")
            compare(Power.actionCount, 0, "cancel restarts nothing")

            keyClick(Qt.Key_Return)
            tryVerify(() => confirm.shown)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            compare(Power.lastAction, "restart")
        }

        function test_download_progress_is_shown() {
            Update.mockPauseDownloadAt(40)
            openSystemPane("p2", "")
            goToRow("rowUpdate")
            keyClick(Qt.Key_Return)
            tryCompare(Update, "available", "0.0.19")
            keyClick(Qt.Key_Return)
            tryCompare(Update, "progress", 40)
            compare(Update.state, "downloading")
            tryVerify(() => findChild(find("rowUpdate"), "value").text === "40 %")
            keyClick(Qt.Key_Return)                        // Accept while downloading does nothing
            compare(Update.state, "downloading")
            Update.mockResumeDownload()
            tryCompare(Update, "state", "staged")
        }

        function test_forbidden_for_a_non_admin_caller() {
            Update.mockSetCallerIsAdmin(false)
            compare(request(() => Update.rollback())[1], "forbidden")
            compare(request(() => Update.setChannel("beta"))[1], "forbidden")
            compare(Update.channel, "stable")
            compare(Update.rollbackAvailable, true)
            compare(Update.mockRollbackCount(), 0)
            compare(request(() => Update.check())[1], "ok", "checking is for everyone")
            Update.mockSetCallerIsAdmin(true)
        }

        function test_forbidden_has_its_own_message() {
            openSystemPane("p1", "1234")
            goToRow("rowChannel")
            Update.mockSetCallerIsAdmin(false)
            keyClick(Qt.Key_Right)
            compare(Update.channel, "stable")
            tryVerify(() => find("updateMessage").visible
                            && find("updateMessage").text === "Only an admin can do this.")
        }

        function test_rollback_asks_for_the_admin_pin() {
            openSystemPane("p1", "1234")                  // Player One: admin
            verify(find("rowChannel").visible)
            verify(find("rowRollback").visible)
            goToRow("rowRollback")

            keyClick(Qt.Key_Return)
            const pad = find("updatePinPad")
            tryVerify(() => pad.shown, 2000, "Accept asks for the PIN")
            enterPin("0000")
            tryVerify(() => !pad.shown)
            tryVerify(() => find("updateMessage").visible && find("updateMessage").text.indexOf("Wrong PIN") === 0)
            tryVerify(() => find("rowRollback").activeFocus, 2000, "focus returns to the row")
            compare(Update.mockRollbackCount(), 0)

            keyClick(Qt.Key_Return)
            tryVerify(() => pad.shown)
            enterPin("1234")
            const confirm = find("updateRollbackConfirm")
            tryVerify(() => confirm.shown, 2000, "the right PIN leads to a confirm")
            compare(Update.mockRollbackCount(), 0, "nothing yet")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !confirm.shown)
            tryVerify(() => find("rowRollback").activeFocus)
            compare(Update.mockRollbackCount(), 0, "cancel rolls nothing back")

            keyClick(Qt.Key_Return)
            tryVerify(() => pad.shown)
            enterPin("1234")
            tryVerify(() => confirm.shown)
            keyClick(Qt.Key_Right)
            const confirmButton = findChild(confirm, "powerConfirm")
            tryVerify(() => confirmButton.activeFocus, 2000, "Right moves to the confirm button")
            compare(confirmButton.Accessible.name, "Roll back now", "the confirmation says what it does (T-189)")
            compare(findChild(confirm, "powerConfirmLabel").text, "Roll back now", "and the visible label says it too (T-194)")
            keyClick(Qt.Key_Return)
            tryCompare(Update, "state", "staged")
            compare(Update.mockRollbackCount(), 1)
            tryVerify(() => !find("rowRollback").visible, 2000, "no second rollback")
            tryVerify(() => find("paneSystem").focusableRows().some(r => r.activeFocus), 2000, "focus is not lost")
            compare(find("rowUpdate").label, "Restart to finish")
        }

        function test_rollback_row_needs_rollback_available() {
            Update.mockSetRollbackAvailable(false)
            tryCompare(Update, "rollbackAvailable", false)
            openSystemPane("p1", "1234")
            compare(find("rowRollback").visible, false)
        }

        function test_channel_row_changes_the_channel() {
            openSystemPane("p1", "1234")
            goToRow("rowChannel")
            keyClick(Qt.Key_Right)
            tryCompare(Update, "channel", "beta")
            verify(find("rowChannel").activeFocus)
            compare(find("rowVersion").value, "0.0.18 · Beta")
        }

        function test_auto_restart_setting_round_trip() {
            compare(Update.autoRestart, true, "on by default")
            compare(request(() => Update.setAutoRestart(false))[1], "ok")
            tryCompare(Update, "autoRestart", false)
            compare(request(() => Update.setAutoRestart(true))[1], "ok")
            tryCompare(Update, "autoRestart", true)
        }

        function test_auto_restart_is_refused_for_a_non_admin_caller() {
            Update.mockSetCallerIsAdmin(false)
            compare(request(() => Update.setAutoRestart(false))[1], "forbidden")
            compare(Update.autoRestart, true)
            Update.mockSetCallerIsAdmin(true)
        }

        function test_auto_restart_row_is_hidden_from_a_standard_profile() {
            openSystemPane("p2", "")                      // Ada: standard
            compare(find("rowAutoRestart").visible, false, "the setting is for admins")
        }

        function test_auto_restart_row_toggles_for_an_admin() {
            openSystemPane("p1", "1234")
            verify(find("rowAutoRestart").visible)
            goToRow("rowAutoRestart")
            compare(find("rowAutoRestart").checked, true)
            keyClick(Qt.Key_Return)
            tryCompare(Update, "autoRestart", false)
            tryVerify(() => find("rowAutoRestart").checked === false)
            verify(find("rowAutoRestart").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(Update, "autoRestart", true)
            tryVerify(() => find("rowAutoRestart").checked === true)
        }

        function test_a_refused_setting_says_so() {
            openSystemPane("p1", "1234")
            goToRow("rowAutoRestart")
            Update.mockSetCallerIsAdmin(false)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("updateMessage").visible
                            && find("updateMessage").text === "Only an admin can do this.")
            compare(Update.autoRestart, true)
            tryVerify(() => find("rowAutoRestart").checked === true, 2000, "the row shows what the service has")
        }

        function test_activity_is_reported_at_most_once_a_minute() {
            compare(Update.mockActivityCount(), 0)
            Update.noteActivity(false)
            Update.noteActivity(false)
            Update.noteActivity(false)
            compare(Update.mockActivityCount(), 1, "a burst of input is one report")
            compare(Update.mockLastActivityAppRunning(), false)
            // An app coming to the front or leaving it is never held back (review 2026-11-02):
            // the input that launched it was reported as "no app".
            Update.noteActivity(true)
            compare(Update.mockActivityCount(), 2, "an app in front is reported at once")
            compare(Update.mockLastActivityAppRunning(), true)
            Update.noteActivity(true)
            compare(Update.mockActivityCount(), 2, "input over the app waits for the minute")
            Update.noteActivity(false)
            compare(Update.mockActivityCount(), 3, "the app closing is reported at once")
            compare(Update.mockLastActivityAppRunning(), false)
        }

        // The sticky restart notice currently on screen, or null.
        function restartToast() {
            for (let i = 0; i < Notifications.model.count; ++i) {
                const t = Notifications.model.get(i)
                if (t.key === "update-restart")
                    return t
            }
            return null
        }

        function test_an_announced_restart_shows_a_toast_until_it_is_called_off() {
            openSystemPane("p2", "")
            Notifications.durationMs = 100                // ordinary toasts would be gone long ago
            compare(Update.restartPending, false)
            verify(restartToast() === null)

            Update.mockAnnounceRestart(Math.floor(Date.now() / 1000) + 120)
            tryCompare(Update, "restartPending", true)
            tryVerify(() => restartToast() !== null, 2000, "the notice appears")
            compare(restartToast().text, "Restarting to finish the update in 2 minutes. Press any button to wait.")
            compare(restartToast().kind, "warning")
            wait(600)
            verify(restartToast() !== null, "it does not dismiss itself")
        }

        function test_a_cleared_restart_takes_the_toast_away() {
            openSystemPane("p2", "")
            Update.mockAnnounceRestart(Math.floor(Date.now() / 1000) + 120)
            tryVerify(() => restartToast() !== null)
            Update.mockAnnounceRestart(0)
            tryCompare(Update, "restartPending", false)
            tryVerify(() => restartToast() === null, 2000, "the notice goes")
        }

        function test_the_notice_is_shown_once_per_announcement() {
            openSystemPane("p2", "")
            Update.mockAnnounceRestart(Math.floor(Date.now() / 1000) + 120)
            tryVerify(() => restartToast() !== null)
            const shown = Notifications.shownCount
            Update.mockAnnounceRestart(Math.floor(Date.now() / 1000) + 121)   // a refreshed record
            wait(100)
            compare(Notifications.shownCount, shown, "the same announcement is not shown again")
        }

        function test_a_press_while_a_restart_is_announced_is_reported_at_once() {
            openSystemPane("p2", "")
            Update.noteActivity(false)                    // the minute is running
            const before = Update.mockActivityCount()
            Update.noteActivity(false)
            compare(Update.mockActivityCount(), before, "inside the minute nothing is sent")

            Update.mockAnnounceRestart(Math.floor(Date.now() / 1000) + 120)
            tryCompare(Update, "restartPending", true)
            keyClick(Qt.Key_Up)                           // any button
            tryVerify(() => Update.mockActivityCount() > before, 2000, "the press got through the minute")
            tryCompare(Update, "restartPending", false)   // the service called the restart off
            tryVerify(() => restartToast() === null, 2000, "and the notice went")
        }

        function test_an_app_in_front_is_reported_without_input() {
            openSystemPane("p2", "")
            const before = Update.mockActivityCount()
            const app = createTemporaryObject(appComponent, host)
            verify(app)
            tc.shell.addApp(app)
            tryVerify(() => app.activeFocus, 2000, "the app takes focus")
            compare(Update.mockActivityCount(), before + 1)
            compare(Update.mockLastActivityAppRunning(), true, "an app is in front")
            tc.shell.removeApp(app)
            compare(Update.mockActivityCount(), before + 2)
            compare(Update.mockLastActivityAppRunning(), false, "the app is gone")
        }

        function test_input_in_the_shell_is_reported_once() {
            compare(Update.mockActivityCount(), 0)
            openSystemPane("p2", "")                      // dozens of key presses
            compare(Update.mockActivityCount(), 1, "the shell reports input, once for the burst")
            compare(Update.mockLastActivityAppRunning(), false, "no app is in front")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Update.mockPauseDownloadAt(40)
            openSystemPane("p1", "1234")
            goToRow("rowUpdate")
            keyClick(Qt.Key_Return)
            tryCompare(Update, "available", "0.0.19")
            keyClick(Qt.Key_Return)
            tryCompare(Update, "progress", 40)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/25-settings-updates.png")
            Update.mockResumeDownload()
        }

        function test_zz_screenshots_restart_notice() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            Update.mockAnnounceRestart(Math.floor(Date.now() / 1000) + 120)
            tryVerify(() => restartToast() !== null, 2000, "the notice appears")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/28-restart-notice.png")
        }
    }
}
