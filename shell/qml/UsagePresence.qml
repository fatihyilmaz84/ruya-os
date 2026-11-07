import QtQuick
import RuyaShell

// Tells the play ledger of ruya-session who is in front (T-247, Session1.ReportPresence): the
// foreground app's instance ("" while the shell itself is in front) and whether the person is
// there: "active", "idle" (no input for `idleSeconds`) or "locked" (nobody signed in). It reports
// on every change and every 20 s, because the service ignores a report older than 75 s. The
// service does the counting; this object only says what it sees.
//
// Idle is read from the console's one idle clock (T-202, IdleClock): the time without input where
// something holding the console awake counts as presence, so a game or a film that asked for the
// screen to stay on (Wayland idle-inhibit) keeps counting however long the pad is not touched.
// What the shell cannot see are buttons it does not map (triggers, X/Y, the right stick) in an app
// that does not ask for the screen; those do not reset the clock.
QtObject {
    id: reporter

    property bool signedIn: false
    // The instance of the app in front; "" when no app is, or the Guide overlay is open.
    property string instance: ""
    property int idleSeconds: 600
    property bool idle: false

    readonly property string attention: !signedIn ? "locked" : idle ? "idle" : "active"

    // Input ended the silence, or the check timer is due.
    function check() {
        idle = IdleClock.sample() >= idleSeconds
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
