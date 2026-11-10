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
        color: Theme.text
        font.pixelSize: Theme.typeHeadline * root.u
        font.weight: Theme.weightDemiBold
    }

    Rectangle {
        objectName: "pagePlaceholder"
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Placeholder")
        Accessible.focusable: true
        anchors { left: parent.left; top: message.bottom; topMargin: Theme.spaceL * root.u }
        width: 360 * root.u
        height: Theme.buttonHeight * root.u
        radius: height / 2
        focus: true
        color: Theme.blurMax > 0 ? Theme.glass : Theme.glassOpaque   // on L0: opaque without blur (04 §3.6, T-434)
        border.width: activeFocus ? Theme.focusRingWidth * root.u : 1
        border.color: activeFocus ? Theme.focusRing : Theme.glassBorder
        Text {
            anchors.centerIn: parent
            text: qsTr("Placeholder")
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * root.u
            font.weight: Theme.weightDemiBold
        }
    }
}
