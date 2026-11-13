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
// Four layouts (`kind`, from the family and the device record's `layout`, RUY-486): "playstation"
// (D-pad upper left, sticks lower centre), "xbox" (also generic, and the Switch Pro: left stick upper
// left, D-pad lower left, right stick lower right of centre), "nintendo" (as xbox, its own words) and
// "nintendo-wiiu" (D-pad and face buttons up, both sticks low). Every stick, D-pad key, face button,
// pill and the touchpad lies inside the body (`bodyContains`, tested); only the shoulders and the
// triggers sit on its edge, as on a real pad. Face buttons carry the position letters (Y B A X) until
// RUY-41's glyphs; paddles and misc1 are not drawn (the raw panel shows them). Decorative: the page
// says in words what was pressed.
Item {
    id: diagram

    property real u: 1
    property string family: ""
    // Input1's device record `layout`: "nintendo-wiiu" or "" (the family's default).
    property string layout: ""
    // input name -> true while held / once pressed since the page opened (Input1 TestInput names).
    property var held: ({})
    property var tried: ({})
    // axis name -> value (sticks -32768..32767, triggers 0..32767).
    property var axes: ({})

    readonly property string kind: layout === "nintendo-wiiu" ? "nintendo-wiiu"
        : family === "playstation" ? "playstation" : family === "nintendo" ? "nintendo" : "xbox"
    readonly property bool playstation: kind === "playstation"
    readonly property bool wiiu: kind === "nintendo-wiiu"
    // The Wii U Pro's ZL / ZR are buttons: they light, their analog track stays empty.
    readonly property bool analogTriggers: !wiiu

    // The words on the pad per layout, in one place (RUY-41 swaps these for the family's glyphs).
    readonly property var words: ({
        "playstation": { l1: "L1", r1: "R1", lt: "L2", rt: "R2", select: qsTr("Create"), start: qsTr("Options"), guide: qsTr("Guide") },
        "xbox": { l1: "LB", r1: "RB", lt: "LT", rt: "RT", select: qsTr("View"), start: qsTr("Menu"), guide: qsTr("Guide") },
        "nintendo": { l1: "L", r1: "R", lt: "ZL", rt: "ZR", select: "−", start: "+", guide: qsTr("Home") },
        "nintendo-wiiu": { l1: "L", r1: "R", lt: "ZL", rt: "ZR", select: "−", start: "+", guide: qsTr("Home") }
    })
    readonly property var word: words[kind]

    // Where things sit per layout, in box units (top left corners; sticks 140, pills 84 x 44).
    readonly property var spots: ({
        "playstation": { select: [344, 164], start: [672, 164], guide: [522, 312], dpad: [210, 190], left: [350, 350], right: [610, 350] },
        "xbox": { select: [364, 180], start: [652, 180], guide: [522, 312], dpad: [350, 330], left: [220, 200], right: [610, 350] },
        "nintendo": { select: [364, 180], start: [652, 180], guide: [522, 312], dpad: [350, 330], left: [220, 200], right: [610, 350] },
        "nintendo-wiiu": { select: [364, 180], start: [652, 180], guide: [522, 174], dpad: [210, 190], left: [350, 390], right: [610, 390] }
    })
    readonly property var spot: spots[kind]

    // The body outline (one path) and a polygon that lies inside it (chords of its curves, bent in
    // where the lower notch is concave): what `bodyContains` tests against.
    readonly property string bodyPath: "M330 140H770C860 140 920 180 950 260L1020 470C1045 545 990 590 930 570C880 555 850 540 810 540H290C250 540 220 555 170 570C110 590 55 545 80 470L150 260C180 180 240 140 330 140Z"
    readonly property var bodyPolygon: [[330, 140], [770, 140], [950, 260], [1020, 470], [930, 570], [866, 549], [810, 540],
                                        [290, 540], [234, 549], [170, 570], [80, 470], [150, 260]]
    function bodyContains(px, py) {
        const p = bodyPolygon
        let inside = false
        for (let i = 0, j = p.length - 1; i < p.length; j = i++) {
            if ((p[i][1] > py) !== (p[j][1] > py) && px < (p[j][0] - p[i][0]) * (py - p[i][1]) / (p[j][1] - p[i][1]) + p[i][0])
                inside = !inside
        }
        return inside
    }

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
            font.pixelSize: (key.width >= 72 * key.u && key.glyph.length <= 3 ? Theme.typeBody : Theme.typeMicro) * key.u
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
            PathSvg { path: diagram.bodyPath }
        }
    }

    // Triggers: a label key over a track that fills with the value.
    Repeater {
        model: [{ input: "left_trigger", x: 2, glyph: diagram.word.lt },
                { input: "right_trigger", x: 1042, glyph: diagram.word.rt }]
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
                    height: diagram.analogTriggers ? parent.height * Math.max(0, Math.min(1, diagram.axis(trigger.modelData.input) / 32767)) : 0
                    radius: width / 2
                    color: Theme.text
                }
            }
        }
    }

    // Shoulders, select / start, Guide, the D-pad and the face buttons (by position, with the
    // position letters), in box units; places and words per layout above. The home glyph comes with
    // RUY-41's icon subset; until then the word. shape: "pill" | "key" (radiusS) | "round".
    readonly property real dpadX: spot.dpad[0]
    readonly property real dpadY: spot.dpad[1]
    readonly property var keys: [
        { input: "l1", x: 230, y: 80, w: 150, h: 48, shape: "pill", glyph: word.l1 },
        { input: "r1", x: 720, y: 80, w: 150, h: 48, shape: "pill", glyph: word.r1 },
        { input: "select", x: spot.select[0], y: spot.select[1], w: 84, h: 44, shape: "pill", glyph: word.select },
        { input: "start", x: spot.start[0], y: spot.start[1], w: 84, h: 44, shape: "pill", glyph: word.start },
        { input: "guide", x: spot.guide[0], y: spot.guide[1], w: 56, h: 56, shape: "round", glyph: word.guide },
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
        x: 440 * diagram.u
        y: 170 * diagram.u
        width: 220 * diagram.u
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
        model: [{ side: "left", click: "l3", x: diagram.spot.left[0], y: diagram.spot.left[1] },
                { side: "right", click: "r3", x: diagram.spot.right[0], y: diagram.spot.right[1] }]
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
