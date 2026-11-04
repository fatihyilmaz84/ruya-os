pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// What the buttons do right now (04 §5): one glyph and verb per action the screen on top accepts,
// bottom-left in the safe area. `hints` is a list of { button, text }, at most four. Never
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
                objectName: "hint_" + modelData.button
                spacing: Theme.spaceS * bar.u

                readonly property string verb: modelData.text

                ButtonGlyph {
                    button: hint.modelData.button
                    u: bar.u
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
