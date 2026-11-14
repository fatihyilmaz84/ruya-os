import QtQuick
import QtTest
import RuyaShell

// RUY-561: a Wayland idle inhibitor counts only while its app is the front app. The compositor
// reports {id, surface} to Shell.addInhibitor; the stand-in window carries the same `surface`. The
// decision (Shell.heldInhibitors) must follow: in front holds, behind Home releases, a frozen app
// (the Session1 record's state, as ruya-session freezes it on a profile switch too) releases, a lock
// releases, a destroyed inhibitor releases once.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    Component {
        id: appComponent
        Item {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            property var surface: ({ name: "surface" })
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }

    TestCase {
        id: tc
        name: "IdleInhibitFront"
        when: windowShown

        property Shell shell: null

        function held() { return IdleInhibit.reasons.indexOf("wayland:1") >= 0 }

        function cleanup() {
            DeviceSettings.pauseGamesInHub = true
            Session.mockFailFreeze(false)
            Session.mockFailThaw(false)
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.pauseGamesInHub = true
            Library.resetMockForTests("")
            Session.mockReset()
            IdleInhibit.releaseAll()
            launchedSpy.clear()
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => findChild(tc.shell, "profileList").activeFocus, 2000, "the picker has the focus")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => Library.available)
            tryVerify(() => Library.items.length === 10)
        }

        // Launches Turbo Racer, adds its window, and registers an inhibitor on the window's surface.
        function playWithInhibitor() {
            tryVerify(() => findChild(tc.shell, "homePlay").activeFocus, 2000, "Play has the focus")
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1 && Session.running[0].state === "running")
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app, "p2")
            tryCompare(tc.shell, "focusedApp", app)
            tc.shell.addInhibitor(1, app.surface)
            return app
        }

        function test_front_holds_and_home_releases() {
            playWithInhibitor()
            tryVerify(() => held(), 2000, "in front: held")
            tc.shell.appsBehindHome = true
            tryVerify(() => !held(), 2000, "behind Home: released")
            tc.shell.appsBehindHome = false
            tc.shell.focusApp(tc.shell.apps[0].item)
            tryVerify(() => held(), 2000, "back in front: taken again")
        }

        function test_another_window_in_front_releases() {
            const first = playWithInhibitor()
            tryVerify(() => held())
            const second = createTemporaryObject(appComponent, host, { surface: ({ name: "second" }) })
            tc.shell.addApp(second, "p2")
            tryCompare(tc.shell, "focusedApp", second)
            tryVerify(() => !held(), 2000, "another window took the front: released")
            tc.shell.focusApp(first)
            tryCompare(tc.shell, "focusedApp", first)
            tryVerify(() => held(), 2000, "back in front: held")
        }

        function test_the_hub_releases_and_closing_it_takes_it_again() {
            DeviceSettings.pauseGamesInHub = false          // nothing is frozen: the Hub alone must release
            playWithInhibitor()
            tryVerify(() => held())
            keyClick(Qt.Key_HomePage)
            tryVerify(() => findChild(tc.shell, "systemPanel").open)
            tryVerify(() => !held(), 2000, "the Hub is open over the app: released")
            compare(Session.running[0].frozen === true, false, "and the game is not frozen")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !findChild(tc.shell, "systemPanel").open)
            tryVerify(() => held(), 2000, "the Hub closed: held again")
        }

        function test_hub_then_home_with_pause_on_stays_released_until_the_card_resumes() {
            playWithInhibitor()
            tryVerify(() => held())
            keyClick(Qt.Key_HomePage)
            tryVerify(() => findChild(tc.shell, "quickMenuItem_resume").focused)
            tryVerify(() => Session.running[0].frozen === true, 2000, "the Hub froze it")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                         // Home
            tryVerify(() => !tc.shell.appOpen, 2000)
            tryVerify(() => Session.running[0].frozen === true, 2000, "the Hub froze it")
            wait(100)
            verify(!held(), "frozen and behind Home: released")
            tryVerify(() => findChild(tc.shell, "recentRow").activeFocus, 2000)
            keyClick(Qt.Key_Return)                         // Accept on its Running card
            tryVerify(() => tc.shell.appOpen, 2000)
            tryVerify(() => Session.running[0].frozen === false, 2000)
            tryVerify(() => held(), 2000, "resumed from the card: held again")
        }

        function test_frozen_releases() {
            playWithInhibitor()
            tryVerify(() => held())
            const instance = Session.running[0].instance
            tryVerify(() => Session.running[0].state === "running")
            Session.mockFailThaw(true)                  // HubPause's sweep thaws a frozen app the Hub did not freeze
            Session.freeze(instance)
            tryVerify(() => Session.running[0].frozen === true)
            tryVerify(() => !held(), 2000, "frozen (the Session record): released")
            Session.mockFailThaw(false)
            Session.thaw(instance)
            tryVerify(() => Session.running[0].frozen === false)
            tryVerify(() => held(), 2000, "thawed: held again")
        }

        function test_lock_releases() {
            playWithInhibitor()
            tryVerify(() => held())
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => !held(), 2000, "locked: released")
        }

        function test_unknown_surface_does_not_hold() {
            playWithInhibitor()
            tc.shell.addInhibitor(5, ({ name: "other" }))
            tc.shell.addInhibitor(6, null)
            wait(50)
            compare(IdleInhibit.reasons.indexOf("wayland:5"), -1)
            compare(IdleInhibit.reasons.indexOf("wayland:6"), -1)
        }

        function test_destroyed_releases_once() {
            playWithInhibitor()
            tryVerify(() => held())
            IdleInhibit.acquire("wayland:1")            // somebody else's count on the same reason
            tc.shell.removeInhibitor(1)
            tryVerify(() => IdleInhibit.reasons.indexOf("wayland:1") >= 0, 2000, "one release only")
            tc.shell.removeInhibitor(1)                 // reported again: no second release
            wait(50)
            verify(held(), "the other count is still there")
            IdleInhibit.release("wayland:1")
            verify(!held())
        }
    }
}
