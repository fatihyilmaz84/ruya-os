pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The notification centre as a sheet (RUY-413, RUY-414, 02 §1 System UI, 04 §5 "Centre sheet"): a modal sheet on the
// right edge over a `scrim`, opened from the Hub's Notifications panel (the bell's own centre is its section page,
// NotificationsPage, RUY-1136). 800 u wide, full height, the left corners `radiusL` (the right ones lie past the
// screen edge), padding `spaceXl` on the left and the safe area right and top; `glassOpaque` with `GlassLayers` and
// the panel shadow on every tier (like the Hub, nothing is blurred behind it). It slides in from the right over
// `overlayMs` (`easeSnap`; a cut under reduced motion). The content is NotificationCentreView (one copy with the
// page); B closes. It accepts every key (a modal), so nothing leaks to the page below.
FocusScope {
    id: sheet

    property real u: 1
    property real marginX: 0
    property real marginY: 0
    property bool shown: false
    property Item returnTo: null
    // Opened from a Hub row: its key, not the Item (clearing items may rebuild the row, RUY-638).
    property string returnKey: ""

    signal closed()
    signal returnToKey(string key)
    // A picked action of an item, and A at a row without actions whose item has an app (NotificationCentreView).
    signal actionRequested(var item, string action)
    signal openRequested(var item)

    readonly property real sheetWidth: 800 * u
    // What the hint bar says (Shell.modalHintsOf).
    readonly property var modalHints: centre.hints

    function open(fromKey) {
        if (shown)
            return
        returnKey = fromKey ?? ""
        returnTo = returnKey !== "" ? null : Window.activeFocusItem
        centre.begin()          // first: what is unread now is "New" (the centre turns active with `shown`)
        shown = true
        centre.forceActiveFocus()
        Sfx.open()
    }

    function close() {
        if (!shown)
            return
        shown = false
        const target = returnTo
        const key = returnKey
        returnTo = null
        returnKey = ""
        if (key !== "")
            returnToKey(key)
        else if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        Sfx.close()
        closed()
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.overlayMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    Item {
        id: slide
        objectName: "centreSlide"
        x: sheet.shown ? sheet.width - sheet.sheetWidth : sheet.width
        width: sheet.sheetWidth
        height: sheet.height
        Behavior on x { NumberAnimation { duration: Theme.overlayMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

        GlassShadow {
            objectName: "centreShadow"
            anchors.fill: panel
            u: sheet.u
            radius: panel.radius
            kind: "panel"
        }
        // Wider than the sheet by its radius, so the right corners lie past the screen edge.
        Rectangle {
            id: panel
            objectName: "centrePanel"
            width: sheet.sheetWidth + radius
            height: parent.height
            radius: Theme.radiusL * sheet.u
            color: Theme.glassOpaque
            GlassLayers {
                objectName: "centreLayers"
                anchors.fill: parent
                u: sheet.u
                radius: parent.radius
                grain: false            // nothing is blurred behind it
            }
        }

        NotificationCentreView {
            id: centre
            objectName: "centreView"
            x: Theme.spaceXl * sheet.u
            y: sheet.marginY
            width: sheet.sheetWidth - x - sheet.marginX
            height: sheet.height - 2 * sheet.marginY
            u: sheet.u
            active: sheet.shown
            backText: qsTr("Close")
            onActionRequested: (item, action) => sheet.actionRequested(item, action)
            onOpenRequested: item => sheet.openRequested(item)
            onProfileLeft: sheet.close()
        }
    }

    // A modal: every key is taken. B closes; the rest is the centre's.
    Keys.onPressed: event => {
        if (BackKey.isBackOrBackspace(event.key) && !event.isAutoRepeat) {
            Sfx.back()
            sheet.close()
        }
        event.accepted = true
    }
}
