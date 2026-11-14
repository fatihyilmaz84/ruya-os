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
    SignalSpy { id: sessionSpy; target: Session; signalName: "launchFinished" }

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
            sessionSpy.clear()
            Session.mockReset()
            // Toasts of earlier tests would fill the three places and queue the new ones.
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function test_grid_and_filter() {
            start("")
            const grid = find("gamesGrid")
            tryVerify(() => grid.activeFocus, 2000, "the grid has focus")
            compare(grid.count, 8)
            tryVerify(() => find("gameCard_steam:620"), 2000, "a Steam game is shown")
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

        function hintVerbs(buttons) {
            return buttons.map(b => findChild(find("hintBar"), "hint_" + b)).map((h, i) => h ? buttons[i] + " " + h.verb : "").join("|")
        }

        // RUY-542: on the filter row A steps the choice, so the bar says Next, not Select.
        function test_filter_row_hints_say_what_a_does() {
            start("")
            const grid = find("gamesGrid")
            tryVerify(() => grid.activeFocus, 2000)
            const verbs = () => hintVerbs(["A", "Left/Right"])
            compare(verbs(), "A Select|", "on the grid A selects")
            keyClick(Qt.Key_Up)
            verify(find("gamesFilter").activeFocus)
            tryCompare(findChild(find("hintBar"), "hint_A"), "verb", "Next")
            compare(verbs(), "A Next|Left/Right Change")
            keyClick(Qt.Key_Down)
            tryCompare(findChild(find("hintBar"), "hint_A"), "verb", "Select")
        }

        function test_launch_request() {
            start("")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
            compare(launchSpy.signalArguments[0][0], "flatpak:org.example.Racer")
            compare(launchSpy.signalArguments[0][1], "flatpak:org.example.Racer")
        }

        // T-386: Play reaches Session1.Launch with the app id and the signed-in profile.
        function test_play_starts_the_game() {
            start("")
            const grid = find("gamesGrid")
            tryVerify(() => grid.activeFocus, 2000)
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(find("gamesFilter").value, "flatpak")
            tryCompare(grid, "count", 3)
            keyClick(Qt.Key_Down)
            verify(grid.activeFocus)
            const shown = Notifications.shownCount
            keyClick(Qt.Key_Return)
            tryCompare(sessionSpy, "count", 1)
            compare(sessionSpy.signalArguments[0][0], "org.example.Racer")
            compare(sessionSpy.signalArguments[0][1], "p2")
            compare(sessionSpy.signalArguments[0][2], "ok")
            tryVerify(() => Session.instanceOf("org.example.Racer", "p2").appId === "org.example.Racer")
            tryVerify(() => find("launchSplash").shown, 2000, "the launch splash is the feedback")
            wait(50)
            compare(Notifications.shownCount, shown, "no toast: not Starting, not an error")
        }

        // Which library items Session1 can start: Flatpak ids, not Steam (T-147).
        function test_session_app_ids() {
            compare(Library.sessionAppId("flatpak:org.example.Racer"), "org.example.Racer")
            compare(Library.sessionAppId("steam:620"), "")
            compare(Library.sessionAppId("nope"), "")
        }

        // A Steam game has no Session1 launch path: Accept opens its details, with no launch and no
        // error toast per press (T-147).
        function test_a_steam_card_opens_details_and_launches_nothing() {
            start("")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            const shown = Notifications.shownCount
            keyClick(Qt.Key_Right)                           // Counter Strike (Turbo Racer is first)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "details")
            wait(50)
            compare(sessionSpy.count, 0)
            compare(launchSpy.count, 0)
            compare(Notifications.shownCount, shown)
            compare(Session.running.length, 0)
        }

        // The service refuses (an id it does not know): the error toast names the game, not the spec.
        function test_refused_launch_shows_an_error_toast() {
            start("")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            const shown = Notifications.shownCount
            tc.shell.launchApp("org.nope.Missing", "Portal 2", "")
            tryCompare(sessionSpy, "count", 1)
            compare(sessionSpy.signalArguments[0][0], "org.nope.Missing")
            compare(sessionSpy.signalArguments[0][1], "p2")
            compare(sessionSpy.signalArguments[0][2], "unknown-app")
            tryCompare(Notifications, "shownCount", shown + 1)
            const toast = Notifications.model.get(Notifications.model.count - 1)
            compare(toast.text, "Portal 2 could not start")
            compare(toast.kind, "error")
            compare(Session.running.length, 0)
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
            compare(find("gamesOpenStore").kind, "action", "RUY-513")
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

        // T-386: Play on a game the service refuses.
        function test_zz_screenshots_launch_failed() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start("")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            tc.shell.launchApp("org.nope.Missing", "Portal 2", "")
            tryCompare(sessionSpy, "count", 1)
            tryVerify(() => Notifications.model.count >= 1, 2000, "the error toast is up")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/21b-games-launch-failed.png")
        }
    }
}
