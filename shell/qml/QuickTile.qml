import QtQuick
import RuyaShell

// A quick tile of the Ruya Hub (04 §5, 02-shell §1.6, T-448): a toggle in the Quick Hub's tiles row.
// An icon over a one-line label, and under it one small line of state (the Wi-Fi network's name,
// "On", "Off"). Off: `selectedFill`; on: `primaryFill` with the filled icon; focused: `focusFill`
// under the ring, like a row. It is a picture: the Hub's list holds the focus and sets `focused`;
// `on` is always the backend's answer, never an optimistic guess. A tile whose backend is missing
// is not created at all (07 §5.2: no fake controls), so there is no disabled look.
Rectangle {
    id: tile

    property real u: 1
    property string iconOn                // icon name while on
    property string iconOff               // icon name while off (default: the same)
    property string label
    property string detail                // the small second line, "" for none
    property bool on: false
    property bool focused: false

    readonly property color ink: on && !focused ? Theme.onPrimary : Theme.text

    Accessible.role: Accessible.CheckBox
    Accessible.name: on ? qsTr("%1, on").arg(label) : qsTr("%1, off").arg(label)
    Accessible.checked: on

    // The tile grows with its text; the row of tiles takes the tallest.
    implicitHeight: Math.max(Theme.rowHeight * u, column.implicitHeight + 2 * Theme.spaceXs * u)
    radius: Theme.radiusM * u
    color: focused ? Theme.focusFill : (on ? Theme.primaryFill : Theme.selectedFill)
    border.width: focused ? Theme.focusRingWidth * u : 0
    border.color: Theme.focusRing

    Column {
        id: column
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                  leftMargin: Theme.spaceXs * tile.u; rightMargin: Theme.spaceXs * tile.u }
        spacing: 0
        Icon {
            objectName: "tileIcon"
            anchors.horizontalCenter: parent.horizontalCenter
            u: tile.u
            name: tile.on || tile.iconOff === "" ? tile.iconOn : tile.iconOff
            filled: tile.on
            color: tile.ink
        }
        Text {
            objectName: "tileLabel"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: tile.label
            color: tile.ink
            font.pixelSize: Theme.typeCaption * tile.u
            font.weight: Theme.weightDemiBold
            elide: Text.ElideRight
        }
        Text {
            objectName: "tileDetail"
            visible: tile.detail !== ""
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText      // a network's name comes from outside
            text: tile.detail
            color: tile.on && !tile.focused ? Theme.onPrimary : Theme.textDim
            font.pixelSize: Theme.typeMicro * tile.u
            font.weight: Theme.weightDemiBold
            elide: Text.ElideRight
        }
    }
}
