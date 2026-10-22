pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Profiles: who exists, add a profile (admins), change or remove your own PIN.
// Everything goes through org.ruyaos.Profiles1 (Profiles.createProfile / setPin).
//
// Adding: "Add profile" opens an inline form (name via the on-screen keyboard, role, PIN
// yes/no); "Create profile" then collects the new PIN twice (standard profiles with a PIN),
// the admin's own PIN, and calls createProfile. See ProfileAddFlow.qml / ChangePinFlow.qml.
SettingsPane {
    id: pane

    // Full-screen layer for the PIN pad and the keyboard (set by the shell through the page).
    property Item overlay

    readonly property var me: Profiles.active
    readonly property string myRole: me.role ?? ""
    readonly property bool isAdmin: myRole === "admin"
    readonly property bool canChangePin: myRole === "admin" || myRole === "standard"
    readonly property bool canRemovePin: myRole === "standard" && (me.hasPin ?? false)

    property bool adding: false
    property string newName: ""
    property string newRole: "standard"
    property bool newUsePin: false

    property string message: ""
    property bool messageIsError: false

    // Where focus returns after a modal closes.
    property Item returnTo: null

    function roleText(role) {
        return role === "admin" ? qsTr("Admin") : role === "guest" ? qsTr("Guest") : qsTr("Standard")
    }

    function describe(status, attemptsLeft, retryAfterSecs) {
        return ProfileStatus.describe(status, attemptsLeft, retryAfterSecs)
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
    // Focus is never lost: if the row that had it is gone (e.g. "Remove my PIN" after the PIN
    // was removed), go to "Change my PIN", else the first row. Does nothing while a modal
    // (PIN pad, keyboard) holds focus, since then the pane is not active.
    function keepFocus() {
        if (!activeFocus)
            return
        if (!focusableRows().some(r => r.activeFocus))
            (changePinRow.visible ? changePinRow : focusableRows()[0])?.forceActiveFocus()
        ensureFocusedVisible()
    }

    function startCreate() {
        if (newName.trim().length === 0) {
            Sfx.back()
            report(qsTr("Enter a name first."), true)
            return
        }
        report("", false)
        beginModal()
        addFlow.start(Profiles.activeProfile, newName.trim(), newRole, newUsePin)
    }

    function startPinChange(mode) {
        report("", false)
        beginModal()
        changeFlow.start(Profiles.activeProfile, me.hasPin ?? false, mode)
    }

    PinPad {
        id: pad
        objectName: "profilesPinPad"
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: pane.u
        onClosed: pane.restoreFocus()
    }

    TextEntry {
        id: nameEntry
        objectName: "profileNameEntry"
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: pane.u
        onAccepted: text => {
            pane.newName = text
            pane.report("", false)
        }
    }

    ProfileAddFlow {
        id: addFlow
        pad: pad
        onFinished: (status, id, attemptsLeft, retryAfterSecs) => {
            if (status === "ok") {
                const created = pane.newName.trim()
                pane.newName = ""
                pane.newRole = "standard"
                pane.newUsePin = false
                pane.adding = false
                pane.report(qsTr("Profile “%1” created.").arg(created), false)
                Notifications.show(qsTr("Profile “%1” created").arg(created), "success")
                addRow.forceActiveFocus()
                pane.ensureFocusedVisible()
            } else {
                Sfx.back()
                pane.report(pane.describe(status, attemptsLeft, retryAfterSecs), true)
            }
        }
    }

    ChangePinFlow {
        id: changeFlow
        pad: pad
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

    // The profiles that exist.
    Repeater {
        model: Profiles.profiles

        SettingRow {
            id: profileRow
            required property var modelData
            objectName: "profileRow_" + modelData.id
            u: pane.u
            swatch: modelData.avatar
            label: modelData.name
            value: pane.roleText(modelData.role)
                   + (modelData.hasPin ? " · " + qsTr("PIN") : "")
                   + (modelData.id === Profiles.activeProfile ? " · " + qsTr("You") : "")
        }
    }

    SettingRow {
        id: addRow
        objectName: "rowAdd"
        u: pane.u
        visible: pane.isAdmin
        label: qsTr("Add profile")
        value: pane.adding ? qsTr("Close") : ""
        onActivated: {
            pane.adding = !pane.adding
            if (pane.adding)
                nameRow.forceActiveFocus()
            Qt.callLater(pane.ensureFocusedVisible)
        }
    }

    SettingRow {
        id: nameRow
        objectName: "rowNewName"
        u: pane.u
        visible: pane.isAdmin && pane.adding
        label: qsTr("Name")
        value: pane.newName.length > 0 ? pane.newName : qsTr("Not set")
        onActivated: {
            pane.beginModal()
            nameEntry.open(qsTr("Profile name"), pane.newName, { maxLength: 32, layout: "text" })
        }
    }
    ChoiceRow {
        id: roleRow
        objectName: "rowNewRole"
        u: pane.u
        visible: pane.isAdmin && pane.adding
        label: qsTr("Role")
        options: [
            { value: "standard", label: qsTr("Standard") },
            { value: "guest", label: qsTr("Guest") },
        ]
        value: pane.newRole
        onEdited: v => {
            pane.newRole = v
            if (v === "guest")
                pane.newUsePin = false     // guests never have a PIN
        }
    }
    ToggleRow {
        id: pinRow
        objectName: "rowNewPin"
        u: pane.u
        visible: pane.isAdmin && pane.adding && pane.newRole === "standard"
        label: qsTr("Protect with a PIN")
        checked: pane.newUsePin
        onToggled: checked => pane.newUsePin = checked
    }
    SettingRow {
        id: createRow
        objectName: "rowCreate"
        u: pane.u
        visible: pane.isAdmin && pane.adding
        label: qsTr("Create profile")
        onActivated: pane.startCreate()
    }

    SettingRow {
        id: changePinRow
        objectName: "rowChangePin"
        u: pane.u
        visible: pane.canChangePin
        label: (pane.me.hasPin ?? false) ? qsTr("Change my PIN") : qsTr("Set a PIN")
        onActivated: pane.startPinChange("change")
    }
    SettingRow {
        objectName: "rowRemovePin"
        u: pane.u
        visible: pane.canRemovePin
        label: qsTr("Remove my PIN")
        onActivated: pane.startPinChange("remove")
    }

    Text {
        objectName: "profilesMessage"
        width: parent ? parent.width : 0
        visible: pane.message.length > 0
        text: pane.message
        color: pane.messageIsError ? "#ff8a80" : Theme.toastSuccess
        font.pixelSize: 28 * pane.u
        wrapMode: Text.Wrap
    }
}
