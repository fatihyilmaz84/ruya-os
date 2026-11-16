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
            Usage.mockReset()
            launchedSpy.clear()
            launchSpy.clear()
            pidSpy.clear()
        }

        function cleanup() {
            DeviceSettings.language = "en"
            Store.mockPauseJobs(false)
            host.width = 1280
            host.height = 720
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
            compare(page().offset, 0, "the focus the page starts on does not scroll the header away")
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

        // The art is the header's right edge: page x 1120..1824 at 1080p (the header starts at the content's x 96).
        function test_the_art_sits_at_x_1120_to_1824_at_1080p() {
            host.width = 1920
            host.height = 1080
            start()
            openPage({ appId: "org.example.Racer" })
            tryCompare(tc.shell, "u", 1)
            tryVerify(() => tc.shell.slots[tc.shell.slots.length - 1].settled, 2000, "the page has finished sliding in")
            const art = find("detailHero")
            const at = art.mapToItem(tc.shell, 0, 0)
            // The content box is the column; the clipping viewport reaches a ring's width past it on both sides.
            const column = find("detailColumn")
            const view = column.mapToItem(tc.shell, 0, 0)
            compare(Math.round(view.x), Math.round(tc.shell.marginX), "the content starts at the safe-area margin: " + view.x + " " + tc.shell.marginX)
            fuzzyCompare(at.x - view.x, 1024, 1, "the art is at page x 1120 relative to the content's left edge")
            fuzzyCompare(at.x + art.width, view.x + column.width, 1, "the art ends at the content's right edge")
            compare(art.width, 704)
            // Owner (lead-27): the focused Play button's ring was cut at the left edge. The whole ring lies
            // inside the clipping viewport, also on the right of the art's column edge.
            const viewport = find("detailViewport")
            const play = find("detailPrimary")
            tryVerify(() => play.activeFocus, 2000, "Play has the focus")
            const ring = findChild(play, "focusRing")
            verify(ring && ring.visible, "Play shows its focus ring")
            const r = ring.mapToItem(viewport, 0, 0)
            verify(r.x >= 0, "the ring's left edge lies inside the viewport: " + r.x)
            verify(at.x + art.width + Theme.focusRingOffset + Theme.focusRingWidth
                   <= viewport.mapToItem(tc.shell, 0, 0).x + viewport.width + 0.5, "a ring around the right edge would fit too")
            host.width = 1280
            host.height = 720
        }

        // After Uninstall… the Library drops the item; a page opened with { id } keeps the app and shows the Store record.
        function test_uninstalling_from_an_id_page_keeps_the_page() {
            start()
            openPage({ id: tc.puzzle })
            compare(page().title, "Block Puzzle")
            Store.uninstall("org.example.Puzzle", false)
            tryVerify(() => Library.item(tc.puzzle).id === undefined, 5000, "the Library drops the item")
            tryVerify(() => Store.app("org.example.Puzzle").installed === false, 5000)
            compare(page().title, "Block Puzzle", "the title stays")
            compare(page().appId, "org.example.Puzzle")
            tryCompare(find("detailPrimary"), "text", "Install")
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

        // ---- Your activity (RUY-532) ----

        readonly property string today: "2026-11-07"

        // One session: `ago` days before today, at 18:00 UTC, `secs` of play.
        function mk(app, ago, secs) {
            const d = new Date(Date.UTC(2026, 10, 7 - ago, 18, 0))
            return { appId: app, start: d.getTime() / 1000, seconds: secs, reason: "quit",
                     day: d.toISOString().slice(0, 10) }
        }

        function seedRuns() {
            Usage.mockSetData("p2", [mk("org.example.Puzzle", 0, 1800), mk("org.example.Puzzle", 3, 3000),
                                     mk("org.example.Puzzle", 20, 600), mk("org.example.Racer", 1, 900),
                                     mk("org.example.Player", 1, 7200), mk("org.example.Player", 2, 60)], today)
        }

        // [value, caption] of a stat.
        function stat(name) {
            const item = find(name)
            return [item.children[0].text, item.children[1].text]
        }

        function test_activity_shows_for_an_installed_game_with_its_numbers() {
            seedRuns()
            start()
            openPage({ id: tc.puzzle })
            tryVerify(() => find("detailActivity").visible, 2000)
            compare(find("detailActivitySection").visible, true)
            compare(find("activityHeading").text, "Your activity")
            compare(stat("activityTotal"), ["1 h 30 min", "Time played"])
            compare(stat("activityLast"), ["Today", "Last played"])
            compare(stat("activitySessions"), ["3", "Times played"])
            compare(find("detailActivity").width, find("detailColumn").width)
            compare(find("detailActivity").height, 176 * page().u)
            compare(find("activityBars").highlightIndex, 29)
            compare(find("activityBars").values.length, 30)
            verify(!find("activityMessage").visible)
            // the heading sits 64 under the header (396), where the design puts it
            compare(Math.round(find("detailActivitySection").y / page().u), 460)
        }

        function test_an_app_says_used_and_opened() {
            seedRuns()
            start()
            Store.install("org.example.Player")
            tryVerify(() => Store.app("org.example.Player").installed === true, 5000)
            tryVerify(() => Store.jobs["org.example.Player"] === undefined, 5000)
            openPage({ id: "flatpak:org.example.Player" })
            tryVerify(() => find("detailActivity").visible, 2000)
            compare(stat("activityTotal"), ["2 h 1 min", "Time used"])
            compare(stat("activityLast"), ["Yesterday", "Last used"])
            compare(stat("activitySessions"), ["2", "Times opened"])
        }

        function test_activity_is_in_turkish() {
            seedRuns()
            DeviceSettings.language = "tr"
            start()
            openPage({ id: tc.puzzle })
            tryVerify(() => find("detailActivity").visible, 2000)
            compare(find("activityHeading").text, "Etkinliğiniz")
            compare(stat("activityTotal")[1], "Oynama süresi")
            compare(stat("activitySessions")[1], "Oynama sayısı")
            keyClick(Qt.Key_Down)
            verify(find("detailActivity").activeFocus)
            compare(hintVerbs(), "accept Tümünü gör|back Geri")
        }

        function test_activity_for_a_game_not_installed_only_with_runs() {
            start()
            openPage({ appId: "org.example.Racer" })
            compare(page().installed, false)
            tryCompare(Usage, "ready", true)
            compare(find("detailActivitySection").visible, false, "not installed, no runs")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            seedRuns()
            Usage.mockTouch("p2")
            openPage({ appId: "org.example.Racer" })
            tryVerify(() => find("detailActivitySection").visible, 3000, "not installed, with runs")
            compare(stat("activitySessions")[0], "1")
        }

        function test_activity_is_not_there_for_steam_or_a_guest() {
            Usage.mockSetData("p2", [mk("steam:730", 0, 600), mk("org.example.Puzzle", 0, 600)], today)
            start()
            tc.shell.openPage("appDetail", { id: "steam:730" })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("fact_source") && find("fact_source").activeFocus, 2000)
            compare(find("detailActivitySection").visible, false, "never for a Steam item")
            tc.shell.closePage()
            tryCompare(tc.shell, "currentPage", "")
            Usage.mockSetData("p3", [mk("org.example.Puzzle", 0, 600)], today)
            Profiles.switchTo("p3", "")                  // Sam, the Guest role
            tryCompare(Profiles, "activeProfile", "p3")
            compare(Profiles.active.role, "guest")
            tc.shell.openPage("appDetail", { id: tc.puzzle })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
            compare(find("detailActivitySection").visible, false, "never for a Guest")
        }

        function test_not_played_is_a_sentence_and_not_a_stop() {
            start()
            openPage({ id: tc.puzzle })
            tryCompare(Usage, "ready", true)
            compare(find("detailActivitySection").visible, true, "installed")
            verify(find("activityMessage").visible)
            compare(find("activityMessage").text, "You have not played this yet. When you do, the time you spend shows up here.")
            verify(!find("detailActivity").visible)
            keyClick(Qt.Key_Down)
            verify(!find("detailActivity").activeFocus, "skipped by Down")
            verify(find("detailPermissions").activeFocus, "went on to This app can")
        }

        function test_loading_before_the_ledger_is_read() {
            Usage.mockRefreshDelayed(1500)
            start()
            openPage({ id: tc.puzzle })
            compare(Usage.ready, false)
            verify(find("activityMessage").visible)
            compare(find("activityMessage").text, "Loading…")
            verify(!find("detailActivity").visible)
            tryCompare(Usage, "ready", true, 5000)
            Usage.mockRefreshDelayed(0)
        }

        function test_accept_opens_the_activity_page_and_back_returns_to_the_block() {
            host.width = 1920
            host.height = 1080
            seedRuns()
            start()
            openPage({ id: tc.puzzle })
            tryVerify(() => find("detailActivity").visible, 2000)
            keyClick(Qt.Key_Down)
            verify(find("detailActivity").activeFocus, "Down from the buttons: the block")
            // the block's bottom edge and ring stay inside the viewport's clip (1080p: the Page frame leaves it ~7 short)
            const block = find("detailActivity")
            const viewport = find("detailViewport")
            tryVerify(() => block.mapToItem(viewport, 0, block.height).y + Theme.focusRingWidth * page().u <= viewport.height + 0.5, 2000,
                      "the focused ring's bottom lies inside detailViewport")
            compare(hintVerbs(), "accept See all|back Back")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "activityGame")
            compare(tc.shell.currentParams.appId, "org.example.Puzzle")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailActivity").activeFocus, 2000, "Back: the focus is on the block again")
            keyClick(Qt.Key_Down)
            verify(find("detailPermissions").activeFocus, "Down: This app can")
            keyClick(Qt.Key_Up)
            verify(find("detailActivity").activeFocus)
            keyClick(Qt.Key_Up)
            verify(find("detailPrimary").activeFocus)
            tryCompare(page(), "offset", 0, 2000, "back on the buttons the column is at 0")
            host.width = 1280
            host.height = 720
        }

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
                // installed, with runs: Your activity focused (RUY-532)
                seedRuns()
                Usage.mockTouch("p2")
                openPage({ id: tc.puzzle })
                tryVerify(() => find("detailActivity").visible, 3000)
                keyClick(Qt.Key_Down)
                tryVerify(() => find("detailActivity").activeFocus, 2000)
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "108-game-page-activity-" + lang + "-" + size[2] + ".png")
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
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "105-game-page-steam-" + lang + "-" + size[2] + ".png")
                tc.shell.closePage()
                // an install that failed
                tc.shell.openPage("appDetail", { appId: "org.example.Broken" })
                tryCompare(tc.shell, "currentPage", "appDetail")
                tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
                tryVerify(() => page() !== null && page().detailsReady, 3000)
                keyClick(Qt.Key_Return)
                tryVerify(() => find("detailError").visible, 5000)
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "107-game-page-error-" + lang + "-" + size[2] + ".png")
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
