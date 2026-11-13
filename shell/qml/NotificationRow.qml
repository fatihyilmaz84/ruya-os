pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// One item of the notification centre (RUY-413, 04 §5 "Notification row"): the toast at rest. A
// 64 u round badge (the kind's fill and glyph, or the item's icon), the title (`typeBody` DemiBold)
// and the detail (`typeCaption`), the time on the right (`typeCaption`) and a 14 u unread dot
// (`text`) for an item that was new when the centre opened. A pinned item has a warning hairline
// border and the `push_pin` glyph in place of the dot. Unfocused it is the toast's card
// (`toastBackground` with the lit rim), where `textDim` holds 4.5:1; focused, `focusFill` under the
// ring, the detail in `text` (`textDim` is under the floor on `focusFill`, 04 §7), and it grows to
// show at most two action pills (64 u, the first `primaryFill`), the picked one ringed. Display
// only: the sheet owns the keys.
Item {
    id: row

    property real u: 1
    property var item: ({})
    property bool focused: false
    property bool fresh: false
    property int pick: 0
    property string timeText: ""

    readonly property var actions: item.actions ?? []
    readonly property bool pinned: item.pinned === true
    readonly property bool hasBody: (item.body ?? "") !== ""
    readonly property bool expanded: focused && actions.length > 0
    readonly property real pad: Theme.spaceM * u
    // 112 u with a detail, 96 u without; a pinned item's title may take two lines (a safety notice is
    // never cut off, like the compact sticky toast, 04 §5 Toast), and then the row grows to fit.
    readonly property real baseHeight: Math.max((hasBody ? 112 : 96) * u, texts.height + 2 * Theme.spaceS * u)
    readonly property real pillHeight: 64 * u

    implicitHeight: expanded ? baseHeight + pillHeight + pad : baseHeight

    Accessible.role: Accessible.ListItem
    Accessible.name: [item.title ?? "", item.body ?? "", timeText,
                      pinned ? qsTr("Pinned") : (fresh ? qsTr("New") : "")].filter(t => t !== "").join(", ")

    Rectangle {
        id: card
        objectName: "notificationCard"
        anchors.fill: parent
        radius: Theme.radiusL * row.u
        color: row.focused ? Theme.focusFill : Theme.toastBackground
        border.width: row.focused ? Theme.focusRingWidth * row.u : (row.pinned ? Theme.hairlineAt(row.u) : 0)
        border.color: row.focused ? Theme.focusRing : Theme.toastWarning
    }
    GlassLayers {
        anchors.fill: parent
        u: row.u
        radius: card.radius
        grain: false
        rim: !row.focused && !row.pinned      // the ring or the warning border stands in for the rim
    }

    Rectangle {
        id: badge
        objectName: "notificationBadge"
        x: row.pad
        y: (row.baseHeight - height) / 2
        width: 64 * row.u
        height: width
        radius: width / 2
        color: Theme.toastBadgeFill(row.item.kind ?? "info")
        Icon {
            anchors.centerIn: parent
            u: row.u
            name: (row.item.icon ?? "") !== "" ? row.item.icon
                : row.item.kind === "success" ? "check_circle"
                : row.item.kind === "warning" ? "warning"
                : row.item.kind === "error" ? "error" : "info"
            color: Theme.toastColor(row.item.kind ?? "info")
        }
    }

    // The time and the dot (or the pin) on the right.
    Row {
        id: side
        anchors { right: parent.right; rightMargin: row.pad }
        y: (row.baseHeight - height) / 2
        spacing: Theme.spaceS * row.u
        Text {
            objectName: "notificationTime"
            anchors.verticalCenter: parent.verticalCenter
            text: row.timeText
            color: Theme.text
            font.pixelSize: Theme.typeCaption * row.u
        }
        Icon {
            objectName: "notificationPin"
            visible: row.pinned
            anchors.verticalCenter: parent.verticalCenter
            u: row.u
            size: 32
            name: "push_pin"
            filled: true
            color: Theme.toastWarning
        }
        Rectangle {
            objectName: "notificationDot"
            visible: !row.pinned && row.fresh
            anchors.verticalCenter: parent.verticalCenter
            width: 14 * row.u
            height: width
            radius: width / 2
            color: Theme.text
        }
    }

    Column {
        id: texts
        x: badge.x + badge.width + row.pad
        width: side.x - Theme.spaceM * row.u - x
        y: (row.baseHeight - height) / 2
        Text {
            objectName: "notificationTitle"
            width: parent.width
            text: row.item.title ?? ""
            textFormat: Text.PlainText          // an app's words: never markup (T-286)
            color: Theme.text
            font.pixelSize: Theme.typeBody * row.u
            font.weight: Theme.weightDemiBold
            elide: Text.ElideRight
            wrapMode: row.pinned ? Text.Wrap : Text.NoWrap
            maximumLineCount: row.pinned ? 2 : 1
        }
        Text {
            objectName: "notificationBody"
            visible: row.hasBody
            width: parent.width
            text: row.item.body ?? ""
            textFormat: Text.PlainText
            color: row.focused ? Theme.text : Theme.textDim
            font.pixelSize: Theme.typeCaption * row.u
            elide: Text.ElideRight
            maximumLineCount: 1
        }
    }

    // The actions of the focused row: Left/Right pick, A runs the picked one.
    Row {
        objectName: "notificationActions"
        visible: row.expanded
        x: texts.x
        y: row.baseHeight - Theme.spaceXs * row.u
        spacing: Theme.spaceS * row.u
        Repeater {
            model: row.expanded ? row.actions : []
            Rectangle {
                id: pill
                required property var modelData
                required property int index
                objectName: "notificationAction_" + index
                readonly property bool picked: index === row.pick
                height: row.pillHeight
                width: pillLabel.implicitWidth + 2 * Theme.spaceL * row.u
                radius: height / 2
                color: index === 0 ? Theme.primaryFill : Theme.glass
                border.width: picked ? Theme.focusRingWidth * row.u : (index === 0 ? 0 : Theme.hairlineAt(row.u))
                border.color: picked ? Theme.focusRing : Theme.glassBorder
                Accessible.role: Accessible.Button
                Accessible.name: modelData.label ?? ""
                Text {
                    id: pillLabel
                    objectName: "notificationActionLabel_" + pill.index
                    anchors.centerIn: parent
                    text: pill.modelData.label ?? ""
                    textFormat: Text.PlainText
                    color: pill.index === 0 ? Theme.onPrimary : Theme.text
                    font.pixelSize: Theme.typeBody * row.u
                    font.weight: Theme.weightDemiBold
                }
            }
        }
    }
}
