import QtQuick
import RuyaShell

// Secondary button (04 §5): a glass pill next to a primary one (Details). Row focus: fill
// `focusFill`, border 1 -> 4 px `focusRing`, no scale.
FocusScope {
    id: button

    property real u: 1
    property string text

    signal accepted()

    implicitWidth: label.implicitWidth + 2 * Theme.spaceXl * u
    implicitHeight: Theme.rowHeight * u

    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.focusable: true

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: button.activeFocus ? Theme.focusFill : Theme.glass
        border.width: button.activeFocus ? Theme.focusRingWidth * button.u : Theme.hairlineAt(button.u)
        border.color: button.activeFocus ? Theme.focusRing : Theme.glassBorder

        Text {
            id: label
            anchors.centerIn: parent
            text: button.text
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * button.u
            font.weight: Theme.weightDemiBold
        }
    }

    Keys.onReturnPressed: { Sfx.select(); button.accepted() }
    Keys.onEnterPressed: { Sfx.select(); button.accepted() }
}
