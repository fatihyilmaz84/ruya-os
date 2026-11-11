import QtQuick
import RuyaShell

// Primary button (04 §5): the one main verb of a screen (Play, Open Store). A pill filled with
// `primaryFill`; focus is the white ring one `focusRingOffset` outside, so a dark gap separates
// it from the fill.
FocusScope {
    id: button

    property real u: 1
    property string text
    // Its action is unavailable for now (a game still closing, T-458): the fill and label dim to
    // disabledOpacity, the focus ring does not, and Accept still fires so the screen can say why.
    property bool dimmed: false

    signal accepted()

    implicitWidth: label.implicitWidth + 2 * Theme.spaceXl * u
    implicitHeight: Theme.rowHeight * u

    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.focusable: true

    Rectangle {
        id: face
        anchors.fill: parent
        radius: height / 2
        color: Theme.primaryFill
        opacity: button.dimmed ? Theme.disabledOpacity : 1

        Text {
            id: label
            anchors.centerIn: parent
            text: button.text
            color: Theme.onPrimary
            font.pixelSize: Theme.typeHeadline * button.u
            font.weight: Theme.weightDemiBold
        }
    }

    // Always visible while focused, never animated away mid-move (04 §4).
    Rectangle {
        objectName: "focusRing"
        anchors.fill: face
        anchors.margins: -Theme.focusRingOffset * button.u
        radius: height / 2
        color: "transparent"
        border.width: Theme.focusRingWidth * button.u
        border.color: Theme.focusRing
        opacity: button.activeFocus ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.focusMs } }
    }

    Keys.onReturnPressed: { Sfx.select(); button.accepted() }
    Keys.onEnterPressed: { Sfx.select(); button.accepted() }
}
