import QtQuick
import QtTest
import RuyaShell

// Power: the Power page, the confirmation dialog and the Guide overlay's power choices. The
// mock backend only records the requested action (Power.lastAction), so nothing is powered
// off. Driven with controller keys only. Signs in as "Ada" (p2, no PIN).
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
        name: "Power"
        when: windowShown

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            Power.mockReset()
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
            tryVerify(() => find("tiles").activeFocus, 2000, "home shelf takes focus after sign-in")
            tryVerify(() => Power.canPowerOff, 2000, "the mock allows everything")
        }

        function openPowerPage() {
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "power")
            tryVerify(() => find("powerSuspend") && find("powerSuspend").activeFocus, 2000, "first row has focus")
        }

        function test_page_rows_and_back() {
            openPowerPage()
            keyClick(Qt.Key_Down)
            tryVerify(() => find("powerRestart").activeFocus)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("powerOff").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("powerOff").activeFocus, "clamped at the last row")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("tiles").activeFocus, 2000, "tiles regain focus")
            compare(find("tiles").currentIndex, 4)
        }

        function test_default_focus_is_cancel() {
            openPowerPage()
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                    // Restart
            tryVerify(() => find("powerConfirmDialog").shown)
            compare(find("powerConfirmTitle").text, "Restart now?")
            tryVerify(() => find("powerCancel").activeFocus, 2000, "Cancel has focus")
            verify(!find("powerConfirm").activeFocus)
            keyClick(Qt.Key_Return)                    // a stray Accept cancels
            compare(Power.actionCount, 0)
        }

        function test_confirm_and_cancel() {
            openPowerPage()
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                    // Restart
            tryVerify(() => find("powerCancel").activeFocus)
            keyClick(Qt.Key_Return)                    // Cancel
            tryVerify(() => !find("powerConfirmDialog").shown)
            tryVerify(() => find("powerRestart").activeFocus, 2000, "focus returns to the row")
            wait(50)
            compare(Power.lastAction, "")
            compare(Power.actionCount, 0)

            keyClick(Qt.Key_Return)                    // again
            tryVerify(() => find("powerCancel").activeFocus)
            keyClick(Qt.Key_Escape)                    // Back cancels too
            tryVerify(() => !find("powerConfirmDialog").shown)
            tryVerify(() => find("powerRestart").activeFocus)
            compare(tc.shell.currentPage, "power", "Back closed the dialog, not the page")
            compare(Power.actionCount, 0)

            keyClick(Qt.Key_Return)
            tryVerify(() => find("powerCancel").activeFocus)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("powerConfirm").activeFocus)
            keyClick(Qt.Key_Return)                    // Confirm
            tryCompare(Power, "lastAction", "restart")
            compare(Power.actionCount, 1)
            tryVerify(() => !find("powerConfirmDialog").shown)
            tryVerify(() => find("powerRestart").activeFocus)
        }

        function test_each_action_is_requested() {
            openPowerPage()
            keyClick(Qt.Key_Return)                    // Suspend
            compare(find("powerConfirmTitle").text, "Suspend now?")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Power, "lastAction", "suspend")
            tryVerify(() => find("powerSuspend").activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                    // Power off
            compare(find("powerConfirmTitle").text, "Power off now?")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Power, "lastAction", "poweroff")
            compare(Power.actionCount, 2)
        }

        function test_unavailable_action_opens_nothing() {
            Power.mockSetCapabilities("no", "yes", "yes")
            tryVerify(() => !Power.canSuspend)
            openPowerPage()
            keyClick(Qt.Key_Return)                    // Suspend is not allowed
            wait(100)
            verify(!find("powerConfirmDialog").shown)
            verify(find("powerSuspend").activeFocus, "focus stays on the row")
            compare(Power.actionCount, 0)
        }

        function test_dialog_is_modal() {
            openPowerPage()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("powerCancel").activeFocus)
            keyClick(Qt.Key_Down)                      // does not move the rows underneath
            verify(find("powerCancel").activeFocus)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("powerConfirm").activeFocus)
            keyClick(Qt.Key_Right)
            verify(find("powerConfirm").activeFocus)
            keyClick(Qt.Key_Left)
            tryVerify(() => find("powerCancel").activeFocus)
            keyClick(Qt.Key_Escape)
            compare(Power.actionCount, 0)
        }

        function test_guide_short_press_opens_overlay() {
            keyPress(Qt.Key_HomePage)
            keyRelease(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            compare(find("systemPanel").powerMode, false)
            wait(Theme.guideHoldMs + 400)
            compare(find("systemPanel").powerMode, false, "released before the hold time")
            verify(find("systemActions").activeFocus)
        }

        function test_guide_long_press() {
            keyPress(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the overlay opens on press")
            compare(find("systemPanel").powerMode, false)
            tryCompare(find("systemPanel"), "powerMode", true, Theme.guideHoldMs + 2000)
            verify(find("systemActions").activeFocus, "the overlay stays open and focused")
            keyRelease(Qt.Key_HomePage)
            wait(100)
            verify(find("systemPanel").open, "releasing after the hold does not close it")
            compare(find("systemActions").count, 4)    // Suspend, Restart, Power off, Back
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                    // Restart
            tryVerify(() => find("overlayPowerConfirm").shown)
            compare(find("overlayPowerConfirm").action, "restart")
            tryVerify(() => find("powerCancel") && find("overlayPowerConfirm").activeFocus)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Power, "lastAction", "restart")
            tryVerify(() => !find("systemPanel").open, 2000, "the overlay closes after Confirm")
            tryVerify(() => find("tiles").activeFocus, 2000, "focus returns to the shelf")
        }

        function test_overlay_power_choices_by_menu() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            compare(find("systemActions").count, 3)    // Switch profile, Power, Close
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                    // Power
            tryCompare(find("systemPanel"), "powerMode", true)
            compare(find("systemActions").currentIndex, 0)
            keyClick(Qt.Key_Return)                    // Suspend -> confirmation
            tryVerify(() => find("overlayPowerConfirm").shown)
            keyClick(Qt.Key_Escape)                    // cancel: back on the power choices
            tryVerify(() => !find("overlayPowerConfirm").shown)
            tryVerify(() => find("systemActions").activeFocus)
            compare(find("systemPanel").powerMode, true)
            compare(Power.actionCount, 0)
            keyClick(Qt.Key_Escape)                    // Back: the system actions again, on "Power"
            tryCompare(find("systemPanel"), "powerMode", false)
            compare(find("systemActions").currentIndex, 1)
            keyClick(Qt.Key_Escape)                    // closes the overlay
            tryVerify(() => !find("systemPanel").open)
            tryVerify(() => find("tiles").activeFocus)
            compare(Power.actionCount, 0)
        }

        function test_overlay_hides_unavailable_choices() {
            Power.mockSetCapabilities("yes", "no", "yes")
            tryVerify(() => !Power.canRestart)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "powerMode", true)
            compare(find("systemActions").count, 3)    // Suspend, Power off, Back
        }

        function test_overlay_power_choices_over_page() {
            openPowerPage()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "powerMode", true)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                    // Power off
            tryVerify(() => find("overlayPowerConfirm").shown)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Power, "lastAction", "poweroff")
            tryVerify(() => !find("systemPanel").open)
            tryVerify(() => find("powerSuspend").activeFocus, 2000, "focus returns to the page")
            compare(tc.shell.currentPage, "power")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openPowerPage()
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("powerCancel").activeFocus)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/13-power-confirm.png")
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "powerMode", true)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/13b-power-choices.png")
        }
    }
}
