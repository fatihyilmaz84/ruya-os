pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Network: the status row (what the console is connected through), the Wi-Fi
// networks in range and a rescan row. Accept on a network joins it: open and saved ones at
// once, a new WPA one after a masked password entry, an enterprise one is refused by the
// service ("unsupported"). A saved network also has an Options menu (RUY-1177, 02 §1.7: Start
// or a held A; `Page.surfaceOptions` is `surfaceOptions` below): Connect (not the one in use)
// and Forget…, which has no confirmation. Everything goes through the
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
            passwordSlot.active = true
            passwordEntry.open(qsTr("Password for %1").arg(ssid), "", { mask: true, layout: "text" })
            return
        }
        Network.connectWifi(id, "")      // open, saved, or enterprise (the service refuses it)
    }

    Connections {
        target: Network
        function onConnectFinished(id, status) {
            if (status !== "ok") {
                Notifications.show(pane.statusText(status), "warning")
            }
        }
        function onForgetFinished(id, status) {
            if (status !== "ok") {
                Notifications.show(qsTr("Could not forget the network."), "warning")
            }
        }
        function onNetworksChanged() { pane.syncNetworks() }
    }

    SettingRow {
        objectName: "rowNetStatus"
        kind: "info"
        u: pane.u
        label: Network.primary.kind === "ethernet" ? qsTr("Wired connection")
             : Network.primary.name ?? qsTr("Network")
        value: pane.stateText(Network.state)
    }

    GroupLabel {
        objectName: "wifiGroupLabel"
        u: pane.u
        visible: wifiModel.count > 0
        text: qsTr("Wi-Fi networks")
    }

    Repeater {
        id: wifiRepeater
        model: wifiModel
        SettingRow {
            id: wifiRow
            required property string netId
            required property string ssid
            required property int signal
            required property string security
            required property bool known
            required property bool active
            objectName: "wifi_" + netId
            kind: "item"
            current: active
            // A saved network has a main action (A connects) and a menu (Start, or a held A): Forget. A new one has no menu.
            hasOptions: known
            acceptVerb: qsTr("Connect")
            anchored: pane.optionsOpenFor === netId
            u: pane.u
            label: ssid
            value: pane.wifiValue(active, known, security, signal)
            onActivated: pane.join(netId, ssid, security, known)
            onOptionsRequested: pane.optionsRequested("network", netId, wifiRow)
        }
    }

    SettingRow {
        objectName: "rowScan"
        kind: "action"
        u: pane.u
        label: qsTr("Scan for networks")
        onActivated: Network.scan()
    }

    // ---- A saved network's Options menu (RUY-1177): Page.surfaceOptions, rows read live from Network.networks ----
    function networkById(id) {
        return Network.networks.find(n => n.id === id)
    }

    // Connect (not the one in use) and, after a divider, Forget. There is no Disconnect: the service has none.
    function networkOptionRows(id) {
        const n = networkById(id)
        if (!n || !n.known)
            return []
        const rows = []
        if (!n.active)
            rows.push({ id: "connect", label: qsTr("Connect"), icon: "link" })
        rows.push({ id: "forget", label: qsTr("Forget…"), icon: "delete", divider: rows.length > 0 })
        return rows
    }

    function runNetworkOption(id, action) {
        const n = networkById(id)
        if (!n)
            return
        if (action === "connect")
            pane.join(id, n.ssid, n.security, n.known)
        else if (action === "forget")
            Network.forget(id)
    }

    surfaceOptions: ({
        rows: id => pane.networkOptionRows(id),
        title: id => pane.networkById(id)?.ssid ?? "",
        note: id => "",
        run: (id, action) => pane.runNetworkOption(id, action),
        // Gone from the scan list, or forgotten: the menu closes and the focus settles on a row.
        exists: id => pane.networkById(id)?.known === true
    })

    // The password keyboard, built when it first opens (T-349).
    Loader {
        id: passwordSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            TextEntry {
                objectName: "wifiPasswordEntry"
                u: pane.u
                onAccepted: text => Network.connectWifi(pane.pendingId, text)
            }
        }
    }
    readonly property TextEntry passwordEntry: passwordSlot.item as TextEntry
}
