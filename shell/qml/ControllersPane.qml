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
// failed: "Controllers can't be read right now." and "Try again" instead of the pad rows. The Confirm button row (RUY-40, 06 §11.2) follows the pad rows (only while a pad
// is connected; dimmed when the list failed)
// and comes before Controls in games: a ChoiceRow "As on the controller" / "Bottom" / "Right" for the signed-in profile
// (Input.confirmButton; Left/Right apply it at once through Input1.SetConfirmButton, a refusal puts the stored value
// back and toasts), with a note under it that tells which button confirms on the active pad (position letters until
// RUY-41's glyph sets; the keyboard sentence while no pad has pressed). Without Input1 the row is dimmed "Not available".
// "Controls in games" (RUY-465; value "Default" / "Changed", GameControls) opens ControlsPage: after
// the pad rows, after Pair when no pad is connected, dimmed with "Not available" when the list failed.
SettingsPane {
    id: pane

    property Item overlay      // where the pairing screen is parented

    // A pad row was accepted: the Settings page opens that controller's page.
    signal controllerRequested(string id)
    // "Controls in games" was accepted: the Settings page opens it.
    signal controlsRequested()

    readonly property bool failed: Input.devicesState === "failed"
    readonly property bool loading: Input.devicesState === "loading"

    hints: confirmRow.activeFocus ? [{ button: "Left/Right", text: qsTr("Change") }, { button: "A", text: qsTr("Next") },
                                     { button: "B", text: qsTr("Back") }]
         : pane.focusedPad ? [{ button: "A", text: qsTr("Open") }, { button: "B", text: qsTr("Back") }]
                           : [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Back") }]
    property bool focusedPad: false

    ListModel { id: padModel }

    // The Confirm button row needs a pad to be about (like the note under it); with none connected the
    // pane starts on Pair as before. A failed list shows it dimmed, like Controls in games.
    readonly property bool confirmShown: !pane.failed && !pane.loading && padModel.count > 0

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
            const entry = { padId: p.id, name: p.name, family: p.family, silhouette: p.model, detailLine: ControllerPads.detailText(p),
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

    Component.onCompleted: {
        syncPads()
        Qt.callLater(GameControls.refresh)      // the Controls in games value; not in the pane's key frame
    }
    // The list could not be read: Try again takes the focus (the pad rows it was on are hidden).
    onFailedChanged: {
        if (!failed)
            return
        if (pane.activeFocus)
            retryRow.forceActiveFocus()
        else
            retryRow.focus = true
    }
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
        id: retryRow
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
            required property string silhouette   // the controller model (not `model`: a delegate has one)
            required property string detailLine
            required property string player
            readonly property bool padRow: true
            objectName: "pad_" + padId
            visible: !pane.failed            // the last list is not shown as if it were current
            u: pane.u
            label: name
            iconName: DeviceIcons.iconFor("controller", family, silhouette)
            detail: detailLine
            value: player
            // "DualSense Wireless Controller, PlayStation controller, Player 1, Bluetooth · Battery 62 %"
            // (SettingControl appends the detail).
            accessibleValue: DeviceIcons.kindText("controller", family) + (player !== "" ? ", " + player : "")
            onActiveFocusChanged: if (activeFocus) pane.focusedPad = true
            onActivated: pane.controllerRequested(padId)
        }
    }

    // The Confirm button (06 §11.2): visible once the list is not loading; dimmed "Not available" without Input1.
    ChoiceRow {
        id: confirmRow
        objectName: "rowConfirmButton"
        visible: pane.confirmShown && Input.confirmButtonAvailable
        u: pane.u
        label: qsTr("Confirm button")
        options: [
            { value: "family", label: qsTr("As on the controller") },
            { value: "south", label: qsTr("Bottom") },
            { value: "east", label: qsTr("Right") },
        ]
        value: Input.confirmButton
        // The row shows the stored value: Input.confirmButton changes at once and goes back on a refusal.
        onEdited: v => {
            Input.setConfirmButton(v)
            confirmRow.value = Qt.binding(() => Input.confirmButton)
        }
        accessibleValue: currentLabel + ". " + confirmNote.sentence
        onActiveFocusChanged: if (activeFocus) pane.focusedPad = false
    }
    SettingRow {
        objectName: "rowConfirmButtonUnavailable"
        visible: pane.failed || (pane.confirmShown && !Input.confirmButtonAvailable)
        dimmed: true
        u: pane.u
        label: qsTr("Confirm button")
        value: qsTr("Not available")
        onActiveFocusChanged: if (activeFocus) pane.focusedPad = false
        onActivated: Notifications.show(qsTr("%1: %2.").arg(label).arg(value), "info")
    }
    Connections {
        target: Input
        function onConfirmButtonRefused() {
            Notifications.show(qsTr("Could not change the confirm button"), "error", "", "", qsTr("Try again."))
        }
    }

    // The note under the row: which buttons confirm and go back on the active pad, after the setting.
    Item {
        id: confirmNote
        objectName: "confirmNote"
        visible: confirmRow.visible
        width: parent ? parent.width : 0
        height: visible ? noteRow.height : 0

        readonly property bool pad: Input.activeFamily !== ""
        // Accept is the right button (east) on a Nintendo pad as it is, and with "Right" on every pad.
        readonly property bool acceptEast: Input.confirmButton === "east"
                                           || (Input.confirmButton === "family" && Input.activeFamily === "nintendo")
        // Position letters (A south, B east) until RUY-41's glyph sets.
        readonly property string acceptLetter: acceptEast ? "B" : "A"
        readonly property string backLetter: acceptEast ? "A" : "B"
        readonly property string sentence: pad
            ? qsTr("On this controller: %1 confirms, %2 goes back.").arg(acceptLetter).arg(backLetter)
            : qsTr("On the keyboard: Enter confirms, Esc goes back.")

        Row {
            id: noteRow
            objectName: "confirmNoteRow"
            spacing: Theme.spaceXs * pane.u
            leftPadding: Theme.spaceL * pane.u
            y: -4 * pane.u                 // 4 u closer to its row than the row gap (04 §5)
            Text {
                visible: confirmNote.pad
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("On this controller:")
                color: Theme.text
                font.pixelSize: Theme.typeCaption * pane.u
            }
            ButtonGlyph {
                visible: confirmNote.pad
                objectName: "confirmNoteAccept"
                anchors.verticalCenter: parent.verticalCenter
                u: pane.u
                button: confirmNote.acceptLetter
            }
            Text {
                visible: confirmNote.pad
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("confirms,")
                color: Theme.text
                font.pixelSize: Theme.typeCaption * pane.u
            }
            ButtonGlyph {
                visible: confirmNote.pad
                objectName: "confirmNoteBack"
                anchors.verticalCenter: parent.verticalCenter
                u: pane.u
                button: confirmNote.backLetter
            }
            Text {
                visible: confirmNote.pad
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("goes back.")
                color: Theme.text
                font.pixelSize: Theme.typeCaption * pane.u
            }
            Text {
                objectName: "confirmNoteKeyboard"
                visible: !confirmNote.pad
                anchors.verticalCenter: parent.verticalCenter
                text: confirmNote.sentence
                color: Theme.text
                font.pixelSize: Theme.typeCaption * pane.u
            }
        }
    }

    // Controls in games after the pads (or, dimmed, after Try again).
    SettingRow {
        id: controlsRow
        objectName: "rowControlsInGames"
        visible: pane.failed || (!pane.loading && padModel.count > 0)
        dimmed: pane.failed
        u: pane.u
        label: qsTr("Controls in games")
        value: pane.failed ? qsTr("Not available") : GameControls.changedFor(GameControls.padFor("")) ? qsTr("Changed") : qsTr("Default")
        onActiveFocusChanged: if (activeFocus) pane.focusedPad = true     // it opens a page: A Open
        onActivated: pane.openControls(controlsRow)
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

    // With no pad connected Controls in games comes after Pair (RUY-39 design §1.4).
    SettingRow {
        id: controlsLastRow
        objectName: "rowControlsInGamesLast"
        visible: !pane.failed && !pane.loading && padModel.count === 0
        u: pane.u
        label: qsTr("Controls in games")
        value: GameControls.changedFor(GameControls.padFor("")) ? qsTr("Changed") : qsTr("Default")
        onActiveFocusChanged: if (activeFocus) pane.focusedPad = true
        onActivated: pane.openControls(controlsLastRow)
    }

    function openControls(row) {
        if (row.dimmed) {
            Notifications.show(qsTr("%1: %2.").arg(row.label).arg(row.value), "info")
            return
        }
        pane.controlsRequested()
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
