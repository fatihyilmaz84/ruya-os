import QtQuick
import QtTest
import RuyaShell

// A running game is always reachable (T-467, 02 §1.5, §1.6): whatever the game's window calls itself
// and whether Session1 could map its process, the shell binds the window to the running instance
// (Shell.instanceOfWindow: process, then the window's app id in its profile, then the only running
// app no other window claims). The Hub lists every running app of the profile as a Switch to row,
// from Home too, and Play on a running game's card brings its window back to the front, thawed.
// Self-contained: its own fixture (mock Session, signs in as "Ada", p2).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A game window: its app id is not its Flatpak id, `pid` is the one of its client (0: none).
    Component {
        id: appComponent
        Item {
            objectName: "standInApp"
            property string appId: "python3.12"
            property int pid: 0
            Keys.onPressed: event => event.accepted = true
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }
    SignalSpy { id: pidSpy; target: Session; signalName: "instanceOfPidFinished" }

    TestCase {
        id: tc
        name: "RunningReachable"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.pauseGamesInHub = true
            Library.resetMockForTests("")
            Session.mockReset()
            launchedSpy.clear()
            pidSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            DeviceSettings.pauseGamesInHub = true
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
        }

        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text)
            return out
        }

        function recordOf(instance) {
            return Session.running.find(r => r.instance === instance)
        }

        function windowRecord(item) {
            return tc.shell.apps.find(r => r.item === item)
        }

        function itemIdOf(appId) {
            const found = Library.items.find(i => Library.sessionAppId(i.id) === appId)
            return found ? found.id : ""
        }

        // Starts `appId` for `profile` without a window and returns its instance once it runs.
        function launchBare(appId, profile) {
            const n = launchedSpy.count
            Session.launch(appId, profile ?? "p2")
            tryCompare(launchedSpy, "count", n + 1)
            const instance = launchedSpy.signalArguments[n][3]
            verify(instance !== "")
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            return instance
        }

        // A window of `appId` whose client the mock maps to `instance` (pid 0: none; pid 99999: of no
        // instance). Waits for the answer when there is a pid.
        function addWindow(props, profile) {
            const n = pidSpy.count
            const app = createTemporaryObject(appComponent, host, props ?? {})
            verify(app)
            tc.shell.addApp(app, profile ?? "p2")
            if ((app.pid ?? 0) > 0)
                tryCompare(pidSpy, "count", n + 1)
            return app
        }

        function openHub() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
        }

        function focusedKey() {
            const list = find("systemActions")
            return list.model[list.currentIndex]
        }

        function goTo(key) {
            for (let i = 0; i < 20 && focusedKey() !== key; ++i)
                keyClick(Qt.Key_Down)
            for (let i = 0; i < 20 && focusedKey() !== key; ++i)
                keyClick(Qt.Key_Up)
            compare(focusedKey(), key)
            verify(find("quickMenuItem_" + key).focused, key + " has the focus ring")
        }

        // Home from the Hub, with the focus on the game's Running card.
        function goHome() {
            openHub()
            goTo("home")
            keyClick(Qt.Key_Return)
            tryVerify(() => !tc.shell.appOpen, 2000, "Home is in front")
        }

        // Owner's case: the window gives itself another id and Session1 could not map its process. Home
        // froze it (the Hub paused it), and Play on its card brings that window back, thawed.
        function test_play_brings_back_an_unmapped_window_thawed() {
            start()
            const racer = launchBare("org.example.Racer")
            const app = addWindow({ pid: 99999 })
            tryVerify(() => app.activeFocus, 2000, "the window is in front")
            compare(windowRecord(app).instance, "", "Session1 could not map the process")
            compare(tc.shell.quickMenuApp.instance, racer, "the window is still known as Turbo Racer's")
            goHome()
            tryVerify(() => recordOf(racer).frozen === true, 2000, "the Hub paused the game")
            verify(!app.activeFocus)
            const row = find("recentRow")
            tryVerify(() => row.activeFocus, 2000, "the focus is on the game's card")
            compare(row.currentItem.itemId, itemIdOf("org.example.Racer"))
            verify(row.currentItem.running, "with its Running pill")
            keyClick(Qt.Key_Return)                          // Play on the Running card
            tryVerify(() => app.activeFocus, 2000, "Play brings the window back")
            tryVerify(() => recordOf(racer).frozen !== true, 2000, "thawed")
            compare(toastTexts().filter(t => t.endsWith("already running")), [], "no toast")
            compare(launchedSpy.count, 1, "no second launch")
            verify(tc.shell.appOpen)
        }

        // The same with no pid at all (a window without a client process), and with an empty app id.
        function test_play_brings_back_a_window_without_pid_or_app_id() {
            start()
            const racer = launchBare("org.example.Racer")
            const app = addWindow({ appId: "" })
            tryVerify(() => app.activeFocus, 2000)
            goHome()
            tryVerify(() => recordOf(racer).frozen === true, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => app.activeFocus, 2000, "Play brings the window back")
            tryVerify(() => recordOf(racer).frozen !== true, 2000, "thawed")
            compare(toastTexts().filter(t => t.endsWith("already running")), [])
        }

        // The Hub from Home lists every running game of the profile (one of them has no window yet),
        // and Switch to opens the one with a window.
        function test_the_hub_from_home_lists_every_running_game() {
            start()
            const racer = launchBare("org.example.Racer")
            const puzzle = launchBare("org.example.Puzzle")
            const app = addWindow({ pid: Session.mockPidOf(racer) })
            tryVerify(() => app.activeFocus, 2000)
            compare(windowRecord(app).instance, racer)
            goHome()
            openHub()
            compare(tc.shell.quickMenuApp, null, "from Home there is no app part")
            compare(tc.shell.quickMenuOthers.map(o => o.appId).sort(), ["org.example.Puzzle", "org.example.Racer"])
            compare(tc.shell.quickMenuOthers.find(o => o.appId === "org.example.Racer").hasWindow, true)
            compare(tc.shell.quickMenuOthers.find(o => o.appId === "org.example.Puzzle").hasWindow, false)
            const keys = find("systemActions").model
            verify(keys.includes("to:org.example.Racer"), "a Switch to row for the game with a window")
            verify(keys.includes("to:org.example.Puzzle"), "and one for the game without")
            verify(focusedKey().startsWith("to:"), "the first row is a running game")

            goTo("to:org.example.Puzzle")                    // no window yet: says so, the Hub stays
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().some(t => t.endsWith("has no window yet.")), 2000)
            verify(find("systemPanel").open, "the Hub stays open")
            verify(find("quickMenuItem_to:org.example.Puzzle").focused)
            compare(Session.mockCalls().filter(c => c.startsWith("stop")), [], "nothing harmful happened")
            verify(recordOf(puzzle) !== undefined)

            goTo("to:org.example.Racer")
            keyClick(Qt.Key_Return)
            tryVerify(() => app.activeFocus, 2000, "Switch to opens the game")
            tryVerify(() => !find("systemPanel").open)
            tryVerify(() => recordOf(racer).frozen !== true, 2000, "thawed")
            verify(tc.shell.appOpen)
        }

        // A frozen game behind Home is listed too, and Switch to thaws it.
        function test_a_frozen_game_is_listed_and_switch_to_thaws_it() {
            start()
            const racer = launchBare("org.example.Racer")
            const app = addWindow({ pid: Session.mockPidOf(racer) })
            tryVerify(() => app.activeFocus, 2000)
            goHome()
            tryVerify(() => recordOf(racer).frozen === true, 2000)
            openHub()
            goTo("to:org.example.Racer")
            keyClick(Qt.Key_Return)
            tryVerify(() => app.activeFocus, 2000)
            tryVerify(() => recordOf(racer).frozen !== true, 2000, "thawed")
        }

        // Same app id in two profiles: the other profile's game and window never cross.
        function test_two_profiles_with_the_same_app_id_never_cross() {
            start()
            const other = launchBare("org.example.Racer", "p1")      // Player One's game, same app id
            const mine = launchBare("org.example.Racer", "p2")
            const hidden = addWindow({ appId: "org.example.Racer", pid: Session.mockPidOf(other) }, "p1")
            compare(windowRecord(hidden).instance, other)
            verify(!hidden.visible, "the other profile's window is hidden")
            compare(tc.shell.windowOf("org.example.Racer"), undefined, "no window of mine yet")
            const app = addWindow({ appId: "org.example.Racer", pid: Session.mockPidOf(mine) })
            tryVerify(() => app.activeFocus, 2000)
            compare(tc.shell.windowOf("org.example.Racer").item, app)
            // a window of the shell's own (profile "") that names the app id and has no pid binds in the
            // signed-in profile (the old lookup took the first running app of that id: the other profile's)
            const plain = addWindow({ appId: "org.example.Racer" }, "")
            tryVerify(() => plain.activeFocus, 2000)
            compare(tc.shell.instanceOfWindow(windowRecord(plain)).instance, mine)
            const plainOther = addWindow({ appId: "org.example.Racer" }, "p1")
            compare(tc.shell.instanceOfWindow(windowRecord(plainOther)).instance, other)
            // the Hub freezes my game (the window in front is the plain one): it is frozen, the other
            // profile's is not, and each window reads its own instance
            openHub()
            compare(tc.shell.quickMenuApp.instance, mine)
            tryVerify(() => recordOf(mine).frozen === true, 2000, "the Hub paused my game")
            verify(tc.shell.appFrozen(windowRecord(plain)), "frozen is read from my own instance")
            verify(tc.shell.appFrozen(windowRecord(app)))
            verify(!tc.shell.appFrozen(windowRecord(hidden)), "the other profile's game is not frozen")
            verify(recordOf(other).frozen !== true)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("systemPanel").open)
            goHome()
            openHub()
            compare(tc.shell.quickMenuOthers.map(o => o.appId), ["org.example.Racer"], "mine only, once")
        }

        // Two windows the shell cannot map to one game: it does not guess (Close does not either).
        function test_two_unmapped_windows_are_not_guessed() {
            start()
            launchBare("org.example.Racer")
            const a = addWindow({ pid: 99999 })
            const b = addWindow({ pid: 99998 })
            compare(tc.shell.instanceOfWindow(windowRecord(a)), undefined)
            compare(tc.shell.instanceOfWindow(windowRecord(b)), undefined)
        }

        // The rare case: a running game with no window at all. Play toasts, nothing else.
        function test_play_on_a_game_without_any_window_toasts() {
            start()
            const racer = launchBare("org.example.Racer")
            compare(tc.shell.windowOf("org.example.Racer"), undefined)
            find("recentRow").forceActiveFocus()
            tc.shell.launchApp("org.example.Racer", "Turbo Racer", "")
            tryVerify(() => toastTexts().some(t => t.endsWith("already running")), 2000)
            verify(!tc.shell.launching)
            verify(recordOf(racer) !== undefined)
        }
    }
}
