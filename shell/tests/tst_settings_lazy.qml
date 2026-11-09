import QtQuick
import QtTest
import RuyaShell

// T-349: opening Settings is cheap. A pane is built the first time its category is selected and is
// then kept; the modals of the panes are built the first time they open; the services' refreshes
// wait for their pane; a page popped by a section switch is destroyed only after the page that
// replaces it has settled and been drawn; the page-open probe writes one line per opened page.
// Counts objects and states, never time (the offscreen renderer says nothing about the Dell).
// Signs in as Player One (p1, admin, PIN 1234), so every category and row is listed.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test-1.2.3"; focus: true }
    }

    // Frames drawn, and when the Settings slot settled and when a popped slot was reaped (in frames).
    Connections {
        id: frameCounter
        target: null
        function onFrameSwapped() { tc.frames += 1 }
    }
    Connections {
        id: settleWatch
        target: null
        function onSettledChanged() {
            if (tc.settingsSlot !== null && tc.settingsSlot.settled && tc.framesAtSettle < 0)
                tc.framesAtSettle = tc.frames
        }
    }
    Connections {
        id: reapWatch
        target: null
        function onSlotCountChanged() {
            if (tc.framesAtReap < 0 && tc.shell.slotCount === 1)
                tc.framesAtReap = tc.frames
        }
    }

    TestCase {
        id: tc
        name: "SettingsLazy"
        when: windowShown

        property Shell shell: null
        property int frames: 0
        property int framesAtSettle: -1
        property int framesAtReap: -1
        property var settingsSlot: null

        // Every pane of Settings, in the admin's category order.
        readonly property var paneNames: ["paneMyProfile", "paneProfiles", "paneNetwork", "paneBluetooth", "paneDisplay",
                                          "paneAudio", "paneStorage", "panePower", "paneSystem", "paneAbout"]

        function find(name) { return findChild(tc.shell, name) }
        function builtPanes() { return tc.paneNames.filter(n => find(n) !== null) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.frames = 0
            tc.framesAtSettle = -1
            tc.framesAtReap = -1
            tc.settingsSlot = null
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function cleanup() {
            frameCounter.target = null
            settleWatch.target = null
            reapWatch.target = null
            Theme.motionFactor = 1.0
            Bluetooth.mockReset()
            Display.mockReset()
        }

        function openSettings() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList") !== null && find("categoryList").activeFocus, 2000, "category list has focus")
        }

        function categoryIndex(key) {
            return find("page_settings").categories.findIndex(c => c.key === key)
        }

        // Up/Down on the category list to `key`, focus on the list at every step.
        function selectCategory(key) {
            const list = find("categoryList")
            const index = tc.categoryIndex(key)
            verify(index >= 0, key + " is listed")
            for (let i = 0; i < 20 && list.currentIndex < index; ++i)
                keyClick(Qt.Key_Down)
            for (let i = 0; i < 20 && list.currentIndex > index; ++i)
                keyClick(Qt.Key_Up)
            compare(list.currentIndex, index)
            verify(list.activeFocus, "the list keeps focus")
        }

        function enterPane(name) {
            keyClick(Qt.Key_Right)
            tryVerify(() => find(name).activeFocus, 2000, name + " has focus")
            tryVerify(() => find(name).focusableRows().some(r => r.activeFocus), 2000, "a row of " + name + " has focus")
        }

        function goToRow(name) {
            for (let i = 0; i < 20 && !(find(name) && find(name).activeFocus); ++i)
                keyClick(Qt.Key_Down)
            verify(find(name).activeFocus, name + " has focus")
        }

        // Back until the modal has closed (a keyboard deletes the pre-filled letters first).
        function backOut(name) {
            for (let i = 0; i < 60 && find(name).shown; ++i)
                keyClick(Qt.Key_Escape)
            tryVerify(() => !find(name).shown, 2000, name + " closed")
        }

        // ---- panes ----

        function test_settings_opens_with_the_first_pane_only() {
            openSettings()
            compare(tc.builtPanes(), ["paneMyProfile"], "only My profile is built")
            verify(find("paneMyProfile").visible)
            verify(!find("paneComingSoon").visible)
            compare(find("page_settings").hints.map(h => h.button + " " + h.text).join(", "), "A Select, B Back")
            enterPane("paneMyProfile")
            verify(find("rowWho").activeFocus, "the first row takes focus, as before")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Back returns to the list")
            compare(tc.shell.currentPage, "settings")
        }

        function test_a_pane_is_built_when_selected_and_kept() {
            openSettings()
            selectCategory("display")
            const display = find("paneDisplay")
            verify(display !== null && display.visible, "Display is built when it is selected")
            verify(!find("paneMyProfile").visible, "and My profile is hidden")
            for (const name of ["paneAudio", "paneStorage", "panePower", "paneSystem", "paneAbout"])
                compare(find(name), null, name + " is not built: it was never selected")
            enterPane("paneDisplay")
            verify(find("rowQuality").activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowOverscan").activeFocus, 2000, "the third row has focus")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000)

            selectCategory("about")
            verify(find("paneAbout").visible)
            verify(!display.visible, "Display is hidden")
            verify(find("paneDisplay") === display, "but kept")
            selectCategory("display")
            verify(find("paneDisplay") === display, "the same pane shows again")
            verify(display.visible)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowOverscan").activeFocus, 2000, "it remembers its last focused row")
            verify(display.activeFocus)
        }

        function test_an_opening_category_builds_only_its_pane() {
            tc.shell.openPage("settings", { category: "display" })
            tryCompare(tc.shell, "currentPage", "settings")
            compare(tc.builtPanes(), ["paneDisplay"], "My profile is not built on the way")
            compare(find("categoryList").currentIndex, tc.categoryIndex("display"))
            verify(find("paneDisplay").visible)
        }

        // ---- modals: built on their first opening, then kept ----

        // PIN pad, delete confirmation and name keyboard of the profile panes (one family each pane).
        function test_profile_modals_wait_for_their_first_opening() {
            openSettings()
            for (const name of ["myProfilePinPad", "myProfileRenameEntry", "myProfileDeleteConfirm"])
                compare(find(name), null, name + " is not built with the pane")
            enterPane("paneMyProfile")
            goToRow("rowRenameMe")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("myProfileRenameEntry") !== null && find("myProfileRenameEntry").shown, 2000, "the keyboard opens")
            tryVerify(() => find("myProfileRenameEntry").activeFocus, 2000, "with the focus")
            verify(find("myProfilePinPad") !== null, "its flow's PIN pad is built with it")
            backOut("myProfileRenameEntry")
            tryVerify(() => find("rowRenameMe").activeFocus, 2000, "focus returns to the row")
            verify(find("myProfileRenameEntry") !== null, "the keyboard is kept")

            goToRow("rowChangePin")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("myProfilePinPad").shown, 2000, "the PIN pad opens")
            backOut("myProfilePinPad")
            tryVerify(() => find("rowChangePin").activeFocus, 2000, "focus returns to the row")

            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000)
            selectCategory("profiles")
            for (const name of ["profilesPinPad", "profilesRenameEntry", "profilesDeleteConfirm", "profileNameEntry"])
                compare(find(name), null, name + " is not built with the pane")
        }

        function test_display_pickers_wait_for_their_first_opening() {
            openSettings()
            selectCategory("display")
            for (const name of ["resolutionPicker", "refreshPicker", "wallpaperPicker"])
                compare(find(name), null, name + " is not built with the pane")
            compare(find("rowWallpaper").value, DisplayText.wallpaperName(DeviceSettings.wallpaper),
                    "the row names the wallpaper without the picker")
            enterPane("paneDisplay")
            goToRow("rowResolution")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("resolutionPicker") !== null && find("resolutionPicker").shown, 2000, "the picker opens")
            tryVerify(() => find("resolutionPickerEntry_3840x2160").activeFocus, 2000, "on the mode in use")
            compare(find("refreshPicker"), null, "the other picker is still not built")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("resolutionPicker").shown, 2000)
            tryVerify(() => find("rowResolution").activeFocus, 2000, "focus returns to the row")

            for (let i = 0; i < 10 && !find("rowWallpaper").activeFocus; ++i)
                keyClick(Qt.Key_Up)
            verify(find("rowWallpaper").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("wallpaperPicker") !== null && find("wallpaperPicker").shown, 2000, "the wallpaper picker opens")
            tryVerify(() => find("wallpaperGrid").activeFocus, 2000)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("wallpaperPicker").shown, 2000)
            tryVerify(() => find("rowWallpaper").activeFocus, 2000, "focus returns to the row")
        }

        function test_system_modals_wait_for_their_first_opening() {
            openSettings()
            selectCategory("system")
            for (const name of ["zonePicker", "updatePinPad", "updateRestartConfirm", "updateRollbackConfirm"])
                compare(find(name), null, name + " is not built with the pane")
            enterPane("paneSystem")
            goToRow("rowTimezone")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("zonePicker") !== null && find("zonePicker").shown, 2000, "the time zone picker opens")
            tryVerify(() => find("zoneRegions").activeFocus, 2000)
            compare(find("updatePinPad"), null, "the PIN pad is still not built")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("zonePicker").shown, 2000)
            verify(find("rowTimezone").activeFocus, "focus returns to the row")
        }

        function test_bluetooth_and_network_modals_wait_for_their_first_opening() {
            openSettings()
            selectCategory("network")
            compare(find("wifiPasswordEntry"), null, "the password keyboard is not built with the pane")
            enterPane("paneNetwork")
            goToRow("wifi_wifi-home")                    // secured and not saved: asks for a password
            keyClick(Qt.Key_Return)
            tryVerify(() => find("wifiPasswordEntry") !== null && find("wifiPasswordEntry").shown, 2000, "the keyboard opens")
            backOut("wifiPasswordEntry")
            tryVerify(() => find("wifi_wifi-home").activeFocus, 2000, "focus returns to the row")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000)

            Bluetooth.mockPairingScript("wait")
            selectCategory("bluetooth")
            for (const name of ["controllerOnboarding", "btRenameEntry", "btForgetConfirm"])
                compare(find(name), null, name + " is not built with the pane")
            enterPane("paneBluetooth")
            goToRow("rowBtPairController")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("controllerOnboarding") !== null && find("controllerOnboarding").shown, 2000, "the pairing screen opens")
            tryVerify(() => find("onbChip_playstation").activeFocus, 2000)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("controllerOnboarding").shown, 2000)
            tryVerify(() => find("rowBtPairController").activeFocus, 2000, "focus returns to the row")
            compare(find("btRenameEntry"), null)

            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000)
            selectCategory("audio")
            compare(find("soundDeleteConfirm"), null, "Audio's confirmation is not built with the pane")
        }

        // ---- refreshes ----

        function test_refreshes_wait_for_their_pane() {
            const network = Network.mockRefreshCalls()
            const bluetooth = Bluetooth.mockRefreshCalls()
            const storage = Storage.mockUsageCalls()
            const themes = SoundThemes.mockRefreshCalls()
            const probe = find("pageProbe")
            const lines = probe.lineCount
            openSettings()
            tryCompare(probe, "lineCount", lines + 1, 3000, "Settings has opened and settled")
            compare(Network.mockRefreshCalls(), network, "opening Settings asks Network for nothing")
            compare(Bluetooth.mockRefreshCalls(), bluetooth, "nor Bluetooth")
            compare(Storage.mockUsageCalls(), storage, "nor Storage")
            compare(SoundThemes.mockRefreshCalls(), themes, "nor the sound themes")

            selectCategory("audio")
            tryVerify(() => SoundThemes.mockRefreshCalls() === themes + 1, 2000, "the sound themes are looked up when Audio shows")
            selectCategory("storage")
            tryVerify(() => Storage.mockUsageCalls() === storage + 1, 2000, "Storage asks when its pane shows")
            compare(Network.mockRefreshCalls(), network, "the Network pane only copies the list it has")
            compare(Bluetooth.mockRefreshCalls(), bluetooth, "so does the Bluetooth pane")
        }

        // ---- the page slots and the probe ----

        // Store to Settings (RB): the Store page is destroyed after the Settings page has finished its
        // glide and that frame is on screen, not in the glide's last frame.
        function test_a_replaced_page_goes_after_the_glide() {
            keyClick(Qt.Key_Up)
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Store
            tryCompare(tc.shell, "currentPage", "store")
            tryVerify(() => find("pageSlot_store").settled, 3000, "the Store has settled")
            frameCounter.target = tc.shell.Window.window
            reapWatch.target = tc.shell
            keyClick(Qt.Key_PageDown)                    // RB: Settings
            compare(tc.shell.currentPage, "settings")
            tc.settingsSlot = find("pageSlot_settings")
            verify(tc.settingsSlot !== null)
            settleWatch.target = tc.settingsSlot
            verify(find("pageSlot_store") !== null, "the Store is still there while Settings glides in")
            tryVerify(() => tc.framesAtReap >= 0, 3000, "the Store is reaped")
            verify(tc.framesAtSettle >= 0, "after Settings settled")
            verify(tc.framesAtReap > tc.framesAtSettle,
                   "and after a frame with Settings at rest (settled at frame " + tc.framesAtSettle + ", reaped at " + tc.framesAtReap + ")")
            tryVerify(() => find("pageSlot_store") === null, 2000, "then destroyed")
            verify(find("categoryList").activeFocus, "focus is on the category list")
        }

        function test_the_probe_writes_a_line_per_page_open() {
            const probe = find("pageProbe")
            const lines = probe.lineCount
            openSettings()
            tryCompare(probe, "lineCount", lines + 1, 3000, "one line once Settings has settled")
            const m = /^page-open settings create=(\d+) firstSwap=(\d+) afterAnim=(\d+) frames=(\d+) maxFrame=(\d+)$/.exec(probe.lastLine)
            verify(m !== null, probe.lastLine)
            verify(Number(m[1]) <= Number(m[2]), "built before the first frame")
            verify(Number(m[1]) <= Number(m[3]), "and before the glide ends")
            verify(Number(m[4]) >= 1)
            compare(probe.pendingKey, "")
            keyClick(Qt.Key_Escape)                      // Back to Home: closing writes nothing
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("sectionNav").activeFocus, 2000, "focus is back on the nav")
            compare(probe.lineCount, lines + 1)
        }
        // A page closed before it settled stops the measurement: nothing keeps counting frames.
        function test_a_page_closed_before_it_settles_cancels_the_probe() {
            const probe = find("pageProbe")
            const lines = probe.lineCount
            tc.shell.openPage("settings", {})
            verify(probe.pendingKey !== "", "the open is being measured")
            tc.shell.closePage()
            compare(probe.pendingKey, "", "closing cancelled it")
            wait(400)
            compare(probe.lineCount, lines, "and no line was written for it")
        }
        // The panes' lazily built modals live in the modal layer inside Loaders: while none is open the
        // shell must not count them as a modal (that would switch off the focus safety net, T-356).
        function test_unopened_pane_modals_do_not_count_as_a_modal() {
            openSettings()
            compare(tc.shell.modalShown(), false, "Settings is open, no modal is")
        }
        // The same with the modals built (their Loaders hold an item, hidden since the keyboard closed):
        // that is no modal either, so the focus safety net still acts when a pane's focus falls out.
        function test_the_focus_net_works_with_a_settings_pane_loaded() {
            openSettings()
            enterPane("paneMyProfile")
            goToRow("rowRenameMe")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("myProfileRenameEntry") !== null && find("myProfileRenameEntry").shown, 2000, "the keyboard opens")
            backOut("myProfileRenameEntry")
            tryVerify(() => find("rowRenameMe").activeFocus, 2000, "focus returns to the row")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000)
            const entry = find("myProfileRenameEntry")
            verify(entry !== null, "the keyboard is built")
            tryVerify(() => !entry.visible, 2000, "and hidden once it has faded out; its Loader still shows")
            compare(tc.shell.modalShown(), false, "a built, closed modal is no modal")
            tc.shell.openPage("power")                   // a page over Settings
            tryCompare(tc.shell, "currentPage", "power")
            tryVerify(() => find("powerSuspend").activeFocus, 2000, "the Power page has the focus")
            tryVerify(() => !find("pageSlot_settings").visible, 2000, "Settings faded out")
            const repairs = tc.shell.focusRepairs
            find("categoryList").forceActiveFocus()      // the covered page takes the focus back
            verify(tc.shell.focusIsLost(), "lost: nothing in the modal layer shows")
            tryVerify(() => find("powerSuspend").activeFocus, 2000, "the net gives it to the page on top")
            compare(tc.shell.focusRepairs, repairs + 1, "the net acted once")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings", 3000, "Back works again")
        }

        // A popped page is destroyed only once the page on top has settled and a frame is on screen. A
        // page popped before its fade-in progressed is already at opacity 0 when it closes, so only
        // topSettled() keeps it: the Settings page opened over the Store is popped at once, and the Store
        // beneath it is still gliding in (a long glide here, so the wait is wide).
        function test_reap_waits_for_the_top_to_settle() {
            Theme.motionFactor = 4
            tc.shell.openPage("store")
            tc.shell.openPage("settings", {})
            const popped = find("pageSlot_settings")
            verify(popped !== null)
            frameCounter.target = tc.shell.Window.window
            tc.shell.closePage()
            compare(popped.closing, true)
            compare(popped.opacity, 0, "it never faded in: nothing but the gate holds it")
            verify(!tc.shell.topSettled(), "the Store has not settled")
            const frames = tc.frames
            tryVerify(() => tc.frames >= frames + 5, 3000, "frames are drawn meanwhile")
            verify(!tc.shell.topSettled(), "and the Store has still not settled")
            verify(find("pageSlot_settings") !== null, "the popped page is still there")
            compare(popped.reaped, false)
            tryVerify(() => find("pageSlot_settings") === null, 8000, "destroyed after the Store settled")
            verify(find("pageSlot_store").settled, "which it had")
        }
    }
}
