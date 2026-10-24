import QtQuick
import RuyaShell

// Steps behind "Rename" and "Delete" in Settings -> Profiles:
//
//   rename: name (TextEntry) -> pin (the actor's, only when the actor has one) -> working
//   delete: confirm (Cancel first) -> pin (the admin's) -> working
//
// Back or Cancel at any step aborts (aborted()). The outcome arrives as
// finished(kind, id, status, attemptsLeft, retryAfterSecs), kind "rename" or "delete".
QtObject {
    id: flow

    required property PinPad pad
    required property TextEntry entry
    required property PowerConfirm confirm

    property string step: "idle"        // idle | name | confirm | pin | working
    readonly property bool active: step !== "idle"

    property string kind                // "rename" | "delete"
    property string actorId
    property bool actorHasPin: false
    property string targetId
    property string targetName
    property string newName

    signal finished(string kind, string id, string status, int attemptsLeft, int retryAfterSecs)
    signal aborted()

    function startRename(actor, hasPin, id, currentName) {
        if (active)
            return
        kind = "rename"
        actorId = actor
        actorHasPin = hasPin
        targetId = id
        targetName = currentName
        step = "name"
        entry.open(qsTr("Profile name"), currentName, { maxLength: 32, layout: "text" })
    }

    function startDelete(actor, hasPin, id, name) {
        if (active)
            return
        kind = "delete"
        actorId = actor
        actorHasPin = hasPin
        targetId = id
        targetName = name
        step = "confirm"
        confirm.customTitle = qsTr("Delete %1?").arg(name)
        confirm.detail = qsTr("Their saved data and settings are removed. This can't be undone.")
        confirm.open("custom")
    }

    function askPin() {
        if (!actorHasPin) {
            apply("")
            return
        }
        step = "pin"
        pad.collect(qsTr("Enter your PIN"), false)
    }

    function apply(pin) {
        step = "working"
        if (kind === "rename")
            Profiles.renameProfile(actorId, pin, targetId, newName)
        else
            Profiles.deleteProfile(actorId, pin, targetId)
    }

    function abort() {
        step = "idle"
        aborted()
    }

    property Connections entryEvents: Connections {
        target: flow.entry

        function onAccepted(text) {
            if (flow.step !== "name")
                return
            flow.newName = text
            flow.askPin()
        }
        function onCancelled() {
            if (flow.step === "name")
                flow.abort()
        }
    }

    property Connections confirmEvents: Connections {
        target: flow.confirm

        function onConfirmed() {
            if (flow.step === "confirm")
                flow.askPin()
        }
        function onClosed() {
            // Cancel and Back close the dialog without confirmed(); Confirm emits it after
            // closed(), so defer the check until it had the chance to move the step.
            Qt.callLater(() => {
                if (flow.step === "confirm")
                    flow.abort()
            })
        }
    }

    property Connections padEvents: Connections {
        target: flow.pad

        function onCollected(pin) {
            if (flow.step === "pin")
                flow.apply(pin)
        }
        function onCancelled() {
            if (flow.step === "pin")
                flow.abort()
        }
    }

    property Connections serviceEvents: Connections {
        target: Profiles

        function onRenameFinished(id, status, attemptsLeft, retryAfterSecs) {
            flow.done("rename", id, status, attemptsLeft, retryAfterSecs)
        }
        function onDeleteFinished(id, status, attemptsLeft, retryAfterSecs) {
            flow.done("delete", id, status, attemptsLeft, retryAfterSecs)
        }
    }

    function done(which, id, status, attemptsLeft, retryAfterSecs) {
        if (step !== "working" || which !== kind || id !== targetId)
            return
        step = "idle"
        finished(which, id, status, attemptsLeft, retryAfterSecs)
    }
}
