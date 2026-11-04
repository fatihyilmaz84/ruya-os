pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// What the buttons do right now (04 §5): one glyph and verb per action the screen on top accepts,
// bottom-left in the safe area. `hints` is a list of { button, text }, at most four; a hint
// with two buttons and one verb (LB RB Sections) gives { buttons: ["LB", "RB"], text }. Never
// focusable; the shell decides what it says and whether it shows.
Item {
    id: bar

    property var hints: []
    property real u: 1
    property bool shown: true

    readonly property int maxHints: 4

    implicitHeight: Theme.glyphSize * u
    implicitWidth: row.implicitWidth
    width: implicitWidth
    height: implicitHeight
    visible: shown && hints.length > 0
    activeFocusOnTab: false

    Row {
        id: row
        spacing: Theme.spaceL * bar.u

        Repeater {
            model: bar.hints.slice(0, bar.maxHints)

            delegate: Row {
                id: hint
                required property var modelData
                readonly property var buttons: modelData.buttons ?? [modelData.button]
                objectName: "hint_" + buttons.join("")
                spacing: Theme.spaceS * bar.u

                readonly property string verb: modelData.text

                Repeater {
                    model: hint.buttons
                    delegate: ButtonGlyph {
                        required property string modelData
                        button: modelData
                        u: bar.u
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: hint.verb
                    color: Theme.textDim
                    font.pixelSize: Theme.typeCaption * bar.u
                }
            }
        }
    }
}
