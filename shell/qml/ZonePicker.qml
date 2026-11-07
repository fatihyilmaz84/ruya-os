pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> System -> Time zone (T-213): a modal with the region and city lists (ZoneChooser).
// Accept on a city asks the service to set it (TimeZone.setTimezone) and closes; the pane tells the
// owner how it went. Back on a region closes without choosing. Modal: it accepts every key. Focus
// returns to the item that had it before open().
FocusScope {
    id: picker

    property real u: 1
    property bool shown: false
    property Item returnTo: null

    signal closed()
    // The owner chose a zone; the request is on its way.
    signal requested(string zone)

    function open() {
        returnTo = Window.activeFocusItem
        shown = true
        chooser.current = TimeZone.timezone
        chooser.start(TimeZone.timezone)
    }

    function close() {
        shown = false
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    // Modal: every key stops here (the chooser takes its own first).
    Keys.onPressed: event => event.accepted = true

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    Rectangle {
        id: panel
        objectName: "zonePanel"
        anchors.centerIn: parent
        width: chooser.width + 2 * Theme.spaceXl * picker.u
        height: content.height + 2 * Theme.spaceXl * picker.u
        radius: Theme.radiusL * picker.u
        color: Theme.panel
        border.width: Theme.hairlineAt(picker.u)
        border.color: Theme.glassBorder
    }

    Column {
        id: content
        anchors.centerIn: panel
        spacing: Theme.spaceM * picker.u

        Text {
            objectName: "zoneTitle"
            text: qsTr("Time zone")
            color: Theme.text
            font.pixelSize: Theme.typeTitle * picker.u
            font.weight: Theme.weightDemiBold
        }

        ZoneChooser {
            id: chooser
            objectName: "zoneChooser"
            u: picker.u
            focus: true
            onChosen: zone => {
                picker.requested(zone)
                picker.close()
            }
            onCancelled: picker.close()
        }
    }
}
