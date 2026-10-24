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

    // The profile whose actions (Rename, Delete) are showing, and what to focus once the
    // list has caught up with a finished rename/delete.
    property string selectedId: ""
    property var pendingFocus: null
    property int deletedIndex: 0       // list position of the profile being deleted
    readonly property var selected: Profiles.profiles.find(p => p.id === selectedId)
    readonly property int adminCount: Profiles.profiles.filter(p => p.role === "admin").length
    readonly property bool canRename: selected !== undefined && selected.role !== "guest"
                                      && (isAdmin || selectedId === Profiles.activeProfile)
    readonly property bool canDelete: selected !== undefined && isAdmin && selected.role !== "guest"
                                      && selectedId !== Profiles.activeProfile
                                      && !(selected.role === "admin" && adminCount <= 1)

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

    function selectProfile(id) {
        selectedId = id
        report("", false)
        Qt.callLater(() => {
            const next = canRename ? renameRow : canDelete ? deleteRow : null
            if (next)
                next.forceActiveFocus()
            ensureFocusedVisible()
        })
    }

    function startRename() {
        report("", false)
        beginModal()
        manageFlow.startRename(Profiles.activeProfile, me.hasPin ?? false, selectedId, selected.name)
    }

    function startDelete() {
        report("", false)
        deletedIndex = Profiles.profiles.findIndex(p => p.id === selectedId)
        beginModal()
        manageFlow.startDelete(Profiles.activeProfile, me.hasPin ?? false, selectedId, selected.name)
    }

    // Applies pendingFocus once the profile list shows the outcome (the reply and the new
    // list may arrive in either order).
    function runPendingFocus() {
        const want = pendingFocus
        if (!want)
            return
        const list = Profiles.profiles
        const rows = focusableRows()
        let target = null
        if (want.kind === "rename") {
            if (list.find(p => p.id === want.id)?.name !== want.name)
                return
            target = rows.find(r => r.objectName === "profileRow_" + want.id)
        } else {
            if (list.some(p => p.id === want.id))
                return
            const next = list[Math.min(want.index, list.length - 1)]
            target = rows.find(r => r.objectName === "profileRow_" + next?.id)
        }
        pendingFocus = null;
        (target ?? changePinRow).forceActiveFocus()
        ensureFocusedVisible()
    }

    Connections {
        target: Profiles
        function onProfilesChanged() { Qt.callLater(pane.runPendingFocus) }
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

    PowerConfirm {
        id: deleteConfirm
        objectName: "profileDeleteConfirm"
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: pane.u
        onClosed: pane.restoreFocus()
    }

    TextEntry {
        id: renameEntry
        objectName: "profileRenameEntry"
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: pane.u
    }

    ProfileManageFlow {
        id: manageFlow
        pad: pad
        entry: renameEntry
        confirm: deleteConfirm
        onAborted: pane.restoreFocus()
        onFinished: (kind, id, status, attemptsLeft, retryAfterSecs) => {
            if (status === "ok") {
                if (kind === "rename") {
                    pane.pendingFocus = { kind: "rename", id: id, name: manageFlow.newName.trim() }
                    pane.report(qsTr("Profile renamed."), false)
                    Notifications.show(qsTr("Profile renamed"), "success")
                } else {
                    pane.pendingFocus = { kind: "delete", id: id, index: pane.deletedIndex }
                    pane.selectedId = ""
                    pane.report(qsTr("Profile “%1” deleted.").arg(manageFlow.targetName), false)
                    Notifications.show(qsTr("Profile “%1” deleted").arg(manageFlow.targetName), "success")
                }
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
            onActivated: pane.selectProfile(modelData.id)
            value: pane.roleText(modelData.role)
                   + (modelData.hasPin ? " · " + qsTr("PIN") : "")
                   + (modelData.id === Profiles.activeProfile ? " · " + qsTr("You") : "")
        }
    }

    SettingRow {
        id: renameRow
        objectName: "rowRename"
        u: pane.u
        visible: pane.canRename
        label: qsTr("Rename %1").arg(pane.selected?.name ?? "")
        onActivated: pane.startRename()
    }
    SettingRow {
        id: deleteRow
        objectName: "rowDelete"
        u: pane.u
        visible: pane.canDelete
        label: qsTr("Delete %1").arg(pane.selected?.name ?? "")
        onActivated: pane.startDelete()
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
        color: pane.messageIsError ? Theme.errorText : Theme.toastSuccess
        font.pixelSize: 28 * pane.u
        wrapMode: Text.Wrap
    }
}
