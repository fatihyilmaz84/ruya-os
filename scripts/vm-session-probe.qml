// Run by vm-session-check.sh as ruya-shell (`ruya-shell --load`, offscreen): the shell's own
// Session singleton, with its D-Bus backend, prints what it reads from ruya-session. T-162.
import QtQuick
import RuyaShell

QtObject {
    id: root

    property Timer ticker: Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            const apps = Session.running.map(r => r.appId + "/" + r.profile + "/" + r.state);
            console.warn("session-probe: mock=" + Session.mock + " running=" + apps.join(","));
        }
    }

    property Connections events: Connections {
        target: Session
        function onAppStarted(instance, appId) {
            console.warn("session-probe: appStarted " + appId);
        }
        function onAppExited(instance, appId, exitCode, reason) {
            console.warn("session-probe: appExited " + appId + " " + exitCode + " " + reason);
        }
    }
}
