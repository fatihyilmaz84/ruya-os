import QtQuick
import QtTest
import RuyaShell

// Art-led Home (T-146) against the mock library: the hero follows the Recent row, Play launches,
// the section nav and LB/RB open pages, Back restores focus, the empty library and the
// Performance tier. Controller keys only. Signs in as "Ada" (p2, no PIN).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: launchSpy; target: Library; signalName: "launchRequested" }

    TestCase {
        id: tc
        name: "Home"
        when: windowShown

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }

        function start(scenario) {
            Library.resetMockForTests(scenario)
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
            tryVerify(() => Library.available)
            if (scenario === "empty")
                tryVerify(() => Library.items.length === 0)
            else if (scenario === "unplayed")
                tryVerify(() => find("heroTitle").text === "Block Puzzle")
            else
                tryVerify(() => find("heroTitle").text === "Portal 2")
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            launchSpy.clear()
        }

        function cleanup() {
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.language = "en"
        }

        function test_focus_starts_on_play() {
            start("")
            verify(find("homePlay").activeFocus)
            compare(find("homePlay").Accessible.name, "Play")
            compare(find("heroTitle").text, "Portal 2")
            verify(find("homeDetails").visible)
            compare(find("recentRow").count, 8)
        }

        function test_arrows_move_between_hero_row_and_nav() {
            start("")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("recentRow").activeFocus, 2000, "Down goes to the Recent row")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Up goes back to Play")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("sectionNav").activeFocus, 2000, "Up from the hero goes to the nav")
            compare(find("sectionNav").currentKey, "home")
            verify(find("navPillRing_home").visible, "the white current pill shows its ring outside")
            keyClick(Qt.Key_Up)
            verify(find("sectionNav").activeFocus, "the nav is the top")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Down from the nav goes to Play")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("homeDetails").activeFocus, 2000, "Right goes to Details")
            keyClick(Qt.Key_Right)
            verify(find("homeDetails").activeFocus, "clamped at the last button")
            keyClick(Qt.Key_Left)
            tryVerify(() => find("homePlay").activeFocus)
            keyClick(Qt.Key_Left)
            verify(find("homePlay").activeFocus, "clamped at the first button")
        }

        function test_moving_along_recent_changes_the_hero() {
            start("")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("recentRow").activeFocus)
            compare(find("heroTitle").text, "Portal 2")
            keyClick(Qt.Key_Right)
            tryCompare(find("heroTitle"), "text", "Counter Strike")
            verify(find("recentRow").activeFocus)
            keyClick(Qt.Key_Left)
            tryCompare(find("heroTitle"), "text", "Portal 2")
            keyClick(Qt.Key_Left)
            compare(find("recentRow").currentIndex, 0, "clamped at the first card")
        }

        function test_hero_art_has_no_monogram() {
            start("")
            // Full-screen art without a picture is the gradient alone, no stray letter mid-screen.
            for (const name of ["heroArtA", "heroArtB"])
                verify(!findChild(find(name), "artMonogram").visible, name)
        }

        function test_play_launches_the_hero_item() {
            start("")
            keyClick(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
            compare(launchSpy.signalArguments[0][0], "steam:620")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Right)
            tryCompare(find("heroTitle"), "text", "Counter Strike")
            keyClick(Qt.Key_Return)                     // Accept on a card
            tryCompare(launchSpy, "count", 2)
            compare(launchSpy.signalArguments[1][0], "steam:730")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("homePlay").activeFocus)
            keyClick(Qt.Key_Return)                     // and Play follows the card
            tryCompare(launchSpy, "count", 3)
            compare(launchSpy.signalArguments[2][0], "steam:730")
        }

        function test_rb_opens_games_and_back_restores_play() {
            start("")
            keyClick(Qt.Key_PageDown)
            tryCompare(tc.shell, "currentPage", "games")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homePlay").activeFocus, 2000, "focus is back where it was")
        }

        function test_rb_from_a_card_restores_the_card() {
            start("")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Right)
            tryCompare(find("heroTitle"), "text", "Counter Strike")
            keyClick(Qt.Key_PageDown)
            tryCompare(tc.shell, "currentPage", "games")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("recentRow").activeFocus, 2000, "the Recent row has focus again")
            compare(find("recentRow").currentIndex, 1)
            compare(find("heroTitle").text, "Counter Strike")
        }

        function test_lb_rb_walk_the_sections_from_the_nav() {
            start("")
            keyClick(Qt.Key_PageUp)                     // nothing before Home
            wait(100)
            compare(tc.shell.currentPage, "")
            verify(find("homePlay").activeFocus)
            keyClick(Qt.Key_Up)
            tryVerify(() => find("sectionNav").activeFocus)
            keyClick(Qt.Key_PageDown)
            tryCompare(tc.shell, "currentPage", "games")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("sectionNav").activeFocus, 2000, "the nav is where it was")
            compare(find("sectionNav").currentKey, "games")
            keyClick(Qt.Key_PageDown)
            tryCompare(tc.shell, "currentPage", "media")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("sectionNav").activeFocus, 2000)
            compare(find("sectionNav").currentKey, "media")
            keyClick(Qt.Key_PageUp)
            tryCompare(tc.shell, "currentPage", "games")
        }

        function test_nav_accept_opens_and_home_pill_returns_to_play() {
            start("")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("sectionNav").activeFocus)
            keyClick(Qt.Key_Return)                     // the Home pill
            tryVerify(() => find("homePlay").activeFocus, 2000, "Accept on Home focuses Play")
            compare(tc.shell.currentPage, "")
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(find("sectionNav").currentKey, "store")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "store")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("sectionNav").activeFocus, 2000)
            compare(find("sectionNav").currentKey, "store", "back on the pill that opened it")
        }

        function test_details_is_a_placeholder_page() {
            start("")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("homeDetails").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "details")
            tryVerify(() => find("pagePlaceholder") && find("pagePlaceholder").activeFocus, 2000)
            compare(launchSpy.count, 0)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homeDetails").activeFocus, 2000, "Details has focus again")
        }

        function test_back_on_home_does_nothing() {
            start("")
            keyClick(Qt.Key_Escape)
            wait(100)
            compare(tc.shell.currentPage, "")
            verify(find("homePlay").activeFocus)
            compare(find("systemPanel").open, false)
        }

        function test_overlay_returns_to_the_focused_card() {
            start("")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Right)
            tryCompare(find("heroTitle"), "text", "Counter Strike")
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("recentRow").activeFocus, 2000)
            compare(find("recentRow").currentIndex, 1)
        }

        function test_empty_library() {
            start("empty")
            compare(find("heroTitle").text, "Your library is empty")
            compare(Library.items.length, 0, "the empty state is for nothing installed")
            compare(find("homePlay").Accessible.name, "Open Store")
            verify(!find("homeDetails").visible)
            compare(find("recentRow").count, 0)
            keyClick(Qt.Key_Down)
            wait(100)
            verify(find("homePlay").activeFocus, "nothing below")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "store")
            compare(launchSpy.count, 0)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homePlay").activeFocus, 2000)
        }

        // Installed but never started (every `lastPlayed` is 0): Home shows the installed items,
        // in the Games page order (by title when nothing was played), not "Your library is empty".
        function test_installed_but_unplayed_items_fill_the_row() {
            start("unplayed")
            compare(Library.recent.length, 0, "nothing was played")
            verify(Library.items.length > 8)
            verify(find("homePlay").activeFocus, "focus starts on Play")
            compare(find("heroTitle").text, "Block Puzzle")
            compare(find("homePlay").Accessible.name, "Play")
            verify(find("homeDetails").visible)
            compare(find("heroEyebrow").text, "INSTALLED")
            compare(find("recentRow").count, 8, "the first eight installed items")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("recentRow").activeFocus, 2000, "Down goes to the row")
            compare(find("recentRow").currentIndex, 0, "focus lands on the first card")
            verify(find("recentCard_flatpak:org.example.Puzzle").focused, "the first card is focused")
            keyClick(Qt.Key_Right)
            tryCompare(find("heroTitle"), "text", "Counter Strike")
            keyClick(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
            compare(launchSpy.signalArguments[0][0], "steam:730")
        }

        function test_played_items_still_win_over_the_installed_fallback() {
            start("")
            compare(find("heroEyebrow").text, "CONTINUE PLAYING")
            compare(find("heroTitle").text, "Portal 2", "the played order, not the title order")
        }

        function test_performance_tier_keeps_the_layout() {
            start("")
            const names = ["sectionNav", "heroBlock", "recentRow", "statusGlass"]
            const before = names.map(n => [find(n).x, find(n).y, find(n).width, find(n).height])
            verify(find("glassBlur").visible, "high tier blurs")
            compare(find("glassFill").color, Theme.glassStrong)
            DeviceSettings.effectsQuality = "performance"
            compare(Theme.blurMax, 0)
            verify(!find("glassBlur").visible, "no MultiEffect on the performance tier")
            compare(find("glassFill").color, Theme.glassOpaque, "the top bar is opaque glass")
            const after = names.map(n => [find(n).x, find(n).y, find(n).width, find(n).height])
            compare(after, before)
            verify(find("homePlay").activeFocus)
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start("")
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/01-home.png")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/01-home-recent.png")
        }

        function test_zz_screenshots_nav_focus() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start("")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("sectionNav").activeFocus, 2000, "Up from the hero goes to the nav")
            verify(find("navPillRing_home").visible, "the ring shows outside the filled Home pill")
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/01-home-nav.png")
        }

        function test_zz_screenshots_performance() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start("")
            DeviceSettings.effectsQuality = "performance"
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/01-home-performance.png")
        }

        function test_zz_screenshots_empty() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start("empty")
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/01-home-empty.png")
        }

        function test_zz_screenshots_unplayed() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start("unplayed")
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/01-home-unplayed.png")
        }

        function test_zz_screenshots_turkish() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start("")
            DeviceSettings.language = "tr"
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/01-home-tr.png")
        }
    }
}
