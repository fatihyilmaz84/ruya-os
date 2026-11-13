pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "<Name> connected" and "<Name> disconnected" toasts for game controllers (T-260), from the
// service's GamepadConnected / GamepadDisconnected (USB or Bluetooth, read from the kernel's input
// devices; keyboards and mice never arrive here), and "<Name> connected" for a Bluetooth keyboard
// (T-301): a listed keyboard whose `connected` turns true in Bluetooth.devices, with the keyboard
// glyph. A keyboard that was already connected when the list first arrived, or that appears
// in the list already connected, says nothing; neither does its leaving. Non-visual; ToastLayer hosts it.
//
// Rules:
//  - A change waits `debounceMs` before it is announced. A cable that flaps (gone and back within
//    that time) says nothing at all: the opposite event cancels the waiting one.
//  - "Connected" is shown once per connection, with the family glyph and the battery when it is
//    known: the Bluetooth device's own level (matched by address) or, failing that, the only
//    controller UPower lists.
//  - "Disconnected" is shown only when the pad was in use: some key reached the shell while it was
//    connected (`noteInput()`, fed by the Shell for every key), or no input device is left to drive
//    the console. A pad that was put down and unplugged says nothing.
QtObject {
    id: toasts

    property int debounceMs: 800

    // Waiting announcements: [{ kind: "connected" | "disconnected", id, name, family, transport }].
    property var waiting: []
    // Pads the user was told are connected: id -> { used }.
    property var shown: ({})
    // How many announcements have been shown, ever (tests).
    property int connectedShown: 0
    property int disconnectedShown: 0

    // The Bluetooth keyboards of the last list: id -> connected. null until a list has been seen (the
    // first one, or the first after the service restarted, is only the baseline).
    property var keyboards: null

    // Called by the Shell for every key, mouse or touch event.
    function noteInput() {
        for (const id in shown)
            shown[id].used = true
    }

    function indexWaiting(id) {
        return waiting.findIndex(w => w.id === id)
    }

    function onConnected(id, name, family, transport, deviceKind) {
        const at = indexWaiting(id)
        if (at >= 0) {
            if (waiting[at].kind === "disconnected") {
                // Gone and back inside the debounce: the user never saw it leave.
                waiting = waiting.filter((w, i) => i !== at)
            }
        } else if (!(id in shown)) {
            waiting = waiting.concat([{ kind: "connected", id: id, name: name, family: family, transport: transport,
                                                         deviceKind: deviceKind ?? "controller" }])
        }
        settle.restart()
    }

    // Looks at a new device list for a keyboard that just connected.
    function noteDevices() {
        const now = ({})
        const previous = toasts.keyboards
        for (const d of Bluetooth.devices) {
            if (d.kind !== "keyboard")
                continue
            now[d.id] = d.connected
            if (previous === null)
                continue
            if (d.connected && previous[d.id] === false) {
                onConnected(d.id, d.name, "", "bluetooth", "keyboard")
            } else if (!d.connected && previous[d.id] === true) {
                // Gone: forget the announcement (a later connection is news again) and anything waiting.
                waiting = waiting.filter(w => w.id !== d.id)
                delete shown[d.id]
            }
        }
        toasts.keyboards = now
    }

    function onDisconnected(id, name, family, transport) {
        const at = indexWaiting(id)
        if (at >= 0) {
            if (waiting[at].kind === "connected") {
                // Came and went inside the debounce: never announced, nothing to take back.
                waiting = waiting.filter((w, i) => i !== at)
            }
        } else if (id in shown) {
            waiting = waiting.concat([{ kind: "disconnected", id: id, name: name, family: family, transport: transport }])
        }
        settle.restart()
    }

    // The name to show: the Bluetooth device's alias (what the user renamed it to) when the id is a
    // Bluetooth address, else the family's words, else the kernel's name.
    function displayName(id, name, family) {
        return DeviceIcons.padName(id, name, family)
    }

    // The battery of the pad that just connected, or -1.
    function batteryOf(id, deviceKind) {
        const wanted = id.toLowerCase()
        const paired = Bluetooth.devices.find(d => d.id.toLowerCase() === wanted)
        if (paired && paired.battery >= 0)
            return paired.battery
        if (deviceKind !== "controller")
            return -1
        const pads = Batteries.devices.filter(d => d.kind === "controller")
        return pads.length === 1 ? pads[0].percent : -1
    }

    function announce(w) {
        if (w.kind === "connected") {
            shown[w.id] = { used: false }
            const name = displayName(w.id, w.name, w.family)
            const deviceKind = w.deviceKind ?? "controller"
            const battery = batteryOf(w.id, deviceKind)
            // The fact is the title; the battery and the way it is connected are the detail (RUY-412).
            const parts = []
            if (battery >= 0)
                parts.push(qsTr("Battery %1%").arg(battery))
            if (w.transport === "bluetooth")
                parts.push(qsTr("Bluetooth"))
            else if (w.transport === "usb")
                parts.push(qsTr("USB"))
            toasts.connectedShown += 1
            Notifications.show(qsTr("%1 connected").arg(name), "success", "", DeviceIcons.iconFor(deviceKind, w.family),
                               parts.join(" · "), { source: "devices" })
        } else {
            const used = shown[w.id] ? shown[w.id].used : false
            delete shown[w.id]
            if (used || !Bluetooth.inputPresent) {
                toasts.disconnectedShown += 1
                Notifications.show(qsTr("%1 disconnected").arg(displayName(w.id, w.name, w.family)), "info", "",
                                   DeviceIcons.iconFor("controller", w.family), "", { source: "devices" })
            }
        }
    }

    property Timer settle: Timer {
        interval: toasts.debounceMs
        onTriggered: {
            const due = toasts.waiting
            toasts.waiting = []
            for (const w of due)
                toasts.announce(w)
        }
    }

    property Connections events: Connections {
        target: Bluetooth
        function onGamepadConnected(id, name, family, transport) { toasts.onConnected(id, name, family, transport) }
        function onGamepadDisconnected(id, name, family, transport) { toasts.onDisconnected(id, name, family, transport) }
        // The service restarted: what it said before is void, and its next read is a new baseline.
        function onGamepadsReset() {
            toasts.waiting = []
            toasts.shown = ({})
            toasts.keyboards = null
        }
        function onDevicesChanged() { toasts.noteDevices() }
    }

    Component.onCompleted: {
        if (Bluetooth.devices.length > 0)
            noteDevices()          // the baseline: what is connected now is not news
    }
}
