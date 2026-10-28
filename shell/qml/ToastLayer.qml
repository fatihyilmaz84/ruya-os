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

            readonly property color accent: kind === "success" ? Theme.toastSuccess
                                          : kind === "warning" ? Theme.toastWarning
                                          : kind === "error" ? Theme.toastError : Theme.toastInfo

            width: list.width
            height: 92 * layer.u
            radius: Theme.radiusM * layer.u
            color: Theme.toastBackground
            border.width: Math.max(1, layer.u)
            border.color: Theme.glassBorder

            Rectangle {
                id: bar
                x: 0
                width: 8 * layer.u
                height: parent.height - 2 * parent.radius
                anchors.verticalCenter: parent.verticalCenter
                color: toast.accent
            }
            Text {
                id: icon
                anchors { left: bar.right; leftMargin: Theme.spaceM * layer.u; verticalCenter: parent.verticalCenter }
                visible: toast.iconText !== ""
                text: toast.iconText
                color: toast.accent
                font.pixelSize: Theme.typeHeadline * layer.u
            }
            Text {
                anchors {
                    left: icon.visible ? icon.right : bar.right
                    leftMargin: Theme.spaceM * layer.u
                    right: parent.right; rightMargin: Theme.spaceM * layer.u
                    verticalCenter: parent.verticalCenter
                }
                text: toast.text
                color: Theme.text
                font.pixelSize: Theme.typeBody * layer.u
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.Wrap
            }

            Timer {
                interval: Notifications.durationMs
                running: true
                onTriggered: Notifications.dismiss(toast.toastId)
            }
        }
    }
}
