import QtQuick
import QtTest
import RuyaShell

// Store page and app detail page against the mock catalogue (13 apps, 9 with controller support, one needing a newer API level).
// Controller keys only. Signs in as "Ada" (p2, no PIN).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: jobsSpy; target: Store; signalName: "jobsChanged" }
    SignalSpy { id: reconciledSpy; target: Store; signalName: "jobsReconciled" }

    TestCase {
        id: tc
        name: "StoreUi"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Store.mockReset()
            Library.resetMockForTests("")              // an uninstall drops its Library item (RUY-524)
            compare(Object.keys(Store.jobs).length, 0, "no job survives the reset")
            Store.controllerFilter = "any"
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
            jobsSpy.clear()
            reconciledSpy.clear()
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

        // Opens the app from its card: focus the row that has it, move to it and press Accept.
        function openApp(id) {
            const rows = ["featured", "games", "apps", "installed"]
            for (const r of rows) {
                const list = find("storeCards_" + r)
                if (!list || !list.visible)
                    continue
                // The row's ids: a row below the fold has no cards until it takes focus (T-377).
                const at = find("storeRow_" + r).ids.indexOf(id)
                if (at < 0)
                    continue
                // The row may be above the focused one (after Back): up to the toolbar, then down.
                for (let i = 0; i < 10 && !list.activeFocus; ++i)
                    keyClick(Qt.Key_Up)
                for (let i = 0; i < 10 && !list.activeFocus; ++i)
                    keyClick(Qt.Key_Down)
                verify(list.activeFocus, "row " + r + " takes focus")
                for (let i = 0; i < 50 && list.currentIndex < at; ++i)
                    keyClick(Qt.Key_Right)
                compare(list.model[list.currentIndex], id)
                keyClick(Qt.Key_Return)
                tryCompare(tc.shell, "currentPage", "appDetail")
                tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
                tryCompare(find("page_appDetail"), "detailsReady", true)   // the gate needs the permissions
                return
            }
            fail("no card for " + id)
        }

        // RUY-1244: the Installed row names a .play app from its package's title (the Library's), not the id's last
        // part, and its page offers no Store update; the Store's own apps keep the Store's names.
        function test_a_play_app_in_the_installed_row_is_named_by_its_package() {
            const id = "play.com.example.starhopper"
            Library.resetMockForTests("play")
            tryVerify(() => Library.item("flatpak:" + id).play === true)
            Store.mockInstallOutside(id, "starhopper", ["network"])
            Store.refreshInstalled()
            tryVerify(() => Store.installed.some(a => a.id === id))
            Store.mockCatalogChanged()                   // the real service lists it in the catalogue too (RUY-854)
            tryVerify(() => Store.app(id).installed === true)
            openStore()
            tryVerify(() => find("storeRow_installed").ids.indexOf(id) >= 0)
            keyClick(Qt.Key_Down, Qt.NoModifier)
            keyClick(Qt.Key_Down, Qt.NoModifier)
            keyClick(Qt.Key_Down, Qt.NoModifier)
            tryVerify(() => find("storeCards_installed").activeFocus, 2000, "the Installed row has focus")
            tryVerify(() => find("appCard_" + id) !== null, 2000, "its card is built")
            const card = find("appCard_" + id)
            compare(card.title, "Star Hopper")
            verify(card.Accessible.name === "Star Hopper, Installed", "accessible name: " + card.Accessible.name)
            compare(card.app.source, "developer", "the badge says Developer")
            compare(find("appCard_org.example.Puzzle").title, "Block Puzzle")
            // The page has no Update, whatever the Store's record says: Play1 updates it.
            Store.mockSetUpdateAvailable(id, true)
            tryVerify(() => Store.app(id).updateAvailable === true)
            openApp(id)
            compare(find("page_appDetail").app.updateAvailable, true, "the Store's record has an update")
            compare(find("page_appDetail").hasUpdate, false)
            compare(find("page_appDetail").secondaryKeys.indexOf("update"), -1)
            compare(find("page_appDetail").title, "Star Hopper")
        }

        // RUY-1244: Play1.Remove leaves the commit in the local remote, so the Store still lists a removed .play app;
        // its page must not offer to install it (the service answers play-managed), and the Store's own apps do.
        function test_a_removed_play_app_has_no_install_button() {
            const id = "play.com.example.removed"
            Store.mockOffer(id, "removed")
            tryVerify(() => Store.app(id).installed === false)
            tc.shell.openPage("appDetail", { appId: id })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryCompare(find("page_appDetail"), "hasRecord", true)
            compare(find("page_appDetail").installed, false)
            compare(find("page_appDetail").primaryKind, "")
            // (A Store app's Install is covered by test_install_from_detail.)
            Store.mockReset()
            Store.mockCatalogChanged()                   // the reset does not announce the catalogue
            tryVerify(() => Store.app(id).id === undefined)
        }

        function test_controller_filter() {
            openStore()
            // Hidden by default: the three apps without controller support.
            compare(Store.controllerFilter, "gamepad")
            // (Next Gen Studio has controller support and counts here, RUY-636.)
            tryCompare(Store.results, "length", 10)
            // Browser belongs to "Apps & media", below the fold: its cards wait for the row to show
            // (T-377), so the row's ids say whether it is listed.
            const apps = find("storeRow_apps")
            compare(apps.ids.indexOf("org.example.Browser"), -1)
            verify(find("appCard_org.example.Racer"))
            // Up from the first row reaches the toolbar, Right the toggle.
            keyClick(Qt.Key_Up)
            verify(find("storeSearch").activeFocus)
            compare(find("storeSearch").kind, "page", "RUY-513: Search opens the keyboard")
            keyClick(Qt.Key_Right)
            verify(find("storeShowAll").activeFocus)
            compare(find("storeShowAll").checked, false)
            keyClick(Qt.Key_Return)
            tryCompare(Store, "controllerFilter", "any")
            tryVerify(() => Store.results.length === 13)
            tryVerify(() => apps.ids.indexOf("org.example.Browser") >= 0, 2000, "Browser shows with all apps")
            keyClick(Qt.Key_Return)
            tryCompare(Store, "controllerFilter", "gamepad")
            tryVerify(() => apps.ids.indexOf("org.example.Browser") < 0)
            compare(find("appCard_org.example.Browser"), null)
        }

        function test_rows_follow_the_catalogue() {
            openStore()
            tryVerify(() => find("storeRow_featured").ids.length === 4)
            tryVerify(() => find("storeRow_games").ids.length === 5)
            tryVerify(() => find("storeRow_installed").ids.length === 3)   // its cards wait for it to show (T-377)
            keyClick(Qt.Key_Down)
            verify(find("storeCards_games").activeFocus)
        }

        function test_install_from_detail() {
            openStore()
            openApp("org.example.Racer")
            compare(find("detailPrimary").text, "Install")
            compare(find("detailSource").text, "Official")
            keyClick(Qt.Key_Return)
            verify(find("page_appDetail").working)
            verify(find("detailProgress").visible)
            tryVerify(() => jobsSpy.count > 0, 2000, "progress arrived")
            tryVerify(() => Store.app("org.example.Racer").installed === true)
            tryVerify(() => !find("page_appDetail").working)
            compare(find("detailPrimary").text, "Play")
            verify(find("detailUninstall").visible)
            verify(!find("detailProgress").visible)
            compare(find("detailError").visible, false)
        }

        // T-434: the detail page's Uninstall… row and progress track lie straight on L0: translucent glass with
        // blur, opaque without it (the Performance tier, 04 §3.6). RUY-524: the buttons are the shared Primary and
        // Secondary ones (fixed fills, 04 §5), so the row is the glass the page draws itself.
        function test_detail_buttons_are_opaque_glass_without_blur() {
            openStore()
            openApp("org.example.Racer")
            const uninstall = find("detailUninstall")
            const primary = find("detailPrimary")
            keyClick(Qt.Key_Return)                         // Install
            tryVerify(() => Store.app("org.example.Racer").installed === true)
            tryVerify(() => !find("page_appDetail").working && uninstall.visible, 2000, "installed")
            tryVerify(() => primary.activeFocus, 2000, "focus stays on the primary button")
            const fill = findChild(uninstall, "rowFill")
            compare(fill.color, Theme.glass, "translucent over the blurred L0 on High")
            compare(find("detailProgress").color, Theme.glass)
            DeviceSettings.effectsQuality = "performance"
            tryCompare(fill, "color", Theme.glassOpaque, 2000, "opaque glass on Performance")
            compare(find("detailProgress").color, Theme.glassOpaque, "and the progress track")
            uninstall.forceActiveFocus()
            tryCompare(fill, "color", Theme.focusFill, 2000, "the focused row keeps the focus fill")
        }

        function cleanup() {
            DeviceSettings.effectsQuality = "high"
        }

        // T-171: the service vanishes mid-install; the page must not wait for a job that is gone.
        function test_service_loss_ends_the_job() {
            openStore()
            openApp("org.example.Racer")
            keyClick(Qt.Key_Return)
            verify(find("detailProgress").visible)
            tryVerify(() => Store.jobs["org.example.Racer"] !== undefined, 2000, "progress arrived")
            Store.mockServiceLost()
            compare(Object.keys(Store.jobs).length, 0)
            verify(!find("page_appDetail").working)
            verify(!find("detailProgress").visible)
            compare(find("detailError").visible, true)
        }

        // T-171: a job still queued behind another has no progress yet; it must end too.
        function test_service_loss_ends_a_queued_job() {
            openStore()
            Store.install("org.example.Racer")          // runs first
            tryVerify(() => Store.jobs["org.example.Racer"] !== undefined, 2000, "progress arrived")
            openApp("org.example.Platformer")
            keyClick(Qt.Key_Return)                     // queued behind Racer
            verify(find("page_appDetail").working)
            verify(Store.jobs["org.example.Platformer"] === undefined, "it has not reported progress")
            Store.mockServiceLost()
            verify(!find("page_appDetail").working)
            verify(!find("detailProgress").visible)
        }

        // T-188: the service restarts mid-install and its job table says the job was interrupted:
        // the page offers Install again, with the error shown.
        function test_restart_with_an_interrupted_job_offers_retry() {
            openStore()
            openApp("org.example.Racer")
            keyClick(Qt.Key_Return)
            tryVerify(() => Store.jobs["org.example.Racer"] !== undefined, 2000, "progress arrived")
            Store.mockServiceLost()
            Store.mockServiceRegained()
            tryCompare(reconciledSpy, "count", 1)
            compare(Object.keys(Store.jobs).length, 0)
            verify(!find("page_appDetail").working)
            compare(find("detailError").visible, true)
            compare(find("detailPrimary").text, "Install")
            verify(!find("detailPrimary").dimmed, "a retry is possible")
        }

        // T-188: Flatpak completed the install while the service was away: no error, the app is
        // installed and the page says Open.
        function test_restart_after_flatpak_completed_the_install() {
            openStore()
            openApp("org.example.Racer")
            keyClick(Qt.Key_Return)
            tryVerify(() => Store.jobs["org.example.Racer"] !== undefined, 2000, "progress arrived")
            Store.mockServiceLost()
            compare(find("detailError").visible, true, "given up at first")
            Store.mockServiceRegained(["org.example.Racer"])
            tryCompare(reconciledSpy, "count", 1)
            tryVerify(() => !find("detailError").visible, 2000, "the error went")
            tryVerify(() => find("detailPrimary").text === "Play")
            verify(!find("page_appDetail").working)
            verify(find("detailUninstall").visible)
        }

        // T-191: a job the page did not start (found by the Store when the shell started, or started
        // elsewhere) shows as working on the app's page; it ends like any other.
        function test_a_job_the_page_did_not_start_shows_as_working() {
            openStore()
            Store.install("org.example.Racer")           // not from the page
            tryVerify(() => Store.jobs["org.example.Racer"] !== undefined, 2000, "progress arrived")
            Store.mockPauseJobs(true)
            openApp("org.example.Racer")
            verify(Store.jobs["org.example.Racer"] !== undefined)
            verify(find("page_appDetail").working, "the page shows the running job")
            verify(find("detailProgress").visible)
            verify(find("detailPrimary").dimmed, "it cannot be started twice")
            verify(!find("detailUninstall").visible)
            Store.mockPauseJobs(false)
            tryVerify(() => !find("page_appDetail").working, 5000, "the job ended")
            tryVerify(() => find("detailPrimary").text === "Play")
            verify(!find("detailProgress").visible)
            compare(find("detailError").visible, false)
        }

        function test_install_error_inline() {
            openStore()
            openApp("org.example.Broken")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("detailError").visible, 5000, "error shows inline")
            verify(find("detailError").text.length > 0)
            compare(find("detailPrimary").text, "Install")
            compare(find("page_appDetail").working, false)
            verify(!find("detailPrimary").dimmed, "stays installable")
            verify(!find("detailUninstall").visible)
        }

        function test_high_risk_flagged() {
            openStore()
            openApp("org.example.Stream")
            verify(find("riskFlag_all-devices").visible)
            verify(!find("riskFlag_network").visible)
            verify(!find("riskFlag_audio").visible)
        }

        // D-pad over the PIN pad keypad (3 columns: 1-9, then Del 0 OK).
        function padPress(label) {
            const order = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "del", "0", "ok"]
            const target = order.indexOf(label)
            const pad = find("detailPinPad")
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

        function test_high_risk_needs_admin_pin() {
            openStore()
            openApp("org.example.Stream")
            verify(find("detailAdminNote").visible)
            keyClick(Qt.Key_Return)
            const pad = find("detailPinPad")
            tryVerify(() => pad.shown && findChild(pad, "pinKeys").activeFocus, 2000, "the PIN pad has focus")
            compare(find("page_appDetail").working, false)
            enterPin("0000")
            tryVerify(() => !pad.shown)
            tryVerify(() => find("detailError").visible && find("detailError").text.indexOf("Wrong PIN") === 0)
            tryVerify(() => find("detailPrimary").activeFocus, 2000, "focus returns to Install")
            compare(find("page_appDetail").working, false)
            compare(Object.keys(Store.jobs).length, 0)

            keyClick(Qt.Key_Return)
            tryVerify(() => pad.shown)
            enterPin("1234")
            tryVerify(() => find("page_appDetail").working, 2000, "the admin's PIN starts the install")
            tryVerify(() => find("detailPrimary").activeFocus)
            tryVerify(() => Store.app("org.example.Stream").installed === true)
        }

        function test_high_risk_back_cancels() {
            openStore()
            openApp("org.example.Stream")
            keyClick(Qt.Key_Return)
            const pad = find("detailPinPad")
            tryVerify(() => pad.shown)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !pad.shown)
            tryVerify(() => find("detailPrimary").activeFocus, 2000, "focus is on Install")
            compare(find("page_appDetail").working, false)
            compare(Object.keys(Store.jobs).length, 0)
            compare(Store.app("org.example.Stream").installed, false)
        }

        function test_low_risk_needs_no_pin() {
            openStore()
            openApp("org.example.Racer")
            verify(!find("detailAdminNote").visible)
            keyClick(Qt.Key_Return)
            verify(find("page_appDetail").working)
            verify(!find("detailPinPad").shown)
            // Ends with the install still running, on purpose (T-167): the next init's reset has
            // to drop it, or a later test that expects no job saw this one (it failed at random
            // when the first progress tick came before the reset).
            tryVerify(() => Store.jobs["org.example.Racer"] !== undefined, 2000, "the job is running")
        }

        function test_update_adding_high_risk_needs_admin_pin() {
            openStore()
            openApp("org.example.Chess")                // its update adds all-devices
            compare(find("detailPrimary").text, "Update")
            verify(find("detailUpdateAdds").visible)
            verify(find("detailUpdateAdds").text.indexOf("Accesses all devices") >= 0, find("detailUpdateAdds").text)
            verify(find("detailAdminNote").visible)
            keyClick(Qt.Key_Return)
            const pad = find("detailPinPad")
            tryVerify(() => pad.shown && findChild(pad, "pinKeys").activeFocus, 2000, "the PIN pad has focus")
            compare(find("page_appDetail").working, false)
            enterPin("0000")
            tryVerify(() => !pad.shown)
            tryVerify(() => find("detailError").visible && find("detailError").text.indexOf("Wrong PIN") === 0)
            tryVerify(() => find("detailPrimary").activeFocus, 2000, "focus returns to Update")
            compare(find("page_appDetail").working, false)
            compare(Object.keys(Store.jobs).length, 0)
            verify(Store.app("org.example.Chess").updateAvailable, "a wrong PIN starts no update")

            keyClick(Qt.Key_Return)
            tryVerify(() => pad.shown)
            enterPin("1234")
            tryVerify(() => find("page_appDetail").working, 2000, "the admin's PIN starts the update")
            tryVerify(() => find("detailPrimary").activeFocus)
            tryVerify(() => Store.app("org.example.Chess").updateAvailable === false)
            tryVerify(() => !find("page_appDetail").working)
            verify(!find("detailAdminNote").visible, "nothing is left to gate")
            verify(!find("detailUpdateAdds").visible)
            verify(Store.app("org.example.Chess").permissions.indexOf("all-devices") >= 0)
        }

        function test_update_adding_high_risk_back_cancels() {
            openStore()
            openApp("org.example.Chess")
            keyClick(Qt.Key_Return)
            const pad = find("detailPinPad")
            tryVerify(() => pad.shown)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !pad.shown)
            tryVerify(() => find("detailPrimary").activeFocus, 2000, "focus is on Update")
            compare(find("page_appDetail").working, false)
            compare(Object.keys(Store.jobs).length, 0)
        }

        function test_update_adding_nothing_is_not_gated() {
            openStore()
            openApp("org.example.Editor")               // an update with no new permission
            compare(find("detailPrimary").text, "Update")
            verify(!find("detailUpdateAdds").visible)
            verify(!find("detailAdminNote").visible)
            keyClick(Qt.Key_Return)
            verify(find("page_appDetail").working, "Update starts at once")
            verify(!find("detailPinPad").shown)
            tryVerify(() => Store.app("org.example.Editor").updateAvailable === false)
        }

        // The hints drawn by the bar, "accept Select|back Cancel" (T-285).
        function barHints() {
            const bar = find("hintBar")
            const parts = []
            for (const b of ["left_right", "accept", "back", "options"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        // The Uninstall confirm asks a Standard profile for an admin's PIN (Player One's, 1234).
        function enterAdminPin() {
            tryVerify(() => find("uninstallPinPad").shown, 2000, "the admin's PIN pad")
            for (const d of [Qt.Key_1, Qt.Key_2, Qt.Key_3, Qt.Key_4])
                keyClick(d)
            keyClick(Qt.Key_Enter)
        }

        // The buttons, This app can, the facts, then Manage (RUY-524): Down until Uninstall… has the focus.
        function downToUninstall() {
            for (let i = 0; i < 20 && !find("detailUninstall").activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(find("detailUninstall").activeFocus, "Down reaches Uninstall…")
        }

        function test_uninstall_confirm() {
            openStore()
            openApp("org.example.Puzzle")              // installed from the start
            compare(find("detailPrimary").text, "Play")
            downToUninstall()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("uninstallCancel").activeFocus, 2000, "Cancel is the default")
            compare(barHints(), "accept Select|back Cancel", "the confirmation says what A and B do (T-285)")
            // Cancel changes nothing.
            keyClick(Qt.Key_Return)
            tryVerify(() => find("detailUninstall").activeFocus)
            verify(Store.app("org.example.Puzzle").installed)
            // Uninstall with data: Up to the toggle, switch it, Down, Right, Accept.
            keyClick(Qt.Key_Return)
            tryVerify(() => find("uninstallCancel").activeFocus)
            keyClick(Qt.Key_Up)
            verify(find("uninstallDeleteData").activeFocus)
            compare(find("uninstallDeleteData").checked, false)
            keyClick(Qt.Key_Return)
            compare(find("uninstallDeleteData").checked, true)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Right)
            verify(find("uninstallGo").activeFocus)
            keyClick(Qt.Key_Return)
            enterAdminPin()                            // Ada is a Standard profile (RUY-499)
            tryVerify(() => Store.app("org.example.Puzzle").installed === false)
            verify(Store.mockDataDeleted("org.example.Puzzle"))
            tryVerify(() => find("detailPrimary").text === "Install")
            tryVerify(() => find("detailPrimary").activeFocus, 2000, "focus is not lost")
        }

        function test_uninstall_keeps_data_by_default() {
            openStore()
            openApp("org.example.Puzzle")
            downToUninstall()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("uninstallCancel").activeFocus)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            enterAdminPin()
            tryVerify(() => Store.app("org.example.Puzzle").installed === false)
            verify(!Store.mockDataDeleted("org.example.Puzzle"))
        }

        function test_detail_back_restores_focus() {
            openStore()
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            const cards = find("storeCards_featured")
            compare(cards.currentIndex, 2)
            const id = cards.model[2]
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appDetail")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "store")
            tryVerify(() => cards.activeFocus, 2000, "same row has focus again")
            compare(cards.currentIndex, 2)
            compare(cards.model[cards.currentIndex], id)
        }

        // T-179: Backspace is Back, like Esc.
        function test_backspace_is_back() {
            openStore()
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            const cards = find("storeCards_featured")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appDetail")
            keyClick(Qt.Key_Backspace)                 // detail -> Store, on the same card
            tryCompare(tc.shell, "currentPage", "store")
            tryVerify(() => cards.activeFocus, 2000, "same row has focus again")
            compare(cards.currentIndex, 2)

            keyClick(Qt.Key_Up)                        // a search is left by Back first
            verify(find("storeSearch").activeFocus)
            find("storeSearchEntry").accepted("chess")
            tryVerify(() => find("storeResults").visible, 2000, "results replace the rows")
            tryVerify(() => find("storeResults").activeFocus, 2000)
            keyClick(Qt.Key_Backspace)
            compare(tc.shell.currentPage, "store")
            tryVerify(() => find("storeRows").visible)
            tryVerify(() => find("storeCards_featured").activeFocus, 2000)

            keyClick(Qt.Key_Backspace)                 // Store -> Home
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("sectionNav").activeFocus, 2000, "the nav regains focus")
        }

        function test_backspace_closes_the_uninstall_dialog() {
            openStore()
            openApp("org.example.Puzzle")
            downToUninstall()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("uninstallCancel").activeFocus)
            keyClick(Qt.Key_Backspace)
            tryVerify(() => find("detailUninstall").activeFocus, 2000, "back on the detail page")
            compare(tc.shell.currentPage, "appDetail")
            verify(Store.app("org.example.Puzzle").installed)
        }

        function test_search_replaces_rows_until_back() {
            openStore()
            keyClick(Qt.Key_Up)
            verify(find("storeSearch").activeFocus)
            keyClick(Qt.Key_Return)
            const entry = find("storeSearchEntry")
            tryVerify(() => entry.visible, 2000, "the keyboard opens")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("storeSearch").activeFocus, 2000, "Cancel gives focus back")
            verify(!find("storeResults").visible)
            // Typing on the on-screen keyboard is tst_textentry's job; hand over the text.
            entry.accepted("chess")
            tryVerify(() => find("storeResults").visible, 2000, "results replace the rows")
            tryVerify(() => find("storeResults").model.length === 1)
            tryVerify(() => find("storeResults").activeFocus, 2000)
            verify(!find("storeRows").visible)
            // Over D-Bus the empty search's answer always comes after a callLater: make the mock as late,
            // so focus can't land on the search's stale rows (lead-21, a Linux-only failure).
            Store.mockSearchReplyDelay(200)
            keyClick(Qt.Key_Escape)
            compare(tc.shell.currentPage, "store")
            tryVerify(() => find("storeRows").visible)
            tryVerify(() => find("storeCards_featured").activeFocus, 2000)
            Store.mockSearchReplyDelay(0)
        }

        // T-291: no content rating is "Not rated", not "All ages".
        function test_unrated_app_says_not_rated() {
            compare(Store.catalogue.find(a => a.id === "org.example.Beta").ageRating, "", "the mock app has no rating")
            openStore()
            openApp("org.example.Beta")
            compare(find("detailAge").text, "Not rated")
        }

        function test_all_ages_stays() {
            openStore()
            openApp("org.example.Player")
            compare(Store.catalogue.find(a => a.id === "org.example.Player").ageRating, "all")
            compare(find("detailAge").text, "All ages")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "store")
            openApp("org.example.Racer")
            compare(find("detailAge").text, "Ages 7+")
        }

        // RUY-156: an app that needs a newer API level than the console is not listed anywhere, but
        // the catalogue still knows it and its page opens, with Install off and a line saying why.
        function test_incompatible_app_is_not_listed() {
            const id = "org.example.Future"
            compare(Store.app(id).compatible, false)
            openStore()
            for (const r of ["featured", "games", "apps", "installed"])
                compare(find("storeRow_" + r).ids.indexOf(id), -1, "not in " + r)
            Store.controllerFilter = "any"   // the page starts on "controller apps only"; the mock app has no controller support
            find("storeSearchEntry").accepted("next gen")
            tryVerify(() => Store.results.some(a => a.id === id), 2000, "the search itself finds it")
            compare(Store.rowIds(false).all.indexOf(id), -1, "the results grid does not list it")
            compare(find("appCard_" + id), null)
        }

        // RUY-636: the mock models the level: raised to the app's minimum, it is listed and installable.
        function test_raising_the_level_lists_the_app_and_enables_install() {
            const id = "org.example.Future"
            compare(Store.app(id).compatible, false)
            openStore()
            compare(find("storeRow_featured").ids.indexOf(id), -1, "hidden at level 0")
            Store.mockSetApiLevel(1)
            tryVerify(() => Store.app(id).compatible === true, 2000)
            tryVerify(() => find("storeRow_featured").ids.indexOf(id) >= 0, 2000, "listed in Featured")
            tryVerify(() => find("storeRow_games").ids.indexOf(id) >= 0, 2000, "listed in Games")
            tc.shell.openPage("appDetail", { appId: id })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryCompare(find("page_appDetail"), "detailsReady", true)
            compare(find("detailCompat").visible, false)
            compare(find("detailPrimary").dimmed, false, "Install is on")
        }

        // The backend refuses an install the console does not fit (RUY-634): install at a level that
        // fits, then drop it, so the app is installed but incompatible (the console went back a level).
        function installWhileItFits(id) {
            Store.mockSetApiLevel(1)
            tryVerify(() => Store.app(id).compatible === true, 2000)
            Store.install(id)
            tryVerify(() => Store.app(id).installed === true, 10000)
            Store.mockSetApiLevel(0)
            tryVerify(() => Store.app(id).compatible === false, 2000)
        }

        function test_installed_incompatible_app_stays_in_the_installed_row() {
            const id = "org.example.Future"
            installWhileItFits(id)
            openStore()
            tryVerify(() => find("storeRow_installed").ids.indexOf(id) >= 0, 2000, "still in Installed")
            compare(find("storeRow_featured").ids.indexOf(id), -1, "but not in Featured")
        }

        function test_incompatible_app_page_cannot_install() {
            const id = "org.example.Future"
            tc.shell.openPage("appDetail", { appId: id })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
            tryCompare(find("page_appDetail"), "detailsReady", true)
            compare(find("detailPrimary").text, "Install")
            compare(find("detailPrimary").dimmed, true, "Install is off")
            compare(find("detailCompat").visible, true)
            compare(find("detailCompat").text, "Needs a newer RuyaOS")
            keyClick(Qt.Key_Return)
            wait(50)
            compare(Object.keys(Store.jobs).length, 0, "no install started")
            compare(Store.app(id).installed, false)
            verify(find("detailPrimary").activeFocus, "focus stays on the button")
            keyClick(Qt.Key_Escape)
            tryVerify(() => tc.shell.currentPage !== "appDetail", 2000, "Back leaves the page")
        }

        function test_compatible_app_page_has_no_notice() {
            tc.shell.openPage("appDetail", { appId: "org.example.Racer" })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryCompare(find("page_appDetail"), "detailsReady", true)
            compare(find("detailCompat").visible, false)
            compare(find("detailPrimary").dimmed, false)
        }

        function test_installed_incompatible_app_stays_and_says_so() {
            const id = "org.example.Future"
            installWhileItFits(id)
            tc.shell.openPage("appDetail", { appId: id })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryCompare(find("page_appDetail"), "detailsReady", true)
            compare(find("detailCompat").visible, true)
            compare(find("detailCompat").text, "Needs a newer RuyaOS than this console has. It stays installed.")
            compare(find("detailUninstall").visible, true, "never removed by itself")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openStore()
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/17-store-home.png")
            openApp("org.example.Stream")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/18-store-detail.png")
            keyClick(Qt.Key_Return)                    // Ada is Standard: the admin PIN pad
            tryVerify(() => find("detailPinPad").shown, 2000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/20-store-admin-pin.png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("detailPinPad").shown)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "store")
            wait(800)
            openApp("org.example.Racer")
            wait(800)                                  // the page has finished fading in
            keyClick(Qt.Key_Return)
            tryVerify(() => Store.jobs["org.example.Racer"] !== undefined, 2000)
            grabImage(tc.shell).save(shotsDir + "/19-store-installing.png")
        }

        // T-428: the Store scrolled to "Apps & media" (its cards are built when the row takes focus).
        function test_zz_screenshots_scrolled() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openStore()
            waitForRendering(tc.shell)
            // The Column of the rows can stay unlaid in a real test window until its next polish (as in
            // tst_long_names): lay it out so the scroll below has places to go to.
            find("storeRow_apps").parent.forceLayout()
            tryVerify(() => find("storeRow_apps").y > 0, 2000, "the rows are laid out")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("storeCards_apps").activeFocus, "Apps & media has focus")
            tryVerify(() => find("storeCards_apps").currentItem !== null && find("storeCards_apps").currentItem.focused, 2000)
            tryVerify(() => find("storeRows").contentY > 0, 2000, "the page scrolled down to the row")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/17-store-apps-and-media.png")
        }

        function test_zz_screenshots_unrated() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openStore()
            openApp("org.example.Beta")                // no content rating
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/57-store-detail-unrated.png")
        }

        function test_zz_screenshots_update() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openStore()
            openApp("org.example.Chess")               // an update that adds a high-risk permission
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/56-store-update-adds.png")
        }
    }
}
