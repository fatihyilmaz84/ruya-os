import QtQuick
import QtTest
import RuyaShell

// The shell drives Ruya Input's route (RUY-409, 06 §5.1-5.2, Input1.SetRoute): "locked" at the
// picker, "shell" at Home, "app" with the game in front, "overlay" with the Hub over it (with its
// instance also once the Hub froze it, RUY-541, so its pads stay), "app" again with the same pads
// after the Thaw; Home over a frozen game and a Close keep them until the game has exited (RUY-611:
// "overlay" with its instance); Lock, a switch and the exit take them away, a switch going through
// "locked" with no profile. A failed call never blocks the UI and the next change sends the newest route; a
// restarted service (a new owner of the name) gets the current route again. The mock Input
// service checks the arguments by the service's rules and models the virtual pads (mockPads).
// Signs in as "Ada" (p2), controller keys only.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A window of an app that takes every key, like a game.
    Component {
        id: appComponent
        Item {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            Keys.onPressed: event => event.accepted = true
        }
    }

    // A window of a client that names no app id and whose process Session1 has not answered for yet
    // (xwayland-satellite's placeholder window, RUY-1040).
    Component {
        id: pidWindowComponent
        Item {
            objectName: "standInPidWindow"
            property string appId: ""
            property int pid: 0
            Keys.onPressed: event => event.accepted = true
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }
    SignalSpy { id: preparedSpy; target: Input; signalName: "padsPrepared" }

    // What held when Session1 answered the launch (RUY-837): how many PreparePads had ended, whether
    // the mock service had the pads, and when (ms since the epoch).
    property int preparedAtLaunch: -1
    property bool padsAtLaunch: false
    property real launchedAt: 0
    Connections {
        target: Session
        function onLaunchFinished() {
            host.preparedAtLaunch = preparedSpy.count
            host.padsAtLaunch = Input.mockPads()
            host.launchedAt = Date.now()
        }
    }
    SignalSpy { id: testSpy; target: Input; signalName: "testStartFinished" }

    // How many SetRoute calls had been made when the last AppExited arrived (RUY-1238): every call before it
    // was sent while the game still ran (the shell sends one event-loop turn after a change at the earliest).
    property int callsAtExit: -1
    Connections {
        target: Session
        function onAppExited() { host.callsAtExit = Input.mockCalls().length }
    }

    TestCase {
        id: tc
        name: "InputRoute"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.pauseGamesInHub = true
            Library.resetMockForTests("")
            Session.mockReset()
            Input.mockFail(false)
            Input.mockPrepareDelayMs(0)
            launchedSpy.clear()
            preparedSpy.clear()
            host.preparedAtLaunch = -1
            host.padsAtLaunch = false
            host.callsAtExit = -1
        }

        function cleanup() {
            DeviceSettings.pauseGamesInHub = true
            Input.mockFail(false)
            Input.mockPrepareDelayMs(0)
            Session.mockFailThaw(false)
        }

        // What the mock service holds now, as one comparable line.
        function served() {
            return Input.mockServiceRoute() + "|" + Input.mockServiceInstance() + "|" + Input.mockServiceProfile()
        }

        // Waits until the shell asked for and the service holds `route` with this instance, app id and
        // profile, answered "ok".
        function expectRoute(route, instance, appId, profile, why) {
            tryVerify(() => Input.route === route && Input.instance === instance && Input.appId === appId
                      && Input.profile === profile && Input.status === "ok", 2000,
                      why + ": asked " + Input.route + "|" + Input.instance + "|" + Input.appId + "|" + Input.profile
                      + " (" + Input.status + ")")
            compare(served(), route + "|" + instance + "|" + profile, why + ": the service holds it")
        }

        // No call ever carried a profile with the route "locked", nor an instance outside app/overlay.
        function checkCalls() {
            for (const c of Input.mockCalls()) {
                if (c.route === "locked")
                    compare(c.profile, "", "a locked route never carries a profile")
                if (c.route === "shell" || c.route === "locked")
                    compare(c.instance, "", "no instance outside app and overlay")
            }
        }

        function start() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            Input.mockClearCalls()
        }

        // From the picker, the profile at `index` (0 Player One, 1 Ada, 2 Guest; no PIN for 1 and 2).
        function signIn(index, id) {
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has the focus")
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Left)
            for (let i = 0; i < index; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", id)
        }

        function recordOf(instance) {
            return Session.running.find(r => r.instance === instance)
        }

        // Play on the hero, the app running and its window: returns { app, instance }, the app focused.
        function playRacer() {
            tryVerify(() => Library.items.length === 10)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play has the focus")
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            const instance = launchedSpy.signalArguments[0][3]
            verify(instance !== "")
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            const app = createTemporaryObject(appComponent, host)
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")
            return { app: app, instance: instance }
        }

        function openHub() {
            keyClick(Qt.Key_HomePage)                    // Guide
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
        }

        function goTo(key) {
            const menu = find("systemPanel")
            const list = find("systemActions")
            if (key === "switch" && !menu.powerMode) {
                goTo("panel:power")
                keyClick(Qt.Key_Return)
                tryCompare(menu, "powerMode", true)
            }
            for (let i = 0; i < 30 && menu.currentKey !== key; ++i)
                keyClick(menu.itemKeys.indexOf(menu.rowKeyOf(key)) > list.currentIndex ? Qt.Key_Down
                         : menu.itemKeys.indexOf(menu.rowKeyOf(key)) < list.currentIndex ? Qt.Key_Up
                         : menu.columnOf(key) > menu.currentColumn ? Qt.Key_Right : Qt.Key_Left)
            compare(menu.currentKey, key)
            verify(find("quickMenuItem_" + key).focused, key + " has the focus ring")
        }

        function test_the_route_follows_focus_overlay_freeze_lock_and_switch() {
            start()
            expectRoute("locked", "", "", "", "the picker")
            verify(!Input.mockPads(), "no pads at the picker")

            signIn(1, "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Home after sign-in")
            expectRoute("shell", "", "", "p2", "Home")

            // Guide works at Home too (route shell): the Hub over Home is still the shell.
            openHub()
            compare(Input.route, "shell", "the Hub over Home is the shell")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("homePlay").activeFocus, 2000, "back at Home")

            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the game in front")
            verify(Input.mockPads(), "the game has its pads")
            const firstPads = Input.mockPadGeneration()

            // Guide over the game: overlay with the instance, also once the Hub froze it (RUY-541): the
            // service sees the same owner and keeps the game's pads, held in neutral.
            const hubFrom = Input.mockCalls().length
            openHub()
            tryVerify(() => recordOf(run.instance).frozen === true, 2000, "the Hub froze the game")
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "the Hub over the frozen game")
            verify(find("inputRoute").frozen, "the route object knows the game is frozen")
            verify(Input.mockPads(), "a game the Hub froze keeps its pads")
            compare(Input.mockPadGeneration(), firstPads, "the same pads, none made or destroyed")
            const frozenFrom = Input.mockCalls().length
            verify(Input.mockCalls().slice(hubFrom).every(c => c.route !== "overlay"
                                                          || (c.instance === run.instance
                                                              && c.appId === "org.example.Racer")),
                   "every overlay call over the game named it")

            // Resume (B) with a Thaw that fails: the game has the focus but stays frozen, so the
            // route stays overlay with its instance, and it keeps the same pads (held in neutral).
            Session.mockFailThaw(true)
            keyClick(Qt.Key_Escape)
            tryVerify(() => run.app.activeFocus, 2000, "the game has the focus again")
            tryVerify(() => !find("systemPanel").open, 2000, "the Hub is closed")
            tryVerify(() => Session.mockCalls().filter(c => c === "thaw " + run.instance).length === 1, 2000,
                      "the Thaw was sent (and failed)")
            verify(recordOf(run.instance).frozen, "the game is still frozen")
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "a frozen game in front")
            verify(Input.mockCalls().slice(frozenFrom).every(c => c.route !== "app"),
                   "no app route was sent while the game was frozen")
            verify(Input.mockPads(), "a frozen game in front keeps its pads")
            compare(Input.mockPadGeneration(), firstPads, "no pad was made again for the frozen game")
            Session.mockFailThaw(false)

            // The Hub again, then Resume: the Thaw works, then "app" with the same pads.
            openHub()
            keyClick(Qt.Key_Escape)
            tryVerify(() => run.app.activeFocus, 2000, "the game has the focus again")
            tryVerify(() => recordOf(run.instance).frozen === false, 2000, "the game runs again")
            expectRoute("app", run.instance, "org.example.Racer", "p2", "back in the game")
            verify(Input.mockPads(), "the game has its pads")
            compare(Input.mockPadGeneration(), firstPads, "the same pads after the Thaw, not new ones")

            // Home from the Hub: the game stays frozen behind Home and keeps its pads (RUY-611: before,
            // Home destroyed them, and a game thawed later by Close read "Gamepad removed" and saved
            // it): the route is "overlay" with the game's instance, held in neutral.
            openHub()
            goTo("home")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("recentRow").activeFocus, 2000, "Home, the focus on the game's card")
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "Home with the frozen game behind it")
            verify(Input.mockPads(), "the frozen game keeps its pads at Home")
            compare(Input.mockPadGeneration(), firstPads, "the same pads at Home")
            keyClick(Qt.Key_Return)                      // the Running card resumes it
            tryVerify(() => run.app.activeFocus, 2000, "the game is in front again")
            tryVerify(() => recordOf(run.instance).frozen === false, 2000, "the game runs again")
            expectRoute("app", run.instance, "org.example.Racer", "p2", "resumed from its card")
            compare(Input.mockPadGeneration(), firstPads, "the same pads after the resume, not new ones")

            // Switch profile (Lock, then another profile): locked with no profile, then the new one.
            openHub()
            goTo("switch")
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker after Switch profile")
            expectRoute("locked", "", "", "", "the picker after Switch profile")
            verify(!Input.mockPads(), "Lock destroys the pads")

            signIn(2, "p3")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Guest's Home")
            verify(!run.app.visible, "Ada's game is hidden from Guest")
            expectRoute("shell", "", "", "p3", "Guest at Home, Ada's game hidden")
            verify(!Input.mockPads(), "Guest has no pads of Ada's game")

            // Lock from Guest, then Ada again: her game comes back to the front.
            Profiles.lock()
            expectRoute("locked", "", "", "", "locked again")
            signIn(1, "p2")
            tryVerify(() => run.app.activeFocus, 2000, "Ada's game is in front again")
            tryVerify(() => recordOf(run.instance).frozen === false, 2000, "and runs")
            expectRoute("app", run.instance, "org.example.Racer", "p2", "Ada's game after sign-in")

            checkCalls()
            verify(Input.mockCalls().every(c => c.route !== "app" || c.profile === "p2"),
                   "only Ada's game was ever routed")
        }

        // RUY-837: Play asks Input for the player's pads first and starts the game only once they are
        // ready, so a game that opens its pad once at start-up (Neverball) finds it; the game's window
        // then takes those pads, none are made again. Ada signs in and presses Play with Input
        // answering after `delay` ms (-1: never); returns the time Play was pressed.
        function pressPlayWithInputAnsweringAfter(delay) {
            start()
            signIn(1, "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Home after sign-in")
            expectRoute("shell", "", "", "p2", "Home")
            tryVerify(() => Library.items.length === 10)
            Input.mockPrepareDelayMs(delay)
            const pressed = Date.now()
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1, 3000, "the game is launched")
            const calls = Input.mockPrepareCalls()
            compare(calls.length, 1, "one PreparePads")
            compare(calls[0].appId, launchedSpy.signalArguments[0][0], "for the game launched")
            compare(calls[0].profile, "p2")
            compare(calls[0].route, "shell", "asked while the shell is in front")
            verify(host.padsAtLaunch, "the pads existed when the game was launched")
            return pressed
        }

        function test_play_starts_the_game_once_its_pads_are_ready() {
            pressPlayWithInputAnsweringAfter(300)
            compare(host.preparedAtLaunch, 1, "Input had answered before the launch")
            compare(preparedSpy.signalArguments[0][2], "ok")
            const generation = Input.mockPadGeneration()
            compare(Input.mockServiceRoute(), "shell", "preparing changes no route")
            const instance = launchedSpy.signalArguments[0][3]
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")
            expectRoute("app", instance, "org.example.Racer", "p2", "the game in front")
            compare(Input.mockPadGeneration(), generation, "the window takes the prepared pads")
            compare(Input.mockPreparedAppId(), "", "no preparation waits any more")
        }

        function test_play_starts_the_game_after_1_s_when_input_does_not_answer() {
            ignoreWarning(/PreparePads org\.example\.Racer did not answer in 1000 ms; the app starts anyway/)
            const pressed = pressPlayWithInputAnsweringAfter(-1)
            compare(host.preparedAtLaunch, 1, "the bound ended the wait")
            compare(preparedSpy.signalArguments[0][2], "timeout")
            verify(host.launchedAt - pressed >= 950, "waited about 1 s: " + (host.launchedAt - pressed))
        }

        function test_a_late_answer_starts_nothing_twice() {
            ignoreWarning(/PreparePads org\.example\.Racer did not answer in 1000 ms/)
            pressPlayWithInputAnsweringAfter(1500)
            compare(preparedSpy.signalArguments[0][2], "timeout", "launched at the bound")
            wait(800)                                   // the answer at 1.5 s comes and goes
            compare(preparedSpy.count, 1, "the late answer is dropped")
            compare(launchedSpy.count, 1, "and launches nothing")
        }

        // With the Hub's pause off the game is not frozen: the overlay keeps its pads (held in neutral)
        // and closing the Hub gives the same pads back.
        function test_without_the_pause_the_overlay_keeps_the_pads() {
            DeviceSettings.pauseGamesInHub = false
            start()
            signIn(1, "p2")
            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the game in front")
            const pads = Input.mockPadGeneration()
            openHub()
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "the Hub over the running game")
            verify(Input.mockPads(), "the pads stay, held in neutral")
            keyClick(Qt.Key_HomePage)                    // Guide closes it
            tryVerify(() => run.app.activeFocus, 2000, "the game has the focus again")
            expectRoute("app", run.instance, "org.example.Racer", "p2", "back in the game")
            compare(Input.mockPadGeneration(), pads, "the same pads, not new ones")
            checkCalls()
        }

        // RUY-611: a game saves its controller choice on quit (LibreQuake: "Gamepad removed" ->
        // joy_device -1), so its pads stay until its instance has exited when it is closed from the Hub:
        // the route stays "overlay" with the instance while the exit is held (mockStopDelay), then
        // "shell". Today's code sent "shell" at once (Home) and the pads died before the game quit.
        function test_close_from_the_hub_keeps_the_pads_until_the_game_has_exited() {
            start()
            signIn(1, "p2")
            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the game in front")
            const pads = Input.mockPadGeneration()
            Session.mockStopDelay(3000)
            openHub()
            tryVerify(() => recordOf(run.instance).frozen === true, 2000, "the Hub froze the game")
            const from = Input.mockCalls().length
            goTo("closeGame")
            keyClick(Qt.Key_Return)
            tryVerify(() => Session.mockCalls().some(c => c === "stop " + run.instance), 2000, "Stop was asked")
            tryVerify(() => tc.shell.closingScreen && !tc.shell.appOpen, 2000, "Home with the closing screen")
            tryCompare(find("launchSplash"), "opacity", 1, 2000)
            verify(recordOf(run.instance) !== undefined, "the game has not exited yet")
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "closing, the exit still to come")
            verify(Input.mockPads(), "the pads stay while the game exits")
            compare(Input.mockPadGeneration(), pads, "the same pads, none made or destroyed")
            verify(Input.mockCalls().slice(from).every(c => c.route === "overlay" && c.instance === run.instance),
                   "no shell or locked route was sent before the game exited")
            // The exit: the route goes to the shell and the pads with it.
            tryVerify(() => recordOf(run.instance) === undefined, 6000, "the game quit")
            expectRoute("shell", "", "", "p2", "the game has exited")
            verify(!Input.mockPads(), "the pads go once the game has exited")
            checkCalls()
        }

        // The Options menu's Close game on the game's card at Home: the game is frozen behind Home, so
        // its pads were kept at Home (RUY-611) and Close's thaw does not take them either.
        function test_close_from_the_options_menu_keeps_the_pads_until_the_game_has_exited() {
            start()
            signIn(1, "p2")
            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the game in front")
            const pads = Input.mockPadGeneration()
            Session.mockStopDelay(3000)
            openHub()
            tryVerify(() => recordOf(run.instance).frozen === true, 2000, "the Hub froze the game")
            goTo("home")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("recentRow").activeFocus, 2000, "Home, the focus on the game's card")
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "Home with the frozen game behind it")
            verify(recordOf(run.instance).frozen, "the game is frozen behind Home")
            verify(Input.mockPads(), "the frozen game has its pads at Home")
            compare(Input.mockPadGeneration(), pads, "the same pads at Home")
            const from = Input.mockCalls().length
            keyClick(Qt.Key_Menu)                        // Options: Resume, Close game
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => Session.mockCalls().some(c => c === "stop " + run.instance), 2000, "Stop was asked")
            tryVerify(() => recordOf(run.instance).frozen === false, 2000, "Close thawed it")
            tryVerify(() => tc.shell.closingScreen, 2000, "the closing screen is up")
            tryCompare(find("launchSplash"), "opacity", 1, 2000)
            verify(recordOf(run.instance) !== undefined, "the game has not exited yet")
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "the thawed game still closing")
            verify(Input.mockPads(), "the pads stay while the game exits")
            compare(Input.mockPadGeneration(), pads, "the same pads, none made or destroyed")
            verify(Input.mockCalls().slice(from).every(c => c.route === "overlay" && c.instance === run.instance),
                   "no shell or locked route was sent before the game exited")
            tryVerify(() => recordOf(run.instance) === undefined, 6000, "the game quit")
            expectRoute("shell", "", "", "p2", "the game has exited")
            verify(!Input.mockPads(), "the pads go once the game has exited")
            checkCalls()
        }

        // The old rules stay: Lock over a frozen game behind Home destroys its pads (a pad never outlives
        // its profile).
        function test_lock_still_destroys_the_pads_of_a_game_held_behind_home() {
            start()
            signIn(1, "p2")
            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the game in front")
            openHub()
            tryVerify(() => recordOf(run.instance).frozen === true, 2000, "the Hub froze the game")
            goTo("home")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("recentRow").activeFocus, 2000, "Home, the focus on the game's card")
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "Home with the frozen game behind it")
            verify(Input.mockPads(), "the frozen game has its pads at Home")
            Profiles.lock()
            expectRoute("locked", "", "", "", "locked with the game behind")
            verify(!Input.mockPads(), "Lock destroys the pads of the frozen game")
            checkCalls()
        }

        // A game that is not frozen behind Home (the Hub's pause is off) has no pads to keep: Home destroys
        // them as before, and closing it makes none.
        function test_a_game_that_is_not_frozen_behind_home_loses_its_pads_as_before() {
            DeviceSettings.pauseGamesInHub = false
            start()
            signIn(1, "p2")
            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the game in front")
            openHub()
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "the Hub over the running game")
            goTo("home")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("recentRow").activeFocus, 2000, "Home, the focus on the game's card")
            verify(!recordOf(run.instance).frozen, "the game runs behind Home")
            expectRoute("shell", "", "", "p2", "Home with a running game behind it")
            verify(!Input.mockPads(), "no pads for a game that is not frozen")
            const from = Input.mockCalls().length
            Session.mockStopDelay(300)
            keyClick(Qt.Key_Menu)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => Session.mockCalls().some(c => c === "stop " + run.instance), 2000, "Stop was asked")
            tryVerify(() => recordOf(run.instance) === undefined, 6000, "the game quit")
            expectRoute("shell", "", "", "p2", "the game has exited")
            verify(!Input.mockPads(), "closing a game with no pads made none")
            verify(Input.mockCalls().slice(from).every(c => c.route === "shell"), "no overlay was sent for it")
            checkCalls()
        }

        // RUY-1238: one stop hold for every kind of stop. The Hub freezes the game in front, Home goes in front
        // of it: the route is "overlay" with its instance (RUY-611's Home hold).
        function freezeBehindHome(run) {
            openHub()
            tryVerify(() => recordOf(run.instance).frozen === true, 2000, "the Hub froze the game")
            goTo("home")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("recentRow").activeFocus, 2000, "Home, the focus on the game's card")
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "Home with the frozen game behind it")
        }

        // The route the shell works out now (synchronous, unlike what Input was last asked) holds the game's pads.
        function holdsNow(instance, why) {
            const r = find("inputRoute")
            compare(r.route + "|" + r.routeInstance + "|" + r.routeAppId, "overlay|" + instance + "|org.example.Racer", why)
        }

        // Once the game has exited: every call from `from` (an index into Input.mockCalls()) until its AppExited
        // held its pads, "overlay" with its instance (a shell, locked or app call sent while it quit would be here).
        function onlyHeldUntilExit(from, instance, why) {
            tryVerify(() => host.callsAtExit >= from, 2000, "AppExited arrived")
            const calls = Input.mockCalls().slice(from, host.callsAtExit)
            verify(calls.every(c => c.route === "overlay" && c.instance === instance && c.appId === "org.example.Racer"),
                   why + ": " + JSON.stringify(calls.map(c => c.route + "|" + c.instance)))
        }

        // The system goes down with a game frozen behind Home (ruya-session's StopAll, replayed in its order:
        // AppStopping, the thaw, AppExited later): nobody in the shell asked for the stop, and the game,
        // thawed so it can quit, still finds its pads until it has exited (LibreQuake saved "no controller"
        // at a reboot when Home's hold ended at the thaw). Then "shell", and the pads go.
        function test_the_system_going_down_keeps_the_pads_of_a_game_frozen_behind_home() {
            start()
            signIn(1, "p2")
            const run = playRacer()
            const pads = Input.mockPadGeneration()
            freezeBehindHome(run)
            Session.mockStopDelay(1500)
            const from = Input.mockCalls().length
            Session.mockStopAll()
            tryVerify(() => recordOf(run.instance).state === "stopping", 2000, "AppStopping: the game is stopping")
            holdsNow(run.instance, "stopping: the route still holds the game")
            tryVerify(() => recordOf(run.instance).frozen === false, 2000, "the stop thawed it")
            holdsNow(run.instance, "stopping and thawed, the exit still to come")
            tryVerify(() => recordOf(run.instance) === undefined, 5000, "the game quit")
            onlyHeldUntilExit(from, run.instance, "no shell or locked route before the exit")
            compare(Input.mockPadGeneration(), pads, "the same pads until the exit, none made or destroyed")
            expectRoute("shell", "", "", "p2", "the game has exited")
            verify(!Input.mockPads(), "the pads go once the game has exited")
            checkCalls()
        }

        // The same with the game in front and not frozen: the shell no longer names a stopping app's window
        // instance (`runningFor`), and the hold keeps the pads with that window in front ("overlay": the game
        // quits, it is not played any more).
        function test_the_system_going_down_keeps_the_pads_of_the_game_in_front() {
            start()
            signIn(1, "p2")
            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the game in front")
            const pads = Input.mockPadGeneration()
            Session.mockStopDelay(1500)
            const from = Input.mockCalls().length
            Session.mockStopAll()
            tryVerify(() => recordOf(run.instance).state === "stopping", 2000, "AppStopping: the game is stopping")
            verify(run.app.activeFocus, "its window is still in front")
            holdsNow(run.instance, "the stopping game in front")
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "the stopping game in front")
            compare(Input.mockPadGeneration(), pads, "the same pads, none made or destroyed")
            tryVerify(() => recordOf(run.instance) === undefined, 5000, "the game quit")
            onlyHeldUntilExit(from, run.instance, "no app, shell or locked route between the stop and the exit")
            expectRoute("shell", "", "", "p2", "the game has exited, its window not yet gone")
            verify(!Input.mockPads(), "the pads go once the game has exited")
            checkCalls()
        }

        // The race of a ListRunning reply computed before the stop that arrives after AppStopping (RUY-1235's
        // review): it says "running" again until the next refresh. The hold was taken on the signal, so the
        // reply does not drop it: still "overlay" with the instance, never "app" or "shell", until the exit.
        function test_a_listing_from_before_the_stop_does_not_drop_the_hold() {
            start()
            signIn(1, "p2")
            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the game in front")
            Session.mockStopDelay(1500)
            const from = Input.mockCalls().length
            Session.mockListRunningLate(300)             // computed now: the game "running"
            Session.mockStopAll()
            tryVerify(() => recordOf(run.instance).state === "stopping", 2000, "AppStopping: the game is stopping")
            tryVerify(() => recordOf(run.instance).state === "running", 2000, "the late reply says running again")
            holdsNow(run.instance, "the hold outlives the stale reply")
            tryVerify(() => recordOf(run.instance) === undefined, 5000, "the game quit")
            onlyHeldUntilExit(from, run.instance, "no app, shell or locked route between the stop and the exit")
            expectRoute("shell", "", "", "p2", "the game has exited")
            checkCalls()
        }

        // Lock destroys the pads of a stopping game too (06 section 5.2: the stop hold ends at a sign-out), and the
        // same profile signing in again BEFORE the game has exited does not bring the hold back: the game is
        // still listed as stopping and still the profile's, so a hold that outlived the Lock would take the pads
        // again on the sign-in. The route stays "shell" with no pads until (and after) the exit.
        function test_a_lock_during_a_stop_ends_the_hold_and_a_sign_in_before_the_exit_does_not_bring_it_back() {
            start()
            signIn(1, "p2")
            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the game in front")
            Session.mockStopDelay(3000)
            Session.mockStopAll()
            tryVerify(() => recordOf(run.instance).state === "stopping", 2000, "AppStopping: the game is stopping")
            tryCompare(tc.shell, "stopPadHold", run.instance, 2000, "the stop hold is taken")
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "the stopping game in front")
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            compare(tc.shell.stopPadHold, "", "the sign-out ended the hold")
            expectRoute("locked", "", "", "", "locked with the game stopping")
            verify(!Input.mockPads(), "Lock destroys the pads of the stopping game")
            signIn(1, "p2")
            verify(recordOf(run.instance) !== undefined && recordOf(run.instance).state === "stopping",
                   "the game has not exited yet")
            const from = Input.mockCalls().length
            compare(tc.shell.stopPadHold, "", "the sign-in does not bring the hold back")
            expectRoute("shell", "", "", "p2", "signed in again, the game still stopping")
            verify(!Input.mockPads(), "no pads for the stopping game after the sign-in")
            tryVerify(() => recordOf(run.instance) === undefined, 6000, "the game quit")
            expectRoute("shell", "", "", "p2", "the game has exited")
            verify(!Input.mockPads(), "still no pads")
            verify(Input.mockCalls().slice(from).every(c => c.route === "shell"), "no overlay was sent after the sign-in")
            checkCalls()
        }

        // A refused Stop ends the hold: nothing is stopping, so a game that is not frozen behind Home (the
        // Hub's pause off) loses its pads at Home as before.
        function test_a_refused_stop_releases_the_hold() {
            DeviceSettings.pauseGamesInHub = false
            start()
            signIn(1, "p2")
            const run = playRacer()
            openHub()
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "the Hub over the running game")
            Session.mockStopAnswer("failed")
            goTo("closeGame")
            keyClick(Qt.Key_Return)
            tryVerify(() => !tc.shell.closingScreen && tc.shell.stopPadHold === "", 2000, "the refused Stop ended the close and the hold")
            verify(recordOf(run.instance) !== undefined && recordOf(run.instance).state === "running", "the game still runs")
            expectRoute("shell", "", "", "p2", "Home, the game not frozen and not stopping")
            verify(!Input.mockPads(), "no pads are held for it")
            Session.mockStopAnswer("")
            checkCalls()
        }

        // The kill check giving up (a Stop reported "killed" with the game still listed, T-458) ends the hold
        // too: the hold went with that AppExited, and the warning comes with the route at the shell.
        function test_the_kill_check_giving_up_releases_the_hold() {
            DeviceSettings.pauseGamesInHub = false
            start()
            signIn(1, "p2")
            const run = playRacer()
            openHub()
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "the Hub over the running game")
            tc.shell.killCheckMs = 200
            Session.mockStopDelay(300)
            Session.mockStubbornStop(true)
            goTo("closeGame")
            keyClick(Qt.Key_Return)
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "closing: the stop hold")
            tryVerify(() => !tc.shell.closingInstances.includes(run.instance), 3000, "the kill check gave up")
            verify(recordOf(run.instance) !== undefined, "the game is still listed")
            compare(tc.shell.stopPadHold, "", "no hold is left")
            expectRoute("shell", "", "", "p2", "Home, the hold released")
            verify(!Input.mockPads(), "no pads are held for it")
            Session.mockStubbornStop(false)
            checkCalls()
        }

        // The Controllers pages' button test runs at Home although a frozen game's pads are held there
        // (the route is "overlay", RUY-611), and the game's pads stay while it runs.
        function test_the_button_test_runs_while_a_frozen_game_is_held_behind_home() {
            start()
            signIn(1, "p2")
            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the game in front")
            const pads = Input.mockPadGeneration()
            openHub()
            tryVerify(() => recordOf(run.instance).frozen === true, 2000, "the Hub froze the game")
            goTo("home")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("recentRow").activeFocus, 2000, "Home, the focus on the game's card")
            expectRoute("overlay", run.instance, "org.example.Racer", "p2", "Home with the frozen game behind it")
            verify(Input.mockPads(), "the frozen game has its pads at Home")
            Input.mockAddDevice({ id: "pad-under-test", name: "Pad under test" })
            testSpy.clear()
            Input.startTest("pad-under-test", false)
            tryCompare(testSpy, "count", 1)
            compare(testSpy.signalArguments[0][1], "ok", "StartTest is allowed under the held overlay")
            verify(Input.mockPads(), "the held game keeps its pads during the test")
            compare(Input.mockPadGeneration(), pads, "the same pads")
            Input.stopTest("pad-under-test")
        }

        // A failed call is logged, never blocks the UI, and the next change sends the newest route.
        function test_a_failed_call_does_not_block_and_the_next_change_sends_again() {
            start()
            Input.mockFail(true)
            signIn(1, "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Home comes although the call failed")
            tryCompare(Input, "status", "failed")
            compare(Input.route, "shell")
            compare(Input.mockServiceRoute(), "locked", "the service did not take it")
            Input.mockFail(false)
            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the next change")
            verify(Input.mockPads())
        }

        // Asking for the route the service already holds sends nothing; asking again after a failure does.
        function test_an_unchanged_route_is_sent_once_and_a_failed_one_again() {
            start()
            signIn(1, "p2")
            expectRoute("shell", "", "", "p2", "Home")
            const n = Input.mockCalls().length
            Input.setRoute("shell", "", "", "p2")
            wait(50)                                     // a negative check: nothing is sent
            compare(Input.mockCalls().length, n, "the same route is not sent again")
            Input.mockFail(true)
            Input.setRoute("shell", "", "", "p3")
            tryCompare(Input, "status", "failed")
            Input.mockFail(false)
            Input.setRoute("shell", "", "", "p3")
            tryCompare(Input, "status", "ok")
            compare(Input.mockServiceProfile(), "p3", "the failed route was sent again")
            Input.setRoute("shell", "", "", "p2")          // back to what the shell says
            tryCompare(Input, "status", "ok")
        }

        // A profile with a PIN: the PIN pad is still "locked", and no call carries a profile before the
        // PIN is accepted (wrong PIN first, then the right one).
        function test_no_profile_before_the_pin_is_verified() {
            start()
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Left)                    // Player One (p1, PIN 1234)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("pinPad").shown, 2000, "the PIN pad opens")
            for (const digit of "9999")
                keyClick(digit)
            keyClick(Qt.Key_Enter)
            wait(50)                                     // a negative check: the wrong PIN signs nobody in
            compare(Profiles.activeProfile, "", "a wrong PIN signs nobody in")
            compare(Input.route, "locked", "the PIN pad is locked")
            verify(Input.mockCalls().every(c => c.profile === ""), "no call carried a profile before the PIN")
            tryVerify(() => find("pinPad").shown && find("pinPad").entered === "", 3000, "the PIN pad is ready again")
            for (const digit of "1234")
                keyClick(digit)
            keyClick(Qt.Key_Enter)
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Home after the PIN")
            expectRoute("shell", "", "", "p1", "Player One at Home")
            checkCalls()
        }

        // A restarted service is in "shell" with no profile: the new owner gets the current route.
        function test_a_restarted_service_gets_the_route_again() {
            start()
            signIn(1, "p2")
            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the game in front")
            Input.mockClearCalls()
            Input.mockRestart()
            compare(Input.mockServiceRoute(), "shell", "the restarted service starts in shell")
            verify(!Input.mockPads(), "and has no pads")
            tryVerify(() => Input.mockServiceRoute() === "app", 2000, "the shell sent the route again")
            expectRoute("app", run.instance, "org.example.Racer", "p2", "after the restart")
            verify(Input.mockPads(), "the game has pads again")
            compare(Input.mockCalls().length, 1, "one call for the new owner")
            verify(run.app.activeFocus, "the game kept the focus")

            // Also at the picker: the restarted service is told "locked".
            Profiles.lock()
            expectRoute("locked", "", "", "", "locked")
            Input.mockRestart()
            tryVerify(() => Input.mockServiceRoute() === "locked", 2000, "the shell sent locked again")
            checkCalls()
        }

        // The Guide key opens the Hub from the game in the route "app" (it reaches the shell as
        // KEY_HOMEPAGE in every route, 06 §5.1), and a held Guide is not sent as a route flood.
        function test_guide_opens_the_hub_from_the_app_route() {
            start()
            signIn(1, "p2")
            const run = playRacer()
            expectRoute("app", run.instance, "org.example.Racer", "p2", "the game in front")
            keyPress(Qt.Key_HomePage)
            tryVerify(() => find("systemPanel").open, 2000, "Guide opened the Hub")
            keyRelease(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub has the focus")
            tryVerify(() => Input.route === "overlay", 2000, "the route is overlay")
            checkCalls()
        }

        // A window whose pid lookup has not answered is routed to the instance the route falls back to,
        // and the window gap resolves it the same way: removing it before the answer leaves "overlay"
        // with the instance, never "shell", which would destroy the game's pads (RUY-1040).
        function test_a_window_removed_before_its_pid_answer_leaves_the_gap_not_shell() {
            start()
            signIn(1, "p2")
            const run = playRacer()
            tc.shell.removeApp(run.app)
            tryVerify(() => Input.route === "overlay" && Input.instance === run.instance, 2000, "the gap holds the instance")
            Session.mockDelayPidAnswers(60000)
            Input.mockClearCalls()
            const early = createTemporaryObject(pidWindowComponent, host, { pid: Session.mockPidOf(run.instance) })
            tc.shell.addApp(early, "p2")
            tryVerify(() => Input.route === "app" && Input.instance === run.instance, 2000, "the pending window is routed app")
            tc.shell.removeApp(early)
            tryVerify(() => Input.route === "overlay" && Input.instance === run.instance, 2000, "removed before the answer: the gap")
            const routes = Input.mockCalls().map(c => c.route)
            verify(!routes.includes("shell"), "no shell route was sent: " + routes)
            const next = createTemporaryObject(pidWindowComponent, host, { pid: Session.mockPidOf(run.instance) })
            tc.shell.addApp(next, "p2")
            tryVerify(() => Input.route === "app" && Input.instance === run.instance, 2000, "a second window gives app again")
            Session.mockDelayPidAnswers(0)
        }
    }
}
