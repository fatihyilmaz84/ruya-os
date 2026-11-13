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
    // The icon a kind brings when the row sets none (the message row's `info`, RUY-512).
    property string defaultIconName
    readonly property string shownIconName: iconName !== "" ? iconName : defaultIconName
    readonly property bool hasIcon: shownIconName !== "" && !hasSwatch
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
    // A second line a kind supplies when `detail` is empty (an action's status, RUY-512).
    property string detailFallback
    readonly property string detailShown: detail !== "" ? detail : detailFallback
    property real trailingWidth: 0
    readonly property bool hasDetail: detailShown !== ""

    // The row's look by kind (RUY-512, 04 §5 "Setting row kinds"). `flat`: a fact or a message, with no
    // fill and no GlassLayers at rest (focus is the normal row focus). `ruleBelow`: a hairline along the
    // bottom edge, set by the pane when the next visible row is a fact too. `centered`: label (and
    // detail) centred in the row, the icon `spaceS` before the label (an action). `primary`: the
    // `primaryFill` pill with its ring `focusRingOffset` outside. `labelWeight`: DemiBold for an action
    // and the current item.
    property bool flat: false
    property bool ruleBelow: false
    property bool centered: false
    property bool primary: false
    property int labelWeight: Font.Normal
    // The label's colour (onPrimary on a primary action).
    property color labelColor: Theme.text

    // What the hint bar shows while this row has the focus (SettingsPane, 04 §5): a list of
    // { button, text }. `hintKind` picks the default; a row names its own verb with `hints:`.
    property string hintKind: "item"
    property var hints: {
        const back = { button: "B", text: qsTr("Back") }
        switch (hintKind) {
        case "info":
            return [back]
        case "page":
            return [{ button: "A", text: qsTr("Open") }, back]
        case "toggle":
            return [{ button: "A", text: qsTr("Toggle") }, back]
        case "choice":
            return [{ button: "Left/Right", text: qsTr("Change") }, { button: "A", text: qsTr("Next") }, back]
        case "slider":
            return [{ button: "Left/Right", text: qsTr("Adjust") }, back]
        default:
            return [{ button: "A", text: qsTr("Select") }, back]
        }
    }

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
                     + (detail !== "" ? ", " + detail : "")
    Accessible.focusable: true

    Rectangle {
        id: background
        objectName: "rowFill"
        anchors.fill: parent
        radius: control.cornerRadius
        // A row lies straight on L0, which is blurred on pages (04 §3.6); with no blur (the Performance
        // tier) translucent glass would show the sharp blobs or picture through, so it is opaque (T-434).
        // A flat row (a fact, a message) has no fill at rest: the clear colour is focusFill's own, at alpha 0,
        // so the focus fade does not pass through black. A primary action keeps its fill when focused.
        color: control.primary ? Theme.primaryFill
               : control.activeFocus ? Theme.focusFill
               : control.flat ? Qt.alpha(Theme.focusFill, 0)
               : (Theme.blurMax > 0 ? Theme.glass : Theme.glassOpaque)
        border.width: control.activeFocus && !control.primary ? Theme.focusRingWidth * control.u : 0     // unfocused: the lit rim below
        border.color: Theme.focusRing
        Behavior on color { ColorAnimation { duration: Theme.focusMs } }
    }
    GlassLayers {
        objectName: "rowLayers"
        anchors.fill: parent
        u: control.u
        radius: control.cornerRadius
        visible: !control.primary && (!control.flat || control.activeFocus)
        grain: false                // a row is not blurred
        rim: !control.activeFocus   // the focus ring replaces the rim
    }

    // The focus ring of a primary action: outside the pill, a dark gap between (as PrimaryButton).
    Rectangle {
        objectName: "rowRingOutside"
        visible: control.primary && control.activeFocus
        anchors.fill: parent
        anchors.margins: -Theme.focusRingOffset * control.u
        radius: height / 2
        color: "transparent"
        border.width: Theme.focusRingWidth * control.u
        border.color: Theme.focusRing
    }

    // Between two facts (the pane sets ruleBelow): a hairline along the bottom edge.
    Rectangle {
        objectName: "rowRule"
        visible: control.ruleBelow && control.flat && !control.activeFocus
        anchors { left: parent.left; leftMargin: Theme.spaceL * control.u; right: parent.right; rightMargin: Theme.spaceL * control.u; bottom: parent.bottom }
        height: Theme.hairlineAt(control.u)
        color: Theme.glassBorder
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
        anchors {
            left: control.centered ? undefined : parent.left
            leftMargin: Theme.spaceL * control.u
            right: control.centered ? labelText.left : undefined
            rightMargin: Theme.spaceS * control.u
            verticalCenter: parent.verticalCenter
        }
        u: control.u
        name: control.hasIcon ? control.shownIconName : ""
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
    readonly property real textWidth: control.centered ? Math.max(0, width - 2 * (Theme.spaceL + (hasIcon ? Theme.iconM + Theme.spaceS : 0)) * u)
                                                       : Math.max(0, width - labelText.x - trailingWidth - Theme.spaceL * u)

    Text {
        id: labelText
        objectName: "label"
        visible: control.labelVisible
        anchors {
            left: control.centered ? undefined : parent.left
            horizontalCenter: control.centered ? parent.horizontalCenter : undefined
            leftMargin: (control.hasSwatch ? Theme.spaceXxxl
                         : control.hasIcon || control.hasGlyph ? Theme.spaceL + Theme.iconM + Theme.spaceS
                         : Theme.spaceL) * control.u
            verticalCenter: parent.verticalCenter
            // With a detail the pair is centred: the label moves up by half the detail and its gap.
            verticalCenterOffset: control.hasDetail ? -(detailText.height + Theme.spaceXxs * control.u) / 2 : 0
        }
        width: control.hasDetail || control.centered ? Math.min(implicitWidth, control.textWidth) : implicitWidth
        elide: control.hasDetail || control.centered ? Text.ElideRight : Text.ElideNone
        textFormat: Text.PlainText      // a label can be a device's own name (Bluetooth, UPower): never markup
        text: control.label
        color: Qt.alpha(control.labelColor, control.dimmed ? Theme.disabledOpacity : 1)
        font.pixelSize: Theme.typeBody * control.u
        font.weight: control.labelWeight
    }

    Text {
        id: detailText
        objectName: "detail"
        visible: control.hasDetail && control.labelVisible
        anchors {
            left: control.centered ? undefined : labelText.left
            horizontalCenter: control.centered ? parent.horizontalCenter : undefined
            top: labelText.bottom
            topMargin: Theme.spaceXxs * control.u
        }
        width: Math.min(implicitWidth, control.textWidth)
        elide: Text.ElideRight
        textFormat: Text.PlainText      // a device's battery and connection: plain words
        text: control.detailShown
        color: Qt.alpha(control.labelColor, control.dimmed ? Theme.disabledOpacity : 1)
        font.pixelSize: Theme.typeCaption * control.u
    }
}
