import QtQuick
import QtTest
import RuyaShell

// ArtRoles (RUY-873): the one rule that picks a Library item's art role. The function tests cover each role
// missing, empty strings and a null art map; the surface tests give an item that carries only a card (and one
// that carries only a cover, besides the icon) to every surface that draws a Library item's picture: the launch
// splash, the close card, the quick menu, the games grid, the Home Recent row and the screen saver. Properties,
// not pixels. Fixtures: the mock `artroles:<dir>` library (Card Only, Cover Only). Signs in as "Ada" (p2).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    Component {
        id: saverComponent
        ScreenSaver { anchors.fill: parent }
    }

    Component {
        id: appComponent
        Item { property string appId: "" }
    }

    TestCase {
        id: tc
        name: "ArtRoles"
        when: windowShown

        property Shell shell: null
        readonly property string cardOnly: "flatpak:org.example.CardOnly"
        readonly property string coverOnly: "flatpak:org.example.CoverOnly"
        readonly property string cardArt: artFixtures + "/playcard.png"
        readonly property string coverArt: artFixtures + "/playcover.png"

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            Library.resetMockForTests("artroles:" + artFixtures)
            Session.mockReset()
        }

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
            tryVerify(() => Library.items.length === 12)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        // Launches `id` and gives its window to the shell: the app is running and in front.
        function runInFront(id) {
            Library.launch(id)
            tryVerify(() => Session.running.length === 1, 2000, "the mock Session runs it")
            const app = createTemporaryObject(appComponent, host, { appId: Library.sessionAppId(id) })
            tc.shell.addApp(app, "p2")
            tryVerify(() => tc.shell.focusedApp === app, 2000, "the app is in front")
        }

        function artData() {
            return [{ tag: "card only", id: cardOnly, art: cardArt }, { tag: "cover only", id: coverOnly, art: coverArt }]
        }

        // ---- the function ---------------------------------------------------------------------------

        function test_wide_order_and_gaps() {
            compare(ArtRoles.wide({ hero: "h", card: "c", cover: "v", tile: "t" }), "h")
            compare(ArtRoles.wide({ card: "c", cover: "v", tile: "t" }), "c")
            compare(ArtRoles.wide({ cover: "v", tile: "t" }), "v")
            compare(ArtRoles.wide({ tile: "t" }), "t")
            compare(ArtRoles.wide({ icon: "i", logo: "l" }), "", "icon and logo are no roles of this rule")
            compare(ArtRoles.wide({}), "")
        }

        function test_tile_order_and_gaps() {
            compare(ArtRoles.tile({ hero: "h", card: "c", cover: "v", tile: "t" }), "t")
            compare(ArtRoles.tile({ hero: "h", card: "c", cover: "v" }), "c")
            compare(ArtRoles.tile({ hero: "h", cover: "v" }), "v")
            compare(ArtRoles.tile({ hero: "h" }), "h")
            compare(ArtRoles.tile({ icon: "i" }), "")
            compare(ArtRoles.tile({}), "")
        }

        function test_empty_strings_are_absent() {
            compare(ArtRoles.wide({ hero: "", card: "", cover: "v", tile: "t" }), "v", "an empty hero and card are skipped")
            compare(ArtRoles.tile({ tile: "", card: "", cover: "", hero: "h" }), "h")
            compare(ArtRoles.wide({ hero: "", card: "", cover: "", tile: "" }), "")
            compare(ArtRoles.tile({ tile: undefined, card: null, cover: "v" }), "v")
        }

        function test_no_art_map_gives_empty() {
            compare(ArtRoles.wide(null), "")
            compare(ArtRoles.wide(undefined), "")
            compare(ArtRoles.tile(null), "")
            compare(ArtRoles.tile(undefined), "")
        }

        // ---- the surfaces ---------------------------------------------------------------------------

        function test_launch_splash_data() { return artData() }
        function test_launch_splash(data) {
            start()
            Library.launch(data.id)
            const splash = find("launchSplash")
            tryVerify(() => splash.shown, 2000, "the splash comes up")
            compare(splash.picture, data.art)
        }

        function test_close_card_data() { return artData() }
        function test_close_card(data) {
            start()
            runInFront(data.id)
            tc.shell.runOption("recent", data.id, "close")
            const splash = find("launchSplash")
            tryVerify(() => tc.shell.closingScreen, 2000, "the closing screen comes up")
            verify(splash.closing)
            compare(splash.picture, data.art)
        }

        function test_quick_menu_picture_data() { return artData() }
        function test_quick_menu_picture(data) {
            start()
            runInFront(data.id)
            compare(tc.shell.quickMenuApp.picture, data.art)
        }

        function test_running_strip_picture_is_the_tile_role_data() { return artData() }
        function test_running_strip_picture_is_the_tile_role(data) {
            start()
            compare(tc.shell.cardArtOfApp(Library.sessionAppId(data.id)), data.art)
        }

        function test_home_recent_card_data() { return artData() }
        function test_home_recent_card(data) {
            start()
            tryVerify(() => find("recentCard_" + data.id), 2000, "the card is in the Recent row")
            compare(find("recentCard_" + data.id).picture, data.art)
        }

        function test_games_card_data() { return artData() }
        function test_games_card(data) {
            start()
            keyClick(Qt.Key_Up)                          // the section nav
            keyClick(Qt.Key_Right)
            compare(find("sectionNav").currentKey, "games")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "games")
            tryVerify(() => find("gameCard_" + data.id), 2000, "the card is in the grid")
            compare(find("gameCard_" + data.id).picture, data.art)
        }

        function test_screen_saver_keeps_items_with_card_or_cover_art() {
            tryVerify(() => Library.items.length === 12)
            const saver = createTemporaryObject(saverComponent, host, { width: 1280, height: 720 })
            verify(saver)
            // Nothing else of this library has a hero or a tile: the pool is these two, not every app.
            compare(saver.pool.map(i => i.id).sort(), [cardOnly, coverOnly])
            const shown = [findChild(saver, "saverLayer0").picture, findChild(saver, "saverLayer1").picture].sort()
            compare(shown, [cardArt, coverArt].sort())
        }
    }
}
