import QtQuick
import RuyaShell

// Placeholder body for pages that have no content yet: a message and one focusable element
// so the focus rules can be tested.
FocusScope {
    id: root

    property real u: 1

    anchors.fill: parent
    focus: true

    Text {
        id: message
        text: qsTr("Coming soon")
        color: Theme.textDim
        font.pixelSize: Theme.typeHeadline * root.u
    }

    Rectangle {
        objectName: "pagePlaceholder"
        anchors { left: parent.left; top: message.bottom; topMargin: 40 * root.u }
        width: 360 * root.u
        height: 76 * root.u
        radius: height / 2
        focus: true
        color: Theme.glass
        border.width: activeFocus ? 4 * root.u : 1
        border.color: activeFocus ? Theme.focusRing : Theme.glassBorder
        Text {
            anchors.centerIn: parent
            text: qsTr("Placeholder")
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * root.u
        }
    }
}
