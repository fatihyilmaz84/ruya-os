pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Hub icon row (04 §5, 02 §1.6, T-471): the Quick Hub's panel entries as one row of round icon buttons
// (`buttonHeight` across, an `iconM` glyph, the Hub row's fill and focus), spread across the panel's
// width; the focused one's name (typeCaption DemiBold) is centred under it. One focus stop: the owner's
// list has the focus, `currentIndex` is the button Left/Right stand on, and the owner handles Accept.
Item {
    id: row

    property real u: 1
    // [{ key ("panel:<id>"), icon, label }]
    property var items: []
    property int currentIndex: 0
    property bool focused: false        // the row has the focus

    readonly property real button: Theme.buttonHeight * u
    readonly property real gap: items.length > 1 ? (width - items.length * button) / (items.length - 1) : 0

    implicitHeight: button + Theme.spaceXs * u + name.implicitHeight
    height: implicitHeight

    Repeater {
        model: row.items
        Rectangle {
            id: entry
            required property int index
            required property var modelData
            readonly property bool focused: row.focused && index === row.currentIndex
            readonly property string label: modelData.label

            objectName: "quickMenuItem_" + modelData.key
            Accessible.role: Accessible.Button
            Accessible.name: label
            x: index * (row.button + row.gap)
            width: row.button
            height: row.button
            radius: height / 2
            color: focused ? Theme.focusFill : Theme.glass
            border.width: focused ? Theme.focusRingWidth * row.u : 1
            border.color: focused ? Theme.focusRing : Theme.glassBorder

            Icon {
                objectName: "hubIconGlyph"
                anchors.centerIn: parent
                u: row.u
                name: entry.modelData.icon
                filled: entry.focused
            }
        }
    }

    // The focused button's name, centred under it and kept inside the row.
    Text {
        id: name
        objectName: "hubIconName"
        readonly property var current: row.items[row.currentIndex]
        visible: row.focused && current !== undefined
        y: row.button + Theme.spaceXs * row.u
        width: Math.min(implicitWidth, row.width)
        x: Math.max(0, Math.min(row.width - width, row.currentIndex * (row.button + row.gap) + row.button / 2 - width / 2))
        textFormat: Text.PlainText
        text: current ? current.label : ""
        color: Theme.text
        font.pixelSize: Theme.typeCaption * row.u
        font.weight: Theme.weightDemiBold
        elide: Text.ElideRight
    }
}
