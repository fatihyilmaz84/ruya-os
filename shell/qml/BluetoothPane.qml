pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Bluetooth & controllers: the power switch, "Add a device" (a scan), "Pair a new
// controller" (the guided screen, ControllerOnboarding, T-260), the devices found or paired, and for
// each paired one a "Forget" row (after a confirmation that names it) and, for a controller, a
// "Rename" row (the on-screen keyboard; BlueZ keeps the name). Accept on a device pairs it (not
// paired), connects it (paired) or disconnects it (connected). A controller says "Connected",
// "Reconnects automatically" (paired and trusted, not connected: it comes back when switched on) or
// "Paired". A paired device that is not bonded (it forgot its keys: it only reconnects in pairing
// mode, T-300) says "Not fully paired" and has a "Pair again" row: Forget, a scan, then Pair as soon
// as it is found again (put it in pairing mode first). With Bluetooth off the pane says so and shows nothing else. Everything goes through
// the Bluetooth singleton (org.ruyaos.Devices1.Bluetooth).
SettingsPane {
    id: pane

    property string busyId     // the device being paired, "" if none
    property Item overlay      // where the pairing screen, the keyboard and the confirmation are parented

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
            const entry = { devId: d.id, name: d.name, shown: DeviceIcons.shownName(list, d), kind: d.kind, family: d.family ?? "", paired: d.paired,
                            bonded: d.bonded ?? true, connected: d.connected, trusted: d.trusted ?? false, battery: d.battery }
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
        if (!visible && onboarding && onboarding.shown)
            onboarding.close()                  // closes its pairing window with it
    }

    // Focus is never lost to a modal that went away: back to the row that opened it.
    property Item modalReturn: null
    function beginModal() { modalReturn = Window.activeFocusItem }
    function restoreFocus() {
        const target = modalReturn
        modalReturn = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        Qt.callLater(pane.ensureFocusedVisible)
    }

    // The device the confirmation and the keyboard are for.
    property string forgetId: ""
    property string renameId: ""

    function askForget(id, name) {
        forgetSlot.active = true
        forgetConfirm.customTitle = qsTr("Forget %1?").arg(name)
        forgetConfirm.detail = qsTr("It will have to be paired again to be used.")
        forgetConfirm.customConfirmName = qsTr("Forget %1").arg(name)
        pane.forgetId = id
        forgetConfirm.open("custom")
    }

    // `shown`: the name the row shows (two like pads are told apart by the end of the address), the
    // keyboard's title; `name` is the pad's alias, what the field starts with.
    function askRename(id, name, shown) {
        pane.renameId = id
        renameSlot.active = true
        // The part of the shown name that is the end of the address stays whole when the title is cut.
        const base = DeviceIcons.plain(name)
        renameEntry.open(shown, name, { maxLength: 48, layout: "text", titleTail: shown.startsWith(base) ? shown.slice(base.length) : "" })
    }

    // The words for a failed operation: the one mapping the pairing screen shares (T-301).
    function statusText(op, status) {
        return BluetoothText.statusText(op, status, "device")
    }

    // "Pair again" (a paired device that is not bonded): the device being repaired, "" if none. Forget
    // first; when it is gone a scan finds it again (it has to be in pairing mode) and it is paired.
    property string repairId: ""
    property bool repairScanSeen: false

    function startRepair(id) {
        if (repairId !== "" || id === busyId)
            return
        repairId = id
        repairScanSeen = false
        busyId = id
        Bluetooth.forget(id)
    }

    function endRepair() {
        repairId = ""
        repairScanSeen = false
        busyId = ""
    }

    // Called when the list or the scan changed during a repair.
    function continueRepair() {
        if (repairId === "")
            return
        if (!Bluetooth.powered) {
            endRepair()                        // Bluetooth was switched off under it
            return
        }
        const d = Bluetooth.devices.find(x => x.id === repairId)
        if (d && !d.paired) {
            const id = repairId
            repairId = ""                      // the pair call below is an ordinary pairing now
            repairScanSeen = false
            Bluetooth.pair(id)
        } else if (repairScanSeen && !Bluetooth.discovering) {
            endRepair()                        // the scan ended and it was not found
            Notifications.show(qsTr("Could not find it. Put the device in pairing mode and try again."), "warning")
        } else if (Bluetooth.discovering) {
            repairScanSeen = true
        }
    }

    function deviceValue(busy, paired, bonded, connected, battery, kind, trusted) {
        if (busy)
            return qsTr("Pairing…")
        if (!paired)
            return qsTr("Not paired")
        if (!bonded)
            return qsTr("Not fully paired")
        // A paired, trusted controller that is off comes back by itself when it is switched on.
        const idle = kind === "controller" && trusted ? qsTr("Reconnects automatically") : qsTr("Paired")
        const parts = [connected ? qsTr("Connected") : idle]
        if (connected && battery >= 0)
            parts.push(qsTr("Battery %1%").arg(battery))
        return parts.join(" · ")
    }

    function activate(id, paired, connected) {
        if (id === busyId)
            return                         // already pairing: a second Accept or a key repeat does nothing
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
            if (op === "forget" && id === pane.repairId) {
                if (status !== "ok") {
                    pane.endRepair()
                    Notifications.show(BluetoothText.statusText("pair", status, "device"), "warning")
                    return
                }
                Bluetooth.startScan()          // the device is gone from the list: find it again
                return
            }
            if (op === "scan" && status !== "ok" && pane.repairId !== "") {
                pane.endRepair()               // the scan that should find it again did not start
                Notifications.show(BluetoothText.statusText("pair", status, "device"), "warning")
                return
            }
            if (op === "power") {
                power.checked = Bluetooth.powered      // a refused switch springs back
                return
            }
            if (op === "controller-pairing" && status !== "ok" && status !== "busy") {
                Notifications.show(status === "unavailable" ? qsTr("Bluetooth is off.")
                                                            : qsTr("Could not start looking for controllers."), "warning")
                return
            }
            if (op === "rename" && status !== "ok") {
                Notifications.show(status === "invalid" ? qsTr("That name does not work. Try another.")
                                                          : qsTr("Could not rename the controller."), "warning")
                return
            }
            if (op === "forget" || op === "scan" || op === "controller-pairing" || status === "ok")
                return
            Notifications.show(pane.statusText(op, status), "warning")
        }
        function onControllerRejected() {
            if (pane.visible)
                Notifications.show(qsTr("A device that is not a controller was ignored."), "info")
        }
        function onDevicesChanged() {
            pane.syncDevices()
            pane.continueRepair()
        }
        function onStateChanged() {
            power.checked = Bluetooth.powered
            pane.continueRepair()
        }
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
        objectName: "rowBtPairController"
        visible: Bluetooth.powered
        u: pane.u
        label: qsTr("Pair a new controller")
        onActivated: {
            pane.beginModal()
            onboardingSlot.active = true
            pane.onboarding.open()
        }
    }

    // The pairing screen, the keyboard and the confirmation are built when each first opens (T-349).
    Loader {
        id: onboardingSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            ControllerOnboarding {
                objectName: "controllerOnboarding"
                u: pane.u
                onClosed: pane.restoreFocus()
            }
        }
    }
    readonly property ControllerOnboarding onboarding: onboardingSlot.item as ControllerOnboarding

    Loader {
        id: renameSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            TextEntry {
                objectName: "btRenameEntry"
                u: pane.u
                onAccepted: text => Bluetooth.rename(pane.renameId, text)
            }
        }
    }
    readonly property TextEntry renameEntry: renameSlot.item as TextEntry

    Loader {
        id: forgetSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            PowerConfirm {
                objectName: "btForgetConfirm"
                u: pane.u
                onConfirmed: Bluetooth.forget(pane.forgetId)
            }
        }
    }
    readonly property PowerConfirm forgetConfirm: forgetSlot.item as PowerConfirm

    Repeater {
        model: deviceModel
        SettingRow {
            required property string devId
            required property string name
            required property string shown
            required property string kind
            required property string family
            required property bool paired
            required property bool bonded
            required property bool connected
            required property bool trusted
            required property int battery
            objectName: "btDev_" + devId
            visible: Bluetooth.powered
            u: pane.u
            label: shown
            iconName: DeviceIcons.iconFor(kind, family)
            value: pane.deviceValue(pane.busyId === devId, paired, bonded, connected, battery, kind, trusted)
            // The screen reader says the name, what it is, then the state: "DualSense, PlayStation
            // controller, Connected".
            accessibleValue: DeviceIcons.kindText(kind, family) + ", " + value
            onActivated: pane.activate(devId, paired, connected)
        }
    }

    Repeater {
        model: deviceModel
        SettingRow {
            required property string devId
            required property string shown
            required property bool paired
            required property bool bonded
            objectName: "btRepair_" + devId
            visible: paired && !bonded && Bluetooth.powered
            u: pane.u
            label: qsTr("Pair again %1").arg(shown)
            value: qsTr("Put it in pairing mode first")
            onActivated: pane.startRepair(devId)
        }
    }

    Repeater {
        model: deviceModel
        SettingRow {
            required property string devId
            required property string name
            required property string shown
            required property string kind
            required property bool paired
            objectName: "btRename_" + devId
            visible: paired && kind === "controller" && Bluetooth.powered
            u: pane.u
            label: qsTr("Rename %1").arg(shown)
            onActivated: pane.askRename(devId, name, shown)
        }
    }

    Repeater {
        model: deviceModel
        SettingRow {
            required property string devId
            required property string shown
            required property bool paired
            objectName: "btForget_" + devId
            visible: paired && Bluetooth.powered
            u: pane.u
            label: qsTr("Forget %1").arg(shown)
            onActivated: pane.askForget(devId, shown)
        }
    }
}
