pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import RuyaShell

// One plot of the stick editor (RUY-465, 04 §5 "Stick plot"): 320 × 320 u, from a stick's settings
// and its position (`stickX`, `stickY`, -1..1, y down as the pad sends it), through 06 §7's formula
// (GameControls.response).
//  - kind "position": the stick's circle (2 u `glassRimLit`), a hairline cross (2 u `glassBorder`),
//    the outer dead-zone band (radius 1 − outer to 1) and the inner dead zone (radius inner)
//    filled `selectedFill`; the raw position as a 28 u ring (3 u, `text`); what the game sees as a
//    28 u `primaryFill` dot in the same direction at radius `out` (inverted per axis after).
//  - kind "response": stick magnitude r across, the output up, both 0..1 over 320 u; axes 2 u
//    `glassRimLit`, the diagonal 2 u `glassBorder` dashed 8/8, the inner dead zone a `selectedFill`
//    band, the curve as a 4 u `text` line (33 samples), the current input as a 28 u `primaryFill` dot.
// Literals of this component (no tokens for them): 320, 28, 3, 4, 8/8 and the 33 samples.
Item {
    id: plot

    property real u: 1
    property string kind: "position"
    property var settings: GameControls.stickDefaults
    property real stickX: 0
    property real stickY: 0

    readonly property real side: 320 * u
    readonly property real half: side / 2
    readonly property real marker: 28 * u
    // The input's magnitude and what the game sees for it (0..1).
    readonly property real r: Math.min(1, Math.sqrt(stickX * stickX + stickY * stickY))
    readonly property real out: GameControls.response(r, settings)
    // The output's direction, after the per-axis inversion.
    readonly property real outX: r > 0 ? stickX / r * out * (settings.invert_x ? -1 : 1) : 0
    readonly property real outY: r > 0 ? stickY / r * out * (settings.invert_y ? -1 : 1) : 0

    width: side
    height: side

    // ---- position ------------------------------------------------------------------------------
    Item {
        objectName: "positionPlot"
        anchors.fill: parent
        visible: plot.kind === "position"

        Rectangle {
            objectName: "outerBand"
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: plot.settings.outer_deadzone * plot.half
            border.color: Theme.selectedFill
        }
        Rectangle {
            objectName: "innerZone"
            anchors.centerIn: parent
            width: 2 * plot.settings.inner_deadzone * plot.half
            height: width
            radius: width / 2
            color: Theme.selectedFill
        }
        Rectangle {
            anchors.centerIn: parent
            width: parent.width
            height: 2 * plot.u
            color: Theme.glassBorder
        }
        Rectangle {
            anchors.centerIn: parent
            width: 2 * plot.u
            height: parent.height
            color: Theme.glassBorder
        }
        Rectangle {
            objectName: "stickCircle"
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: 2 * plot.u
            border.color: Theme.glassRimLit
        }
        Rectangle {
            objectName: "rawRing"
            width: plot.marker
            height: width
            radius: width / 2
            x: plot.half + plot.stickX * plot.half - width / 2
            y: plot.half + plot.stickY * plot.half - height / 2
            color: "transparent"
            border.width: 3 * plot.u
            border.color: Theme.text
        }
        Rectangle {
            objectName: "outputDot"
            width: plot.marker
            height: width
            radius: width / 2
            x: plot.half + plot.outX * plot.half - width / 2
            y: plot.half + plot.outY * plot.half - height / 2
            color: Theme.primaryFill
        }
    }

    // ---- response ------------------------------------------------------------------------------
    Item {
        objectName: "responsePlot"
        anchors.fill: parent
        visible: plot.kind === "response"

        Rectangle {
            objectName: "innerBand"
            width: plot.settings.inner_deadzone * plot.side
            height: parent.height
            color: Theme.selectedFill
        }
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: Theme.glassBorder
                strokeWidth: 2 * plot.u
                strokeStyle: ShapePath.DashLine
                dashPattern: [4, 4]                  // 8 u on, 8 u off at a 2 u stroke
                fillColor: "transparent"
                startX: 0
                startY: plot.side
                PathLine { x: plot.side; y: 0 }
            }
        }
        Shape {
            objectName: "curve"
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: Theme.text
                strokeWidth: 4 * plot.u
                fillColor: "transparent"
                joinStyle: ShapePath.RoundJoin
                capStyle: ShapePath.RoundCap
                PathPolyline {
                    path: {
                        const points = []
                        for (let i = 0; i <= 32; ++i) {
                            const x = i / 32
                            points.push(Qt.point(x * plot.side, plot.side - GameControls.response(x, plot.settings) * plot.side))
                        }
                        return points
                    }
                }
            }
        }
        Rectangle {
            width: 2 * plot.u
            height: parent.height
            color: Theme.glassRimLit
        }
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 2 * plot.u
            color: Theme.glassRimLit
        }
        Rectangle {
            objectName: "responseDot"
            width: plot.marker
            height: width
            radius: width / 2
            x: plot.r * plot.side - width / 2
            y: plot.side - plot.out * plot.side - height / 2
            color: Theme.primaryFill
        }
    }
}
