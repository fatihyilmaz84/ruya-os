import QtQuick
import QtTest
import RuyaShell

// Games page against the mock library (8 games: 5 Steam, 3 Flatpak; plus 2 apps). Controller keys
// only. Signs in as "Ada" (p2, no PIN).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: launchSpy; target: Library; signalName: "launchRequested" }
    SignalSpy { id: pulseSpy; signalName: "runningChanged" }

    TestCase {
        id: tc
        name: "Games"
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
            else
                tryVerify(() => Library.items.length === 10)
            keyClick(Qt.Key_Up)                          // the section nav
            keyClick(Qt.Key_Right)
            compare(find("sectionNav").currentKey, "games")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "games")
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            launchSpy.clear()
        }

        function test_grid_and_filter() {
            start("")
            const grid = find("gamesGrid")
            tryVerify(() => grid.activeFocus, 2000, "the grid has focus")
            compare(grid.count, 8)
            verify(find("gameCard_steam:620"), "a Steam game is shown")
            verify(!find("gameCard_flatpak:org.example.Player"), "an app is not")
            keyClick(Qt.Key_Up)
            verify(find("gamesFilter").activeFocus, "Up from the first row reaches the filter")
            keyClick(Qt.Key_Right)
            compare(find("gamesFilter").value, "steam")
            tryCompare(grid, "count", 5)
            keyClick(Qt.Key_Right)
            compare(find("gamesFilter").value, "flatpak")
            tryCompare(grid, "count", 3)
            keyClick(Qt.Key_Down)
            verify(grid.activeFocus, "Down returns to the grid")
        }

        function test_launch_request() {
            start("")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
            compare(launchSpy.signalArguments[0][0], "steam:620")
            compare(launchSpy.signalArguments[0][1], "steam://rungameid/620")
        }

        function test_accept_pulses_the_card() {
            start("")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            const card = find("gamesGrid").currentItem
            verify(card)
            const pulse = findChild(card, "pulseAnimation")
            verify(pulse, "the card has a pulse animation")
            pulseSpy.target = pulse
            pulseSpy.clear()
            keyClick(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
            tryVerify(() => pulseSpy.count > 0, 2000, "Accept pulses the game card")
        }

        function test_recent() {
            start("")
            const r = Library.recent
            compare(r.length, 8)
            for (let i = 1; i < r.length; ++i)
                verify(r[i - 1].lastPlayed >= r[i].lastPlayed, "newest first")
            verify(r.every(i => i.lastPlayed > 0))
        }

        function test_empty_state() {
            start("empty")
            verify(find("gamesEmpty").visible)
            tryVerify(() => find("gamesOpenStore").activeFocus, 2000, "the button has focus")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "store")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start("")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/21-games-grid.png")
        }
    }
}
