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
    height: Theme.rowHeight * u
    activeFocusOnTab: true
    Behavior on opacity { NumberAnimation { duration: Theme.focusMs } }   // the pane's peek-row cue (T-185); instant under reduced motion

    // What a screen reader says after the label: the subtype sets it (a value, "on"/"off").
    property string accessibleValue
    Accessible.role: Accessible.Button
    Accessible.name: accessibleValue.length > 0 ? label + ", " + accessibleValue : label
    Accessible.focusable: true

    Rectangle {
        id: background
        anchors.fill: parent
        radius: height / 2
        color: control.activeFocus ? Theme.focusFill : Theme.glass
        border.width: control.activeFocus ? Theme.focusRingWidth * control.u : 0     // unfocused: the lit rim below
        border.color: Theme.focusRing
        Behavior on color { ColorAnimation { duration: Theme.focusMs } }
    }
    GlassLayers {
        objectName: "rowLayers"
        anchors.fill: parent
        u: control.u
        radius: height / 2
        grain: false                // a row is not blurred
        rim: !control.activeFocus   // the focus ring replaces the rim
    }

    Rectangle {
        id: swatchDot
        objectName: "swatch"
        visible: control.hasSwatch
        anchors { left: parent.left; leftMargin: Theme.spaceM * control.u; verticalCenter: parent.verticalCenter }
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
            leftMargin: (control.hasSwatch ? Theme.spaceXxxl : Theme.spaceL) * control.u
            verticalCenter: parent.verticalCenter
        }
        text: control.label
        color: Theme.text
        font.pixelSize: Theme.typeBody * control.u
    }
}
