pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Manage profiles (T-315, admins only): who exists, Rename / Delete another
// profile, Add profile. Everything goes through org.ruyaos.Profiles1 (Profiles.createProfile /
// renameProfile / deleteProfile). Your own name and PIN are in MyProfilePane.qml; the shared
// parts (PIN pad, rename/delete flow, focus return) in ProfilePaneBase.qml.
//
// Adding: "Add profile" opens an inline form (name via the on-screen keyboard, role, PIN
// yes/no); "Create profile" then collects the new PIN twice (standard profiles with a PIN),
// the admin's own PIN, and calls createProfile. See ProfileAddFlow.qml.
//
// Where later work lands: a profile's role (T-211) and parental controls (T-212) are set with
// further rows beside Rename / Delete, shown for the selected profile.
ProfilePaneBase {
    id: pane

    fallbackRow: addRow

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
    // Your own profile is changed under My profile, so only another one is renamed or deleted here.
    readonly property bool other: selected !== undefined && selectedId !== Profiles.activeProfile
    readonly property bool canRename: other && isAdmin && selected.role !== "guest"
    readonly property bool canDelete: other && isAdmin && selected.role !== "guest"
                                      && !(selected.role === "admin" && adminCount <= 1)

    function selectProfile(id) {
        selectedId = id
        report(id === Profiles.activeProfile ? qsTr("Your own profile is under My profile.") : "", false)
        Qt.callLater(() => {
            const next = canRename ? renameRow : canDelete ? deleteRow : null
            if (next)
                next.forceActiveFocus()
            ensureFocusedVisible()
        })
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
        (target ?? addRow).forceActiveFocus()
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

    // The keyboard for the new profile's name, built when it first opens (T-349).
    Loader {
        id: nameEntrySlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            TextEntry {
                objectName: "profileNameEntry"
                u: pane.u
                onAccepted: text => {
                    pane.newName = text
                    pane.report("", false)
                }
            }
        }
    }
    readonly property TextEntry nameEntry: nameEntrySlot.item as TextEntry

    ProfileAddFlow {
        id: addFlow
        pad: pane.pad
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

    Connections {
        target: pane.manageFlow
        function onFinished(kind, id, status, attemptsLeft, retryAfterSecs) {
            if (status === "ok") {
                if (kind === "rename") {
                    pane.pendingFocus = { kind: "rename", id: id, name: pane.manageFlow.newName.trim() }
                    pane.report(qsTr("Profile renamed."), false)
                    Notifications.show(qsTr("Profile renamed"), "success")
                } else {
                    pane.pendingFocus = { kind: "delete", id: id, index: pane.deletedIndex }
                    pane.selectedId = ""
                    pane.report(qsTr("Profile “%1” deleted.").arg(pane.manageFlow.targetName), false)
                    Notifications.show(qsTr("Profile “%1” deleted").arg(pane.manageFlow.targetName), "success")
                }
                Qt.callLater(pane.runPendingFocus)
            } else {
                Sfx.back()
                pane.report(pane.describe(status, attemptsLeft, retryAfterSecs), true)
                pane.restoreFocus()
            }
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
        onActivated: pane.startRename(pane.selectedId, pane.selected.name)
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
            nameEntrySlot.active = true
            pane.nameEntry.open(qsTr("Profile name"), pane.newName, { maxLength: 32, layout: "text" })
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

    Text {
        objectName: "profilesMessage"
        width: parent ? parent.width : 0
        visible: pane.message.length > 0
        textFormat: Text.PlainText
        text: pane.message
        color: pane.messageIsError ? Theme.errorText : Theme.toastSuccess
        font.pixelSize: Theme.typeBody * pane.u
        wrapMode: Text.Wrap
    }
}
