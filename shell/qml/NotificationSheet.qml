pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The notification centre (RUY-413, 02 §1 System UI, 04 §5 "Centre sheet"): a modal sheet on the
// right edge over a `scrim`, opened from the bell. 800 u wide, full height, the left corners
// `radiusL` (the right ones lie past the screen edge), padding `spaceXl` on the left and the safe
// area right and top; `glassOpaque` with `GlassLayers` and the panel shadow on every tier (like the
// Hub, nothing is blurred behind it). It slides in from the right over `overlayMs` (`easeSnap`; a
// cut under reduced motion).
//
// Top to bottom: the title with "N new" and Clear all (hidden when only pinned items are left), the
// Quiet mode row, then the groups "Pinned until resolved", "New" (the items that were unread when it
// opened, and those that arrive while it is open) and "Earlier", each under a caption. A row is a
// NotificationRow. Opening marks everything read (the badge empties) and puts the focus on the first
// row (a pinned one, if any), else on Quiet mode. Up from the first row reaches Quiet mode, then
// Clear all. On a row: Left/Right pick an action, A runs it (and the item goes, unless pinned), Start
// (the options button) clears the item (not a pinned one), B closes. A row without actions opens
// its app on A when it has one; otherwise A does nothing and has no hint. When the focused row goes
// (cleared here or by its source) the focus moves to the next row, else the previous one, else
// Quiet mode. A long list scrolls with the focus in rows, with the Hub's fades at an edge that hides
// rows. It accepts every key (a modal), so nothing leaks to the page below.
FocusScope {
    id: sheet

    property real u: 1
    property real marginX: 0
    property real marginY: 0
    property bool shown: false
    property Item returnTo: null

    // The ids that were unread when the centre opened, and those that arrived while it was open.
    property var freshIds: []
    // "N new" in the title: the unread count at the opening.
    property int newCount: 0
    // The clock the times are read against: set at the opening and each minute while open.
    property double nowMs: 0
    // The list's model: keys only ("cap:pinned" | "cap:new" | "cap:earlier" | "n:<id>").
    property var keys: []
    // Where the focus is: "clear" | "quiet" | "row" (then `focusKey` is the row).
    property string stop: "quiet"
    property string focusKey: ""
    // The picked action of the focused row.
    property int pick: 0

    signal closed()
    // The Shell runs it: "restart", "settings:<category>", or "open" (the item's app).
    signal actionRequested(var item, string action)

    readonly property real sheetWidth: 800 * u
    readonly property var items: NotificationCentre.items
    readonly property var byId: {
        const m = {}
        for (let i = 0; i < items.length; ++i)
            m["n:" + items[i].id] = items[i]
        return m
    }
    readonly property bool hasClearable: items.some(i => !i.pinned)
    readonly property var currentItem: stop === "row" && focusKey !== "" ? (byId[focusKey] ?? null) : null
    readonly property var currentActions: currentItem ? (currentItem.actions ?? []) : []

    // What the hint bar says (Shell.modalHintsOf).
    readonly property var modalHints: {
        const close = { button: "B", text: qsTr("Close") }
        if (stop === "clear")
            return [{ button: "A", text: qsTr("Clear all") }, close]
        if (stop === "quiet")
            return [{ button: "A", text: qsTr("Toggle") }, close]
        const it = currentItem
        if (!it)
            return [close]
        const out = []
        if (currentActions.length > 0)
            out.push({ button: "A", text: qsTr("Select") })
        else if ((it.appId ?? "") !== "")
            out.push({ button: "A", text: qsTr("Open") })
        if (currentActions.length > 1)
            out.push({ button: "Left/Right", text: qsTr("Choose") })
        if (!it.pinned)
            out.push({ button: "Start", text: qsTr("Clear") })
        out.push(close)
        return out
    }

    // "Just now", "2 min ago", the local time today (T-213), "Yesterday", "3 days ago".
    function timeText(ms) {
        const diff = Math.max(0, nowMs - ms)
        if (diff < 60000)
            return qsTr("Just now")
        if (diff < 3600000)
            return qsTr("%n min ago", "", Math.floor(diff / 60000))
        const day = TimeZone.formatIsoDate(ms)
        if (day === TimeZone.formatIsoDate(nowMs))
            return TimeZone.formatClock(ms)
        if (day === TimeZone.formatIsoDate(nowMs - 86400000))
            return qsTr("Yesterday")
        return qsTr("%n days ago", "", Math.max(2, Math.round(diff / 86400000)))
    }

    function open() {
        if (shown)
            return
        returnTo = Window.activeFocusItem
        nowMs = NotificationCentre.nowMs()
        freshIds = items.filter(i => i.unread).map(i => i.id)
        newCount = freshIds.length
        NotificationCentre.markRead()
        shown = true
        keys = buildKeys()
        focusFirst()
        Sfx.open()
    }

    function close() {
        if (!shown)
            return
        shown = false
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        Sfx.close()
        closed()
    }

    function buildKeys() {
        const out = []
        const pinned = items.filter(i => i.pinned)
        const fresh = items.filter(i => !i.pinned && freshIds.indexOf(i.id) >= 0)
        const earlier = items.filter(i => !i.pinned && freshIds.indexOf(i.id) < 0)
        if (pinned.length > 0)
            out.push("cap:pinned")
        pinned.forEach(i => out.push("n:" + i.id))
        if (fresh.length > 0)
            out.push("cap:new")
        fresh.forEach(i => out.push("n:" + i.id))
        if (earlier.length > 0)
            out.push("cap:earlier")
        earlier.forEach(i => out.push("n:" + i.id))
        return out
    }

    function firstRow() {
        return keys.findIndex(k => k.startsWith("n:"))
    }

    function focusRow(at) {
        stop = "row"
        focusKey = keys[at]
        pick = 0
        list.currentIndex = at
        list.forceActiveFocus()
        list.reveal()
    }

    function focusQuiet() {
        stop = "quiet"
        focusKey = ""
        quietRow.forceActiveFocus()
    }

    function focusFirst() {
        const at = firstRow()
        if (at >= 0)
            focusRow(at)
        else
            focusQuiet()
    }

    // The row to take the focus when `gone` left the list: the next row of the old order that is
    // still there, else the previous one; "" when none is.
    function neighbour(old, gone, next) {
        for (let i = gone + 1; i < old.length; ++i) {
            if (old[i].startsWith("n:") && next.indexOf(old[i]) >= 0)
                return old[i]
        }
        for (let i = gone - 1; i >= 0; --i) {
            if (old[i].startsWith("n:") && next.indexOf(old[i]) >= 0)
                return old[i]
        }
        return ""
    }

    // The items changed: the rows follow, and the focus stays on its row, or moves on from a row
    // that went (and from Clear all when nothing is left to clear).
    function rebuild() {
        if (!shown)
            return
        // An item that arrives while the centre is open is new, and seen.
        const arrived = items.filter(i => i.unread && freshIds.indexOf(i.id) < 0).map(i => i.id)
        if (arrived.length > 0) {
            freshIds = freshIds.concat(arrived)
            NotificationCentre.markRead()
        }
        const old = keys
        const next = buildKeys()
        if (old.join("|") === next.join("|"))
            return
        let target = focusKey
        if (stop === "row" && next.indexOf(target) < 0)
            target = neighbour(old, old.indexOf(focusKey), next)
        keys = next
        if (stop === "row") {
            if (target === "")
                focusQuiet()
            else
                focusRow(next.indexOf(target))
        } else if (stop === "clear" && !hasClearable) {
            focusFirst()
        }
    }

    function moveUp() {
        if (stop === "row") {
            for (let i = list.currentIndex - 1; i >= 0; --i) {
                if (keys[i].startsWith("n:")) {
                    Sfx.navigate()
                    focusRow(i)
                    return
                }
            }
            Sfx.navigate()
            focusQuiet()
        } else if (stop === "quiet" && hasClearable) {
            Sfx.navigate()
            stop = "clear"
            focusKey = ""
            clearAll.forceActiveFocus()
        }
    }

    function moveDown() {
        if (stop === "clear") {
            Sfx.navigate()
            focusQuiet()
        } else if (stop === "quiet") {
            const at = firstRow()
            if (at >= 0) {
                Sfx.navigate()
                focusRow(at)
            }
        } else {
            for (let i = list.currentIndex + 1; i < keys.length; ++i) {
                if (keys[i].startsWith("n:")) {
                    Sfx.navigate()
                    focusRow(i)
                    return
                }
            }
        }
    }

    function movePick(step) {
        if (stop !== "row")
            return
        const next = Math.max(0, Math.min(currentActions.length - 1, pick + step))
        if (next !== pick) {
            pick = next
            Sfx.navigate()
        }
    }

    function activate() {
        const it = currentItem
        if (!it)
            return
        if (currentActions.length > 0) {
            const action = currentActions[Math.min(pick, currentActions.length - 1)].id
            Sfx.select()
            sheet.actionRequested(it, action)
            NotificationCentre.invoke(it.id, action)
        } else if ((it.appId ?? "") !== "") {
            Sfx.select()
            sheet.actionRequested(it, "open")
        }
    }

    function clearCurrent() {
        const it = currentItem
        if (!it || it.pinned)
            return
        Sfx.select()
        NotificationCentre.dismiss(it.id)
    }

    function clearEverything() {
        Sfx.select()
        NotificationCentre.dismissAll()
    }

    Connections {
        target: NotificationCentre
        function onItemsChanged() { sheet.rebuild() }
        // Signed out or switched under it (a lock): another profile's list is never shown in it.
        function onProfileChanged() { sheet.close() }
    }
    // The times move on while the centre is open (not a decoration: the words change).
    Timer {
        interval: 60000
        repeat: true
        running: sheet.shown
        onTriggered: sheet.nowMs = NotificationCentre.nowMs()
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

        Item {
            id: content
            x: Theme.spaceXl * sheet.u
            y: sheet.marginY
            width: sheet.sheetWidth - x - sheet.marginX
            height: sheet.height - 2 * sheet.marginY

            // The title, "N new" and Clear all.
            Item {
                id: header
                width: parent.width
                height: Math.max(titleText.implicitHeight, clearAll.height)
                Text {
                    id: titleText
                    objectName: "centreTitle"
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Notifications")
                    color: Theme.text
                    font.pixelSize: Theme.typeTitle * sheet.u
                    font.weight: Theme.weightDemiBold
                    width: Math.min(implicitWidth, header.width - (clearAll.visible ? clearAll.width + Theme.spaceM * sheet.u : 0))
                    elide: Text.ElideRight
                }
                Text {
                    objectName: "centreNewCount"
                    visible: sheet.newCount > 0
                    anchors { left: titleText.right; leftMargin: Theme.spaceS * sheet.u; baseline: titleText.baseline }
                    text: qsTr("%n new", "", sheet.newCount)
                    color: Theme.textDim
                    font.pixelSize: Theme.typeBody * sheet.u
                }
                SecondaryButton {
                    id: clearAll
                    objectName: "centreClearAll"
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    visible: sheet.hasClearable
                    u: sheet.u
                    text: qsTr("Clear all")
                    onAccepted: sheet.clearEverything()
                }
            }

            ToggleRow {
                id: quietRow
                objectName: "centreQuiet"
                anchors.top: header.bottom
                anchors.topMargin: Theme.spaceM * sheet.u
                width: parent.width
                u: sheet.u
                label: qsTr("Quiet mode")
                iconName: "notifications_paused"
                onToggled: on => NotificationCentre.setQuiet(on)
            }
            Binding { target: quietRow; property: "checked"; value: NotificationCentre.quiet }

            // The rows, or the empty state. The list scrolls by rows with the Hub's fades (QuickMenu.qml).
            Item {
                id: listBox
                objectName: "centreListBox"
                anchors { top: quietRow.bottom; topMargin: Theme.spaceM * sheet.u }
                width: parent.width
                height: content.height - y

                ListView {
                    id: list
                    objectName: "centreList"
                    Accessible.role: Accessible.List
                    Accessible.name: qsTr("Notifications")
                    anchors.fill: parent
                    spacing: Theme.spaceS * sheet.u
                    interactive: false
                    keyNavigationEnabled: false     // the sheet moves between rows and skips the captions
                    activeFocusOnTab: false
                    clip: true
                    highlightMoveDuration: 0
                    model: sheet.keys

                    // Brings the current row into view and keeps it clear of the fade at the edge that hides
                    // rows (`spaceL` high): the Hub's reveal (QuickMenu.qml, T-450).
                    function reveal() {
                        if (currentIndex < 0)
                            return
                        positionViewAtIndex(currentIndex, ListView.Contain)
                        const item = itemAtIndex(currentIndex)
                        if (!item || contentHeight <= height)
                            return
                        const fade = Theme.spaceL * sheet.u
                        if (item.y - contentY < fade)
                            contentY = Math.max(originY, item.y - fade)
                        else if (item.y + item.height - contentY > height - fade)
                            contentY = Math.min(originY + contentHeight - height, item.y + item.height + fade - height)
                    }
                    // The focused row grows with its actions: put it clear of the fades again.
                    onHeightChanged: reveal()
                    onContentHeightChanged: reveal()

                    delegate: Item {
                        id: entry
                        required property string modelData
                        required property int index
                        readonly property bool caption: modelData.startsWith("cap:")
                        objectName: caption ? "centreCaption_" + modelData.slice(4) : "centreRow_" + modelData.slice(2)
                        width: ListView.view.width
                        height: caption ? captionText.implicitHeight + Theme.spaceXs * sheet.u : rowItem.implicitHeight
                        Text {
                            id: captionText
                            visible: entry.caption
                            anchors.bottom: parent.bottom
                            text: entry.modelData === "cap:pinned" ? qsTr("Pinned until resolved")
                                : entry.modelData === "cap:new" ? qsTr("New") : qsTr("Earlier")
                            color: Theme.text
                            font.pixelSize: Theme.typeCaption * sheet.u
                            font.weight: Theme.weightDemiBold
                        }
                        NotificationRow {
                            id: rowItem
                            objectName: "notificationRow"
                            visible: !entry.caption
                            width: parent.width
                            u: sheet.u
                            item: entry.caption ? ({}) : (sheet.byId[entry.modelData] ?? ({}))
                            focused: list.activeFocus && entry.modelData === sheet.focusKey
                            fresh: !entry.caption && sheet.freshIds.indexOf(item.id) >= 0
                            pick: focused ? sheet.pick : 0
                            timeText: entry.caption ? "" : sheet.timeText(item.time ?? 0)
                        }
                    }
                }

                Rectangle {
                    objectName: "centreMoreAbove"
                    readonly property bool needed: list.contentY > list.originY + 1
                    visible: needed
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: Theme.spaceL * sheet.u
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Theme.glassOpaque }
                        GradientStop { position: 1.0; color: Qt.alpha(Theme.glassOpaque, 0) }
                    }
                }
                Rectangle {
                    objectName: "centreMoreBelow"
                    readonly property bool needed: list.contentY + list.height < list.originY + list.contentHeight - 1
                    visible: needed
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: Theme.spaceL * sheet.u
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.alpha(Theme.glassOpaque, 0) }
                        GradientStop { position: 1.0; color: Theme.glassOpaque }
                    }
                }

                // Nothing kept.
                Column {
                    objectName: "centreEmpty"
                    visible: sheet.keys.length === 0
                    anchors.centerIn: parent
                    width: parent.width
                    spacing: Theme.spaceS * sheet.u
                    Icon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        u: sheet.u
                        size: Theme.iconL
                        name: "notifications"
                        color: Theme.textDim
                    }
                    Text {
                        objectName: "centreEmptyTitle"
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: qsTr("No notifications")
                        color: Theme.text
                        font.pixelSize: Theme.typeHeadline * sheet.u
                        font.weight: Theme.weightDemiBold
                        wrapMode: Text.Wrap
                    }
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: qsTr("New ones show up here.")
                        color: Theme.textDim
                        font.pixelSize: Theme.typeBody * sheet.u
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }

    // A modal: every key is taken. Return on Clear all and on Quiet mode is the control's own.
    Keys.onPressed: event => {
        const k = event.key
        if (BackKey.isBackOrBackspace(k)) {
            if (!event.isAutoRepeat) {
                Sfx.back()
                sheet.close()
            }
        } else if (k === Qt.Key_Up) {
            sheet.moveUp()
        } else if (k === Qt.Key_Down) {
            sheet.moveDown()
        } else if (k === Qt.Key_Left || k === Qt.Key_Right) {
            const step = sheet.LayoutMirroring.enabled ? -1 : 1
            sheet.movePick(k === Qt.Key_Right ? step : -step)
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            if (!event.isAutoRepeat)
                sheet.activate()
        } else if (k === Qt.Key_Menu || k === Qt.Key_Delete) {
            if (!event.isAutoRepeat)
                sheet.clearCurrent()
        }
        event.accepted = true
    }
}
