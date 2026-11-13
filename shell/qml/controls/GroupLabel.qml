import QtQuick
import RuyaShell

// A heading that names the rows below it in a pane (RUY-512, 04 §5 "Setting row kinds"): `typeHeadline`
// DemiBold in `text`, flush with the pills' left edge, one line elided. Never focusable, so Up/Down skip
// it. In a pane column (spacing `spaceS`) it leaves `spaceXl` above its text and `spaceXs` between its text
// and the next row: the item is `spaceXl` of top padding, the text, and `spaceXs - spaceS` (a negative
// bottom padding, the column gap overlapping by 8) below.
Item {
    id: heading

    property real u: 1
    property string text

    width: parent ? parent.width : 900 * u
    height: Theme.spaceXl * u + label.implicitHeight + (Theme.spaceXs - Theme.spaceS) * u

    Accessible.role: Accessible.Heading
    Accessible.name: text

    Text {
        id: label
        objectName: "groupLabelText"
        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: Theme.spaceXl * heading.u }
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: heading.text
        color: Theme.text
        font.pixelSize: Theme.typeHeadline * heading.u
        font.weight: Theme.weightDemiBold
    }
}
