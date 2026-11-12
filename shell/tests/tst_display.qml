import QtQuick
import QtTest
import RuyaShell

// The screen's resolution, refresh rate and UI size (T-198, org.ruyaos.Devices1.Display): the mock
// follows the contract, Settings -> Display & motion has Resolution, Refresh rate and UI size rows,
// a chosen mode restarts the shell (the mock counts it) and asks "Keep this resolution?" with a
// countdown that reverts, and the UI size changes the Theme's unit. Driven with controller keys.
// Own file: the Display state is process-wide, and the dialog hides the rest of the shell.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: setModeSpy; target: Display; signalName: "setModeFinished" }
    SignalSpy { id: keepSpy; target: Display; signalName: "keepFinished" }
    SignalSpy { id: revertSpy; target: Display; signalName: "revertFinished" }
    SignalSpy { id: resetSpy; target: Display; signalName: "resetFinished" }
    SignalSpy { id: brightnessSpy; target: Display; signalName: "setBrightnessFinished" }

    TestCase {
        id: tc
        name: "Display"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Display.mockReset()
            Display.countdownTickMs = 1000
            Display.acceptGraceMs = 1          // the grace time has its own tests
            tryVerify(() => Display.available)
            tryCompare(Display, "pending", false)
            tryCompare(Display, "uiScalePercent", 0)
            setModeSpy.clear()
            keepSpy.clear()
            revertSpy.clear()
            resetSpy.clear()
            brightnessSpy.clear()
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
        }

        function cleanup() {
            Session.mockReset()
            Display.mockReset()
            Display.countdownTickMs = 1000
            Display.acceptGraceMs = 1000
            Notifications.durationMs = Theme.toastMs
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
            DeviceSettings.language = "en"
            DeviceSettings.reducedMotion = false
        }

        // The reply status of one SetMode call.
        function chooseSize(width, height) {
            const before = setModeSpy.count
            Display.chooseResolution(width, height)
            tryCompare(setModeSpy, "count", before + 1)
            return setModeSpy.signalArguments[before][0]
        }

        // The dialog takes Accept once the grace time has passed.
        function waitForAccept() {
            tryVerify(() => find("modeConfirm").acceptReady)
        }

        // Keep, the way an owner who sees the picture does it: Right, then Accept.
        function answerKeep() {
            waitForAccept()
            keyClick(Qt.Key_Right)
            verify(find("modeKeep").activeFocus, "Right reaches Keep")
            keyClick(Qt.Key_Return)
        }

        function openDisplayPane() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Left)                    // to Home: the nav may open on the Settings pill, and Right from it reaches the "N more" chip (T-301)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList") !== null && find("categoryList").activeFocus, 2000, "category list has focus")
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Down)
            compare(find("categoryList").currentIndex, 3)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
        }

        function downTo(name) {
            for (let i = 0; i < 12 && !find(name).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(find(name).activeFocus, name + " has focus")
        }

        // ---- Brightness (T-471: moved here from the Hub's Display panel, T-454) ----

        function brightnessText() { return findChild(find("rowBrightness"), "value").text }

        function test_brightness_is_a_slider_row_only_with_a_backlight() {
            compare(Display.brightnessSupported, false, "the default mock screen is a TV")
            openDisplayPane()
            verify(!find("rowBrightness").visible, "a TV has no backlight: no row, not a greyed one")
            verify(Display.mockUseScenario("laptop"))
            tryCompare(Display, "brightnessSupported", true)
            tryVerify(() => find("rowBrightness").visible, 2000, "the row comes with the backlight")
            downTo("rowBrightness")
            compare(Display.brightness, 60)
            compare(brightnessText(), "60%")
            // The screen loses its backlight (a monitor was plugged in): the row goes.
            Display.mockUseScenario("tv4k")
            tryVerify(() => !find("rowBrightness").visible)
        }

        function test_left_and_right_step_brightness_by_five_and_follow_the_answer() {
            Display.mockUseScenario("laptop")
            tryCompare(Display, "brightnessSupported", true)
            openDisplayPane()
            downTo("rowBrightness")
            keyClick(Qt.Key_Left)
            tryCompare(Display, "brightness", 55)
            tryCompare(brightnessSpy, "count", 1)
            compare(brightnessSpy.signalArguments[0][0], "ok")
            tryCompare(findChild(find("rowBrightness"), "value"), "text", "55%")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            tryCompare(Display, "brightness", 65, 5000)
            compare(Display.mockBrightnessCalls(), 3)
            // Presses that come before the answer step on from the last press, not from the old level.
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Left)
            tryCompare(Display, "brightness", 50, 5000)
            compare(Display.mockBrightnessCalls(), 6)
            verify(find("rowBrightness").activeFocus, "the focus stays on the row")
        }

        function test_brightness_stops_at_the_ends() {
            Display.mockUseScenario("laptop")
            tryCompare(Display, "brightnessSupported", true)
            openDisplayPane()
            downTo("rowBrightness")
            for (let i = 0; i < 9; ++i)
                keyClick(Qt.Key_Right)             // 60 -> 100 is eight steps
            tryCompare(Display, "brightness", 100, 5000)
            const calls = Display.mockBrightnessCalls()
            compare(calls, 8, "the ninth press at the top asks nothing")
            for (let i = 0; i < 25; ++i)
                keyClick(Qt.Key_Left)              // 100 -> 5 is nineteen steps; the rest ask nothing
            tryCompare(Display, "brightness", 5, 5000)
            compare(Display.mockBrightnessCalls(), calls + 19, "never below 5 %: a black screen cannot be undone with a pad")
        }

        function test_a_refused_brightness_toasts_and_keeps_the_level() {
            Display.mockUseScenario("laptop")
            tryCompare(Display, "brightnessSupported", true)
            openDisplayPane()
            downTo("rowBrightness")
            Display.mockFailBrightnessNext()
            keyClick(Qt.Key_Right)
            tryCompare(brightnessSpy, "count", 1)
            compare(brightnessSpy.signalArguments[0][0], "failed")
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "warning")
            compare(Notifications.model.get(0).text, "Could not change the brightness.")
            compare(Display.brightness, 60)
            tryCompare(findChild(find("rowBrightness"), "value"), "text", "60%", 2000, "the row shows what the service has")
            // The next press starts from the level the service has, not from the refused target.
            keyClick(Qt.Key_Right)
            tryCompare(Display, "brightness", 65)
        }

        function test_the_panel_asks_for_the_level_again_when_it_opens() {
            Display.mockUseScenario("laptop")
            tryCompare(Display, "brightnessSupported", true)
            Display.mockBacklightKey(30)             // the laptop's own keys: nobody tells the shell
            wait(50)
            compare(Display.brightness, 60, "the shell has not heard of it")
            openDisplayPane()
            tryCompare(Display, "brightness", 30)    // the pane asked when it was shown
            tryCompare(findChild(find("rowBrightness"), "value"), "text", "30%")
        }

        // ---- the mock follows the contract ----

        function test_the_mock_follows_the_contract() {
            compare(Display.outputId, "HDMI-A-1")
            compare(Display.outputName, "Living room TV")
            compare(Display.widthMm, 1220)
            compare(Display.currentWidth, 3840)
            compare(Display.currentHeight, 2160)
            compare(Display.currentRefreshMhz, 60000)
            compare(Display.preferredWidth, 3840)
            // The sizes, preferred first, each once; the mode in use is marked.
            const sizes = Display.resolutions.map(r => r.width + "x" + r.height)
            compare(JSON.stringify(sizes), JSON.stringify(["3840x2160", "2560x1440", "1920x1080", "1280x720"]))
            compare(Display.resolutions[0].preferred, true)
            compare(Display.resolutions[0].current, true)
            compare(Display.resolutions[2].current, false)
            compare(Display.refreshRates(1920, 1080).length, 3)

            // A refresh rate the size does not have, and a size that is not listed.
            compare(chooseSize(640, 480), "unknown-mode")
            compare(Display.mockSetModeCalls(), 0, "never reaches the service")

            // The mode in use is "unchanged": nothing waits, nothing restarts.
            compare(chooseSize(3840, 2160), "unchanged")
            compare(Display.pending, false)
            compare(Display.mockRestartCount(), 0)

            Display.mockFailNext()
            compare(chooseSize(1920, 1080), "failed")
            compare(Display.pending, false, "a failed call changes nothing")
            compare(Display.mockRestartCount(), 0)

            compare(chooseSize(1920, 1080), "ok")
            tryCompare(Display, "pending", true)
            compare(Display.pendingWidth, 1920)
            compare(Display.pendingRefreshMhz, 60000, "the same rate is kept")
            compare(Display.mockRestartCount(), 1, "the shell restarts on an ok")
            tryCompare(Display, "confirming", true)
            compare(Display.currentWidth, 3840, "nothing is stored before Keep")

            // One change at a time (the dialog is up, so the shell would not ask; the facade says so).
            compare(chooseSize(1280, 720), "busy")
            compare(Display.mockSetModeCalls(), 3, "busy is answered before the service")

            Display.keep()
            tryCompare(keepSpy, "count", 1)
            compare(keepSpy.signalArguments[0][0], "ok")
            tryCompare(Display, "pending", false)
            tryCompare(Display, "currentWidth", 1920)
            Display.keep()
            tryCompare(keepSpy, "count", 2)
            compare(keepSpy.signalArguments[1][0], "no-pending")
            Display.revert()
            tryCompare(revertSpy, "count", 1)
            compare(revertSpy.signalArguments[0][0], "no-pending")
            compare(Display.mockRestartCount(), 1, "nothing to revert, nothing restarts")
        }

        function test_a_new_choice_keeps_the_refresh_rate_when_the_size_has_it() {
            compare(chooseSize(1920, 1080), "ok")
            tryCompare(Display, "confirming", true)
            Display.keep()
            tryCompare(Display, "currentWidth", 1920)
            // 1080p has 60, 50 and 24 Hz; pick 50, then go to 720p, which has only 60.
            Display.chooseRefresh(50000)
            tryCompare(Display, "confirming", true)
            Display.keep()
            tryCompare(Display, "currentRefreshMhz", 50000)
            compare(chooseSize(1280, 720), "ok")
            tryCompare(Display, "pendingRefreshMhz", 60000)
        }

        function test_a_reply_that_arrives_late_does_not_replace_a_newer_state() {
            Display.mockRefreshDelayed(250)               // the state as it is now: Auto
            compare(Display.mockPendingReplies(), 1)
            Display.setUiScale(150)
            tryCompare(Display, "uiScalePercent", 150)
            tryVerify(() => Display.mockPendingReplies() === 0)
            compare(Display.uiScalePercent, 150, "the old reply was dropped")
        }

        // ---- the UI size ----

        function test_auto_asks_the_screens_physical_size() {
            // The design reference: a 55" TV read from the sofa is 1; a hair off it still is.
            compare(Display.autoScale, 1)
            verify(Display.mockUseScenario("tv1080"))
            tryCompare(Display, "outputId", "HDMI-A-2")
            compare(Display.autoScale, 1, "a 40-inch TV is not enlarged")
            verify(Display.mockUseScenario("monitor"))
            tryCompare(Display, "outputId", "DP-1")
            compare(Display.autoScale, 0.85, "a 32-inch monitor read from a desk")
            compare(Display.uiScaleFactor, 0.85)
            compare(Display.autoScaleFor(0, 0), 1, "unknown size")
            compare(Display.autoScaleFor(597, 336), 0.55, "a 27-inch monitor")
            compare(Display.autoScaleFor(309, 174), 1, "a laptop screen is never enlarged")
            compare(Display.autoScaleFor(1600, 900), 1, "a bigger TV is read from further away, not shrunk")
            compare(Display.autoScaleFor(5000, 2800), 1)
        }

        function test_the_ui_size_row_changes_the_themes_unit() {
            openDisplayPane()
            downTo("rowUiSize")
            const row = find("rowUiSize")
            compare(row.value, 0)
            compare(Theme.uiScale, 1, "Auto on the reference TV")
            compare(tc.shell.u, tc.shell.height / 1080)

            for (const [percent, factor] of [[100, 1], [125, 1.25], [150, 1.5], [200, 2]]) {
                keyClick(Qt.Key_Right)
                tryCompare(Display, "uiScalePercent", percent)
                tryCompare(Theme, "uiScale", factor)
                compare(row.value, percent)
                compare(tc.shell.u, tc.shell.height / 1080 * factor, "the unit follows " + percent + " %")
                verify(row.activeFocus, "focus stays on the row")
            }
            keyClick(Qt.Key_Right)                       // wraps to Auto
            tryCompare(Display, "uiScalePercent", 0)
            tryCompare(Theme, "uiScale", 1)

            // On a monitor Auto is smaller than 100 %.
            verify(Display.mockUseScenario("monitor"))
            tryCompare(Theme, "uiScale", 0.85)
            compare(tc.shell.u, tc.shell.height / 1080 * 0.85)
            keyClick(Qt.Key_Right)
            tryCompare(Theme, "uiScale", 1, 2000, "an owner's 100 % overrides Auto")
        }

        // ---- the pane ----

        function test_the_pane_lists_the_modes_and_marks_the_recommended_one() {
            openDisplayPane()
            downTo("rowResolution")
            compare(find("rowResolution").value, "3840 × 2160")
            compare(find("rowRefreshRate").visible, true, "4K has 60 and 30 Hz")
            compare(find("rowRefreshRate").value, "60 Hz")

            keyClick(Qt.Key_Return)
            const picker = find("resolutionPicker")
            tryVerify(() => picker.shown)
            const list = find("resolutionPickerList")
            compare(list.count, 4)
            tryVerify(() => find("resolutionPickerEntry_3840x2160").activeFocus, 2000, "the list opens on the mode in use")
            compare(find("resolutionPickerEntry_3840x2160").value, "Recommended · Current")
            compare(find("resolutionPickerEntry_1920x1080").value, "")
            compare(find("resolutionPickerEntry_1920x1080").label, "1920 × 1080")

            // T-272: the panel is the glass sheet, not a flat `panel` card.
            const sheet = find("resolutionPickerPanel")
            verify(sheet.layers !== undefined, "the panel is a GlassSheet")
            compare(sheet.fillColor, sheet.blurred ? Theme.glassStrong : Theme.glassOpaque)
            verify(!Qt.colorEqual(sheet.fillColor, Theme.panel), "not the flat panel fill")
            verify(findChild(sheet, "glassSheetLayers").tintVisible)

            // Up and Down clamp at the ends; Back closes without choosing and focus returns.
            keyClick(Qt.Key_Up)
            verify(find("resolutionPickerEntry_3840x2160").activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("resolutionPickerEntry_1920x1080").activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("resolutionPickerEntry_1280x720").activeFocus)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !picker.shown)
            tryVerify(() => find("rowResolution").activeFocus, 2000, "focus returns to the row")
            compare(Display.mockSetModeCalls(), 0, "Back chose nothing")
            compare(Display.pending, false)
        }

        function test_the_refresh_row_is_there_only_when_the_size_has_a_choice() {
            verify(Display.mockUseScenario("tv1080"))
            tryCompare(Display, "outputId", "HDMI-A-2")
            openDisplayPane()
            compare(find("rowRefreshRate").visible, true, "1080p: 60 and 50 Hz")
            chooseSize(1024, 768)
            tryCompare(Display, "confirming", true)
            compare(find("rowRefreshRate").visible, true, "the rows follow the mode in use, not the one on trial")
            tryVerify(() => find("modeRevert").activeFocus)
            answerKeep()
            tryCompare(Display, "currentWidth", 1024)
            compare(find("rowRefreshRate").visible, false, "a size with no known rate has no choice to make")
            compare(find("rowResolution").value, "1024 × 768")
        }

        // ---- the safe switch ----

        function pickResolution(key) {
            downTo("rowResolution")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("resolutionPicker").shown)
            const entry = "resolutionPickerEntry_" + key
            for (let i = 0; i < 8 && !find(entry).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(find(entry).activeFocus, entry + " has focus")
            keyClick(Qt.Key_Return)
        }

        function test_choosing_a_mode_asks_to_keep_it_and_keep_stores_it() {
            openDisplayPane()
            pickResolution("1920x1080")
            tryVerify(() => !find("resolutionPicker").shown)
            tryCompare(Display, "confirming", true)
            compare(Display.mockRestartCount(), 1)
            const dialog = find("modeConfirm")
            tryCompare(dialog, "shown", true)
            tryVerify(() => dialog.visible)
            compare(find("modeConfirmTitle").text, "Keep this resolution?")
            compare(find("modeConfirmMode").text, "1920 × 1080, 60 Hz")
            verify(find("modeConfirmDetail").text.indexOf("15 seconds") > 0, find("modeConfirmDetail").text)
            // Focus lands on Revert: a blind Accept on a screen that shows nothing goes back.
            tryVerify(() => find("modeRevert").activeFocus, 2000, "focus lands on Revert")
            compare(find("modeKeep").activeFocus, false)

            // Right reaches Keep, Left comes back; nothing leaks to the pane underneath.
            keyClick(Qt.Key_Right)
            verify(find("modeKeep").activeFocus)
            keyClick(Qt.Key_Left)
            verify(find("modeRevert").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("modeRevert").activeFocus, "the dialog is modal")
            compare(find("rowResolution").activeFocus, false)

            answerKeep()
            tryCompare(Display, "pending", false)
            tryCompare(Display, "currentWidth", 1920)
            tryVerify(() => !dialog.visible)
            tryVerify(() => find("rowResolution").activeFocus, 2000, "focus returns to the row")
            compare(find("rowResolution").value, "1920 × 1080")
            compare(Display.mockRestartCount(), 1, "Keep does not restart")
            compare(Notifications.model.count, 0, "a good change shows no toast")
        }

        function test_back_and_the_revert_button_restore_the_previous_mode() {
            openDisplayPane()
            pickResolution("1280x720")
            tryCompare(Display, "confirming", true)
            const dialog = find("modeConfirm")
            tryVerify(() => find("modeRevert").activeFocus)
            keyClick(Qt.Key_Escape)                      // Back = Revert
            tryCompare(Display, "pending", false)
            tryVerify(() => !dialog.visible)
            compare(Display.currentWidth, 3840, "the previous mode stays")
            compare(Display.mockRestartCount(), 2, "the shell restarts again to show it")
            tryVerify(() => find("rowResolution").activeFocus, 2000, "focus returns to the row")

            pickResolution("1280x720")
            tryCompare(Display, "confirming", true)
            // The Revert button, and a blind Accept (nothing to see, nothing moved): it reverts.
            tryVerify(() => find("modeRevert").activeFocus)
            waitForAccept()
            keyClick(Qt.Key_Return)
            tryCompare(Display, "pending", false)
            compare(Display.currentWidth, 3840)
            compare(Display.mockRestartCount(), 4)
        }

        // The grace time: a double press on the picker's row must not keep a mode nobody has seen.
        function test_accept_is_ignored_just_after_the_dialog_appears() {
            Display.acceptGraceMs = 3000
            openDisplayPane()
            pickResolution("1920x1080")
            tryCompare(Display, "confirming", true)
            const dialog = find("modeConfirm")
            tryVerify(() => find("modeRevert").activeFocus)
            compare(dialog.acceptReady, false)
            keyClick(Qt.Key_Return)                      // the second press of a double press
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // ... even on Keep
            compare(dialog.acceptReady, false, "still inside the grace time")
            compare(Display.confirming, true, "nothing was kept or reverted")
            compare(Display.currentWidth, 3840)
            compare(Display.mockRestartCount(), 1)
            keyClick(Qt.Key_Escape)                      // Back is never delayed
            tryCompare(Display, "pending", false)
            compare(Display.mockRestartCount(), 2)

            // Once it has passed, Accept counts.
            Display.acceptGraceMs = 50
            pickResolution("1920x1080")
            tryCompare(Display, "confirming", true)
            waitForAccept()
            keyClick(Qt.Key_Return)
            tryCompare(Display, "pending", false)
        }

        // The hint bar names what A does on the focused button.
        function test_the_hint_bar_follows_the_focused_button() {
            openDisplayPane()
            pickResolution("1920x1080")
            tryCompare(Display, "confirming", true)
            tryVerify(() => find("modeRevert").activeFocus)
            compare(tc.shell.hintList[0].button, "A")
            compare(tc.shell.hintList[0].text, "Revert")
            compare(tc.shell.hintList[1].text, "Revert")
            keyClick(Qt.Key_Right)
            verify(find("modeKeep").activeFocus)
            compare(tc.shell.hintList[0].text, "Keep")
            compare(tc.shell.hintList[1].button, "B")
            keyClick(Qt.Key_Left)
            compare(tc.shell.hintList[0].text, "Revert")
        }

        // A Keep the service refuses leaves no dead dialog: a toast, and the countdown reverts.
        function test_a_keep_the_service_refuses_shows_a_toast_and_the_countdown_reverts() {
            openDisplayPane()
            pickResolution("1920x1080")
            tryCompare(Display, "confirming", true)
            tryVerify(() => find("modeRevert").activeFocus)
            Display.mockFailKeepNext()
            answerKeep()
            tryCompare(keepSpy, "count", 1)
            compare(keepSpy.signalArguments[0][0], "failed")
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "error")
            compare(Display.confirming, true, "the mode is not kept")
            Display.countdownTickMs = 5
            tryCompare(Display, "pending", false, 4000)
            compare(Display.currentWidth, 3840, "the countdown reverted it")
            compare(Display.mockRestartCount(), 2)
        }

        // Revert always restarts the shell, whatever the service answered: the mode on trial may be on
        // screen, and the guard at the next start puts things right.
        function test_a_revert_the_service_fails_restarts_the_shell_anyway() {
            Display.countdownTickMs = 5
            openDisplayPane()
            Display.mockFailRevertNext()
            pickResolution("1280x720")
            tryCompare(revertSpy, "count", 1, 4000)
            compare(revertSpy.signalArguments[0][0], "failed")
            compare(Display.mockRestartCount(), 2, "the shell restarted after the failed revert too")
            // The mock's guard saw a second start with the marker and dropped the change.
            tryCompare(Display, "pending", false)
            compare(Display.currentWidth, 3840)
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "warning", "the new shell says the preferred mode is back")
            tryVerify(() => !find("modeConfirm").visible)
        }

        // The service refuses a change that could trip the compositor's start limit.
        function test_a_change_is_refused_while_restarts_are_crowded() {
            openDisplayPane()
            Display.mockSetCrowded(true)
            pickResolution("1920x1080")
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "warning")
            verify(Notifications.model.get(0).text.indexOf("minute") > 0, Notifications.model.get(0).text)
            compare(Display.mockSetModeCalls(), 1, "the service was asked and said busy")
            compare(Display.mockRestartCount(), 0)
            compare(Display.confirming, false)
            tryVerify(() => find("rowResolution").activeFocus, 2000, "focus is back on the row")
        }

        function test_nobody_answering_reverts_when_the_countdown_runs_out() {
            Display.countdownTickMs = 5
            openDisplayPane()
            pickResolution("2560x1440")
            tryCompare(Display, "confirming", true)
            // Nobody presses anything (a TV that shows nothing): the dialog counts down and reverts.
            tryCompare(Display, "pending", false, 4000)
            tryVerify(() => !find("modeConfirm").visible)
            compare(Display.currentWidth, 3840, "the previous mode is back")
            compare(Display.mockRestartCount(), 2)
            compare(revertSpy.count, 1)
            compare(revertSpy.signalArguments[0][0], "ok")
        }

        // True when the dialog has counted below `below` seconds and its text names the seconds left,
        // read in one go so that a tick between two reads cannot make them disagree.
        function countdownShows(below) {
            const left = find("modeConfirm").secondsLeft
            return left < below && find("modeConfirmDetail").text.indexOf(left + " seconds") > 0
        }

        function test_the_countdown_shows_the_seconds_left() {
            Display.countdownTickMs = 100
            openDisplayPane()
            pickResolution("1920x1080")
            tryCompare(Display, "confirming", true)
            // It has ticked below the start and the text says how many seconds are left now.
            tryVerify(() => countdownShows(14))
            answerKeep()                                 // Keep before it ends
            tryCompare(Display, "pending", false)
            compare(Display.currentWidth, 1920)
            wait(150)
            compare(Display.mockRestartCount(), 1, "a kept change is never reverted by the stopped countdown")
        }

        function test_a_mode_the_service_refuses_shows_a_toast_and_no_dialog() {
            openDisplayPane()
            Display.mockFailNext()
            pickResolution("1920x1080")
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "error")
            compare(Display.confirming, false)
            compare(find("modeConfirm").visible, false)
        }

        function test_a_running_app_must_be_closed_before_the_shell_restarts() {
            Session.launch("org.example.Racer", "p2")
            tryVerify(() => Session.running.length === 1)
            openDisplayPane()
            pickResolution("1920x1080")
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "warning")
            compare(Display.mockSetModeCalls(), 0, "nothing was asked of the service")
            compare(Display.mockRestartCount(), 0, "the shell did not restart under the running app")
            compare(Display.confirming, false)
            tryVerify(() => find("rowResolution").activeFocus, 2000, "focus is back on the row")
            Session.mockReset()
            tryVerify(() => Session.running.length === 0)
        }

        function test_a_dropped_change_after_a_bad_start_is_told_once() {
            chooseSize(1920, 1080)
            tryCompare(Display, "confirming", true)
            Display.mockSimulateFallback()               // the console came back a second time without a confirmation
            tryCompare(Display, "pending", false)
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "warning")
            compare(Display.currentWidth, 3840, "the preferred mode is back")
            tryVerify(() => !find("modeConfirm").visible)
        }

        function test_the_shell_opens_the_display_page_when_it_comes_back_on_a_new_mode() {
            // The restart brought the shell back on the home screen with a change waiting.
            compare(tc.shell.currentPage, "")
            chooseSize(1920, 1080)
            tryCompare(Display, "confirming", true)
            tryCompare(tc.shell, "currentPage", "settings")
            tryCompare(find("categoryList"), "currentIndex", 3)
            tryCompare(find("modeConfirm"), "shown", true)
            tryVerify(() => find("modeRevert").activeFocus, 2000, "focus lands on Revert")
            answerKeep()
            tryCompare(Display, "pending", false)
            tryVerify(() => find("categoryList").activeFocus || find("paneDisplay").activeFocus, 2000, "focus is back in Settings")
        }

        function test_the_refresh_picker_changes_only_the_rate() {
            openDisplayPane()
            downTo("rowRefreshRate")
            keyClick(Qt.Key_Return)
            const picker = find("refreshPicker")
            tryVerify(() => picker.shown)
            compare(find("refreshPickerList").count, 2)
            tryVerify(() => find("refreshPickerEntry_60000").activeFocus, 2000, "opens on the rate in use")
            compare(find("refreshPickerEntry_60000").value, "Recommended · Current")
            compare(find("refreshPickerEntry_30000").label, "30 Hz")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("refreshPickerEntry_30000").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(Display, "confirming", true)
            compare(Display.pendingWidth, 3840)
            compare(Display.pendingRefreshMhz, 30000)
            compare(find("modeConfirmMode").text, "3840 × 2160, 30 Hz")
            tryVerify(() => find("modeRevert").activeFocus)
            answerKeep()
            tryCompare(Display, "currentRefreshMhz", 30000)
            tryVerify(() => find("rowRefreshRate").activeFocus, 2000, "focus returns to the row")
            compare(find("rowRefreshRate").value, "30 Hz")
        }

        // ---- Reset display settings, and the rows without a screen ----

        function test_reset_puts_the_preferred_mode_and_auto_back() {
            openDisplayPane()
            pickResolution("1920x1080")
            tryCompare(Display, "confirming", true)
            tryVerify(() => find("modeRevert").activeFocus)
            answerKeep()
            tryCompare(Display, "currentWidth", 1920)
            Display.setUiScale(150)
            tryCompare(Display, "uiScalePercent", 150)
            const restarts = Display.mockRestartCount()

            downTo("rowResetDisplay")
            const resets = Display.mockResetCalls()
            keyClick(Qt.Key_Return)
            tryCompare(Display, "currentWidth", 3840)
            tryCompare(Display, "uiScalePercent", 0)
            compare(Display.mockResetCalls(), resets + 1)
            compare(Display.mockRestartCount(), restarts + 1, "the mode changed, so the shell restarts")
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "info")
            compare(Display.confirming, false, "the preferred mode needs no confirmation")
            verify(find("rowResetDisplay").activeFocus)

            // Nothing left to reset: no restart.
            keyClick(Qt.Key_Return)
            tryCompare(resetSpy, "count", 2)
            compare(Display.mockRestartCount(), restarts + 1)
        }

        function test_reset_waits_for_a_running_app_when_the_mode_would_change() {
            openDisplayPane()
            pickResolution("1920x1080")
            tryCompare(Display, "confirming", true)
            tryVerify(() => find("modeRevert").activeFocus)
            answerKeep()
            tryCompare(Display, "currentWidth", 1920)
            Session.launch("org.example.Racer", "p2")
            tryVerify(() => Session.running.length === 1)
            downTo("rowResetDisplay")
            keyClick(Qt.Key_Return)
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "warning")
            compare(Display.mockResetCalls(), 0)
            compare(Display.currentWidth, 1920)
        }

        function test_the_ui_size_and_reset_rows_stay_without_a_screen() {
            Display.setUiScale(200)
            tryCompare(Display, "uiScalePercent", 200)
            verify(Display.mockUseScenario("none"))
            tryCompare(Display, "available", false)
            compare(Display.uiScalePercent, 200, "the stored size is still known")
            openDisplayPane()
            compare(find("rowResolution").visible, false)
            compare(find("rowRefreshRate").visible, false)
            compare(find("rowUiSize").visible, true)
            compare(find("rowResetDisplay").visible, true)
            downTo("rowUiSize")
            keyClick(Qt.Key_Right)                       // wraps to Auto
            tryCompare(Display, "uiScalePercent", 0)
            keyClick(Qt.Key_Right)
            tryCompare(Display, "uiScalePercent", 100)
            keyClick(Qt.Key_Down)
            verify(find("rowResetDisplay").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(Display, "uiScalePercent", 0)
            compare(Display.mockRestartCount(), 0, "no screen, no mode to put back")
        }

        // ---- the biggest UI size ----

        function test_the_dialog_fits_the_screen_at_200_percent() {
            Display.setUiScale(200)
            tryCompare(Display, "uiScalePercent", 200)
            for (const language of ["en", "tr"]) {
                DeviceSettings.language = language
                openDisplayPane()
                pickResolution("1920x1080")
                tryCompare(Display, "confirming", true)
                const panel = find("modeConfirmPanel")
                tryVerify(() => find("modeConfirm").visible)
                verify(panel.x >= 0 && panel.x + panel.width <= tc.shell.width, language + ": the card is inside the screen: " + panel.x + " " + panel.width)
                for (const name of ["modeConfirmTitle", "modeConfirmMode", "modeConfirmDetail"]) {
                    const text = find(name)
                    verify(text.width <= panel.width, language + " " + name + " fits the card")
                    verify(text.contentWidth <= text.width + 1, language + " " + name + " wraps instead of overflowing")
                }
                verify(find("modeKeep").mapToItem(panel, 0, 0).x + find("modeKeep").width <= panel.width, language + ": the buttons are in the card")
                keyClick(Qt.Key_Escape)
                tryCompare(Display, "pending", false)
                tryVerify(() => !find("modeConfirm").visible)
                keyClick(Qt.Key_Escape)                  // leave Settings for the next round
                tryVerify(() => find("categoryList").activeFocus)
                keyClick(Qt.Key_Escape)
                tryCompare(tc.shell, "currentPage", "")
            }
        }

        function test_turkish_labels() {
            DeviceSettings.language = "tr"
            openDisplayPane()
            downTo("rowResolution")
            compare(find("rowResolution").label, "Çözünürlük")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("resolutionPicker").shown)
            compare(find("resolutionPickerEntry_3840x2160").value, "Önerilen · Geçerli")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("resolutionPicker").shown)
        }

        function test_zz_screenshots_brightness() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Display.mockUseScenario("laptop")
            tryCompare(Display, "brightnessSupported", true)
            openDisplayPane()
            downTo("rowBrightness")
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/display-4-brightness.png")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            host.width = 1920
            host.height = 1080
            tryCompare(tc.shell, "height", 1080)
            openDisplayPane()
            downTo("rowResolution")
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/display-1-pane.png")

            keyClick(Qt.Key_Return)
            tryVerify(() => find("resolutionPicker").shown)
            tryVerify(() => find("resolutionPickerEntry_3840x2160").activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/display-2-picker.png")
            keyClick(Qt.Key_Return)                      // 1920 x 1080
            tryCompare(Display, "confirming", true)
            tryVerify(() => find("modeRevert").activeFocus)
            Display.countdownTickMs = 100000             // hold the countdown for the picture
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/display-3-confirm.png")
            answerKeep()
            tryCompare(Display, "pending", false)

            DeviceSettings.language = "tr"
            Display.countdownTickMs = 1000
            Display.chooseRefresh(50000)
            tryCompare(Display, "confirming", true)
            tryVerify(() => find("modeRevert").activeFocus)
            Display.countdownTickMs = 100000
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/display-4-confirm-tr.png")
            keyClick(Qt.Key_Escape)
            tryCompare(Display, "pending", false)
            DeviceSettings.language = "en"

            // The UI size on the pane (150 %), and Home at 125 % and on a desk monitor's Auto.
            downTo("rowUiSize")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            tryCompare(Display, "uiScalePercent", 150)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/display-5-ui-150.png")
            Display.setUiScale(125)
            tryCompare(Display, "uiScalePercent", 125)
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/display-6-home-125.png")
            // 200 %: the pane (the Resolution row's label and value) and the dialog.
            Display.setUiScale(200)
            tryCompare(Display, "uiScalePercent", 200)
            openDisplayPane()
            downTo("rowResolution")
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/display-8-pane-200.png")
            pickResolution("1280x720")
            tryCompare(Display, "confirming", true)
            tryVerify(() => find("modeRevert").activeFocus)
            Display.countdownTickMs = 100000
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/display-9-confirm-200.png")
            keyClick(Qt.Key_Escape)
            tryCompare(Display, "pending", false)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            Display.setUiScale(0)
            verify(Display.mockUseScenario("monitor"))
            tryCompare(Theme, "uiScale", 0.85)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/display-7-home-monitor.png")
        }
    }
}
