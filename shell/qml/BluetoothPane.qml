pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Bluetooth (the controllers themselves: ControllersPane, RUY-39): the power switch, "Add a device" (a scan), "Pair a new
// controller" (the guided screen, ControllerOnboarding, T-260) and the devices found or paired. Accept on a device
// that is not paired pairs it (a keyboard asks first). Accept on a paired one opens its Options menu (RUY-1176, 02 §1.7:
// several actions and none main; `Page.surfaceOptions` is `surfaceOptions` below): "Pair again" (it is not bonded, T-300: it
// forgot its keys and only reconnects in pairing mode: Forget, a scan, then Pair as soon as it is found again; first
// row and focused), Connect or Disconnect, "Controller settings" (a connected pad: its page), "Rename…" (a controller:
// the on-screen keyboard; BlueZ keeps the name) and, after a divider, "Forget…" (a confirmation that names it). A
// controller says "Connected", "Reconnects automatically" (paired and trusted, not connected: it comes back when
// switched on) or "Paired"; a device that is not bonded says "Not fully paired" in `warningText`. With Bluetooth off the pane says
// so and shows nothing else. Everything goes through the Bluetooth singleton (org.ruyaos.Devices1.Bluetooth).
SettingsPane {
    id: pane

    property string busyId     // the device being paired, "" if none
    property Item overlay      // where the pairing screen, the keyboard and the confirmation are parented

    // "Controller settings" in a device's menu: the Settings page opens that pad's page.
    signal controllerRequested(string id)

    // Rows follow Bluetooth.devices by id (updated in place), so focus stays on a row when the
    // list is re-published, e.g. after a device connects or its battery changes.
    ListModel { id: deviceModel }

    function syncDevices() {
        // Where focus is now, to put it on a neighbour if its row goes away (Forget, or a device that leaves while its menu is open).
        const before = pane.focusedRowIndex()
        const list = Bluetooth.devices
        for (let i = deviceModel.count - 1; i >= 0; --i) {
            const id = deviceModel.get(i).devId
            if (!list.some(d => d.id === id))
                deviceModel.remove(i)
        }
        for (let i = 0; i < list.length; ++i) {
            const d = list[i]
            const entry = { devId: d.id, name: d.name, shown: DeviceIcons.shownName(list, d), shownBase: DeviceIcons.shownParts(list, d).name,
                            shownTail: DeviceIcons.shownParts(list, d).tail, deviceKind: d.kind, family: d.family ?? "", silhouette: d.model ?? "", paired: d.paired,
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
        // The keyboard confirmation's device left the list: close it, focus goes back to the list.
        if (pane.keyboardId !== "" && keyboardSlot.active && keyboardConfirm.shown && !list.some(d => d.id === pane.keyboardId)) {
            keyboardConfirm.cancel()
            pane.keyboardId = ""
            if (!pane.focusableRows().some(r => r.activeFocus))
                pane.focusableRows()[0]?.forceActiveFocus()
        }
        Qt.callLater(pane.refocusNear, before)
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
            if (d.keyboard === true)
                askKeyboard(id, d.name)        // a keyboard always asks, a repair included
            else
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

    // keyboardConfirmed: only the keyboard question's Accept says true (RUY-422); the service refuses
    // a keyboard-class device without it.
    function startPairing(id, keyboardConfirmed) {
        busyId = id
        Bluetooth.pair(id, keyboardConfirmed === true)
    }

    // "This is a keyboard. Pair it?": Cancel has focus, Back cancels, Accept on "Pair <name>" pairs.
    property string keyboardId: ""

    function askKeyboard(id, name) {
        keyboardSlot.active = true
        keyboardConfirm.customTitle = qsTr("This is a keyboard. Pair it?")
        keyboardConfirm.detail = qsTr("%1 could type anywhere on this console.").arg(name)
        keyboardConfirm.customConfirmName = qsTr("Pair %1").arg(name)
        pane.keyboardId = id
        keyboardConfirm.open("custom")
    }

    // Accept on a device that is not paired (a paired one opens its menu): pair it, a keyboard after its question.
    function pairDevice(id) {
        if (id === busyId)
            return                         // already pairing: a second Accept or a key repeat does nothing
        const dev = Bluetooth.devices.find(d => d.id === id)
        if (dev && dev.keyboard === true)
            askKeyboard(id, dev.name)      // a keyboard types anywhere: a second confirmation (RUY-411)
        else
            startPairing(id)
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
                Notifications.show(status === "unavailable" ? BluetoothText.unavailableText()
                                                            : qsTr("Could not start looking for controllers."), "warning")
                return
            }
            if (op === "rename")
                return                         // BluetoothDeviceActions toasts a failure
            if (op === "connect" && status === "not-confirmed") {
                const dev = Bluetooth.devices.find(d => d.id === id)
                if (dev)
                    pane.askKeyboard(id, dev.name)     // the service refused: ask the question, then Pair
                return
            }
            if (op === "forget" || op === "scan" || op === "controller-pairing" || status === "ok")
                return
            Notifications.show(pane.statusText(op, status), "warning")
        }
        function onControllerRejected() {
            if (pane.visible)
                Notifications.show(qsTr("Another device tried to pair and was turned away."), "info")
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
        kind: "info"
        visible: !Bluetooth.powered
        enabled: false                       // information, not a stop
        u: pane.u
        label: qsTr("Bluetooth is off")
    }

    SettingRow {
        objectName: "rowBtAdd"
        kind: "action"
        visible: Bluetooth.powered
        u: pane.u
        label: qsTr("Add a device")
        value: Bluetooth.discovering ? qsTr("Scanning…") : ""
        onActivated: Bluetooth.startScan()
    }

    SettingRow {
        objectName: "rowBtPairController"
        kind: "action"
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

    BluetoothDeviceActions {
        id: deviceActions
        u: pane.u
        overlay: pane.overlay
    }
    Loader {
        id: keyboardSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            PowerConfirm {
                objectName: "btKeyboardConfirm"
                customDestructive: false
                u: pane.u
                onConfirmed: pane.startPairing(pane.keyboardId, true)
            }
        }
    }
    readonly property PowerConfirm keyboardConfirm: keyboardSlot.item as PowerConfirm

    Repeater {
        model: deviceModel
        SettingRow {
            id: deviceRow
            required property string devId
            required property string name
            required property string shown
            required property string shownBase
            required property string shownTail
            required property string deviceKind
            required property string family
            required property string silhouette   // the controller model (not `model`: a delegate has one)
            required property bool paired
            required property bool bonded
            required property bool connected
            required property bool trusted
            required property int battery
            objectName: "btDev_" + devId
            kind: "item"
            visible: Bluetooth.powered
            u: pane.u
            label: shownBase
            labelTail: shownTail
            iconName: DeviceIcons.iconFor(deviceKind, family, silhouette)
            value: pane.deviceValue(pane.busyId === devId, paired, bonded, connected, battery, deviceKind, trusted)
            // A device that must be paired again says so in the colour of a warning (02 §1.7, needs attention).
            valueColor: paired && !bonded && pane.busyId !== devId ? Theme.warningText : Theme.text
            // A paired device has several actions and none main: Accept opens its menu. One that is not paired has one: Pair.
            hasOptions: paired
            acceptOpensOptions: paired
            anchored: pane.optionsOpenFor === devId
            // The screen reader says the name, what it is, then the state: "DualSense, PlayStation
            // controller, Connected".
            accessibleValue: DeviceIcons.kindText(deviceKind, family, silhouette) + ", " + value
            onActivated: pane.pairDevice(devId)
            onOptionsRequested: pane.optionsRequested("bluetooth", devId, deviceRow)
        }
    }

    // ---- A paired device's Options menu (RUY-1176): Page.surfaceOptions, rows built from the service's list ----
    function deviceById(id) {
        return Bluetooth.devices.find(d => d.id === id)
    }

    // The pad of Input1 that is this Bluetooth device, while it is connected (ControllerPads matches them).
    function padOf(id) {
        return ControllerPads.controllers().find(p => p.btId === id)
    }

    function deviceOptionRows(id) {
        const d = deviceById(id)
        if (!d || !d.paired)
            return []
        const rows = []
        if (d.bonded === false)
            rows.push({ id: "repair", label: qsTr("Pair again"), icon: "link" })
        rows.push(d.connected ? { id: "disconnect", label: qsTr("Disconnect"), icon: "link_off" }
                              : { id: "connect", label: qsTr("Connect"), icon: "link" })
        if (padOf(id))
            rows.push({ id: "settings", label: qsTr("Controller settings"), icon: "settings" })
        if (d.kind === "controller")
            rows.push({ id: "rename", label: qsTr("Rename…"), icon: "edit" })
        rows.push({ id: "forget", label: qsTr("Forget…"), icon: "delete", divider: true })
        return rows
    }

    function runDeviceOption(id, action) {
        const d = deviceById(id)
        if (!d)
            return
        switch (action) {
        case "repair":
            startRepair(id)
            break
        case "connect":
            Bluetooth.connectDevice(id)        // an unconfirmed keyboard is refused ("not-confirmed"): onFinished asks (RUY-444)
            break
        case "disconnect":
            Bluetooth.disconnectDevice(id)
            break
        case "settings":
            controllerRequested(padOf(id)?.id ?? "")
            break
        case "rename":
            deviceActions.askRename(id, d.name, DeviceIcons.shownName(Bluetooth.devices, d))
            break
        case "forget":
            deviceActions.askForget(id, DeviceIcons.shownName(Bluetooth.devices, d))
            break
        }
    }

    surfaceOptions: ({
        rows: id => pane.deviceOptionRows(id),
        title: id => { const d = pane.deviceById(id); return d ? DeviceIcons.shownParts(Bluetooth.devices, d) : ({ name: "", tail: "" }) },
        // "Pair again" needs the device in pairing mode: said under the menu, where the row's own line used to say it.
        note: id => pane.deviceById(id)?.bonded === false ? qsTr("Pair again: put the device in pairing mode first.") : "",
        run: (id, action) => pane.runDeviceOption(id, action),
        exists: id => pane.deviceById(id) !== undefined
    })
}
