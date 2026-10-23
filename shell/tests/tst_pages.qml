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
                { tag: "store", index: 2, focusName: "pagePlaceholder" },
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
            tryVerify(() => find("pagePlaceholder") && find("pagePlaceholder").activeFocus)
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
