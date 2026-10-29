import QtQuick
import QtTest
import RuyaShell

// Store page and app detail page against the mock catalogue (12 apps, 9 with controller support).
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

    TestCase {
        id: tc
        name: "StoreUi"
        when: windowShown

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Store.mockReset()
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
            tryVerify(() => find("tiles").activeFocus, 2000, "home shelf takes focus after sign-in")
            jobsSpy.clear()
        }

        function openStore() {
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(find("tiles").currentIndex, 2)
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
                const at = list.model.indexOf(id)
                if (at < 0)
                    continue
                while (!list.activeFocus)
                    keyClick(Qt.Key_Down)
                while (list.currentIndex < at)
                    keyClick(Qt.Key_Right)
                compare(list.model[list.currentIndex], id)
                keyClick(Qt.Key_Return)
                tryCompare(tc.shell, "currentPage", "appDetail")
                tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
                return
            }
            fail("no card for " + id)
        }

        function test_controller_filter() {
            openStore()
            // Hidden by default: the three apps without controller support.
            compare(Store.controllerFilter, "gamepad")
            tryCompare(Store.results, "length", 9)
            compare(find("appCard_org.example.Browser"), null)
            verify(find("appCard_org.example.Racer"))
            // Up from the first row reaches the toolbar, Right the toggle.
            keyClick(Qt.Key_Up)
            verify(find("storeSearch").activeFocus)
            keyClick(Qt.Key_Right)
            verify(find("storeShowAll").activeFocus)
            compare(find("storeShowAll").checked, false)
            keyClick(Qt.Key_Return)
            tryCompare(Store, "controllerFilter", "any")
            tryVerify(() => Store.results.length === 12)
            tryVerify(() => find("appCard_org.example.Browser") !== null, 2000, "Editor shows with all apps")
            keyClick(Qt.Key_Return)
            tryCompare(Store, "controllerFilter", "gamepad")
            tryVerify(() => find("appCard_org.example.Browser") === null)
        }

        function test_rows_follow_the_catalogue() {
            openStore()
            tryVerify(() => find("storeCards_featured").model.length === 4)
            tryVerify(() => find("storeCards_games").model.length === 5)
            tryVerify(() => find("storeCards_installed").model.length === 3)
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
            compare(find("detailPrimary").text, "Open")
            verify(find("detailUninstall").visible)
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
            verify(find("detailPrimary").active, "stays installable")
            verify(!find("detailUninstall").visible)
        }

        function test_high_risk_flagged() {
            openStore()
            openApp("org.example.Stream")
            verify(find("riskFlag_all-devices").visible)
            verify(!find("riskFlag_network").visible)
            verify(!find("riskFlag_audio").visible)
        }

        function test_uninstall_confirm() {
            openStore()
            openApp("org.example.Puzzle")              // installed from the start
            compare(find("detailPrimary").text, "Open")
            keyClick(Qt.Key_Down)
            verify(find("detailUninstall").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("uninstallCancel").activeFocus, 2000, "Cancel is the default")
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
            tryVerify(() => Store.app("org.example.Puzzle").installed === false)
            verify(Store.mockDataDeleted("org.example.Puzzle"))
            tryVerify(() => find("detailPrimary").text === "Install")
            tryVerify(() => find("detailPrimary").activeFocus, 2000, "focus is not lost")
        }

        function test_uninstall_keeps_data_by_default() {
            openStore()
            openApp("org.example.Puzzle")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("uninstallCancel").activeFocus)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
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
            keyClick(Qt.Key_Escape)
            compare(tc.shell.currentPage, "store")
            tryVerify(() => find("storeRows").visible)
            tryVerify(() => find("storeCards_featured").activeFocus, 2000)
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
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "store")
            wait(800)
            openApp("org.example.Racer")
            wait(800)                                  // the page has finished fading in
            keyClick(Qt.Key_Return)
            tryVerify(() => Store.jobs["org.example.Racer"] !== undefined, 2000)
            grabImage(tc.shell).save(shotsDir + "/19-store-installing.png")
        }
    }
}
