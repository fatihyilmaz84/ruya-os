pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> My profile (T-315): the signed-in profile's own options. Who I am (read-only),
// rename myself, set / change / remove my PIN, and the Activity page. Everything goes through
// org.ruyaos.Profiles1 (Profiles.renameProfile / setPin). The shared parts (PIN pad, rename
// flow, focus return) are in ProfilePaneBase.qml. The profile list and everything that
// touches other people's profiles is in ManageProfilesPane.qml.
//
// Where later work lands: profile customisation (avatar, colour, T-210) goes between "Rename"
// and the PIN rows; the parental limits view (T-212) goes after the PIN rows, before Activity.
ProfilePaneBase {
    id: pane

    namePrefix: "myProfile"
    fallbackRow: changePinRow

    readonly property bool canRename: myRole === "admin" || myRole === "standard"
    readonly property bool canChangePin: myRole === "admin" || myRole === "standard"
    readonly property bool canRemovePin: myRole === "standard" && (me.hasPin ?? false)

    // Rows come and go with the signed-in profile (Rename, PIN rows): lay the column out now
    // (SettingsPane.reflow), or a real window can keep them unlaid and clipped to one row.
    onMyRoleChanged: Qt.callLater(reflow)
    onMeChanged: Qt.callLater(reflow)
    Component.onCompleted: Qt.callLater(reflow)

    // The "Activity" row was activated: the Settings page opens the Activity page (T-247).
    signal activityRequested()

    // The rename of the signed-in profile finished: focus returns to the Rename row once the
    // list shows the new name.
    property string renamedTo: ""
    function runPendingFocus() {
        if (renamedTo.length === 0 || me.name !== renamedTo)
            return
        renamedTo = ""
        renameRow.forceActiveFocus()
        ensureFocusedVisible()
    }

    function startPinChange(mode) {
        report("", false)
        beginModal()
        changeFlow.start(Profiles.activeProfile, me.hasPin ?? false, mode)
    }

    Connections {
        target: Profiles
        function onProfilesChanged() { Qt.callLater(pane.runPendingFocus) }
    }

    Connections {
        target: pane.manageFlow
        function onFinished(kind, id, status, attemptsLeft, retryAfterSecs) {
            if (status === "ok") {
                pane.renamedTo = pane.manageFlow.newName.trim()
                pane.report(qsTr("Profile renamed."), false)
                Notifications.show(qsTr("Profile renamed"), "success")
                Qt.callLater(pane.runPendingFocus)
            } else {
                Sfx.back()
                pane.report(pane.describe(status, attemptsLeft, retryAfterSecs), true)
                pane.restoreFocus()
            }
        }
    }

    ChangePinFlow {
        id: changeFlow
        pad: pane.pad
        onFinished: (status, attemptsLeft, retryAfterSecs) => {
            if (status === "ok") {
                const text = changeFlow.mode === "remove" ? qsTr("PIN removed.") : qsTr("PIN changed.")
                pane.report(text, false)
                Notifications.show(text, "success")
            } else {
                Sfx.back()
                pane.report(pane.describe(status, attemptsLeft, retryAfterSecs), true)
            }
            pane.restoreFocus()
        }
    }

    // Who I am: name, role and whether a PIN is set. Read-only here.
    SettingRow {
        id: whoRow
        objectName: "rowWho"
        kind: "info"
        u: pane.u
        swatch: pane.me.avatar ?? "transparent"
        label: pane.me.name ?? ""
        value: pane.roleText(pane.myRole) + (pane.me.hasPin ? " · " + qsTr("PIN") : "")
    }
    SettingRow {
        id: renameRow
        objectName: "rowRenameMe"
        kind: "action"
        u: pane.u
        visible: pane.canRename
        label: qsTr("Rename %1").arg(pane.me.name ?? "")
        onActivated: pane.startRename(Profiles.activeProfile, pane.me.name ?? "")
    }

    SettingRow {
        id: changePinRow
        objectName: "rowChangePin"
        kind: "action"
        u: pane.u
        visible: pane.canChangePin
        label: (pane.me.hasPin ?? false) ? qsTr("Change my PIN") : qsTr("Set a PIN")
        onActivated: pane.startPinChange("change")
    }
    SettingRow {
        objectName: "rowRemovePin"
        kind: "action"
        u: pane.u
        visible: pane.canRemovePin
        label: qsTr("Remove my PIN")
        onActivated: pane.startPinChange("remove")
    }
    SettingRow {
        id: activityRow
        objectName: "rowActivity"
        kind: "page"
        u: pane.u
        visible: Profiles.activeProfile !== ""
        label: qsTr("Activity")
        value: qsTr("What you played")
        onActivated: pane.activityRequested()
    }

    Text {
        objectName: "myProfileMessage"
        width: parent ? parent.width : 0
        visible: pane.message.length > 0
        textFormat: Text.PlainText
        text: pane.message
        color: pane.messageIsError ? Theme.errorText : Theme.toastSuccess
        font.pixelSize: Theme.typeBody * pane.u
        wrapMode: Text.Wrap
    }
}
