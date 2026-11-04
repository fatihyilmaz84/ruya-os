pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Bluetooth & controllers: the power switch, "Add a device" (a scan) with a hint on
// pairing mode, the devices found or paired, and a "Forget" row for each paired one. Accept on
// a device pairs it (not paired), connects it (paired) or disconnects it (connected). With
// Bluetooth off the pane says so and shows nothing else. Everything goes through the Bluetooth
// singleton (org.ruyaos.Devices1.Bluetooth).
SettingsPane {
    id: pane

    property string busyId     // the device being paired, "" if none

    // Rows follow Bluetooth.devices by id (updated in place), so focus stays on a row when the
    // list is re-published, e.g. after a device connects or its battery changes.
    ListModel { id: deviceModel }

    function syncDevices() {
        // Where focus is now, to put it on a neighbour if its row goes away (Forget).
        const before = pane.activeFocus ? focusableRows().findIndex(r => r.activeFocus) : -1
        const list = Bluetooth.devices
        for (let i = deviceModel.count - 1; i >= 0; --i) {
            const id = deviceModel.get(i).devId
            if (!list.some(d => d.id === id))
                deviceModel.remove(i)
        }
        for (let i = 0; i < list.length; ++i) {
            const d = list[i]
            const entry = { devId: d.id, name: d.name, paired: d.paired, connected: d.connected, battery: d.battery }
            let at = -1
            for (let j = 0; j < deviceModel.count; ++j) {
                if (deviceModel.get(j).devId === d.id) {
                    at = j
                    break
                }
            }
            if (at < 0) {
                deviceModel.insert(i, entry)
            } else {
                deviceModel.set(at, entry)
                if (at !== i)
                    deviceModel.move(at, i, 1)
            }
        }
        Qt.callLater(pane.refocus, before)
    }

    // After a list update: if the focused row vanished, focus the row now at its place (or the
    // last one).
    function refocus(index) {
        if (!pane.activeFocus || index < 0)
            return
        const rows = focusableRows()
        if (rows.length > 0 && !rows.some(r => r.activeFocus))
            rows[Math.min(index, rows.length - 1)].forceActiveFocus()
        ensureFocusedVisible()
    }

    Component.onCompleted: syncDevices()

    onVisibleChanged: {
        if (!visible && Bluetooth.discovering)
            Bluetooth.stopScan()
    }

    // The single mapping from a service status to text.
    function statusText(op, status) {
        switch (status) {
        case "pairing-failed": return qsTr("Pairing failed. Put the device in pairing mode and try again.")
        case "timeout": return qsTr("The device did not answer.")
        case "unavailable": return qsTr("Bluetooth is off.")
        case "unknown-device": return qsTr("That device is no longer available.")
        }
        return op === "pair" ? qsTr("Could not pair the device.") : qsTr("Could not connect.")
    }

    function deviceValue(busy, paired, connected, battery) {
        if (busy)
            return qsTr("Pairing…")
        if (!paired)
            return qsTr("Not paired")
        const parts = [connected ? qsTr("Connected") : qsTr("Paired")]
        if (connected && battery >= 0)
            parts.push(qsTr("Battery %1%").arg(battery))
        return parts.join(" · ")
    }

    function activate(id, paired, connected) {
        if (!paired) {
            busyId = id
            Bluetooth.pair(id)
        } else if (connected) {
            Bluetooth.disconnectDevice(id)
        } else {
            Bluetooth.connectDevice(id)
        }
    }

    Connections {
        target: Bluetooth
        function onFinished(op, id, status) {
            if (op === "pair" && id === pane.busyId)
                pane.busyId = ""
            if (op === "power") {
                power.checked = Bluetooth.powered      // a refused switch springs back
                return
            }
            if (op === "forget" || op === "scan" || status === "ok")
                return
            Sfx.back()
            Notifications.show(pane.statusText(op, status), "warning")
        }
        function onDevicesChanged() { pane.syncDevices() }
        function onStateChanged() { power.checked = Bluetooth.powered }
    }

    ToggleRow {
        id: power
        objectName: "rowBtPower"
        u: pane.u
        label: qsTr("Bluetooth")
        checked: Bluetooth.powered
        onToggled: on => Bluetooth.setPowered(on)
    }

    SettingRow {
        objectName: "rowBtOff"
        visible: !Bluetooth.powered
        enabled: false                       // information, not a stop
        u: pane.u
        label: qsTr("Bluetooth is off")
    }

    SettingRow {
        objectName: "rowBtAdd"
        visible: Bluetooth.powered
        u: pane.u
        label: qsTr("Add a device")
        value: Bluetooth.discovering ? qsTr("Scanning…") : ""
        onActivated: Bluetooth.startScan()
    }

    SettingRow {
        objectName: "rowBtHint"
        visible: Bluetooth.powered
        enabled: false
        u: pane.u
        label: qsTr("Controller: hold its pairing button until the light blinks")
    }

    Repeater {
        model: deviceModel
        SettingRow {
            required property string devId
            required property string name
            required property bool paired
            required property bool connected
            required property int battery
            objectName: "btDev_" + devId
            visible: Bluetooth.powered
            u: pane.u
            label: name
            value: pane.deviceValue(pane.busyId === devId, paired, connected, battery)
            onActivated: pane.activate(devId, paired, connected)
        }
    }

    Repeater {
        model: deviceModel
        SettingRow {
            required property string devId
            required property string name
            required property bool paired
            objectName: "btForget_" + devId
            visible: paired && Bluetooth.powered
            u: pane.u
            label: qsTr("Forget %1").arg(name)
            onActivated: Bluetooth.forget(devId)
        }
    }
}
