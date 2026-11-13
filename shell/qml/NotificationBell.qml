import QtQuick
import RuyaShell

// The bell at the left end of the status cluster (RUY-413, 04 §5 "Bell"): a round button of
// `buttonHeight` on the Hub pill's surface (`glass` with a hairline `glassBorder`; focused,
// `focusFill` under the `focusRingWidth` ring), the `notifications` glyph (`notifications_paused`,
// filled, while quiet mode is on) and the unread count in a 32 u badge (`typeMicro` DemiBold,
// `onPrimary` on `primaryFill`; "9+" above nine; none at 0). Right from the Settings gear reaches it;
// Accept opens the notification centre. Left goes back to the gear, Right to the "N more" chip when
// there is one, Down into the page, Back closes the page, LB/RB step the section; Guide and Menu
// bubble up like they do from the nav.
FocusScope {
    id: bell

    property real u: 1
    property int count: 0
    property bool quiet: false

    signal activated()
    signal leftRequested()
    signal rightRequested()
    signal downRequested()
    signal backRequested()
    signal stepRequested(int direction)

    readonly property string badgeText: count > 9 ? "9+" : String(count)

    implicitWidth: Theme.buttonHeight * u
    implicitHeight: Theme.buttonHeight * u
    activeFocusOnTab: false

    Accessible.role: Accessible.Button
    Accessible.name: (quiet ? qsTr("Notifications, %n unread, quiet mode on", "", count)
                            : qsTr("Notifications, %n unread", "", count))
    Accessible.focusable: true

    Rectangle {
        objectName: "bellSurface"
        anchors.fill: parent
        radius: height / 2
        color: bell.activeFocus ? Theme.focusFill : Theme.glass
        border.width: bell.activeFocus ? Theme.focusRingWidth * bell.u : Theme.hairlineAt(bell.u)
        border.color: bell.activeFocus ? Theme.focusRing : Theme.glassBorder
    }

    Icon {
        objectName: "bellIcon"
        anchors.centerIn: parent
        u: bell.u
        name: bell.quiet ? "notifications_paused" : "notifications"
        filled: bell.quiet
        color: Theme.text
    }

    Rectangle {
        id: badge
        objectName: "bellBadge"
        visible: bell.count > 0
        height: 32 * bell.u
        width: Math.max(height, badgeLabel.implicitWidth + 2 * Theme.spaceXs * bell.u)
        radius: height / 2
        x: bell.width - width * 0.75
        y: -height * 0.25
        color: Theme.primaryFill
        Text {
            id: badgeLabel
            objectName: "bellBadgeText"
            anchors.centerIn: parent
            text: bell.badgeText
            color: Theme.onPrimary
            font.pixelSize: Theme.typeMicro * bell.u
            font.weight: Theme.weightDemiBold
        }
    }

    // Only the keys the bell handles are accepted; the rest (Guide, Menu, volume) bubble up to the Shell.
    // Up is the top edge of the screen: nothing moves, nothing leaks to the page below.
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (!event.isAutoRepeat) {
                Sfx.select()
                bell.activated()
            }
        } else if (event.key === Qt.Key_Left) {
            bell.leftRequested()
        } else if (event.key === Qt.Key_Right) {
            bell.rightRequested()
        } else if (event.key === Qt.Key_Down) {
            bell.downRequested()
        } else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
            bell.stepRequested(event.key === Qt.Key_PageDown ? 1 : -1)
        } else if (BackKey.isBackOrBackspace(event.key)) {
            bell.backRequested()
        } else if (event.key !== Qt.Key_Up) {
            return
        }
        event.accepted = true
    }
}
