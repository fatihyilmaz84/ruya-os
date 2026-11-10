import QtQuick
import QtTest
import RuyaShell

// A window finds its running game by its process, not by the app id it gives itself (T-459,
// 02 §1.5, §1.6): a pygame game's window calls itself "python3.12", so the shell asks
// Session1.InstanceOfPid for the client's pid and the window record takes that instance. The Hub's
// title, Close game, the Running card, Resume, "Switch to" and the pause all go by it; with no
// instance at all, Close says it could not close the game instead of going Home silently. The mock
// Session gives every launched instance a made-up pid (mockPidOf). Signs in as "Ada" (p2).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A game window whose app id is not its Flatpak id, with the pid of its client.
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
        name: "WindowInstance"
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

        // A signal's arguments (an arguments object, not an array) against the expected values.
        function compareArgs(args, expected) {
            compare(args.length, expected.length)
            for (let i = 0; i < expected.length; ++i)
                compare(args[i], expected[i], "argument " + i)
        }

        function recordOf(instance) {
            return Session.running.find(r => r.instance === instance)
        }

        function windowRecord(item) {
            return tc.shell.apps.find(r => r.item === item)
        }

        function racerId() {
            const found = Library.items.find(i => Library.sessionAppId(i.id) === "org.example.Racer")
            return found ? found.id : ""
        }

        // Play on the hero (Turbo Racer); its window says "python3.12" and arrives while the splash
        // is up: the splash ends when Session1 names the window's instance. Returns { app, instance }.
        function playRacer() {
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            const instance = launchedSpy.signalArguments[0][3]
            verify(instance !== "")
            const pid = Session.mockPidOf(instance)
            verify(pid > 0, "the mock gives the instance a pid")
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            verify(tc.shell.launching, "the splash is up until the window is known")
            const app = createTemporaryObject(appComponent, host, { pid: pid })
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => windowRecord(app) && windowRecord(app).instance === instance, 2000,
                      "the window takes the instance of its process")
            tryVerify(() => !tc.shell.launching, 2000, "the splash ends on the window after all")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")
            return { app: app, instance: instance }
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
            compare(focusedKey(), key)
            verify(find("quickMenuItem_" + key).focused, key + " has the focus ring")
        }

        function test_the_mock_names_the_instance_of_a_pid() {
            const n = launchedSpy.count
            Session.launch("org.example.Racer", "p2")
            tryCompare(launchedSpy, "count", n + 1)
            const instance = launchedSpy.signalArguments[n][3]
            const pid = Session.mockPidOf(instance)
            verify(pid > 0)
            Session.instanceOfPid(pid)
            tryCompare(pidSpy, "count", 1)
            compareArgs(pidSpy.signalArguments[0], [pid, "ok", instance])
            Session.instanceOfPid(pid + 1000)
            tryCompare(pidSpy, "count", 2)
            compareArgs(pidSpy.signalArguments[1], [pid + 1000, "not-found", ""])
            Session.instanceOfPid(0)
            tryCompare(pidSpy, "count", 3)
            compareArgs(pidSpy.signalArguments[2], [0, "invalid", ""])
        }

        function test_the_hub_names_the_game_and_close_ends_it() {
            start()
            const run = playRacer()
            openHub()
            compare(find("quickMenuTitle").text, tc.shell.titleOfApp("org.example.Racer"),
                    "the Hub's title is the game's, not python3.12")
            verify(find("quickMenuTitle").text !== "python3.12")
            compare(tc.shell.quickMenuApp.instance, run.instance)
            tryVerify(() => recordOf(run.instance).frozen === true, 2000, "the Hub pauses the game")
            compare(Session.mockCalls(), ["freeze " + run.instance])
            goTo("closeGame")
            keyClick(Qt.Key_Return)
            tryVerify(() => !tc.shell.appOpen, 2000, "Home is in front")
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance, "stop " + run.instance])
            tryVerify(() => recordOf(run.instance) === undefined, 2000, "the game quit")
            compare(toastTexts().filter(t => t.startsWith("Could not close")), [])
        }

        function test_home_shows_its_running_card_and_the_card_resumes_it() {
            start()
            const run = playRacer()
            openHub()
            goTo("home")
            keyClick(Qt.Key_Return)
            tryVerify(() => !tc.shell.appOpen, 2000, "Home is in front")
            const row = find("recentRow")
            tryVerify(() => row.activeFocus, 2000, "the focus is on the game's card")
            compare(row.currentItem.itemId, racerId(), "the card is Turbo Racer's")
            verify(row.currentItem.running, "with its Running pill")
            keyClick(Qt.Key_Return)                          // Resume on the card
            tryVerify(() => run.app.activeFocus, 2000, "the card brings the python3.12 window back")
            verify(!tc.shell.launching, "no second launch")
            compare(launchedSpy.count, 1)
        }

        function test_switch_to_names_and_reaches_the_window() {
            start()
            const racer = playRacer()
            const n = launchedSpy.count
            Session.launch("org.example.Puzzle", "p2")
            tryCompare(launchedSpy, "count", n + 1)
            const puzzleInstance = launchedSpy.signalArguments[n][3]
            tryVerify(() => recordOf(puzzleInstance) !== undefined && recordOf(puzzleInstance).state === "running")
            const puzzle = createTemporaryObject(appComponent, host,
                                                 { appId: "org.example.Puzzle", pid: Session.mockPidOf(puzzleInstance) })
            tc.shell.addApp(puzzle, "p2")
            tryVerify(() => puzzle.activeFocus, 2000, "the newest window is in front")
            tryVerify(() => windowRecord(puzzle).instance === puzzleInstance)

            openHub()
            compare(tc.shell.quickMenuOthers.map(o => o.appId), ["org.example.Racer"],
                    "the other window is named by its instance's app")
            compare(tc.shell.quickMenuOthers[0].title, tc.shell.titleOfApp("org.example.Racer"))
            goTo("to:org.example.Racer")
            keyClick(Qt.Key_Return)
            tryVerify(() => racer.app.activeFocus, 2000, "Turbo Racer is in front")
            compare(tc.shell.quickMenuApp.instance, racer.instance)
            openHub()
            tryVerify(() => recordOf(racer.instance).frozen === true, 2000, "the Hub pauses Turbo Racer")
            verify(Session.mockCalls().includes("freeze " + racer.instance))
        }

        // No pid (or a process of no app) and no running app of the profile: nothing can be stopped.
        function test_close_with_no_instance_warns_and_stays() {
            start()
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000)
            compare(Session.running.length, 0)
            openHub()
            compare(tc.shell.quickMenuApp.instance, "")
            goTo("closeGame")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().includes("Could not close python3.12."), 2000, "a warning says so")
            compare(Notifications.model.get(0).kind, "warning")
            verify(find("systemPanel").open, "the Hub stays open: no silent Home")
            verify(tc.shell.appOpen)
            verify(find("quickMenuItem_closeGame").focused, "the focus stays on Close game")
            compare(Session.mockCalls().filter(c => c.startsWith("stop")), [])
        }

        // A window that names no running app and whose process is of no instance closes the profile's
        // newest app (the fallback when Session1 cannot tell); the Hub's title stays the window's own.
        function test_close_falls_back_to_the_newest_app() {
            start()
            const n = launchedSpy.count
            Session.launch("org.example.Racer", "p2")
            tryCompare(launchedSpy, "count", n + 1)
            const instance = launchedSpy.signalArguments[n][3]
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            const app = createTemporaryObject(appComponent, host, { pid: 99999 })
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000)
            tryCompare(pidSpy, "count", 1)
            compare(pidSpy.signalArguments[0][1], "not-found")
            compare(windowRecord(app).instance, "")
            openHub()
            compare(tc.shell.quickMenuApp.instance, "", "the window names no running app")
            goTo("closeGame")
            keyClick(Qt.Key_Return)
            tryVerify(() => !tc.shell.appOpen, 2000, "Home is in front")
            verify(Session.mockCalls().includes("stop " + instance))
        }
    }
}
