import QtQuick
import QtTest
import RuyaShell

// Page navigation: tiles open pages, Back returns to the same tile, the Guide overlay works
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

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }

        function signInAsAda() {
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("tiles").activeFocus, 2000, "home shelf takes focus after sign-in")
        }

        function openTile(index) {
            for (let i = 0; i < index; ++i)
                keyClick(Qt.Key_Right)
            compare(find("tiles").currentIndex, index)
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

        function test_each_tile_opens_its_page_data() {
            return [
                { tag: "games", index: 0, focusName: "pagePlaceholder" },
                { tag: "media", index: 1, focusName: "pagePlaceholder" },
                { tag: "store", index: 2, focusName: "storeCards_featured" },   // T-111
                { tag: "settings", index: 3, focusName: "categoryList" },   // T-103: real page
                { tag: "power", index: 4, focusName: "powerSuspend" },      // T-107: real page
            ]
        }

        function test_each_tile_opens_its_page(data) {
            openTile(data.index)
            tryCompare(tc.shell, "currentPage", data.tag)
            tryVerify(() => find("page_" + data.tag) !== null, 2000, "page is loaded")
            tryVerify(() => find(data.focusName).activeFocus, 2000, "page focuses its first element")
            tryVerify(() => find("page_" + data.tag).visible)
            tryVerify(() => !find("home").visible, 2000, "home fades away")
        }

        function test_back_restores_tile_focus() {
            openTile(1)
            tryVerify(() => find("pagePlaceholder") && find("pagePlaceholder").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("tiles").activeFocus, 2000, "tiles regain focus")
            compare(find("tiles").currentIndex, 1)
            tryVerify(() => find("home").visible)
            tryVerify(() => !find("pageHost").visible, 2000, "page fades out")
        }

        function test_overlay_over_page() {
            openTile(1)
            tryVerify(() => find("pagePlaceholder") && find("pagePlaceholder").activeFocus)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "overlay opens over the page")
            compare(tc.shell.currentPage, "media")
            keyClick(Qt.Key_Escape)                    // closes the overlay, not the page
            tryVerify(() => find("pagePlaceholder").activeFocus, 2000, "focus returns to the page")
            compare(tc.shell.currentPage, "media")
            compare(find("tiles").activeFocus, false)
        }

        function test_page_is_isolated() {
            openTile(2)
            tryVerify(() => find("storeCards_featured") && find("storeCards_featured").activeFocus)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Down)
            compare(find("tiles").currentIndex, 2)
            compare(find("tiles").activeFocus, false)
            compare(tc.shell.currentPage, "store")
        }

        function test_switch_profile_from_page() {
            openTile(0)
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
            tryVerify(() => find("tiles").activeFocus, 2000, "home shelf takes focus after sign-in")
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
            openTile(3)
            tryVerify(() => find("categoryList").activeFocus)
            for (let i = 0; i < 8; ++i)
                keyClick(Qt.Key_Down)
            compare(find("categoryList").currentIndex, 8)
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
            compare(find("categoryList").currentIndex, 8)
            tryVerify(() => find("aboutQt").activeFocus, 2000, "same row has focus again")
        }

        function test_back_walks_the_stack() {
            openTile(2)
            tryVerify(() => find("storeCards_featured").activeFocus)
            openDetail({})
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "store")
            tryVerify(() => find("storeCards_featured").activeFocus)
            compare(find("tiles").activeFocus, false)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("tiles").activeFocus, 2000, "tiles regain focus")
            compare(find("tiles").currentIndex, 2)
            tryVerify(() => find("pageSlot_detail") === null, 2000, "popped page is destroyed")
        }

        function test_overlay_over_nested_page() {
            openTile(1)
            tryVerify(() => find("pagePlaceholder").activeFocus)
            openDetail({})
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "overlay opens over the nested page")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("detailItem").activeFocus, 2000, "focus returns to the nested page")
            compare(tc.shell.currentPage, "detail")
        }

        function test_params_reach_the_page() {
            openTile(1)
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
            openTile(1)
            tryVerify(() => find("pagePlaceholder").activeFocus)
            openDetail({})
            compare(find("pageHost").children.length, 2)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("pageHost").children.length === 0, 2000, "no page items left")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openTile(1)
            tryVerify(() => find("pagePlaceholder") && find("pagePlaceholder").activeFocus)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/5-page-placeholder.png")
        }
    }
}
