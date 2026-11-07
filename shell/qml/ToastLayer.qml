pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Toast stack at the top right, below the header. Never takes focus and never accepts
// input, so it can sit above pages without touching the focus chain.
Item {
    id: layer

    property real u: 1
    property real marginX: 0
    property real marginY: 0

    readonly property int visibleCount: list.count

    // A game controller was plugged in, paired or lost (T-260). The Shell tells it about every key
    // so that "disconnected" is shown only for a pad that was in use.
    readonly property ControllerToasts controllerToasts: ControllerToasts {
        objectName: "controllerToasts"
    }
    function noteInput() { controllerToasts.noteInput() }

    // A connected Bluetooth device's battery is low (once per crossing, Bluetooth.batteryLow).
    Connections {
        target: Bluetooth
        function onBatteryLow(id, name, percent, kind, family) {
            Notifications.show(qsTr("%1: battery low (%2%)").arg(name).arg(percent), "warning", "",
                               DeviceIcons.iconFor(kind, family))
        }
    }

    // A controller (UPower) is discharging at 15 % or less (once per crossing, Batteries.batteryLow).
    // This is the only low-battery toast for controllers: Bluetooth.batteryLow skips them.
    Connections {
        target: Batteries
        function onBatteryLow(id, name, percent) {
            Notifications.show(qsTr("Controller battery low (%1%)").arg(percent), "warning", "",
                               DeviceIcons.iconFor("controller", ""))
        }
    }

    // A drive was plugged in (once per drive and insert, when its volumes are in the list; a stick
    // with several partitions names the first and counts the rest), and an eject finished.
    // No actions yet; nothing on the drive is opened or run.
    Connections {
        target: Storage
        function onDriveAdded(drive, label, volumeCount) {
            Notifications.show(volumeCount > 1
                               ? qsTr("Drive inserted: %1 (and %n more)", "", volumeCount - 1).arg(label)
                               : qsTr("Drive inserted: %1").arg(label), "info")
        }
        function onFinished(op, id, status) {
            if (op === "eject" && status === "ok")
                Notifications.show(qsTr("Safe to remove"), "success")
        }
    }

    ListView {
        id: list
        objectName: "toastList"
        anchors {
            right: parent.right; rightMargin: layer.marginX
            top: parent.top; topMargin: layer.marginY + Theme.spaceXxxl * layer.u
        }
        width: 560 * layer.u
        height: Notifications.maxVisible * (92 + 14) * layer.u
        spacing: Theme.spaceS * layer.u
        interactive: false
        keyNavigationEnabled: false
        activeFocusOnTab: false
        model: Notifications.model

        add: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.pageMs; easing.type: Easing.OutCubic }
                NumberAnimation { property: "x"; from: Theme.pageSlide * layer.u; to: 0; duration: Theme.pageMs; easing.type: Easing.OutCubic }
            }
        }
        remove: Transition {
            NumberAnimation { property: "opacity"; to: 0; duration: Theme.pageMs; easing.type: Easing.OutCubic }
        }
        displaced: Transition {
            NumberAnimation { property: "y"; duration: Theme.focusMs; easing.type: Easing.OutCubic }
        }

        delegate: Rectangle {
            id: toast
            required property int toastId
            required property string text
            required property string kind
            required property string iconText
            required property string iconName
            required property bool sticky

            readonly property color accent: kind === "success" ? Theme.toastSuccess
                                          : kind === "warning" ? Theme.toastWarning
                                          : kind === "error" ? Theme.toastError : Theme.toastInfo

            width: list.width
            height: 92 * layer.u
            radius: Theme.radiusM * layer.u
            color: Theme.toastBackground

            GlassShadow {
                objectName: "toastShadow"
                z: -1                   // behind the toast's own fill
                anchors.fill: parent
                u: layer.u
                radius: toast.radius
                kind: "panel"
            }
            GlassLayers {
                objectName: "toastLayers"
                anchors.fill: parent
                u: layer.u
                radius: toast.radius
                grain: false            // a toast is not blurred
            }

            Rectangle {
                id: bar
                x: 0
                width: 8 * layer.u
                height: parent.height - 2 * parent.radius
                anchors.verticalCenter: parent.verticalCenter
                color: toast.accent
            }
            Icon {
                id: glyph
                objectName: "toastIcon"
                anchors { left: bar.right; leftMargin: Theme.spaceM * layer.u; verticalCenter: parent.verticalCenter }
                visible: toast.iconName !== ""
                u: layer.u
                name: toast.iconName
                color: toast.accent
            }
            Text {
                id: icon
                anchors { left: bar.right; leftMargin: Theme.spaceM * layer.u; verticalCenter: parent.verticalCenter }
                visible: toast.iconText !== "" && !glyph.visible
                text: toast.iconText
                color: toast.accent
                font.pixelSize: Theme.typeHeadline * layer.u
                font.weight: Theme.weightDemiBold
            }
            Text {
                anchors {
                    left: glyph.visible ? glyph.right : icon.visible ? icon.right : bar.right
                    leftMargin: Theme.spaceM * layer.u
                    right: parent.right; rightMargin: Theme.spaceM * layer.u
                    verticalCenter: parent.verticalCenter
                }
                objectName: "toastText"
                text: toast.text
                // A toast may carry a name a device gave itself: never markup (T-260).
                textFormat: Text.PlainText
                color: Theme.text
                font.pixelSize: Theme.typeBody * layer.u
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.Wrap
            }

            Timer {
                interval: Notifications.durationMs
                running: !toast.sticky
                onTriggered: Notifications.dismiss(toast.toastId)
            }
        }
    }
}
