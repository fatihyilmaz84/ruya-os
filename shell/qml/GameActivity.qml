pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell
import "controls"

// "Your activity" on the game page (RUY-532, 02 §1.8, 04 §5 "Activity summary"): one block with three
// numbers, the last 30 days as bars and a chevron; A opens the game's Activity page. The page decides
// whether the section is shown and reads the ledger (`game` is `Usage.game(appId)`); this item only draws
// it. Nothing played yet: one sentence, and no focus stop.
Column {
    id: root

    property real u: 1
    property var game: ({})
    property bool ready: true
    property bool isApp: false
    // The block is the section's one focus stop: set by the page when there is something to open.
    readonly property bool played: (game.total ?? 0) > 0
    readonly property bool stopShown: ready && played
    readonly property alias block: block
    signal openRequested()

    width: parent ? parent.width : 1728 * u
    spacing: Theme.spaceS * u

    Text {
        objectName: "activityHeading"
        width: parent.width
        textFormat: Text.PlainText
        color: Theme.text
        font.pixelSize: Theme.typeHeadline * root.u
        font.weight: Theme.weightDemiBold
        elide: Text.ElideRight
        text: qsTr("Your activity")
    }

    Text {
        objectName: "activityMessage"
        width: parent.width
        visible: !root.stopShown
        text: !root.ready ? qsTr("Loading…")
                          : qsTr("You have not played this yet. When you do, the time you spend shows up here.")
        color: Theme.text
        font.pixelSize: Theme.typeBody * root.u
        wrapMode: Text.Wrap
    }

    SettingControl {
        id: block
        objectName: "detailActivity"
        visible: root.stopShown
        width: parent.width
        height: 176 * root.u                     // token-ok: 04 §5 Activity summary
        u: root.u
        label: qsTr("Your activity")
        labelVisible: false
        cornerRadius: Theme.radiusL * root.u
        hintKind: "page"
        hints: [{ action: "accept", text: qsTr("See all") }, { action: "back", text: qsTr("Back") }]
        accessibleValue: stat1.value + " " + stat1.caption + ", " + stat2.value + " " + stat2.caption + ", "
                         + stat3.value + " " + stat3.caption

        component Stat: Column {
            id: stat
            property string value
            property string caption
            width: 300 * root.u                  // token-ok: 04 §5 Activity summary
            spacing: Theme.spaceXs * root.u
            Text {
                width: parent.width
                text: stat.value
                textFormat: Text.PlainText
                color: Theme.text
                font.pixelSize: Theme.typeTitle * root.u
                font.weight: Theme.weightDemiBold
                elide: Text.ElideRight
                maximumLineCount: 1
            }
            Text {
                width: parent.width
                text: stat.caption
                textFormat: Text.PlainText
                color: Theme.text
                font.pixelSize: Theme.typeCaption * root.u
                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }

        Row {
            id: stats
            x: Theme.spaceL * root.u
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spaceL * root.u

            Stat {
                id: stat1
                objectName: "activityTotal"
                value: DurationText.plain(root.game.total ?? 0)
                caption: root.isApp ? qsTr("Time used") : qsTr("Time played")
            }
            Stat {
                id: stat2
                objectName: "activityLast"
                value: DurationText.day(root.game.last ?? 0)
                caption: root.isApp ? qsTr("Last used") : qsTr("Last played")
            }
            Stat {
                id: stat3
                objectName: "activitySessions"
                value: String(root.game.sessions ?? 0)
                caption: root.isApp ? qsTr("Times opened") : qsTr("Times played")
            }
        }

        Column {
            id: chart
            objectName: "activityChart"
            width: 560 * root.u                  // token-ok: 04 §5 Activity summary
            anchors { right: chevron.left; rightMargin: Theme.spaceL * root.u; verticalCenter: parent.verticalCenter }
            spacing: Theme.spaceXs * root.u
            Text {
                width: parent.width
                text: qsTr("Last 30 days")
                textFormat: Text.PlainText
                color: Theme.text
                font.pixelSize: Theme.typeCaption * root.u
                elide: Text.ElideRight
                maximumLineCount: 1
            }
            BarChart {
                objectName: "activityBars"
                width: parent.width
                height: plotHeight * root.u
                u: root.u
                plotHeight: 66                   // token-ok: 04 §5 Activity summary
                values: root.game.strip ?? []
                highlightIndex: 29
            }
        }

        Icon {
            id: chevron
            objectName: "activityChevron"
            anchors { right: parent.right; rightMargin: Theme.spaceS * root.u; verticalCenter: parent.verticalCenter }
            u: root.u
            name: "chevron_right"
            color: Theme.text
        }

        function accept() {
            Sfx.select()
            root.openRequested()
        }
        Keys.onReturnPressed: accept()
        Keys.onEnterPressed: accept()
    }
}
