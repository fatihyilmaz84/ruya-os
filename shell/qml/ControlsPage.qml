pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Controllers -> Controls in games (RUY-465, 02 §1.2, 06 §7): what games see of the
// signed-in console profile's controllers. Opened with params { id } from a controller page (that
// pad is the one shown), or {} from Settings > Controllers (the first connected pad). Left, not
// focusable: ControlsIntro. Right, a pane: Applies to (All controllers / <Family> controllers / This
// <pad>), Button layout (Standard / Nintendo), Remap buttons (opens RemapPage; "%n changed" or
// "Default"), Left stick and Right stick (open StickPage; "Default" or "Changed"), Export to USB
// drive (the drive's label) and Import from USB drive (ControlsImportPicker), or "Plug in a USB
// drive first." without a drive, and Reset to default (a dialog). Every change saves at once
// (GameControls). Back (or Left) closes the page.
Page {
    id: page

    readonly property string padId: String((params ?? {}).id ?? "")
    readonly property var pad: GameControls.padFor(padId)
    readonly property string family: pad ? pad.family : ""
    // The drive export and import use: the first mounted removable volume, a writable one first.
    readonly property var drive: Storage.volumes.find(v => v.removable && v.mounted && !v.readOnly)
                                 ?? Storage.volumes.find(v => v.removable && v.mounted) ?? null

    title: qsTr("Controls in games")
    hints: body.hints

    Component.onCompleted: GameControls.show(padId)

    // Applies to: the choices the pad allows, and the stored one when it is for another pad.
    readonly property var appliesOptions: {
        const out = [{ value: "all", label: qsTr("All controllers") }]
        const current = GameControls.appliesValue
        if (page.pad && GameControls.familyControllers(page.pad.family) !== "")
            out.push({ value: "family:" + page.pad.family, label: GameControls.familyControllers(page.pad.family) })
        if (page.pad)
            out.push({ value: "device:" + page.pad.id, label: qsTr("This %1").arg(GameControls.shortName(page.pad.name)) })
        if (!out.some(o => o.value === current)) {
            const family = GameControls.familyControllers(GameControls.matchFamily)
            out.push({ value: current, label: current.startsWith("family:") && family !== "" ? family : qsTr("Another controller") })
        }
        return out
    }

    readonly property var layoutOptions: [{ value: "standard", label: qsTr("Standard") },
                                          { value: "nintendo", label: qsTr("Nintendo") }]

    function stickValue(side) {
        return GameControls.stickChanged(side) ? qsTr("Changed") : qsTr("Default")
    }

    ControlsIntro {
        objectName: "controlsIntro"
        u: page.u
        family: page.family
        model: page.pad ? page.pad.model : ""
    }

    SettingsPane {
        id: body
        objectName: "controlsBody"
        anchors { left: parent.left; leftMargin: (470 + Theme.spaceXxl) * page.u; right: parent.right; top: parent.top; bottom: parent.bottom }
        u: page.u
        focus: true
        onExitRequested: page.backRequested()

        ChoiceRow {
            id: appliesRow
            objectName: "rowAppliesTo"
            u: page.u
            label: qsTr("Applies to")
            options: page.appliesOptions
            onEdited: v => GameControls.setAppliesTo(v)
        }
        Binding { target: appliesRow; property: "value"; value: GameControls.appliesValue }

        ChoiceRow {
            id: layoutRow
            objectName: "rowLayout"
            u: page.u
            label: qsTr("Button layout")
            options: page.layoutOptions
            onEdited: v => GameControls.setLayout(v)
        }
        Binding { target: layoutRow; property: "value"; value: GameControls.layout }

        SettingRow {
            objectName: "rowRemap"
            kind: "page"
            u: page.u
            label: qsTr("Remap buttons")
            value: GameControls.remapCount > 0 ? qsTr("%n changed", "", GameControls.remapCount) : qsTr("Default")
            onActivated: page.openRequested("controlsRemap", ({ id: page.padId }))
        }

        SettingRow {
            objectName: "rowLeftStick"
            kind: "page"
            u: page.u
            label: qsTr("Left stick")
            value: page.stickValue("left")
            onActivated: page.openRequested("controlsStick", ({ id: page.padId, side: "left" }))
        }

        SettingRow {
            objectName: "rowRightStick"
            kind: "page"
            u: page.u
            label: qsTr("Right stick")
            value: page.stickValue("right")
            onActivated: page.openRequested("controlsStick", ({ id: page.padId, side: "right" }))
        }

        SettingRow {
            objectName: "rowExport"
            kind: "action"
            visible: page.drive !== null
            u: page.u
            label: qsTr("Export to USB drive")
            value: page.drive ? page.drive.label : ""
            onActivated: GameControls.exportTo(page.drive.id)
        }

        SettingRow {
            objectName: "rowImport"
            kind: "action"
            visible: page.drive !== null
            u: page.u
            label: qsTr("Import from USB drive")
            onActivated: {
                importSlot.active = true
                page.importPicker.open(page.drive)
            }
        }

        SettingRow {
            objectName: "rowNoDrive"
            kind: "info"
            visible: page.drive === null
            enabled: false                       // an unavailable line (04 §5): its label is the message
            u: page.u
            label: qsTr("Plug in a USB drive first.")
        }

        SettingRow {
            objectName: "rowReset"
            kind: "action"
            u: page.u
            label: qsTr("Reset to default")
            onActivated: {
                resetSlot.active = true
                const dialog = page.resetConfirm
                dialog.customTitle = qsTr("Reset controls in games?")
                dialog.detail = qsTr("Every button, stick and curve goes back to the default.")
                dialog.customConfirmName = qsTr("Reset controls")
                dialog.open("custom")
            }
        }
    }

    // Built on their first opening (T-349).
    Loader {
        id: importSlot
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            ControlsImportPicker {
                objectName: "controlsImport"
                u: page.u
            }
        }
    }
    readonly property ControlsImportPicker importPicker: importSlot.item as ControlsImportPicker

    Loader {
        id: resetSlot
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            PowerConfirm {
                objectName: "controlsResetConfirm"
                u: page.u
                onConfirmed: GameControls.resetAll()
            }
        }
    }
    readonly property PowerConfirm resetConfirm: resetSlot.item as PowerConfirm
}
