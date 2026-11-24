pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Manage profiles -> a profile (RUY-715, 02 §1.2): what an admin can do with one other
// profile. Opened with params { id } (the profile's id) from ManageProfilesPane. Rows only: the profile's
// role and PIN state as a fact (the title is the name), then "Rename <name>" (focus first) and "Delete <name>". Both go through
// the one rename/delete flow of ProfilePaneBase (PIN pad, name keyboard, delete confirmation), so there is
// no second copy of it; its modals sit on the overlay under the "managedProfile" names. A rename leaves
// the page open with the new name; a delete closes it (ManageProfilesPane then puts the focus on the next
// row). The page also closes when the profile is gone for any other reason, or when the signed-in profile
// is no longer an admin. Your own profile is never opened here (its row says it is under My profile);
// the last admin is not offered Delete. Back (or Left) closes the page.
Page {
    id: page

    readonly property string profileId: String((params ?? {}).id ?? "")
    readonly property var profile: Profiles.profiles.find(p => p.id === profileId)
    // The last profile seen stays while the page closes.
    property var last: ({ name: "", role: "standard", hasPin: false, avatar: "transparent" })
    onProfileChanged: {
        if (profile)
            last = profile
        closeIfStale()
    }
    Component.onCompleted: {
        if (profile)
            last = profile
        Qt.callLater(page.focusFirstAction)
    }
    // Rename is the first row to hold the focus (the pane's own start is the fact row above it, which
    // can still be reached with Up). Only the page's own focus item moves unless the pane is active.
    function focusFirstAction() {
        const first = renameRow.visible ? renameRow : deleteRow
        if (body.activeFocus)
            first.forceActiveFocus()
        else
            first.focus = true
    }

    title: last.name
    hints: body.hints

    readonly property bool other: profile !== undefined && profileId !== Profiles.activeProfile
    readonly property int adminCount: Profiles.profiles.filter(p => p.role === "admin").length
    // The same rules as before the page: another profile, an admin signed in, and never the last admin.
    readonly property bool canRename: other && body.isAdmin
    // The service's rule. For an admin viewing another admin it is never true today (that makes two admins),
    // so it is a guard, not a visible state.
    readonly property bool isLastAdmin: profile !== undefined && profile.role === "admin" && adminCount <= 1
    readonly property bool canDelete: other && body.isAdmin && !isLastAdmin

    // The page closes once (a page that is closing for any reason never asks again: that would close the
    // page below).
    property bool gone: false
    onBackRequested: gone = true
    function closeIfStale() {
        if (gone || (profile !== undefined && body.isAdmin))
            return
        gone = true
        page.backRequested()
    }
    Connections {
        target: body
        function onIsAdminChanged() { page.closeIfStale() }
    }

    ProfilePaneBase {
        id: body
        objectName: "managedProfileBody"
        namePrefix: "managedProfile"
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.min(parent.width, 760 * page.u)
        u: page.u
        overlay: page.overlay
        focus: true
        fallbackRow: renameRow
        onExitRequested: page.backRequested()

        Connections {
            target: body.manageFlow
            function onFinished(kind, id, status, attemptsLeft, retryAfterSecs) {
                if (status === "ok") {
                    if (kind === "rename") {
                        body.report(qsTr("Profile renamed."), false)
                        Notifications.show(qsTr("Profile renamed"), "success")
                    } else {
                        Notifications.show(qsTr("Profile “%1” deleted").arg(body.manageFlow.targetName), "success")
                    }
                } else {
                    Sfx.back()
                    body.report(body.describe(status, attemptsLeft, retryAfterSecs), true)
                    body.restoreFocus()
                }
            }
        }

        // Who it is: the swatch, the role and whether a PIN is set (the title is the name). Read-only.
        SettingRow {
            id: whoRow
            objectName: "rowManagedWho"
            kind: "info"
            u: page.u
            swatch: page.last.avatar ?? "transparent"
            label: body.roleText(page.last.role)
            value: page.last.hasPin ? qsTr("PIN set") : qsTr("No PIN")
        }
        SettingRow {
            id: renameRow
            objectName: "rowRename"
            kind: "action"
            u: page.u
            visible: page.canRename
            label: qsTr("Rename %1").arg(page.last.name)
            onActivated: body.startRename(page.profileId, page.last.name)
        }
        SettingRow {
            id: deleteRow
            objectName: "rowDelete"
            kind: "action"
            u: page.u
            visible: page.canDelete
            label: qsTr("Delete %1").arg(page.last.name)
            onActivated: body.startDelete(page.profileId, page.last.name)
        }

        Text {
            objectName: "managedProfileMessage"
            width: parent ? parent.width : 0
            visible: body.message.length > 0
            textFormat: Text.PlainText
            text: body.message
            color: body.messageIsError ? Theme.errorText : Theme.toastSuccess
            font.pixelSize: Theme.typeBody * page.u
            wrapMode: Text.Wrap
        }
    }
}
