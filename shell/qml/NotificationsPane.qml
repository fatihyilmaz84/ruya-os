pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Notifications (RUY-414, 02 §1.2, T-245): the signed-in profile's notification settings,
// kept by Notifications1 (NotificationCentre) and written at once. Quiet mode (the same switch as the
// bell's centre and the Hub), "Don't interrupt games", quiet hours (a schedule: from and to on the
// console's clock, the span may run over midnight), how long a toast stays, the notification sound,
// "Show notifications from" (a switch per source, then one per app that has sent one: an item of a source
// that is off is not kept and not shown) and Clear history (pinned items stay).
SettingsPane {
    id: pane

    property Item overlay      // where the confirmation is parented

    // The sources of the system, in the order of the rows; the apps follow (see syncApps).
    readonly property var fixedSources: ["system", "updates", "devices", "store"]

    function sourceLabel(key) {
        switch (key) {
        case "system": return qsTr("System")
        case "updates": return qsTr("Updates")
        case "devices": return qsTr("Devices")
        case "store": return qsTr("Store and downloads")
        }
        return key.startsWith("app:") ? pane.appName(key.substring(4)) : key
    }
    // An app's name: its library title, else its Store name, else its id.
    function appName(appId) {
        const found = Library.items.length > 0 ? Library.itemForApp(appId) : ({})   // any installation (RUY-137)
        return found.title ?? (Store.app(appId).name || appId)
    }

    // "00:00" ... "23:00", and the stored time when it is not on the hour (set by something else).
    function timeOptions(current) {
        const out = []
        for (let h = 0; h < 24; ++h)
            out.push(String(h).padStart(2, "0") + ":00")
        if (current && out.indexOf(current) < 0) {
            out.push(current)
            out.sort()
        }
        return out.map(t => ({ value: t, label: t }))
    }
    function secondsOptions(current) {
        const secs = [4, 6, 8, 12]
        if (secs.indexOf(current) < 0) {
            secs.push(current)
            secs.sort((a, b) => a - b)
        }
        return secs.map(s => ({ value: s, label: qsTr("%1 s").arg(s) }))
    }
    function writeQuietHours(enabled, from, to) {
        NotificationCentre.setSetting("QuietHours", ({ enabled: enabled, from: from, to: to }))
    }
    function writeSource(key, on) {
        const next = Object.assign({}, NotificationCentre.sourcesEnabled)
        next[key] = on
        NotificationCentre.setSetting("SourcesEnabled", next)
    }

    // One switch per source: the four of the system, then an app once it has sent a notification or has a
    // switch of its own. Rows are only added (an app that was shown stays, so the focus never jumps).
    ListModel {
        id: sourceModel
        ListElement { sourceKey: "system" }
        ListElement { sourceKey: "updates" }
        ListElement { sourceKey: "devices" }
        ListElement { sourceKey: "store" }
    }
    function hasSource(key) {
        for (let i = 0; i < sourceModel.count; ++i) {
            if (sourceModel.get(i).sourceKey === key)
                return true
        }
        return false
    }
    function syncApps() {
        const keys = Object.keys(NotificationCentre.sourcesEnabled).filter(k => k.startsWith("app:"))
        for (const it of NotificationCentre.items) {
            if (it.source === "app" && (it.appId ?? "") !== "")
                keys.push("app:" + it.appId)
        }
        let added = false
        for (const k of keys) {
            if (!pane.hasSource(k)) {
                sourceModel.append({ sourceKey: k })
                added = true
            }
        }
        if (added)
            pane.reflow()
    }
    Connections {
        target: NotificationCentre
        function onItemsChanged() { pane.syncApps() }
        function onSettingsChanged() { pane.syncApps() }
    }
    Component.onCompleted: Qt.callLater(syncApps)       // off the frame that builds the pane (T-349)

    ToggleRow {
        id: quiet
        objectName: "rowNotifQuiet"
        u: pane.u
        label: qsTr("Quiet mode")
        iconName: "notifications_paused"
        onToggled: checked => NotificationCentre.setQuiet(checked)
    }
    Binding { target: quiet; property: "checked"; value: NotificationCentre.quiet }

    SettingNote {
        objectName: "notifQuietHoursNote"
        u: pane.u
        visible: Notifications.inQuietHours
        text: qsTr("Quiet hours until %1").arg(Notifications.quietUntil)
    }

    ToggleRow {
        id: dontInterrupt
        objectName: "rowNotifDontInterrupt"
        u: pane.u
        label: qsTr("Don't interrupt games")
        onToggled: checked => NotificationCentre.setDontInterruptGames(checked)
    }
    Binding { target: dontInterrupt; property: "checked"; value: NotificationCentre.dontInterruptGames }

    SettingNote {
        objectName: "notifDontInterruptNote"
        u: pane.u
        text: qsTr("Over a game, only urgent notifications show.")
    }

    ChoiceRow {
        id: hoursOn
        objectName: "rowNotifQuietHours"
        u: pane.u
        label: qsTr("Quiet hours")
        options: [{ value: false, label: qsTr("Off") }, { value: true, label: qsTr("On") }]
        onEdited: v => pane.writeQuietHours(v, NotificationCentre.quietHours.from, NotificationCentre.quietHours.to)
    }
    Binding { target: hoursOn; property: "value"; value: NotificationCentre.quietHours.enabled === true }

    ChoiceRow {
        id: hoursFrom
        objectName: "rowNotifQuietFrom"
        u: pane.u
        visible: NotificationCentre.quietHours.enabled === true
        label: qsTr("Quiet from")
        options: pane.timeOptions(NotificationCentre.quietHours.from)
        onEdited: v => pane.writeQuietHours(true, v, NotificationCentre.quietHours.to)
    }
    Binding { target: hoursFrom; property: "value"; value: NotificationCentre.quietHours.from }

    ChoiceRow {
        id: hoursTo
        objectName: "rowNotifQuietTo"
        u: pane.u
        visible: NotificationCentre.quietHours.enabled === true
        label: qsTr("Quiet until")
        options: pane.timeOptions(NotificationCentre.quietHours.to)
        onEdited: v => pane.writeQuietHours(true, NotificationCentre.quietHours.from, v)
    }
    Binding { target: hoursTo; property: "value"; value: NotificationCentre.quietHours.to }

    ChoiceRow {
        id: toastFor
        objectName: "rowNotifToastSeconds"
        u: pane.u
        label: qsTr("Show each for")
        options: pane.secondsOptions(NotificationCentre.toastSeconds)
        onEdited: v => NotificationCentre.setSetting("ToastSeconds", v)
    }
    Binding { target: toastFor; property: "value"; value: NotificationCentre.toastSeconds }

    ToggleRow {
        id: sounds
        objectName: "rowNotifSounds"
        u: pane.u
        label: qsTr("Notification sounds")
        onToggled: checked => NotificationCentre.setSetting("Sounds", checked)
    }
    Binding { target: sounds; property: "checked"; value: NotificationCentre.sounds }

    GroupLabel {
        u: pane.u
        text: qsTr("Show notifications from")
    }

    Repeater {
        model: sourceModel
        ToggleRow {
            id: sourceRow
            required property string sourceKey
            objectName: "rowNotifSource_" + sourceKey
            u: pane.u
            label: pane.sourceLabel(sourceKey)
            onToggled: checked => pane.writeSource(sourceKey, checked)
            Binding { target: sourceRow; property: "checked"; value: NotificationCentre.sourcesEnabled[sourceRow.sourceKey] !== false }
        }
    }

    SettingRow {
        id: clearRow
        objectName: "rowNotifClearHistory"
        kind: "action"
        u: pane.u
        label: qsTr("Clear history")
        onActivated: pane.askClear()
    }

    // Clear history asks first; the confirm button names the action (T-194). Pinned items stay.
    function askClear() {
        clearSlot.active = true
        clearConfirm.customTitle = qsTr("Clear the notification history?")
        clearConfirm.detail = qsTr("Pinned notifications stay until what they are about is dealt with.")
        clearConfirm.customConfirmName = qsTr("Clear history")
        clearConfirm.open("custom")
    }
    Loader {
        id: clearSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false           // built on the first opening, then kept (PATTERNS.md)
        sourceComponent: Component {
            PowerConfirm {
                objectName: "notifClearConfirm"
                u: pane.u
                onConfirmed: NotificationCentre.dismissAll()
            }
        }
    }
    readonly property PowerConfirm clearConfirm: clearSlot.item as PowerConfirm
}
