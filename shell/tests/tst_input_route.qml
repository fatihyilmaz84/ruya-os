import QtQuick
import QtTest
import RuyaShell

// The shell drives Ruya Input's route (RUY-409, 06 §5.1-5.2, Input1.SetRoute): "locked" at the
// picker, "shell" at Home, "app" with the game in front, "overlay" with the Hub over it (with its
// instance also once the Hub froze it, RUY-541, so its pads stay), "app" again with the same pads after
// the Thaw; Home, Lock and a switch take them away, a switch going through "locked" with no profile. A failed call never blocks the UI and the next change sends the newest
// route; a restarted service (a new owner of the name) gets the current route again. The mock Input
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

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }

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
            launchedSpy.clear()
        }

        function cleanup() {
            DeviceSettings.pauseGamesInHub = true
            Input.mockFail(false)
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

            // Home from the Hub: the game stays frozen behind Home, the route is the shell's and the
            // pads go (out of RUY-541's scope: Home over a frozen game still destroys them).
            openHub()
            goTo("home")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("recentRow").activeFocus, 2000, "Home, the focus on the game's card")
            expectRoute("shell", "", "", "p2", "Home with the game behind it")
            verify(!Input.mockPads(), "no pads at Home")
            keyClick(Qt.Key_Return)                      // the Running card resumes it
            tryVerify(() => run.app.activeFocus, 2000, "the game is in front again")
            expectRoute("app", run.instance, "org.example.Racer", "p2", "resumed from its card")
            verify(Input.mockPadGeneration() > firstPads, "after Home the game gets new pads")

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
    }
}
