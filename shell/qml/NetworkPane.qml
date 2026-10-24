pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Network: the status row (what the console is connected through), the Wi-Fi
// networks in range, a rescan row, and a "Forget" row for each saved network. Accept on a
// network joins it: open and saved ones at once, a new WPA one after a masked password entry,
// an enterprise one is refused by the service ("unsupported"). Everything goes through the
// Network singleton (org.ruyaos.Devices1.Network).
SettingsPane {
    id: pane

    // Full-screen layer for the password entry (the Settings page's modal layer).
    property Item overlay

    property string pendingId     // the network the password entry is for
    property string pendingName

    // Rows follow Network.networks by id (updated in place), so focus stays on a row when the
    // list is re-published, e.g. after joining a network.
    ListModel { id: wifiModel }

    function syncNetworks() {
        const list = Network.networks
        for (let i = wifiModel.count - 1; i >= 0; --i) {
            const id = wifiModel.get(i).netId
            if (!list.some(n => n.id === id))
                wifiModel.remove(i)
        }
        for (let i = 0; i < list.length; ++i) {
            const n = list[i]
            const entry = { netId: n.id, ssid: n.ssid, signal: n.signal, security: n.security,
                            known: n.known, active: n.active }
            let at = -1
            for (let j = 0; j < wifiModel.count; ++j) {
                if (wifiModel.get(j).netId === n.id) {
                    at = j
                    break
                }
            }
            if (at < 0) {
                wifiModel.insert(i, entry)
            } else {
                wifiModel.set(at, entry)
                if (at !== i)
                    wifiModel.move(at, i, 1)
            }
        }
        Qt.callLater(pane.settleFocus)   // the focused row may have gone (a forgotten network)
    }

    // The first network is where focus lands when the pane is first entered; the status row
    // above it is read-only information, not a stop.
    Component.onCompleted: {
        syncNetworks()
        const first = wifiRepeater.itemAt(0)
        if (first)
            first.focus = true
    }

    // The single mapping from a service status to text.
    function statusText(status) {
        switch (status) {
        case "wrong-password": return qsTr("Wrong password.")
        case "unsupported": return qsTr("Enterprise networks are not supported.")
        case "unknown-network": return qsTr("That network is no longer available.")
        case "invalid": return qsTr("Enter the password.")
        }
        return qsTr("Could not connect.")
    }

    function stateText(state) {
        switch (state) {
        case "connected": return qsTr("Connected")
        case "connecting": return qsTr("Connecting")
        case "limited": return qsTr("No internet")
        }
        return qsTr("Not connected")
    }

    function securityText(security) {
        return security === "open" ? qsTr("Open") : security === "enterprise" ? qsTr("Enterprise") : qsTr("Secured")
    }

    function wifiValue(active, known, security, signal) {
        const parts = []
        if (active)
            parts.push(qsTr("Connected"))
        else if (known)
            parts.push(qsTr("Saved"))
        parts.push(pane.securityText(security))
        parts.push(qsTr("%1%").arg(signal))
        return parts.join(" · ")
    }

    function join(id, ssid, security, known) {
        if (security === "wpa-psk" && !known) {
            pendingId = id
            pendingName = ssid
            passwordEntry.open(qsTr("Password for %1").arg(ssid), "", { mask: true, layout: "text" })
            return
        }
        Network.connectWifi(id, "")      // open, saved, or enterprise (the service refuses it)
    }

    Connections {
        target: Network
        function onConnectFinished(id, status) {
            if (status !== "ok") {
                Sfx.back()
                Notifications.show(pane.statusText(status), "warning")
            }
        }
        function onForgetFinished(id, status) {
            if (status !== "ok") {
                Sfx.back()
                Notifications.show(qsTr("Could not forget the network."), "warning")
            }
        }
        function onNetworksChanged() { pane.syncNetworks() }
    }

    SettingRow {
        objectName: "rowNetStatus"
        u: pane.u
        label: Network.primary.kind === "ethernet" ? qsTr("Wired connection")
             : Network.primary.name ?? qsTr("Network")
        value: pane.stateText(Network.state)
    }

    Repeater {
        id: wifiRepeater
        model: wifiModel
        SettingRow {
            required property string netId
            required property string ssid
            required property int signal
            required property string security
            required property bool known
            required property bool active
            objectName: "wifi_" + netId
            u: pane.u
            label: ssid
            value: pane.wifiValue(active, known, security, signal)
            onActivated: pane.join(netId, ssid, security, known)
        }
    }

    SettingRow {
        objectName: "rowScan"
        u: pane.u
        label: qsTr("Scan for networks")
        onActivated: Network.scan()
    }

    Repeater {
        model: wifiModel
        SettingRow {
            required property string netId
            required property string ssid
            required property bool known
            objectName: "forget_" + netId
            visible: known
            u: pane.u
            label: qsTr("Forget %1").arg(ssid)
            onActivated: Network.forget(netId)
        }
    }

    TextEntry {
        id: passwordEntry
        objectName: "wifiPasswordEntry"
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: pane.u
        onAccepted: text => Network.connectWifi(pane.pendingId, text)
    }
}
