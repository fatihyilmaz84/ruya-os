pragma ComponentBehavior: Bound
import QtQuick
import QtQml.Models
import RuyaShell
import "controls"

// Settings -> Profiles -> Activity (T-247): what the active profile played. Private to the
// profile: it reads the active profile's ledger only, and no profile ever sees another's.
//   This week      a bar chart of the last seven days (today highlighted) and one plain sentence
//   Most played    the top five of the last 30 days (Accept opens the game's page)
//   Highlights     modest: the longest session this month, days in a row, games not played lately
//   History        newest first, grouped by day
//   Clear my activity   (after a confirmation) deletes the ledger: the same call as T-220's. It is the
//                       first row of History, so a long list does not bury it (RUY-48).
// The ledger is read when the page appears and kept fresh only while an Activity page is on screen
// (Usage.setWatching); History pages in: focus on its last row asks for 60 more sessions (Usage.loadMore).
// The numbers come from the Usage singleton (computed from the service's day rows); the words are
// DurationText's and this page's. No ranking, no goals, nothing to win.
Page {
    id: page

    title: qsTr("Activity")

    hints: body.hints

    readonly property var week: Usage.week
    readonly property bool showData: Usage.ready && !Usage.empty

    // The catalogue is read as a property, so names appear when it has loaded.
    function nameOf(appId) {
        const app = Store.catalogue.find(a => a.id === appId)
        if (app && app.name)
            return app.name
        const last = appId.split(".").pop()
        return last.length > 0 ? last : appId
    }

    // One plain sentence against the week before (never a score).
    function weekSentence() {
        const w = week
        const diff = w.total - w.previous
        if (w.total === 0 && w.previous === 0)
            return qsTr("Nothing played in the last two weeks.")
        if (w.total === 0)
            return qsTr("Nothing played this week yet.")
        if (w.previous === 0)
            return qsTr("Nothing played the week before.")
        if (Math.abs(diff) < 300)
            return qsTr("About the same as the week before.")
        return diff > 0 ? qsTr("%1 more than the week before.").arg(DurationText.plain(diff))
                        : qsTr("%1 less than the week before.").arg(DurationText.plain(-diff))
    }

    // The game's own icon (the Library's art.icon, else the Store's), or "" for the generic glyph.
    function iconOf(appId) {
        const item = Library.items.find(i => Library.sessionAppId(i.id) === appId)
        const own = item && item.art ? (item.art.icon ?? "") : ""
        const app = own === "" ? Store.catalogue.find(a => a.id === appId) : null
        const path = own !== "" ? own : app ? (app.icon ?? "") : ""
        // A path (Linux "/..." or a Windows drive "C:/...") becomes a file URL; a URL stays as it is.
        return path.startsWith("/") ? "file://" + path : /^[A-Za-z]:\//.test(path) ? "file:///" + path : path
    }

    function lastPlayedText(unix) {
        const iso = TimeZone.formatIsoDate(unix * 1000)
        const ago = Usage.daysAgo(iso)
        // After "last played": lower case, unlike the day headings.
        return ago === 0 ? qsTr("today") : ago === 1 ? qsTr("yesterday") : DurationText.dayWord(ago < 0 ? 99 : ago, iso)
    }

    // The history as a ListModel, so a DelegateChooser can pick the heading or the row. It is
    // rebuilt only when the content changes.
    ListModel { id: historyModel }
    property string historySignature: ""

    function rowOf(item) {
        return {
            kind: item.kind,
            day: item.day ?? "",
            appId: item.appId ?? "",
            start: item.start ?? 0,
            seconds: item.seconds ?? 0,
            reason: item.reason ?? "",
            running: item.open ?? false
        }
    }

    // A page appended to the list (the old rows are its start) keeps the rows it has, so the focus
    // stays on the row the player was on; any other change rebuilds the list.
    function syncHistory() {
        const list = Usage.history
        const signature = JSON.stringify(list)
        if (signature === historySignature)
            return
        historySignature = signature
        let grows = list.length >= historyModel.count
        for (let i = 0; grows && i < historyModel.count; ++i) {
            const old = historyModel.get(i)
            const item = list[i]
            // A day heading may gain seconds when the page continues its day; a session may not change.
            grows = old.kind === item.kind && (item.kind === "day" ? old.day === item.day
                                                : old.appId === item.appId && old.start === item.start && old.running === (item.open ?? false))
        }
        if (!grows) {
            historyModel.clear()
        } else {
            for (let i = 0; i < historyModel.count; ++i) {
                if (list[i].kind === "day" && historyModel.get(i).seconds !== list[i].seconds)
                    historyModel.setProperty(i, "seconds", list[i].seconds)
            }
        }
        for (let i = historyModel.count; i < list.length; ++i)
            historyModel.append(rowOf(list[i]))
    }

    function dataChanged() {
        syncHistory()
        body.reflow()
        Qt.callLater(body.settleFocus)
    }

    Connections {
        target: Usage
        function onDataChanged() { page.dataChanged() }
        function onClearFinished(status) {
            if (status === "ok") {
                Notifications.show(qsTr("Your activity was cleared."), "success")
            } else {
                Notifications.show(qsTr("Your activity could not be cleared."), "error")
            }
        }
    }

    // A read that fails leaves nothing to browse: Try again takes the focus (the data rows are hidden).
    readonly property bool failed: !Usage.ready && Usage.status !== ""
    onFailedChanged: {
        if (!failed)
            return
        if (body.activeFocus)
            retryRow.forceActiveFocus()
        else
            retryRow.focus = true
    }

    onVisibleChanged: Usage.setWatching(page, visible)
    Component.onCompleted: {
        syncHistory()
        Usage.setWatching(page, visible)
    }

    SettingsPane {
        id: body
        objectName: "activityBody"
        anchors.fill: parent
        u: page.u
        focus: true
        // The chart is read with Left and Right (a bar at a time); every other row gives its own hints by kind.
        hints: chartRow.activeFocus ? [{ actions: ["left", "right"], text: qsTr("Browse") }, { action: "back", text: qsTr("Back") }]
               : focusedRow ? (focusedRow as SettingControl).hints : [{ action: "accept", text: qsTr("Select") }, { action: "back", text: qsTr("Back") }]
        onExitRequested: page.backRequested()

        // Shown instead of the data.
        Text {
            objectName: "activityMessage"
            width: parent ? parent.width : 0
            visible: !page.showData
            text: !Usage.ready && Usage.status === "" ? qsTr("Loading…")
                : !Usage.ready ? qsTr("Your activity could not be read.")
                : qsTr("Nothing here yet. Once you play, this page lists your games and how long you played. It stays on this console, and Clear my activity deletes it.")
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
            wrapMode: Text.Wrap
        }
        SettingRow {
            id: retryRow
            objectName: "activityRetry"
            kind: "action"
            u: page.u
            visible: page.failed
            label: qsTr("Try again")
            onActivated: Usage.refresh()
        }

        Text {
            objectName: "activityHeadWeek"
            width: parent ? parent.width : 0
            visible: page.showData
            topPadding: Theme.spaceS * page.u
            text: qsTr("This week")
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
            font.weight: Theme.weightDemiBold
        }
        ChartRow {
            id: chartRow
            objectName: "activityWeek"
            u: page.u
            visible: page.showData
            headline: DurationText.plain(page.week.total ?? 0)
            caption: page.weekSentence()
            values: (page.week.days ?? []).map(d => d.seconds)
            labels: (page.week.days ?? []).map(d => DurationText.weekdayShort(d.dow))
            valueTexts: (page.week.days ?? []).map(d => DurationText.plain(d.seconds))
            highlightIndex: (page.week.days ?? []).length - 1
        }

        GroupLabel {
            objectName: "activityHeadTop"
            visible: page.showData && Usage.top.length > 0
            text: qsTr("Most played, last 30 days")
            u: page.u
        }
        Repeater {
            id: topRepeater
            model: page.showData ? Usage.top : []
            delegate: SettingRow {
                id: topRow
                required property var modelData
                required property int index
                objectName: "activityTop_" + index
                kind: "page"
                u: page.u
                iconName: "sports_esports"
                iconSource: page.iconOf(modelData.appId)
                label: page.nameOf(modelData.appId)
                value: qsTr("%1, last played %2").arg(DurationText.plain(modelData.seconds)).arg(page.lastPlayedText(modelData.last))
                onActivated: page.openRequested("activityGame", ({ appId: modelData.appId }))
            }
        }

        GroupLabel {
            objectName: "activityHeadHighlights"
            visible: page.showData && highlightsPresent
            readonly property bool highlightsPresent: (Usage.highlights.longestMonth?.seconds ?? 0) > 0
                                                      || (Usage.highlights.streak ?? 0) > 0
                                                      || (Usage.highlights.lapsed ?? []).length > 0
            text: qsTr("Highlights")
            u: page.u
        }
        SettingRow {
            id: longestRow
            objectName: "activityLongest"
            kind: "info"
            u: page.u
            visible: page.showData && (Usage.highlights.longestMonth?.seconds ?? 0) > 0
            label: qsTr("Longest session this month")
            value: qsTr("%1, %2").arg(page.nameOf(Usage.highlights.longestMonth?.appId ?? ""))
                       .arg(DurationText.plain(Usage.highlights.longestMonth?.seconds ?? 0))
        }
        SettingRow {
            id: streakRow
            objectName: "activityStreak"
            kind: "info"
            u: page.u
            visible: page.showData && (Usage.highlights.streak ?? 0) > 0
            label: qsTr("You have played %n day(s) in a row.", "", Usage.highlights.streak ?? 0)
        }
        Repeater {
            model: page.showData ? (Usage.highlights.lapsed ?? []) : []
            delegate: SettingRow {
                required property var modelData
                required property int index
                objectName: "activityLapsed_" + index
                kind: "page"
                u: page.u
                label: qsTr("You have not played %1 for %n day(s).", "", modelData.days).arg(page.nameOf(modelData.appId))
                onActivated: page.openRequested("activityGame", ({ appId: modelData.appId }))
            }
        }

        Text {
            objectName: "activityHeadHistory"
            width: parent ? parent.width : 0
            visible: page.showData && historyModel.count > 0
            topPadding: Theme.spaceS * page.u
            text: qsTr("History")
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
            font.weight: Theme.weightDemiBold
        }
        SettingRow {
            id: clearRow
            objectName: "activityClear"
            kind: "action"
            u: page.u
            visible: page.showData
            label: qsTr("Clear my activity")
            onActivated: {
                clearConfirm.customTitle = qsTr("Clear your activity?")
                clearConfirm.detail = qsTr("Deletes the list of what you played.\nYour games and saves stay.\nThis can't be undone.")
                clearConfirm.customConfirmName = qsTr("Clear my activity")
                clearConfirm.open("custom")
            }
        }

        Repeater {
            model: page.showData ? historyModel : null
            delegate: DelegateChooser {
                role: "kind"
                DelegateChoice {
                    roleValue: "day"
                    Text {
                        required property string day
                        required property int seconds
                        objectName: "activityDay_" + day
                        readonly property int ago: Usage.daysAgo(day)
                        width: parent ? parent.width : 0
                        topPadding: Theme.spaceXs * page.u
                        text: qsTr("%1, %2").arg(DurationText.dayWord(ago < 0 ? 99 : ago, day)).arg(DurationText.plain(seconds))
                        color: Theme.text
                        font.pixelSize: Theme.typeCaption * page.u
                        font.weight: Theme.weightDemiBold
                    }
                }
                DelegateChoice {
                    roleValue: "session"
                    SettingRow {
                        required property string appId
                        required property double start
                        required property int seconds
                        required property bool running
                        required property int index
                        objectName: "activitySession_" + appId + "_" + start
                        kind: "page"
                        u: page.u
                        label: page.nameOf(appId)
                        value: running ? qsTr("%1, playing now").arg(TimeZone.formatClock(start * 1000))
                                       : qsTr("%1, %2").arg(TimeZone.formatClock(start * 1000)).arg(DurationText.plain(seconds))
                        onActivated: page.openRequested("activityGame", ({ appId: appId }))
                        // The last row of the list: its focus asks for the next 60 sessions. The row keeps the
                        // focus (syncHistory appends), so the player goes on down the longer list.
                        readonly property bool lastRow: index === historyModel.count - 1
                        onActiveFocusChanged: if (activeFocus && lastRow && Usage.more) Usage.loadMore()
                    }
                }
            }
        }
        SettingNote {
            objectName: "activityCapped"
            u: page.u
            topPadding: Theme.spaceS * page.u
            visible: page.showData && Usage.capped
            text: qsTr("Showing your last 1000 sessions.")
        }
    }

    PowerConfirm {
        id: clearConfirm
        objectName: "activityClearConfirm"
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: page.u
        onConfirmed: Usage.clearHistory()
        onClosed: Qt.callLater(body.settleFocus)
    }
}
