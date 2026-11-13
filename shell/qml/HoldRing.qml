import QtQuick
import QtQuick.Shapes
import RuyaShell

// The Hold ring (04 §5, 02 §1.7): the long-press feedback on an item that has an Options menu. A round
// disc `buttonHeight` across in `glassOpaque` with the `more_horiz` glyph in its centre, a
// `focusRingWidth` track in `glassBorder` on its edge and over it an arc in `focusRing` with round ends
// that grows clockwise from 12 o'clock. The owner (AcceptHold) says when it is `shown` and how far the
// hold has come (`progress`, 0 to 1); the ring fades in over `focusMs` when it appears and is cut when it
// goes. Place it with `anchors.centerIn` on the art of a card or on a hero pill. Never focusable.
Item {
    id: ring

    property real u: 1
    property bool shown: false
    property real progress: 0

    readonly property real diameter: Theme.buttonHeight * u
    readonly property real stroke: Theme.focusRingWidth * u
    // The arc's radius: its stroke lies on the disc's edge, inside it.
    readonly property real arcRadius: diameter / 2 - stroke / 2

    width: diameter
    height: diameter
    visible: opacity > 0
    opacity: 0
    Accessible.ignored: true
    activeFocusOnTab: false

    onShownChanged: {
        if (shown) {
            if (Theme.focusMs > 0)
                fadeIn.restart()
            else
                opacity = 1
        } else {
            fadeIn.stop()
            opacity = 0              // a release cuts it: no fade out
        }
    }

    NumberAnimation {
        id: fadeIn
        target: ring
        property: "opacity"
        from: 0
        to: 1
        duration: Theme.focusMs
    }

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Theme.glassOpaque
    }

    Icon {
        anchors.centerIn: parent
        u: ring.u
        name: "more_horiz"
        color: Theme.text
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            objectName: "holdRingTrack"
            strokeColor: Theme.glassBorder
            strokeWidth: ring.stroke
            fillColor: "transparent"
            PathAngleArc {
                centerX: ring.diameter / 2
                centerY: ring.diameter / 2
                radiusX: ring.arcRadius
                radiusY: ring.arcRadius
                startAngle: -90
                sweepAngle: 360
            }
        }
        ShapePath {
            objectName: "holdRingArc"
            strokeColor: ring.progress > 0 ? Theme.focusRing : "transparent"   // a round cap would draw a dot at 0
            strokeWidth: ring.stroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: ring.diameter / 2
                centerY: ring.diameter / 2
                radiusX: ring.arcRadius
                radiusY: ring.arcRadius
                startAngle: -90
                sweepAngle: 359.9 * Math.max(0, Math.min(1, ring.progress))
            }
        }
    }
}
