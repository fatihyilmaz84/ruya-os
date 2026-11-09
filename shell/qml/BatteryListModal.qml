pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The devices the status cluster has no chip for (the "N more" chip, BatteryMore), each with its icon,
// battery glyph and percentage (T-301). A small modal like PowerConfirm: Close has the focus when it
// opens, Accept and Back close it and focus returns to the item that had it before open() (checked
// for still being usable). Up/Down scroll a list longer than the panel. It accepts every key.
// `devices` is the cluster's own list of hidden devices ([{ id, name, kind, ... }], from Batteries),
// so the percentages follow the batteries while the list is open; it closes by itself when nothing is
// hidden any more. Names come from outside: drawn as plain text and elided.
FocusScope {
    id: dialog

    property real u: 1
    property var devices: []
    property bool shown: false
    property Item returnTo: null
    // What the hint bar says while this is open (Shell.modalHintsOf).
    readonly property var modalHints: [{ button: "A", text: qsTr("Close") }, { button: "B", text: qsTr("Back") }]

    signal closed()

    readonly property int maxRows: 6
    readonly property real rowWidth: 760 * u

    function open() {
        returnTo = Window.activeFocusItem
        list.currentIndex = 0
        shown = true
        closeButton.forceActiveFocus()
    }

    function close() {
        if (!shown)
            return
        shown = false
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    function scrollBy(step) {
        list.currentIndex = Math.max(0, Math.min(list.count - 1, list.currentIndex + step))
        list.positionViewAtIndex(list.currentIndex, ListView.Contain)
    }

    // Nothing hidden any more (a device left or the screen got room): nothing to list.
    onDevicesChanged: if (shown && devices.length === 0) close()

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    Rectangle {
        objectName: "batteryListPanel"
        anchors.centerIn: parent
        width: dialog.rowWidth + 120 * dialog.u
        height: card.height + 96 * dialog.u
        radius: Theme.radiusL * dialog.u
        color: Theme.panel
        border.color: Theme.glassBorder
    }

    Column {
        id: card
        anchors.centerIn: parent
        spacing: Theme.spaceL * dialog.u

        Text {
            objectName: "batteryListTitle"
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("More devices")
            color: Theme.text
            font.pixelSize: Theme.typeTitle * dialog.u
            font.weight: Theme.weightDemiBold
        }

        ListView {
            id: list
            objectName: "batteryList"
            anchors.horizontalCenter: parent.horizontalCenter
            width: dialog.rowWidth
            height: Math.min(count, dialog.maxRows) * Theme.rowHeight * dialog.u
            model: dialog.devices
            clip: true
            interactive: false
            keyNavigationEnabled: false
            activeFocusOnTab: false
            highlightMoveDuration: 0
            delegate: Item {
                id: row
                required property var modelData
                required property int index
                objectName: "batteryListRow_" + modelData.id
                width: list.width
                height: Theme.rowHeight * dialog.u
                Text {
                    objectName: "batteryListName_" + row.modelData.id
                    anchors { left: parent.left; right: rowChip.left; rightMargin: Theme.spaceM * dialog.u
                              verticalCenter: parent.verticalCenter }
                    textFormat: Text.PlainText
                    text: DeviceIcons.batteryName(row.modelData)
                    elide: Text.ElideRight
                    color: Theme.text
                    font.pixelSize: Theme.typeBody * dialog.u
                }
                BatteryChip {
                    id: rowChip
                    objectName: "batteryListChip_" + row.modelData.id
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    deviceId: row.modelData.id
                    u: dialog.u
                }
            }
        }

        Rectangle {
            id: closeButton
            objectName: "batteryListClose"
            anchors.horizontalCenter: parent.horizontalCenter
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Close")
            Accessible.focusable: true
            width: 300 * dialog.u
            height: Theme.buttonHeight * dialog.u
            radius: height / 2
            color: activeFocus ? Theme.focusFill : Theme.glass
            border.width: activeFocus ? Theme.focusRingWidth * dialog.u : Theme.hairlineAt(dialog.u)
            border.color: activeFocus ? Theme.focusRing : Theme.glassBorder
            Text {
                anchors.centerIn: parent
                text: qsTr("Close")
                color: Theme.text
                font.pixelSize: Theme.typeHeadline * dialog.u
                font.weight: Theme.weightDemiBold
            }
            Keys.onReturnPressed: event => {
                if (!event.isAutoRepeat) {
                    Sfx.select()
                    dialog.close()
                }
            }
            Keys.onEnterPressed: event => {
                if (!event.isAutoRepeat) {
                    Sfx.select()
                    dialog.close()
                }
            }
        }
    }

    Keys.onPressed: event => {
        if (BackKey.isBackOrBackspace(event.key)) {
            if (!event.isAutoRepeat) {
                Sfx.back()
                dialog.close()
            }
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
            dialog.scrollBy(event.key === Qt.Key_Down ? 1 : -1)      // a list longer than the panel scrolls
        }
        event.accepted = true      // modal: nothing leaks to the page or the cluster underneath
    }
}
