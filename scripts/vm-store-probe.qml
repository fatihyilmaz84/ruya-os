// Run by vm-store-check.sh as ruya-shell (`ruya-shell --load`, offscreen): the shell's own Store
// singleton, with its D-Bus backend, prints what it reads from ruya-store. T-134.
import QtQuick
import RuyaShell

QtObject {
    id: root

    property Timer ticker: Timer {
        interval: 2000
        running: true
        repeat: true
        onTriggered: {
            const ids = Store.catalogue.map(a => a.id + (a.installed ? "(installed)" : ""));
            console.warn("store-probe: mock=" + Store.mock + " available=" + Store.available
                + " catalogue=" + Store.catalogue.length + " installed=" + Store.installed.length
                + " jobs=" + JSON.stringify(Store.jobs) + " apps=" + ids.join(","));
        }
    }

    property Connections events: Connections {
        target: Store
        function onJobFinished(id, status) {
            console.warn("store-probe: jobFinished " + id + " " + status);
        }
    }
}
