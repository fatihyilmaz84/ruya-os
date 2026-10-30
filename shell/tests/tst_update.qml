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

    SignalSpy { id: requestSpy; target: Update; signalName: "requestFinished" }

    TestCase {
        id: tc
        name: "Update"
        when: windowShown

        property Item shell: null
        readonly property int systemIndex: 7

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            tryCompare(Profiles, "activeProfile", "")
            Update.mockReset()
            tryCompare(Update, "state", "idle")
            requestSpy.clear()
        }

        function cleanup() {
            Notifications.durationMs = Theme.toastMs
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
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
            tryVerify(() => find("tiles").activeFocus, 2000, "home shelf takes focus after sign-in")
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                       // Settings tile
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
    }
}
