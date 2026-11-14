pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import RuyaShell

// A controller button or key on a primaryFill circle (04 §3.7, RUY-41): the glyph of an `action`
// (06 §11.1: accept, back, options, tabPrev, ...) on the active input, after the Confirm setting, or
// of a button `position` (south, east, l1, ...) on a pad of `family`. Glyphs.qml is the table: Xbox
// and Nintendo letters, our own PlayStation shapes, the keyboard's key caps, the generic position
// diamonds. Words and caps longer than one letter make a pill. `family` and `confirmMode` follow the
// active input unless a caller sets them (a controller's own page draws that pad's glyphs).
Rectangle {
    id: glyph

    property string action: ""
    property string position: ""
    property string family: Input.activeFamily
    property string confirmMode: Input.confirmButton
    property real u: 1
    // The colour of the letter, shape or dots: onPrimary on the primaryFill circle (a drawn pad's
    // face button sets its own fill and ink).
    property color ink: Theme.onPrimary

    readonly property var entry: action !== "" ? Glyphs.glyphFor(action, family, confirmMode)
                                               : Glyphs.glyphForPosition(position, family)
    // What is drawn: "text" (with `shown`), "shape" (with `shape`) or "dots" (with `dotPosition`).
    readonly property string kind: entry.kind
    readonly property string shown: entry.text
    readonly property string shape: entry.shape
    readonly property string dotPosition: entry.kind === "dots" ? entry.position : ""

    implicitHeight: Theme.glyphSize * u
    implicitWidth: kind === "text" ? Math.max(implicitHeight, letter.implicitWidth + 2 * Theme.spaceXs * u) : implicitHeight
    radius: height / 2
    color: Theme.primaryFill

    Accessible.role: Accessible.StaticText
    Accessible.name: entry.name

    Text {
        id: letter
        objectName: "glyphText"
        visible: glyph.kind === "text"
        anchors.centerIn: parent
        text: glyph.shown
        color: glyph.ink
        font.pixelSize: Theme.typeMicro * glyph.u
        font.weight: Theme.weightBold
    }

    // The PlayStation shapes, our own drawings (no vendor artwork): strokes in onPrimary in a box of
    // half the circle, drawn in path units of 100.
    Shape {
        id: shapeItem
        objectName: "glyphShape"
        visible: glyph.kind === "shape"
        anchors.centerIn: parent
        width: glyph.height / 2
        height: width
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: glyph.ink
            strokeWidth: glyph.height / 16          // 2.5 u at glyphSize 40, a proportion of the glyph
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            scale: Qt.size(shapeItem.width / 100, shapeItem.height / 100)
            PathSvg {
                path: glyph.shape === "cross" ? "M14 14L86 86M86 14L14 86"
                    : glyph.shape === "circle" ? "M50 10A40 40 0 1 1 49.99 10Z"
                    : glyph.shape === "square" ? "M14 14H86V86H14Z"
                    : glyph.shape === "triangle" ? "M50 10L92 84H8Z" : ""
            }
        }
    }

    // The generic set: four dots in a diamond, the one at the button's position filled.
    Item {
        id: dots
        objectName: "glyphDots"
        visible: glyph.kind === "dots"
        anchors.centerIn: parent
        width: glyph.height * 0.6                   // a proportion of the glyph
        height: width
        Repeater {
            model: [{ p: "north", x: 0.5, y: 0 }, { p: "east", x: 1, y: 0.5 }, { p: "south", x: 0.5, y: 1 }, { p: "west", x: 0, y: 0.5 }]
            Rectangle {
                required property var modelData
                objectName: "glyphDot_" + modelData.p
                readonly property bool filled: modelData.p === glyph.dotPosition
                width: dots.width / 3
                height: width
                radius: width / 2
                x: modelData.x * (dots.width - width)
                y: modelData.y * (dots.height - width)
                color: filled ? glyph.ink : "transparent"
                border.width: filled ? 0 : 1.5 * glyph.u     // a hairline ring
                border.color: glyph.ink
            }
        }
    }
}
