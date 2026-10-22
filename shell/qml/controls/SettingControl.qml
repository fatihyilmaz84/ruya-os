import QtQuick
import RuyaShell

// Base of every settings row: a rounded bar with the label on the left and a visible focus
// ring. Subtypes add their own content on the right. Rows handle only the keys they use;
// Up/Down and anything else bubble to the pane, which moves between rows.
FocusScope {
    id: control

    property real u: 1
    property string label

    // The pane navigates over children that set this.
    readonly property bool focusable: true

    width: parent ? parent.width : 900 * u
    height: 84 * u
    activeFocusOnTab: true

    Rectangle {
        id: background
        anchors.fill: parent
        radius: height / 2
        color: control.activeFocus ? Qt.rgba(1, 1, 1, 0.2) : Theme.glass
        border.width: control.activeFocus ? 4 * control.u : Math.max(1, control.u)
        border.color: control.activeFocus ? Theme.focusRing : Theme.glassBorder
        Behavior on color { ColorAnimation { duration: Theme.focusMs } }
    }

    Text {
        id: labelText
        objectName: "label"
        anchors { left: parent.left; leftMargin: 36 * control.u; verticalCenter: parent.verticalCenter }
        text: control.label
        color: Theme.text
        font.pixelSize: 30 * control.u
    }
}
