import QtQuick
import RuyaShell

// Steps behind "Change my PIN" / "Set a PIN" / "Remove my PIN":
//
//   idle -> oldPin (only when the profile has a PIN) -> newPin (change only, entered twice)
//        -> setting -> idle
//
// mode "change" sets a new PIN; mode "remove" sets "" (the service refuses that for admins,
// and the pane hides the option for them). Back on an empty pad cancels (aborted()). The
// outcome arrives as finished(status, attemptsLeft, retryAfterSecs).
QtObject {
    id: flow

    required property PinPad pad

    property string step: "idle"
    readonly property bool active: step !== "idle"

    property string profileId
    property string mode: "change"      // "change" | "remove"
    property string oldPin

    signal finished(string status, int attemptsLeft, int retryAfterSecs)
    signal aborted()

    function start(id, hasPin, mode) {
        if (active)
            return
        profileId = id
        flow.mode = mode
        oldPin = ""
        if (hasPin) {
            step = "oldPin"
            pad.collect(qsTr("Enter your current PIN"), false)
        } else {
            askNewPin()
        }
    }

    function askNewPin() {
        if (mode === "remove") {
            apply("")
            return
        }
        step = "newPin"
        pad.collect(qsTr("Choose a new PIN"), true)
    }

    function apply(newPin) {
        step = "setting"
        Profiles.setPin(profileId, oldPin, newPin)
    }

    property Connections padEvents: Connections {
        target: flow.pad

        function onCollected(pin) {
            if (flow.step === "oldPin") {
                flow.oldPin = pin
                flow.askNewPin()
            } else if (flow.step === "newPin") {
                flow.apply(pin)
            }
        }
        function onCancelled() {
            if (flow.step === "oldPin" || flow.step === "newPin") {
                flow.step = "idle"
                flow.aborted()
            }
        }
    }

    property Connections serviceEvents: Connections {
        target: Profiles

        function onSetPinFinished(id, status, attemptsLeft, retryAfterSecs) {
            if (flow.step !== "setting" || id !== flow.profileId)
                return
            flow.step = "idle"
            flow.oldPin = ""
            flow.finished(status, attemptsLeft, retryAfterSecs)
        }
    }
}
