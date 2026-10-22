import QtQuick
import RuyaShell

// Base of every settings row: a rounded bar with the label on the left and a visible focus
// ring. Subtypes add their own content on the right. Rows handle only the keys they use;
// Up/Down and anything else bubble to the pane, which moves between rows.
FocusScope {
    id: control

    property real u: 1
    property string label
    // Optional colour dot before the label (e.g. a profile's avatar colour).
    property color swatch: "transparent"
    readonly property bool hasSwatch: swatch.a > 0

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

    Rectangle {
        id: swatchDot
        objectName: "swatch"
        visible: control.hasSwatch
        anchors { left: parent.left; leftMargin: 30 * control.u; verticalCenter: parent.verticalCenter }
        width: 40 * control.u
        height: width
        radius: width / 2
        color: control.swatch
    }

    Text {
        id: labelText
        objectName: "label"
        anchors {
            left: parent.left
            leftMargin: (control.hasSwatch ? 90 : 36) * control.u
            verticalCenter: parent.verticalCenter
        }
        text: control.label
        color: Theme.text
        font.pixelSize: 30 * control.u
    }
}
