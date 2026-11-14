pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// What the buttons do right now (04 §5): one glyph and verb per action the screen on top accepts,
// bottom-left in the safe area. `hints` is a list of { action, text }, at most four, naming actions
// of 06 §11.1 (accept, back, options, ...), never letters (lint-glyph-actions.ps1); ButtonGlyph draws
// each on the active input (RUY-41). A hint with two actions and one verb (LB RB Sections) gives
// { actions: ["tabPrev", "tabNext"], text }; an optional `family` draws one device's glyph whatever
// the active input is (the capture dialog's Esc). Never focusable; the shell decides what it says
// and whether it shows.
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
                readonly property var actions: modelData.actions ?? [modelData.action]
                objectName: "hint_" + actions.join("_")
                spacing: Theme.spaceS * bar.u

                readonly property string verb: modelData.text

                Repeater {
                    model: hint.actions
                    delegate: ButtonGlyph {
                        required property string modelData
                        action: modelData
                        family: hint.modelData.family ?? Input.activeFamily
                        u: bar.u
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: hint.verb
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * bar.u
                }
            }
        }
    }
}
