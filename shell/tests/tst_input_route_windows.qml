import QtQuick
import QtTest
import RuyaShell

// Two windows of one app keep its pads (RUY-814, 06 §5.2): Input destroys the virtual pads on a
// "shell" route, so the shell must not send one between the windows of a running instance.
//   - a second window of the same client (same pid) takes the instance at once, with no lookup;
//   - a window whose instance lookup is pending holds the route that was sent; the reply naming
//     another instance or none sends where things end up (no stale hold);
//   - the last window of a running instance closing keeps the pads for windowGapMs, until a window
//     maps, the instance exits, the Hub opens or the time is up.
// Signs in as "Ada" (p2). The mock Session gives every instance a pid and can delay its answers.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A game window that calls itself "python3.12", so only its pid names the instance.
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

    TestCase {
        id: tc
        name: "InputRouteWindows"
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
            launchedSpy.clear()
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
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function recordOf(instance) {
            return Session.running.find(r => r.instance === instance)
        }

        function windowRecord(item) {
            return tc.shell.apps.find(r => r.item === item)
        }

        // Launches the app and waits until it runs; returns { instance, pid }.
        function launch(appId) {
            const n = launchedSpy.count
            Session.launch(appId, "p2")
            tryCompare(launchedSpy, "count", n + 1)
            const instance = launchedSpy.signalArguments[n][3]
            verify(instance !== "")
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            return { instance: instance, pid: Session.mockPidOf(instance), appId: appId }
        }

        function mapWindow(pid) {
            const app = createTemporaryObject(appComponent, host, { pid: pid })
            verify(app)
            tc.shell.addApp(app, "p2")
            return app
        }

        // The first window of a launched app, once its route is "app" with the instance.
        function firstWindow(run) {
            const app = mapWindow(run.pid)
            tryVerify(() => windowRecord(app) && windowRecord(app).instance === run.instance, 2000, "the window takes the instance")
            expectApp(run)
            return app
        }

        function expectApp(run, why) {
            tryVerify(() => Input.route === "app" && Input.instance === run.instance && Input.appId === run.appId
                      && Input.profile === "p2" && Input.status === "ok", 2000,
                      (why ?? "app") + ": asked " + Input.route + "|" + Input.instance + "|" + Input.appId + " (" + Input.status + ")")
        }

        // The routes the shell sent since the calls were cleared.
        function routesSent() {
            return Input.mockCalls().map(c => c.route)
        }

        function test_a_second_window_of_the_same_client_has_no_lookup_and_no_shell_route() {
            start()
            const run = launch("org.example.Racer")
            const first = firstWindow(run)
            const gen = Input.mockPadGeneration()
            verify(Input.mockPads())
            Session.mockDelayPidAnswers(300)
            Input.mockClearCalls()

            const second = mapWindow(run.pid)
            const rec = windowRecord(second)
            compare(rec.instance, run.instance, "the sibling's instance at once")
            verify(!rec.pending, "no lookup is pending")
            expectApp(run, "the second window in front")
            wait(400)                           // a lookup would have answered by now
            expectApp(run, "still app")
            verify(!routesSent().includes("shell"), "no shell route between the windows: " + routesSent())
            compare(Input.mockPadGeneration(), gen, "the same pads, none destroyed or made")
            verify(first && second)
        }

        function test_a_pending_lookup_holds_the_route_and_ends_on_the_other_instance() {
            start()
            const racer = launch("org.example.Racer")
            const puzzle = launch("org.example.Puzzle")
            const first = firstWindow(racer)
            Session.mockDelayPidAnswers(300)
            Input.mockClearCalls()

            const second = mapWindow(puzzle.pid)       // a different client: its lookup is pending
            verify(windowRecord(second).pending)
            tryVerify(() => tc.shell.frontLookupPending, 2000, "the lookup is pending")
            const gen = Input.mockPadGeneration()
            compare(find("inputRoute").route, "app", "the route is held while the lookup is pending")
            compare(find("inputRoute").routeInstance, racer.instance)
            tryCompare(tc.shell, "frontLookupPending", false)
            expectApp(puzzle, "the reply names the other instance")
            verify(!routesSent().includes("shell"), "no shell route while the lookup was pending: " + routesSent())
            verify(Input.mockPadGeneration() > gen, "another instance gets its own pads")
            verify(first && second)
        }

        function test_a_lookup_that_answers_none_ends_the_hold_on_shell() {
            start()
            const run = launch("org.example.Racer")
            const first = firstWindow(run)
            Session.mockDelayPidAnswers(300)
            Input.mockClearCalls()

            const second = mapWindow(99999)            // no instance has this pid
            tryVerify(() => tc.shell.frontLookupPending, 2000, "the lookup is pending")
            compare(find("inputRoute").route, "app", "held while pending")
            tryCompare(tc.shell, "frontLookupPending", false)
            tryVerify(() => Input.route === "shell" && Input.status === "ok", 2000, "no stale hold: the route ends as shell")
            compare(windowRecord(second).instance, "")
            verify(first)
        }

        function test_the_gap_after_the_last_window_keeps_the_pads_until_the_next_window() {
            start()
            const run = launch("org.example.Racer")
            const first = firstWindow(run)
            const gen = Input.mockPadGeneration()
            tc.shell.windowGapMs = 5000
            Input.mockClearCalls()

            first.destroy()
            tryVerify(() => windowRecord(first) === undefined, 2000, "the window is gone")
            tryVerify(() => Input.route === "overlay" && Input.instance === run.instance && Input.appId === run.appId
                      && Input.status === "ok", 2000, "the gap holds the instance's pads: " + Input.route)
            compare(Input.mockPadGeneration(), gen, "the pads stay")

            Session.mockDelayPidAnswers(300)
            const second = mapWindow(run.pid)          // the sibling is gone: a lookup, held meanwhile
            tryCompare(tc.shell, "frontLookupPending", false)
            expectApp(run, "the next window")
            verify(!routesSent().includes("shell"), "no shell route in the gap: " + routesSent())
            compare(Input.mockPadGeneration(), gen, "the same pads through the gap")
            tryCompare(tc.shell, "gapInstance", "")
            verify(second)
        }

        function test_the_gap_ends_on_time_on_exit_and_for_the_hub() {
            start()
            let run = launch("org.example.Racer")
            let first = firstWindow(run)
            tc.shell.windowGapMs = 250
            first.destroy()
            tryVerify(() => Input.route === "overlay" && Input.instance === run.instance, 2000, "gap begins")
            tryVerify(() => Input.route === "shell" && Input.status === "ok", 2000, "time is up: shell")

            // The instance exits during the gap.
            tc.shell.windowGapMs = 60000
            run = launch("org.example.Puzzle")
            first = firstWindow(run)
            first.destroy()
            tryVerify(() => Input.route === "overlay" && Input.instance === run.instance, 2000, "gap begins again")
            Session.stop(run.instance)
            tryVerify(() => recordOf(run.instance) === undefined, 2000, "the instance exited")
            tryVerify(() => Input.route === "shell" && Input.status === "ok", 2000, "exit releases the hold")
            compare(tc.shell.gapInstance, "")
        }

        function test_the_hub_in_the_gap_sends_shell() {
            start()
            const run = launch("org.example.Racer")
            const first = firstWindow(run)
            tc.shell.windowGapMs = 60000
            first.destroy()
            tryVerify(() => Input.route === "overlay" && Input.instance === run.instance, 2000, "gap begins")
            keyClick(Qt.Key_HomePage)                  // Guide
            tryVerify(() => find("systemPanel").open, 2000, "the Hub opens")
            tryVerify(() => Input.route === "shell" && Input.status === "ok", 2000, "the Hub on purpose: shell")
            compare(tc.shell.gapInstance, "")
        }
    }
}
