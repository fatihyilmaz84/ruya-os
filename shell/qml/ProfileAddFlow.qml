import QtQuick
import RuyaShell

// Steps behind "Create profile": [new PIN, entered twice] -> [admin PIN] -> createProfile.
// Non-visual; the pane owns the form (name, role, PIN yes/no) and the shared PinPad.
//
//   idle -> newPin (standard profile with a PIN only) -> adminPin -> creating -> idle
//
// Cancelling a pad (Back on an empty pad) returns to idle and emits aborted(). The outcome
// of the service call arrives as finished(status, id, attemptsLeft, retryAfterSecs).
QtObject {
    id: flow

    required property PinPad pad

    property string step: "idle"
    readonly property bool active: step !== "idle"

    property string adminId
    property string name
    property string role
    property bool usePin
    property string newPin

    signal finished(string status, string id, int attemptsLeft, int retryAfterSecs)
    signal aborted()

    function start(adminId, name, role, usePin) {
        if (active)
            return
        flow.adminId = adminId
        flow.name = name
        flow.role = role
        flow.usePin = usePin
        newPin = ""
        if (role === "standard" && usePin) {
            step = "newPin"
            pad.collect(qsTr("Choose a PIN"), true)
        } else {
            askAdminPin()
        }
    }

    function askAdminPin() {
        step = "adminPin"
        pad.collect(qsTr("Enter your PIN to confirm"), false)
    }

    property Connections padEvents: Connections {
        target: flow.pad

        function onCollected(pin) {
            if (flow.step === "newPin") {
                flow.newPin = pin
                flow.askAdminPin()
            } else if (flow.step === "adminPin") {
                flow.step = "creating"
                Profiles.createProfile(flow.adminId, pin, flow.name, flow.role,
                                       flow.role === "standard" && flow.usePin ? flow.newPin : "")
            }
        }
        function onCancelled() {
            if (flow.step === "newPin" || flow.step === "adminPin") {
                flow.step = "idle"
                flow.aborted()
            }
        }
    }

    property Connections serviceEvents: Connections {
        target: Profiles

        function onCreateFinished(status, id, attemptsLeft, retryAfterSecs) {
            if (flow.step !== "creating")
                return
            flow.step = "idle"
            flow.newPin = ""
            flow.finished(status, id, attemptsLeft, retryAfterSecs)
        }
    }
}
