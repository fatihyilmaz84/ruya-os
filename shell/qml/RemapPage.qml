pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Controls in games -> Remap buttons (RUY-465, 06 §7). Opened with params { id } (the pad shown;
// none: the first connected one). Left: ControlsIntro. Right, one row per remappable input of the
// pad's family in GameControls.sources' order: the button's glyph in the icon slot, its name, and
// what it acts as now (a glyph and a name, DemiBold when it differs from the layout). Accept opens
// RemapCapture; the first press on the pad becomes the target, the row updates in place and keeps
// the focus, and once the change is saved a toast says "<name> now acts as <target>". Pressing the
// button it already acts as changes nothing. No pad: the rows are dimmed and Accept says "Connect a
// controller first.". Back (or Left) closes the page.
Page {
    id: page

    readonly property string padId: String((params ?? {}).id ?? "")
    readonly property var pad: GameControls.padFor(padId)
    readonly property string family: pad ? pad.family : ""

    title: qsTr("Remap buttons")
    hints: [{ button: "A", text: qsTr("Change") }, { button: "B", text: qsTr("Back") }]

    Component.onCompleted: GameControls.refresh()

    // The toasts of the changes on their way, by GameControls' tag: { title, detail }.
    property var pendingToasts: ({})

    function startCapture(source) {
        if (!page.pad) {
            Sfx.back()
            Notifications.show(qsTr("Connect a controller first."), "info", "", "sports_esports")
            return
        }
        captureSlot.active = true
        page.capture.open(source, page.pad.id, GameControls.shortName(page.pad.name), page.family)
    }

    function applyCapture(source, input) {
        const title = qsTr("%1 now acts as %2").arg(GameControls.buttonName(source, page.family))
                                              .arg(GameControls.buttonName(input, page.family))
        if (!GameControls.setTarget(source, input))
            return                              // the same button: no change
        const next = Object.assign({}, pendingToasts)
        next["remap:" + source] = { title: title, detail: page.pad ? page.pad.name : "" }
        pendingToasts = next
    }

    Connections {
        target: GameControls
        function onSaved(tag) {
            const toast = page.pendingToasts[tag]
            if (!toast)
                return
            const next = Object.assign({}, page.pendingToasts)
            delete next[tag]
            page.pendingToasts = next
            Notifications.show(toast.title, "success", "", "", toast.detail)
        }
        function onFailed(tag) {
            page.pendingToasts = ({})
        }
    }

    // A row of the list: the source's glyph and name, then what it acts as.
    component RemapRow: SettingControl {
        id: row
        property string targetGlyph
        property string targetName
        property bool changed: false
        signal activated()

        accessibleValue: targetName
        trailingWidth: valueRow.width + Theme.spaceS * u

        Row {
            id: valueRow
            anchors { right: parent.right; rightMargin: Theme.spaceL * row.u; verticalCenter: parent.verticalCenter }
            spacing: Theme.spaceS * row.u
            ButtonGlyph {
                objectName: "targetGlyph"
                anchors.verticalCenter: parent.verticalCenter
                u: row.u
                button: row.targetGlyph
                Accessible.ignored: true
            }
            Text {
                objectName: "value"
                anchors.verticalCenter: parent.verticalCenter
                text: row.targetName
                color: Theme.text
                font.pixelSize: Theme.typeBody * row.u
                font.weight: row.changed ? Theme.weightDemiBold : Theme.weightRegular
            }
        }

        function accept() {
            Sfx.select()
            activated()
        }
        Keys.onReturnPressed: event => { if (!event.isAutoRepeat) accept() }
        Keys.onEnterPressed: event => { if (!event.isAutoRepeat) accept() }
    }

    ControlsIntro {
        objectName: "remapIntro"
        u: page.u
        family: page.family
        model: page.pad ? page.pad.model : ""
    }

    SettingsPane {
        id: body
        objectName: "remapBody"
        anchors { left: parent.left; leftMargin: (470 + Theme.spaceXxl) * page.u; right: parent.right; top: parent.top; bottom: parent.bottom }
        u: page.u
        focus: true
        hints: page.hints
        onExitRequested: page.backRequested()

        Repeater {
            model: GameControls.sources
            RemapRow {
                required property string modelData
                objectName: "remap_" + modelData
                u: page.u
                glyph: GameControls.glyphOf(modelData, page.family)
                label: GameControls.buttonName(modelData, page.family)
                targetGlyph: GameControls.glyphOf(GameControls.targetOf(modelData), page.family)
                targetName: GameControls.buttonName(GameControls.targetOf(modelData), page.family)
                changed: GameControls.isChanged(modelData)
                dimmed: page.pad === null
                onActivated: page.startCapture(modelData)
            }
        }
    }

    // Built on its first opening (T-349).
    Loader {
        id: captureSlot
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            RemapCapture {
                id: captureDialog
                objectName: "remapCapture"
                u: page.u
                onCapturedInput: input => page.applyCapture(captureDialog.source, input)
            }
        }
    }
    readonly property RemapCapture capture: captureSlot.item as RemapCapture
}
