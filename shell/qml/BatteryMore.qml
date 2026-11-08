import QtQuick
import RuyaShell

// The "N more" chip of the status cluster (T-301, 04 §5): a stack of two battery glyphs and the label
// "N more" for the devices that did not get a chip of their own. It is the one focusable part of
// the cluster: the pad reaches it from the section nav (Right at the last pill) and Accept opens the
// list of the hidden devices (BatteryListModal). Left goes back to the nav, Down into the page,
// Back as in the nav (closes the page), LB/RB step the section; it never keeps a key.
// Its accessible name lists the devices, so a screen reader needs no focus on the others.
// `compact` is the old "+N": no glyph and no words, for a cluster that has no room for them (a large
// UI size); the accessible name does not change.
FocusScope {
    id: more

    property real u: 1
    property int count: 0
    property bool compact: false
    // The hidden devices, [{ name, percent }], for the accessible name.
    property var devices: []

    signal activated()
    signal leftRequested()
    signal downRequested()
    signal backRequested()
    signal stepRequested(int direction)

    readonly property real pad: Theme.spaceXs * more.u
    implicitWidth: content.width + 2 * pad + (Theme.focusRingWidth * more.u)
    implicitHeight: content.height + 2 * pad

    activeFocusOnTab: false

    Accessible.role: Accessible.Button
    Accessible.name: qsTr("%n more device(s) with a battery: %1", "", more.count)
                     .arg(more.devices.map(d => qsTr("%1 %2 percent").arg(d.name).arg(d.percent)).join(", "))
    Accessible.focusable: true

    Rectangle {
        objectName: "batteryMoreFocus"
        anchors.fill: parent
        radius: height / 2
        color: more.activeFocus ? Theme.focusFill : "transparent"
        border.width: more.activeFocus ? Theme.focusRingWidth * more.u : 0
        border.color: Theme.focusRing
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: Theme.spaceXs * more.u

        // A stack of two batteries: the front one in the text colour, the one behind it dimmer
        // and shifted, so the glyph reads as "several".
        Item {
            id: stack
            visible: !more.compact
            anchors.verticalCenter: parent.verticalCenter
            width: front.width + shift
            height: front.height
            readonly property real shift: Theme.spaceXs * more.u * 1.5
            Icon {
                objectName: "batteryMoreBack"
                x: stack.shift
                u: more.u
                name: "battery_full"
                color: Theme.textDim
            }
            Icon {
                id: front
                objectName: "batteryMoreFront"
                u: more.u
                name: "battery_full"
                color: Theme.text
            }
        }
        Text {
            id: label
            objectName: "batteryMoreLabel"
            anchors.verticalCenter: parent.verticalCenter
            text: more.compact ? "+" + more.count : qsTr("%n more", "", more.count)
            color: Theme.text
            font.pixelSize: Theme.typeBody * more.u
        }
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (!event.isAutoRepeat) {
                Sfx.select()
                more.activated()
            }
        } else if (event.key === Qt.Key_Left) {
            more.leftRequested()
        } else if (event.key === Qt.Key_Down) {
            more.downRequested()
        } else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
            more.stepRequested(event.key === Qt.Key_PageDown ? 1 : -1)
        } else if (BackKey.isBackOrBackspace(event.key)) {
            more.backRequested()
        }
        // Right and Up are the edge of the screen: nothing moves, nothing leaks to the page below.
        event.accepted = true
    }
}
