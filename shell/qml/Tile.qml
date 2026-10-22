import QtQuick

Item {
    id: tile

    required property int index
    required property string key      // stable id of the page this tile opens
    required property string title
    required property color accent
    property real u: 1

    readonly property bool focused: ListView.isCurrentItem && ListView.view.activeFocus

    function pulse() { pulseAnimation.restart() }

    scale: focused ? Theme.focusScale : 1.0
    z: focused ? 1 : 0
    Behavior on scale { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.OutCubic } }

    Rectangle {
        id: card
        anchors.fill: parent
        radius: 18 * tile.u
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.lighter(tile.accent, 1.25) }
            GradientStop { position: 1.0; color: Qt.darker(tile.accent, 1.8) }
        }

        Text {
            anchors { left: parent.left; bottom: parent.bottom; margins: 22 * tile.u }
            text: tile.title
            color: Theme.text
            font.pixelSize: 34 * tile.u
            font.weight: Font.DemiBold
        }
    }

    // Focus ring: always visible on the focused tile, never animated away mid-navigation.
    Rectangle {
        anchors.fill: card
        anchors.margins: -7 * tile.u
        radius: card.radius + 7 * tile.u
        color: "transparent"
        border.width: 4 * tile.u
        border.color: Theme.focusRing
        opacity: tile.focused ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.focusMs } }
    }

    SequentialAnimation {
        id: pulseAnimation
        NumberAnimation { target: card; property: "scale"; to: 0.94; duration: 70; easing.type: Easing.OutQuad }
        NumberAnimation { target: card; property: "scale"; to: 1.0; duration: 180; easing.type: Easing.OutBack }
    }
}
