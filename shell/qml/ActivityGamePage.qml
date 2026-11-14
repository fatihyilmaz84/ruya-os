pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell
import "controls"

// One game's activity (T-247): total time, how often it was played, first and last time, the
// longest and the average session, and the last 30 days as a strip of bars. Opened with
// Shell.openPage("activityGame", { appId }) from the Activity page or the "Your activity" button
// of the app page. Private to the active profile, like the Activity page.
Page {
    id: page

    readonly property string appId: params.appId ?? ""
    // Usage.game() is a function, not a property: the tick makes the binding read it again
    // whenever the ledger changes.
    property int statsTick: 0
    readonly property var game: Usage.game(statsTick >= 0 ? appId : "")
    Connections {
        target: Usage
        function onDataChanged() { page.statsTick++ }
    }
    readonly property bool played: (game.total ?? 0) > 0

    title: {
        const app = Store.catalogue.find(a => a.id === appId)
        if (app && app.name)
            return app.name
        const last = appId.split(".").pop()
        return last.length > 0 ? last : appId
    }

    hints: body.hints

    function dayText(unix) {
        if (!unix)
            return "-"
        const iso = TimeZone.formatIsoDate(unix * 1000)
        const ago = Usage.daysAgo(iso)
        return ago < 0 || ago > 6 ? Qt.locale().toString(new Date(iso + "T12:00:00"), "d MMM yyyy")
                                  : DurationText.dayWord(ago, iso)
    }

    // The date of bar i of the 30-day strip (the last bar is today).
    function stripDate(i) {
        const base = new Date(Usage.today + "T12:00:00")
        base.setDate(base.getDate() - (29 - i))
        return base
    }

    onVisibleChanged: {
        if (visible)
            Usage.refresh()
    }
    Component.onCompleted: {
        if (visible)
            Usage.refresh()
    }

    SettingsPane {
        id: body
        objectName: "gameBody"
        anchors.fill: parent
        u: page.u
        focus: true
        hints: strip.activeFocus ? [{ button: "Left/Right", text: qsTr("Browse") }, { button: "B", text: qsTr("Back") }]
                                 : [{ button: "B", text: qsTr("Back") }]
        onExitRequested: page.backRequested()

        Text {
            objectName: "gameMessage"
            width: parent ? parent.width : 0
            visible: !Usage.ready || !page.played
            text: !Usage.ready ? qsTr("Loading…")
                              : qsTr("You have not played this yet. When you do, the time you spend shows up here.")
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
            wrapMode: Text.Wrap
        }

        SettingRow {
            objectName: "gameTotal"
            kind: "info"
            u: page.u
            visible: Usage.ready && page.played
            label: qsTr("Time played")
            value: DurationText.plain(page.game.total ?? 0)
        }
        SettingRow {
            objectName: "gameSessions"
            kind: "info"
            u: page.u
            visible: Usage.ready && page.played
            label: qsTr("Times played")
            value: String(page.game.sessions ?? 0)
        }
        SettingRow {
            objectName: "gameFirst"
            kind: "info"
            u: page.u
            visible: Usage.ready && page.played
            label: qsTr("First played")
            value: page.dayText(page.game.first ?? 0)
        }
        SettingRow {
            objectName: "gameLast"
            kind: "info"
            u: page.u
            visible: Usage.ready && page.played
            label: qsTr("Last played")
            value: page.dayText(page.game.last ?? 0)
        }
        SettingRow {
            objectName: "gameLongest"
            kind: "info"
            u: page.u
            visible: Usage.ready && page.played
            label: qsTr("Longest session")
            value: DurationText.plain(page.game.longest ?? 0)
        }
        SettingRow {
            objectName: "gameAverage"
            kind: "info"
            u: page.u
            visible: Usage.ready && page.played
            label: qsTr("Average session")
            value: DurationText.plain(page.game.average ?? 0)
        }
        Text {
            objectName: "gameHeadStrip"
            width: parent ? parent.width : 0
            visible: Usage.ready && page.played
            topPadding: Theme.spaceS * page.u
            text: qsTr("Last 30 days")
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
            font.weight: Theme.weightDemiBold
        }
        ChartRow {
            id: strip
            objectName: "gameStrip"
            u: page.u
            visible: Usage.ready && page.played
            values: page.game.strip ?? []
            valueTexts: (page.game.strip ?? []).map((s, i) =>
                Qt.locale().toString(page.stripDate(i), "ddd d MMM") + ", " + DurationText.plain(s))
            highlightIndex: 29
        }
    }
}
