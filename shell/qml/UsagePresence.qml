import QtQuick
import RuyaShell

// Tells the play ledger of ruya-session who is in front (T-247, Session1.ReportPresence): the
// foreground app's instance ("" while the shell itself is in front) and whether the person is
// there: "active", "idle" (no input for `idleSeconds`) or "locked" (nobody signed in). It reports
// on every change and every 20 s, because the service ignores a report older than 75 s. The
// service does the counting; this object only says what it sees.
//
// The idle clock here is the simple one of this task (the time since the last input the window
// saw); T-202's single idle clock replaces it. The first `idleSeconds` of silence still count: the
// shell cannot know yet that nobody is there.
QtObject {
    id: reporter

    property bool signedIn: false
    // The instance of the app in front; "" when no app is, or the Guide overlay is open.
    property string instance: ""
    property int idleSeconds: 600
    property bool idle: false
    property double lastInputMs: Date.now()
    // Replaced in tests.
    property var now: () => Date.now()

    readonly property string attention: !signedIn ? "locked" : idle ? "idle" : "active"

    function noteInput() {
        lastInputMs = now()
        if (idle)
            idle = false
    }

    function check() {
        idle = (now() - lastInputMs) >= idleSeconds * 1000
    }

    function report() {
        Usage.reportPresence(instance, attention)
    }

    onInstanceChanged: report()
    onAttentionChanged: report()
    Component.onCompleted: report()

    property Timer beat: Timer {
        objectName: "presenceBeat"
        interval: 20000        // the service's report period (api/dbus Session1)
        repeat: true
        running: true
        onTriggered: reporter.report()
    }

    property Timer idleCheck: Timer {
        objectName: "presenceIdleCheck"
        interval: 5000         // how often the idle rule is evaluated
        repeat: true
        running: true
        onTriggered: reporter.check()
    }
}
