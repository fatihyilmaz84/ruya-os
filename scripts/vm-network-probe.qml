// The shell's own Network singleton, with its D-Bus backend, prints what it reads from
// ruya-devices (T-132). Run in the VM as ruya-shell, offscreen:
//   runuser -u ruya-shell -- env XDG_RUNTIME_DIR=/run/user/$(id -u ruya-shell) QT_QPA_PLATFORM=offscreen \
//       QT_FORCE_STDERR_LOGGING=1 timeout 60 ruya-shell --load /var/tmp/vm-network-probe.qml
// console.warn, not console.log: the image filters debug output.
import QtQuick
import RuyaShell

QtObject {
    id: root

    property Timer ticker: Timer {
        interval: 2000
        running: true
        repeat: true
        onTriggered: {
            console.warn("net-probe: " + new Date().toISOString().substr(11, 8) + " mock=" + Network.mock
                + " state=" + Network.state + " primary=" + JSON.stringify(Network.primary));
        }
    }

    property Connections events: Connections {
        target: Network
        function onStateChanged() {
            console.warn("net-probe: " + new Date().toISOString().substr(11, 8) + " stateChanged " + Network.state);
        }
    }
}
