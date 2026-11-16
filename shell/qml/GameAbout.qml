pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell
import "controls"

// The About section of the game page (02 §1.8, 04 §5 "Game page", RUY-534): the Store's description in
// `typeBody` (line 40, at most 1200 wide: the reading measure; the block spans the column), 6 lines
// elided, and, when an update is ready and has notes, "What's new in <version>" with the notes, 4 lines.
// Anything cut adds "More" with a chevron: Accept opens the text sheet (`readRequested`). One focus stop
// (the flat block: no fill at rest, focused = `focusFill` + ring). No description: the section is left out.
Column {
    id: about

    property real u: 1
    property string description: ""
    property string notes: ""            // shown only with `showNotes` (an update is ready)
    property string version: ""
    property bool showNotes: false
    property string heading: qsTr("About")

    readonly property bool hasText: description !== ""
    readonly property bool notesShown: showNotes && notes !== ""
    readonly property string notesHeading: version !== "" ? qsTr("What's new in %1").arg(version) : qsTr("What's new")
    // Something was cut: the "More" line, and Accept reads the whole text.
    readonly property bool cut: descriptionText.truncated || (notesShown && notesText.truncated)
    readonly property alias block: block

    signal readRequested()

    width: parent ? parent.width : 0
    spacing: Theme.spaceS * u
    visible: hasText

    Text {
        width: about.width
        textFormat: Text.PlainText
        text: about.heading
        color: Theme.text
        font.pixelSize: Theme.typeHeadline * about.u
        font.weight: Theme.weightDemiBold
        elide: Text.ElideRight
    }

    SettingControl {
        id: block
        objectName: "detailAbout"
        width: parent.width
        height: content.height + 2 * Theme.spaceM * about.u
        u: about.u
        label: about.heading
        labelVisible: false
        flat: true
        cornerRadius: Theme.radiusL * about.u
        hintKind: "info"
        accessibleValue: about.description

        Keys.onPressed: event => {
            if (about.cut && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                Sfx.select()
                about.readRequested()
                event.accepted = true
            }
        }

        Column {
            id: content
            x: Theme.spaceL * about.u
            y: Theme.spaceM * about.u
            width: Math.min(1200 * about.u, block.width - 2 * Theme.spaceL * about.u)

            Text {
                id: descriptionText
                objectName: "aboutDescription"
                width: parent.width
                wrapMode: Text.Wrap
                maximumLineCount: 6
                elide: Text.ElideRight
                textFormat: Text.PlainText
                lineHeight: 40 * about.u
                lineHeightMode: Text.FixedHeight
                text: about.description
                color: Theme.text
                font.pixelSize: Theme.typeBody * about.u
            }

            Item {
                width: 1
                height: Theme.spaceM * about.u
                visible: about.notesShown
            }
            Text {
                objectName: "aboutNotesTitle"
                width: parent.width
                visible: about.notesShown
                textFormat: Text.PlainText
                elide: Text.ElideRight
                lineHeight: 40 * about.u
                lineHeightMode: Text.FixedHeight
                text: about.notesHeading
                color: Theme.text
                font.pixelSize: Theme.typeBody * about.u
                font.weight: Theme.weightDemiBold
            }
            Text {
                id: notesText
                objectName: "aboutNotes"
                width: parent.width
                visible: about.notesShown
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
                textFormat: Text.PlainText
                lineHeight: 40 * about.u
                lineHeightMode: Text.FixedHeight
                text: about.notes
                color: Theme.text
                font.pixelSize: Theme.typeBody * about.u
            }

            Item {
                width: 1
                height: Theme.spaceS * about.u
                visible: about.cut
            }
            Row {
                objectName: "aboutMore"
                visible: about.cut
                height: visible ? 40 * about.u : 0
                spacing: Theme.spaceXs * about.u

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: qsTr("More")
                    color: Theme.text
                    font.pixelSize: Theme.typeBody * about.u
                    font.weight: Theme.weightDemiBold
                }
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    u: about.u
                    name: "chevron_right"
                }
            }
        }
    }
}
