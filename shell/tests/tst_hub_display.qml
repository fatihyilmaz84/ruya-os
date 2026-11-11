import QtQuick
import QtTest
import RuyaShell

// The Display panel of Ruya Hub (T-454, 02 §1.6): the screen's resolution and refresh rate through the
// mode list of Settings (ModePicker) with the same keep-or-revert dialog (ModeConfirm), and Brightness as a
// slider row only where the screen has a backlight. Mock backends; signs in as "Ada" (p2), controller keys
// only. Own file: the Display state is process-wide, and the dialog hides the rest of the shell.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A "game" with something to look at behind the Hub (screenshots).
    Component {
        id: pictureAppComponent
        Rectangle {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            color: "steelblue"
            Keys.onPressed: event => event.accepted = true
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: parent.height / 3; color: "darkgreen" }
            Rectangle { x: parent.width * 0.55; y: parent.height * 0.2; width: parent.width * 0.2; height: width; radius: width / 2; color: "gold" }
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }
    SignalSpy { id: setModeSpy; target: Display; signalName: "setModeFinished" }
    SignalSpy { id: brightnessSpy; target: Display; signalName: "setBrightnessFinished" }

    TestCase {
        id: tc
        name: "HubDisplay"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function start() {
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
            tryVerify(() => Library.available)
            tryVerify(() => Library.items.length === 10)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            Display.mockReset()
            Display.acceptGraceMs = 1          // the grace time has its own tests (tst_display)
            tryVerify(() => Display.available)
            tryCompare(Display, "pending", false)
            Library.resetMockForTests("")
            Session.mockReset()
            setModeSpy.clear()
            brightnessSpy.clear()
            launchedSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            Session.mockReset()
            Display.mockReset()
            Display.countdownTickMs = 1000
            Display.acceptGraceMs = 1000
            DeviceSettings.reducedMotion = false
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function openHub() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
        }

        function focusedKey() {
            const list = find("systemActions")
            return list.model[list.currentIndex]
        }

        function goTo(key) {
            for (let i = 0; i < 20 && focusedKey() !== key; ++i)
                keyClick(Qt.Key_Down)
            compare(focusedKey(), key)
            verify(find("quickMenuItem_" + key).focused, key + " has the focus ring")
        }

        // The Hub, then the Display panel; the focus is on its first row.
        function openDisplay() {
            openHub()
            goTo("panel:display")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "display")
            tryCompare(find("systemPanel"), "swap", 1)
            verify(find("systemActions").activeFocus)
        }

        function rowName(key) { return find("quickMenuItem_" + key).Accessible.name }
        function panelKeys() { return find("systemPanel").itemKeys }

        function hintVerbs() {
            const bar = find("hintBar")
            const parts = []
            for (const b of ["A", "Left/Right", "B"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        // Keep, the way an owner who sees the picture does it: Right, then Accept.
        function answerKeep() {
            tryVerify(() => find("modeConfirm").acceptReady)
            keyClick(Qt.Key_Right)
            verify(find("modeKeep").activeFocus, "Right reaches Keep")
            keyClick(Qt.Key_Return)
        }

        // Accept on the Resolution row, then the entry with this key (Up/Down in the list), then Accept.
        function pickResolution(key) {
            goTo("display:resolution")
            keyClick(Qt.Key_Return)
            const picker = find("hubModePicker")
            verify(picker, "the mode list is built")
            tryCompare(picker, "shown", true)
            tryVerify(() => picker.activeFocus || find("hubModePickerEntry_" + key) !== null)
            for (let i = 0; i < 12 && !find("hubModePickerEntry_" + key).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(find("hubModePickerEntry_" + key).activeFocus, key + " has the focus")
            keyClick(Qt.Key_Return)
        }

        // ---- the entry and the rows ----------------------------------------------------------------------------

        function test_a_tv_has_the_display_panel_with_the_mode_rows_and_no_brightness() {
            start()
            openHub()
            const keys = panelKeys()
            verify(keys.indexOf("panel:performance") < keys.indexOf("panel:display"), "the entry follows Performance")
            verify(keys.indexOf("panel:display") < keys.indexOf("power"), "and comes before Power")
            goTo("panel:display")
            compare(rowName("panel:display"), "Display")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "display")
            tryCompare(find("systemPanel"), "swap", 1)
            compare(find("hubPanelTitle").text, "Display")
            compare(panelKeys().join(), "display:resolution,display:refresh", "a TV has no backlight: no Brightness row")
            compare(focusedKey(), "display:resolution", "focus lands on the first row")
            compare(rowName("display:resolution"), "Resolution, 3840 × 2160")
            compare(rowName("display:refresh"), "Refresh rate, 60 Hz")
            // A row of the Hub is read in `text` (04 §3.1, §7), and a pick row has no arrows.
            compare(findChild(find("quickMenuItem_display:resolution"), "hubValueText").color, Theme.text)
            compare(findChild(find("quickMenuItem_display:resolution"), "hubValueText").text, "3840 × 2160")
            compare(hintVerbs(), "A Choose|B Back")
            keyClick(Qt.Key_Right)
            compare(Display.mockSetModeCalls(), 0, "Left/Right on a pick row change nothing")
            compare(Display.mockBrightnessCalls(), 0, "no brightness was ever set on a TV")
            // Back: the Hub on the entry.
            keyClick(Qt.Key_Escape)
            tryCompare(find("systemPanel"), "panelId", "")
            compare(focusedKey(), "panel:display")
        }

        function test_the_refresh_row_is_there_only_when_the_size_has_a_choice() {
            start()
            // A 1080p TV: 1920x1080 at 60 and 50 Hz, 1280x720 and 1024x768 at one rate each.
            verify(Display.mockUseScenario("tv1080"))
            tryCompare(Display, "outputId", "HDMI-A-2")
            openDisplay()
            compare(panelKeys().join(), "display:resolution,display:refresh")
            // Another size with one rate (1280x720): the row goes, the resolution row stays.
            pickResolution("1280x720")
            tryCompare(Display, "confirming", true)
            tryVerify(() => find("modeConfirm").shown)
            answerKeep()
            tryCompare(Display, "pending", false)
            openDisplay()
            compare(panelKeys().join(), "display:resolution", "one rate, or none known: nothing to choose")
        }

        function test_no_screen_known_means_no_display_entry() {
            start()
            verify(Display.mockUseScenario("none"))
            tryCompare(Display, "available", false)
            openHub()
            compare(panelKeys().indexOf("panel:display"), -1, "an empty panel would be a dead end")
        }

        function test_the_entry_comes_and_goes_with_the_screen_while_the_hub_is_open() {
            start()
            openHub()
            verify(panelKeys().indexOf("panel:display") >= 0)
            Display.mockUseScenario("none")
            tryVerify(() => panelKeys().indexOf("panel:display") < 0)
            Display.mockUseScenario("tv4k")
            tryVerify(() => panelKeys().indexOf("panel:display") >= 0)
        }

        // ---- brightness ----------------------------------------------------------------------------------------

        function test_brightness_is_a_slider_row_only_with_a_backlight() {
            start()
            verify(Display.mockUseScenario("laptop"))
            tryCompare(Display, "brightnessSupported", true)
            compare(Display.brightness, 60)
            openDisplay()
            compare(panelKeys().join(), "display:resolution,display:refresh,display:brightness")
            goTo("display:brightness")
            compare(rowName("display:brightness"), "Brightness, 60 %")
            compare(findChild(find("quickMenuItem_display:brightness"), "quickMenuSliderValue").text, "60 %")
            compare(findChild(find("quickMenuItem_display:brightness"), "quickMenuSliderValue").color, Theme.text)
            const track = findChild(find("quickMenuItem_display:brightness"), "quickMenuSliderTrack")
            const fill = findChild(find("quickMenuItem_display:brightness"), "quickMenuSliderFill")
            verify(track.visible)
            fuzzyCompare(fill.width / track.width, 0.6, 0.01)
            compare(hintVerbs(), "Left/Right Adjust|B Back", "no A: there is nothing to press")
            // The panel the other way round: the screen loses its backlight (a monitor was plugged in).
            Display.mockUseScenario("tv4k")
            tryVerify(() => panelKeys().indexOf("display:brightness") < 0)
            verify(find("systemActions").activeFocus)
            verify(find("quickMenuItem_" + focusedKey()).focused, "the focus stays on a row")
        }

        function test_left_and_right_step_brightness_by_five_and_follow_the_answer() {
            start()
            Display.mockUseScenario("laptop")
            tryCompare(Display, "brightnessSupported", true)
            openDisplay()
            goTo("display:brightness")
            keyClick(Qt.Key_Left)
            tryCompare(Display, "brightness", 55)
            tryCompare(brightnessSpy, "count", 1)
            compare(brightnessSpy.signalArguments[0][0], "ok")
            compare(rowName("display:brightness"), "Brightness, 55 %")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            tryCompare(Display, "brightness", 65, 5000)
            compare(Display.mockBrightnessCalls(), 3)
            keyClick(Qt.Key_Return)
            wait(50)
            compare(Display.mockBrightnessCalls(), 3, "Accept does nothing on Brightness")
            // Presses that come before the answer step on from the last press, not from the old level.
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Left)
            tryCompare(Display, "brightness", 50, 5000)
            compare(Display.mockBrightnessCalls(), 6)
            verify(find("quickMenuItem_display:brightness").focused, "the focus stays on the row")
        }

        function test_brightness_stops_at_the_ends() {
            start()
            Display.mockUseScenario("laptop")
            tryCompare(Display, "brightnessSupported", true)
            openDisplay()
            goTo("display:brightness")
            for (let i = 0; i < 9; ++i)
                keyClick(Qt.Key_Right)             // 60 -> 100 is eight steps
            tryCompare(Display, "brightness", 100, 5000)
            const calls = Display.mockBrightnessCalls()
            compare(calls, 8, "the ninth press at the top asks nothing")
            for (let i = 0; i < 25; ++i)
                keyClick(Qt.Key_Left)              // 100 -> 5 is nineteen steps; the rest ask nothing
            tryCompare(Display, "brightness", 5, 5000)
            compare(Display.mockBrightnessCalls(), calls + 19, "never below 5 %: a black screen cannot be undone with a pad")
            verify(Display.brightness >= 1)
        }

        function test_a_refused_brightness_toasts_and_keeps_the_level() {
            start()
            Display.mockUseScenario("laptop")
            tryCompare(Display, "brightnessSupported", true)
            openDisplay()
            goTo("display:brightness")
            Display.mockFailBrightnessNext()
            keyClick(Qt.Key_Right)
            tryCompare(brightnessSpy, "count", 1)
            compare(brightnessSpy.signalArguments[0][0], "failed")
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "warning")
            compare(Notifications.model.get(0).text, "Could not change the brightness.")
            compare(Display.brightness, 60, "the row shows what the service has")
            // The next press starts from the level the service has, not from the refused target.
            keyClick(Qt.Key_Right)
            tryCompare(Display, "brightness", 65)
        }

        function test_the_panel_asks_for_the_level_again_when_it_opens() {
            start()
            Display.mockUseScenario("laptop")
            tryCompare(Display, "brightnessSupported", true)
            Display.mockBacklightKey(30)             // the laptop's own keys: nobody tells the shell
            wait(50)
            compare(Display.brightness, 60, "the shell has not heard of it")
            openDisplay()
            goTo("display:brightness")
            tryCompare(Display, "brightness", 30)    // the panel asked when it opened
            compare(rowName("display:brightness"), "Brightness, 30 %")
        }

        // ---- the mode list ---------------------------------------------------------------------------------------

        function test_accept_opens_the_mode_list_and_back_leaves_it_without_a_change() {
            start()
            openDisplay()
            keyClick(Qt.Key_Return)
            const picker = find("hubModePicker")
            verify(picker, "the mode list is built when first needed")
            tryCompare(picker, "shown", true)
            compare(find("hubModePickerTitle").text, "Resolution")
            // Settings' entries: the recommended and the current size are noted.
            compare(find("hubModePickerEntry_3840x2160").value, "Recommended · Current")
            verify(find("hubModePickerEntry_1920x1080"), "the sizes of the screen are listed")
            tryVerify(() => find("hubModePickerEntry_3840x2160").activeFocus, 2000, "the list opens on the mode in use")
            compare(hintVerbs(), "A Select|B Cancel")
            // Modal: the keys do not reach the Hub's list underneath.
            keyClick(Qt.Key_Down)
            verify(find("hubModePickerEntry_2560x1440").activeFocus)
            compare(focusedKey(), "display:resolution")
            keyClick(Qt.Key_Escape)                           // Back
            tryCompare(picker, "shown", false)
            tryVerify(() => find("systemActions").activeFocus && find("quickMenuItem_display:resolution").focused, 2000,
                      "focus is back on the Resolution row")
            verify(find("systemPanel").open, "Back leaves the list, not the Hub")
            compare(find("systemPanel").panelId, "display")
            compare(Display.mockSetModeCalls(), 0)
            compare(hintVerbs(), "A Choose|B Back")
            // Back once more: the Hub; once more: out.
            keyClick(Qt.Key_Escape)
            tryCompare(find("systemPanel"), "panelId", "")
        }

        function test_the_refresh_list_offers_the_rates_of_the_current_size() {
            start()
            openDisplay()
            goTo("display:refresh")
            keyClick(Qt.Key_Return)
            const picker = find("hubModePicker")
            tryCompare(picker, "shown", true)
            compare(find("hubModePickerTitle").text, "Refresh rate")
            compare(find("hubModePickerEntry_60000").value, "Recommended · Current")
            verify(find("hubModePickerEntry_30000"))
            compare(find("hubModePickerEntry_30000").label, "30 Hz")
            keyClick(Qt.Key_Escape)
            tryCompare(picker, "shown", false)
        }

        // ---- a change keeps or reverts like Settings -----------------------------------------------------------------

        function test_a_chosen_size_asks_to_keep_it_and_keep_stores_it() {
            start()
            openDisplay()
            pickResolution("1920x1080")
            tryCompare(Display, "confirming", true)
            compare(Display.mockRestartCount(), 1, "the console restarts to show the mode")
            compare(setModeSpy.signalArguments[0][0], "ok")
            tryVerify(() => !find("systemPanel").open, 2000, "the Hub is gone with the restart")
            const dialog = find("modeConfirm")
            tryCompare(dialog, "shown", true)
            tryVerify(() => dialog.visible)
            compare(find("modeConfirmTitle").text, "Keep this resolution?")
            compare(find("modeConfirmMode").text, "1920 × 1080, 60 Hz")
            // The dialog is above the Hub (z), and focus lands on Revert: a blind Accept goes back.
            verify(dialog.z > find("systemPanel").z)
            tryVerify(() => find("modeRevert").activeFocus, 2000, "focus lands on Revert")
            answerKeep()
            tryCompare(Display, "pending", false)
            tryCompare(Display, "currentWidth", 1920)
            tryVerify(() => !dialog.visible)
            compare(Display.mockRestartCount(), 1, "Keep does not restart")
            compare(Notifications.model.count, 0, "a good change shows no toast")
        }

        function test_back_and_the_countdown_restore_the_previous_mode() {
            start()
            openDisplay()
            pickResolution("1280x720")
            tryCompare(Display, "confirming", true)
            const dialog = find("modeConfirm")
            tryVerify(() => find("modeRevert").activeFocus)
            keyClick(Qt.Key_Escape)                           // Back = Revert
            tryCompare(Display, "pending", false)
            tryVerify(() => !dialog.visible)
            compare(Display.currentWidth, 3840, "the previous mode stays")
            compare(Display.mockRestartCount(), 2, "the console restarts again to show it")

            // Nobody answers: the countdown runs out and reverts.
            Display.countdownTickMs = 5
            pickAgain()
            tryCompare(Display, "pending", false, 5000)
            compare(Display.currentWidth, 3840)
            compare(Display.mockRestartCount(), 4)
            Display.countdownTickMs = 1000
        }

        function pickAgain() {
            if (!find("systemPanel").open)
                openDisplay()
            pickResolution("1280x720")
            tryCompare(Display, "confirming", true)
        }

        function test_a_new_rate_changes_only_the_rate() {
            start()
            openDisplay()
            goTo("display:refresh")
            keyClick(Qt.Key_Return)
            tryCompare(find("hubModePicker"), "shown", true)
            for (let i = 0; i < 6 && !find("hubModePickerEntry_30000").activeFocus; ++i)
                keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(Display, "confirming", true)
            compare(find("modeConfirmMode").text, "3840 × 2160, 30 Hz")
            tryVerify(() => find("modeRevert").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(Display, "pending", false)
            compare(Display.currentRefreshMhz, 60000)
        }

        function test_a_running_game_must_be_closed_before_the_console_restarts() {
            start()
            keyClick(Qt.Key_Return)                           // Play
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(pictureAppComponent, host)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000)
            openDisplay()
            pickResolution("1920x1080")
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "warning")
            compare(Display.mockSetModeCalls(), 0, "nothing was asked of the service")
            compare(Display.mockRestartCount(), 0, "the console did not restart under the game")
            compare(Display.confirming, false)
            verify(find("systemPanel").open, "the Hub stays; the player can still close the game")
            tryVerify(() => find("quickMenuItem_display:resolution").focused, 2000, "focus is back on the row")
        }

        function test_a_mode_the_service_refuses_toasts_and_keeps_the_hub() {
            start()
            openDisplay()
            Display.mockFailNext()
            pickResolution("1920x1080")
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "error")
            compare(Notifications.model.get(0).text, "The screen mode could not be changed.")
            verify(find("systemPanel").open)
            compare(Display.confirming, false)
            tryVerify(() => find("quickMenuItem_display:resolution").focused, 2000)
        }

        function test_a_crowded_restart_history_asks_to_try_again_later() {
            start()
            openDisplay()
            Display.mockSetCrowded(true)
            pickResolution("1920x1080")
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).kind, "warning")
            verify(find("systemPanel").open)
        }

        function test_turkish_labels() {
            start()
            Display.mockUseScenario("laptop")
            tryCompare(Display, "brightnessSupported", true)
            DeviceSettings.language = "tr"
            openDisplay()
            compare(find("hubPanelTitle").text, "Ekran")
            verify(rowName("display:resolution").indexOf("Çözünürlük") === 0, rowName("display:resolution"))
            verify(rowName("display:refresh").indexOf("Yenileme hızı") === 0, rowName("display:refresh"))
            verify(rowName("display:brightness").indexOf("Parlaklık") === 0, rowName("display:brightness"))
            DeviceSettings.language = "en"
        }

        // ---- screenshots ---------------------------------------------------------------------------------------------

        function test_zz_screenshots_hub_display_panel() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            Display.mockUseScenario("laptop")
            tryCompare(Display, "brightnessSupported", true)
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(pictureAppComponent, host)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused, 2000)
            goTo("panel:display")
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/hub-display-1-entry.png")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "display")
            tryCompare(find("systemPanel"), "swap", 1)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-display-2-laptop.png")
            goTo("display:brightness")
            keyClick(Qt.Key_Left)
            tryCompare(Display, "brightness", 55)
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/hub-display-3-brightness.png")
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Up)
            compare(focusedKey(), "display:resolution")
            keyClick(Qt.Key_Return)
            tryCompare(find("hubModePicker"), "shown", true)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-display-4-modes.png")
            keyClick(Qt.Key_Escape)
            tryCompare(find("hubModePicker"), "shown", false)
            // A TV: no brightness row.
            Display.mockUseScenario("tv4k")
            tryVerify(() => find("systemPanel").itemKeys.indexOf("display:brightness") < 0)
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/hub-display-5-tv.png")
        }

        // The countdown of "Keep this resolution?" over a game's picture, at the size of the TV.
        function test_zz_screenshots_hub_display_keep_dialog() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            keyClick(Qt.Key_Return)                          // Play: a game with a picture is in front
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(pictureAppComponent, host)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000)
            Display.chooseResolution(1920, 1080)             // the dialog over it (a restart would end the game: this is the dialog's look)
            tryCompare(Display, "confirming", true)
            tryCompare(find("modeConfirm"), "shown", true)
            tryVerify(() => find("modeRevert").activeFocus, 2000)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-display-6-keep.png")
            keyClick(Qt.Key_Escape)
            tryCompare(Display, "pending", false)
        }
    }
}
