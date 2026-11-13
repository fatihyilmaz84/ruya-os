import QtQuick
import QtTest
import RuyaShell

// Uninstall… on a game or app card (02 §1.7, RUY-499): the row and its conditions, the shared confirm
// (Cancel first, the toggle and its line, stacked buttons), the admin's PIN, Store.uninstall with and
// without the data, and where the focus goes when the card has left (Home's Recent row, the hero, Games,
// and nothing left). Block Puzzle (flatpak:org.example.Puzzle) is the app the Store mock has installed.
// Signs in as "Ada" (p2, standard: the admin's PIN is asked) unless a test says it is the admin.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }

    TestCase {
        id: tc
        name: "Uninstall"
        when: windowShown

        property Shell shell: null
        readonly property string puzzle: "flatpak:org.example.Puzzle"
        readonly property string puzzleApp: "org.example.Puzzle"

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.language = "en"
            Library.resetMockForTests("")
            Session.mockReset()
            Store.mockReset()
            launchedSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            host.width = 1280
            Display.setUiScale(0)
            DeviceSettings.language = "en"
            Store.mockPauseJobs(false)
        }

        // As "Ada" (p2, standard) by default; "admin" signs in as Player One (p1, PIN 1234), "guest" as Guest.
        function start(who) {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            if (who === "admin") {
                Profiles.switchTo("p1", "1234")
                tryCompare(Profiles, "activeProfile", "p1")
            } else if (who === "guest") {
                keyClick(Qt.Key_Right)
                keyClick(Qt.Key_Right)
                keyClick(Qt.Key_Return)
                tryCompare(Profiles, "activeProfile", "p3")
            } else {
                keyClick(Qt.Key_Right)
                keyClick(Qt.Key_Return)
                tryCompare(Profiles, "activeProfile", "p2")
            }
            tryVerify(() => Library.available)
            tryVerify(() => Library.items.length === 10)
            tryVerify(() => Store.available)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            wait(50)                                    // the Return that signed in has been released
        }

        function menu() { return find("optionsMenu") }
        function rowIds() { return menu().rows.map(r => r.id) }
        function confirm() { return find("uninstallConfirm") }
        function pad() { return find("uninstallPinPad") }

        function toRecent() {
            keyClick(Qt.Key_Down)
            tryVerify(() => find("recentRow").activeFocus, 2000)
        }

        function toRecentItem(itemId) {
            toRecent()
            const row = find("recentRow")
            for (let i = 0; i < 8 && row.currentItem.itemId !== itemId; ++i)
                keyClick(Qt.Key_Right)
            compare(row.currentItem.itemId, itemId)
        }

        function openGames() {
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Right)
            compare(find("sectionNav").currentKey, "games")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "games")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            wait(50)                                    // the Return that opened it is released
        }

        function toGamesItem(itemId) {
            const grid = find("gamesGrid")
            for (let i = 0; i < 12 && grid.currentItem.itemId !== itemId; ++i)
                keyClick(Qt.Key_Right)
            compare(grid.currentItem.itemId, itemId)
        }

        // The menu is open: down to Uninstall…, Accept; the confirm opens with Cancel focused.
        function chooseUninstall() {
            verify(menu().shown)
            for (let i = 0; i < 8 && menu().rows[menu().current].id !== "uninstall"; ++i)
                keyClick(Qt.Key_Down)
            compare(menu().rows[menu().current].id, "uninstall")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("uninstallCancel").activeFocus, 2000, "Cancel has the focus")
            tryVerify(() => confirm().visible && confirm().opacity >= 1, 2000, "the dialog is up")
        }

        function enterPin(pin) {
            for (const ch of pin)
                keyClick(Qt.Key_0 + Number(ch))
            keyClick(Qt.Key_Enter)
        }

        // Down to Go, Accept; as a standard profile the admin's PIN pad opens.
        function goAndPin(pin) {
            keyClick(Qt.Key_Right)
            verify(find("uninstallGo").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => pad().shown, 2000, "the admin's PIN pad")
            tryVerify(() => pad().activeFocus, 2000)
            enterPin(pin)
        }

        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text)
            return out
        }

        function hintVerbs() {
            const bar = find("hintBar")
            const parts = []
            for (const b of ["A", "B", "Start"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        // ---- the row ----

        function test_the_row_is_last_after_a_divider() {
            start()
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            verify(menu().shown)
            compare(rowIds(), ["play", "details", "activity", "uninstall"])
            const last = menu().rows[3]
            compare(last.label, "Uninstall…")
            compare(last.icon, "delete")
            compare(last.divider, true, "a divider before the destructive row")
            verify(!menu().rows[2].divider)
        }

        function test_a_guest_gets_the_row_without_activity() {
            start("guest")
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            compare(rowIds(), ["play", "details", "uninstall"])
        }

        function test_no_row_for_steam_a_running_app_or_a_store_job() {
            start()
            toRecent()
            keyClick(Qt.Key_Right)                       // Counter Strike
            compare(find("recentRow").currentItem.itemId, "steam:730")
            keyClick(Qt.Key_Menu)
            compare(rowIds(), ["activity"], "not a Flatpak: no Uninstall…")
            keyClick(Qt.Key_Escape)

            keyClick(Qt.Key_Left)                        // Turbo Racer: a Store job runs on its card
            compare(find("recentRow").currentItem.itemId, "flatpak:org.example.Racer")
            keyClick(Qt.Key_Menu)
            verify(rowIds().indexOf("uninstall") >= 0)
            Store.install("org.example.Racer")
            tryVerify(() => Store.jobs["org.example.Racer"] !== undefined, 2000, "the job is on the card")
            Store.mockPauseJobs(true)                    // it stands still
            tryVerify(() => rowIds().indexOf("uninstall") < 0, 2000, "the row is hidden while a job runs")
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Menu)
            compare(rowIds(), ["play", "details", "activity"])
            keyClick(Qt.Key_Escape)
            Store.mockPauseJobs(false)
            tryVerify(() => Store.jobs["org.example.Racer"] === undefined, 10000, "the job ends")
            Store.mockReset()

            // running: Close is there instead
            toRecentItem(tc.puzzle)
            const n = launchedSpy.count
            Session.launch(tc.puzzleApp, "p2")
            tryCompare(launchedSpy, "count", n + 1)
            keyClick(Qt.Key_Menu)
            tryVerify(() => menu().shown)
            verify(rowIds().indexOf("close") >= 0)
            compare(rowIds().indexOf("uninstall"), -1)
        }

        // ---- the confirm ----

        function test_the_confirm_opens_on_cancel_with_the_toggle_off() {
            start()
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            compare(find("uninstallTitle").text, "Uninstall Block Puzzle?")
            compare(find("uninstallDeleteData").checked, false)
            verify(find("uninstallLine").visible)
            compare(find("uninstallLine").text, "Saved data stays on this console.")
            verify(!find("uninstallWarning").visible)
            compare(find("uninstallGo").text, "Uninstall")
            compare(hintVerbs(), "A Select|B Cancel")
            verify(!menu().shown, "the menu closed first")
            // the toggle changes the line and the danger label
            keyClick(Qt.Key_Up)
            verify(find("uninstallDeleteData").activeFocus)
            keyClick(Qt.Key_Return)
            compare(find("uninstallDeleteData").checked, true)
            verify(!find("uninstallLine").visible)
            verify(find("uninstallWarning").visible)
            compare(findChild(find("uninstallWarning"), "uninstallWarningText").text,
                    "Saved data of every profile is deleted too. This can't be undone.")
            compare(find("uninstallGo").text, "Uninstall and delete data")
            keyClick(Qt.Key_Return)
            compare(find("uninstallDeleteData").checked, false)
            compare(find("uninstallGo").text, "Uninstall")
            // Down from the toggle: Cancel; the buttons sit in a row, Left and Right between them
            keyClick(Qt.Key_Down)
            verify(find("uninstallCancel").activeFocus)
            keyClick(Qt.Key_Right)
            verify(find("uninstallGo").activeFocus)
            keyClick(Qt.Key_Up)
            verify(find("uninstallDeleteData").activeFocus, "Up from a button reaches the toggle")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Left)
            verify(find("uninstallCancel").activeFocus)
            compare(find("uninstallCancel").y, find("uninstallGo").y, "one row at 1080p-ish sizes")
            verify(find("uninstallCancel").x < find("uninstallGo").x, "Cancel first")
        }

        function test_back_and_cancel_change_nothing_and_the_toggle_is_off_again() {
            start()
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Return)
            compare(find("uninstallDeleteData").checked, true)
            keyClick(Qt.Key_Escape)                      // Back = Cancel
            tryVerify(() => !confirm().shown)
            tryVerify(() => find("recentRow").activeFocus, 2000, "the focus is on the card")
            compare(find("recentRow").currentItem.itemId, tc.puzzle)
            verify(Library.items.some(i => i.id === tc.puzzle))
            compare(Object.keys(Store.jobs).length, 0)
            // Cancel too, and the toggle is off on every opening
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            compare(find("uninstallDeleteData").checked, false)
            keyClick(Qt.Key_Return)                      // Cancel has the focus
            tryVerify(() => !confirm().shown)
            tryVerify(() => find("recentRow").activeFocus, 2000)
            verify(Store.app(tc.puzzleApp).installed)
        }

        function test_the_buttons_stack_when_they_do_not_fit() {
            start()
            // The test fonts are narrower than the real ones, so the window is narrowed until the long Turkish
            // label cannot share a row with Cancel (on a real 1080p screen at 200 % it is the same case).
            host.width = 900
            DeviceSettings.language = "tr"
            Display.setUiScale(200)
            tryCompare(Theme, "uiScale", 2)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            const title = find("uninstallTitle").text
            verify(title.endsWith(" kaldırılsın mı?"), "only the name is cut, the question survives: " + title)
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Return)                      // the long label: "Kaldır ve verileri sil"
            compare(find("uninstallGo").text, "Kaldır ve verileri sil")
            verify(confirm().stacked, "Cancel, the gap and the pill do not fit one row: " + [confirm().u, confirm().width, confirm().contentWidth, confirm().goWidth, confirm().cancelWidth].join(" "))
            const cancel = find("uninstallCancel")
            const go = find("uninstallGo")
            compare(cancel.width, confirm().contentWidth, "stacked at the full content width")
            compare(go.width, confirm().contentWidth)
            verify(cancel.y < go.y, "Cancel first")
            compare(cancel.x, go.x)
            verify(findChild(confirm(), "uninstallPanel").width <= tc.shell.width, "the card fits the screen")
            // Up/Down move between the stacked buttons; Up from the top one reaches the toggle
            keyClick(Qt.Key_Down)
            verify(cancel.activeFocus)
            keyClick(Qt.Key_Down)
            verify(go.activeFocus)
            keyClick(Qt.Key_Up)
            verify(cancel.activeFocus)
            keyClick(Qt.Key_Up)
            verify(find("uninstallDeleteData").activeFocus)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !confirm().shown)
        }

        function test_signing_out_closes_the_dialog_and_the_pin_pad() {
            start()
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => pad().shown, 2000)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => !confirm().shown && !pad().shown, 2000, "nothing is left over the picker")
            compare(Object.keys(Store.jobs).length, 0)
            verify(Store.app(tc.puzzleApp).installed)
        }

        // ---- the admin's PIN, and Store.uninstall ----

        function test_a_standard_profile_enters_an_admin_pin_and_back_cancels_everything() {
            start()
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => pad().shown, 2000)
            compare(findChild(pad(), "pinTitle").text, "Enter an admin's PIN")
            compare(hintVerbs(), "B Cancel")
            keyClick(Qt.Key_Escape)                      // Back on the empty pad
            tryVerify(() => !pad().shown && !confirm().shown, 2000, "Back cancels everything")
            tryVerify(() => find("recentRow").activeFocus, 2000)
            compare(Object.keys(Store.jobs).length, 0)
            verify(Store.app(tc.puzzleApp).installed)
        }

        function test_a_wrong_pin_shows_the_pin_pads_message() {
            start()
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            goAndPin("0000")
            tryVerify(() => findChild(pad(), "pinMessage").text.indexOf("Wrong PIN") === 0, 2000)
            verify(pad().shown, "the pad stays for another try")
            verify(Store.app(tc.puzzleApp).installed)
            compare(Object.keys(Store.jobs).length, 0)
            enterPin("1234")
            tryVerify(() => Store.app(tc.puzzleApp).installed === false, 5000)
        }

        function test_the_right_pin_uninstalls_and_keeps_the_data_by_default() {
            start()
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            goAndPin("1234")
            tryVerify(() => Store.app(tc.puzzleApp).installed === false, 5000)
            verify(!Store.mockDataDeleted(tc.puzzleApp), "delete_data false")
        }

        function test_the_toggle_on_deletes_the_saves() {
            start()
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Down)
            goAndPin("1234")
            tryVerify(() => Store.app(tc.puzzleApp).installed === false, 5000)
            verify(Store.mockDataDeleted(tc.puzzleApp), "delete_data true")
        }

        function test_an_admin_needs_no_pin() {
            start("admin")
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            verify(!pad().shown, "no PIN pad for an admin")
            tryVerify(() => Store.app(tc.puzzleApp).installed === false, 5000)
        }

        // ---- the result ----

        function test_success_toasts_and_focuses_the_next_recent_card() {
            start()
            toRecentItem(tc.puzzle)
            const row = find("recentRow")
            const at = row.currentIndex
            const ids = tc.shell.recentIds.slice()
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            goAndPin("1234")
            tryVerify(() => Store.app(tc.puzzleApp).installed === false, 5000)
            tryVerify(() => toastTexts().indexOf("Block Puzzle was uninstalled.") >= 0, 2000)
            Library.mockRemoveItem(tc.puzzle)            // Library1 sees the app go
            tryVerify(() => !tc.shell.recentIds.includes(tc.puzzle), 2000, "the card leaves")
            tryVerify(() => row.activeFocus && row.currentIndex === at, 2000, "the focus is at its place")
            compare(row.currentItem.itemId, tc.shell.recentIds[at])
            verify(ids[at] !== row.currentItem.itemId)
        }

        function test_the_card_may_leave_before_the_job_ends() {
            start()
            toRecentItem(tc.puzzle)
            const row = find("recentRow")
            const at = row.currentIndex
            Store.mockPauseJobs(true)                    // the job stands still: the card leaves first
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            goAndPin("1234")
            tryVerify(() => !pad().shown, 2000)
            verify(Store.app(tc.puzzleApp).installed, "the job has not run")
            keyClick(Qt.Key_Menu)                        // asked, with no progress yet: the row is already gone
            verify(menu().shown)
            compare(rowIds(), ["play", "details", "activity"])
            keyClick(Qt.Key_Escape)
            Library.mockRemoveItem(tc.puzzle)
            tryVerify(() => !tc.shell.recentIds.includes(tc.puzzle), 2000)
            Store.mockPauseJobs(false)
            tryVerify(() => toastTexts().indexOf("Block Puzzle was uninstalled.") >= 0, 5000)
            tryVerify(() => row.activeFocus && row.currentIndex === at, 2000)
            verify(row.currentItem.itemId !== tc.puzzle)
        }

        function test_from_the_hero_the_focus_goes_to_its_primary_button() {
            start()
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Up)                          // the hero shows Block Puzzle
            tryVerify(() => find("homePlay").activeFocus)
            compare(find("heroTitle").text, "Block Puzzle")
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            goAndPin("1234")
            tryVerify(() => Store.app(tc.puzzleApp).installed === false, 5000)
            Library.mockRemoveItem(tc.puzzle)
            tryVerify(() => find("heroTitle").text !== "Block Puzzle", 2000)
            tryVerify(() => find("homePlay").activeFocus, 2000, "the hero's primary button")
            compare(find("recentRow").currentIndex, 0, "it shows the Recent row's first item")
            compare(find("heroTitle").text, tc.shell.heroItem.title)
            compare(find("heroTitle").text, Library.item(tc.shell.recentIds[0]).title)
        }

        function test_nothing_installed_any_more_focuses_open_store() {
            start()
            for (const i of Library.items.slice()) {
                if (i.id !== tc.puzzle)
                    Library.mockRemoveItem(i.id)
            }
            tryVerify(() => tc.shell.recentIds.length === 1, 2000)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            goAndPin("1234")
            tryVerify(() => Store.app(tc.puzzleApp).installed === false, 5000)
            Library.mockRemoveItem(tc.puzzle)
            tryVerify(() => tc.shell.libraryEmpty, 2000)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            compare(find("homePlay").text, "Open Store")
        }

        function test_a_failure_toasts_and_keeps_the_focus() {
            start()
            toRecent()                                   // Turbo Racer: the Store does not have it installed
            compare(find("recentRow").currentItem.itemId, "flatpak:org.example.Racer")
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            goAndPin("1234")
            tryVerify(() => toastTexts().indexOf("Could not uninstall Turbo Racer. Try again.") >= 0, 5000)
            verify(find("recentRow").activeFocus, "the focus stays on the item")
            compare(find("recentRow").currentItem.itemId, "flatpak:org.example.Racer")
            verify(Library.items.some(i => i.id === "flatpak:org.example.Racer"))
        }

        function test_games_focus_goes_to_the_next_card_and_then_to_open_the_store() {
            start()
            openGames()
            toGamesItem(tc.puzzle)
            const grid = find("gamesGrid")
            const at = grid.currentIndex
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            goAndPin("1234")
            tryVerify(() => Store.app(tc.puzzleApp).installed === false, 5000)
            tryVerify(() => toastTexts().indexOf("Block Puzzle was uninstalled.") >= 0, 2000)
            Library.mockRemoveItem(tc.puzzle)
            tryVerify(() => grid.count === 7, 2000)
            tryVerify(() => grid.activeFocus && grid.currentIndex === at, 2000, "the next card")
            verify(grid.currentItem.itemId !== tc.puzzle)
        }

        function test_games_with_nothing_left_focus_open_the_store() {
            start()
            for (const i of Library.items.slice()) {
                if (i.id !== tc.puzzle)
                    Library.mockRemoveItem(i.id)
            }
            tryVerify(() => Library.items.length === 1, 2000)
            openGames()
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            goAndPin("1234")
            tryVerify(() => Store.app(tc.puzzleApp).installed === false, 5000)
            Library.mockRemoveItem(tc.puzzle)
            tryVerify(() => find("gamesOpenStore").activeFocus, 2000, "Open the Store")
        }

        function test_games_the_last_card_hands_the_focus_to_the_previous_one() {
            start()
            for (const i of Library.items.slice()) {
                if (i.id !== tc.puzzle && i.id !== "steam:730")
                    Library.mockRemoveItem(i.id)
            }
            tryVerify(() => Library.items.length === 2, 2000)
            openGames()
            const grid = find("gamesGrid")
            toGamesItem(tc.puzzle)
            compare(grid.currentIndex, 1, "Block Puzzle is the last card")
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            goAndPin("1234")
            tryVerify(() => Store.app(tc.puzzleApp).installed === false, 5000)
            Library.mockRemoveItem(tc.puzzle)
            tryVerify(() => grid.count === 1, 2000)
            tryVerify(() => grid.activeFocus && grid.currentItem.itemId === "steam:730", 2000, "the previous card")
        }

        // ---- the app page uses the same dialog ----

        function test_the_app_pages_uninstall_uses_the_same_dialog() {
            start()
            tryVerify(() => Store.catalogue.length > 0)
            tc.shell.openPage("appDetail", { appId: tc.puzzleApp })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary").activeFocus, 2000)
            keyClick(Qt.Key_Down)
            verify(find("detailUninstall").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("uninstallCancel").activeFocus, 2000)
            compare(find("uninstallTitle").text, "Uninstall Block Puzzle?")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => pad().shown, 2000, "the admin's PIN pad, as from the menu")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !confirm().shown && !pad().shown, 2000)
            tryVerify(() => find("detailUninstall").activeFocus, 2000, "Back lands on the button")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("uninstallCancel").activeFocus)
            goAndPin("1234")
            tryVerify(() => Store.app(tc.puzzleApp).installed === false, 5000)
            tryVerify(() => find("detailPrimary").text === "Install", 2000)
            tryVerify(() => find("detailPrimary").activeFocus, 2000, "focus is not lost")
            compare(toastTexts().indexOf("Block Puzzle was uninstalled."), -1, "the page shows the result itself")
        }

        // ---- screenshots (dev.ps1 shots; English and Turkish) ----

        function settle() { wait(900) }

        function openConfirm() {
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            tryVerify(() => menu().opacity >= 1, 2000)
            chooseUninstall()
            tryVerify(() => menu().opacity <= 0, 2000)
            tryVerify(() => confirm().opacity >= 1, 2000)
        }

        function test_zz_screenshots_confirm() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            for (const lang of ["en", "tr"]) {
                DeviceSettings.language = lang
                start()
                openConfirm()
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "70-uninstall-confirm-" + lang + ".png")
                keyClick(Qt.Key_Up)
                keyClick(Qt.Key_Return)                      // the toggle on: the warning and the long label
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "71-uninstall-warning-" + lang + ".png")
                keyClick(Qt.Key_Down)
                keyClick(Qt.Key_Right)
                keyClick(Qt.Key_Return)                      // as Ada: the admin's PIN pad
                tryVerify(() => pad().shown && pad().opacity >= 1, 2000)
                keyClick(Qt.Key_0)
                keyClick(Qt.Key_0)
                keyClick(Qt.Key_0)
                keyClick(Qt.Key_0)
                keyClick(Qt.Key_Enter)                       // a wrong PIN: the pad's message
                tryVerify(() => findChild(pad(), "pinMessage").text.length > 0, 2000)
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "72-uninstall-pin-wrong-" + lang + ".png")
                keyClick(Qt.Key_Escape)
                tryVerify(() => !confirm().shown, 2000)
                tc.shell.destroy()
                wait(100)
            }
        }

        function test_zz_screenshots_stacked() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            for (const lang of ["en", "tr"]) {
                DeviceSettings.language = lang
                start()
                Display.setUiScale(200)
                tryCompare(Theme, "uiScale", 2)
                tryVerify(() => find("homePlay").activeFocus, 2000)
                openConfirm()
                keyClick(Qt.Key_Up)
                keyClick(Qt.Key_Return)
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "73-uninstall-big-ui-" + lang + ".png")
                keyClick(Qt.Key_Escape)
                tryVerify(() => !confirm().shown, 2000)
                Display.setUiScale(0)
                tc.shell.destroy()
                wait(100)
            }
        }

        // ---- the lockout: last, it leaves the admin locked out ----

        function test_zz_too_many_wrong_pins_dim_the_pad_and_count_down() {
            start()
            toRecentItem(tc.puzzle)
            keyClick(Qt.Key_Menu)
            chooseUninstall()
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => pad().shown, 2000)
            for (let i = 0; i < 8 && !pad().locked; ++i) {
                enterPin("0000")
                tryVerify(() => !pad().busy, 2000)
            }
            verify(pad().locked, "the pad is dimmed")
            verify(pad().lockSecs > 0, "with its countdown")
            verify(findChild(pad(), "pinMessage").text.indexOf("Too many attempts") === 0)
            verify(pad().shown)
            verify(Store.app(tc.puzzleApp).installed)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !pad().shown && !confirm().shown, 2000)
        }
    }
}
