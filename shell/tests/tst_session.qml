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
    SignalSpy { id: stopped; target: Session; signalName: "stopFinished" }
    SignalSpy { id: exited; target: Session; signalName: "appExited" }

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
            stopped.clear()
            exited.clear()
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
            compare(Notifications.model.get(Notifications.model.count - 1).text, "nolaunch stopped unexpectedly")
            tryVerify(() => Session.running.length === started)
        }
    }
}
