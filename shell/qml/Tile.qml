import QtQuick

Item {
    id: tile

    required property int index
    required property string key      // stable id of the page this tile opens
    required property string title
    property real u: 1

    readonly property color accent: Theme.tileAccent(key)
    readonly property bool focused: ListView.isCurrentItem && ListView.view.activeFocus

    // Accept feedback; skipped under reduced motion (the page change that follows is the feedback).
    function pulse() {
        if (!Theme.reducedMotion)
            pulseAnimation.restart()
    }

    scale: focused ? Theme.focusScale : 1.0
    z: focused ? 1 : 0
    Behavior on scale { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.OutCubic } }

    Rectangle {
        id: card
        anchors.fill: parent
        radius: Theme.radiusM * tile.u
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.lighter(tile.accent, 1.25) }
            GradientStop { position: 1.0; color: Qt.darker(tile.accent, 1.8) }
        }

        Text {
            anchors { left: parent.left; bottom: parent.bottom; margins: Theme.spaceM * tile.u }
            text: tile.title
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * tile.u
            font.weight: Font.DemiBold
        }
    }

    // Focus ring: always visible on the focused tile, never animated away mid-navigation.
    Rectangle {
        anchors.fill: card
        anchors.margins: -Theme.focusRingOffset * tile.u
        radius: card.radius + Theme.focusRingOffset * tile.u
        color: "transparent"
        border.width: Theme.focusRingWidth * tile.u
        border.color: Theme.focusRing
        opacity: tile.focused ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.focusMs } }
    }

    SequentialAnimation {
        id: pulseAnimation
        objectName: "pulseAnimation"
        NumberAnimation { target: card; property: "scale"; to: Theme.pulseScale; duration: Theme.pulseDownMs; easing.type: Easing.OutQuad }
        NumberAnimation { target: card; property: "scale"; to: 1.0; duration: Theme.pulseUpMs; easing.type: Easing.OutBack }
    }
}
