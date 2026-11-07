pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// A row of rounded bars for a few values (T-247, 04 §5): the week chart and the 30-day strip of
// the Activity pages. Tokens only; a bar grows over `Theme.pageMs` (0 under reduced motion, so
// there is no animation then). `highlightIndex` is drawn in the primary colour (today); the other
// bars are `text` at 70 % (3:1 against the row, measured on Dreamglass's brightest tint; textDim is
// 2.3:1 there) and every label is `text` (textDim is for opaque surfaces only, 04 §3.1). With
// `interactive`, Left/Right move `currentIndex` to read a bar's value as text above it; the host
// decides when a bar is being read: it sets `currentIndex` while it has focus and resets it to -1 when not (ChartRow). The text alternative for a screen reader is
// `summary`: "Mon 1 h 20 min, Tue 0 min, ...".
FocusScope {
    id: chart

    property real u: 1
    property var values: []                // numbers >= 0, one per bar
    property var labels: []                // a short label under each bar ("" for none)
    property var valueTexts: []            // the value in words per bar ("1 h 20 min")
    property int highlightIndex: -1
    property bool interactive: false
    property int currentIndex: -1          // the bar being read (interactive charts only)
    property real plotHeight: 200          // design px: the room for the tallest bar
    property real barGap: Theme.spaceXs    // design px between bars

    readonly property int count: values.length
    readonly property real maxValue: {
        let m = 0
        for (let i = 0; i < values.length; ++i)
            m = Math.max(m, values[i])
        return m
    }
    readonly property bool hasLabels: labels.some(l => l.length > 0)
    readonly property string summary: {
        const parts = []
        for (let i = 0; i < values.length; ++i)
            parts.push(((labels[i] ?? "") + " " + (valueTexts[i] ?? "")).trim())
        return parts.join(", ")
    }
    readonly property string currentText: currentIndex >= 0 && currentIndex < values.length
        ? ((labels[currentIndex] ?? "") + " " + (valueTexts[currentIndex] ?? "")).trim() : ""

    function step(delta) {
        if (!interactive || count === 0)
            return
        const from = currentIndex < 0 ? Math.max(0, highlightIndex) : currentIndex
        const next = Math.max(0, Math.min(count - 1, from + delta))
        if (next !== currentIndex) {
            currentIndex = next
            Sfx.navigate()
        }
    }

    implicitHeight: (plotHeight + Theme.typeCaption * 2 + Theme.spaceS * 2) * u

    Accessible.role: Accessible.Graphic
    Accessible.name: summary

    // The value being read, above the plot.
    Text {
        objectName: "chartReadout"
        anchors { top: parent.top; horizontalCenter: parent.horizontalCenter }
        visible: chart.interactive && chart.currentText.length > 0
        text: chart.currentText
        color: Theme.text
        font.pixelSize: Theme.typeCaption * chart.u
        font.weight: Theme.weightDemiBold
        textFormat: Text.PlainText
    }

    Row {
        id: bars
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: chart.plotHeight * chart.u + (chart.hasLabels ? (Theme.typeCaption + Theme.spaceXs) * chart.u : 0)
        spacing: chart.barGap * chart.u

        Repeater {
            model: chart.count
            delegate: Item {
                id: slot
                required property int index
                readonly property real value: chart.values[index] ?? 0
                readonly property bool current: chart.interactive && chart.currentIndex === index
                width: (bars.width - bars.spacing * (chart.count - 1)) / Math.max(1, chart.count)
                height: bars.height

                Rectangle {
                    id: bar
                    objectName: "chartBar_" + slot.index
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: label.visible ? label.top : parent.bottom
                    anchors.bottomMargin: label.visible ? Theme.spaceXs * chart.u : 0
                    width: slot.width
                    // A bar that is 0 stays a hairline stub so the row of bars still reads as one.
                    height: slot.value > 0 && chart.maxValue > 0
                            ? Math.max(Theme.spaceXs * chart.u, chart.plotHeight * chart.u * slot.value / chart.maxValue)
                            : Theme.spaceXxs * chart.u
                    radius: Math.min(width / 2, Theme.radiusS * chart.u)
                    color: slot.index === chart.highlightIndex ? Theme.primaryFill : Theme.text
                    opacity: slot.index === chart.highlightIndex ? 1 : slot.value > 0 ? 0.7 : 0.45
                    border.width: slot.current ? Theme.focusRingWidth * chart.u : 0
                    border.color: Theme.focusRing
                    Behavior on height {
                        NumberAnimation {
                            duration: Theme.pageMs
                            easing.type: Easing.Bezier
                            easing.bezierCurve: Theme.easeSnap
                        }
                    }
                }

                Text {
                    id: label
                    objectName: "chartLabel_" + slot.index
                    anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom }
                    visible: chart.hasLabels
                    width: slot.width
                    horizontalAlignment: Text.AlignHCenter
                    text: chart.labels[slot.index] ?? ""
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * chart.u
                    font.weight: slot.index === chart.highlightIndex ? Theme.weightDemiBold : Theme.weightRegular
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
            }
        }
    }

    Keys.onLeftPressed: event => {
        if (!interactive) {
            event.accepted = false
            return
        }
        step(-1)
        event.accepted = true
    }
    Keys.onRightPressed: event => {
        if (!interactive) {
            event.accepted = false
            return
        }
        step(1)
        event.accepted = true
    }
}
