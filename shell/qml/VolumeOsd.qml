import QtQuick
import RuyaShell

// Volume indicator, bottom centre. Appears on any volume or mute change and hides by itself
// `Theme.osdMs` after the last one. Display only: never focusable, never takes input.
Item {
    id: osd

    property real u: 1
    property real marginY: 0

    property bool shown: false

    width: 520 * u
    height: 96 * u
    anchors.horizontalCenter: parent.horizontalCenter
    y: parent.height - marginY - height - 30 * u
    opacity: shown ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.OutCubic } }

    Connections {
        target: Audio
        function onAdjusted() {
            osd.shown = true
            hideTimer.restart()
        }
    }
    Timer {
        id: hideTimer
        interval: Theme.osdMs
        onTriggered: osd.shown = false
    }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Theme.toastBackground
        border.width: Math.max(1, osd.u)
        border.color: Theme.glassBorder
    }

    Text {
        id: label
        anchors { left: parent.left; leftMargin: Theme.spaceL * osd.u; verticalCenter: parent.verticalCenter }
        text: Audio.muted ? qsTr("Muted") : qsTr("Volume")
        color: Audio.muted ? Theme.toastWarning : Theme.text
        font.pixelSize: Theme.typeBody * osd.u
    }
    Rectangle {
        id: track
        objectName: "volumeTrack"
        anchors { left: label.right; leftMargin: Theme.spaceM * osd.u; right: value.left; rightMargin: Theme.spaceM * osd.u; verticalCenter: parent.verticalCenter }
        height: 12 * osd.u
        radius: height / 2
        color: Theme.glass
        Rectangle {
            width: parent.width * (Audio.muted ? 0 : Audio.volume) / 100
            height: parent.height
            radius: parent.radius
            color: Theme.text
        }
    }
    Text {
        id: value
        objectName: "volumeValue"
        anchors { right: parent.right; rightMargin: Theme.spaceL * osd.u; verticalCenter: parent.verticalCenter }
        width: 70 * osd.u
        horizontalAlignment: Text.AlignRight
        text: Audio.muted ? "–" : Audio.volume
        color: Theme.text
        font.pixelSize: Theme.typeBody * osd.u
    }
}
