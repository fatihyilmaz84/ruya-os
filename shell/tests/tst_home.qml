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

        property Shell shell: null

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
                tryVerify(() => find("heroTitle").text === "Turbo Racer")
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
            compare(find("heroTitle").text, "Turbo Racer")
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
            compare(find("heroTitle").text, "Turbo Racer")
            keyClick(Qt.Key_Right)
            tryCompare(find("heroTitle"), "text", "Counter Strike")
            verify(find("recentRow").activeFocus)
            keyClick(Qt.Key_Left)
            tryCompare(find("heroTitle"), "text", "Turbo Racer")
            keyClick(Qt.Key_Left)
            compare(find("recentRow").currentIndex, 0, "clamped at the first card")
        }

        function test_hero_art_has_no_monogram() {
            start("")
            // Full-screen art without a picture is the gradient alone, no stray letter mid-screen.
            for (const name of ["heroArtA", "heroArtB"])
                verify(!findChild(find(name), "artMonogram").visible, name)
        }

        function test_hero_art_does_not_shimmer() {
            start("")
            for (const name of ["heroArtA", "heroArtB"]) {
                find(name).imageStatus = Image.Loading
                compare(find(name).shimmering, false, name)
            }
        }

        // Play on the hero asks the library to launch it (the splash and the launch itself: tst_appflow).
        function test_play_launches_the_hero_item() {
            start("")
            keyClick(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
            compare(launchSpy.signalArguments[0][0], "flatpak:org.example.Racer")
        }

        // A Steam game has no Session1 launch path: no Play on the hero (Details has the focus), and
        // Accept on its card opens Details instead of launching (T-147).
        function test_a_steam_game_has_no_play() {
            start("")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Right)
            tryCompare(find("heroTitle"), "text", "Counter Strike")
            verify(!find("homePlay").visible, "no Play button")
            keyClick(Qt.Key_Return)                     // Accept on the card
            tryCompare(tc.shell, "currentPage", "details")
            compare(launchSpy.count, 0, "nothing was launched")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("homeDetails").activeFocus, 2000, "Details has the focus")
            keyClick(Qt.Key_Left)
            verify(find("homeDetails").activeFocus, "there is no Play to move to")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Left)
            tryCompare(find("heroTitle"), "text", "Turbo Racer")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play comes back with a game that can start")
        }

        function test_played_items_still_win_over_the_installed_fallback() {
            start("")
            compare(find("heroEyebrow").text, "CONTINUE PLAYING")
            compare(find("heroTitle").text, "Turbo Racer", "the played order, not the title order")
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

        function test_zz_screenshots_balanced() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start("")
            DeviceSettings.effectsQuality = "balanced"
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/01-home-balanced.png")
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
