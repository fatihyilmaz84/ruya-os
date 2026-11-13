pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Controllers (RUY-39 / T-368, 02 §1.2, 06 §11.2): one row per connected controller
// (Input1.ListDevices through ControllerPads.controllers(): the family glyph, the name, a detail line
// "Bluetooth · Battery 62 %", and "Player n" when the record has a player), then "Pair a new
// controller" (the guided pairing screen of the Bluetooth pane). Accept on a pad row opens its
// controller page (controllerRequested). Rows are keyed by the stable id and updated in place, so a
// battery change never moves the focus; a focused row that goes hands the focus to the row before it,
// else the next (04 §4). No pad: "No controllers connected." as an unavailable line. ListDevices
// failed: "Controllers can't be read right now." and "Try again" instead of the pad rows. The Confirm button row is RUY-40's,
// "Controls in games" RUY-42's.
SettingsPane {
    id: pane

    property Item overlay      // where the pairing screen is parented

    // A pad row was accepted: the Settings page opens that controller's page.
    signal controllerRequested(string id)

    readonly property bool failed: Input.devicesState === "failed"
    readonly property bool loading: Input.devicesState === "loading"

    hints: pane.focusedPad ? [{ button: "A", text: qsTr("Open") }, { button: "B", text: qsTr("Back") }]
                           : [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Back") }]
    property bool focusedPad: false

    ListModel { id: padModel }

    function syncPads() {
        const rows = focusableRows()
        // The focused row (also while a page covers Settings: its `focus`, not `activeFocus`).
        const before = rows.findIndex(r => r.focus)
        const wasPad = before >= 0 && rows[before].padRow === true
        const list = ControllerPads.controllers()
        let removedFocused = false
        for (let i = padModel.count - 1; i >= 0; --i) {
            const id = padModel.get(i).padId
            if (!list.some(p => p.id === id)) {
                if (wasPad && rows[before].padId === id)
                    removedFocused = true
                padModel.remove(i)
            }
        }
        for (let i = 0; i < list.length; ++i) {
            const p = list[i]
            const entry = { padId: p.id, name: p.name, family: p.family, detailLine: ControllerPads.detailText(p),
                            player: ControllerPads.playerText(p.slot) }
            let at = -1
            for (let j = 0; j < padModel.count; ++j) {
                if (padModel.get(j).padId === p.id) {
                    at = j
                    break
                }
            }
            if (at < 0) {
                padModel.insert(i, entry)
            } else {
                padModel.set(at, entry)
                if (at !== i)
                    padModel.move(at, i, 1)
            }
        }
        if (removedFocused)
            Qt.callLater(pane.refocusAfter, before)
    }

    // The focused pad row went: the row before it, else the next one (now at its place).
    function refocusAfter(index) {
        const rows = focusableRows()
        if (rows.length === 0)
            return
        const target = rows[Math.max(0, Math.min(index - 1, rows.length - 1))]
        if (pane.activeFocus)
            target.forceActiveFocus()
        else
            target.focus = true          // a covered page: only its own focus item moves (T-356)
        ensureFocusedVisible()
    }

    Component.onCompleted: syncPads()
    Connections {
        target: Input
        function onDevicesChanged() { pane.syncPads() }
    }
    // The Hub's pads give the alias and the battery (ControllerPads); they may arrive later.
    Connections {
        target: Bluetooth
        function onGamepadsChanged() { pane.syncPads() }
        function onDevicesChanged() { pane.syncPads() }
    }
    Connections {
        target: Batteries
        function onDevicesChanged() { pane.syncPads() }
    }

    onVisibleChanged: {
        if (!visible && onboarding && onboarding.shown)
            onboarding.close()
    }

    // Focus is never lost to the pairing screen: back to the row that opened it.
    property Item modalReturn: null
    function restoreFocus() {
        const target = modalReturn
        modalReturn = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        Qt.callLater(pane.ensureFocusedVisible)
    }

    SettingRow {
        objectName: "rowPadsNone"
        visible: !pane.failed && !pane.loading && padModel.count === 0
        enabled: false                       // information: an unavailable line (04 §5)
        u: pane.u
        label: qsTr("No controllers connected.")
    }

    SettingRow {
        objectName: "rowPadsFailed"
        visible: pane.failed
        enabled: false
        u: pane.u
        label: qsTr("Controllers can't be read right now.")
    }

    SettingRow {
        objectName: "rowPadsRetry"
        visible: pane.failed
        u: pane.u
        label: qsTr("Try again")
        onActiveFocusChanged: if (activeFocus) pane.focusedPad = false
        onActivated: Input.refreshDevices()
    }

    Repeater {
        model: padModel
        SettingRow {
            id: padRow
            required property string padId
            required property string name
            required property string family
            required property string detailLine
            required property string player
            readonly property bool padRow: true
            objectName: "pad_" + padId
            visible: !pane.failed            // the last list is not shown as if it were current
            u: pane.u
            label: name
            iconName: DeviceIcons.iconFor("controller", family)
            detail: detailLine
            value: player
            // "DualSense Wireless Controller, PlayStation controller, Player 1, Bluetooth · Battery 62 %"
            // (SettingControl appends the detail).
            accessibleValue: DeviceIcons.kindText("controller", family) + (player !== "" ? ", " + player : "")
            onActiveFocusChanged: if (activeFocus) pane.focusedPad = true
            onActivated: pane.controllerRequested(padId)
        }
    }

    SettingRow {
        objectName: "rowPadsPair"
        u: pane.u
        label: qsTr("Pair a new controller")
        onActiveFocusChanged: if (activeFocus) pane.focusedPad = false
        onActivated: {
            pane.modalReturn = Window.activeFocusItem
            onboardingSlot.active = true
            pane.onboarding.open()
        }
    }

    // The pairing screen is built when it first opens (T-349).
    Loader {
        id: onboardingSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            ControllerOnboarding {
                objectName: "controllerOnboardingControllers"
                u: pane.u
                onClosed: pane.restoreFocus()
            }
        }
    }
    readonly property ControllerOnboarding onboarding: onboardingSlot.item as ControllerOnboarding
}
