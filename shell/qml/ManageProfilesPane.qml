pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Manage profiles (T-315, admins only): who exists, a page for each other profile with
// Rename / Delete (RUY-715), Add profile. Everything goes through org.ruyaos.Profiles1
// (Profiles.createProfile / renameProfile / deleteProfile). Your own name and PIN are in
// MyProfilePane.qml; the shared parts (PIN pad, rename/delete flow, focus return) in ProfilePaneBase.qml.
//
// Accept on another profile's row (a page row) opens its page, ManagedProfilePage (profileRequested);
// Back there returns to this row. Accept on your own row opens nothing: it says it is under My profile.
// A profile deleted on its page is gone from the list: the focus goes to the row at its place.
//
// Adding: "Add profile" opens an inline form (name via the on-screen keyboard, role, PIN
// yes/no); "Create profile" then collects the new PIN twice (standard profiles with a PIN),
// the admin's own PIN, and calls createProfile. See ProfileAddFlow.qml.
//
// Where later work lands: a profile's role (T-211) and parental controls (T-212) are set with
// further rows on the profile's page, beside Rename / Delete.
ProfilePaneBase {
    id: pane

    fallbackRow: addRow

    property bool adding: false
    property string newName: ""
    property string newRole: "standard"
    property bool newUsePin: false

    // A profile row was accepted: the Settings page opens that profile's page (ManagedProfilePage).
    signal profileRequested(string id)

    // The profile whose page was opened last: kept up to date while it exists, so that when it is gone
    // (deleted on its page) the focus lands on the row now at its place.
    property string openedId: ""
    property string openedName: ""
    property int openedIndex: 0
    // The profile's page is open over Settings (until this pane has the focus again).
    property bool covered: false
    onActiveFocusChanged: if (activeFocus) covered = false

    function openProfile(profile) {
        report("", false)
        covered = true
        openedId = profile.id
        openedName = profile.name
        openedIndex = Profiles.profiles.findIndex(p => p.id === profile.id)
        profileRequested(profile.id)
    }

    // A profile's row, also while Settings is covered by a page (then the rows read as hidden and disabled,
    // so focusableRows() has none).
    function rowFor(id) {
        for (let i = 0; i < rows.length; ++i) {
            if (rows[i].objectName === "profileRow_" + id)
                return rows[i]
        }
        return null
    }

    // The opened profile is gone: say so, and focus the row at its place (the one before it at the end of
    // the list, Add profile when none is left). The pane is covered by the page while this runs, or has
    // just got the focus back: only its own focus item moves while covered (T-356).
    function runPendingFocus() {
        if (openedId === "")
            return
        const list = Profiles.profiles
        const at = list.findIndex(p => p.id === openedId)
        if (at >= 0) {
            openedIndex = at
            openedName = list[at].name
            // The list is rebuilt on every change (a rename): the page below keeps its focus on the
            // new row of the profile, not on one that is gone.
            const row = covered ? rowFor(openedId) : null
            if (row)
                row.focus = true
            return
        }
        const next = list[Math.min(openedIndex, list.length - 1)]
        const target = (next ? rowFor(next.id) : null) ?? addRow
        report(qsTr("Profile “%1” deleted.").arg(openedName), false)
        openedId = ""
        if (pane.activeFocus)
            target.forceActiveFocus()
        else
            target.focus = true
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

    // The profiles that exist.
    Repeater {
        model: Profiles.profiles

        SettingRow {
            id: profileRow
            required property var modelData
            objectName: "profileRow_" + modelData.id
            // Another profile opens its page; your own is under My profile (so this row opens nothing).
            kind: modelData.id === Profiles.activeProfile ? "item" : "page"
            u: pane.u
            swatch: modelData.avatar
            label: modelData.name
            onActivated: {
                if (modelData.id === Profiles.activeProfile)
                    pane.report(qsTr("Your own profile is under My profile."), false)
                else
                    pane.openProfile(modelData)
            }
            value: pane.roleText(modelData.role)
                   + (modelData.hasPin ? " · " + qsTr("PIN") : "")
                   + (modelData.id === Profiles.activeProfile ? " · " + qsTr("You") : "")
        }
    }

    SettingRow {
        id: addRow
        objectName: "rowAdd"
        kind: "action"
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
        kind: "page"
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
    // RUY-716: no role choice any more. Kept guests are gone (temporary guests come from "Who's
    // playing?"), so a profile made here is Standard; admins come from first setup.
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
        kind: "action"
        emphasis: "primary"
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
