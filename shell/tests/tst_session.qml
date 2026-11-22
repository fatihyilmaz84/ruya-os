import QtQuick
import QtTest
import RuyaShell

// Session singleton against the mock backend: Launch/Stop statuses, the running list, AppExited
// reasons and the "stopped unexpectedly" toast (hosted by Shell).
Item {
    id: host
    width: 640
    height: 360

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test" }
    }

    SignalSpy { id: launched; target: Session; signalName: "launchFinished" }
    SignalSpy { id: launchedItems; target: Session; signalName: "launchItemFinished" }
    SignalSpy { id: startedSpy; target: Session; signalName: "appStarted" }
    SignalSpy { id: stopped; target: Session; signalName: "stopFinished" }
    SignalSpy { id: exited; target: Session; signalName: "appExited" }
    SignalSpy { id: freezeSpy; target: Session; signalName: "freezeFinished" }
    SignalSpy { id: thawSpy; target: Session; signalName: "thawFinished" }

    TestCase {
        id: tc
        name: "Session"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Session.mockReset()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => Session.running.length === 0)
            launched.clear()
            launchedItems.clear()
            startedSpy.clear()
            stopped.clear()
            exited.clear()
            freezeSpy.clear()
            thawSpy.clear()
        }

        // Launches and returns the instance of an "ok" launch.
        function launchOk(appId, profile) {
            const n = launched.count
            Session.launch(appId, profile)
            tryCompare(launched, "count", n + 1)
            const args = launched.signalArguments[n]
            compare(args[2], "ok")
            verify(args[3] !== "")
            return args[3]
        }

        function launchStatus(appId, profile) {
            const n = launched.count
            Session.launch(appId, profile)
            tryCompare(launched, "count", n + 1)
            const args = launched.signalArguments[n]
            compare(args[0], appId)
            compare(args[1], profile)
            if (args[2] !== "ok")
                compare(args[3], "")
            return args[2]
        }

        function test_statuses() {
            compare(launchStatus("org.nope.Missing", "p1"), "unknown-app")
            compare(launchStatus("org.example.Racer", "nobody"), "unknown-profile")
            compare(launchStatus("", "p1"), "invalid")
            compare(launchStatus("org.example.Racer", ""), "invalid")
            const instance = launchOk("org.example.Racer", "p1")
            compare(launchStatus("org.example.Racer", "p1"), "already-running")
            // The same app may run for another profile.
            launchOk("org.example.Racer", "p2")

            Session.stop("no-such-instance")
            tryCompare(stopped, "count", 1)
            compare(stopped.signalArguments[0][1], "unknown-instance")
            Session.stop("")
            tryCompare(stopped, "count", 2)
            compare(stopped.signalArguments[1][1], "invalid")
            Session.stop(instance)
            tryCompare(stopped, "count", 3)
            compare(stopped.signalArguments[2][0], instance)
            compare(stopped.signalArguments[2][1], "ok")
            tryCompare(exited, "count", 1)
        }

        function test_running_list_and_quit() {
            const instance = launchOk("org.example.Chess", "p1")
            tryVerify(() => Session.running.length === 1)
            let r = Session.running[0]
            compare(r.instance, instance)
            compare(r.appId, "org.example.Chess")
            compare(r.profile, "p1")
            verify(r.started > 0)
            tryVerify(() => Session.instanceOf("org.example.Chess", "p1").state === "running")

            const shown = Notifications.shownCount
            Session.stop(instance)
            tryCompare(exited, "count", 1)
            compare(exited.signalArguments[0][0], instance)
            compare(exited.signalArguments[0][1], "org.example.Chess")
            compare(exited.signalArguments[0][2], 0)
            compare(exited.signalArguments[0][3], "quit")
            tryVerify(() => Session.running.length === 0)
            // A normal quit says nothing (checked with Shell hosted in test_crash_toast).
            compare(Notifications.shownCount, shown)
        }

        // ADR-041 (RUY-1051): every record names its Library1 item; an app launched by Launch has no parent.
        function test_records_carry_item_and_parent() {
            const instance = launchOk("org.example.Racer", "p1")
            tryVerify(() => Session.running.length === 1)
            const r = Session.running[0]
            compare(r.instance, instance)
            compare(r.item, "flatpak:org.example.Racer")
            compare(r.parent, "")
        }

        function launchItemStatus(item, profile) {
            const n = launchedItems.count
            Session.launchItem(item, profile)
            tryCompare(launchedItems, "count", n + 1)
            const args = launchedItems.signalArguments[n]
            compare(args[0], item)
            compare(args[1], profile)
            if (args[2] !== "ok")
                compare(args[3], "")
            return args[2]
        }

        // LaunchItem as ruya-session answers it: a Flatpak item is Launch, a Steam game "failed" until
        // RUY-1052, anything else "invalid".
        function test_launch_item() {
            compare(launchItemStatus("flatpak:org.example.Chess", "p1"), "ok")
            const instance = launchedItems.signalArguments[0][3]
            verify(instance !== "")
            tryVerify(() => Session.instanceOf("org.example.Chess", "p1").instance === instance)
            compare(Session.instanceOf("org.example.Chess", "p1").item, "flatpak:org.example.Chess")
            compare(launchItemStatus("flatpak:org.example.Chess", "p1"), "already-running")
            compare(launchStatus("org.example.Chess", "p1"), "already-running", "the same app as Launch's")
            compare(launchItemStatus("flatpak:org.nope.Missing", "p1"), "unknown-app")
            compare(launchItemStatus("flatpak:org.example.Racer", "nobody"), "unknown-profile")
            compare(launchItemStatus("steam:70", "p1"), "failed")
            for (const bad of ["", "flatpak:", "steam:", "steam:7a", "play:x", "org.example.Racer"])
                compare(launchItemStatus(bad, "p1"), "invalid", bad)
            compare(launched.count, 1, "launchItem answers with launchItemFinished only")
        }

        // The mock's seam for B6: a Steam game as a child of a running Steam instance (ADR-041).
        function test_mock_child_seam() {
            const steam = launchOk("org.example.Steam", "p1")
            compare(Session.mockStartChild(steam, "steam:70"), "", "the parent is still starting")
            tryVerify(() => Session.instanceOf("org.example.Steam", "p1").state === "running")
            startedSpy.clear()
            compare(Session.mockStartChild(steam, "flatpak:org.example.Racer"), "", "not a Steam game")
            compare(Session.mockStartChild("no-such-instance", "steam:70"), "")
            const game = Session.mockStartChild(steam, "steam:70")
            verify(game !== "" && game !== steam)
            tryCompare(startedSpy, "count", 1)
            compare(startedSpy.signalArguments[0][0], game)
            compare(startedSpy.signalArguments[0][1], "org.example.Steam", "AppStarted carries the parent's app id")
            tryVerify(() => Session.running.length === 2)
            const child = Session.running.find(r => r.instance === game)
            verify(child !== undefined)
            compare(child.item, "steam:70")
            compare(child.parent, steam)
            compare(child.appId, "org.example.Steam")
            compare(child.profile, "p1")
            compare(child.state, "running")
            compare(Session.mockStartChild(game, "steam:80"), "", "a child has no children")

            Session.mockEndChild(game)
            tryCompare(exited, "count", 1)
            compare(exited.signalArguments[0][0], game)
            compare(exited.signalArguments[0][1], "org.example.Steam")
            compare(exited.signalArguments[0][3], "quit")
            tryVerify(() => Session.running.length === 1)
            compare(Session.running[0].instance, steam)
            Session.mockEndChild(steam)
            wait(50)
            compare(exited.count, 1, "endChild ends children only")

            // Stop on the parent stops its children first.
            const second = Session.mockStartChild(steam, "steam:80")
            verify(second !== "")
            tryVerify(() => Session.running.length === 2)
            Session.stop(steam)
            tryCompare(exited, "count", 3)
            compare(exited.signalArguments[1][0], second)
            compare(exited.signalArguments[2][0], steam)
            compare(Session.mockCalls(), ["stop " + second, "stop " + steam])
            tryVerify(() => Session.running.length === 0)
        }

        // Kill on a parent kills its children first (ADR-041, lead decision on RUY-1051).
        function test_mock_kill_ends_children_first() {
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            const steam = launchOk("org.example.Steam", "p2")
            tryVerify(() => Session.instanceOf("org.example.Steam", "p2").state === "running")
            const game = Session.mockStartChild(steam, "steam:70")
            verify(game !== "")
            tryVerify(() => Session.running.length === 2)
            Session.kill(steam)
            tryCompare(exited, "count", 2)
            compare(exited.signalArguments[0][0], game)
            compare(exited.signalArguments[0][3], "killed")
            compare(exited.signalArguments[1][0], steam)
            compare(Session.mockCalls(), ["kill " + game, "kill " + steam])
            tryVerify(() => Session.running.length === 0)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
        }

        // Freeze and Thaw (T-457), as ruya-session answers them: a running app of the signed-in
        // profile only, a second freeze changes nothing, a stop thaws a frozen app first.
        function freezeStatus(instance) {
            const n = freezeSpy.count
            Session.freeze(instance)
            tryCompare(freezeSpy, "count", n + 1)
            compare(freezeSpy.signalArguments[n][0], instance)
            return freezeSpy.signalArguments[n][1]
        }

        function test_freeze_and_thaw() {
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            const mine = launchOk("org.example.Racer", "p2")
            const theirs = launchOk("org.example.Racer", "p1")
            compare(freezeStatus(mine), "not-running", "still starting")
            tryVerify(() => Session.instanceOf("org.example.Racer", "p2").state === "running")
            tryVerify(() => Session.instanceOf("org.example.Racer", "p1").state === "running")
            compare(freezeStatus(""), "invalid")
            compare(freezeStatus("no-such-instance"), "not-running")
            compare(freezeStatus(theirs), "not-allowed", "another profile's app")
            compare(freezeStatus(mine), "ok")
            tryVerify(() => Session.instanceOf("org.example.Racer", "p2").frozen === true)
            compare(freezeStatus(mine), "ok", "a second freeze is ok")
            compare(Session.mockCalls(), ["freeze " + mine], "and does nothing")
            verify(!Session.instanceOf("org.example.Racer", "p1").frozen)

            Session.thaw(mine)
            tryCompare(thawSpy, "count", 1)
            compare(thawSpy.signalArguments[0][1], "ok")
            tryVerify(() => Session.instanceOf("org.example.Racer", "p2").frozen === false)

            compare(freezeStatus(mine), "ok")
            tryVerify(() => Session.instanceOf("org.example.Racer", "p2").frozen === true)
            Session.stop(mine)
            tryCompare(exited, "count", 1)
            compare(exited.signalArguments[0][3], "quit")
            compare(Session.mockCalls(), ["freeze " + mine, "thaw " + mine, "freeze " + mine,
                                          "thaw " + mine, "stop " + mine], "a stop thaws first")
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
        }

        function test_crash_toast() {
            const shell = createTemporaryObject(shellComponent, host)
            verify(shell)
            const shown = Notifications.shownCount

            // A normal quit: no toast.
            const instance = launchOk("org.example.Chess", "p1")
            tryVerify(() => Session.instanceOf("org.example.Chess", "p1").state === "running")
            Session.stop(instance)
            tryCompare(exited, "count", 1)
            wait(50)
            compare(Notifications.shownCount, shown)

            // A crash: exactly one toast, reason "crashed".
            launchOk("crashy", "p1")
            tryCompare(exited, "count", 2)
            compare(exited.signalArguments[1][1], "crashy")
            compare(exited.signalArguments[1][2], 139)
            compare(exited.signalArguments[1][3], "crashed")
            tryCompare(Notifications, "shownCount", shown + 1)
            wait(50)
            compare(Notifications.shownCount, shown + 1)
            compare(Notifications.model.get(Notifications.model.count - 1).text, "crashy stopped unexpectedly")
            tryVerify(() => Session.running.length === 0)

            // Never reached running: one toast, reason "launch-failed", no AppStarted.
            const started = Session.running.length
            launchOk("nolaunch", "p1")
            tryCompare(exited, "count", 3)
            compare(exited.signalArguments[2][1], "nolaunch")
            compare(exited.signalArguments[2][2], -1)
            compare(exited.signalArguments[2][3], "launch-failed")
            tryCompare(Notifications, "shownCount", shown + 2)
            wait(50)
            compare(Notifications.shownCount, shown + 2)
            compare(Notifications.model.get(Notifications.model.count - 1).text, "nolaunch could not start")
            tryVerify(() => Session.running.length === started)
        }
    }
}
