pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> System. The language row writes straight to DeviceSettings, which installs the
// translator and retranslates the UI at once. Language names are shown in their own language.
//
// The Updates group (org.ruyaos.Update1) is one row that follows the update state: check,
// download (with progress), "Restart to finish". A rollback to the previous image and the
// channel are for admins; the rollback asks for the admin's PIN (Profiles.verifyAdmin), then
// a confirmation, then calls Update.rollback().
SettingsPane {
    id: pane

    // Full-screen layer for the PIN pad and the confirmations (the Settings page's modal layer).
    property Item overlay

    readonly property bool isAdmin: (Profiles.active.role ?? "") === "admin"
    readonly property string updateState: Update.state

    property string message: ""
    property bool messageIsError: false
    property string rollbackStep: "idle"     // idle | pin | confirm | working
    property Item returnTo: null

    function channelLabel(channel) {
        return channel === "beta" ? qsTr("Beta") : qsTr("Stable")
    }

    function lastCheckText() {
        return Update.lastCheck > 0
            ? qsTr("Last checked %1").arg(Qt.formatDateTime(new Date(Update.lastCheck * 1000), "d MMM, hh:mm"))
            : qsTr("Never checked")
    }

    function updateLabel() {
        switch (updateState) {
        case "checking": return qsTr("Checking for updates…")
        case "downloading": return qsTr("Downloading version %1").arg(Update.available || Update.staged)
        case "staged": return qsTr("Restart to finish")
        default:
            return Update.available.length > 0 ? qsTr("Download version %1").arg(Update.available)
                                               : qsTr("Check for updates")
        }
    }

    function updateValue() {
        switch (updateState) {
        case "checking": return ""
        case "downloading": return qsTr("%1 %").arg(Update.progress)
        case "staged": return qsTr("Version %1 is ready").arg(Update.staged)
        case "up-to-date": return qsTr("Up to date")
        case "failed": return qsTr("Failed")
        default: return Update.available.length > 0 ? qsTr("Update found") : pane.lastCheckText()
        }
    }

    function activateUpdate() {
        message = ""
        if (updateState === "staged") {
            beginModal()
            restartConfirm.open("restart")
        } else if (updateState === "idle" && Update.available.length > 0) {
            Update.download()
        } else if (updateState === "idle" || updateState === "up-to-date" || updateState === "failed") {
            Update.check()
        }
    }

    function report(text, isError) {
        message = text
        messageIsError = isError
    }

    function beginModal() {
        returnTo = Window.activeFocusItem
    }
    function restoreFocus() {
        const target = returnTo
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        Qt.callLater(keepFocus)
    }
    // The rollback row disappears once the rollback is done: move to the update row.
    function keepFocus() {
        if (!activeFocus)
            return
        if (!focusableRows().some(r => r.activeFocus))
            updateRow.forceActiveFocus()
        ensureFocusedVisible()
    }

    function startRollback() {
        report("", false)
        beginModal()
        rollbackStep = "pin"
        pad.collect(qsTr("Enter your PIN"), false)
    }

    function abortRollback() {
        rollbackStep = "idle"
        restoreFocus()
    }

    PinPad {
        id: pad
        objectName: "updatePinPad"
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: pane.u
        onCollected: pin => {
            if (pane.rollbackStep === "pin") {
                pane.rollbackStep = "working"
                Profiles.verifyAdmin(Profiles.activeProfile, pin)
            }
        }
        onCancelled: if (pane.rollbackStep === "pin") pane.abortRollback()
        onClosed: if (pane.rollbackStep === "idle") pane.restoreFocus()
    }

    PowerConfirm {
        id: restartConfirm
        objectName: "updateRestartConfirm"
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: pane.u
        onClosed: pane.restoreFocus()
    }

    PowerConfirm {
        id: rollbackConfirm
        objectName: "updateRollbackConfirm"
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: pane.u
        onConfirmed: {
            if (pane.rollbackStep === "confirm") {
                pane.rollbackStep = "working"
                Update.rollback()
            }
        }
        onClosed: {
            // Cancel and Back close without confirmed(); Confirm emits it after closed().
            Qt.callLater(() => {
                if (pane.rollbackStep === "confirm")
                    pane.abortRollback()
                else
                    pane.restoreFocus()
            })
        }
    }

    Connections {
        target: Profiles

        function onVerifyAdminFinished(adminId, status, attemptsLeft, retryAfterSecs) {
            if (pane.rollbackStep !== "working")
                return
            if (status === "ok") {
                pane.rollbackStep = "confirm"
                rollbackConfirm.customTitle = qsTr("Roll back to the previous version?")
                rollbackConfirm.detail = qsTr("The console starts the previous version the next time it restarts.")
                rollbackConfirm.open("custom")
            } else {
                Sfx.back()
                pane.rollbackStep = "idle"
                pane.report(ProfileStatus.describe(status, attemptsLeft, retryAfterSecs), true)
                pane.restoreFocus()
            }
        }
    }

    Connections {
        target: Update

        function onRequestFinished(method, status) {
            if (method === "rollback" && pane.rollbackStep === "working") {
                pane.rollbackStep = "idle"
                if (status === "ok") {
                    pane.report(qsTr("The previous version starts after the next restart."), false)
                } else {
                    Sfx.back()
                    pane.report(qsTr("Could not roll back."), true)
                }
                pane.restoreFocus()
            } else if (status !== "ok" && (method === "check" || method === "download" || method === "setChannel")) {
                Sfx.back()
                pane.report(status === "busy" ? qsTr("An update is already in progress.")
                                              : qsTr("The update could not be started."), true)
            }
        }
        function onStatusChanged() {
            if (Update.state === "failed" && Update.error.length > 0)
                pane.report(Update.error, true)
        }
    }

    ChoiceRow {
        id: language
        objectName: "rowLanguage"
        u: pane.u
        label: qsTr("Language")
        options: [
            { value: "en", label: "English" },
            { value: "tr", label: "Türkçe" },
        ]
        onEdited: v => {
            DeviceSettings.language = v
            language.value = DeviceSettings.language
        }
    }
    Binding { target: language; property: "value"; value: DeviceSettings.language }

    Text {
        objectName: "updatesHeading"
        width: parent ? parent.width : 0
        topPadding: Theme.spaceS * pane.u
        text: qsTr("Updates")
        color: Theme.textDim
        font.pixelSize: Theme.typeBody * pane.u
    }

    SettingRow {
        objectName: "rowVersion"
        u: pane.u
        label: qsTr("Version")
        value: Update.current + " · " + pane.channelLabel(Update.channel)
    }

    ChoiceRow {
        id: channelRow
        objectName: "rowChannel"
        u: pane.u
        visible: pane.isAdmin
        label: qsTr("Update channel")
        options: [
            { value: "stable", label: qsTr("Stable") },
            { value: "beta", label: qsTr("Beta") },
        ]
        onEdited: v => {
            pane.report("", false)
            Update.setChannel(v)
        }
    }
    Binding { target: channelRow; property: "value"; value: Update.channel }

    SettingRow {
        id: updateRow
        objectName: "rowUpdate"
        u: pane.u
        label: pane.updateLabel()
        value: pane.updateValue()
        onActivated: pane.activateUpdate()
    }

    SettingRow {
        id: rollbackRow
        objectName: "rowRollback"
        u: pane.u
        visible: pane.isAdmin && Update.rollbackAvailable
        label: qsTr("Roll back to the previous version")
        onActivated: pane.startRollback()
    }

    Text {
        objectName: "updateMessage"
        width: parent ? parent.width : 0
        visible: pane.message.length > 0
        text: pane.message
        color: pane.messageIsError ? Theme.errorText : Theme.toastSuccess
        font.pixelSize: Theme.typeBody * pane.u
        wrapMode: Text.Wrap
    }
}
