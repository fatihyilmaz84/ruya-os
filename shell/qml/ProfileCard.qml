import QtQuick

Item {
    id: card

    required property int index
    required property var modelData
    property real u: 1

    readonly property bool focused: ListView.isCurrentItem && ListView.view.activeFocus

    width: 260 * u
    height: 320 * u
    scale: focused ? Theme.focusScale : 1.0
    Behavior on scale { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.OutCubic } }

    Rectangle {
        id: avatar
        anchors.horizontalCenter: parent.horizontalCenter
        width: 200 * card.u
        height: width
        radius: width / 2
        color: card.modelData.avatar
        border.width: card.focused ? 6 * card.u : 0
        border.color: Theme.focusRing

        Text {
            anchors.centerIn: parent
            text: card.modelData.name.charAt(0).toUpperCase()
            color: Theme.text
            font.pixelSize: 96 * card.u
            font.weight: Font.Light
        }
    }

    Text {
        anchors { horizontalCenter: parent.horizontalCenter; top: avatar.bottom; topMargin: 24 * card.u }
        text: card.modelData.name
        color: card.focused ? Theme.text : Theme.textDim
        font.pixelSize: 34 * card.u
    }

    Rectangle {
        visible: card.modelData.hasPin
        anchors { right: avatar.right; bottom: avatar.bottom }
        width: 64 * card.u
        height: 36 * card.u
        radius: height / 2
        color: Theme.background
        border.color: Theme.glassBorder
        Text {
            anchors.centerIn: parent
            text: qsTr("PIN")
            color: Theme.textDim
            font.pixelSize: 18 * card.u
            font.weight: Font.DemiBold
        }
    }
}
