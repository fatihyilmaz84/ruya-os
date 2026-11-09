import QtQuick
import QtTest
import RuyaShell

// Page navigation: the section nav opens pages, Back returns to the same pill, the Guide overlay works
// over pages. Driven with controller keys only (arrows, Return = Accept, Escape = Back,
// HomePage = Guide). Signs in as "Ada" (p2, no PIN).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A detail page registered through Shell.extraPages.
    Component {
        id: detailPage
        Page {
            title: "Detail"
            Rectangle {
                objectName: "detailItem"
                focus: true
                width: 100; height: 100
                color: "transparent"       // token-ok: test fixture
            }
        }
    }

    TestCase {
        id: tc
        name: "Pages"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function signInAsAda() {
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        // Opens a section through the nav (Up from Play, Right to the pill, Accept). Power is
        // not in the nav (it is in the Guide overlay), so its page is opened directly.
        function openSection(key) {
            if (key === "power") {
                tc.shell.openPage("power")
                return
            }
            keyClick(Qt.Key_Up)
            const nav = find("sectionNav")
            tryVerify(() => nav.activeFocus)
            for (let i = 0; i < nav.keys.indexOf(key); ++i)
                keyClick(Qt.Key_Right)
            compare(nav.currentKey, key)
            keyClick(Qt.Key_Return)
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            signInAsAda()
        }

        function cleanup() {
            Usage.mockFailNextRefresh("")            // a failure armed by a test that stopped early
            Theme.motionFactor = 1.0                 // short fades set by a test (the focus tests)
        }

        function test_each_section_opens_its_page_data() {
            return [
                { tag: "games", focusName: "gamesGrid" },   // T-113: real page
                { tag: "media", focusName: "pagePlaceholder" },
                { tag: "store", focusName: "storeCards_featured" },   // T-111
                { tag: "settings", focusName: "categoryList" },   // T-103: real page
                { tag: "power", focusName: "powerSuspend" },      // T-107: real page
            ]
        }

        function test_each_section_opens_its_page(data) {
            openSection(data.tag)
            tryCompare(tc.shell, "currentPage", data.tag)
            tryVerify(() => find("page_" + data.tag) !== null, 2000, "page is loaded")
            tryVerify(() => find(data.focusName).activeFocus, 2000, "page focuses its first element")
            tryVerify(() => find("page_" + data.tag).visible)
            tryVerify(() => !find("home").visible, 2000, "home fades away")
        }

        function test_back_restores_nav_focus() {
            openSection("media")
            tryVerify(() => find("pagePlaceholder") && find("pagePlaceholder").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("sectionNav").activeFocus, 2000, "the nav regains focus")
            compare(find("sectionNav").currentKey, "media")
            tryVerify(() => find("home").visible)
            tryVerify(() => !find("pageHost").visible, 2000, "page fades out")
        }

        function test_overlay_over_page() {
            openSection("media")
            tryVerify(() => find("pagePlaceholder") && find("pagePlaceholder").activeFocus)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "overlay opens over the page")
            compare(tc.shell.currentPage, "media")
            keyClick(Qt.Key_Escape)                    // closes the overlay, not the page
            tryVerify(() => find("pagePlaceholder").activeFocus, 2000, "focus returns to the page")
            compare(tc.shell.currentPage, "media")
            compare(find("homePlay").activeFocus, false)
        }

        function test_page_is_isolated() {
            openSection("store")
            tryVerify(() => find("storeCards_featured") && find("storeCards_featured").activeFocus)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Down)
            compare(find("sectionNav").currentKey, "store")
            compare(find("sectionNav").activeFocus, false)
            compare(tc.shell.currentPage, "store")
        }

        function test_switch_profile_from_page() {
            openSection("media")
            tryVerify(() => find("pagePlaceholder") && find("pagePlaceholder").activeFocus)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_Return)                    // "Switch profile"
            tryCompare(Profiles, "activeProfile", "")
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("profileList").activeFocus, 2000, "picker regains focus")
            compare(find("profileList").currentIndex, 1)     // the picker keeps Ada selected
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            compare(tc.shell.currentPage, "")
            tryVerify(() => find("home").visible)
            tryVerify(() => !find("pageHost").visible, 2000, "no page after the next sign-in")
        }

        function openDetail(params) {
            tc.shell.extraPages = ({ detail: detailPage })
            tc.shell.openPage("detail", params)
            tryCompare(tc.shell, "currentPage", "detail")
            tryVerify(() => find("detailItem") && find("detailItem").activeFocus, 2000, "detail takes focus")
        }

        function test_nested_page_keeps_state() {
            openSection("settings")
            tryVerify(() => find("categoryList").activeFocus)
            for (let i = 0; i < 9; ++i)
                keyClick(Qt.Key_Down)
            compare(find("categoryList").currentIndex, 9)
            keyClick(Qt.Key_Right)                      // into the About pane
            tryVerify(() => find("aboutVersion").activeFocus, 2000, "first About row has focus")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("aboutQt").activeFocus)
            const settings = find("page_settings")
            openDetail({})
            compare(settings.enabled, false)
            tryCompare(settings, "visible", false)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            compare(find("page_settings"), settings)
            compare(find("categoryList").currentIndex, 9)
            tryVerify(() => find("aboutQt").activeFocus, 2000, "same row has focus again")
        }

        function test_back_walks_the_stack() {
            failOnWarning(/StorePage\.qml.*TypeError/)   // T-171: the cards read a page that was gone
            openSection("store")
            tryVerify(() => find("storeCards_featured").activeFocus)
            openDetail({})
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "store")
            tryVerify(() => find("storeCards_featured").activeFocus)
            compare(find("homePlay").activeFocus, false)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("sectionNav").activeFocus, 2000, "the nav regains focus")
            compare(find("sectionNav").currentKey, "store")
            tryVerify(() => find("pageSlot_detail") === null, 2000, "popped page is destroyed")
        }

        // T-179: Backspace is Back, like Esc.
        function test_backspace_walks_the_stack() {
            openSection("settings")
            tryVerify(() => find("categoryList").activeFocus)
            for (let i = 0; i < 9; ++i)
                keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Right)                      // into the About pane
            tryVerify(() => find("aboutVersion").activeFocus, 2000, "first About row has focus")
            openDetail({})
            tryVerify(() => find("detailItem").activeFocus, 2000, "detail takes focus")
            keyClick(Qt.Key_Backspace)                  // nested page -> Settings, same pane row
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("aboutVersion").activeFocus, 2000, "the pane row has focus again")
            keyClick(Qt.Key_Backspace)                  // pane -> list
            tryVerify(() => find("categoryList").activeFocus)
            compare(tc.shell.currentPage, "settings")
            keyClick(Qt.Key_Backspace)                  // list -> Home, the nav pill
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("sectionNav").activeFocus, 2000, "the nav regains focus")
            compare(find("sectionNav").currentKey, "settings")
            keyClick(Qt.Key_Backspace)                  // Back on Home does nothing
            compare(tc.shell.currentPage, "")
            verify(find("sectionNav").activeFocus)
        }

        function test_overlay_over_nested_page() {
            openSection("media")
            tryVerify(() => find("pagePlaceholder").activeFocus)
            openDetail({})
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "overlay opens over the nested page")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("detailItem").activeFocus, 2000, "focus returns to the nested page")
            compare(tc.shell.currentPage, "detail")
        }

        function test_params_reach_the_page() {
            openSection("media")
            tryVerify(() => find("pagePlaceholder").activeFocus)
            compare(Object.keys(tc.shell.currentParams).length, 0)
            openDetail({ id: "app.x", n: 7 })
            compare(find("page_detail").params.id, "app.x")
            compare(tc.shell.currentParams.n, 7)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "media")
            compare(Object.keys(tc.shell.currentParams).length, 0)
        }

        function test_sign_out_leaves_no_pages() {
            openSection("media")
            tryVerify(() => find("pagePlaceholder").activeFocus)
            openDetail({})
            compare(find("pageHost").children.length, 2)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("pageHost").children.length === 0, 2000, "no page items left")
        }

        function test_nav_on_each_section_page_data() {
            return [
                { tag: "games", focusName: "gamesGrid" },
                { tag: "media", focusName: "pagePlaceholder" },
                { tag: "store", focusName: "storeCards_featured" },
                { tag: "settings", focusName: "categoryList" },
            ]
        }

        function test_nav_on_each_section_page(data) {
            openSection(data.tag)
            tryCompare(tc.shell, "currentPage", data.tag)
            tryVerify(() => find(data.focusName).activeFocus, 2000)
            const nav = find("sectionNav")
            tryCompare(nav, "opacity", 1)
            verify(nav.visible)
            compare(nav.section, data.tag, "the current pill is the page")
            compare(find("navIcon_settings").filled, data.tag === "settings")
            // Up from the top row goes to the nav, on this page's pill; Down comes back to the
            // item that had focus. (Games and Store have a filter or search row above the content.)
            const win = tc.shell.Window.window
            let last = null
            for (let i = 0; i < 3 && !nav.activeFocus; ++i) {
                last = win.activeFocusItem
                keyClick(Qt.Key_Up)
            }
            tryVerify(() => nav.activeFocus, 2000, "Up reaches the nav")
            compare(nav.currentKey, data.tag)
            keyClick(Qt.Key_Down)
            tryVerify(() => !nav.activeFocus, 2000)
            verify(last !== null)
            tryVerify(() => win.activeFocusItem === last, 2000, "Down returns to the same item")
            compare(tc.shell.currentPage, data.tag)
        }

        function test_nav_down_returns_to_the_same_item() {
            openSection("settings")
            tryVerify(() => find("categoryList").activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            compare(find("categoryList").currentIndex, 2)
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Up)
            compare(find("categoryList").currentIndex, 0)
            verify(find("categoryList").activeFocus, "Up inside the list stays in the page")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("sectionNav").activeFocus)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("categoryList").activeFocus, 2000)
            compare(find("categoryList").currentIndex, 0)
        }

        function test_bumpers_switch_sections_on_a_page() {
            openSection("games")
            tryVerify(() => find("gamesGrid").activeFocus)
            keyClick(Qt.Key_PageDown)
            tryCompare(tc.shell, "currentPage", "media")
            tryVerify(() => find("pagePlaceholder").activeFocus, 2000)
            compare(find("sectionNav").section, "media")
            keyClick(Qt.Key_PageUp)
            tryCompare(tc.shell, "currentPage", "games")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            keyClick(Qt.Key_PageUp)                    // Home
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            // Back from a switched-to page still lands on Home.
            keyClick(Qt.Key_PageDown)
            tryCompare(tc.shell, "currentPage", "games")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
        }

        function test_nav_hidden_on_detail_and_disabled_under_guide() {
            openSection("store")
            tryVerify(() => find("storeCards_featured").activeFocus)
            const nav = find("sectionNav")
            openDetail({})
            tryCompare(nav, "opacity", 0)
            compare(nav.enabled, false)
            keyClick(Qt.Key_Up)
            compare(nav.activeFocus, false)
            keyClick(Qt.Key_PageDown)
            compare(tc.shell.currentPage, "detail")
            keyClick(Qt.Key_Escape)
            tryCompare(nav, "opacity", 1)
            tryVerify(() => find("storeCards_featured").activeFocus, 2000)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000)
            compare(nav.enabled, false)
            keyClick(Qt.Key_Escape)
            tryCompare(nav, "enabled", true)
        }

        // T-356 helpers (top-level functions: a local inside a nested function blinds the member lint).
        function describeFocus(f) {
            let s = ""
            for (let p = f; p; p = p.parent)
                s += (p.objectName || String(p)) + (p.visible ? "" : "[hidden]") + (p.enabled ? "" : "[disabled]") + " < "
            return s || "nothing"
        }
        // The page on top has faded in, the pages below have faded out, and the active focus is a
        // visible, enabled item of the page on top.
        function checkFocusOnTop(what, frames) {
            const top = tc.shell.slots[tc.shell.slots.length - 1]
            tryCompare(top, "opacity", 1)
            tryVerify(() => tc.shell.slots.slice(0, -1).every(s => !s.visible), 2000, what + ": the page below faded out")
            // `frames` drawn frames of grace (a pane hands the focus on from a hidden item in a
            // Qt.callLater of its own: one or two frames, whatever the fades). 0 is a single read: the
            // "replies due" state is in between and must already be right (T-356); the shell's safety
            // net does not stand in for it (focusRepairs is asserted by the callers).
            let problem = focusProblem(top, what)
            for (let i = 0; i < frames && problem !== ""; ++i) {
                waitForRendering(tc.shell)
                problem = focusProblem(top, what)
            }
            compare(problem, "")
        }
        function focusProblem(top, what) {
            const f = tc.shell.Window.window.activeFocusItem
            let inside = false
            for (let p = f; p; p = p.parent)
                inside = inside || p === top.page
            return inside && f.visible && f.enabled ? "" : what + ": " + describeFocus(f)
        }
        // With bad services, also while replies are on their way and once they are in.
        function settleAndCheck(what, bad) {
            checkFocusOnTop(what, 3)
            if (!bad)
                return
            Bluetooth.mockRefreshDelayed(40)
            Network.mockRefreshDelayed(40)
            Library.mockListDelayed(40)
            checkFocusOnTop(what + " (replies due)", 0)
            tryVerify(() => Bluetooth.mockPendingReplies() === 0 && Network.mockPendingReplies() === 0
                      && Library.mockPendingReplies() === 0, 3000)
            checkFocusOnTop(what + " (replies in)", 3)
        }
        function openForFocus(key, extra, bad) {
            const chess = "org.example.Chess"
            const params = { appDetail: { appId: chess }, activityGame: { appId: chess },
                             details: { id: Library.games[0].id } }
            if (bad)
                Usage.mockFailNextRefresh("failed")
            tc.shell.openPage(key, Object.assign({}, params[key] ?? {}, extra))
            tryCompare(tc.shell, "currentPage", key)
        }
        function backTo(key, what) {
            for (let i = 0; i < 2 && tc.shell.currentPage !== key; ++i)
                keyClick(Qt.Key_Escape)                  // a Settings pane hands Back to its list first
            compare(tc.shell.currentPage, key, what + ": Back leaves")
        }

        // T-356: every page owns the focus once it is open and the page below has faded out (a covered
        // page hides its items then), opened from Home and over the app page (whose hidden buttons
        // once pulled the focus out of the page on top), with every Settings pane entered; with
        // healthy services and with failing or late ones. Back leaves each one, and the shell's
        // safety net is never needed.
        function test_every_page_owns_the_focus_data() {
            return [{ tag: "healthy", bad: false }, { tag: "failing or late services", bad: true }]
        }
        function test_every_page_owns_the_focus(data) {
            tryVerify(() => Store.catalogue.length > 0 && Library.games.length > 0)
            // Short but real fades (30 ms instead of 300): about 90 page changes would wait ~35 s for
            // them, and the covered page must still hide itself in a fade for this to test the race.
            Theme.motionFactor = 0.03
            for (const key of Object.keys(tc.shell.builtinPages)) {
                openForFocus(key, {}, data.bad)
                settleAndCheck(key + " from Home", data.bad)
                backTo("", key)
                openForFocus("appDetail", {}, data.bad)
                settleAndCheck("appDetail", data.bad)
                openForFocus(key, {}, data.bad)
                settleAndCheck(key + " over the app page", data.bad)
                backTo("appDetail", key + " over the app page")
                backTo("", "appDetail")
            }
            // Player One is an admin: his list also has Manage profiles ("profiles"), which Ada's has not.
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after the switch")
            for (const category of ["myprofile", "profiles", "network", "bluetooth", "display", "audio", "storage",
                                    "accessibility", "power", "system", "about"]) {
                openForFocus("settings", { category: category }, data.bad)
                tryVerify(() => find("categoryList").activeFocus)
                // SettingsPage opens on its first category when the one asked for is not listed.
                compare(find("page_settings").current.key, category, "the requested category opened")
                keyClick(Qt.Key_Right)                   // into the pane (nothing for a category without one)
                settleAndCheck("settings: " + category, data.bad)
                backTo("", "settings: " + category)
            }
            compare(tc.shell.focusRepairs, 0, "every page kept the focus itself")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openSection("media")
            tryVerify(() => find("pagePlaceholder") && find("pagePlaceholder").activeFocus)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/5-page-placeholder.png")
        }

        function test_zz_screenshots_settings_focus() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openSection("settings")
            tryVerify(() => find("categoryList").activeFocus)
            keyClick(Qt.Key_Up)
            tryVerify(() => find("sectionNav").activeFocus)
            compare(find("sectionNav").currentKey, "settings")
            verify(find("navPillRing_settings").visible)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/5c-settings-nav-focus.png")
        }

        function test_zz_screenshots_settings() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openSection("settings")
            tryVerify(() => find("categoryList").activeFocus)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/5b-settings-nav.png")
        }
    }
}
