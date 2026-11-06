import QtQuick
import QtQuick.Shapes
import RuyaShell

// The 1 px rim of a glass surface (04 §3.8): white 15 %, 30 % on the top-left half, as one ring
// whose fill is a diagonal gradient (a light from 135 degrees). A flat `border` cannot do that.
// The ring is drawn inside the item: it fills `width` x `height` with corner radius `radius`.
Shape {
    id: rim

    property real radius: 0
    property real line: 1            // ring width in pixels (Theme.hairlineAt(u))
    property color lit: Theme.glassRimLit
    property color base: Theme.glassRim

    readonly property real r: Math.max(0, Math.min(radius, Math.min(width, height) / 2))
    readonly property real ri: Math.max(0, r - line)

    preferredRendererType: Shape.CurveRenderer

    ShapePath {
        fillRule: ShapePath.OddEvenFill
        strokeColor: "transparent"
        fillGradient: LinearGradient {
            x1: 0; y1: 0
            x2: (rim.width + rim.height) / 2
            y2: (rim.width + rim.height) / 2
            GradientStop { position: 0.2; color: rim.lit }
            GradientStop { position: 0.8; color: rim.base }
        }

        // Outer rounded rectangle.
        startX: rim.r; startY: 0
        PathLine { x: rim.width - rim.r; y: 0 }
        PathArc { x: rim.width; y: rim.r; radiusX: rim.r; radiusY: rim.r; direction: PathArc.Clockwise }
        PathLine { x: rim.width; y: rim.height - rim.r }
        PathArc { x: rim.width - rim.r; y: rim.height; radiusX: rim.r; radiusY: rim.r; direction: PathArc.Clockwise }
        PathLine { x: rim.r; y: rim.height }
        PathArc { x: 0; y: rim.height - rim.r; radiusX: rim.r; radiusY: rim.r; direction: PathArc.Clockwise }
        PathLine { x: 0; y: rim.r }
        PathArc { x: rim.r; y: 0; radiusX: rim.r; radiusY: rim.r; direction: PathArc.Clockwise }

        // Inner one, inset by `line`: the hole of the ring.
        PathMove { x: rim.line + rim.ri; y: rim.line }
        PathLine { x: rim.width - rim.line - rim.ri; y: rim.line }
        PathArc { x: rim.width - rim.line; y: rim.line + rim.ri; radiusX: rim.ri; radiusY: rim.ri; direction: PathArc.Clockwise }
        PathLine { x: rim.width - rim.line; y: rim.height - rim.line - rim.ri }
        PathArc { x: rim.width - rim.line - rim.ri; y: rim.height - rim.line; radiusX: rim.ri; radiusY: rim.ri; direction: PathArc.Clockwise }
        PathLine { x: rim.line + rim.ri; y: rim.height - rim.line }
        PathArc { x: rim.line; y: rim.height - rim.line - rim.ri; radiusX: rim.ri; radiusY: rim.ri; direction: PathArc.Clockwise }
        PathLine { x: rim.line; y: rim.line + rim.ri }
        PathArc { x: rim.line + rim.ri; y: rim.line; radiusX: rim.ri; radiusY: rim.ri; direction: PathArc.Clockwise }
    }
}
