pragma ComponentBehavior: Bound
import QtQuick

// Stand-in for hero artwork: slow-drifting soft colour fields tinted by the focused tile.
// Cheap to render (a few rectangles), and the frosted shelf blurs it into something cinematic.
Item {
    id: backdrop

    property color tint: "#3a5bd9"
    Behavior on tint { ColorAnimation { duration: Theme.tintMs; easing.type: Easing.InOutQuad } }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.darker(backdrop.tint, 3.2) }
            GradientStop { position: 1.0; color: Theme.background }
        }
    }

    component Blob: Rectangle {
        id: blob
        property real driftX
        property real driftY
        property int period: 18000
        width: backdrop.width * 0.55
        height: width
        radius: width / 2
        opacity: 0.55

        SequentialAnimation on driftX {
            loops: Animation.Infinite
            NumberAnimation { to: 1; duration: blob.period; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0; duration: blob.period; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on driftY {
            loops: Animation.Infinite
            NumberAnimation { to: 1; duration: blob.period * 1.3; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0; duration: blob.period * 1.3; easing.type: Easing.InOutSine }
        }
    }

    Blob {
        color: backdrop.tint
        x: backdrop.width * (-0.1 + 0.25 * driftX)
        y: backdrop.height * (-0.3 + 0.2 * driftY)
    }
    Blob {
        color: Qt.lighter(backdrop.tint, 1.4)
        period: 23000
        opacity: 0.35
        x: backdrop.width * (0.55 - 0.2 * driftX)
        y: backdrop.height * (0.1 + 0.25 * driftY)
    }
    Blob {
        color: Qt.rgba(1, 1, 1, 1)
        period: 29000
        opacity: 0.08
        width: backdrop.width * 0.35
        x: backdrop.width * (0.3 + 0.3 * driftX)
        y: backdrop.height * (0.5 - 0.3 * driftY)
    }
}
