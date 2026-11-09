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
//   Clear my activity   (after a confirmation) deletes the ledger: the same call as T-220's.
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

    function syncHistory() {
        const list = Usage.history
        const signature = JSON.stringify(list)
        if (signature === historySignature)
            return
        historySignature = signature
        historyModel.clear()
        for (const item of list) {
            historyModel.append({
                kind: item.kind,
                day: item.day ?? "",
                appId: item.appId ?? "",
                start: item.start ?? 0,
                seconds: item.seconds ?? 0,
                reason: item.reason ?? "",
                running: item.open ?? false
            })
        }
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

    onVisibleChanged: {
        if (visible)
            Usage.refresh()
    }
    Component.onCompleted: {
        syncHistory()
        if (visible)
            Usage.refresh()
    }

    SettingsPane {
        id: body
        objectName: "activityBody"
        anchors.fill: parent
        u: page.u
        focus: true
        // The chart and the two highlight facts only read; the other rows do something on Accept.
        // The chart is read with Left and Right (a bar at a time); the two highlight facts only read.
        hints: chartRow.activeFocus ? [{ button: "Left/Right", text: qsTr("Browse") }, { button: "B", text: qsTr("Back") }]
               : (longestRow.activeFocus || streakRow.activeFocus)
               ? [{ button: "B", text: qsTr("Back") }]
               : [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Back") }]
        onExitRequested: page.backRequested()

        // Shown instead of the data.
        Text {
            objectName: "activityMessage"
            width: parent ? parent.width : 0
            visible: !page.showData
            text: !Usage.ready && Usage.status === "" ? qsTr("Loading…")
                : !Usage.ready ? qsTr("Your activity could not be read.")
                : qsTr("Nothing here yet. When you play something, the time you spend shows up on this page. Only you can see it.")
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
            wrapMode: Text.Wrap
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

        Text {
            objectName: "activityHeadTop"
            width: parent ? parent.width : 0
            visible: page.showData && Usage.top.length > 0
            topPadding: Theme.spaceS * page.u
            text: qsTr("Most played, last 30 days")
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
            font.weight: Theme.weightDemiBold
        }
        Repeater {
            id: topRepeater
            model: page.showData ? Usage.top : []
            delegate: SettingRow {
                id: topRow
                required property var modelData
                required property int index
                objectName: "activityTop_" + index
                u: page.u
                iconName: "sports_esports"
                label: page.nameOf(modelData.appId)
                value: qsTr("%1, last played %2").arg(DurationText.plain(modelData.seconds)).arg(page.lastPlayedText(modelData.last))
                onActivated: page.openRequested("activityGame", ({ appId: modelData.appId }))
            }
        }

        Text {
            objectName: "activityHeadHighlights"
            width: parent ? parent.width : 0
            visible: page.showData && highlightsPresent
            readonly property bool highlightsPresent: (Usage.highlights.longestMonth?.seconds ?? 0) > 0
                                                      || (Usage.highlights.streak ?? 0) > 0
                                                      || (Usage.highlights.lapsed ?? []).length > 0
            topPadding: Theme.spaceS * page.u
            text: qsTr("Highlights")
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
            font.weight: Theme.weightDemiBold
        }
        SettingRow {
            id: longestRow
            objectName: "activityLongest"
            u: page.u
            visible: page.showData && (Usage.highlights.longestMonth?.seconds ?? 0) > 0
            label: qsTr("Longest session this month")
            value: qsTr("%1, %2").arg(page.nameOf(Usage.highlights.longestMonth?.appId ?? ""))
                       .arg(DurationText.plain(Usage.highlights.longestMonth?.seconds ?? 0))
        }
        SettingRow {
            id: streakRow
            objectName: "activityStreak"
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
                        objectName: "activitySession_" + appId + "_" + start
                        u: page.u
                        label: page.nameOf(appId)
                        value: running ? qsTr("%1, playing now").arg(TimeZone.formatClock(start * 1000))
                                       : qsTr("%1, %2").arg(TimeZone.formatClock(start * 1000)).arg(DurationText.plain(seconds))
                        onActivated: page.openRequested("activityGame", ({ appId: appId }))
                    }
                }
            }
        }

        SettingRow {
            id: clearRow
            objectName: "activityClear"
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
