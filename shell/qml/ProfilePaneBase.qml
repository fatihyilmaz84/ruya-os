pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// What the two profile panes share (T-315): Settings -> My profile (MyProfilePane) and
// Settings -> Manage profiles (ManageProfilesPane). It holds the signed-in profile
// (`me`, `isAdmin`), the full-screen PIN pad, name keyboard and delete confirmation those panes
// open, the rename/delete flow behind them, the one-line result message, and how focus returns
// to the row a modal came from. The panes only declare their rows (and a Text for `message`
// as their last child); each reacts to manageFlow.finished.
SettingsPane {
    id: pane

    // Full-screen layer for the PIN pad and the keyboard (set by the shell through the page).
    property Item overlay

    // The modals get objectNames from this, so the two panes (both alive at once) don't share any.
    property string namePrefix: "profiles"

    readonly property var me: Profiles.active
    readonly property string myRole: me.role ?? ""
    readonly property bool isAdmin: myRole === "admin"

    // The modals (PIN pad, delete confirmation, name keyboard) are built on the first modal this
    // pane opens (beginModal, T-349), all three at once: the flows use them together.
    property bool modalsBuilt: false
    readonly property PinPad pad: padSlot.item as PinPad
    readonly property ProfileManageFlow manageFlow: flow

    property string message: ""
    property bool messageIsError: false

    // Where focus returns after a modal closes, and the row to use when that row is gone
    // (e.g. "Remove my PIN" after the PIN was removed).
    property Item returnTo: null
    property Item fallbackRow: null

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
        modalsBuilt = true
    }
    function restoreFocus() {
        const target = returnTo
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        Qt.callLater(keepFocus)
    }
    // Focus is never lost: if the row that had it is gone, go to the fallback row, else the
    // first row. Does nothing while a modal (PIN pad, keyboard) holds focus, since then the pane
    // is not active.
    function keepFocus() {
        if (!activeFocus)
            return
        if (!focusableRows().some(r => r.activeFocus))
            (fallbackRow && fallbackRow.visible ? fallbackRow : focusableRows()[0])?.forceActiveFocus()
        ensureFocusedVisible()
    }

    // The rename of a profile (your own, or another one as an admin).
    function startRename(id, name) {
        report("", false)
        beginModal()
        flow.startRename(Profiles.activeProfile, me.hasPin ?? false, id, name)
    }

    // Each modal sits in a Loader on the overlay, which sizes it (T-349, shell/PATTERNS.md).
    Loader {
        id: padSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: pane.modalsBuilt
        sourceComponent: Component {
            PinPad {
                objectName: pane.namePrefix + "PinPad"
                u: pane.u
                onClosed: pane.restoreFocus()
            }
        }
    }

    Loader {
        id: confirmSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: pane.modalsBuilt
        sourceComponent: Component {
            PowerConfirm {
                objectName: pane.namePrefix + "DeleteConfirm"
                u: pane.u
                onClosed: pane.restoreFocus()
            }
        }
    }

    Loader {
        id: entrySlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: pane.modalsBuilt
        sourceComponent: Component {
            TextEntry {
                objectName: pane.namePrefix + "RenameEntry"
                u: pane.u
            }
        }
    }

    ProfileManageFlow {
        id: flow
        pad: pane.pad
        entry: entrySlot.item as TextEntry
        confirm: confirmSlot.item as PowerConfirm
        onAborted: pane.restoreFocus()
    }
}
