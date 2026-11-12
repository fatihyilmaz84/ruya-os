pragma Singleton
import QtQuick

// What a Bluetooth service status says in words (T-301): the one mapping the Bluetooth pane
// (a toast after a failed pair, connect or disconnect) and the controller pairing screen (the reason
// under a pad that failed) both use, so a new status is added once. `subject` is "device" (the pane,
// any kind) or "controller" (the pairing screen, which only ever deals with pads); it changes the
// noun and nothing else.
//
// The statuses are the ones of api/dbus/org.ruyaos.Devices1.xml: "pairing-failed", "timeout",
// "unavailable", "unknown-device", "not-confirmed"; anything else (including "failed") gets the plain "could not ..."
// of the operation.
QtObject {
    id: text

    function statusText(op, status, subject) {
        const pad = subject === "controller"
        switch (status) {
        case "pairing-failed":
            return pad ? qsTr("Pairing failed. Put the controller in pairing mode again.")
                       : qsTr("Pairing failed. Put the device in pairing mode and try again.")
        case "timeout":
            return pad ? qsTr("The controller did not answer.") : qsTr("The device did not answer.")
        case "unavailable":
            return qsTr("Bluetooth is off.")
        case "not-confirmed":
            return qsTr("That keyboard was not confirmed.")
        case "unknown-device":
            return pad ? qsTr("The controller went away.") : qsTr("That device is no longer available.")
        }
        if (op === "pair")
            return pad ? qsTr("Could not pair the controller.") : qsTr("Could not pair the device.")
        return op === "disconnect" ? qsTr("Could not disconnect.") : qsTr("Could not connect.")
    }
}
