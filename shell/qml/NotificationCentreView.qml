pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The notification centre's content (RUY-413, 02 §1 System UI, 04 §5 "Centre sheet"): one copy, shown as the bell's
// section page (NotificationsPage, RUY-1136) and in the sheet the Hub's Notifications panel opens (NotificationSheet).
//
// Top to bottom: the title (`showTitle`; a page has its own) with "N new" and Clear all (hidden when only pinned items
// are left), the Quiet mode row, then the groups "Pinned until resolved", "New" (the items that were unread when it
// opened, and those that arrive while it is `active`) and "Earlier", each under a caption. A row is a
// NotificationRow. `begin()` (the host's opening) marks everything read (the badge empties) and puts the focus on the
// first row (a pinned one, if any), else on Quiet mode. Up from the first row reaches Quiet mode, then Clear all; Up
// from there is not taken (a page hands it to the nav). On a row: Left/Right pick an action, A runs it (and the item
// goes, unless pinned), Start (the options button) clears the item (not a pinned one). Back is the host's. A row
// without actions opens its app on A when it has one; otherwise A does nothing and has no hint. When the focused row
// goes (cleared here or by its source) the focus moves to the next row, else the previous one, else Quiet mode. A
// long list scrolls with the focus in rows; on an opaque surface (`opaque`, the sheet) with fades at an edge that
// hides rows, on a page with the Settings pane's scroll cue (T-185): while more lies beyond the first / last row in
// view, that row (never the focused one) is drawn at `peekOpacity`. The focus moves inside with `focus = true` only, so a covered page never pulls it (PATTERNS.md, T-356).
FocusScope {
    id: view

    property real u: 1
    // The host is showing it (the sheet is open, the page is on top): items that arrive now are new and seen.
    property bool active: false
    // The title line's own title (the sheet's); a page shows its own title instead.
    property bool showTitle: true
    // On an opaque panel (the sheet): `textDim` for the secondary words and the fades at the list's edges in
    // `glassOpaque`. On a page (the blurred backdrop) the words are `text` and the list has no fades (04 §3.1).
    property bool opaque: true
    // The Back hint's verb ("Close" in the sheet, "Back" on a page).
    property string backText: ""

    // The ids that were unread when the centre opened, and those that arrived while it was active.
    property var freshIds: []
    // "N new" in the title: the unread count at the opening.
    property int newCount: 0
    // The clock the times are read against: set at the opening and each minute while active.
    property double nowMs: 0
    // The list's model: keys only ("cap:pinned" | "cap:new" | "cap:earlier" | "n:<id>").
    property var keys: []
    // Where the focus is: "clear" | "quiet" | "row" (then `focusKey` is the row).
    property string stop: "quiet"
    property string focusKey: ""
    // The picked action of the focused row.
    property int pick: 0

    // A picked action of an item (Shell.runNotificationAction decides what it does: an app's action goes
    // back to the app; the console's own run in the shell, a restart after a confirmation).
    signal actionRequested(var item, string action)
    // A at a row without actions whose item has an app: open that app.
    signal openRequested(var item)
    // The signed-in profile changed under it (a lock, a switch): another profile's list is never shown.
    signal profileLeft()

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
    readonly property color dimText: opaque ? Theme.textDim : Theme.text

    // What the hint bar says for the focused stop (the sheet's `modalHints`, the page's `hints`).
    readonly property var hints: {
        const back = { action: "back", text: backText }
        if (stop === "clear")
            return [{ action: "accept", text: qsTr("Clear all") }, back]
        if (stop === "quiet")
            return [{ action: "accept", text: qsTr("Toggle") }, back]
        const it = currentItem
        if (!it)
            return [back]
        const out = []
        if (currentActions.length > 0)
            out.push({ action: "accept", text: qsTr("Select") })
        else if ((it.appId ?? "") !== "")
            out.push({ action: "accept", text: qsTr("Open") })
        if (currentActions.length > 1)
            out.push({ actions: ["left", "right"], text: qsTr("Choose") })
        if (!it.pinned)
            out.push({ action: "options", text: qsTr("Clear") })
        out.push(back)
        return out
    }

    // "Just now", "2 min ago", the local time today (T-213), "Yesterday", "3 days ago".
    function timeText(ms) {
        return Notifications.ageText(ms, nowMs)
    }

    // The host opens the centre: the list as it is now, everything read, the focus on the first row.
    function begin() {
        nowMs = NotificationCentre.nowMs()
        freshIds = items.filter(i => i.unread).map(i => i.id)
        newCount = freshIds.length
        NotificationCentre.markRead()
        keys = buildKeys()
        focusFirst()
        // Then from the list's top, its first caption included (the ListView brings a new current item to the view's
        // top, which left the caption above the first row out of view), as far as the focused row stays whole.
        list.positionViewAtBeginning()
        list.reveal()
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
        list.focus = true
        list.reveal()
    }

    function focusQuiet() {
        stop = "quiet"
        focusKey = ""
        quietRow.focus = true
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
        if (!active)
            return
        // An item that arrives while the centre is shown is new, and seen.
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
    onActiveChanged: rebuild()

    // Up: the row above, then Quiet mode, then Clear all. False at the top (nothing moved).
    function moveUp() {
        if (stop === "row") {
            for (let i = list.currentIndex - 1; i >= 0; --i) {
                if (keys[i].startsWith("n:")) {
                    Sfx.navigate()
                    focusRow(i)
                    return true
                }
            }
            Sfx.navigate()
            focusQuiet()
            return true
        } else if (stop === "quiet" && hasClearable) {
            Sfx.navigate()
            stop = "clear"
            focusKey = ""
            clearAll.focus = true
            return true
        }
        return false
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
            view.actionRequested(it, action)
        } else if ((it.appId ?? "") !== "") {
            Sfx.select()
            view.openRequested(it)
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
        function onItemsChanged() { view.rebuild() }
        function onProfileChanged() { view.profileLeft() }
    }
    // The times move on while the centre is shown (not a decoration: the words change).
    Timer {
        interval: 60000
        repeat: true
        running: view.active
        onTriggered: view.nowMs = NotificationCentre.nowMs()
    }

    // The title, "N new" and Clear all.
    Item {
        id: header
        width: parent.width
        height: Math.max(titleText.implicitHeight, clearAll.height)
        Text {
            id: titleText
            objectName: "centreTitle"
            visible: view.showTitle
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("Notifications")
            color: Theme.text
            font.pixelSize: Theme.typeTitle * view.u
            font.weight: Theme.weightDemiBold
            width: view.showTitle ? Math.min(implicitWidth, header.width - (clearAll.visible ? clearAll.width + Theme.spaceM * view.u : 0)) : 0
            elide: Text.ElideRight
        }
        // Shown only where it fits whole before Clear all (a long language can leave no room: Turkish
        // "Tümünü temizle" at 100 %); the New caption and the dots still say which items are new.
        Text {
            objectName: "centreNewCount"
            readonly property real room: (clearAll.visible ? clearAll.x - Theme.spaceM * view.u : header.width) - x
            visible: view.newCount > 0 && implicitWidth <= room
            anchors { left: titleText.right; leftMargin: view.showTitle ? Theme.spaceS * view.u : 0; baseline: titleText.baseline }
            text: qsTr("%n new", "", view.newCount)
            color: view.dimText
            font.pixelSize: Theme.typeBody * view.u
        }
        SecondaryButton {
            id: clearAll
            objectName: "centreClearAll"
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            visible: view.hasClearable
            // `spaceL` padding instead of the button's `spaceXl`: the header shares one line of 800 u
            // with the title and "N new".
            width: implicitWidth - 2 * (Theme.spaceXl - Theme.spaceL) * view.u
            u: view.u
            text: qsTr("Clear all")
            onAccepted: view.clearEverything()
        }
    }

    ToggleRow {
        id: quietRow
        objectName: "centreQuiet"
        anchors.top: header.bottom
        anchors.topMargin: Theme.spaceM * view.u
        width: parent.width
        u: view.u
        label: qsTr("Quiet mode")
        iconName: "notifications_paused"
        onToggled: on => NotificationCentre.setQuiet(on)
    }
    Binding { target: quietRow; property: "checked"; value: NotificationCentre.quiet }

    // The rows, or the empty state. The list scrolls by rows with the Hub's fades (QuickMenu.qml).
    Item {
        id: listBox
        objectName: "centreListBox"
        anchors { top: quietRow.bottom; topMargin: Theme.spaceM * view.u }
        width: parent.width
        height: view.height - y

        ListView {
            id: list
            objectName: "centreList"
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Notifications")
            anchors.fill: parent
            spacing: Theme.spaceS * view.u
            interactive: false
            keyNavigationEnabled: false     // the view moves between rows and skips the captions
            activeFocusOnTab: false
            clip: true
            highlightMoveDuration: 0
            model: view.keys

            // Brings the current row into view and keeps it clear of the fade at the edge that hides
            // rows (`spaceL` high, on the opaque sheet only; the page has no fades, so no margin): the Hub's
            // reveal (QuickMenu.qml, T-450).
            function reveal() {
                // Not laid out yet (the page opening): nothing to bring into view, and Contain in a view 0 high would
                // scroll the row's caption away; onHeightChanged reveals again.
                if (currentIndex < 0 || height <= 0)
                    return
                positionViewAtIndex(currentIndex, ListView.Contain)
                const item = itemAtIndex(currentIndex)
                if (!item || contentHeight <= height)
                    return
                const fade = view.opaque ? Theme.spaceL * view.u : 0
                if (item.y - contentY < fade)
                    contentY = Math.max(originY, item.y - fade)
                else if (item.y + item.height - contentY > height - fade)
                    contentY = Math.min(originY + contentHeight - height, item.y + item.height + fade - height)
            }
            // The focused row grows with its actions: put it clear of the fades again.
            onHeightChanged: reveal()
            onContentHeightChanged: reveal()

            // The scroll cue on a page (the Settings pane's, T-185, 04 §5): the index of the first (`top`) or last row
            // in view, even in part, while more lies beyond that edge; -1 when nothing is beyond it, and on the sheet
            // (its fades are the cue there).
            function edgeRow(top) {
                if (view.opaque)
                    return -1
                const more = top ? contentY > originY + 1 : contentY + height < originY + contentHeight - 1
                if (!more)
                    return -1
                let found = -1
                for (let i = 0; i < count; ++i) {
                    const it = itemAtIndex(i)
                    if (!it || it.y + it.height <= contentY + 0.5 || it.y >= contentY + height - 0.5)
                        continue
                    if (top)
                        return i
                    found = i
                }
                return found
            }
            readonly property int peekAbove: { void contentY; void height; void contentHeight; void count; return edgeRow(true) }
            readonly property int peekBelow: { void contentY; void height; void contentHeight; void count; return edgeRow(false) }

            delegate: Item {
                id: entry
                required property string modelData
                required property int index
                readonly property bool caption: modelData.startsWith("cap:")
                objectName: caption ? "centreCaption_" + modelData.slice(4) : "centreRow_" + modelData.slice(2)
                width: ListView.view.width
                height: caption ? captionText.implicitHeight + Theme.spaceXs * view.u : rowItem.implicitHeight
                // The scroll cue: the peek row at `peekOpacity`, never the focused one; eased like a Settings row.
                readonly property bool peek: (index === list.peekAbove || index === list.peekBelow) && !rowItem.focused
                opacity: peek ? Theme.peekOpacity : 1
                Behavior on opacity { NumberAnimation { duration: Theme.focusMs } }   // instant under reduced motion
                Text {
                    id: captionText
                    visible: entry.caption
                    anchors.bottom: parent.bottom
                    text: entry.modelData === "cap:pinned" ? qsTr("Pinned until resolved")
                        : entry.modelData === "cap:new" ? qsTr("New") : qsTr("Earlier")
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * view.u
                    font.weight: Theme.weightDemiBold
                }
                NotificationRow {
                    id: rowItem
                    objectName: "notificationRow"
                    visible: !entry.caption
                    width: parent.width
                    u: view.u
                    item: entry.caption ? ({}) : (view.byId[entry.modelData] ?? ({}))
                    focused: list.activeFocus && entry.modelData === view.focusKey
                    fresh: !entry.caption && view.freshIds.indexOf(item.id) >= 0
                    pick: focused ? view.pick : 0
                    timeText: entry.caption ? "" : view.timeText(item.time ?? 0)
                }
            }
        }

        Rectangle {
            objectName: "centreMoreAbove"
            readonly property bool needed: list.contentY > list.originY + 1
            visible: view.opaque && needed
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: Theme.spaceL * view.u
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.glassOpaque }
                GradientStop { position: 1.0; color: Qt.alpha(Theme.glassOpaque, 0) }
            }
        }
        Rectangle {
            objectName: "centreMoreBelow"
            readonly property bool needed: list.contentY + list.height < list.originY + list.contentHeight - 1
            visible: view.opaque && needed
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: Theme.spaceL * view.u
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.alpha(Theme.glassOpaque, 0) }
                GradientStop { position: 1.0; color: Theme.glassOpaque }
            }
        }

        // Nothing kept.
        Column {
            objectName: "centreEmpty"
            visible: view.keys.length === 0
            anchors.centerIn: parent
            width: parent.width
            spacing: Theme.spaceS * view.u
            Icon {
                anchors.horizontalCenter: parent.horizontalCenter
                u: view.u
                size: Theme.iconL
                name: "notifications"
                color: view.dimText
            }
            Text {
                objectName: "centreEmptyTitle"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("No notifications")
                color: Theme.text
                font.pixelSize: Theme.typeHeadline * view.u
                font.weight: Theme.weightDemiBold
                wrapMode: Text.Wrap
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("New ones show up here.")
                color: view.dimText
                font.pixelSize: Theme.typeBody * view.u
                wrapMode: Text.Wrap
            }
        }
    }

    // The centre's keys; Back and anything not taken here are the host's (a page: Up at the top goes to the nav,
    // LB/RB step the section). Return on Clear all and on Quiet mode is the control's own.
    Keys.onPressed: event => {
        const k = event.key
        if (k === Qt.Key_Up) {
            event.accepted = view.moveUp()
        } else if (k === Qt.Key_Down) {
            view.moveDown()
            event.accepted = true
        } else if (k === Qt.Key_Left || k === Qt.Key_Right) {
            const step = view.LayoutMirroring.enabled ? -1 : 1
            view.movePick(k === Qt.Key_Right ? step : -step)
            event.accepted = true
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            if (!event.isAutoRepeat)
                view.activate()
            event.accepted = true
        } else if (k === Qt.Key_Menu || k === Qt.Key_Delete) {
            if (!event.isAutoRepeat)
                view.clearCurrent()
            event.accepted = true
        }
    }
}
