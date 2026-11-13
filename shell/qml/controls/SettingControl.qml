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
    // Optional controller button in the icon slot (RUY-465, 04 §5): a `ButtonGlyph` at `glyphSize`
    // (the size of `iconM`) for a row about one button (Remap buttons). The button's name is the
    // label, so the glyph is decorative too. Not together with a swatch or an icon.
    property string glyph
    readonly property bool hasGlyph: glyph !== "" && !hasSwatch && !hasIcon

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

    // Optional second line under the label (RUY-39, 04 §5): `typeCaption` Regular in `text`, `spaceXxs`
    // under the label, both centred in the row together; one line, elided; appended to the accessible
    // name. With a detail the label is one line and elided too. `trailingWidth` is what a subtype draws
    // on the right (SettingRow's value), so the two lines end before it.
    property string detail
    property real trailingWidth: 0
    readonly property bool hasDetail: detail !== ""

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
    Accessible.name: (accessibleValue.length > 0 ? label + ", " + accessibleValue : label)
                     + (hasDetail ? ", " + detail : "")
    Accessible.focusable: true

    Rectangle {
        id: background
        objectName: "rowFill"
        anchors.fill: parent
        radius: control.cornerRadius
        // A row lies straight on L0, which is blurred on pages (04 §3.6); with no blur (the Performance
        // tier) translucent glass would show the sharp blobs or picture through, so it is opaque (T-434).
        color: control.activeFocus ? Theme.focusFill : (Theme.blurMax > 0 ? Theme.glass : Theme.glassOpaque)
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

    ButtonGlyph {
        objectName: "rowGlyph"
        visible: control.hasGlyph
        anchors { left: parent.left; leftMargin: Theme.spaceL * control.u; verticalCenter: parent.verticalCenter }
        u: control.u
        button: control.glyph
        opacity: control.dimmed ? Theme.disabledOpacity : 1
        Accessible.ignored: true
    }

    // Room for the label and the detail between their left edge and the trailing content.
    readonly property real textWidth: Math.max(0, width - labelText.x - trailingWidth - Theme.spaceL * u)

    Text {
        id: labelText
        objectName: "label"
        visible: control.labelVisible
        anchors {
            left: parent.left
            leftMargin: (control.hasSwatch ? Theme.spaceXxxl
                         : control.hasIcon || control.hasGlyph ? Theme.spaceL + Theme.iconM + Theme.spaceS
                         : Theme.spaceL) * control.u
            verticalCenter: parent.verticalCenter
            // With a detail the pair is centred: the label moves up by half the detail and its gap.
            verticalCenterOffset: control.hasDetail ? -(detailText.height + Theme.spaceXxs * control.u) / 2 : 0
        }
        width: control.hasDetail ? Math.min(implicitWidth, control.textWidth) : implicitWidth
        elide: control.hasDetail ? Text.ElideRight : Text.ElideNone
        textFormat: Text.PlainText      // a label can be a device's own name (Bluetooth, UPower): never markup
        text: control.label
        color: Qt.alpha(Theme.text, control.dimmed ? Theme.disabledOpacity : 1)
        font.pixelSize: Theme.typeBody * control.u
    }

    Text {
        id: detailText
        objectName: "detail"
        visible: control.hasDetail && control.labelVisible
        anchors { left: labelText.left; top: labelText.bottom; topMargin: Theme.spaceXxs * control.u }
        width: Math.min(implicitWidth, control.textWidth)
        elide: Text.ElideRight
        textFormat: Text.PlainText      // a device's battery and connection: plain words
        text: control.detail
        color: Qt.alpha(Theme.text, control.dimmed ? Theme.disabledOpacity : 1)
        font.pixelSize: Theme.typeCaption * control.u
    }
}
