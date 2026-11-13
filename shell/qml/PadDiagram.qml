pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import RuyaShell

// A drawn controller for the Button test (RUY-39, 04 §5 "PadDiagram"): a 1100 x 600 u box with the
// body (one path, `glass` with a 2 u `glassRimLit` stroke) and every control the test can show. Each
// control is idle (`glass`, 1 u `glassBorder`), tried (pressed since the page opened: `selectedFill`,
// 2 u `glassRimLit`) or held (`primaryFill`, its glyph in `onPrimary`). Sticks are 140 u circles with a
// 36 u dot that follows the axis (+-52 u), filled while clicked; the triggers are pills that fill from
// the bottom with their value. No animations: the drawing follows the stream as it comes.
// PlayStation layout as drawn on the board; Xbox, Nintendo and generic pads swap the left stick and
// the D-pad. Face buttons carry the position letters (Y B A X) until RUY-41's glyphs; paddles and
// misc1 are not drawn (the raw panel shows them). Decorative: the page says in words what was pressed.
Item {
    id: diagram

    property real u: 1
    property string family: ""
    // input name -> true while held / once pressed since the page opened (Input1 TestInput names).
    property var held: ({})
    property var tried: ({})
    // axis name -> value (sticks -32768..32767, triggers 0..32767).
    property var axes: ({})

    readonly property bool playstation: family === "playstation"
    readonly property bool nintendo: family === "nintendo"

    width: 1100 * u
    height: 600 * u

    function look(name) {
        return held[name] === true ? "held" : tried[name] === true ? "tried" : "idle"
    }
    function axis(name) {
        const v = axes[name]
        return v === undefined ? 0 : v
    }

    // A control's face, by its look ("idle" | "tried" | "held"). An inline component has no access to
    // the diagram's id, so the size unit and the look are passed in.
    component Key: Rectangle {
        id: key
        property real u: 1
        property string input
        property string glyph
        property string look: "idle"
        objectName: "padCtl_" + input
        color: look === "held" ? Theme.primaryFill : look === "tried" ? Theme.selectedFill : Theme.glass
        border.width: (look === "idle" ? 1 : look === "tried" ? 2 : 0) * u
        border.color: look === "tried" ? Theme.glassRimLit : Theme.glassBorder
        Text {
            anchors.centerIn: parent
            visible: key.glyph !== ""
            text: key.glyph
            color: key.look === "held" ? Theme.onPrimary : Theme.text
            font.pixelSize: (key.width >= 72 * key.u ? Theme.typeBody : Theme.typeMicro) * key.u
            font.weight: Theme.weightDemiBold
        }
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: Theme.glass
            strokeColor: Theme.glassRimLit
            strokeWidth: 2 * diagram.u
            scale: Qt.size(diagram.u, diagram.u)
            PathSvg {
                path: "M330 140H770C860 140 920 180 950 260L1020 470C1045 545 990 590 930 570C880 555 850 500 810 450H290C250 500 220 555 170 570C110 590 55 545 80 470L150 260C180 180 240 140 330 140Z"
            }
        }
    }

    // Triggers: a label key over a track that fills with the value.
    Repeater {
        model: [{ input: "left_trigger", x: 2, glyph: diagram.playstation ? "L2" : diagram.nintendo ? "ZL" : "LT" },
                { input: "right_trigger", x: 1042, glyph: diagram.playstation ? "R2" : diagram.nintendo ? "ZR" : "RT" }]
        Item {
            id: trigger
            required property var modelData
            x: modelData.x * diagram.u
            y: 96 * diagram.u
            width: 56 * diagram.u
            height: 234 * diagram.u
            Key {
                u: diagram.u
                look: diagram.look(trigger.modelData.input)
                width: parent.width
                height: width
                radius: Theme.radiusS * diagram.u
                input: trigger.modelData.input
                glyph: trigger.modelData.glyph
            }
            Rectangle {
                objectName: "padTrack_" + trigger.modelData.input
                y: 74 * diagram.u
                width: parent.width
                height: 160 * diagram.u
                radius: width / 2
                color: Theme.glass
                border.width: diagram.u
                border.color: Theme.glassBorder
                clip: true
                Rectangle {
                    objectName: "padTrackFill_" + trigger.modelData.input
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: parent.height * Math.max(0, Math.min(1, diagram.axis(trigger.modelData.input) / 32767))
                    radius: width / 2
                    color: Theme.text
                }
            }
        }
    }

    // Shoulders, Create / Options, Guide, the D-pad and the face buttons (by position, with the
    // position letters), in box units. D-pad: PlayStation upper left, the others lower left (where
    // PlayStation has its left stick). shape: "pill" | "key" (radiusS) | "round".
    readonly property real dpadX: playstation ? 210 : 350
    readonly property real dpadY: playstation ? 190 : 350
    readonly property var keys: [
        { input: "l1", x: 230, y: 80, w: 150, h: 48, shape: "pill", glyph: playstation ? "L1" : nintendo ? "L" : "LB" },
        { input: "r1", x: 720, y: 80, w: 150, h: 48, shape: "pill", glyph: playstation ? "R1" : nintendo ? "R" : "RB" },
        { input: "select", x: 372, y: 180, w: 40, h: 68, shape: "pill", glyph: "" },
        { input: "start", x: 688, y: 180, w: 40, h: 68, shape: "pill", glyph: "" },
        // The home glyph comes with RUY-41's icon subset; until then the word.
        { input: "guide", x: 522, y: 312, w: 56, h: 56, shape: "round", glyph: qsTr("Guide") },
        { input: "dpad_up", x: dpadX + 62, y: dpadY, w: 56, h: 56, shape: "key", glyph: "" },
        { input: "dpad_down", x: dpadX + 62, y: dpadY + 124, w: 56, h: 56, shape: "key", glyph: "" },
        { input: "dpad_left", x: dpadX, y: dpadY + 62, w: 56, h: 56, shape: "key", glyph: "" },
        { input: "dpad_right", x: dpadX + 124, y: dpadY + 62, w: 56, h: 56, shape: "key", glyph: "" },
        { input: "north", x: 764, y: 170, w: 72, h: 72, shape: "round", glyph: "Y" },
        { input: "east", x: 838, y: 244, w: 72, h: 72, shape: "round", glyph: "B" },
        { input: "south", x: 764, y: 318, w: 72, h: 72, shape: "round", glyph: "A" },
        { input: "west", x: 690, y: 244, w: 72, h: 72, shape: "round", glyph: "X" }
    ]

    // Touchpad (PlayStation only).
    Rectangle {
        objectName: "padTouchpad"
        visible: diagram.playstation
        x: 430 * diagram.u
        y: 170 * diagram.u
        width: 240 * diagram.u
        height: 120 * diagram.u
        radius: Theme.radiusM * diagram.u
        color: Theme.glass
        border.width: diagram.u
        border.color: Theme.glassBorder
        Text {
            anchors.centerIn: parent
            text: qsTr("Touchpad")
            color: Theme.text
            font.pixelSize: Theme.typeCaption * diagram.u
        }
    }

    Repeater {
        model: diagram.keys
        Key {
            required property var modelData
            u: diagram.u
            look: diagram.look(modelData.input)
            input: modelData.input
            glyph: modelData.glyph
            x: modelData.x * diagram.u
            y: modelData.y * diagram.u
            width: modelData.w * diagram.u
            height: modelData.h * diagram.u
            radius: modelData.shape === "key" ? Theme.radiusS * diagram.u : Math.min(width, height) / 2
        }
    }

    // Sticks.
    Repeater {
        model: [{ side: "left", click: "l3", x: diagram.playstation ? 350 : 210, y: diagram.playstation ? 350 : 190 },
                { side: "right", click: "r3", x: 610, y: 350 }]
        Rectangle {
            id: stick
            required property var modelData
            readonly property string look: diagram.look(modelData.click)
            objectName: "padStick_" + modelData.side
            x: modelData.x * diagram.u
            y: modelData.y * diagram.u
            width: 140 * diagram.u
            height: width
            radius: width / 2
            color: look === "held" ? Theme.primaryFill : look === "tried" ? Theme.selectedFill : Theme.glass
            border.width: (look === "tried" ? 2 : 1) * diagram.u
            border.color: look === "tried" ? Theme.glassRimLit : Theme.glassBorder
            Rectangle {       // the 3 u inner ring
                anchors.centerIn: parent
                width: parent.width - 24 * diagram.u
                height: width
                radius: width / 2
                color: "transparent"
                border.width: 3 * diagram.u
                border.color: Theme.glassBorder
            }
            Rectangle {
                objectName: "padStickDot_" + stick.modelData.side
                width: 36 * diagram.u
                height: width
                radius: width / 2
                color: stick.look === "held" ? Theme.onPrimary : Theme.text
                x: (stick.width - width) / 2 + 52 * diagram.u * diagram.axis(stick.modelData.side + "_x") / 32768
                y: (stick.height - height) / 2 + 52 * diagram.u * diagram.axis(stick.modelData.side + "_y") / 32768
            }
        }
    }
}
