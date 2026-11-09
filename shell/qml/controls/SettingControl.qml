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
    // Optional icon before the label (a name from Icon.qml, e.g. a device's kind, T-199). Decorative:
    // what it shows is also in the label or the accessible value. Not together with a swatch.
    property string iconName
    readonly property bool hasIcon: iconName !== "" && !hasSwatch

    // The row is there but cannot be used now (an audio output that is not connected, T-348): its label
    // and icon are drawn at Theme.disabledOpacity (a value text, e.g. the reason, stays whole). It still takes
    // focus, so the reason can be read.
    property bool dimmed: false

    // A tall row (a chart, T-247) rounds its corners with a token instead of height / 2, and may
    // draw its own text in place of the label.
    property real cornerRadius: height / 2
    property bool labelVisible: true

    // Where the label ends, so a subtype can place text after it (SliderRow's caption, T-312).
    readonly property real labelRight: labelText.x + labelText.width

    // The pane navigates over children that set this.
    readonly property bool focusable: true

    width: parent ? parent.width : 900 * u
    height: Theme.rowHeight * u
    // No activeFocusOnTab (T-190): the window's tab chain would move focus without the pane scrolling;
    // SettingsPane handles Tab / Shift+Tab itself, like Down / Up.
    Behavior on opacity { NumberAnimation { duration: Theme.focusMs } }   // the pane's peek-row cue (T-185); instant under reduced motion

    // What a screen reader says after the label: the subtype sets it (a value, "on"/"off").
    property string accessibleValue
    Accessible.role: Accessible.Button
    Accessible.name: accessibleValue.length > 0 ? label + ", " + accessibleValue : label
    Accessible.focusable: true

    Rectangle {
        id: background
        anchors.fill: parent
        radius: control.cornerRadius
        color: control.activeFocus ? Theme.focusFill : Theme.glass
        border.width: control.activeFocus ? Theme.focusRingWidth * control.u : 0     // unfocused: the lit rim below
        border.color: Theme.focusRing
        Behavior on color { ColorAnimation { duration: Theme.focusMs } }
    }
    GlassLayers {
        objectName: "rowLayers"
        anchors.fill: parent
        u: control.u
        radius: control.cornerRadius
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

    Icon {
        objectName: "rowIcon"
        visible: control.hasIcon
        anchors { left: parent.left; leftMargin: Theme.spaceL * control.u; verticalCenter: parent.verticalCenter }
        u: control.u
        name: control.hasIcon ? control.iconName : ""
        color: Qt.alpha(Theme.text, control.dimmed ? Theme.disabledOpacity : 1)
    }

    Text {
        id: labelText
        objectName: "label"
        visible: control.labelVisible
        anchors {
            left: parent.left
            leftMargin: (control.hasSwatch ? Theme.spaceXxxl
                         : control.hasIcon ? Theme.spaceL + Theme.iconM + Theme.spaceS
                         : Theme.spaceL) * control.u
            verticalCenter: parent.verticalCenter
        }
        textFormat: Text.PlainText      // a label can be a device's own name (Bluetooth, UPower): never markup
        text: control.label
        color: Qt.alpha(Theme.text, control.dimmed ? Theme.disabledOpacity : 1)
        font.pixelSize: Theme.typeBody * control.u
    }
}
