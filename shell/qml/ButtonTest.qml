pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Press a button to try" (T-260): the buttons the console understands, lighting up while they are
// held and staying marked once tried. The shell sees a controller only as the keys `ruya-inputd`
// makes of it (shell/CLAUDE.md: D-pad and left stick = arrows, A = Return, LB/RB = PageUp/PageDown),
// so X, Y, the triggers and the right stick are not shown here; T-217's full button test is the
// place for the raw buttons and may extend this component.
//
// It takes focus when shown and accepts every key. Start (Menu) emits `continued()`, B / Esc /
// Backspace emits `closed()`; those two are the way out, so they are drawn as hints and not tested.
FocusScope {
    id: test

    property real u: 1
    // Name of the pad being tried, for the heading.
    property string padName: ""

    signal continued()
    signal closed()

    // name -> true while held / true once pressed (names: up down left right a lb rb).
    property var held: ({})
    property var tried: ({})
    readonly property int triedCount: Object.keys(tried).length

    readonly property var keyNames: ({
        [Qt.Key_Up]: "up", [Qt.Key_Down]: "down", [Qt.Key_Left]: "left", [Qt.Key_Right]: "right",
        [Qt.Key_Return]: "a", [Qt.Key_Enter]: "a",
        [Qt.Key_PageUp]: "lb", [Qt.Key_PageDown]: "rb"
    })

    function isHeld(name) { return held[name] === true }
    function isTried(name) { return tried[name] === true }

    function press(key) {
        const name = keyNames[key]
        if (name === undefined)
            return
        const h = Object.assign({}, held)
        h[name] = true
        held = h
        const t = Object.assign({}, tried)
        t[name] = true
        tried = t
    }

    function release(key) {
        const name = keyNames[key]
        if (name === undefined)
            return
        const h = Object.assign({}, held)
        delete h[name]
        held = h
    }

    implicitWidth: column.implicitWidth
    implicitHeight: column.implicitHeight

    Keys.onPressed: event => {
        event.accepted = true
        if (event.key === Qt.Key_Menu) {
            if (!event.isAutoRepeat)
                test.continued()
        } else if (BackKey.isBackOrBackspace(event.key)) {
            if (!event.isAutoRepeat)
                test.closed()
        } else if (!event.isAutoRepeat) {
            test.press(event.key)
        }
    }
    Keys.onReleased: event => {
        event.accepted = true
        if (!event.isAutoRepeat)
            test.release(event.key)
    }

    // One button of the picture: lit while held, filled once tried.
    component Cell: Rectangle {
        id: cell
        required property string name
        required property string label
        property real cellWidth: Theme.rowHeight
        readonly property bool lit: test.isHeld(name)
        readonly property bool done: test.isTried(name)

        objectName: "testButton_" + name
        width: cellWidth * test.u
        height: Theme.rowHeight * test.u
        radius: Theme.radiusS * test.u
        color: lit ? Theme.primaryFill : (done ? Theme.selectedFill : Theme.glass)
        border.width: Theme.hairlineAt(test.u)
        border.color: Theme.glassBorder
        Accessible.role: Accessible.StaticText
        Accessible.name: label + (lit ? qsTr(", pressed") : (done ? qsTr(", tried") : ""))

        Text {
            anchors.centerIn: parent
            text: cell.label
            color: cell.lit ? Theme.onPrimary : Theme.text
            font.pixelSize: Theme.typeCaption * test.u
            font.weight: Theme.weightDemiBold
        }
    }

    Column {
        id: column
        spacing: Theme.spaceL * test.u

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spaceXxl * test.u

            Cell { name: "lb"; label: qsTr("LB"); cellWidth: 120 }
            Cell { name: "rb"; label: qsTr("RB"); cellWidth: 120 }
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spaceXxxl * test.u

            // D-pad and left stick: the arrows.
            Column {
                spacing: Theme.spaceXs * test.u
                Cell { anchors.horizontalCenter: parent.horizontalCenter; name: "up"; label: qsTr("Up"); cellWidth: 140 }
                Row {
                    spacing: Theme.spaceXs * test.u
                    Cell { name: "left"; label: qsTr("Left"); cellWidth: 140 }
                    Cell { name: "right"; label: qsTr("Right"); cellWidth: 140 }
                }
                Cell { anchors.horizontalCenter: parent.horizontalCenter; name: "down"; label: qsTr("Down"); cellWidth: 140 }
            }

            Cell { anchors.verticalCenter: parent.verticalCenter; name: "a"; label: qsTr("A"); cellWidth: 140 }
        }

        Text {
            objectName: "testNote"
            anchors.horizontalCenter: parent.horizontalCenter
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("D-pad and left stick are the arrows.")
            color: Theme.textDim
            font.pixelSize: Theme.typeCaption * test.u
        }
    }
}
