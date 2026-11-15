import QtQuick
import RuyaShell

// A one-line note under a setting row with button glyphs in its sentence (RUY-500, 04 §5): a Row of
// caption Texts and ButtonGlyphs. `text` is one qsTr sentence with %1 and %2 (so a language can put
// the buttons where its grammar wants them); the note splits it there itself and draws a glyph in
// each gap. A glyph is an `action` ("accept") on the pad's `family` after `confirmMode`, or a button
// `position` ("south") on the family's pad. `sentence` is the full text with the glyphs' names, for
// the row's accessible value. It sits `spaceL` in from the row and 4 u closer to it than the row gap.
Item {
    id: note

    property real u: 1
    property string text: ""
    property string family: ""
    property string confirmMode: "family"
    property string firstAction: ""
    property string firstPosition: ""
    property string secondAction: ""
    property string secondPosition: ""
    // The glyphs' objectNames (tests and the shots find them by these).
    property string firstName: "noteFirst"
    property string secondName: "noteSecond"

    readonly property string firstLabel: firstGlyph.entry.name
    readonly property string secondLabel: secondGlyph.entry.name
    readonly property string sentence: text.replace("%1", firstLabel).replace("%2", secondLabel)
    // The text before %1, between %1 and %2, after %2.
    readonly property var parts: {
        const a = text.split("%1")
        const head = a[0]
        const rest = a.length > 1 ? a.slice(1).join("%1") : ""
        const b = rest.split("%2")
        return [head.trim(), b[0].trim(), b.length > 1 ? b.slice(1).join("%2").trim() : ""]
    }
    readonly property alias glyphRow: noteRow

    width: parent ? parent.width : 0
    height: visible ? noteRow.height : 0

    Row {
        id: noteRow
        objectName: note.objectName + "Row"
        spacing: Theme.spaceXs * note.u
        leftPadding: Theme.spaceL * note.u
        y: -4 * note.u                 // 4 u closer to its row than the row gap (04 §5)
        Text {
            visible: text !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: note.parts[0]
            textFormat: Text.PlainText
            color: Theme.text
            font.pixelSize: Theme.typeCaption * note.u
        }
        ButtonGlyph {
            id: firstGlyph
            objectName: note.firstName
            anchors.verticalCenter: parent.verticalCenter
            u: note.u
            action: note.firstAction
            position: note.firstPosition
            family: note.family
            confirmMode: note.confirmMode
        }
        Text {
            visible: text !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: note.parts[1]
            textFormat: Text.PlainText
            color: Theme.text
            font.pixelSize: Theme.typeCaption * note.u
        }
        ButtonGlyph {
            id: secondGlyph
            objectName: note.secondName
            anchors.verticalCenter: parent.verticalCenter
            u: note.u
            action: note.secondAction
            position: note.secondPosition
            family: note.family
            confirmMode: note.confirmMode
        }
        Text {
            visible: text !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: note.parts[2]
            textFormat: Text.PlainText
            color: Theme.text
            font.pixelSize: Theme.typeCaption * note.u
        }
    }
}
