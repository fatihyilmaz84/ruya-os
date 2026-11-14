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

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.language = "en"
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
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            tryVerify(() => Power.canPowerOff, 2000, "the mock allows everything")
        }

        // Power is not in the section nav (it is in the Guide overlay): open the page directly.
        function openPowerPage() {
            tc.shell.openPage("power")
            tryCompare(tc.shell, "currentPage", "power")
            tryVerify(() => find("powerSuspend") && find("powerSuspend").activeFocus, 2000, "first row has focus")
            for (const n of ["powerSuspend", "powerRestart", "powerOff"])
                compare(find(n).kind, "action", n)
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
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play regains focus")
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

        // T-194: the visible label of the action button is the action, and it is the accessible
        // name too (WCAG 2.5.3); only a custom dialog without a name says "Confirm".
        function test_button_label_is_the_action() {
            openPowerPage()
            const dialog = find("powerConfirmDialog")
            const label = findChild(dialog, "powerConfirmLabel")
            const expected = [["suspend", "Suspend now"], ["restart", "Restart now"], ["poweroff", "Power off now"]]
            for (const [action, text] of expected) {
                dialog.open(action)
                tryVerify(() => find("powerCancel").activeFocus, 2000, action + ": Cancel has focus")
                compare(label.text, text, action)
                compare(find("powerConfirm").Accessible.name, label.text, action + ": name equals label")
                compare(find("powerCancel").Accessible.name, "Cancel")
                dialog.cancel()
                tryVerify(() => !dialog.shown)
            }
            dialog.customConfirmName = ""
            dialog.open("custom")
            compare(label.text, "Confirm", "a custom dialog without a name keeps the generic word")
            compare(find("powerConfirm").Accessible.name, "Confirm")
            dialog.cancel()
            tryVerify(() => !dialog.shown)
            dialog.customConfirmName = "Roll back now"
            dialog.open("custom")
            compare(find("powerConfirm").color, Theme.dangerFill, "a custom confirm is danger-red by default")
            compare(label.text, "Roll back now")
            compare(find("powerConfirm").Accessible.name, "Roll back now")
            dialog.cancel()
            tryVerify(() => !dialog.shown)
            dialog.customDestructive = false
            dialog.open("custom")
            compare(find("powerConfirm").color, Theme.glass, "a non-destructive custom confirm is the neutral pill")
            dialog.cancel()
            tryVerify(() => !dialog.shown)
            dialog.customDestructive = true
        }

        // The Turkish labels are the action too; the same text is the name.
        function test_button_label_is_translated() {
            DeviceSettings.language = "tr"
            openPowerPage()
            const dialog = find("powerConfirmDialog")
            const label = findChild(dialog, "powerConfirmLabel")
            dialog.open("restart")
            compare(label.text, "Şimdi yeniden başlat")
            compare(find("powerConfirm").Accessible.name, "Şimdi yeniden başlat")
            compare(find("powerCancel").Accessible.name, "İptal")
            dialog.cancel()
            tryVerify(() => !dialog.shown)
        }

        // What is wrong with the buttons' place inside the dialog at the size the shell really
        // gives it ("" when nothing). Row and Column lay out on the next frame: callers wait.
        function buttonsProblem(dialog) {
            const panel = findChild(dialog, "powerConfirmPanel")
            const confirm = find("powerConfirm")
            const cancel = find("powerCancel")
            const label = findChild(dialog, "powerConfirmLabel")
            const c = confirm.mapToItem(dialog, 0, 0)
            const k = cancel.mapToItem(dialog, 0, 0)
            const p = panel.mapToItem(dialog, 0, 0)
            const dims = [k.x, c.x, confirm.width, p.x, panel.width, dialog.width, dialog.u].join(",")
            if (!(dialog.u > 0.5))
                return "no real scale " + dims
            if (!(p.x >= 0 && p.x + panel.width <= dialog.width + 0.5))
                return "the card is outside the window " + dims
            if (!(k.x >= p.x && c.x + confirm.width <= p.x + panel.width + 0.5))
                return "a button is outside the card " + dims
            if (!(k.x + cancel.width <= c.x))
                return "the buttons overlap " + dims
            if (!(label.width <= confirm.width + 0.5 && label.x >= 0))
                return "the label is outside its button " + dims
            return ""
        }

        function checkButtonsInside(dialog, what) {
            tryVerify(() => buttonsProblem(dialog) === "", 2000, what + ": " + buttonsProblem(dialog))
        }

        // T-194: the longest names (English and Turkish) still fit the dialog; beyond the room
        // the label elides and the full text stays in the accessible name.
        function test_longest_names_fit_the_dialog() {
            openPowerPage()
            const dialog = find("powerConfirmDialog")
            const label = findChild(dialog, "powerConfirmLabel")
            const names = [
                ["en", "Roll back now"],
                ["en", "Delete Wolfeschlegelsteinhausen Jr"],
                ["tr", "Şimdi önceki sürüme dön"],
                ["tr", "Wolfeschlegelsteinhausen Jr. profilini sil"]
            ]
            for (const [lang, name] of names) {
                DeviceSettings.language = lang
                dialog.customTitle = name + "?"
                dialog.customConfirmName = name
                dialog.open("custom")
                tryVerify(() => find("powerCancel").activeFocus, 2000)
                tryCompare(label, "text", name)
                checkButtonsInside(dialog, name)
                verify(!label.truncated, name + ": fits without eliding")
                dialog.cancel()
                tryVerify(() => !dialog.shown)
            }
            const absurd = "Delete " + "Ayşegül-Çağlayan-Öztürk-".repeat(12)
            dialog.customTitle = "Delete?"
            dialog.customConfirmName = absurd
            dialog.open("custom")
            tryVerify(() => find("powerCancel").activeFocus, 2000)
            checkButtonsInside(dialog, "absurd name")
            verify(label.truncated, "the label elides when there is no room")
            compare(find("powerConfirm").Accessible.name, absurd, "the name keeps the whole text")
            dialog.cancel()
            tryVerify(() => !dialog.shown)
        }

        // T-179: Backspace is Back, like Esc.
        function test_backspace_is_back() {
            openPowerPage()
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                    // Restart
            tryVerify(() => find("powerCancel").activeFocus)
            keyClick(Qt.Key_Backspace)                 // the dialog closes, not the page
            tryVerify(() => !find("powerConfirmDialog").shown)
            tryVerify(() => find("powerRestart").activeFocus, 2000, "focus returns to the row")
            compare(tc.shell.currentPage, "power")
            compare(Power.actionCount, 0)

            keyClick(Qt.Key_Backspace)                 // then the page
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play regains focus")
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
            compare(find("powerSuspend").dimmed, true)
            const before = Notifications.shownCount
            keyClick(Qt.Key_Return)                    // Suspend is not allowed
            tryVerify(() => Notifications.shownCount > before, 2000, "it says why")
            const texts = []
            for (let i = 0; i < Notifications.model.count; ++i)
                texts.push(Notifications.model.get(i).text)
            verify(texts.includes("Suspend: Not available."), "name: reason, never a silent no-op")
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

        function test_super_long_press_data() {
            return [
                { tag: "Super_L", key: Qt.Key_Super_L },
                { tag: "Meta", key: Qt.Key_Meta },
            ]
        }

        // A held Super is a held Guide: the same code path (T-124).
        function test_super_long_press(data) {
            keyPress(data.key)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the overlay opens on press")
            compare(find("systemPanel").powerMode, false)
            tryCompare(find("systemPanel"), "powerMode", true, Theme.guideHoldMs + 2000)
            keyRelease(data.key)
            wait(100)
            verify(find("systemPanel").open, "releasing after the hold does not close it")
            compare(find("systemActions").count, 5)    // Suspend, Restart, Power off, Switch profile, Back (T-471)
        }

        function test_super_short_press_does_not_open_power_choices() {
            keyPress(Qt.Key_Super_L)
            keyRelease(Qt.Key_Super_L)
            tryVerify(() => find("systemActions").activeFocus)
            wait(Theme.guideHoldMs + 400)
            compare(find("systemPanel").powerMode, false, "released before the hold time")
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
            compare(find("systemActions").count, 5)    // Suspend, Restart, Power off, Switch profile, Back (T-471)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                    // Restart
            tryVerify(() => find("overlayPowerConfirm").shown)
            compare(find("overlayPowerConfirm").action, "restart")
            tryVerify(() => find("powerCancel") && find("overlayPowerConfirm").activeFocus)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Power, "lastAction", "restart")
            tryVerify(() => !find("systemPanel").open, 2000, "the overlay closes after Confirm")
            tryVerify(() => find("homePlay").activeFocus, 2000, "focus returns to the shelf")
        }

        function test_overlay_power_choices_by_menu() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            // Power is the last of the panel icons, the Hub's last row (T-471)
            compare(find("systemPanel").controlsOf("panels").slice(-1), ["panel:power"])
            hubGoTo("panel:power")
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
            compare(find("systemActions").currentIndex, find("systemPanel").itemKeys.indexOf("panels"))
            compare(find("systemPanel").currentKey, "panel:power", "on the Power icon")
            keyClick(Qt.Key_Escape)                    // closes the overlay
            tryVerify(() => !find("systemPanel").open)
            tryVerify(() => find("homePlay").activeFocus)
            compare(Power.actionCount, 0)
        }

        // T-189: Backspace is Back in the Guide overlay too (T-179 tested it on the Power page only).
        function test_overlay_backspace_is_back() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            hubGoTo("panel:power")
            keyClick(Qt.Key_Return)                    // Power
            tryCompare(find("systemPanel"), "powerMode", true)
            verify(find("systemActions").activeFocus)
            keyClick(Qt.Key_Backspace)                 // Back: the system actions again, on "Power"
            tryCompare(find("systemPanel"), "powerMode", false)
            compare(find("systemPanel").open, true, "the first Backspace only leaves the power choices")
            compare(find("systemActions").currentIndex, find("systemPanel").itemKeys.indexOf("panels"))
            compare(find("systemPanel").currentKey, "panel:power", "on the Power icon")
            verify(find("systemActions").activeFocus)
            keyClick(Qt.Key_Backspace)                 // closes the overlay
            tryVerify(() => !find("systemPanel").open)
            tryVerify(() => find("homePlay").activeFocus, 2000, "focus returns to the shelf")
            compare(Power.actionCount, 0)
        }

        function test_overlay_hides_unavailable_choices() {
            Power.mockSetCapabilities("yes", "no", "yes")
            tryVerify(() => !Power.canRestart)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            hubGoTo("panel:power")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "powerMode", true)
            compare(find("systemActions").count, 4)    // Suspend, Power off, Switch profile, Back
        }

        function test_overlay_power_choices_over_page() {
            openPowerPage()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            hubGoTo("panel:power")
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
            tryCompare(find("powerConfirmDialog"), "opacity", 1, 5000, "the dialog has faded in")
            wait(200)
            grabImage(tc.shell).save(shotsDir + "/13-power-confirm.png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("powerConfirmDialog").shown)
            // Turkish (the longest stock label), then a long name under Daylight (T-194).
            DeviceSettings.language = "tr"
            find("powerConfirmDialog").open("restart")
            tryVerify(() => find("powerCancel").activeFocus)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("powerConfirm").activeFocus)
            tryCompare(find("powerConfirmDialog"), "opacity", 1, 5000, "the dialog has faded in")
            wait(200)
            grabImage(tc.shell).save(shotsDir + "/13c-power-confirm-tr.png")
            find("powerConfirmDialog").cancel()
            DeviceSettings.language = "en"
            DeviceSettings.theme = "daylight"
            find("powerConfirmDialog").customTitle = "Delete Wolfeschlegelsteinhausen Jr?"
            find("powerConfirmDialog").detail = "Their saved games and settings are removed."
            find("powerConfirmDialog").customConfirmName = "Delete Wolfeschlegelsteinhausen Jr"
            find("powerConfirmDialog").open("custom")
            tryVerify(() => find("powerCancel").activeFocus)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("powerConfirm").activeFocus)
            tryCompare(Theme, "mix", 1, 5000, "the theme has finished fading")
            tryCompare(find("powerConfirmDialog"), "opacity", 1, 5000, "the dialog has faded in")
            wait(200)
            grabImage(tc.shell).save(shotsDir + "/13d-power-confirm-long-daylight.png")
            find("powerConfirmDialog").cancel()
            find("powerConfirmDialog").detail = ""
            DeviceSettings.theme = "dreamglass"
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            hubGoTo("panel:power")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "powerMode", true)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/13b-power-choices.png")
        }
    }
}
