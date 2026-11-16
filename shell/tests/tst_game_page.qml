import QtQuick
import QtTest
import RuyaShell

// The game page, part 1 (02 §1.8, RUY-524): one page per Library or Store item (`appDetail`), a header that
// changes with the state (not installed, a Store job, installed, update, running, no launch path, the Store
// not answering), then This app can, Information and Manage; focus stops, the column's offset and Back.
// Signs in as "Ada" (p2, a Standard profile).
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
        Item {
            property string appId: "org.example.Puzzle"
            property int pid: 0
            objectName: "standInApp"
            Keys.onPressed: event => { event.accepted = true }
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }
    SignalSpy { id: launchSpy; target: Library; signalName: "launchRequested" }
    SignalSpy { id: pidSpy; target: Session; signalName: "instanceOfPidFinished" }

    TestCase {
        id: tc
        name: "GamePage"
        when: windowShown

        property Shell shell: null
        readonly property string racer: "flatpak:org.example.Racer"
        readonly property string puzzle: "flatpak:org.example.Puzzle"

        function find(name) { return findChild(tc.shell, name) }
        function page() { return find("page_appDetail") }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.language = "en"
            Library.resetMockForTests("")
            Session.mockReset()
            Store.mockReset()
            launchedSpy.clear()
            launchSpy.clear()
            pidSpy.clear()
        }

        function cleanup() {
            DeviceSettings.language = "en"
            Store.mockPauseJobs(false)
        }

        function start(itemCount) {
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
            tryVerify(() => Library.items.length === (itemCount ?? 10))
            tryVerify(() => Store.available && Store.catalogue.length > 0)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            wait(50)
        }

        // Opens the page with `params` and waits until it is settled and focused.
        function openPage(params, focusName) {
            tc.shell.openPage("appDetail", params)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find(focusName ?? "detailPrimary") && find(focusName ?? "detailPrimary").activeFocus, 2000,
                      "focus starts on " + (focusName ?? "detailPrimary"))
        }

        function hintVerbs() {
            const bar = find("hintBar")
            const parts = []
            for (const b of ["accept", "back", "options"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        function recordOf(instance) { return Session.running.find(r => r.instance === instance) }

        function launchBare(appId) {
            const n = launchedSpy.count
            Session.launch(appId, "p2")
            tryCompare(launchedSpy, "count", n + 1)
            const instance = launchedSpy.signalArguments[n][3]
            verify(instance !== "")
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            return instance
        }

        function addWindow(props) {
            const n = pidSpy.count
            const app = createTemporaryObject(appComponent, host, props ?? {})
            verify(app)
            tc.shell.addApp(app, "p2")
            if ((app.pid ?? 0) > 0)
                tryCompare(pidSpy, "count", n + 1)
            return app
        }

        function goHome() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
            const panel = find("systemPanel")
            for (let i = 0; i < 30 && panel.currentKey !== "home"; ++i)
                keyClick(Qt.Key_Down)
            compare(panel.currentKey, "home")
            keyClick(Qt.Key_Return)
            tryVerify(() => !tc.shell.appOpen, 2000, "Home is in front")
            tryVerify(() => find("recentRow").activeFocus || find("homePlay").activeFocus, 2000)
        }

        // ---- the header by state ----

        function test_not_installed_shows_install_and_the_sizes() {
            start()
            openPage({ appId: "org.example.Racer" })
            compare(page().title, "Turbo Racer")
            compare(find("detailPrimary").text, "Install")
            compare(find("detailPrimary").dimmed, false)
            verify(find("detailPrimary").width >= 280 * page().u, "at least 280 wide")
            compare(find("detailSource").text, "Official")
            compare(find("detailAge").text, "Ages 7+")
            compare(find("detailDeveloper").text, "Example Games")
            verify(!find("detailRunning").visible)
            verify(!find("detailUpdateBadge").visible)
            verify(find("detailDownload").visible)
            verify(/^Download .+ · .+ on disk$/.test(find("detailDownload").text), find("detailDownload").text)
            compare(find("detail_update"), null, "no secondary button")
            verify(!find("detailManage").visible, "nothing to manage before it is installed")
            verify(find("detailPermissions").visible)
            compare(hintVerbs(), "accept Select|back Back")
        }

        function test_the_same_item_from_a_library_id_and_from_the_store() {
            start()
            openPage({ id: tc.racer })
            const fromId = [page().title, page().appId, find("detailPrimary").text]
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            openPage({ appId: "org.example.Racer" })
            compare([page().title, page().appId, find("detailPrimary").text], fromId)
            compare(fromId[0], "Turbo Racer")
            compare(fromId[1], "org.example.Racer")
        }

        function test_installed_game_plays_and_manages() {
            start()
            openPage({ id: tc.puzzle })
            compare(find("detailPrimary").text, "Play")
            compare(find("detailPrimary").dimmed, false)
            compare(find("detail_update"), null)
            verify(!find("detailDownload").visible, "no download line once installed")
            verify(find("detailUninstall").visible)
            keyClick(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
            compare(launchSpy.signalArguments[0][0], tc.puzzle)
        }

        function test_update_adds_a_button_and_the_status_lines() {
            Library.resetMockForTests("chess")
            start(11)
            openPage({ id: "flatpak:org.example.Chess" })
            tryCompare(page(), "hasUpdate", true)
            compare(find("detailPrimary").text, "Play")
            compare(find("detail_update").text, "Update")
            verify(find("detailUpdateBadge").visible, "the Update ready badge")
            compare(find("detailUpdateBadge").text, "Update ready")
            compare(find("detailUpdateReady").text, "Update ready: version 1.5.0")
            verify(find("detailUpdateAdds").visible, "the adds line")
            verify(find("detailUpdateAdds").text.indexOf("Accesses all devices") >= 0, "adds: " + find("detailUpdateAdds").text)
            verify(find("detailAdminNote").visible, "Ada is not an admin: the PIN line")
            keyClick(Qt.Key_Right)
            verify(find("detail_update").activeFocus, "Left and Right move between the buttons")
            keyClick(Qt.Key_Left)
            verify(find("detailPrimary").activeFocus)
            keyClick(Qt.Key_Right)
            verify(find("detail_update").activeFocus, "Update has the focus")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("detailPinPad").shown, 2000, "the update needs an admin's PIN")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("detailPinPad").shown)
            tryVerify(() => find("detailPrimary").activeFocus || find("detail_update").activeFocus, 2000)
        }

        function test_a_store_job_dims_the_primary_and_hides_the_rest() {
            Library.resetMockForTests("chess")
            start(11)
            Store.install("org.example.Racer")
            tryVerify(() => Store.jobs["org.example.Racer"] !== undefined, 2000, "progress arrived")
            Store.mockPauseJobs(true)
            openPage({ appId: "org.example.Racer" })
            verify(page().working)
            compare(find("detailPrimary").dimmed, true)
            verify(find("detailPrimary").text.endsWith("…"), find("detailPrimary").text)
            verify(find("detailProgress").visible)
            verify(/^\d+ % · It keeps going if you leave this page\.$/.test(find("detailPhase").text), find("detailPhase").text)
            verify(!find("detailDownload").visible)
            verify(!find("detailManage").visible, "no Manage while a job runs")
            keyClick(Qt.Key_Return)
            tryVerify(() => Notifications.model.count > 0, 2000)
            compare(Notifications.model.get(0).text, "Another change is running. Try again in a moment.")
            verify(find("detailPrimary").activeFocus, "the dimmed button keeps the focus")
        }

        function test_running_shows_resume_and_close_and_blocks_uninstall() {
            start()
            const instance = launchBare("org.example.Puzzle")
            const app = addWindow({ pid: Session.mockPidOf(instance) })
            tryVerify(() => app.activeFocus, 2000)
            goHome()
            openPage({ id: tc.puzzle })
            compare(find("detailPrimary").text, "Resume")
            compare(find("detail_close").text, "Close game")
            verify(find("detailRunning").visible, "the Running badge")
            compare(find("detailRunning").text, "Running")
            verify(!find("detailUninstall").visible, "no Uninstall… while it runs")
            verify(find("detailManageNote").visible, "the note instead")
            compare(find("detailManageNote").label, "Close the game to uninstall it.")
        }

        function test_an_app_says_open() {
            start()
            Store.install("org.example.Player")
            tryVerify(() => Store.app("org.example.Player").installed === true, 5000)
            tryVerify(() => Store.jobs["org.example.Player"] === undefined, 5000)
            openPage({ id: "flatpak:org.example.Player" })
            compare(find("detailPrimary").text, "Open")
            // The Options menu says it too (02 §1.7).
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            compare(tc.shell.gameRows("flatpak:org.example.Player")[0].label, "Open")
        }

        function test_a_steam_item_has_no_buttons_and_starts_on_a_fact() {
            start()
            openPage({ id: "steam:730" }, "fact_source")
            compare(page().title, "Counter Strike")
            compare(find("detailPrimary"), null, "no launch path: no buttons")
            verify(find("detailNoLaunch").visible)
            compare(find("detailNoLaunch").label, "Start this game from Steam for now.")
            compare(find("detailSource").text, "Steam")
            verify(find("detailSource").visible, "the Steam badge shows")
            compare(find("detailDeveloper").text, "Installed through Steam")
            verify(find("detailDeveloper").visible, "the Steam line shows")
            verify(!find("detailAge").visible)
            verify(!find("detailPermissionsSection").visible, "no permissions for Steam")
            verify(!find("detailManage").visible)
            compare(find("fact_steamId").value, "730")
            verify(find("fact_lastPlayed").value !== "")
            compare(find("fact_developer"), null, "a fact with no value is left out")
            verify(find("detailSteamPlayTime").visible)
            compare(hintVerbs(), "back Back")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
        }

        function test_the_store_not_answering_offers_try_again() {
            Library.resetMockForTests("unlisted")
            start(11)
            openPage({ id: "flatpak:org.example.Unlisted" })
            compare(page().title, "Unlisted App")
            compare(find("detailPrimary").text, "Open", "an app")
            compare(find("detail_retry").text, "Try again")
            verify(find("detailStoreDown").visible)
            compare(find("detailStoreDown").text, "Store details are unavailable right now.")
            verify(!find("detailSource").visible, "a Flatpak with no record has no source badge")
            verify(!find("detailAge").visible)
            verify(!find("detailPermissionsSection").visible)
            compare(find("fact_source").value, "Flatpak")
            compare(find("fact_appId").value, "org.example.Unlisted")
            verify(!find("detailManage").visible, "no uninstall without a record")
            keyClick(Qt.Key_Right)
            verify(find("detail_retry").activeFocus)
            keyClick(Qt.Key_Return)
            verify(find("detail_retry").activeFocus, "Try again keeps the focus")
        }

        function test_the_service_going_away_offers_try_again() {
            start()
            openPage({ id: tc.puzzle })
            compare(find("detail_retry"), null, "the Store answers: no Try again")
            Store.mockServiceLost()
            tryVerify(() => !Store.available)
            tryVerify(() => find("detail_retry") !== null, 2000, "Try again appears")
            verify(find("detailStoreDown").visible)
            compare(find("detailPrimary").text, "Play", "the Library data and Play stay")
            Store.mockServiceRegained()
            tryVerify(() => Store.available)
            tryVerify(() => find("detail_retry") === null, 2000, "and goes when it answers again")
        }

        function test_an_install_error_is_a_status_line() {
            start()
            tc.shell.openPage("appDetail", { appId: "org.example.Broken" })
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
            tryCompare(page(), "detailsReady", true)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("detailError").visible, 5000)
            compare(find("detailError").color, Theme.errorText)
            compare(find("detailPrimary").text, "Install")
        }

        // ---- the sections ----

        function test_facts_are_left_out_when_they_have_no_value() {
            start()
            openPage({ id: tc.puzzle })
            tryCompare(page(), "detailsReady", true)
            verify(find("fact_developer") !== null)
            verify(find("fact_size") !== null, "installed: the size on disk")
            compare(find("fact_downloadSize"), null)
            compare(find("fact_license"), null, "Block Puzzle has no licence in the mock")
            compare(find("fact_source").value, "Official")
            compare(find("fact_controller").value, "Full controller support")
        }

        function test_information_of_a_not_installed_app() {
            start()
            openPage({ appId: "org.example.Racer" })
            tryCompare(page(), "detailsReady", true)
            compare(find("fact_version").value, "1.4.2")
            verify(find("fact_updated").value.indexOf("2024") >= 0, find("fact_updated").value)
            verify(find("fact_downloadSize") !== null && find("fact_installedSize") !== null)
            compare(find("fact_size"), null)
            compare(find("fact_license").value, "MIT")
            compare(find("fact_categories").value, "Adventure, Puzzle", "known words only, Game dropped")
            compare(find("fact_age").value, "Ages 7+")
        }

        function test_turkish_words() {
            DeviceSettings.language = "tr"
            start()
            openPage({ appId: "org.example.Racer" })
            tryCompare(page(), "detailsReady", true)
            compare(find("detailPrimary").text, "Kur")
            compare(find("fact_categories").value, "Macera, Bulmaca")
            compare(find("fact_license").label, "Lisans")
            verify(/^İndirme .+ · Diskte .+$/.test(find("detailDownload").text), find("detailDownload").text)
        }

        // ---- focus, scrolling, Back ----

        function test_focus_goes_stop_to_stop_and_the_column_follows() {
            start()
            openPage({ appId: "org.example.Racer" })
            tryCompare(page(), "detailsReady", true)
            const column = find("detailColumn")
            const viewport = find("detailViewport")
            compare(page().offset, 0, "in the header the column is at 0")
            keyClick(Qt.Key_Up)
            verify(find("detailPrimary").activeFocus, "Up stops at the first stop")
            keyClick(Qt.Key_Down)
            verify(find("detailPermissions").activeFocus, "This app can is one stop")
            compare(hintVerbs(), "back Back")
            keyClick(Qt.Key_Down)
            verify(find("fact_developer").activeFocus, "the first fact")
            const info = find("detailInformation")
            tryCompare(page(), "offset", Math.min(info.y, column.height - viewport.height))
            verify(page().offset > 0, "the heading of Information moved up")
            tryVerify(() => Math.abs(column.y + page().offset) < 0.5, 2000, "the column glides to the offset")
            keyClick(Qt.Key_Right)
            verify(find("fact_source").activeFocus, "Right: the other column")
            keyClick(Qt.Key_Down)
            verify(find("fact_updated").activeFocus, "Down keeps the column")
            keyClick(Qt.Key_Left)
            verify(find("fact_version").activeFocus)
            // to the last fact: the end of the page stops it
            for (let i = 0; i < 12; ++i)
                keyClick(Qt.Key_Down)
            const last = find("fact_appId")
            verify(last.activeFocus || find("fact_controller").activeFocus)
            tryCompare(page(), "offset", Math.max(0, column.height - viewport.height), 2000, "never past the end")
            // and back up to the header: offset 0
            for (let i = 0; i < 20; ++i)
                keyClick(Qt.Key_Up)
            verify(find("detailPrimary").activeFocus)
            tryCompare(page(), "offset", 0)
            compare(hintVerbs(), "accept Select|back Back")
        }

        function test_back_closes_the_page_and_returns_the_focus() {
            start()
            keyClick(Qt.Key_Right)                       // Details
            tryVerify(() => find("homeDetails").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appDetail")
            compare(tc.shell.currentParams.id, tc.racer)
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
            keyClick(Qt.Key_Menu)
            verify(!find("optionsMenu").shown, "the options button does nothing on this page")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homeDetails").activeFocus, 2000, "back on Details")
        }

        function test_the_options_menus_details_opens_the_page_for_a_steam_card() {
            start()
            keyClick(Qt.Key_Down)
            tryVerify(() => find("recentRow").activeFocus, 2000)
            keyClick(Qt.Key_Right)                       // Counter Strike
            compare(find("recentRow").currentItem.itemId, "steam:730")
            keyClick(Qt.Key_Menu)
            tryVerify(() => find("optionsMenu").shown)
            compare(find("optionsMenu").rows[0].id, "details")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appDetail")
            compare(tc.shell.currentParams.id, "steam:730")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("recentRow").activeFocus, 2000, "the card has the focus again")
        }

        function test_uninstall_asks_the_shared_dialog() {
            start()
            openPage({ id: tc.puzzle })
            find("detailUninstall").forceActiveFocus()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("uninstallCancel").activeFocus, 2000)
            compare(find("uninstallTitle").text, "Uninstall Block Puzzle?")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("detailUninstall").activeFocus, 2000, "Cancel returns to the row")
        }

        // ---- screenshots (dev.ps1 shots; English and Turkish, 1080p and 720p) ----

        function settle() { wait(900) }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            for (const size of [[1280, 720, "720p"], [1920, 1080, "1080p"]])
            for (const lang of ["en", "tr"]) {
                host.width = size[0]
                host.height = size[1]
                DeviceSettings.language = lang
                Library.resetMockForTests("chess")
                Session.mockReset()
                Store.mockReset()
                start(11)
                tryVerify(() => Store.catalogue.length > 0)
                // not installed
                openPage({ appId: "org.example.Racer" })
                tryCompare(page(), "detailsReady", true)
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "100-game-page-not-installed-" + lang + "-" + size[2] + ".png")
                keyClick(Qt.Key_Down)
                keyClick(Qt.Key_Down)
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "101-game-page-information-" + lang + "-" + size[2] + ".png")
                keyClick(Qt.Key_Escape)
                tryCompare(tc.shell, "currentPage", "")
                // installed, with an update
                openPage({ id: "flatpak:org.example.Chess" })
                tryCompare(page(), "detailsReady", true)
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "102-game-page-update-" + lang + "-" + size[2] + ".png")
                for (let i = 0; i < 20; ++i)
                    keyClick(Qt.Key_Down)
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "103-game-page-manage-" + lang + "-" + size[2] + ".png")
                keyClick(Qt.Key_Escape)
                tryCompare(tc.shell, "currentPage", "")
                // running
                const instance = launchBare("org.example.Puzzle")
                const app = addWindow({ pid: Session.mockPidOf(instance) })
                tryVerify(() => app.activeFocus, 2000)
                goHome()
                tc.shell.openPage("appDetail", { id: tc.puzzle })
                tryCompare(tc.shell, "currentPage", "appDetail")
                tryVerify(() => page() && page().primaryKind === "resume", 2000)
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "104-game-page-running-" + lang + "-" + size[2] + ".png")
                tc.shell.closePage()
                // Steam
                tc.shell.openPage("appDetail", { id: "steam:730" })
                tryCompare(tc.shell, "currentPage", "appDetail")
                tryVerify(() => find("fact_source") && find("fact_source").activeFocus, 2000)
                verify(find("detailSource").visible && find("detailDeveloper").visible, "the Steam header lines: " + find("detailSource").parent.height + " " + find("detailSource").parent.visible + " " + find("detailDeveloper").height)
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "105-game-page-steam-" + lang + "-" + size[2] + ".png")
                tc.shell.closePage()
                // the Store does not answer
                Store.mockServiceLost()
                tryVerify(() => !Store.available)
                tc.shell.openPage("appDetail", { id: tc.puzzle })
                tryCompare(tc.shell, "currentPage", "appDetail")
                tryVerify(() => find("detail_retry") !== null, 2000)
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "106-game-page-store-down-" + lang + "-" + size[2] + ".png")
                Store.mockServiceRegained()
                tc.shell.destroy()
                wait(100)
            }
            host.width = 1280
            host.height = 720
        }
    }
}
