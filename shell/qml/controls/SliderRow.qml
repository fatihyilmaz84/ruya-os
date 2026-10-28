import QtQuick
import RuyaShell

// Label plus a bar. Left/Right step by `stepSize` within from..to (clamped, no wrapping) and
// are always consumed, so they never move focus out of the pane. edited(value) reports a
// change made by the user; at a bound nothing changes and nothing is emitted.
SettingControl {
    id: row

    property real from: 0
    property real to: 100
    property real stepSize: 1
    property real value: 0
    property string unit: ""          // appended to the number, e.g. "%"

    signal edited(real value)

    function step(delta) {
        const next = Math.min(to, Math.max(from, value + delta * stepSize))
        if (next === value)
            return
        Sfx.navigate()
        value = next
        edited(next)
    }

    Text {
        id: valueText
        objectName: "value"
        anchors { right: parent.right; rightMargin: Theme.spaceL * row.u; verticalCenter: parent.verticalCenter }
        width: 90 * row.u
        horizontalAlignment: Text.AlignRight
        text: Math.round(row.value) + row.unit
        color: Theme.text
        font.pixelSize: Theme.typeBody * row.u
    }
    Rectangle {
        anchors { right: valueText.left; rightMargin: Theme.spaceM * row.u; verticalCenter: parent.verticalCenter }
        width: 320 * row.u
        height: 12 * row.u
        radius: height / 2
        color: Theme.glass
        Rectangle {
            width: row.to > row.from ? parent.width * (row.value - row.from) / (row.to - row.from) : 0
            height: parent.height
            radius: parent.radius
            color: Theme.text
        }
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Left) {
            row.step(-1)
            event.accepted = true
        } else if (event.key === Qt.Key_Right) {
            row.step(1)
            event.accepted = true
        }
    }
}
