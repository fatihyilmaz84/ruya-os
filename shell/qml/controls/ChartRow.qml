import QtQuick
import RuyaShell

// A tall settings row holding a BarChart (T-247), with an optional headline and caption on its
// left ("5 h 20 min", "That is 40 min more than the week before."). It takes focus like any row
// of a SettingsPane; with `interactive`, Left and Right move between the bars and the chart reads
// the bar's value above it (the keys never reach the pane, like a slider's). Read-only: Accept
// does nothing.
SettingControl {
    id: row

    property string headline
    property string caption
    property alias chart: chart
    property alias values: chart.values
    property alias labels: chart.labels
    property alias valueTexts: chart.valueTexts
    property alias highlightIndex: chart.highlightIndex
    property bool interactive: true

    // Without headline and caption the chart gets the whole row.
    readonly property bool hasText: headline.length > 0 || caption.length > 0

    height: (chart.plotHeight + 2 * Theme.typeCaption + Theme.spaceXl * 2) * u
    cornerRadius: Theme.radiusL * u
    labelVisible: false
    accessibleValue: (headline.length > 0 ? headline + ", " : "") + (caption.length > 0 ? caption + " " : "") + chart.summary

    onActiveFocusChanged: {
        if (activeFocus && interactive && chart.currentIndex < 0)
            chart.currentIndex = Math.max(0, chart.highlightIndex)
        if (!activeFocus)
            chart.currentIndex = -1
    }

    Column {
        id: textBlock
        visible: row.hasText
        anchors { left: parent.left; leftMargin: Theme.spaceL * row.u; verticalCenter: parent.verticalCenter }
        width: row.hasText ? 420 * row.u : 0
        spacing: Theme.spaceS * row.u

        Text {
            objectName: "chartHeadline"
            width: parent.width
            text: row.headline
            color: Theme.text
            font.pixelSize: Theme.typeTitle * row.u
            font.weight: Theme.weightLight
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
        }
        Text {
            objectName: "chartCaption"
            width: parent.width
            text: row.caption
            color: Theme.text
            font.pixelSize: Theme.typeCaption * row.u
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
        }
    }

    BarChart {
        id: chart
        objectName: "chart"
        anchors {
            left: row.hasText ? textBlock.right : parent.left
            leftMargin: Theme.spaceL * row.u
            right: parent.right
            rightMargin: Theme.spaceL * row.u
            verticalCenter: parent.verticalCenter
        }
        height: implicitHeight
        u: row.u
        interactive: row.interactive
        focus: false
    }

    // The chart reads Left/Right only while the row has focus; the row forwards them.
    Keys.onLeftPressed: event => {
        if (!row.interactive) {
            event.accepted = false
            return
        }
        chart.step(-1)
        event.accepted = true
    }
    Keys.onRightPressed: event => {
        if (!row.interactive) {
            event.accepted = false
            return
        }
        chart.step(1)
        event.accepted = true
    }
}
