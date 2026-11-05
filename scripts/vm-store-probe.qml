// Run by vm-store-check.sh as ruya-shell (`ruya-shell --load`, offscreen): the shell's own Store
// singleton, with its D-Bus backend, prints what it reads from ruya-store. T-134.
import QtQuick
import RuyaShell

QtObject {
    id: root

    // Set by vm-store-check.sh for the restart test (T-171, a copy with the id filled in): the
    // probe's own Store starts this install, so the shell's D-Bus backend owns the job (it
    // ignores jobs it didn't start itself).
    property string installApp: ""
    property bool installRequested: false

    function maybeInstall() {
        if (installApp === "" || installRequested || !Store.available)
            return;
        if (!Store.catalogue.some(a => a.id === installApp))
            return;
        installRequested = true;
        console.warn("store-probe: install requested " + installApp);
        Store.install(installApp);
    }

    property Timer ticker: Timer {
        interval: 2000
        running: true
        repeat: true
        onTriggered: {
            const ids = Store.catalogue.map(a => a.id + (a.installed ? "(installed)" : ""));
            console.warn("store-probe: mock=" + Store.mock + " available=" + Store.available
                + " catalogue=" + Store.catalogue.length + " installed=" + Store.installed.length
                + " jobs=" + JSON.stringify(Store.jobs) + " t=" + new Date().toISOString().substr(11, 8) + " apps=" + ids.join(","));
            root.maybeInstall();
        }
    }

    property Connections events: Connections {
        target: Store
        function onJobFinished(id, status) {
            console.warn("store-probe: jobFinished " + id + " " + status);
        }
        // Logged at once (not on the 2 s tick), so the script can restart the service while the
        // job is known to be in Store.jobs.
        function onJobsChanged() {
            console.warn("store-probe: jobsChanged " + JSON.stringify(Store.jobs));
        }
        // T-188: the service's job table was applied (once at start, once per new service owner).
        function onJobsReconciled() {
            console.warn("store-probe: jobsReconciled jobs=" + JSON.stringify(Store.jobs));
        }
        function onCatalogueChanged() {
            root.maybeInstall();
        }
    }
}
