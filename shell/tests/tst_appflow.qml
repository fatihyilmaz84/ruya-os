import QtQuick
import QtTest
import RuyaShell

// Full-screen apps (T-147): Play -> launch splash -> the app's window gets the focus; Guide opens the
// quick menu over the app; Home leaves the app running behind (a Running pill, Accept resumes);
// Close game stops it; a launch that fails, crashes or hangs; toasts wait while an app is in front.
// The mock Session answers the launch; the app window is a stand-in item the test hands to
// Shell.addApp, as the compositor does on Linux. Controller keys only. Signs in as "Ada" (p2), whose
// newest library item is the Flatpak game Turbo Racer (the mock Steam games have no Session1 path).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A window of an app: records the keys it receives and takes them all, like a game.
    Component {
        id: appComponent
        Item {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            property var keys: []
            Keys.onPressed: event => {
                keys = keys.concat([event.key])
                event.accepted = true
            }
        }
    }

    // A "game" with something to look at behind the quick menu (screenshots).
    Component {
        id: pictureAppComponent
        Rectangle {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            color: "steelblue"
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: parent.height / 3; color: "darkgreen" }
            Rectangle { x: parent.width * 0.55; y: parent.height * 0.2; width: parent.width * 0.2; height: width; radius: width / 2; color: "gold" }
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }
    SignalSpy { id: stoppedSpy; target: Session; signalName: "stopFinished" }
    SignalSpy { id: exitedSpy; target: Session; signalName: "appExited" }

    TestCase {
        id: tc
        name: "AppFlow"
        when: windowShown

        property Shell shell: null
        readonly property string racerCard: "recentCard_flatpak:org.example.Racer"

        function find(name) { return findChild(tc.shell, name) }

        // Down until the Quick Hub's row `key` has the focus (T-448: the rows above it depend on the
        // library, the tiles and the recent games).
        function hubGoTo(key) {
            const list = find("systemActions")
            for (let i = 0; i < 20 && list.model[list.currentIndex] !== key; ++i)
                keyClick(Qt.Key_Down)
            compare(list.model[list.currentIndex], key)
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
            tryVerify(() => Library.available)
            tryVerify(() => Library.items.length === 10)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            compare(find("heroTitle").text, "Turbo Racer")
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            Library.resetMockForTests("")
            Session.mockReset()
            launchedSpy.clear()
            stoppedSpy.clear()
            exitedSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
        }

        // Play on the hero, the answer, and the app's window: the app item is returned focused.
        function playRacer() {
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            compare(launchedSpy.signalArguments[0][2], "ok")
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(appComponent, host)
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")
            return app
        }

        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text)
            return out
        }

        function hintVerbs() {
            const bar = find("hintBar")
            const parts = []
            for (const b of ["A", "B"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        // ---- launch ----------------------------------------------------------------------------

        function test_play_runs_the_splash_until_the_window_then_focus_goes_to_the_app() {
            start()
            keyClick(Qt.Key_Return)                         // Play on Turbo Racer
            const splash = find("launchSplash")
            tryVerify(() => splash.shown, 2000, "the splash comes up at once")
            tryVerify(() => splash.activeFocus, 2000, "it holds the focus")
            compare(find("launchTitle").text, "Turbo Racer")
            tryCompare(launchedSpy, "count", 1)
            compare(launchedSpy.signalArguments[0][0], "org.example.Racer")
            compare(launchedSpy.signalArguments[0][1], "p2")
            compare(launchedSpy.signalArguments[0][2], "ok")
            tryCompare(find("launchStatus"), "text", "Starting…")
            compare(hintVerbs(), "", "nothing to press while it starts")

            // Input to the shell is locked: Down and Accept reach nothing, and no second launch starts.
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            Library.launch("flatpak:org.example.Racer")      // a second Play while one is pending
            wait(60)
            verify(splash.shown && splash.activeFocus)
            verify(!find("recentRow").activeFocus && !find("homePlay").activeFocus)
            compare(launchedSpy.count, 1, "a second Play while a launch is pending is ignored")
            compare(Notifications.model.count, 0, "no Starting toast: the splash is the feedback")

            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the app's first window gets the focus")
            tryCompare(splash, "shown", false)
            verify(tc.shell.appOpen)
            verify(!tc.shell.launching)

            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Return)
            compare(app.keys, [Qt.Key_Left, Qt.Key_Return], "arrows and Accept reach the app")
        }

        function test_guide_opens_the_quick_menu_with_resume_first_and_back_returns() {
            start()
            const app = playRacer()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the quick menu opens over the app")
            verify(!app.activeFocus)
            compare(find("systemActions").currentIndex, 0)
            verify(find("quickMenuItem_resume").focused, "Resume has the focus")
            tryVerify(() => find("quickMenuApp").visible, 2000, "the app part is there")
            compare(find("quickMenuTitle").text, "Turbo Racer")
            compare(find("quickMenuTime").text, "Just started")
            compare(hintVerbs(), "A Select|B Resume")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_X)
            compare(app.keys.length, 0, "no key reached the app")
            keyClick(Qt.Key_Escape)
            tryVerify(() => app.activeFocus, 2000, "Back returns the focus to the app")
            verify(!find("systemPanel").open)
            compare(app.keys.length, 0)

            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused)
            keyClick(Qt.Key_Return)                          // Resume
            tryVerify(() => app.activeFocus && !find("systemPanel").open)
        }

        function test_the_quick_menu_without_an_app_has_no_app_part() {
            start()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            compare(find("systemPanel").hasApp, false)
            tryVerify(() => find("quickMenuSystem").visible)
            verify(!find("quickMenuApp").visible)
            verify(!find("quickMenuItem_resume"))
            verify(!find("quickMenuItem_home"))
            verify(find("quickMenuItem_volume"), "the volume row is there")
            // T-448: the first Recent row has the focus (Switch profile only when there is no recent game).
            verify(find("quickMenuItem_recent:flatpak:org.example.Racer").focused, "the first action has the focus, not the volume row")
            compare(hintVerbs(), "A Start|B Close", "T-448: a Recent row says what A does")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("systemPanel").open)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Back returns to Play")
        }

        function test_the_volume_row_changes_the_volume_with_left_and_right() {
            start()
            Audio.mockReset()
            tryVerify(() => Audio.volume >= 0)
            Audio.setVolume(40)
            tryCompare(Audio, "volume", 40)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            hubGoTo("volume")                                // T-448: the Recent rows come first
            verify(find("quickMenuItem_volume").focused)
            keyClick(Qt.Key_Right)
            tryCompare(Audio, "volume", 45)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            tryCompare(Audio, "volume", 35)
            verify(find("systemPanel").open, "Left/Right never close the menu")
            tryVerify(() => find("volumeOsd").shown, 2000, "the change reached the OSD")
            wait(Theme.focusMs + 200)
            compare(find("volumeOsd").opacity, 0, "but it stays away while the menu has its own volume row")
            keyClick(Qt.Key_Escape)
        }

        // ---- Home and Close ---------------------------------------------------------------------

        function test_home_leaves_the_game_running_with_its_card_focused_and_accept_resumes() {
            start()
            const app = playRacer()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused)
            keyClick(Qt.Key_Down)
            verify(find("quickMenuItem_home").focused)
            keyClick(Qt.Key_Return)                          // Home
            tryVerify(() => !tc.shell.appOpen, 2000)
            tryVerify(() => find("recentRow").activeFocus, 2000, "the focus is on the Recent row")
            const card = find(tc.racerCard)
            verify(card, "the game's card is there")
            verify(card.focused, "and focused")
            verify(card.running, "with its Running pill")
            compare(card.stateText, "Running")
            verify(!app.activeFocus, "the app lost the focus")
            compare(Session.running.length, 1, "it keeps running")
            compare(tc.shell.apps.length, 1)
            verify(tc.shell.appRunning)
            keyClick(Qt.Key_Left)                            // some keys on Home: the update service hears them
            keyClick(Qt.Key_Left)
            compare(Update.mockLastActivityAppRunning(), true, "the update service is told a game runs behind Home")
            compare(app.keys.length, 0, "Home's keys did not reach the app")

            // Accept on the Running card resumes the same window, with no second launch.
            keyClick(Qt.Key_Return)
            tryVerify(() => app.activeFocus, 2000, "Accept on the Running card resumes the app")
            verify(tc.shell.appOpen)
            compare(launchedSpy.count, 1, "no new launch")
            compare(Session.running.length, 1)
        }

        function test_a_window_that_names_its_app_late_resumes_from_its_card() {
            // T-435, ACBR (Electron) on the Dell: the compositor hands the window over before the
            // client sets its app_id. Accept on the Running card launched again ("ACBR is already
            // running") instead of bringing the window back.
            start()
            keyClick(Qt.Key_Return)                          // Play on Turbo Racer
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(appComponent, host, { appId: "" })
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the window without an id ends the splash and takes the focus")
            app.appId = "org.example.Racer"                  // the client names its app now
            tryVerify(() => tc.shell.windowOf("org.example.Racer") !== undefined, 2000, "the record takes the id")
            compare(tc.shell.windowOf("org.example.Racer").item, app)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                          // Home
            tryVerify(() => find("recentRow").activeFocus, 2000)
            const card = find(tc.racerCard)
            verify(card && card.focused && card.running, "the Running card has the focus")
            keyClick(Qt.Key_Return)
            tryVerify(() => app.activeFocus, 2000, "Accept on the Running card resumes the window")
            compare(launchedSpy.count, 1, "no new launch")
            compare(toastTexts().length, 0, "no 'already running' toast")
            // The quick menu over it closes that instance.
            const instance = Session.running[0].instance
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("quickMenuItem_closeGame").focused)
            keyClick(Qt.Key_Return)
            tryCompare(stoppedSpy, "count", 1)
            compare(stoppedSpy.signalArguments[0][0], instance)
        }

        function test_hero_play_says_resume_while_the_game_runs_behind_home() {
            start()
            const app = playRacer()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("recentRow").activeFocus)
            keyClick(Qt.Key_Up)
            tryVerify(() => find("homePlay").activeFocus)
            compare(find("heroBlock").primaryText, "Resume")
            keyClick(Qt.Key_Return)
            tryVerify(() => app.activeFocus, 2000)
        }

        function test_close_game_stops_the_game_and_the_pill_goes_when_it_has_exited() {
            start()
            const app = playRacer()
            const instance = Session.running[0].instance
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("quickMenuItem_closeGame").focused)
            keyClick(Qt.Key_Return)
            tryCompare(stoppedSpy, "count", 1)
            compare(stoppedSpy.signalArguments[0][0], instance)
            compare(stoppedSpy.signalArguments[0][1], "ok")
            tryVerify(() => !tc.shell.appOpen, 2000, "Home is in front")
            tryCompare(exitedSpy, "count", 1)
            compare(exitedSpy.signalArguments[0][3], "quit")
            tryVerify(() => !find(tc.racerCard).running, 2000, "the pill is gone after AppExited")
            compare(Session.running.length, 0)
            compare(Notifications.model.count, 0, "a normal quit is silent")
            tc.shell.removeApp(app)                          // the compositor drops the window
            wait(100)
            verify(find("recentRow").activeFocus, "an app behind Home going away leaves the focus where it was")
            verify(!tc.shell.appOpen)
            verify(!tc.shell.appRunning)
        }

        // ---- the closing screen (T-458) ---------------------------------------------------------

        // Guide, down to Close game, Accept: the game is asked to stop and the closing screen comes up.
        function closeGameFromHub() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("quickMenuItem_closeGame").focused)
            keyClick(Qt.Key_Return)
        }

        function test_close_game_shows_the_closing_screen_until_the_game_has_exited() {
            start()
            const app = playRacer()
            Session.mockStopDelay(700)
            closeGameFromHub()
            const splash = find("launchSplash")
            tryVerify(() => tc.shell.closingScreen, 2000)
            tryCompare(splash, "opacity", 1, 2000)
            verify(splash.closing)
            compare(find("launchStatus").text, "Closing Turbo Racer…")
            compare(find("launchTitle").text, "Turbo Racer")
            verify(splash.activeFocus, "the closing screen holds the focus")
            verify(!find("launchClose").visible, "nothing to press")
            compare(hintVerbs(), "")
            verify(find("launchDots").visible)
            compare(find(tc.racerCard).stateText, "Closing", "the card never says Running while it closes")
            // Back and the other keys cannot leave it; Guide still opens the Hub and Back returns to the screen.
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Down)
            verify(splash.activeFocus && splash.shown, "Back, Accept and Down are taken")
            compare(app.keys.length, 0, "no key reaches the game")
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "Guide opens the Hub over the closing screen")
            keyClick(Qt.Key_Escape)
            tryVerify(() => splash.activeFocus, 2000, "Back from the Hub returns to the closing screen")
            // It ends on AppExited: Home in front, the focus on the game's card.
            tryCompare(exitedSpy, "count", 1)
            tryVerify(() => !tc.shell.closingScreen, 2000)
            tryCompare(splash, "shown", false)
            tryVerify(() => find("recentRow").activeFocus, 2000, "the focus is where Close left it")
            tryVerify(() => find(tc.racerCard).stateText === "", 2000, "no pill after AppExited")
            compare(Session.running.length, 0)
            compare(Notifications.model.count, 0)
        }

        function test_a_slow_exit_brings_home_back_with_a_closing_pill_and_play_only_toasts() {
            start()
            const app = playRacer()
            tc.shell.closeSplashMs = 250
            Session.mockStopDelay(3000)
            closeGameFromHub()
            tryVerify(() => tc.shell.closingScreen, 2000)
            tryVerify(() => !tc.shell.closingScreen, 2000, "Home comes back after the wait")
            tryVerify(() => find("recentRow").activeFocus, 2000)
            const card = find(tc.racerCard)
            verify(card.focused)
            compare(card.stateText, "Closing")
            verify(!card.running, "not Running")
            compare(Session.running.length, 1, "the game is still listed")
            // Accept on the card: only a toast, no resume and no launch.
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().includes("Turbo Racer is still closing."), 2000)
            verify(!app.activeFocus, "the window was not brought back")
            verify(!tc.shell.appOpen)
            compare(launchedSpy.count, 1, "no new launch")
            // The hero's Play does the same.
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
            keyClick(Qt.Key_Up)
            tryVerify(() => find("homePlay").activeFocus)
            compare(find("heroBlock").primaryText, "Closing…")
            verify(find("homePlay").dimmed, "Closing… looks unavailable (dimmed), yet keeps the focus")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().includes("Turbo Racer is still closing."), 2000)
            verify(!tc.shell.appOpen)
            compare(launchedSpy.count, 1)
            // AppExited: the pill becomes nothing.
            tryCompare(exitedSpy, "count", 1, 5000)
            tryVerify(() => find(tc.racerCard).stateText === "", 2000, "no pill after AppExited")
            compare(find("heroBlock").primaryText, "Play")
            verify(!find("homePlay").dimmed, "Play is not dimmed once the game has exited")
        }

        function test_a_game_still_listed_after_the_kill_gets_a_warning_and_is_running_again() {
            start()
            const app = playRacer()
            tc.shell.closeSplashMs = 150
            tc.shell.killCheckMs = 200
            Session.mockStubbornStop(true)
            Session.mockStopDelay(100)
            closeGameFromHub()
            tryCompare(exitedSpy, "count", 1, 3000)
            compare(exitedSpy.signalArguments[0][3], "killed")
            tryVerify(() => toastTexts().includes("Turbo Racer did not close. Restart the console if it keeps running."), 3000)
            compare(Notifications.model.get(0).kind, "warning")
            tryVerify(() => find(tc.racerCard).stateText === "Running", 2000, "it is listed, so the card says Running again")
            verify(!tc.shell.closingScreen)
            verify(app)
        }

        function test_the_closing_screen_has_no_motion_under_reduced_motion() {
            start()
            DeviceSettings.reducedMotion = true
            playRacer()
            Session.mockStopDelay(500)
            closeGameFromHub()
            const splash = find("launchSplash")
            tryVerify(() => tc.shell.closingScreen, 2000)
            tryCompare(splash, "opacity", 1, 2000)
            compare(splash.animating, false, "the dots stand still, nothing slides or scales")
            compare(splash.zoom, 1.04, "the art is at its final scale")
            compare(find("launchStatus").text, "Closing Turbo Racer…")
            tryVerify(() => !tc.shell.closingScreen, 3000)
        }

        function test_switch_to_another_running_app() {
            start()
            const racer = playRacer()
            const puzzle = createTemporaryObject(appComponent, host, { appId: "org.example.Puzzle" })
            tc.shell.addApp(puzzle, "p2")
            tryVerify(() => puzzle.activeFocus, 2000, "the newest window is in front")
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus)
            compare(find("quickMenuTitle").text, "Block Puzzle")
            const item = find("quickMenuItem_to:org.example.Racer")
            verify(item, "the other running app is listed")
            compare(item.label, "Switch to Turbo Racer")
            verify(!find("quickMenuItem_to:org.example.Puzzle"), "the app in front is not")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(item.focused)
            keyClick(Qt.Key_Return)
            tryVerify(() => racer.activeFocus, 2000, "Turbo Racer is in front")
            verify(racer.z > puzzle.z)
            verify(!find("systemPanel").open)
        }

        // ---- failures --------------------------------------------------------------------------

        function test_a_crashing_app_with_no_window_shows_an_error_and_the_focus_goes_back() {
            start()
            tc.shell.launchApp("crashy", "Crashy", "")
            const splash = find("launchSplash")
            tryVerify(() => splash.shown)
            tryCompare(exitedSpy, "count", 1, 3000)
            compare(exitedSpy.signalArguments[0][3], "crashed")
            tryCompare(splash, "shown", false)
            tryCompare(Notifications.model, "count", 1)
            const toast = Notifications.model.get(0)
            compare(toast.text, "Crashy stopped unexpectedly. Try again.")
            compare(toast.kind, "error")
            tryVerify(() => find("homePlay").activeFocus, 2000, "focus is back on Play")
            verify(!tc.shell.appOpen)
        }

        function test_a_crash_after_the_window_comes_back_to_home() {
            start()
            tc.shell.launchApp("crashy", "Crashy", "")
            const app = createTemporaryObject(appComponent, host, { appId: "crashy" })
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000)
            tryCompare(exitedSpy, "count", 1, 3000)
            tryCompare(Notifications.model, "count", 1)
            // The launch is over, so the name is the app's own: the library or the store do not know "crashy".
            compare(Notifications.model.get(0).text, "crashy stopped unexpectedly. Try again.")
            compare(Notifications.model.get(0).kind, "error")
            verify(tc.shell.appOpen, "an error toast over the app does not take it away")
            tc.shell.removeApp(app)                          // the compositor drops the dead window
            tryVerify(() => !tc.shell.appOpen)
            tryVerify(() => find("homePlay").activeFocus, 2000, "focus is back on Home")
        }

        function test_an_app_that_cannot_start_ends_the_splash_with_an_error() {
            start()
            tc.shell.launchApp("nolaunch", "No Launch", "")
            tryVerify(() => find("launchSplash").shown)
            tryCompare(exitedSpy, "count", 1, 3000)
            compare(exitedSpy.signalArguments[0][3], "launch-failed")
            tryCompare(find("launchSplash"), "shown", false)
            tryCompare(Notifications.model, "count", 1)
            compare(Notifications.model.get(0).text, "No Launch could not be started. Try again.")
            tryVerify(() => find("homePlay").activeFocus)
        }

        function test_a_refused_launch_names_the_request_and_caps_the_name() {
            start()
            const title = "A very long game title that goes on and on"
            tc.shell.launchApp("org.nope.Missing", title, "")
            tryVerify(() => find("launchSplash").shown)
            tryCompare(launchedSpy, "count", 1)
            compare(launchedSpy.signalArguments[0][2], "unknown-app")
            tryCompare(find("launchSplash"), "shown", false)
            tryCompare(Notifications.model, "count", 1)
            const toast = Notifications.model.get(0)
            const capped = title.slice(0, 29) + "…"
            compare(toast.text, capped + " could not be started. Try again.")
            compare(toast.kind, "error")
            verify(capped.length <= 30)
            verify(!toast.text.includes("org.nope"), "never the raw spec")
            tryVerify(() => find("homePlay").activeFocus)
            compare(Session.running.length, 0)
        }

        function test_already_running_without_a_window_says_so() {
            start()
            Session.launch("org.example.Racer", "p2")        // running, but no window has come
            tryCompare(launchedSpy, "count", 1)
            keyClick(Qt.Key_Return)                          // Play on Turbo Racer
            tryCompare(launchedSpy, "count", 2)
            compare(launchedSpy.signalArguments[1][2], "already-running")
            tryCompare(find("launchSplash"), "shown", false)
            tryCompare(Notifications.model, "count", 1)
            compare(Notifications.model.get(0).text, "Turbo Racer is already running")
            tryVerify(() => find("homePlay").activeFocus)
        }

        function test_already_running_with_a_window_brings_it_to_the_front() {
            start()
            const app = playRacer()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                          // Home
            tryVerify(() => find("recentRow").activeFocus)
            Library.launch("flatpak:org.example.Racer")      // Play again on the running game
            tryVerify(() => app.activeFocus, 2000)
            compare(launchedSpy.count, 1, "the window is there: nothing is launched again")
        }

        function test_a_launch_that_never_gets_a_window_says_still_starting_and_close_ends_it() {
            start()
            tc.shell.launchStillMs = 150
            keyClick(Qt.Key_Return)
            const splash = find("launchSplash")
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => splash.slow, 3000, "20 s (shortened here) without a window")
            compare(find("launchStatus").text, "Still starting…")
            tryVerify(() => find("launchClose").activeFocus, 2000, "Close has the focus")
            compare(hintVerbs(), "A Close|B Close")
            const instance = Session.running[0].instance
            keyClick(Qt.Key_Return)
            tryCompare(stoppedSpy, "count", 1)
            compare(stoppedSpy.signalArguments[0][0], instance)
            tryCompare(splash, "shown", false)
            tryVerify(() => find("homePlay").activeFocus, 2000, "focus is back on Play")
            tryCompare(Session.running, "length", 0)
            compare(Notifications.model.count, 0, "closing it is not an error")
        }

        // Once "Still starting" shows, Back closes it as well (the hint bar says so).
        function test_back_closes_a_launch_that_is_still_starting() {
            start()
            tc.shell.launchStillMs = 150
            keyClick(Qt.Key_Return)
            const splash = find("launchSplash")
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => splash.slow, 3000)
            keyClick(Qt.Key_Escape)
            tryCompare(stoppedSpy, "count", 1)
            tryCompare(splash, "shown", false)
            tryVerify(() => find("homePlay").activeFocus, 2000, "focus is back on Play")
            compare(Notifications.model.count, 0)
        }

        // ---- Play only where Session1 can start it ------------------------------------------------

        function test_a_game_with_no_launch_path_has_no_play_button() {
            start()
            keyClick(Qt.Key_Down)
            tryVerify(() => find("recentRow").activeFocus)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(find("heroTitle").text, "Portal 2")
            verify(!find("homePlay").visible, "no Play for a Steam game")
            verify(find("homeDetails").visible)
            keyClick(Qt.Key_Up)
            tryVerify(() => find("homeDetails").activeFocus, 2000, "Details takes the focus")
            keyClick(Qt.Key_Left)
            verify(find("homeDetails").activeFocus, "there is no Play to go to")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                          // Accept on the card opens Details
            tryCompare(tc.shell, "currentPage", "details")
            compare(launchedSpy.count, 0, "nothing was launched")
            compare(Notifications.model.count, 0, "and no error toast")
            // And asking the library for it anyway does nothing visible.
            Library.launch("steam:620")
            wait(60)
            compare(launchedSpy.count, 0)
            verify(!tc.shell.launching)
            compare(Notifications.model.count, 0)
        }

        // ---- toasts ------------------------------------------------------------------------------

        function test_toasts_wait_while_an_app_has_the_screen() {
            start()
            Notifications.show("On Home", "info")
            tryCompare(Notifications.model, "count", 1)
            const app = playRacer()
            tryCompare(Notifications.model, "count", 0, 2000, "an info toast on screen goes back to the queue")
            compare(Notifications.pendingCount, 1)
            Notifications.show("Sound moved", "success")
            Notifications.show("Careful", "warning")
            Notifications.show("Broken", "error")
            tryCompare(Notifications.model, "count", 2)
            compare(toastTexts(), ["Careful", "Broken"], "only warnings and errors are drawn")
            compare(Notifications.pendingCount, 2, "On Home and Sound moved wait")

            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused)
            compare(Notifications.pendingCount, 2, "the quick menu over the app keeps them waiting")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                          // Home
            tryVerify(() => !tc.shell.appOpen)
            tryVerify(() => toastTexts().includes("On Home"), 3000, "back in the shell the queue is shown, oldest first")
            verify(app)
        }

        // ---- reduced motion ---------------------------------------------------------------------

        function test_reduced_motion_makes_the_launch_a_cut() {
            start()
            compare(Theme.launchMs, 400)
            DeviceSettings.reducedMotion = true
            compare(Theme.launchMs, 0, "launchMs is 0 under reduced motion")
            keyClick(Qt.Key_Return)
            const splash = find("launchSplash")
            tryVerify(() => splash.shown)
            tryCompare(launchedSpy, "count", 1)
            tryCompare(splash, "opacity", 1, 2000)
            compare(splash.zoom, 1.04, "the art is at its final scale")
            compare(splash.animating, false, "no animation runs during the launch")
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000)
            tryCompare(splash, "opacity", 0, 2000)
            compare(splash.animating, false)
        }

        // ---- screenshots (dev.ps1 shots) ---------------------------------------------------------

        function test_zz_screenshots_splash() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryCompare(find("launchStatus"), "text", "Starting…")
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/appflow-1-launch-splash.png")
            tc.shell.launchState = Object.assign({}, tc.shell.launchState, { slow: true })
            tryVerify(() => find("launchClose").visible)
            find("launchSplash").focusClose()
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/appflow-2-launch-still-starting.png")
        }

        function test_zz_screenshots_quick_menu_over_the_app() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(pictureAppComponent, host)
            tc.shell.addApp(app, "p2")
            const second = createTemporaryObject(pictureAppComponent, host, { appId: "org.example.Puzzle" })
            tc.shell.addApp(second, "p2")
            tc.shell.focusApp(app)
            tryVerify(() => app.activeFocus, 2000)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused, 2000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/appflow-3-quick-menu-over-app.png")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Left)
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/appflow-4-quick-menu-volume-row.png")
        }

        function test_zz_screenshots_quick_menu_without_an_app() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_recent:flatpak:org.example.Racer").focused, 2000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/appflow-5-quick-menu-no-app.png")
        }

        function test_zz_screenshots_home_with_the_running_card() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            const app = playRacer()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("recentRow").activeFocus, 2000)
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/appflow-6-home-running-card.png")
            verify(app)
        }

        function test_zz_screenshots_closing() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            playRacer()
            tc.shell.closeSplashMs = 2500
            Session.mockStopDelay(60000)
            closeGameFromHub()
            tryVerify(() => tc.shell.closingScreen, 2000)
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/appflow-7-closing-screen.png")
            tryVerify(() => !tc.shell.closingScreen, 4000)
            tryVerify(() => find("recentRow").activeFocus, 2000)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/appflow-8-home-closing-pill.png")
        }

        function test_the_splash_animates_with_full_motion() {
            start()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("launchSplash").animating, 2000, "the dots (and the fade) run")
            tryCompare(find("launchSplash"), "opacity", 1, 3000)
            keyClick(Qt.Key_HomePage)                        // Guide still works during a launch
            tryVerify(() => find("systemActions").activeFocus, 2000)
            compare(find("systemPanel").hasApp, false, "no app part before there is a window")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("launchSplash").activeFocus, 2000, "Back returns to the splash")
        }
    }
}
