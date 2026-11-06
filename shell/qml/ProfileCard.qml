import QtQuick

Item {
    id: card

    required property int index
    required property var modelData
    property real u: 1

    readonly property bool focused: ListView.isCurrentItem && ListView.view.activeFocus

    Accessible.role: Accessible.ListItem
    Accessible.name: modelData.hasPin ? qsTr("%1, PIN protected").arg(modelData.name) : modelData.name
    Accessible.selected: focused

    width: 260 * u
    height: 320 * u
    scale: focused ? Theme.focusScale : 1.0
    Behavior on scale { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide } }

    Rectangle {
        id: avatar
        anchors.horizontalCenter: parent.horizontalCenter
        width: Theme.avatarSize * card.u
        height: width
        radius: width / 2
        color: card.modelData.avatar
        border.width: card.focused ? 6 * card.u : 0
        border.color: Theme.focusRing

        Text {
            anchors.centerIn: parent
            text: card.modelData.name.charAt(0).toUpperCase()
            color: Theme.text
            font.pixelSize: Theme.typeHero * card.u
            font.weight: Theme.weightLight
        }
    }

    Text {
        anchors { horizontalCenter: parent.horizontalCenter; top: avatar.bottom; topMargin: Theme.spaceM * card.u }
        text: card.modelData.name
        color: Theme.text
        font.pixelSize: Theme.typeHeadline * card.u
        font.weight: card.focused ? Theme.weightDemiBold : Theme.weightRegular   // de-emphasis by weight, not by a dimmer colour
    }

    Badge {
        visible: card.modelData.hasPin
        anchors { right: avatar.right; bottom: avatar.bottom }
        u: card.u
        text: qsTr("PIN")
    }
}
