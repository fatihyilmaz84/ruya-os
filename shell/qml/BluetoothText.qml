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

    // The adapter as a person knows it: the service says "usb" or "built-in" when the two differ, else "hciN" (04 section 6).
    function adapterWords(token, subject) {
        if (token === "usb") {
            if (subject) {
                //: Starts the toast "%1 is off. Bluetooth uses %2.": the USB adapter is the SUBJECT, the one that is off (capital T).
                return qsTr("The USB adapter")
            }
            //: Ends the toast "%1 is off. Bluetooth uses %2.": the USB adapter is the OBJECT, the one in use (lower-case t).
            return qsTr("the USB adapter")
        }
        if (token === "built-in") {
            if (subject) {
                //: Starts the toast "%1 is off. Bluetooth uses %2.": the built-in adapter is the SUBJECT, the one that is off (capital T).
                return qsTr("The built-in adapter")
            }
            //: Ends the toast "%1 is off. Bluetooth uses %2.": the built-in adapter is the OBJECT, the one in use (lower-case t).
            return qsTr("the built-in adapter")
        }
        return token
    }

    // "unavailable" while Bluetooth is on: the console's main adapter is off and another one is on (RUY-21),
    // so the adapter is named.
    function unavailableText() {
        if (Bluetooth.primaryAdapterOff !== "" && Bluetooth.adapterInUse !== "") {
            const off = adapterWords(Bluetooth.primaryAdapterOff, true)
            const inUse = adapterWords(Bluetooth.adapterInUse, false)
            //: A toast. %1: the adapter that is off ("The USB adapter", or a name such as "hci1"), %2: the one in use ("the built-in adapter" or "hci0"). Names such as hci0 stay as they are.
            return qsTr("%1 is off. Bluetooth uses %2.").arg(off).arg(inUse)
        }
        return qsTr("Bluetooth is off.")
    }

    function statusText(op, status, subject) {
        const pad = subject === "controller"
        switch (status) {
        case "pairing-failed":
            return pad ? qsTr("Pairing failed. Put the controller in pairing mode again.")
                       : qsTr("Pairing failed. Put the device in pairing mode and try again.")
        case "timeout":
            return pad ? qsTr("The controller did not answer.") : qsTr("The device did not answer.")
        case "unavailable":
            return unavailableText()
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
